//! Mjolnir Web Gateway — bridges HTTP to Iroh TCP forwarding.
//!
//! Accepts plain HTTP from Cloudflare (which terminates TLS), extracts the
//! target VM from the subdomain (z32-encoded node ID), connects via Iroh's
//! TCP forwarding protocol, and does blind bidirectional byte copying.
//!
//! URL format: https://<z32-node-id>[-<port>].vm.worldtree.network
//!
//! Supports HTTP/1.1, WebSocket upgrades, SSE, and any TCP-based protocol.

use clap::Parser;
use dashmap::DashMap;
use iroh::endpoint::{Connection, Endpoint};
use iroh_base::{EndpointAddr, PublicKey};
use mjolnir_protocol::TCP_FWD_ALPN;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tracing::{debug, info, warn};

#[derive(Parser, Clone)]
#[command(name = "mjolnir-gateway", about = "Mjolnir Web Gateway — HTTP to Iroh bridge")]
struct Config {
    /// Listen address
    #[arg(long, default_value = "0.0.0.0:8080", env = "GATEWAY_LISTEN")]
    listen: SocketAddr,

    /// Default VM target port when none specified in subdomain
    #[arg(long, default_value = "80", env = "GATEWAY_DEFAULT_PORT")]
    default_port: u16,

    /// Domain suffix (requests must match *.<domain>)
    #[arg(long, default_value = "vm.worldtree.network", env = "GATEWAY_DOMAIN")]
    domain: String,

    /// Iroh connection timeout in seconds
    #[arg(long, default_value = "15", env = "GATEWAY_CONNECT_TIMEOUT")]
    connect_timeout: u64,

    /// Response timeout in seconds (0 = no timeout). Time to wait for the
    /// first byte from the VM after forwarding the request.
    #[arg(long, default_value = "30", env = "GATEWAY_RESPONSE_TIMEOUT")]
    response_timeout: u64,

    /// Connection pool TTL in seconds. Cached Iroh connections are evicted
    /// after this idle period.
    #[arg(long, default_value = "300", env = "GATEWAY_POOL_TTL")]
    pool_ttl: u64,

    /// Maximum number of cached connections in the pool.
    #[arg(long, default_value = "256", env = "GATEWAY_POOL_MAX")]
    pool_max: usize,
}

/// Cached QUIC connection with last-used timestamp for TTL eviction.
struct CachedConnection {
    conn: Connection,
    last_used: Instant,
}

/// Connection pool that caches Iroh QUIC connections keyed by PublicKey.
/// Avoids repeated QUIC handshakes + relay discovery for warm requests.
struct ConnectionPool {
    cache: DashMap<PublicKey, CachedConnection>,
    ttl: Duration,
    max_size: usize,
}

impl ConnectionPool {
    fn new(ttl: Duration, max_size: usize) -> Self {
        Self {
            cache: DashMap::new(),
            ttl,
            max_size,
        }
    }

    /// Get a cached connection if it exists, is not closed, and hasn't expired.
    fn get(&self, key: &PublicKey) -> Option<Connection> {
        let entry = self.cache.get(key)?;
        let elapsed = entry.last_used.elapsed();
        if elapsed > self.ttl {
            drop(entry);
            self.cache.remove(key);
            debug!("Pool: evicted expired connection for {}", key);
            return None;
        }
        let conn = entry.conn.clone();
        // Check if the connection is still alive
        if conn.close_reason().is_some() {
            drop(entry);
            self.cache.remove(key);
            debug!("Pool: evicted closed connection for {}", key);
            return None;
        }
        drop(entry);
        // Update last_used timestamp
        if let Some(mut entry) = self.cache.get_mut(key) {
            entry.last_used = Instant::now();
        }
        Some(conn)
    }

    /// Insert a connection into the pool. Evicts oldest if at capacity.
    fn insert(&self, key: PublicKey, conn: Connection) {
        if self.cache.len() >= self.max_size {
            // Evict the oldest entry
            if let Some(oldest) = self
                .cache
                .iter()
                .min_by_key(|e| e.last_used)
                .map(|e| e.key().clone())
            {
                self.cache.remove(&oldest);
                debug!("Pool: evicted LRU connection for {}", oldest);
            }
        }
        self.cache.insert(
            key,
            CachedConnection {
                conn,
                last_used: Instant::now(),
            },
        );
    }

    /// Remove a connection on error.
    fn evict(&self, key: &PublicKey) {
        self.cache.remove(key);
    }
}

/// Errors that can occur before the proxy starts bidirectional copying.
#[derive(Debug)]
enum ProxyError {
    /// Timed out reading HTTP headers from the client.
    HeaderTimeout,
    /// Could not find a Host header in the request.
    MissingHost,
    /// The Host header's domain suffix doesn't match our configured domain.
    InvalidDomain,
    /// The z32 node ID in the subdomain is malformed.
    InvalidTicket(String),
    /// Iroh connection to the VM timed out.
    ConnectTimeout,
    /// Iroh connection to the VM failed.
    ConnectError(String),
    /// Failed to open a bidirectional stream on the QUIC connection.
    StreamError(String),
    /// VM did not send any response bytes within the timeout.
    ResponseTimeout,
}

impl std::fmt::Display for ProxyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProxyError::HeaderTimeout => write!(f, "Request timeout"),
            ProxyError::MissingHost => write!(f, "Missing Host header"),
            ProxyError::InvalidDomain => write!(f, "Invalid domain"),
            ProxyError::InvalidTicket(e) => write!(f, "Invalid VM ticket: {}", e),
            ProxyError::ConnectTimeout => write!(f, "VM connection timed out"),
            ProxyError::ConnectError(e) => write!(f, "Could not reach VM: {}", e),
            ProxyError::StreamError(e) => write!(f, "VM connection failed: {}", e),
            ProxyError::ResponseTimeout => write!(f, "VM did not respond in time"),
        }
    }
}

impl ProxyError {
    fn status_code(&self) -> u16 {
        match self {
            ProxyError::HeaderTimeout => 408,
            ProxyError::MissingHost => 400,
            ProxyError::InvalidDomain => 400,
            ProxyError::InvalidTicket(_) => 400,
            ProxyError::ConnectTimeout => 504,
            ProxyError::ConnectError(_) => 502,
            ProxyError::StreamError(_) => 502,
            ProxyError::ResponseTimeout => 504,
        }
    }
}

fn error_to_http_response(err: &ProxyError) -> Vec<u8> {
    let status = err.status_code();
    let body = err.to_string();
    let reason = match status {
        400 => "Bad Request",
        408 => "Request Timeout",
        502 => "Bad Gateway",
        504 => "Gateway Timeout",
        _ => "Error",
    };
    format!(
        "HTTP/1.1 {} {}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        status, reason, body.len(), body
    )
    .into_bytes()
}

/// Parsed subdomain info: the z32 node ID string and optional target port.
struct SubdomainInfo {
    node_id_z32: String,
    port: Option<u16>,
}

/// Parse the subdomain from a Host header value.
///
/// Expected formats:
///   <z32-node-id>.<domain>
///   <z32-node-id>-<port>.<domain>
///
/// The z32 alphabet (ybndrfg8ejkmcpqxot1uwisza345h769) doesn't contain `-`,
/// so splitting on the last `-` to extract a port suffix is unambiguous.
fn parse_subdomain(host: &str, domain_suffix: &str) -> Result<SubdomainInfo, ProxyError> {
    // Strip any :port from the Host value (that's the gateway listen port)
    let host_no_port = host.split(':').next().unwrap_or(host);

    // Host is already lowercased by browsers/Cloudflare, but normalize anyway
    let host_lower = host_no_port.to_ascii_lowercase();
    let suffix = format!(".{}", domain_suffix.to_ascii_lowercase());

    if !host_lower.ends_with(&suffix) {
        return Err(ProxyError::InvalidDomain);
    }

    // Extract the subdomain part (everything before the domain suffix)
    let subdomain = &host_lower[..host_lower.len() - suffix.len()];
    if subdomain.is_empty() {
        return Err(ProxyError::InvalidTicket("empty subdomain".into()));
    }

    // Try to split off a port suffix: <z32>-<port>
    // The z32 alphabet doesn't contain `-`, so this is unambiguous.
    if let Some(dash_pos) = subdomain.rfind('-') {
        let maybe_port = &subdomain[dash_pos + 1..];
        if let Ok(port) = maybe_port.parse::<u16>() {
            let node_id = &subdomain[..dash_pos];
            if node_id.is_empty() {
                return Err(ProxyError::InvalidTicket("empty node ID".into()));
            }
            return Ok(SubdomainInfo {
                node_id_z32: node_id.to_string(),
                port: Some(port),
            });
        }
    }

    // No port suffix — whole subdomain is the node ID
    Ok(SubdomainInfo {
        node_id_z32: subdomain.to_string(),
        port: None,
    })
}

/// Parse z32 node ID into an EndpointAddr.
///
/// Decodes the z-base-32 string to 32 raw bytes, then constructs a PublicKey.
fn resolve_ticket(z32_str: &str) -> Result<EndpointAddr, ProxyError> {
    let bytes = z32::decode(z32_str.as_bytes())
        .map_err(|e| ProxyError::InvalidTicket(format!("z32 decode: {}", e)))?;
    let key_bytes: [u8; 32] = bytes
        .try_into()
        .map_err(|v: Vec<u8>| ProxyError::InvalidTicket(format!("expected 32 bytes, got {}", v.len())))?;
    let pubkey = PublicKey::from_bytes(&key_bytes)
        .map_err(|e| ProxyError::InvalidTicket(format!("{}", e)))?;
    Ok(EndpointAddr::new(pubkey))
}

/// Read from the TCP stream until we find the end of HTTP headers (\r\n\r\n).
/// Returns the buffer containing all bytes read (headers + possibly start of body).
/// Times out after `timeout` duration.
async fn read_until_headers(
    stream: &mut TcpStream,
    timeout: Duration,
) -> Result<Vec<u8>, ProxyError> {
    const MAX_HEADER_SIZE: usize = 8192;
    let mut buf = Vec::with_capacity(4096);
    let mut tmp = [0u8; 4096];

    let result = tokio::time::timeout(timeout, async {
        loop {
            let n = stream
                .read(&mut tmp)
                .await
                .map_err(|_| ProxyError::MissingHost)?;
            if n == 0 {
                return Err(ProxyError::MissingHost);
            }
            buf.extend_from_slice(&tmp[..n]);
            if buf.len() > MAX_HEADER_SIZE {
                return Err(ProxyError::MissingHost);
            }
            // Check for end of headers
            if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                return Ok(());
            }
        }
    })
    .await;

    match result {
        Ok(Ok(())) => Ok(buf),
        Ok(Err(e)) => Err(e),
        Err(_) => Err(ProxyError::HeaderTimeout),
    }
}

/// Extract the Host header value from raw HTTP header bytes.
/// Case-insensitive search for "host:" header line.
fn extract_host(header_bytes: &[u8]) -> Option<String> {
    let header_str = std::str::from_utf8(header_bytes).ok()?;

    for line in header_str.split("\r\n") {
        // Case-insensitive match for "host:"
        if line.len() > 5 && line[..5].eq_ignore_ascii_case("host:") {
            return Some(line[5..].trim().to_string());
        }
    }
    None
}

/// Set up the proxy: read headers, parse subdomain, connect to VM via Iroh.
/// Returns the header buffer (to be forwarded) and the QUIC send/recv streams.
async fn setup_proxy(
    stream: &mut TcpStream,
    ep: &Endpoint,
    pool: &ConnectionPool,
    cfg: &Config,
) -> Result<
    (
        Vec<u8>,
        iroh::endpoint::SendStream,
        iroh::endpoint::RecvStream,
    ),
    ProxyError,
> {
    // Read HTTP headers (5s timeout for header reading)
    let header_buf = read_until_headers(stream, Duration::from_secs(5)).await?;

    // Extract Host header
    let host = extract_host(&header_buf).ok_or(ProxyError::MissingHost)?;

    // Parse subdomain to get node ID and port
    let info = parse_subdomain(&host, &cfg.domain)?;
    let port = info.port.unwrap_or(cfg.default_port);

    // Resolve z32 node ID to EndpointAddr
    let addr = resolve_ticket(&info.node_id_z32)?;
    let pubkey = addr.id;

    // Try cached connection first, fall back to new connect
    let conn = if let Some(cached) = pool.get(&pubkey) {
        debug!("Pool hit for {}", info.node_id_z32);
        cached
    } else {
        debug!("Pool miss for {}, connecting...", info.node_id_z32);
        let new_conn = tokio::time::timeout(
            Duration::from_secs(cfg.connect_timeout),
            ep.connect(addr, TCP_FWD_ALPN),
        )
        .await
        .map_err(|_| ProxyError::ConnectTimeout)?
        .map_err(|e| ProxyError::ConnectError(e.to_string()))?;
        pool.insert(pubkey, new_conn.clone());
        new_conn
    };

    // Open bidirectional stream
    let (mut send, recv) = match conn.open_bi().await {
        Ok(streams) => streams,
        Err(e) => {
            // Connection might be stale — evict and retry once
            pool.evict(&pubkey);
            debug!("Stale connection for {}, reconnecting: {}", info.node_id_z32, e);
            let addr = resolve_ticket(&info.node_id_z32)?;
            let new_conn = tokio::time::timeout(
                Duration::from_secs(cfg.connect_timeout),
                ep.connect(addr, TCP_FWD_ALPN),
            )
            .await
            .map_err(|_| ProxyError::ConnectTimeout)?
            .map_err(|e| ProxyError::ConnectError(e.to_string()))?;
            pool.insert(pubkey, new_conn.clone());
            new_conn
                .open_bi()
                .await
                .map_err(|e| ProxyError::StreamError(e.to_string()))?
        }
    };

    // Send target port as 2-byte big-endian u16 (TCP_FWD protocol)
    send.write_all(&port.to_be_bytes())
        .await
        .map_err(|e| ProxyError::StreamError(e.to_string()))?;

    Ok((header_buf, send, recv))
}

/// Run the bidirectional proxy: forward buffered headers, wait for first response
/// byte (with timeout), then copy in both directions.
///
/// Returns `Err(ProxyError)` only if the error occurs before any data is sent to
/// the client, so the caller can still send an HTTP error response.
async fn run_proxy(
    stream: TcpStream,
    header_buf: Vec<u8>,
    mut quic_send: iroh::endpoint::SendStream,
    mut quic_recv: iroh::endpoint::RecvStream,
    response_timeout: Duration,
) -> Result<(), (ProxyError, TcpStream)> {
    let (mut tcp_read, mut tcp_write) = stream.into_split();

    // Forward the already-read HTTP headers to the VM
    if let Err(e) = quic_send.write_all(&header_buf).await {
        warn!("Failed to forward headers to VM: {}", e);
        return Ok(());
    }

    // Wait for the first byte from the VM with a timeout.
    // This catches the case where nothing is listening on the target port.
    if !response_timeout.is_zero() {
        let mut first_byte = [0u8; 1];
        let err = match tokio::time::timeout(response_timeout, quic_recv.read(&mut first_byte)).await {
            Ok(Ok(Some(1))) => {
                // Got the first byte — forward it and continue with full copy
                if let Err(e) = tcp_write.write_all(&first_byte).await {
                    warn!("Failed to write first byte to client: {}", e);
                    return Ok(());
                }
                None
            }
            Ok(Ok(Some(_) | None)) => Some(ProxyError::ResponseTimeout),
            Ok(Err(e)) => Some(ProxyError::StreamError(e.to_string())),
            Err(_) => Some(ProxyError::ResponseTimeout),
        };
        if let Some(e) = err {
            // Reunite the split halves so caller can write an error response
            let stream = tcp_read.reunite(tcp_write).expect("reunite failed");
            return Err((e, stream));
        }
    }

    // Bidirectional copy: client <-> VM
    let client_to_vm = async {
        let r = tokio::io::copy(&mut tcp_read, &mut quic_send).await;
        let _ = quic_send.finish();
        r
    };
    let vm_to_client = async {
        tokio::io::copy(&mut quic_recv, &mut tcp_write).await
    };

    let (c2v, v2c) = tokio::join!(client_to_vm, vm_to_client);
    if let Err(e) = c2v {
        // Connection reset by client is normal (browser closed tab)
        if e.kind() != std::io::ErrorKind::ConnectionReset {
            warn!("client->vm error: {}", e);
        }
    }
    if let Err(e) = v2c {
        if e.kind() != std::io::ErrorKind::ConnectionReset {
            warn!("vm->client error: {}", e);
        }
    }

    Ok(())
}

/// Handle a single incoming TCP connection.
async fn handle_connection(mut stream: TcpStream, peer: SocketAddr, ep: &Endpoint, pool: &ConnectionPool, cfg: &Config) {
    let response_timeout = Duration::from_secs(cfg.response_timeout);

    match setup_proxy(&mut stream, ep, pool, cfg).await {
        Ok((header_buf, quic_send, quic_recv)) => {
            info!("{}: proxying", peer);
            if let Err((e, mut stream)) = run_proxy(stream, header_buf, quic_send, quic_recv, response_timeout).await {
                warn!("{}: {}", peer, e);
                let _ = stream.write_all(&error_to_http_response(&e)).await;
            }
        }
        Err(e) => {
            warn!("{}: {}", peer, e);
            let _ = stream.write_all(&error_to_http_response(&e)).await;
        }
    }
}

async fn shutdown_signal() {
    let ctrl_c = tokio::signal::ctrl_c();
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to register SIGTERM handler");
        tokio::select! {
            _ = ctrl_c => {}
            _ = term.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        ctrl_c.await.ok();
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    let cfg = Config::parse();

    info!("Starting Iroh endpoint...");
    let endpoint = Endpoint::builder().bind().await?;
    endpoint.online().await;
    info!("Iroh endpoint ready");

    let pool = Arc::new(ConnectionPool::new(
        Duration::from_secs(cfg.pool_ttl),
        cfg.pool_max,
    ));

    let ep = Arc::new(endpoint);
    let cfg = Arc::new(cfg);

    let listener = TcpListener::bind(cfg.listen).await?;
    info!("Listening on {} (pool: max={}, ttl={}s)", cfg.listen, cfg.pool_max, cfg.pool_ttl);

    loop {
        tokio::select! {
            accept = listener.accept() => {
                let (stream, peer) = accept?;
                let ep = Arc::clone(&ep);
                let pool = Arc::clone(&pool);
                let cfg = Arc::clone(&cfg);
                tokio::spawn(async move {
                    handle_connection(stream, peer, &ep, &pool, &cfg).await;
                });
            }
            _ = shutdown_signal() => {
                info!("Shutting down");
                break;
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_subdomain_basic() {
        let info = parse_subdomain(
            "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u.vm.worldtree.network",
            "vm.worldtree.network",
        )
        .unwrap();
        assert_eq!(
            info.node_id_z32,
            "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
        );
        assert_eq!(info.port, None);
    }

    #[test]
    fn test_parse_subdomain_with_port() {
        let info = parse_subdomain(
            "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u-3000.vm.worldtree.network",
            "vm.worldtree.network",
        )
        .unwrap();
        assert_eq!(
            info.node_id_z32,
            "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
        );
        assert_eq!(info.port, Some(3000));
    }

    #[test]
    fn test_parse_subdomain_with_gateway_port() {
        let info = parse_subdomain(
            "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u.vm.worldtree.network:8080",
            "vm.worldtree.network",
        )
        .unwrap();
        assert_eq!(
            info.node_id_z32,
            "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
        );
        assert_eq!(info.port, None);
    }

    #[test]
    fn test_parse_subdomain_wrong_domain() {
        let result = parse_subdomain("something.other.domain", "vm.worldtree.network");
        assert!(matches!(result, Err(ProxyError::InvalidDomain)));
    }

    #[test]
    fn test_parse_subdomain_empty() {
        let result = parse_subdomain("vm.worldtree.network", "vm.worldtree.network");
        assert!(matches!(result, Err(ProxyError::InvalidDomain)));
    }

    #[test]
    fn test_parse_subdomain_case_insensitive() {
        let info = parse_subdomain(
            "YBNDRFG8EJKMCPQXOT1UWISZA345H769YBNDRFG8EJKMCPQXOT1U.VM.WORLDTREE.NETWORK",
            "vm.worldtree.network",
        )
        .unwrap();
        assert_eq!(
            info.node_id_z32,
            "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u"
        );
        assert_eq!(info.port, None);
    }

    #[test]
    fn test_parse_subdomain_port_5173() {
        let info = parse_subdomain(
            "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u-5173.vm.worldtree.network",
            "vm.worldtree.network",
        )
        .unwrap();
        assert_eq!(info.port, Some(5173));
    }

    #[test]
    fn test_extract_host_basic() {
        let headers = b"GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n";
        assert_eq!(extract_host(headers), Some("example.com".to_string()));
    }

    #[test]
    fn test_extract_host_case_insensitive() {
        let headers = b"GET / HTTP/1.1\r\nhOsT: example.com\r\n\r\n";
        assert_eq!(extract_host(headers), Some("example.com".to_string()));
    }

    #[test]
    fn test_extract_host_with_port() {
        let headers = b"GET / HTTP/1.1\r\nHost: example.com:8080\r\n\r\n";
        assert_eq!(extract_host(headers), Some("example.com:8080".to_string()));
    }

    #[test]
    fn test_extract_host_missing() {
        let headers = b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n";
        assert_eq!(extract_host(headers), None);
    }

    #[test]
    fn test_z32_roundtrip() {
        // Generate a valid key, encode as z32, parse it back, verify roundtrip.
        let secret = iroh_base::SecretKey::generate(&mut rand::rng());
        let key = secret.public();
        let z32_str = z32::encode(key.as_bytes());
        assert_eq!(z32_str.len(), 52, "z32 should be 52 chars for 32 bytes");
        // Verify resolve_ticket parses it back correctly
        let addr = resolve_ticket(&z32_str).unwrap();
        assert_eq!(addr.id, key);
    }

    #[test]
    fn test_z32_known_vectors() {
        // Cross-validate with Elixir z32_from_hex implementation
        let zeros = [0u8; 32];
        assert_eq!(
            z32::encode(&zeros),
            "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"
        );

        let ones = [0xffu8; 32];
        assert_eq!(
            z32::encode(&ones),
            "999999999999999999999999999999999999999999999999999o"
        );

        let deadbeef: Vec<u8> = (0..32).map(|i| [0xde, 0xad, 0xbe, 0xef][i % 4]).collect();
        assert_eq!(
            z32::encode(&deadbeef),
            "54s57566is9q9zipz5z77mp679xk5xzx54s57566is9q9zipz5zo"
        );
    }

    #[test]
    fn test_error_responses() {
        let resp = error_to_http_response(&ProxyError::MissingHost);
        let resp_str = String::from_utf8(resp).unwrap();
        assert!(resp_str.starts_with("HTTP/1.1 400 Bad Request"));
        assert!(resp_str.contains("Missing Host header"));

        let resp = error_to_http_response(&ProxyError::ConnectTimeout);
        let resp_str = String::from_utf8(resp).unwrap();
        assert!(resp_str.starts_with("HTTP/1.1 504 Gateway Timeout"));

        let resp = error_to_http_response(&ProxyError::HeaderTimeout);
        let resp_str = String::from_utf8(resp).unwrap();
        assert!(resp_str.starts_with("HTTP/1.1 408 Request Timeout"));

        let resp = error_to_http_response(&ProxyError::ResponseTimeout);
        let resp_str = String::from_utf8(resp).unwrap();
        assert!(resp_str.starts_with("HTTP/1.1 504 Gateway Timeout"));
        assert!(resp_str.contains("VM did not respond in time"));
    }
}

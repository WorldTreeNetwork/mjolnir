//! Mjolnir Web Gateway — bridges HTTP to Iroh TCP forwarding.
//!
//! Accepts plain HTTP from Cloudflare (which terminates TLS), extracts the
//! target VM from the subdomain (z32-encoded node ID), connects via Iroh's
//! TCP forwarding protocol, and does blind bidirectional byte copying.
//!
//! URL format: https://<z32-node-id>[-<port>].vm.worldtree.network
//!
//! Supports HTTP/1.1, WebSocket upgrades, SSE, and any TCP-based protocol.

use arc_swap::ArcSwap;
use clap::Parser;
use dashmap::DashMap;
use iroh::endpoint::{Connection, Endpoint};
use iroh_base::{EndpointAddr, PublicKey};
use mjolnir_gateway::acme::{AcmeConfig, IssuedCert};
use mjolnir_gateway::cloudflare::CloudflareClient;
use mjolnir_gateway::tls::{load_server_config, load_server_config_from_bytes, TlsError};
use mjolnir_protocol::TCP_FWD_ALPN;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use tracing::{debug, error, info, warn};

#[derive(Parser, Clone)]
#[command(name = "mjolnir-gateway", about = "Mjolnir Web Gateway — HTTP to Iroh bridge")]
struct Config {
    /// Listen address for plaintext HTTP. Empty string disables the plaintext listener.
    #[arg(long, default_value = "0.0.0.0:8080", env = "GATEWAY_LISTEN")]
    listen: String,

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

    /// Pool staleness probe timeout in seconds (0 = disable probe).
    /// When reusing a pooled QUIC connection, the gateway requires the VM
    /// to emit the first response byte within this window. If not, the
    /// connection is assumed silently dead (e.g. NAT rebind, guest crash
    /// without RST), evicted from the pool, and the request retried once
    /// with a freshly-dialled connection. The probe applies ONLY to
    /// pool-hit requests; fresh connections respect `response_timeout`
    /// only. Set to 0 to disable (restores old "trust the pool" behavior).
    #[arg(long, default_value = "10", env = "GATEWAY_POOL_PROBE_TIMEOUT")]
    pool_probe_timeout: u64,

    /// TLS listen address. Empty string disables the TLS listener.
    #[arg(long, default_value = "0.0.0.0:443", env = "GATEWAY_TLS_LISTEN")]
    tls_listen: String,

    /// PEM-encoded cert chain (fullchain). Required if tls_listen is non-empty.
    #[arg(long, default_value = "/etc/mjolnir/fullchain.pem", env = "GATEWAY_TLS_CERT")]
    tls_cert: PathBuf,

    /// PEM-encoded private key. Required if tls_listen is non-empty.
    #[arg(long, default_value = "/etc/mjolnir/privkey.pem", env = "GATEWAY_TLS_KEY")]
    tls_key: PathBuf,

    /// Refuse TLS handshakes if cert expires within this many seconds.
    /// Default 86400 (24h) — set to 0 to disable.
    #[arg(long, default_value = "86400", env = "GATEWAY_TLS_EXPIRY_FAIL_SECS")]
    tls_expiry_fail_secs: u64,

    /// TLS session resumption cache size.
    #[arg(long, default_value = "4096", env = "GATEWAY_TLS_SESSION_CACHE")]
    tls_session_cache: usize,

    /// ACME auto-TLS mode. "enabled" = issue/renew certs via ACME; anything else = static-cert mode.
    #[arg(long, default_value = "disabled", env = "GATEWAY_ACME")]
    acme: String,

    /// ACME directory URL.
    #[arg(long, default_value = "https://acme-v02.api.letsencrypt.org/directory", env = "GATEWAY_ACME_DIRECTORY")]
    acme_directory: String,

    /// Contact email for the ACME account.
    #[arg(long, default_value = "", env = "GATEWAY_ACME_EMAIL")]
    acme_email: String,

    /// Comma-separated domains to include in the cert. Wildcards OK.
    #[arg(long, default_value = "", env = "GATEWAY_ACME_DOMAINS", value_delimiter = ',')]
    acme_domains: Vec<String>,

    /// Re-issue the cert this many seconds before expiry. Default 30 days.
    #[arg(long, default_value = "2592000", env = "GATEWAY_ACME_RENEW_BEFORE_SECS")]
    acme_renew_before_secs: u64,

    /// Cloudflare API token (Zone:DNS:Edit scope). Required if acme=enabled.
    #[arg(long, default_value = "", env = "CLOUDFLARE_API_TOKEN", hide_env_values = true, hide = true)]
    cloudflare_api_token: String,
}

// ── Validation ────────────────────────────────────────────────────────────────

/// Fail-fast check when ACME mode is enabled: all required fields must be set.
fn validate_acme_config(cfg: &Config) -> Result<(), Box<dyn std::error::Error>> {
    let mut missing = Vec::new();
    if cfg.cloudflare_api_token.is_empty() {
        missing.push("CLOUDFLARE_API_TOKEN (--cloudflare-api-token)");
    }
    if cfg.acme_email.is_empty() {
        missing.push("GATEWAY_ACME_EMAIL (--acme-email)");
    }
    if cfg.acme_domains.is_empty() || cfg.acme_domains.iter().all(|d| d.is_empty()) {
        missing.push("GATEWAY_ACME_DOMAINS (--acme-domains)");
    }
    if !missing.is_empty() {
        return Err(format!(
            "acme=enabled requires the following to be set: {}",
            missing.join(", ")
        )
        .into());
    }
    Ok(())
}

// ── TlsState ─────────────────────────────────────────────────────────────────

/// Hot-reloadable TLS server configuration. The inner `ServerConfig` is stored
/// in an `ArcSwap` so the SIGHUP handler can atomically swap in a fresh cert
/// without pausing in-flight connections.
struct TlsState {
    config: ArcSwap<rustls::ServerConfig>,
    cert_path: PathBuf,
    key_path: PathBuf,
    session_cache: usize,
    fail_within: Duration,
    /// The expiry time of the currently-loaded certificate.
    not_after: std::sync::RwLock<SystemTime>,
}

impl TlsState {
    /// Load TLS config from disk and wrap in a shared `Arc<TlsState>`.
    /// Returns `Err` if the cert or key cannot be read/parsed — callers
    /// should treat this as a fatal startup error (MH3 fail-safe).
    fn load(
        cert_path: PathBuf,
        key_path: PathBuf,
        session_cache: usize,
        fail_within: Duration,
    ) -> Result<Arc<Self>, TlsError> {
        let (server_config, resolver) =
            load_server_config(&cert_path, &key_path, session_cache, fail_within)?;
        let not_after = resolver.current_not_after();
        Ok(Arc::new(Self {
            config: ArcSwap::from(server_config),
            cert_path,
            key_path,
            session_cache,
            fail_within,
            not_after: std::sync::RwLock::new(not_after),
        }))
    }

    /// Build a `TlsState` from in-memory PEM bytes (ACME path).
    fn from_pem_bytes(
        chain_pem: &[u8],
        key_pem: &[u8],
        session_cache: usize,
        fail_within: Duration,
        not_after: SystemTime,
    ) -> Result<Arc<Self>, TlsError> {
        let (server_config, _resolver) =
            load_server_config_from_bytes(chain_pem, key_pem, session_cache, fail_within)?;
        Ok(Arc::new(Self {
            config: ArcSwap::from(server_config),
            // Sentinel paths — not used in ACME mode (reload goes through swap_from_pem).
            cert_path: PathBuf::new(),
            key_path: PathBuf::new(),
            session_cache,
            fail_within,
            not_after: std::sync::RwLock::new(not_after),
        }))
    }

    /// Reload the certificate from disk and atomically swap it in.
    /// On failure the **current** certificate remains active (fail-safe).
    fn reload(&self) -> Result<(), TlsError> {
        match load_server_config(&self.cert_path, &self.key_path, self.session_cache, self.fail_within) {
            Ok((new_config, resolver)) => {
                let new_not_after = resolver.current_not_after();
                self.config.store(new_config);
                if let Ok(mut guard) = self.not_after.write() {
                    *guard = new_not_after;
                }
                info!(event = "cert.reloaded", "TLS certificate hot-reloaded");
                Ok(())
            }
            Err(e) => {
                warn!(event = "cert.reload_failed", error = %e, "TLS reload failed — keeping previous certificate");
                Err(e)
            }
        }
    }

    /// Swap in a new certificate from in-memory PEM bytes (ACME renewal path).
    /// Atomically replaces the `ServerConfig`. On failure the current config
    /// remains active.
    fn swap_from_pem(
        &self,
        chain_pem: &[u8],
        key_pem: &[u8],
        new_not_after: SystemTime,
    ) -> Result<(), TlsError> {
        let (new_config, _resolver) =
            load_server_config_from_bytes(chain_pem, key_pem, self.session_cache, self.fail_within)?;
        self.config.store(new_config);
        if let Ok(mut guard) = self.not_after.write() {
            *guard = new_not_after;
        }
        Ok(())
    }

    /// Return the expiry time of the currently-loaded certificate.
    fn current_not_after(&self) -> SystemTime {
        self.not_after.read().map(|g| *g).unwrap_or(SystemTime::UNIX_EPOCH)
    }

    /// Build a `TlsAcceptor` from the currently-active `ServerConfig`.
    fn acceptor(&self) -> tokio_rustls::TlsAcceptor {
        tokio_rustls::TlsAcceptor::from(self.config.load_full())
    }
}

// ── ACME renewal ──────────────────────────────────────────────────────────────

/// Returns `true` when the cert will expire within `renew_before` from now.
fn should_renew(state: &TlsState, renew_before: &Duration) -> bool {
    let not_after = state.current_not_after();
    match not_after.duration_since(SystemTime::now()) {
        Ok(remaining) => remaining < *renew_before,
        Err(_) => true, // already expired
    }
}

/// Background task: checks every 12 hours and renews the cert when needed.
async fn renewal_loop(state: Arc<TlsState>, acme_cfg: AcmeConfig, cf: CloudflareClient) {
    let mut tick = tokio::time::interval(Duration::from_secs(12 * 3600));
    tick.tick().await; // consume the immediate tick
    loop {
        tick.tick().await;
        if should_renew(&state, &acme_cfg.renew_before) {
            match mjolnir_gateway::acme::issue(&acme_cfg, &cf).await {
                Ok(new_cert) => {
                    if let Err(e) = state.swap_from_pem(
                        new_cert.chain_pem.as_bytes(),
                        new_cert.key_pem.as_bytes(),
                        new_cert.not_after,
                    ) {
                        error!("acme.swap_failed: {}", e);
                    } else {
                        info!("acme.renewed: new fingerprint {}", new_cert.fingerprint_sha256);
                    }
                }
                Err(e) => {
                    error!("acme.renewal_failed: {}", e);
                }
            }
        }
    }
}

// ── ConnectionPool ────────────────────────────────────────────────────────────

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
                .map(|e| *e.key())
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

// ── ProxyError ────────────────────────────────────────────────────────────────

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
    /// A pooled connection appeared alive but never delivered the first
    /// response byte within the probe window. Indicates silent death
    /// (NAT rebind, peer restart without QUIC close). Triggers a
    /// retry-with-fresh-connection in `handle_connection`.
    PoolStale,
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
            ProxyError::PoolStale => write!(f, "Pooled VM connection was silently dead; retrying with fresh"),
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
            ProxyError::PoolStale => 504,
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

// ── Subdomain parsing ─────────────────────────────────────────────────────────

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

// ── Proxy logic ───────────────────────────────────────────────────────────────

/// Read from the stream until we find the end of HTTP headers (\r\n\r\n).
/// Returns the buffer containing all bytes read (headers + possibly start of body).
/// Times out after `timeout` duration.
async fn read_until_headers<S>(
    stream: &mut S,
    timeout: Duration,
) -> Result<Vec<u8>, ProxyError>
where
    S: AsyncRead + Unpin,
{
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
///
/// Returns `(header_buf, send, recv, pool_hit, pubkey)`:
/// - `header_buf`: already-read HTTP request to forward
/// - `send`/`recv`: QUIC bidi streams
/// - `pool_hit`: true iff the underlying QUIC connection was taken from
///   the pool (vs freshly dialled). Used by `run_proxy` to decide
///   whether to enforce `pool_probe_timeout` on first-byte read.
/// - `pubkey`: the VM's Iroh PublicKey, so the caller can evict it from
///   the pool on a detected silent-death (see `handle_connection`'s
///   `PoolStale` retry branch).
///
/// When `force_fresh` is true, the cached connection is skipped entirely
/// and evicted up front. Used by `handle_connection` to retry after a
/// `PoolStale` detection.
async fn setup_proxy<S>(
    stream: &mut S,
    ep: &Endpoint,
    pool: &ConnectionPool,
    cfg: &Config,
    force_fresh: bool,
    // When force_fresh, caller has already buffered the request body so
    // we don't re-read from the client. None on first attempt.
    pre_read_headers: Option<Vec<u8>>,
) -> Result<
    (
        Vec<u8>,
        iroh::endpoint::SendStream,
        iroh::endpoint::RecvStream,
        bool,
        PublicKey,
    ),
    ProxyError,
>
where
    S: AsyncRead + AsyncWrite + Unpin + Send,
{
    // Read HTTP headers (5s timeout for header reading) — or reuse buffered
    let header_buf = match pre_read_headers {
        Some(buf) => buf,
        None => read_until_headers(stream, Duration::from_secs(5)).await?,
    };

    // Extract Host header
    let host = extract_host(&header_buf).ok_or(ProxyError::MissingHost)?;

    // Parse subdomain to get node ID and port
    let info = parse_subdomain(&host, &cfg.domain)?;
    let port = info.port.unwrap_or(cfg.default_port);

    // Resolve z32 node ID to EndpointAddr
    let addr = resolve_ticket(&info.node_id_z32)?;
    let pubkey = addr.id;

    // When force_fresh, pre-emptively evict any cached connection so we
    // dial a brand new one below.
    if force_fresh {
        pool.evict(&pubkey);
    }

    // Try cached connection first, fall back to new connect
    let (conn, pool_hit) = if !force_fresh {
        if let Some(cached) = pool.get(&pubkey) {
            debug!("Pool hit for {}", info.node_id_z32);
            (cached, true)
        } else {
            debug!("Pool miss for {}, connecting...", info.node_id_z32);
            let new_conn = tokio::time::timeout(
                Duration::from_secs(cfg.connect_timeout),
                ep.connect(addr.clone(), TCP_FWD_ALPN),
            )
            .await
            .map_err(|_| ProxyError::ConnectTimeout)?
            .map_err(|e| ProxyError::ConnectError(e.to_string()))?;
            pool.insert(pubkey, new_conn.clone());
            (new_conn, false)
        }
    } else {
        debug!("Forced fresh connect for {}", info.node_id_z32);
        let new_conn = tokio::time::timeout(
            Duration::from_secs(cfg.connect_timeout),
            ep.connect(addr.clone(), TCP_FWD_ALPN),
        )
        .await
        .map_err(|_| ProxyError::ConnectTimeout)?
        .map_err(|e| ProxyError::ConnectError(e.to_string()))?;
        pool.insert(pubkey, new_conn.clone());
        (new_conn, false)
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

    Ok((header_buf, send, recv, pool_hit, pubkey))
}

/// Write an HTTP error response through `w` and shut down the write half.
/// Errors are silently ignored — the connection is being torn down anyway.
async fn write_error_and_shutdown<W>(w: &mut W, err: &ProxyError)
where
    W: AsyncWrite + Unpin,
{
    let _ = w.write_all(&error_to_http_response(err)).await;
    let _ = w.shutdown().await;
}

/// Forward the buffered request headers to the VM and, optionally,
/// block until the VM emits its first response byte. Returned as
/// `Ok(Some(byte))` so the caller can prepend it to the client stream
/// before handing the rest off to `run_proxy`. When `probe_timeout` is
/// zero, this helper skips the probe entirely and returns `Ok(None)`.
///
/// Errors are returned to the caller without any client-facing I/O so
/// `handle_connection` can either retry with a fresh QUIC connection
/// (on `ResponseTimeout` from a pool-hit — treated as silent death) or
/// synthesize a 502/504 error page after surfacing the actual problem.
async fn forward_headers_and_probe(
    header_buf: &[u8],
    quic_send: &mut iroh::endpoint::SendStream,
    quic_recv: &mut iroh::endpoint::RecvStream,
    probe_timeout: Duration,
    is_pool_hit: bool,
) -> Result<Option<u8>, ProxyError> {
    quic_send
        .write_all(header_buf)
        .await
        .map_err(|e| ProxyError::StreamError(e.to_string()))?;

    if probe_timeout.is_zero() {
        return Ok(None);
    }

    // On pool hits, a probe timeout almost certainly means a silently-dead
    // connection (NAT rebind, peer restart) — signal that with the
    // dedicated `PoolStale` variant so `handle_connection` knows to retry
    // with a fresh dial. On fresh connections the same symptom means the
    // upstream actually isn't responding — that is `ResponseTimeout`.
    let timeout_err = || {
        if is_pool_hit {
            ProxyError::PoolStale
        } else {
            ProxyError::ResponseTimeout
        }
    };

    let mut fb = [0u8; 1];
    match tokio::time::timeout(probe_timeout, quic_recv.read(&mut fb)).await {
        Ok(Ok(Some(1))) => Ok(Some(fb[0])),
        Ok(Ok(Some(_) | None)) => Err(timeout_err()),
        Ok(Err(e)) => Err(ProxyError::StreamError(e.to_string())),
        Err(_) => Err(timeout_err()),
    }
}

/// Bidirectional copy between client TCP stream and VM QUIC streams.
/// If `prefix_byte` is `Some`, it is written to the client before the
/// copy begins (used when the pool-probe has already consumed the first
/// response byte).
async fn run_proxy<S>(
    stream: S,
    prefix_byte: Option<u8>,
    mut quic_send: iroh::endpoint::SendStream,
    mut quic_recv: iroh::endpoint::RecvStream,
) where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (mut tcp_read, mut tcp_write) = tokio::io::split(stream);

    if let Some(b) = prefix_byte {
        if let Err(e) = tcp_write.write_all(&[b]).await {
            warn!("Failed to write probed first byte to client: {}", e);
            return;
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
        if e.kind() != std::io::ErrorKind::ConnectionReset {
            warn!("client->vm error: {}", e);
        }
    }
    if let Err(e) = v2c {
        if e.kind() != std::io::ErrorKind::ConnectionReset {
            warn!("vm->client error: {}", e);
        }
    }
}

/// Handle a single incoming connection (plain TCP or TLS).
async fn handle_connection<S>(mut stream: S, peer: SocketAddr, ep: &Endpoint, pool: &ConnectionPool, cfg: &Config)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let response_timeout = Duration::from_secs(cfg.response_timeout);
    let pool_probe_timeout = Duration::from_secs(cfg.pool_probe_timeout);

    // We allow at most one retry: the first attempt may use a pooled connection
    // that has silently died (NAT rebind, peer restarted without QUIC close).
    // If the pool-probe fires, we drop the stale conn and dial a fresh one.
    // `cached_headers` preserves the already-parsed HTTP request (including any
    // body bytes that arrived in the same TCP packet) across the retry so we
    // don't re-read from the client (which has been blocking on response).
    let mut cached_headers: Option<Vec<u8>> = None;

    for attempt in 0u32..2 {
        let force_fresh = attempt > 0;
        match setup_proxy(
            &mut stream,
            ep,
            pool,
            cfg,
            force_fresh,
            cached_headers.take(),
        )
        .await
        {
            Ok((header_buf, mut quic_send, mut quic_recv, pool_hit, pubkey)) => {
                info!(
                    "{}: proxying{}",
                    peer,
                    if pool_hit {
                        " (pooled)"
                    } else if force_fresh {
                        " (fresh retry)"
                    } else {
                        " (fresh)"
                    }
                );

                // Choose probe timeout:
                // - Pool hit + pool_probe_timeout > 0 → aggressive probe
                //   (detects silent-dead pooled connections and retries fresh).
                // - Fresh connection → fall back to response_timeout (may be 0
                //   = unlimited, which is correct for reasoning models).
                let probe = if pool_hit && !pool_probe_timeout.is_zero() {
                    pool_probe_timeout
                } else {
                    response_timeout
                };

                match forward_headers_and_probe(
                    &header_buf,
                    &mut quic_send,
                    &mut quic_recv,
                    probe,
                    pool_hit,
                )
                .await
                {
                    Ok(first_byte) => {
                        run_proxy(stream, first_byte, quic_send, quic_recv).await;
                        return;
                    }
                    Err(e) => {
                        // Silent-dead pool connection: evict + retry once fresh.
                        // `PoolStale` is only ever produced when the probe fired
                        // on a pool-hit, so if we see it on attempt 0 we know a
                        // fresh dial is the right recovery.
                        if matches!(e, ProxyError::PoolStale) && attempt == 0 {
                            warn!(
                                "{}: pool probe timed out after {:?}, evicting and retrying fresh",
                                peer, pool_probe_timeout
                            );
                            pool.evict(&pubkey);
                            let _ = quic_send.finish();
                            // quic_recv drops on scope exit
                            cached_headers = Some(header_buf);
                            continue;
                        }
                        warn!("{}: {}", peer, e);
                        write_error_and_shutdown(&mut stream, &e).await;
                        return;
                    }
                }
            }
            Err(e) => {
                warn!("{}: {}", peer, e);
                let _ = stream.write_all(&error_to_http_response(&e)).await;
                let _ = stream.shutdown().await;
                return;
            }
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

    // Install ring crypto provider before any rustls use.
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("failed to install rustls crypto provider");

    let cfg = Config::parse();

    // ── Startup validation ────────────────────────────────────────────────────

    if cfg.tls_expiry_fail_secs == 0 {
        warn!(
            "GATEWAY_TLS_EXPIRY_FAIL_SECS=0 disables the Scenario-3 expiring-cert mitigation; \
             production should set 86400 or higher"
        );
    }

    // At least one listener must be enabled.
    if cfg.listen.is_empty() && cfg.tls_listen.is_empty() {
        error!("Both GATEWAY_LISTEN and GATEWAY_TLS_LISTEN are empty — no listeners configured, exiting");
        std::process::exit(1);
    }

    let acme_enabled = cfg.acme == "enabled";

    // Fail-fast: validate ACME config before doing anything expensive.
    if acme_enabled {
        validate_acme_config(&cfg)?;
    }

    // ── State dir (used by ACME) ──────────────────────────────────────────────

    let state_dir = {
        let base = std::env::var("STATE_DIRECTORY")
            .unwrap_or_else(|_| "/var/lib/mjolnir-gateway".to_owned());
        let dir = PathBuf::from(base).join("acme");
        std::fs::create_dir_all(&dir)?;
        dir
    };

    // ── Bind listeners ────────────────────────────────────────────────────────

    let plain_listener: Option<TcpListener> = if cfg.listen.is_empty() {
        info!("Plaintext listener disabled (GATEWAY_LISTEN is empty)");
        None
    } else {
        let addr: SocketAddr = cfg.listen.parse()?;
        let l = TcpListener::bind(addr).await?;
        info!("Plaintext listener on {}", addr);
        Some(l)
    };

    let tls_state: Option<Arc<TlsState>> = if cfg.tls_listen.is_empty() {
        info!("TLS listener disabled (GATEWAY_TLS_LISTEN is empty)");
        None
    } else if acme_enabled {
        // ── ACME branch ───────────────────────────────────────────────────────
        let cf_client = CloudflareClient::new(cfg.cloudflare_api_token.clone())?;
        let acme_cfg = AcmeConfig {
            directory_url: cfg.acme_directory.clone(),
            email: cfg.acme_email.clone(),
            domains: cfg.acme_domains.iter().filter(|d| !d.is_empty()).cloned().collect(),
            state_dir: state_dir.clone(),
            renew_before: Duration::from_secs(cfg.acme_renew_before_secs),
        };

        let issued: IssuedCert = mjolnir_gateway::acme::load_or_issue(&acme_cfg, &cf_client).await?;
        info!(
            "ACME cert ready: expires {}, fingerprint {}",
            humantime::format_rfc3339_seconds(issued.not_after),
            issued.fingerprint_sha256
        );

        let fail_within = Duration::from_secs(cfg.tls_expiry_fail_secs);
        let state = TlsState::from_pem_bytes(
            issued.chain_pem.as_bytes(),
            issued.key_pem.as_bytes(),
            cfg.tls_session_cache,
            fail_within,
            issued.not_after,
        )?;

        // Spawn background renewal task.
        tokio::spawn(renewal_loop(Arc::clone(&state), acme_cfg, cf_client));

        Some(state)
    } else {
        // ── Static-cert branch ────────────────────────────────────────────────
        let fail_within = Duration::from_secs(cfg.tls_expiry_fail_secs);
        let state = TlsState::load(
            cfg.tls_cert.clone(),
            cfg.tls_key.clone(),
            cfg.tls_session_cache,
            fail_within,
        )?;
        Some(state)
    };

    let tls_listener: Option<TcpListener> = if cfg.tls_listen.is_empty() {
        None
    } else {
        let addr: SocketAddr = cfg.tls_listen.parse()?;
        let l = TcpListener::bind(addr).await?;
        info!("TLS listener on {}", addr);
        Some(l)
    };

    // ── Iroh endpoint + pool ──────────────────────────────────────────────────

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

    // ── SIGHUP handler ────────────────────────────────────────────────────────

    #[cfg(unix)]
    let mut sighup = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup())
        .expect("failed to register SIGHUP handler");

    // ── Accept loop ───────────────────────────────────────────────────────────

    info!(
        "Gateway ready (pool: max={}, ttl={}s, probe={}s)",
        cfg.pool_max, cfg.pool_ttl, cfg.pool_probe_timeout
    );

    loop {
        // We need to optionally poll the two listeners. Using async blocks that
        // resolve to a tagged enum lets us handle all cases cleanly.
        enum Event {
            Plain(std::io::Result<(tokio::net::TcpStream, SocketAddr)>),
            Tls(std::io::Result<(tokio::net::TcpStream, SocketAddr)>),
            Shutdown,
            #[cfg(unix)]
            Sighup,
        }

        let event = {
            // Build futures for each optional listener.
            let plain_fut = async {
                match &plain_listener {
                    Some(l) => Event::Plain(l.accept().await),
                    None => std::future::pending().await,
                }
            };
            let tls_fut = async {
                match &tls_listener {
                    Some(l) => Event::Tls(l.accept().await),
                    None => std::future::pending().await,
                }
            };

            #[cfg(unix)]
            {
                tokio::select! {
                    e = plain_fut => e,
                    e = tls_fut => e,
                    _ = shutdown_signal() => Event::Shutdown,
                    _ = sighup.recv() => Event::Sighup,
                }
            }
            #[cfg(not(unix))]
            {
                tokio::select! {
                    e = plain_fut => e,
                    e = tls_fut => e,
                    _ = shutdown_signal() => Event::Shutdown,
                }
            }
        };

        match event {
            Event::Plain(Ok((stream, peer))) => {
                let ep = Arc::clone(&ep);
                let pool = Arc::clone(&pool);
                let cfg = Arc::clone(&cfg);
                tokio::spawn(async move {
                    handle_connection(stream, peer, &ep, &pool, &cfg).await;
                });
            }
            Event::Plain(Err(e)) => {
                warn!("Plaintext accept error: {}", e);
            }
            Event::Tls(Ok((tcp_stream, peer))) => {
                let tls = Arc::clone(tls_state.as_ref().expect("tls_state present when tls_listener present"));
                let ep = Arc::clone(&ep);
                let pool = Arc::clone(&pool);
                let cfg = Arc::clone(&cfg);
                tokio::spawn(async move {
                    match tls.acceptor().accept(tcp_stream).await {
                        Ok(tls_stream) => {
                            handle_connection(tls_stream, peer, &ep, &pool, &cfg).await;
                        }
                        Err(e) => {
                            warn!("{}: TLS handshake failed: {}", peer, e);
                        }
                    }
                });
            }
            Event::Tls(Err(e)) => {
                warn!("TLS accept error: {}", e);
            }
            Event::Shutdown => {
                info!("Shutting down");
                break;
            }
            #[cfg(unix)]
            Event::Sighup => {
                if let Some(ref tls) = tls_state {
                    if acme_enabled {
                        info!("SIGHUP received — forcing ACME cert renewal");
                        // Fire-and-forget forced renewal; errors are logged inside.
                        // We can't easily await here without restructuring the loop,
                        // so we spawn a one-shot task.
                        let tls_clone = Arc::clone(tls);
                        let acme_cfg2 = AcmeConfig {
                            directory_url: cfg.acme_directory.clone(),
                            email: cfg.acme_email.clone(),
                            domains: cfg.acme_domains.iter().filter(|d| !d.is_empty()).cloned().collect(),
                            state_dir: state_dir.clone(),
                            renew_before: Duration::from_secs(cfg.acme_renew_before_secs),
                        };
                        let cf2 = match CloudflareClient::new(cfg.cloudflare_api_token.clone()) {
                            Ok(c) => c,
                            Err(e) => {
                                error!("SIGHUP: failed to create CF client: {}", e);
                                continue;
                            }
                        };
                        tokio::spawn(async move {
                            match mjolnir_gateway::acme::issue(&acme_cfg2, &cf2).await {
                                Ok(cert) => {
                                    if let Err(e) = tls_clone.swap_from_pem(
                                        cert.chain_pem.as_bytes(),
                                        cert.key_pem.as_bytes(),
                                        cert.not_after,
                                    ) {
                                        error!("SIGHUP acme.swap_failed: {}", e);
                                    } else {
                                        info!("SIGHUP acme.renewed: fingerprint {}", cert.fingerprint_sha256);
                                    }
                                }
                                Err(e) => error!("SIGHUP acme.issue_failed: {}", e),
                            }
                        });
                    } else {
                        info!("SIGHUP received — reloading TLS certificate");
                        if let Err(e) = tls.reload() {
                            warn!("TLS reload failed: {}", e);
                        }
                    }
                } else {
                    debug!("SIGHUP received but TLS is disabled — ignoring");
                }
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── helpers ───────────────────────────────────────────────────────────────

    fn generate_self_signed_pem(cn: &str) -> (Vec<u8>, Vec<u8>) {
        use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair};

        let mut params = CertificateParams::default();
        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, cn);
        params.distinguished_name = dn;
        params.not_before = rcgen::date_time_ymd(2024, 1, 1);
        params.not_after = rcgen::date_time_ymd(2099, 1, 1);

        let kp = KeyPair::generate().expect("keygen");
        let cert = params.self_signed(&kp).expect("self-sign");
        (cert.pem().into_bytes(), kp.serialize_pem().into_bytes())
    }

    fn install_provider() {
        let _ = rustls::crypto::ring::default_provider().install_default();
    }

    // ── Existing tests (unchanged) ────────────────────────────────────────────

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

    /// 1c.ii — `write_error_and_shutdown` writes the HTTP error response to any
    /// `AsyncWrite + Unpin` — exercised here over a `tokio::io::duplex` pair.
    #[tokio::test]
    async fn write_error_and_shutdown_sends_504_over_duplex() {
        // Create an in-memory full-duplex pair. `server_side` is what the gateway
        // writes to; `client_side` is what the "client" reads from.
        let (client_side, server_side) = tokio::io::duplex(4096);
        let (mut client_read, _client_write) = tokio::io::split(client_side);
        let (_server_read, mut server_write) = tokio::io::split(server_side);

        // Invoke the helper with a ResponseTimeout error.
        write_error_and_shutdown(&mut server_write, &ProxyError::ResponseTimeout).await;

        // Read whatever the client side received.
        let mut received = Vec::new();
        let _ = tokio::io::copy(&mut client_read, &mut received).await;

        let response_str = String::from_utf8(received).expect("valid utf-8");
        assert!(
            response_str.starts_with("HTTP/1.1 504 Gateway Timeout"),
            "expected 504 status line, got: {:?}",
            &response_str[..response_str.len().min(80)]
        );
        assert!(
            response_str.contains("VM did not respond in time"),
            "expected body text in response"
        );
    }

    // ── Task 1d new test ──────────────────────────────────────────────────────

    /// Verify that `TlsState::reload` keeps the previous (working) cert loaded
    /// when the reload fails due to corrupted cert files.
    ///
    /// Steps:
    ///   1. Write a valid self-signed cert + key to temp files.
    ///   2. Construct a `TlsState` — should succeed.
    ///   3. Overwrite the cert file with garbage.
    ///   4. Call `reload()` — must return `Err`.
    ///   5. Call `acceptor()` — must still produce a working `TlsAcceptor`
    ///      (the old config is still in the ArcSwap).
    #[test]
    fn tls_state_reload_keeps_previous_cert_on_failure() {
        install_provider();

        let (cert_pem, key_pem) = generate_self_signed_pem("reload-test");

        let dir = tempfile::tempdir().expect("tempdir");
        let cert_path = dir.path().join("cert.pem");
        let key_path = dir.path().join("key.pem");
        std::fs::write(&cert_path, &cert_pem).unwrap();
        std::fs::write(&key_path, &key_pem).unwrap();

        // Step 2: initial load must succeed.
        let tls_state = TlsState::load(
            cert_path.clone(),
            key_path.clone(),
            128,
            Duration::from_secs(86400),
        )
        .expect("initial TlsState::load must succeed");

        // Capture the pointer to the currently-loaded ServerConfig.
        let config_before = Arc::as_ptr(&tls_state.config.load_full());

        // Step 3: corrupt the cert file.
        std::fs::write(&cert_path, b"this is not a valid PEM cert").unwrap();

        // Step 4: reload must fail.
        let reload_result = tls_state.reload();
        assert!(
            reload_result.is_err(),
            "reload() must return Err when cert file is corrupt"
        );

        // Step 5: the ArcSwap still holds the original config — pointer unchanged.
        let config_after = Arc::as_ptr(&tls_state.config.load_full());
        assert_eq!(
            config_before, config_after,
            "reload failure must not replace the loaded ServerConfig"
        );

        // acceptor() must not panic and must produce a usable TlsAcceptor.
        let _acceptor = tls_state.acceptor();
    }

    // ── Wave 3 new tests ──────────────────────────────────────────────────────

    /// validate_acme_config returns Err naming the missing token when only
    /// email and domains are provided.
    #[test]
    fn config_rejects_acme_enabled_without_token() {
        let cfg = Config::parse_from([
            "prog",
            "--acme=enabled",
            "--acme-email=x@y.com",
            "--acme-domains=a.com",
            // Intentionally omit --cloudflare-api-token
        ]);
        let result = validate_acme_config(&cfg);
        assert!(result.is_err(), "expected Err when token is missing");
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("CLOUDFLARE_API_TOKEN"),
            "error should mention CLOUDFLARE_API_TOKEN, got: {msg}"
        );
    }

    /// --acme-domains=a.com,b.com,*.c.com produces the expected Vec.
    #[test]
    fn config_parses_comma_separated_domains() {
        let cfg = Config::parse_from([
            "prog",
            "--acme-domains=a.com,b.com,*.c.com",
        ]);
        assert_eq!(
            cfg.acme_domains,
            vec!["a.com", "b.com", "*.c.com"],
            "acme_domains should parse comma-separated values"
        );
    }

    /// should_renew returns true when the cert expires within renew_before.
    #[test]
    fn should_renew_returns_true_when_expiring_soon() {
        install_provider();
        let (cert_pem, key_pem) = generate_self_signed_pem("renew-soon");
        let dir = tempfile::tempdir().expect("tempdir");
        let cert_path = dir.path().join("cert.pem");
        let key_path = dir.path().join("key.pem");
        std::fs::write(&cert_path, &cert_pem).unwrap();
        std::fs::write(&key_path, &key_pem).unwrap();

        // Build a TlsState but then manually override not_after to be soon.
        let state = TlsState::load(cert_path, key_path, 128, Duration::from_secs(60))
            .expect("TlsState::load");

        // Set not_after to 1 hour from now — less than renew_before of 30 days.
        let expiring_soon = SystemTime::now() + Duration::from_secs(3600);
        *state.not_after.write().unwrap() = expiring_soon;

        let renew_before = Duration::from_secs(30 * 24 * 3600);
        assert!(
            should_renew(&state, &renew_before),
            "should_renew must return true when cert expires soon"
        );
    }

    /// should_renew returns false when the cert has plenty of time remaining.
    #[test]
    fn should_renew_returns_false_when_fresh() {
        install_provider();
        let (cert_pem, key_pem) = generate_self_signed_pem("renew-fresh");
        let dir = tempfile::tempdir().expect("tempdir");
        let cert_path = dir.path().join("cert.pem");
        let key_path = dir.path().join("key.pem");
        std::fs::write(&cert_path, &cert_pem).unwrap();
        std::fs::write(&key_path, &key_pem).unwrap();

        let state = TlsState::load(cert_path, key_path, 128, Duration::from_secs(60))
            .expect("TlsState::load");

        // Set not_after to 365 days from now — well beyond renew_before of 30 days.
        let fresh = SystemTime::now() + Duration::from_secs(365 * 24 * 3600);
        *state.not_after.write().unwrap() = fresh;

        let renew_before = Duration::from_secs(30 * 24 * 3600);
        assert!(
            !should_renew(&state, &renew_before),
            "should_renew must return false when cert is fresh"
        );
    }
}

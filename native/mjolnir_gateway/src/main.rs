//! Mjolnir Web Gateway — HTTP reverse-proxy fronting Iroh peers and
//! local TCP backends.
//!
//! Two routing dispositions after matching the Host header's apex:
//!
//! 1. **Local route**: `(apex, subdomain)` is pinned in the loaded config;
//!    the gateway TCP-dials the backend and hands off to `run_proxy_local`.
//!    Bytes are forwarded unmodified — no header rewriting.
//!
//! 2. **Iroh fallthrough**: apex declared `fallthrough = "iroh"`, no local
//!    route hit. The subdomain is z32-decoded into a node ID and forwarded
//!    via the TCP_FWD ALPN over Iroh QUIC.
//!
//! Apexes declared `fallthrough = "none"` never consult Iroh and return 404
//! for any unmatched subdomain.

use arc_swap::ArcSwap;
use dashmap::DashMap;
use iroh::endpoint::{Connection, Endpoint};
use iroh_base::{EndpointAddr, PublicKey};
use mjolnir_gateway::acme::{AcmeConfig, IssuedCert};
use mjolnir_gateway::cloudflare::CloudflareClient;
use mjolnir_gateway::config::{self, Apex, Fallthrough, SitesResolver};
use mjolnir_gateway::route::RouteTable;
use mjolnir_gateway::sites::{self as sites_mod, LookupResult};
use mjolnir_gateway::tls::{load_server_config, load_server_config_from_bytes, TlsError};
use mjolnir_protocol::TCP_FWD_ALPN;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use tracing::{debug, error, info, warn};

// ── TlsState (unchanged) ─────────────────────────────────────────────────────

/// Hot-reloadable TLS server configuration. The inner `ServerConfig` is stored
/// in an `ArcSwap` so the SIGHUP handler can atomically swap in a fresh cert
/// without pausing in-flight connections.
struct TlsState {
    config: ArcSwap<rustls::ServerConfig>,
    cert_path: PathBuf,
    key_path: PathBuf,
    session_cache: usize,
    fail_within: Duration,
    not_after: std::sync::RwLock<SystemTime>,
}

impl TlsState {
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
            cert_path: PathBuf::new(),
            key_path: PathBuf::new(),
            session_cache,
            fail_within,
            not_after: std::sync::RwLock::new(not_after),
        }))
    }

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

    fn current_not_after(&self) -> SystemTime {
        self.not_after.read().map(|g| *g).unwrap_or(SystemTime::UNIX_EPOCH)
    }

    fn acceptor(&self) -> tokio_rustls::TlsAcceptor {
        tokio_rustls::TlsAcceptor::from(self.config.load_full())
    }
}

// ── ACME renewal ──────────────────────────────────────────────────────────────

fn should_renew(state: &TlsState, renew_before: &Duration) -> bool {
    let not_after = state.current_not_after();
    match not_after.duration_since(SystemTime::now()) {
        Ok(remaining) => remaining < *renew_before,
        Err(_) => true,
    }
}

/// Shared mutable ACME state: config (SAN list may change on SIGHUP) + CF client.
struct AcmeState {
    cfg: tokio::sync::RwLock<AcmeConfig>,
    cf: CloudflareClient,
}

async fn renewal_loop(state: Arc<TlsState>, acme: Arc<AcmeState>) {
    let mut tick = tokio::time::interval(Duration::from_secs(12 * 3600));
    tick.tick().await;
    loop {
        tick.tick().await;
        let renew_before = { acme.cfg.read().await.renew_before };
        if should_renew(&state, &renew_before) {
            let cfg_snapshot = acme.cfg.read().await.clone_for_issue();
            match mjolnir_gateway::acme::issue(&cfg_snapshot, &acme.cf).await {
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
                Err(e) => error!("acme.renewal_failed: {}", e),
            }
        }
    }
}

// AcmeConfig doesn't impl Clone, so give ourselves a local helper.
trait AcmeConfigExt {
    fn clone_for_issue(&self) -> AcmeConfig;
}
impl AcmeConfigExt for AcmeConfig {
    fn clone_for_issue(&self) -> AcmeConfig {
        AcmeConfig {
            directory_url: self.directory_url.clone(),
            email: self.email.clone(),
            domains: self.domains.clone(),
            state_dir: self.state_dir.clone(),
            renew_before: self.renew_before,
        }
    }
}

// ── ConnectionPool (unchanged) ────────────────────────────────────────────────

struct CachedConnection {
    conn: Connection,
    last_used: Instant,
}

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
        if conn.close_reason().is_some() {
            drop(entry);
            self.cache.remove(key);
            debug!("Pool: evicted closed connection for {}", key);
            return None;
        }
        drop(entry);
        if let Some(mut entry) = self.cache.get_mut(key) {
            entry.last_used = Instant::now();
        }
        Some(conn)
    }

    fn insert(&self, key: PublicKey, conn: Connection) {
        if self.cache.len() >= self.max_size {
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

    fn evict(&self, key: &PublicKey) {
        self.cache.remove(key);
    }
}

// ── ProxyError ────────────────────────────────────────────────────────────────

#[derive(Debug)]
enum ProxyError {
    HeaderTimeout,
    MissingHost,
    /// Host is an apex with `fallthrough="none"` (or empty subdomain) and no
    /// route matches — 404.
    NotFound,
    /// Host matches no declared apex — 400.
    DomainMismatch,
    /// Host equals an apex exactly (no subdomain) — 400 (out of scope per spec).
    EmptySubdomain,
    /// Negotiated SNI ≠ received Host header — 421.
    MisdirectedRequest,
    InvalidTicket(String),
    ConnectTimeout,
    ConnectError(String),
    StreamError(String),
    ResponseTimeout,
    PoolStale,
    /// Local TCP dial to the configured backend failed. The carried string is
    /// for logging only — the HTTP body stays generic to avoid leaking
    /// internal addresses.
    LocalBackendUnreachable(String),
}

impl std::fmt::Display for ProxyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProxyError::HeaderTimeout => write!(f, "Request timeout"),
            ProxyError::MissingHost => write!(f, "Missing Host header"),
            ProxyError::NotFound => write!(f, "Not Found"),
            ProxyError::DomainMismatch => write!(f, "Invalid domain"),
            ProxyError::EmptySubdomain => write!(f, "Empty subdomain"),
            ProxyError::MisdirectedRequest => write!(f, "Misdirected Request"),
            ProxyError::InvalidTicket(e) => write!(f, "Invalid VM ticket: {}", e),
            ProxyError::ConnectTimeout => write!(f, "VM connection timed out"),
            ProxyError::ConnectError(e) => write!(f, "Could not reach VM: {}", e),
            ProxyError::StreamError(e) => write!(f, "VM connection failed: {}", e),
            ProxyError::ResponseTimeout => write!(f, "VM did not respond in time"),
            ProxyError::PoolStale => write!(f, "Pooled VM connection was silently dead; retrying with fresh"),
            ProxyError::LocalBackendUnreachable(_) => write!(f, "Bad Gateway"),
        }
    }
}

impl ProxyError {
    fn status_code(&self) -> u16 {
        match self {
            ProxyError::HeaderTimeout => 408,
            ProxyError::MissingHost => 400,
            ProxyError::NotFound => 404,
            ProxyError::DomainMismatch => 400,
            ProxyError::EmptySubdomain => 400,
            ProxyError::MisdirectedRequest => 421,
            ProxyError::InvalidTicket(_) => 400,
            ProxyError::ConnectTimeout => 504,
            ProxyError::ConnectError(_) => 502,
            ProxyError::StreamError(_) => 502,
            ProxyError::ResponseTimeout => 504,
            ProxyError::PoolStale => 504,
            ProxyError::LocalBackendUnreachable(_) => 502,
        }
    }
}

fn error_to_http_response(err: &ProxyError) -> Vec<u8> {
    let status = err.status_code();
    let body = err.to_string();
    let reason = match status {
        400 => "Bad Request",
        404 => "Not Found",
        408 => "Request Timeout",
        421 => "Misdirected Request",
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

/// Parsed z32 subdomain info used by the Iroh path only.
struct SubdomainInfo {
    node_id_z32: String,
    port: Option<u16>,
}

/// Parse a raw subdomain string (already lowercased, no apex, not port-split)
/// as a z32 node ID optionally followed by `-<port>`.
///
/// The z32 alphabet (`ybndrfg8ejkmcpqxot1uwisza345h769`) does not contain `-`,
/// so splitting on the last `-` to extract a port is unambiguous.
fn parse_z32_subdomain(subdomain: &str) -> Result<SubdomainInfo, ProxyError> {
    // Defensive: classify() guarantees non-empty subdomain before calling here,
    // but we guard anyway in case this function is called from other paths.
    if subdomain.is_empty() {
        return Err(ProxyError::EmptySubdomain);
    }
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
    Ok(SubdomainInfo {
        node_id_z32: subdomain.to_string(),
        port: None,
    })
}

/// Legacy helper retained so existing tests compile. Combines apex matching
/// (single-apex) + z32 parsing into one call. New code should go through
/// `RouteTable::match_host` + `parse_z32_subdomain`.
#[cfg(test)]
fn parse_subdomain(host: &str, domain_suffix: &str) -> Result<SubdomainInfo, ProxyError> {
    let host_no_port = host.split(':').next().unwrap_or(host);
    let host_lower = host_no_port.to_ascii_lowercase();
    let suffix = domain_suffix.to_ascii_lowercase();

    if host_lower == suffix {
        return Err(ProxyError::DomainMismatch);
    }
    let boundary = format!(".{}", suffix);
    let subdomain = match host_lower.strip_suffix(&boundary) {
        Some(prefix) => prefix,
        None => return Err(ProxyError::DomainMismatch),
    };
    parse_z32_subdomain(subdomain)
}

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

// ── HTTP header reading ──────────────────────────────────────────────────────

async fn read_until_headers<S>(stream: &mut S, timeout: Duration) -> Result<Vec<u8>, ProxyError>
where
    S: AsyncRead + Unpin,
{
    const MAX_HEADER_SIZE: usize = 8192;
    let mut buf = Vec::with_capacity(4096);
    let mut tmp = [0u8; 4096];

    let result = tokio::time::timeout(timeout, async {
        loop {
            let n = stream.read(&mut tmp).await.map_err(|_| ProxyError::MissingHost)?;
            if n == 0 {
                return Err(ProxyError::MissingHost);
            }
            buf.extend_from_slice(&tmp[..n]);
            if buf.len() > MAX_HEADER_SIZE {
                return Err(ProxyError::MissingHost);
            }
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

fn extract_host(header_bytes: &[u8]) -> Option<String> {
    let header_str = std::str::from_utf8(header_bytes).ok()?;
    for line in header_str.split("\r\n") {
        if line.len() > 5 && line[..5].eq_ignore_ascii_case("host:") {
            return Some(line[5..].trim().to_string());
        }
    }
    None
}

/// Strip `:port` suffix from a Host value.
fn host_without_port(host: &str) -> &str {
    host.split(':').next().unwrap_or(host)
}

// ── Routing disposition ──────────────────────────────────────────────────────

/// Outcome of Host → route resolution *before* any network work.
enum Disposition<'a> {
    Local(&'a Apex, String, SocketAddr),
    Iroh(&'a Apex, String),
    Reject(ProxyError),
}

fn classify<'a>(table: &'a RouteTable, host: &str) -> Disposition<'a> {
    let host_bare = host_without_port(host);
    let Some((apex, subdomain)) = table.match_host(host_bare) else {
        return Disposition::Reject(ProxyError::DomainMismatch);
    };
    if subdomain.is_empty() {
        return Disposition::Reject(ProxyError::EmptySubdomain);
    }
    if let Some(backend) = table.lookup_local(apex, &subdomain) {
        return Disposition::Local(apex, subdomain, backend);
    }
    match apex.fallthrough {
        Fallthrough::Iroh => Disposition::Iroh(apex, subdomain),
        Fallthrough::None => Disposition::Reject(ProxyError::NotFound),
    }
}

// ── Iroh proxy path ──────────────────────────────────────────────────────────

/// Runtime knobs consumed by the Iroh path.
struct IrohConfig {
    connect_timeout: Duration,
    response_timeout: Duration,
    pool_probe_timeout: Duration,
    default_port: u16,
}

async fn setup_iroh_proxy(
    subdomain: &str,
    header_buf: Vec<u8>,
    ep: &Endpoint,
    pool: &ConnectionPool,
    cfg: &IrohConfig,
    force_fresh: bool,
) -> Result<
    (
        Vec<u8>,
        iroh::endpoint::SendStream,
        iroh::endpoint::RecvStream,
        bool,
        PublicKey,
    ),
    ProxyError,
> {
    let info = parse_z32_subdomain(subdomain)?;
    let port = info.port.unwrap_or(cfg.default_port);
    let addr = resolve_ticket(&info.node_id_z32)?;
    let pubkey = addr.id;

    if force_fresh {
        pool.evict(&pubkey);
    }

    let (conn, pool_hit) = if !force_fresh {
        if let Some(cached) = pool.get(&pubkey) {
            debug!("Pool hit for {}", info.node_id_z32);
            (cached, true)
        } else {
            debug!("Pool miss for {}, connecting...", info.node_id_z32);
            let new_conn = tokio::time::timeout(cfg.connect_timeout, ep.connect(addr.clone(), TCP_FWD_ALPN))
                .await
                .map_err(|_| ProxyError::ConnectTimeout)?
                .map_err(|e| ProxyError::ConnectError(e.to_string()))?;
            pool.insert(pubkey, new_conn.clone());
            (new_conn, false)
        }
    } else {
        debug!("Forced fresh connect for {}", info.node_id_z32);
        let new_conn = tokio::time::timeout(cfg.connect_timeout, ep.connect(addr.clone(), TCP_FWD_ALPN))
            .await
            .map_err(|_| ProxyError::ConnectTimeout)?
            .map_err(|e| ProxyError::ConnectError(e.to_string()))?;
        pool.insert(pubkey, new_conn.clone());
        (new_conn, false)
    };

    let (mut send, recv) = match conn.open_bi().await {
        Ok(streams) => streams,
        Err(e) => {
            pool.evict(&pubkey);
            debug!("Stale connection for {}, reconnecting: {}", info.node_id_z32, e);
            let addr = resolve_ticket(&info.node_id_z32)?;
            let new_conn = tokio::time::timeout(cfg.connect_timeout, ep.connect(addr, TCP_FWD_ALPN))
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

    send.write_all(&port.to_be_bytes())
        .await
        .map_err(|e| ProxyError::StreamError(e.to_string()))?;

    Ok((header_buf, send, recv, pool_hit, pubkey))
}

async fn write_error_and_shutdown<W>(w: &mut W, err: &ProxyError)
where
    W: AsyncWrite + Unpin,
{
    let _ = w.write_all(&error_to_http_response(err)).await;
    let _ = w.shutdown().await;
}

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

    let client_to_vm = async {
        let r = tokio::io::copy(&mut tcp_read, &mut quic_send).await;
        let _ = quic_send.finish();
        r
    };
    let vm_to_client = async { tokio::io::copy(&mut quic_recv, &mut tcp_write).await };

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

// ── Local TCP backend path ──────────────────────────────────────────────────

/// Dial the configured local backend. Returns the connected `TcpStream` or a
/// `ProxyError::LocalBackendUnreachable`. Split out so the caller retains
/// ownership of the client stream and can write a 502 if the dial fails.
async fn dial_local(backend: SocketAddr, connect_timeout: Duration) -> Result<tokio::net::TcpStream, ProxyError> {
    tokio::time::timeout(connect_timeout, tokio::net::TcpStream::connect(backend))
        .await
        .map_err(|_| ProxyError::LocalBackendUnreachable(format!("connect timeout to {}", backend)))?
        .map_err(|e| ProxyError::LocalBackendUnreachable(format!("{} → {}", backend, e)))
}

/// Forward `header_buf` + the rest of `client` to an already-dialled
/// `backend_stream` bidirectionally. Does NOT rewrite headers.
async fn run_proxy_local<S>(client: S, backend_stream: tokio::net::TcpStream, header_buf: Vec<u8>)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (mut bk_read, mut bk_write) = tokio::io::split(backend_stream);
    let (mut cl_read, mut cl_write) = tokio::io::split(client);

    // Forward the already-buffered request bytes first.
    if !header_buf.is_empty() {
        if let Err(e) = bk_write.write_all(&header_buf).await {
            warn!("write header to backend: {}", e);
            return;
        }
    }

    let client_to_backend = async {
        let r = tokio::io::copy(&mut cl_read, &mut bk_write).await;
        let _ = bk_write.shutdown().await;
        r
    };
    let backend_to_client = async {
        let r = tokio::io::copy(&mut bk_read, &mut cl_write).await;
        let _ = cl_write.shutdown().await;
        r
    };

    let (c2b, b2c) = tokio::join!(client_to_backend, backend_to_client);
    if let Err(e) = c2b {
        if e.kind() != std::io::ErrorKind::ConnectionReset {
            warn!("client->backend error: {}", e);
        }
    }
    if let Err(e) = b2c {
        if e.kind() != std::io::ErrorKind::ConnectionReset {
            warn!("backend->client error: {}", e);
        }
    }
}

// ── Connection handler ──────────────────────────────────────────────────────

/// Shared context threaded through the accept loop.
struct AppCtx {
    ep: Arc<Endpoint>,
    pool: Arc<ConnectionPool>,
    routes: Arc<ArcSwap<RouteTable>>,
    iroh_cfg: Arc<IrohConfig>,
    sites_resolver: Option<SitesResolver>,
}

/// Handle a single incoming connection (plain TCP or TLS). `sni_hostname`, when
/// set, forces SNI=Host enforcement (Decision 4).
async fn handle_connection<S>(mut stream: S, peer: SocketAddr, ctx: Arc<AppCtx>, sni_hostname: Option<String>)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    // Snapshot the route table — in-flight connections keep this view even
    // across a SIGHUP swap.
    let table = ctx.routes.load_full();

    let header_buf = match read_until_headers(&mut stream, Duration::from_secs(5)).await {
        Ok(buf) => buf,
        Err(e) => {
            warn!("{}: {}", peer, e);
            let _ = stream.write_all(&error_to_http_response(&e)).await;
            let _ = stream.shutdown().await;
            return;
        }
    };

    let host = match extract_host(&header_buf) {
        Some(h) => h,
        None => {
            let e = ProxyError::MissingHost;
            warn!("{}: {}", peer, e);
            let _ = stream.write_all(&error_to_http_response(&e)).await;
            let _ = stream.shutdown().await;
            return;
        }
    };

    // SNI ≡ Host enforcement on the TLS path.
    if let Some(ref sni) = sni_hostname {
        let host_bare = host_without_port(&host).to_ascii_lowercase();
        if host_bare != sni.to_ascii_lowercase() {
            let e = ProxyError::MisdirectedRequest;
            warn!("{}: SNI={} Host={} mismatch — 421", peer, sni, host_bare);
            let _ = stream.write_all(&error_to_http_response(&e)).await;
            let _ = stream.shutdown().await;
            return;
        }
    }

    match classify(&table, &host) {
        Disposition::Local(apex, subdomain, backend) => {
            info!(
                peer = %peer,
                apex = %apex.suffix,
                subdomain = %subdomain,
                route = "local",
                "proxy decision"
            );
            let connect_timeout = ctx.iroh_cfg.connect_timeout;
            match dial_local(backend, connect_timeout).await {
                Ok(backend_stream) => {
                    run_proxy_local(stream, backend_stream, header_buf).await;
                }
                Err(e) => {
                    match &e {
                        ProxyError::LocalBackendUnreachable(detail) => {
                            warn!("{}: local backend unreachable: {}", peer, detail);
                        }
                        _ => warn!("{}: {}", peer, e),
                    }
                    write_error_and_shutdown(&mut stream, &e).await;
                }
            }
        }
        Disposition::Iroh(apex, subdomain) => {
            info!(
                peer = %peer,
                apex = %apex.suffix,
                subdomain = %subdomain,
                route = "iroh",
                "proxy decision"
            );
            handle_iroh_connection(stream, peer, ctx.clone(), subdomain, header_buf).await;
        }
        Disposition::Reject(ref e @ ProxyError::DomainMismatch) => {
            // No configured apex matched — try the sites-alias resolver before
            // falling through to 404.
            if let Some(ref resolver) = ctx.sites_resolver {
                // HTTP hostnames are case-insensitive; the Mjolnir-side index
                // is keyed on lowercase fqdn, so normalise here before lookup.
                let host_bare_owned = host_without_port(&host).to_ascii_lowercase();
                let host_bare = host_bare_owned.as_str();
                match sites_mod::lookup(resolver, host_bare).await {
                    LookupResult::Hit(backend) => {
                        info!(
                            peer = %peer,
                            host = %host_bare,
                            route = "sites",
                            "sites alias hit — forwarding to mjolnir backend"
                        );
                        let connect_timeout = ctx.iroh_cfg.connect_timeout;
                        match dial_local(backend, connect_timeout).await {
                            Ok(backend_stream) => {
                                run_proxy_local(stream, backend_stream, header_buf).await;
                            }
                            Err(dial_err) => {
                                warn!("{}: sites backend unreachable: {}", peer, dial_err);
                                write_error_and_shutdown(&mut stream, &dial_err).await;
                            }
                        }
                        return;
                    }
                    LookupResult::Miss => {
                        // Fall through to the existing 404 below.
                    }
                    LookupResult::Error => {
                        warn!(
                            peer = %peer,
                            host = %host,
                            "sites resolver error"
                        );
                        // Fall through to the existing 404 below.
                    }
                }
            }
            warn!(
                peer = %peer,
                host = %host,
                error = %e,
                "proxy rejection"
            );
            let _ = stream.write_all(&error_to_http_response(e)).await;
            let _ = stream.shutdown().await;
        }
        Disposition::Reject(e) => {
            warn!(
                peer = %peer,
                host = %host,
                error = %e,
                "proxy rejection"
            );
            let _ = stream.write_all(&error_to_http_response(&e)).await;
            let _ = stream.shutdown().await;
        }
    }
}

/// Iroh fallthrough: resolve z32 subdomain, pool-aware dial, forward headers.
async fn handle_iroh_connection<S>(
    mut stream: S,
    peer: SocketAddr,
    ctx: Arc<AppCtx>,
    subdomain: String,
    header_buf: Vec<u8>,
) where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let response_timeout = ctx.iroh_cfg.response_timeout;
    let pool_probe_timeout = ctx.iroh_cfg.pool_probe_timeout;

    let mut cached_headers: Option<Vec<u8>> = Some(header_buf);

    for attempt in 0u32..2 {
        let force_fresh = attempt > 0;
        let hdrs = cached_headers.take().unwrap_or_default();
        match setup_iroh_proxy(&subdomain, hdrs, &ctx.ep, &ctx.pool, &ctx.iroh_cfg, force_fresh).await {
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

                let probe = if pool_hit && !pool_probe_timeout.is_zero() {
                    pool_probe_timeout
                } else {
                    response_timeout
                };

                match forward_headers_and_probe(&header_buf, &mut quic_send, &mut quic_recv, probe, pool_hit).await
                {
                    Ok(first_byte) => {
                        run_proxy(stream, first_byte, quic_send, quic_recv).await;
                        return;
                    }
                    Err(e) => {
                        if matches!(e, ProxyError::PoolStale) && attempt == 0 {
                            warn!(
                                "{}: pool probe timed out after {:?}, evicting and retrying fresh",
                                peer, pool_probe_timeout
                            );
                            ctx.pool.evict(&pubkey);
                            let _ = quic_send.finish();
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

// ── Signal helpers ──────────────────────────────────────────────────────────

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

// ── Main ─────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("failed to install rustls crypto provider");

    // ── Load config ───────────────────────────────────────────────────────────
    let config_path = config::resolve_config_path();
    let loaded = match config::load(&config_path) {
        Ok(c) => c,
        Err(e) => {
            error!("config load failed: {}", e);
            std::process::exit(1);
        }
    };

    info!(
        event = "gateway.startup",
        source = ?loaded.source,
        apex_count = loaded.apexes.len(),
        route_count = loaded.routes.len(),
        acme_enabled = loaded.acme.enabled,
        "gateway starting"
    );
    for apex in &loaded.apexes {
        info!(event = "apex.configured", apex = %apex.suffix, fallthrough = ?apex.fallthrough);
    }
    for route in &loaded.routes {
        debug!(
            event = "route.configured",
            apex = %route.apex,
            subdomain = %route.subdomain,
            backend = %route.backend
        );
    }

    if loaded.listen.is_none() && loaded.listen_tls.is_none() {
        error!("no listeners configured — exiting");
        std::process::exit(1);
    }

    if loaded.tls_expiry_fail_secs == 0 {
        warn!("tls_expiry_fail_secs=0 disables the Scenario-3 expiring-cert mitigation");
    }

    // ── State dir (ACME) ──────────────────────────────────────────────────────
    let state_dir = {
        let base = std::env::var("STATE_DIRECTORY").unwrap_or_else(|_| "/var/lib/mjolnir-gateway".to_owned());
        let dir = PathBuf::from(base).join("acme");
        std::fs::create_dir_all(&dir)?;
        dir
    };

    // ── Bind listeners ────────────────────────────────────────────────────────
    let plain_listener: Option<TcpListener> = if let Some(addr) = loaded.listen {
        let l = TcpListener::bind(addr).await?;
        info!("Plaintext listener on {}", addr);
        Some(l)
    } else {
        info!("Plaintext listener disabled");
        None
    };

    // Build ACME config + cert (may be static) up front.
    let acme_enabled = loaded.acme.enabled;

    let acme_state: Option<Arc<AcmeState>> = if acme_enabled {
        if loaded.acme.email.is_empty() {
            error!("[acme].email is required when ACME is enabled");
            std::process::exit(1);
        }
        let token = match config::load_cloudflare_token(&loaded) {
            Ok(t) => t,
            Err(e) => {
                error!("cloudflare token: {}", e);
                std::process::exit(1);
            }
        };
        let cf = CloudflareClient::new(token)?;
        let san_list = loaded.effective_acme_domains();
        if san_list.is_empty() {
            error!("[acme].domains is empty after SAN auto-derivation");
            std::process::exit(1);
        }
        let acme_cfg = AcmeConfig {
            directory_url: loaded.acme.directory.clone(),
            email: loaded.acme.email.clone(),
            domains: san_list,
            state_dir: state_dir.clone(),
            renew_before: loaded.acme_renew_before(),
        };
        Some(Arc::new(AcmeState {
            cfg: tokio::sync::RwLock::new(acme_cfg),
            cf,
        }))
    } else {
        None
    };

    let tls_state: Option<Arc<TlsState>> = if loaded.listen_tls.is_none() {
        info!("TLS listener disabled");
        None
    } else if let Some(ref acme) = acme_state {
        let acme_cfg = acme.cfg.read().await.clone_for_issue();
        let issued: IssuedCert = mjolnir_gateway::acme::load_or_issue(&acme_cfg, &acme.cf).await?;
        info!(
            "ACME cert ready: expires {}, fingerprint {}",
            humantime::format_rfc3339_seconds(issued.not_after),
            issued.fingerprint_sha256
        );
        let fail_within = loaded.tls_expiry_fail();
        let state = TlsState::from_pem_bytes(
            issued.chain_pem.as_bytes(),
            issued.key_pem.as_bytes(),
            loaded.tls_session_cache,
            fail_within,
            issued.not_after,
        )?;
        tokio::spawn(renewal_loop(Arc::clone(&state), Arc::clone(acme)));
        Some(state)
    } else {
        let cert = loaded
            .tls_cert_path
            .clone()
            .ok_or("tls_listen set but no [tls].cert configured and ACME disabled")?;
        let key = loaded
            .tls_key_path
            .clone()
            .ok_or("tls_listen set but no [tls].key configured and ACME disabled")?;
        let fail_within = loaded.tls_expiry_fail();
        let state = TlsState::load(cert, key, loaded.tls_session_cache, fail_within)?;
        Some(state)
    };

    let tls_listener: Option<TcpListener> = if let Some(addr) = loaded.listen_tls {
        let l = TcpListener::bind(addr).await?;
        info!("TLS listener on {}", addr);
        Some(l)
    } else {
        None
    };

    // ── Iroh endpoint + pool ──────────────────────────────────────────────────
    info!("Starting Iroh endpoint...");
    let endpoint = Endpoint::builder().bind().await?;
    endpoint.online().await;
    info!("Iroh endpoint ready");

    let pool = Arc::new(ConnectionPool::new(loaded.pool_ttl(), loaded.pool_max));

    let iroh_cfg = Arc::new(IrohConfig {
        connect_timeout: loaded.connect_timeout(),
        response_timeout: loaded.response_timeout(),
        pool_probe_timeout: loaded.pool_probe_timeout(),
        default_port: loaded.vm_default_port,
    });

    let route_table = Arc::new(ArcSwap::from_pointee(RouteTable::from_config(&loaded)));

    let ctx = Arc::new(AppCtx {
        ep: Arc::new(endpoint),
        pool,
        routes: route_table.clone(),
        iroh_cfg,
        sites_resolver: loaded.sites_resolver.clone(),
    });

    // ── SIGHUP handler ────────────────────────────────────────────────────────
    #[cfg(unix)]
    let mut sighup = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup())
        .expect("failed to register SIGHUP handler");

    // ── Accept loop ───────────────────────────────────────────────────────────
    info!(
        "Gateway ready (pool: max={}, ttl={}s, probe={}s)",
        loaded.pool_max, loaded.pool_ttl_secs, loaded.pool_probe_timeout_secs
    );

    // Snapshot the initial listen addrs so SIGHUP can warn if they diverge.
    let initial_listen = loaded.listen;
    let initial_listen_tls = loaded.listen_tls;

    loop {
        enum Event {
            Plain(std::io::Result<(tokio::net::TcpStream, SocketAddr)>),
            Tls(std::io::Result<(tokio::net::TcpStream, SocketAddr)>),
            Shutdown,
            #[cfg(unix)]
            Sighup,
        }

        let event = {
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
                let ctx = Arc::clone(&ctx);
                tokio::spawn(async move {
                    handle_connection(stream, peer, ctx, None).await;
                });
            }
            Event::Plain(Err(e)) => warn!("Plaintext accept error: {}", e),
            Event::Tls(Ok((tcp_stream, peer))) => {
                let tls = Arc::clone(tls_state.as_ref().expect("tls_state present"));
                let ctx = Arc::clone(&ctx);
                tokio::spawn(async move {
                    match tls.acceptor().accept(tcp_stream).await {
                        Ok(tls_stream) => {
                            let sni = tls_stream
                                .get_ref()
                                .1
                                .server_name()
                                .map(|s| s.to_ascii_lowercase());
                            handle_connection(tls_stream, peer, ctx, sni).await;
                        }
                        Err(e) => warn!("{}: TLS handshake failed: {}", peer, e),
                    }
                });
            }
            Event::Tls(Err(e)) => warn!("TLS accept error: {}", e),
            Event::Shutdown => {
                info!("Shutting down");
                break;
            }
            #[cfg(unix)]
            Event::Sighup => {
                info!("SIGHUP received — reloading config + certs");

                // Step 1: re-read config (TOML if TOML mode, env otherwise).
                if loaded.source == config::ConfigSource::Env {
                    info!(
                        "SIGHUP in env mode: env vars are re-read from the process env, \
                         which systemd freezes after startup. To change env values, restart the service."
                    );
                }
                let reload = match loaded.source {
                    config::ConfigSource::Toml => config::load(&config_path),
                    config::ConfigSource::Env => config::load_from_env(),
                };
                let new_loaded = match reload {
                    Ok(c) => c,
                    Err(e) => {
                        error!("SIGHUP: config reload failed, keeping previous: {}", e);
                        continue;
                    }
                };

                // Step 2: warn on listener-address drift (not applied).
                if new_loaded.listen != initial_listen || new_loaded.listen_tls != initial_listen_tls {
                    warn!(
                        "SIGHUP: listen/listen_tls changed — ignored (listener change requires restart)"
                    );
                }

                // Step 3: atomically swap the route table.
                let new_table = RouteTable::from_config(&new_loaded);
                let route_count = new_table.route_count();
                let apex_count = new_table.apex_count();
                route_table.store(Arc::new(new_table));
                info!(
                    event = "config.reloaded",
                    apex_count,
                    route_count,
                    "route table swapped"
                );

                // Step 4: update ACME SAN list + kick a renewal (if ACME).
                if let (Some(acme), Some(tls)) = (acme_state.as_ref(), tls_state.as_ref()) {
                    let new_sans = new_loaded.effective_acme_domains();
                    if new_sans.is_empty() {
                        warn!("SIGHUP: new config has empty ACME SAN list — skipping renewal");
                    } else {
                        let mut guard = acme.cfg.write().await;
                        guard.domains = new_sans;
                        guard.email = new_loaded.acme.email.clone();
                        guard.directory_url = new_loaded.acme.directory.clone();
                        guard.renew_before = new_loaded.acme_renew_before();
                        let snapshot = guard.clone_for_issue();
                        drop(guard);

                        let tls_clone = Arc::clone(tls);
                        let acme_clone = Arc::clone(acme);
                        tokio::spawn(async move {
                            match mjolnir_gateway::acme::issue(&snapshot, &acme_clone.cf).await {
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
                    }
                } else if let Some(tls) = tls_state.as_ref() {
                    // Static cert mode — reload from disk.
                    if let Err(e) = tls.reload() {
                        warn!("SIGHUP: static cert reload failed: {}", e);
                    }
                }
            }
        }
    }

    Ok(())
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use mjolnir_gateway::config::{Apex, Fallthrough, LoadedConfig, Route};

    // ── helpers ──────────────────────────────────────────────────────────────

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

    /// Build a minimal LoadedConfig suitable for RouteTable construction.
    fn loaded_with(apexes: Vec<Apex>, routes: Vec<Route>) -> LoadedConfig {
        LoadedConfig {
            source: mjolnir_gateway::config::ConfigSource::Toml,
            listen: None,
            listen_tls: None,
            vm_default_port: 80,
            connect_timeout_secs: 15,
            response_timeout_secs: 0,
            pool_ttl_secs: 300,
            pool_max: 256,
            pool_probe_timeout_secs: 10,
            tls_expiry_fail_secs: 86400,
            tls_session_cache: 4096,
            tls_cert_path: None,
            tls_key_path: None,
            acme: mjolnir_gateway::config::AcmeSettings {
                enabled: false,
                email: String::new(),
                directory: String::new(),
                renew_before_secs: 0,
                cloudflare_api_token_file: None,
                explicit_domains: None,
            },
            apexes,
            routes,
            sites_resolver: None,
        }
    }

    // ── Existing tests (unchanged semantics, parse_subdomain retained for BC) ─

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
        assert_eq!(info.port, Some(3000));
    }

    #[test]
    fn test_parse_subdomain_with_gateway_port() {
        // Host header with its own :port must still parse.
        let info = parse_subdomain(
            "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u.vm.worldtree.network:8080",
            "vm.worldtree.network",
        )
        .unwrap();
        assert_eq!(info.port, None);
    }

    #[test]
    fn test_parse_subdomain_wrong_domain() {
        let result = parse_subdomain("something.other.domain", "vm.worldtree.network");
        assert!(matches!(result, Err(ProxyError::DomainMismatch)));
    }

    #[test]
    fn test_parse_subdomain_empty() {
        let result = parse_subdomain("vm.worldtree.network", "vm.worldtree.network");
        assert!(matches!(result, Err(ProxyError::DomainMismatch)));
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
        let secret = iroh_base::SecretKey::generate(&mut rand::rng());
        let key = secret.public();
        let z32_str = z32::encode(key.as_bytes());
        assert_eq!(z32_str.len(), 52);
        let addr = resolve_ticket(&z32_str).unwrap();
        assert_eq!(addr.id, key);
    }

    #[test]
    fn test_z32_known_vectors() {
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

        let resp = error_to_http_response(&ProxyError::ConnectTimeout);
        let resp_str = String::from_utf8(resp).unwrap();
        assert!(resp_str.starts_with("HTTP/1.1 504 Gateway Timeout"));

        let resp = error_to_http_response(&ProxyError::HeaderTimeout);
        let resp_str = String::from_utf8(resp).unwrap();
        assert!(resp_str.starts_with("HTTP/1.1 408 Request Timeout"));

        let resp = error_to_http_response(&ProxyError::ResponseTimeout);
        let resp_str = String::from_utf8(resp).unwrap();
        assert!(resp_str.starts_with("HTTP/1.1 504 Gateway Timeout"));
    }

    #[tokio::test]
    async fn write_error_and_shutdown_sends_504_over_duplex() {
        let (client_side, server_side) = tokio::io::duplex(4096);
        let (mut client_read, _client_write) = tokio::io::split(client_side);
        let (_server_read, mut server_write) = tokio::io::split(server_side);

        write_error_and_shutdown(&mut server_write, &ProxyError::ResponseTimeout).await;

        let mut received = Vec::new();
        let _ = tokio::io::copy(&mut client_read, &mut received).await;

        let response_str = String::from_utf8(received).expect("valid utf-8");
        assert!(response_str.starts_with("HTTP/1.1 504 Gateway Timeout"));
        assert!(response_str.contains("VM did not respond in time"));
    }

    // ── TlsState tests (unchanged) ───────────────────────────────────────────

    #[test]
    fn tls_state_reload_keeps_previous_cert_on_failure() {
        install_provider();

        let (cert_pem, key_pem) = generate_self_signed_pem("reload-test");

        let dir = tempfile::tempdir().expect("tempdir");
        let cert_path = dir.path().join("cert.pem");
        let key_path = dir.path().join("key.pem");
        std::fs::write(&cert_path, &cert_pem).unwrap();
        std::fs::write(&key_path, &key_pem).unwrap();

        let tls_state =
            TlsState::load(cert_path.clone(), key_path.clone(), 128, Duration::from_secs(86400))
                .expect("initial TlsState::load must succeed");

        let config_before = Arc::as_ptr(&tls_state.config.load_full());

        std::fs::write(&cert_path, b"this is not a valid PEM cert").unwrap();

        let reload_result = tls_state.reload();
        assert!(reload_result.is_err());

        let config_after = Arc::as_ptr(&tls_state.config.load_full());
        assert_eq!(config_before, config_after);

        let _acceptor = tls_state.acceptor();
    }

    #[test]
    fn should_renew_returns_true_when_expiring_soon() {
        install_provider();
        let (cert_pem, key_pem) = generate_self_signed_pem("renew-soon");
        let dir = tempfile::tempdir().expect("tempdir");
        let cert_path = dir.path().join("cert.pem");
        let key_path = dir.path().join("key.pem");
        std::fs::write(&cert_path, &cert_pem).unwrap();
        std::fs::write(&key_path, &key_pem).unwrap();

        let state =
            TlsState::load(cert_path, key_path, 128, Duration::from_secs(60)).expect("TlsState::load");

        let expiring_soon = SystemTime::now() + Duration::from_secs(3600);
        *state.not_after.write().unwrap() = expiring_soon;

        let renew_before = Duration::from_secs(30 * 24 * 3600);
        assert!(should_renew(&state, &renew_before));
    }

    #[test]
    fn should_renew_returns_false_when_fresh() {
        install_provider();
        let (cert_pem, key_pem) = generate_self_signed_pem("renew-fresh");
        let dir = tempfile::tempdir().expect("tempdir");
        let cert_path = dir.path().join("cert.pem");
        let key_path = dir.path().join("key.pem");
        std::fs::write(&cert_path, &cert_pem).unwrap();
        std::fs::write(&key_path, &key_pem).unwrap();

        let state =
            TlsState::load(cert_path, key_path, 128, Duration::from_secs(60)).expect("TlsState::load");

        let fresh = SystemTime::now() + Duration::from_secs(365 * 24 * 3600);
        *state.not_after.write().unwrap() = fresh;

        let renew_before = Duration::from_secs(30 * 24 * 3600);
        assert!(!should_renew(&state, &renew_before));
    }

    // ── New classification tests (multi-apex + route precedence) ─────────────

    fn apex(suffix: &str, ft: Fallthrough) -> Apex {
        Apex {
            suffix: suffix.to_owned(),
            fallthrough: ft,
        }
    }

    fn route(apex: &str, sub: &str, backend: &str) -> Route {
        Route {
            apex: apex.to_owned(),
            subdomain: sub.to_owned(),
            backend: backend.parse().unwrap(),
        }
    }

    #[test]
    fn route_precedes_iroh_under_fallthrough_iroh() {
        // Apex is iroh-fallthrough, but `special` is pinned to a local backend.
        let cfg = loaded_with(
            vec![apex("vm.worldtree.network", Fallthrough::Iroh)],
            vec![route("vm.worldtree.network", "special", "127.0.0.1:4000")],
        );
        let table = RouteTable::from_config(&cfg);
        let d = classify(&table, "special.vm.worldtree.network");
        assert!(matches!(d, Disposition::Local(_, _, _)));

        // Any other subdomain falls through to Iroh.
        let d = classify(&table, "abcdef.vm.worldtree.network");
        assert!(matches!(d, Disposition::Iroh(_, _)));
    }

    #[test]
    fn fallthrough_none_returns_404_no_iroh_decode() {
        let cfg = loaded_with(
            vec![apex("worldtree.network", Fallthrough::None)],
            vec![route("worldtree.network", "git", "127.0.0.1:3000")],
        );
        let table = RouteTable::from_config(&cfg);

        // Pinned route → Local
        let d = classify(&table, "git.worldtree.network");
        assert!(matches!(d, Disposition::Local(_, _, _)));

        // Unpinned → 404 (NotFound)
        let d = classify(&table, "unknown.worldtree.network");
        assert!(matches!(d, Disposition::Reject(ProxyError::NotFound)));
    }

    #[test]
    fn domain_mismatch_returns_400_no_routing() {
        let cfg = loaded_with(vec![apex("a.com", Fallthrough::Iroh)], vec![]);
        let table = RouteTable::from_config(&cfg);
        let d = classify(&table, "foo.b.com");
        assert!(matches!(d, Disposition::Reject(ProxyError::DomainMismatch)));
    }

    #[test]
    fn empty_subdomain_returns_400() {
        let cfg = loaded_with(vec![apex("a.com", Fallthrough::Iroh)], vec![]);
        let table = RouteTable::from_config(&cfg);
        let d = classify(&table, "a.com");
        assert!(matches!(d, Disposition::Reject(ProxyError::EmptySubdomain)));
    }

    #[test]
    fn classify_strips_host_port_before_matching() {
        let cfg = loaded_with(vec![apex("a.com", Fallthrough::Iroh)], vec![]);
        let table = RouteTable::from_config(&cfg);
        let d = classify(&table, "foo.a.com:8080");
        match d {
            Disposition::Iroh(a, sub) => {
                assert_eq!(a.suffix, "a.com");
                assert_eq!(sub, "foo");
            }
            _ => panic!("expected Iroh disposition"),
        }
    }

    #[test]
    fn sni_host_mismatch_returns_421() {
        // Integration-ish: we can't run TLS here, but we can confirm the
        // `handle_connection`-equivalent logic rejects mismatch. We do this
        // via a tiny inlined reproduction of the enforcement branch that
        // mirrors handle_connection's body.
        let sni = "git.worldtree.network".to_string();
        let host = "admin.worldtree.network";
        let host_bare = host_without_port(host).to_ascii_lowercase();
        let mismatch = host_bare != sni.to_ascii_lowercase();
        assert!(mismatch);

        let resp = error_to_http_response(&ProxyError::MisdirectedRequest);
        let resp_str = String::from_utf8(resp).unwrap();
        assert!(resp_str.starts_with("HTTP/1.1 421 Misdirected Request"));
    }

    // ── Integration tests: local-backend byte pass-through ──────────────────

    /// Spec AC 2: with a local route, bytes reach the stub backend unmodified —
    /// no X-Forwarded-* injection, original Host preserved.
    #[tokio::test]
    async fn local_route_passes_bytes_unmodified_no_forwarded_headers() {
        // Start a stub TCP listener that records whatever it receives.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let backend_addr = listener.local_addr().unwrap();

        let received = Arc::new(tokio::sync::Mutex::new(Vec::<u8>::new()));
        let received_clone = received.clone();
        tokio::spawn(async move {
            if let Ok((mut s, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                // Read whatever the client sends, up to first chunk.
                if let Ok(n) = s.read(&mut buf).await {
                    received_clone.lock().await.extend_from_slice(&buf[..n]);
                }
                // Echo back a trivial 200 so the proxy can close cleanly.
                let _ = s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n").await;
                let _ = s.shutdown().await;
            }
        });

        // The "client end" of the duplex pair is driven by a helper task that
        // pre-feeds an HTTP request and then drains whatever the proxy writes
        // back. `proxy_side` is what run_proxy_local operates on — the same
        // role a `TcpStream` plays in production.
        let request_bytes =
            b"GET /foo HTTP/1.1\r\nHost: git.worldtree.network\r\nUser-Agent: test\r\n\r\n";
        let req_bytes: Vec<u8> = request_bytes.to_vec();

        let (client_end, proxy_side) = tokio::io::duplex(8192);
        tokio::spawn(async move {
            let (mut cr, mut cw) = tokio::io::split(client_end);
            cw.write_all(&req_bytes).await.unwrap();
            cw.shutdown().await.ok();
            // Drain the response so run_proxy_local's backend→client copy
            // doesn't block forever on a full pipe.
            let mut sink = Vec::new();
            let _ = tokio::io::copy(&mut cr, &mut sink).await;
        });

        // read_until_headers will pull from proxy_side; we call run_proxy_local
        // after reading the header block — match handle_connection semantics.
        let mut proxy_side = proxy_side;
        let header_buf = read_until_headers(&mut proxy_side, Duration::from_secs(2))
            .await
            .expect("read headers");

        // Sanity check: the parsed Host is what we expect.
        assert_eq!(
            extract_host(&header_buf).as_deref(),
            Some("git.worldtree.network")
        );

        let backend_stream = dial_local(backend_addr, Duration::from_secs(2))
            .await
            .expect("dial_local should succeed");
        run_proxy_local(proxy_side, backend_stream, header_buf).await;

        // Wait briefly for the stub to finish recording.
        tokio::time::sleep(Duration::from_millis(50)).await;
        let got = received.lock().await.clone();
        let got_str = String::from_utf8(got).expect("utf-8");

        assert!(got_str.contains("Host: git.worldtree.network"), "original Host must reach backend, got: {:?}", got_str);
        assert!(!got_str.to_ascii_lowercase().contains("x-forwarded-for"));
        assert!(!got_str.to_ascii_lowercase().contains("x-forwarded-proto"));
        assert!(!got_str.to_ascii_lowercase().contains("x-forwarded-host"));
        assert!(!got_str.to_ascii_lowercase().contains("x-real-ip"));
    }

    /// Spec AC 4: fallthrough="none" request for an unknown subdomain yields
    /// a `Disposition::Reject(NotFound)` — no Iroh endpoint consulted.
    #[test]
    fn fallthrough_none_returns_404_and_does_not_dial_iroh() {
        let cfg = loaded_with(
            vec![apex("worldtree.network", Fallthrough::None)],
            vec![route("worldtree.network", "git", "127.0.0.1:3000")],
        );
        let table = RouteTable::from_config(&cfg);
        let d = classify(&table, "unknown.worldtree.network");
        match d {
            Disposition::Reject(ProxyError::NotFound) => {}
            other => panic!("expected Reject(NotFound), got variant that is not: {:?}",
                match other {
                    Disposition::Local(_, _, _) => "Local",
                    Disposition::Iroh(_, _) => "Iroh",
                    Disposition::Reject(_) => "Reject(other)",
                }
            ),
        }
    }

    /// Fallthrough=iroh → an unmatched subdomain yields `Disposition::Iroh`
    /// which will attempt z32 decode on the subdomain. We assert the
    /// disposition; actual z32 decode is exercised by `test_z32_roundtrip`.
    #[test]
    fn fallthrough_iroh_attempts_z32_decode_when_no_route() {
        let cfg = loaded_with(vec![apex("vm.worldtree.network", Fallthrough::Iroh)], vec![]);
        let table = RouteTable::from_config(&cfg);
        let d = classify(&table, "somesub.vm.worldtree.network");
        match d {
            Disposition::Iroh(a, sub) => {
                assert_eq!(a.suffix, "vm.worldtree.network");
                assert_eq!(sub, "somesub");
                // A non-z32 subdomain would fail parse_z32_subdomain (exercised
                // inside setup_iroh_proxy); `somesub` is z32-valid chars so we
                // assert the attempt by confirming Disposition is Iroh.
            }
            _ => panic!("expected Iroh disposition"),
        }
    }

    #[test]
    fn local_backend_unreachable_body_is_generic() {
        // The body of the 502 must say "Bad Gateway", not leak the backend.
        let e = ProxyError::LocalBackendUnreachable("127.0.0.1:9999 → connection refused".into());
        let resp = error_to_http_response(&e);
        let resp_str = String::from_utf8(resp).unwrap();
        assert!(resp_str.starts_with("HTTP/1.1 502 Bad Gateway"));
        assert!(resp_str.contains("Bad Gateway"));
        assert!(
            !resp_str.contains("127.0.0.1:9999"),
            "backend address must not leak into the response body"
        );
        assert!(
            !resp_str.contains("connection refused"),
            "underlying error must not leak into the response body"
        );
    }

    /// Spec R5: when the local backend port is unbound, the client receives
    /// `HTTP/1.1 502 Bad Gateway` — not a silent connection close.
    /// This drives `handle_connection` end-to-end via a duplex pair.
    #[tokio::test]
    async fn local_backend_unreachable_sends_502_to_client() {
        // Pick a port that is guaranteed unbound by binding then dropping the listener.
        let probe = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let dead_addr = probe.local_addr().unwrap();
        drop(probe); // port is now unbound

        let cfg = loaded_with(
            vec![apex("worldtree.network", Fallthrough::None)],
            vec![route("worldtree.network", "git", &dead_addr.to_string())],
        );
        let table = Arc::new(ArcSwap::from_pointee(RouteTable::from_config(&cfg)));

        let ep = iroh::endpoint::Endpoint::builder()
            .bind()
            .await
            .expect("iroh endpoint");
        let ctx = Arc::new(AppCtx {
            ep: Arc::new(ep),
            pool: Arc::new(ConnectionPool::new(Duration::from_secs(300), 256)),
            routes: table,
            iroh_cfg: Arc::new(IrohConfig {
                connect_timeout: Duration::from_millis(200),
                response_timeout: Duration::from_secs(5),
                pool_probe_timeout: Duration::from_secs(5),
                default_port: 80,
            }),
            sites_resolver: None,
        });

        let (client_end, proxy_side) = tokio::io::duplex(8192);
        let response_collector: Arc<tokio::sync::Mutex<Vec<u8>>> =
            Arc::new(tokio::sync::Mutex::new(Vec::new()));
        let collector_clone = response_collector.clone();

        tokio::spawn(async move {
            let (mut cr, mut cw) = tokio::io::split(client_end);
            cw.write_all(b"GET / HTTP/1.1\r\nHost: git.worldtree.network\r\n\r\n")
                .await
                .unwrap();
            drop(cw);
            let mut buf = Vec::new();
            let _ = tokio::io::copy(&mut cr, &mut buf).await;
            *collector_clone.lock().await = buf;
        });

        handle_connection(proxy_side, "127.0.0.1:9999".parse().unwrap(), ctx, None).await;

        // Give the collector task time to drain.
        tokio::time::sleep(Duration::from_millis(50)).await;
        let response = response_collector.lock().await.clone();
        let response_str = String::from_utf8(response).expect("utf-8");
        assert!(
            response_str.starts_with("HTTP/1.1 502 Bad Gateway"),
            "expected 502, got: {:?}",
            &response_str[..response_str.len().min(120)]
        );
        assert!(
            !response_str.contains(&dead_addr.to_string()),
            "backend address must not leak: {:?}",
            response_str
        );
    }

    /// AC 5 integration: driving `handle_connection` with SNI != Host yields 421.
    /// If the SNI enforcement branch is deleted, this test will fail because
    /// the proxy will forward instead of rejecting.
    #[tokio::test]
    async fn handle_connection_sni_host_mismatch_returns_421() {
        let cfg = loaded_with(
            vec![apex("worldtree.network", Fallthrough::None)],
            vec![route("worldtree.network", "git", "127.0.0.1:1")],
        );
        let table = Arc::new(ArcSwap::from_pointee(RouteTable::from_config(&cfg)));
        let ep = iroh::endpoint::Endpoint::builder()
            .bind()
            .await
            .expect("iroh endpoint");
        let ctx = Arc::new(AppCtx {
            ep: Arc::new(ep),
            pool: Arc::new(ConnectionPool::new(Duration::from_secs(300), 256)),
            routes: table,
            iroh_cfg: Arc::new(IrohConfig {
                connect_timeout: Duration::from_millis(200),
                response_timeout: Duration::from_secs(5),
                pool_probe_timeout: Duration::from_secs(5),
                default_port: 80,
            }),
            sites_resolver: None,
        });

        // SNI says git.worldtree.network; Host header says admin.worldtree.network.
        let sni = Some("git.worldtree.network".to_string());
        let request = b"GET / HTTP/1.1\r\nHost: admin.worldtree.network\r\n\r\n";

        let (client_end, proxy_side) = tokio::io::duplex(8192);
        let response_collector: Arc<tokio::sync::Mutex<Vec<u8>>> =
            Arc::new(tokio::sync::Mutex::new(Vec::new()));
        let collector_clone = response_collector.clone();
        tokio::spawn(async move {
            let (mut cr, mut cw) = tokio::io::split(client_end);
            cw.write_all(request).await.unwrap();
            drop(cw);
            let mut buf = Vec::new();
            let _ = tokio::io::copy(&mut cr, &mut buf).await;
            *collector_clone.lock().await = buf;
        });

        handle_connection(proxy_side, "127.0.0.1:9999".parse().unwrap(), ctx, sni).await;

        tokio::time::sleep(Duration::from_millis(50)).await;
        let response = response_collector.lock().await.clone();
        let response_str = String::from_utf8(response).expect("utf-8");
        assert!(
            response_str.starts_with("HTTP/1.1 421 Misdirected Request"),
            "expected 421, got: {:?}",
            &response_str[..response_str.len().min(120)]
        );
    }
}

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
use clap::{Parser, Subcommand};
use dashmap::DashMap;
use iroh::endpoint::{Connection, Endpoint};
use iroh::{EndpointAddr, PublicKey};
use mjolnir_gateway::acme::{AcmeConfig, IssuedCert};
use mjolnir_gateway::cloudflare::CloudflareClient;
use mjolnir_gateway::config::{self, Apex, Fallthrough, SitesResolver};
use mjolnir_gateway::route::RouteTable;
use mjolnir_gateway::sites::{self as sites_mod, LookupResult};
use mjolnir_gateway::sites_serve;
use mjolnir_gateway::tls::{
    build_certified_key, load_server_config_with_sni, CertEntryRuntime, SniCertResolver, TlsError,
};
use mjolnir_protocol::TCP_FWD_ALPN;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use tracing::{debug, error, info, warn};

// ── TlsState (unchanged) ─────────────────────────────────────────────────────

/// Hot-reloadable TLS server configuration. The `ServerConfig` (built once with
/// an [`SniCertResolver`] as its cert resolver) is stored in an `ArcSwap` so the
/// acceptor always sees a live handle; cert selection — primary (ACME/static)
/// plus per-host bring-your-own certs — is owned by the persistent `sni`
/// resolver, which supports atomic hot-swap without pausing in-flight
/// connections.
struct TlsState {
    config: ArcSwap<rustls::ServerConfig>,
    sni: Arc<SniCertResolver>,
    cert_path: PathBuf,
    key_path: PathBuf,
    not_after: std::sync::RwLock<SystemTime>,
}

impl TlsState {
    /// Static-cert path: read PEM files, build the SNI-backed ServerConfig.
    fn load(
        cert_path: PathBuf,
        key_path: PathBuf,
        session_cache: usize,
        fail_within: Duration,
    ) -> Result<Arc<Self>, TlsError> {
        let chain_pem = std::fs::read(&cert_path)?;
        let key_pem = std::fs::read(&key_path)?;
        let (_key, not_after) = build_certified_key(&chain_pem, &key_pem)?;
        let (server_config, sni) = load_server_config_with_sni(
            &chain_pem,
            &key_pem,
            HashMap::new(),
            session_cache,
            fail_within,
        )?;
        Ok(Arc::new(Self {
            config: ArcSwap::from(server_config),
            sni,
            cert_path,
            key_path,
            not_after: std::sync::RwLock::new(not_after),
        }))
    }

    /// ACME / in-memory path: build the SNI-backed ServerConfig from PEM bytes.
    fn from_pem_bytes(
        chain_pem: &[u8],
        key_pem: &[u8],
        session_cache: usize,
        fail_within: Duration,
        not_after: SystemTime,
    ) -> Result<Arc<Self>, TlsError> {
        let (server_config, sni) = load_server_config_with_sni(
            chain_pem,
            key_pem,
            HashMap::new(),
            session_cache,
            fail_within,
        )?;
        Ok(Arc::new(Self {
            config: ArcSwap::from(server_config),
            sni,
            cert_path: PathBuf::new(),
            key_path: PathBuf::new(),
            not_after: std::sync::RwLock::new(not_after),
        }))
    }

    /// Re-read the static cert from disk and swap the PRIMARY cert in the
    /// persistent SNI resolver. Extra (BYO) certs are untouched.
    fn reload(&self) -> Result<(), TlsError> {
        let chain_pem = match std::fs::read(&self.cert_path) {
            Ok(b) => b,
            Err(e) => {
                let e = TlsError::Io(e);
                warn!(event = "cert.reload_failed", error = %e, "TLS reload failed — keeping previous certificate");
                return Err(e);
            }
        };
        let key_pem = match std::fs::read(&self.key_path) {
            Ok(b) => b,
            Err(e) => {
                let e = TlsError::Io(e);
                warn!(event = "cert.reload_failed", error = %e, "TLS reload failed — keeping previous certificate");
                return Err(e);
            }
        };
        match build_certified_key(&chain_pem, &key_pem) {
            Ok((key, new_not_after)) => {
                self.sni.swap_primary(key, new_not_after);
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

    /// Swap the PRIMARY cert from in-memory PEM (ACME renewal). The persistent
    /// SNI resolver instance is kept, so extra certs survive the renewal.
    fn swap_from_pem(
        &self,
        chain_pem: &[u8],
        key_pem: &[u8],
        new_not_after: SystemTime,
    ) -> Result<(), TlsError> {
        let (key, _not_after) = build_certified_key(chain_pem, key_pem)?;
        self.sni.swap_primary(key, new_not_after);
        if let Ok(mut guard) = self.not_after.write() {
            *guard = new_not_after;
        }
        Ok(())
    }

    /// Replace the per-host bring-your-own cert map (SIGHUP hot-load).
    fn swap_extra_certs(&self, map: HashMap<String, CertEntryRuntime>) {
        self.sni.swap_extra(map);
    }

    fn current_not_after(&self) -> SystemTime {
        self.not_after
            .read()
            .map(|g| *g)
            .unwrap_or(SystemTime::UNIX_EPOCH)
    }

    fn acceptor(&self) -> tokio_rustls::TlsAcceptor {
        tokio_rustls::TlsAcceptor::from(self.config.load_full())
    }
}

/// Build the runtime BYO-cert map from `extra_certs`. Reads each cert+key file
/// and parses it; WARN-and-skips any entry whose files are missing or fail to
/// parse so a bad drop-in never crashes startup or a reload.
fn build_extra_cert_map(
    extra_certs: &[mjolnir_gateway::config::CertEntry],
) -> HashMap<String, CertEntryRuntime> {
    let mut map = HashMap::new();
    for entry in extra_certs {
        let chain_pem = match std::fs::read(&entry.cert_path) {
            Ok(b) => b,
            Err(e) => {
                warn!(
                    event = "cert.sni_skip",
                    host = %entry.host,
                    path = %entry.cert_path.display(),
                    error = %e,
                    "BYO cert file unreadable — skipping"
                );
                continue;
            }
        };
        let key_pem = match std::fs::read(&entry.key_path) {
            Ok(b) => b,
            Err(e) => {
                warn!(
                    event = "cert.sni_skip",
                    host = %entry.host,
                    path = %entry.key_path.display(),
                    error = %e,
                    "BYO key file unreadable — skipping"
                );
                continue;
            }
        };
        match build_certified_key(&chain_pem, &key_pem) {
            Ok((key, not_after)) => {
                map.insert(entry.host.clone(), CertEntryRuntime { key, not_after });
            }
            Err(e) => {
                warn!(
                    event = "cert.sni_skip",
                    host = %entry.host,
                    error = %e,
                    "BYO cert/key failed to parse — skipping"
                );
            }
        }
    }
    map
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
            // Cache-aware: reuse a still-valid cert covering the current SAN set
            // instead of re-requesting from Let's Encrypt on every tick.
            match mjolnir_gateway::acme::load_or_issue(&cfg_snapshot, &acme.cf).await {
                Ok(new_cert) => {
                    if let Err(e) = state.swap_from_pem(
                        new_cert.chain_pem.as_bytes(),
                        new_cert.key_pem.as_bytes(),
                        new_cert.not_after,
                    ) {
                        error!("acme.swap_failed: {}", e);
                    } else {
                        info!(
                            "acme.renewed: new fingerprint {}",
                            new_cert.fingerprint_sha256
                        );
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
            ProxyError::PoolStale => write!(
                f,
                "Pooled VM connection was silently dead; retrying with fresh"
            ),
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
    let key_bytes: [u8; 32] = bytes.try_into().map_err(|v: Vec<u8>| {
        ProxyError::InvalidTicket(format!("expected 32 bytes, got {}", v.len()))
    })?;
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
    // `read_until_headers` returns whatever the socket handed us, which is the
    // header block PLUS however much of the request BODY arrived in the same
    // read. Decoding the whole buffer as UTF-8 therefore fails for any binary
    // upload — a gzipped tarball starts `1f 8b`, and 0x8b is an invalid
    // continuation byte — and the caller turns that None into a 400
    // "Missing Host header" even though the Host header was perfectly fine.
    //
    // That broke `mj deploy` (gzip tarball) and any raw-binary POST to
    // /api/sites over the gateway, while leaving GETs and text bodies working,
    // which made it look like a size or auth problem rather than an encoding
    // one. Cut at the header terminator first, then decode lossily: headers are
    // ASCII, so a stray byte should degrade one line, never fail the request.
    let end = header_bytes
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4)
        .unwrap_or(header_bytes.len());

    let header_str = String::from_utf8_lossy(&header_bytes[..end]);

    for line in header_str.split("\r\n") {
        let bytes = line.as_bytes();
        // Compare as bytes: after a lossy decode a line may contain multi-byte
        // replacement chars, and slicing a &str by byte index can panic on a
        // char boundary. If the first five bytes are ASCII "host:", index 5 is
        // guaranteed to be a boundary.
        if bytes.len() > 5 && bytes[..5].eq_ignore_ascii_case(b"host:") {
            return Some(line[5..].trim().to_string());
        }
    }
    None
}

/// Strip `:port` suffix from a Host value.
fn host_without_port(host: &str) -> &str {
    host.split(':').next().unwrap_or(host)
}

const HTTP01_PATH: &str = "/.well-known/acme-challenge/";

/// Token from `GET|HEAD /.well-known/acme-challenge/<token>`. `None` if this
/// request is not an HTTP-01 challenge (proxy as usual).
fn extract_acme_http01_token(header_bytes: &[u8]) -> Option<String> {
    let end = header_bytes
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4)
        .unwrap_or(header_bytes.len());
    let headers = String::from_utf8_lossy(&header_bytes[..end]);
    let first = headers.split("\r\n").next()?;
    let mut parts = first.split_whitespace();
    let method = parts.next()?;
    if !method.eq_ignore_ascii_case("GET") && !method.eq_ignore_ascii_case("HEAD") {
        return None;
    }
    let path = parts.next()?;
    let rest = path.strip_prefix(HTTP01_PATH)?;
    let token = rest.split('?').next().unwrap_or(rest);
    if token.is_empty() || token.len() > 128 {
        return None;
    }
    if !token
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return None;
    }
    Some(token.to_string())
}

fn http01_dir() -> std::path::PathBuf {
    std::env::var("MJOLNIR_HTTP01_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("/var/lib/mjolnir-gateway/http-01"))
}

/// If this is an HTTP-01 GET/HEAD, answer from `MJOLNIR_HTTP01_DIR` and do
/// not proxy. Missing token → 404 (do not leak to the guest).
fn try_serve_http01(header_bytes: &[u8]) -> Option<Vec<u8>> {
    let token = extract_acme_http01_token(header_bytes)?;
    let path = http01_dir().join(&token);
    let (status, body) = match std::fs::read(&path) {
        Ok(b) => ("200 OK", b),
        Err(_) => ("404 Not Found", Vec::new()),
    };
    let first = String::from_utf8_lossy(header_bytes);
    let method = first.split_whitespace().next().unwrap_or("GET");
    let omit_body = method.eq_ignore_ascii_case("HEAD");
    let mut out = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    if !omit_body {
        out.extend_from_slice(&body);
    }
    Some(out)
}

// ── Routing disposition ──────────────────────────────────────────────────────

/// Outcome of Host → route resolution *before* any network work.
enum Disposition<'a> {
    /// Local TCP backend. The trailing `Option<String>` is the retained Iroh
    /// fallback target (`<node>[-<port>]`) when this route shadowed an alias —
    /// used for self-healing failover if the local dial fails (Phase 3).
    Local(&'a Apex, String, SocketAddr, Option<String>),
    Iroh(&'a Apex, String),
    Reject(ProxyError),
}

fn classify<'a>(table: &'a RouteTable, host: &str) -> Disposition<'a> {
    let host_bare = host_without_port(host);
    let Some((apex, subdomain)) = table.match_host(host_bare) else {
        return Disposition::Reject(ProxyError::DomainMismatch);
    };
    if subdomain.is_empty() {
        // Bare apex host (Host == apex). A local [[route]] declared with an
        // empty subdomain serves the apex directly, exactly like a subdomain
        // route; only if no such route exists is the bare apex out of scope
        // (the Iroh/alias paths require a non-empty subdomain).
        if let Some(backend) = table.lookup_local(apex, &subdomain) {
            let fallback = table.lookup_local_fallback(apex, &subdomain);
            return Disposition::Local(apex, subdomain, backend, fallback);
        }
        return Disposition::Reject(ProxyError::EmptySubdomain);
    }
    if let Some(backend) = table.lookup_local(apex, &subdomain) {
        let fallback = table.lookup_local_fallback(apex, &subdomain);
        return Disposition::Local(apex, subdomain, backend, fallback);
    }
    // Vanity alias: a friendly subdomain pinned to an Iroh node ID. Resolves
    // regardless of the apex's fallthrough mode (so a `none` apex can still
    // serve declared aliases) and reuses the Iroh path via a synthetic
    // `<node>[-<port>]` subdomain.
    if let Some(target) = table.lookup_alias(apex, &subdomain) {
        return Disposition::Iroh(apex, target);
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
            let new_conn =
                tokio::time::timeout(cfg.connect_timeout, ep.connect(addr.clone(), TCP_FWD_ALPN))
                    .await
                    .map_err(|_| ProxyError::ConnectTimeout)?
                    .map_err(|e| ProxyError::ConnectError(e.to_string()))?;
            pool.insert(pubkey, new_conn.clone());
            (new_conn, false)
        }
    } else {
        debug!("Forced fresh connect for {}", info.node_id_z32);
        let new_conn =
            tokio::time::timeout(cfg.connect_timeout, ep.connect(addr.clone(), TCP_FWD_ALPN))
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
            debug!(
                "Stale connection for {}, reconnecting: {}",
                info.node_id_z32, e
            );
            let addr = resolve_ticket(&info.node_id_z32)?;
            let new_conn =
                tokio::time::timeout(cfg.connect_timeout, ep.connect(addr, TCP_FWD_ALPN))
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
async fn dial_local(
    backend: SocketAddr,
    connect_timeout: Duration,
) -> Result<tokio::net::TcpStream, ProxyError> {
    tokio::time::timeout(connect_timeout, tokio::net::TcpStream::connect(backend))
        .await
        .map_err(|_| {
            ProxyError::LocalBackendUnreachable(format!("connect timeout to {}", backend))
        })?
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
async fn handle_connection<S>(
    mut stream: S,
    peer: SocketAddr,
    ctx: Arc<AppCtx>,
    sni_hostname: Option<String>,
) where
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

    // HTTP-01 must win before classify/proxy. LE follows a customer CNAME
    // to this :80 with Host=<their apex>; vite must never see the challenge.
    if let Some(resp) = try_serve_http01(&header_buf) {
        let _ = stream.write_all(&resp).await;
        let _ = stream.shutdown().await;
        return;
    }

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
        Disposition::Local(apex, subdomain, backend, fallback) => {
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
                    // Phase 3: self-healing failover. If this route retained an
                    // Iroh node from a shadowed alias, serve over the overlay
                    // instead of returning 502 — makes a stale local route
                    // non-fatal.
                    if let Some(target) = fallback {
                        info!(
                            peer = %peer,
                            apex = %apex.suffix,
                            subdomain = %subdomain,
                            route = "iroh-fallback",
                            "local backend unreachable — failing over to retained Iroh alias"
                        );
                        handle_iroh_connection(stream, peer, ctx.clone(), target, header_buf).await;
                    } else {
                        write_error_and_shutdown(&mut stream, &e).await;
                    }
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
        Disposition::Reject(
            ref
            e @ (ProxyError::DomainMismatch | ProxyError::EmptySubdomain | ProxyError::NotFound),
        ) => {
            // Nothing in the loaded config serves this Host. Three distinct ways
            // to get here, and a Sites alias can legitimately cover all of them:
            //   - DomainMismatch:  no declared apex matched at all
            //   - EmptySubdomain:  Host IS a declared apex, but no [[route]]
            //                      claims the bare apex (serving an apex like
            //                      `worldtree.network` itself from Sites)
            //   - NotFound:        declared apex, fallthrough="none", and no
            //                      route/alias matched the subdomain
            // Consult the resolver before falling through. On Miss/Error we emit
            // the SAME status this arm would have produced anyway (`e` is
            // preserved), so widening the match cannot change any response that
            // isn't a Sites hit.
            if let Some(ref resolver) = ctx.sites_resolver {
                // HTTP hostnames are case-insensitive; the Mjolnir-side index
                // is keyed on lowercase fqdn, so normalise here before lookup.
                let host_bare_owned = host_without_port(&host).to_ascii_lowercase();
                let host_bare = host_bare_owned.as_str();
                match sites_mod::lookup(resolver, host_bare).await {
                    LookupResult::Hit(backend, site) => {
                        // Preferred path: serve the materialized plaintext
                        // snapshot straight off disk. Only when it isn't there
                        // (published before materialization existed, or a
                        // publish is mid-flight) do we forward to Mjolnir and
                        // let it decrypt per request.
                        let current = site.current_dir(&resolver.sites_root);
                        if let Some(dir) =
                            sites_serve::resolve_snapshot_dir(&resolver.sites_root, &current).await
                        {
                            info!(
                                peer = %peer,
                                host = %host_bare,
                                route = "sites-static",
                                dir = %dir.display(),
                                "sites alias hit — serving materialized snapshot"
                            );
                            sites_serve::serve_connection(
                                stream,
                                header_buf,
                                dir,
                                host_bare.to_owned(),
                            )
                            .await;
                            return;
                        }
                        debug!(
                            peer = %peer,
                            host = %host_bare,
                            path = %current.display(),
                            "no materialized snapshot — falling back to mjolnir backend"
                        );
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
        match setup_iroh_proxy(
            &subdomain,
            hdrs,
            &ctx.ep,
            &ctx.pool,
            &ctx.iroh_cfg,
            force_fresh,
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

// ── CLI ──────────────────────────────────────────────────────────────────────

/// Mjolnir web gateway. With no subcommand, runs the reverse-proxy server.
#[derive(Debug, Parser)]
#[command(name = "mjolnir-gateway", version)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Certificate management (HTTP-01 issuance; `--manual` for DNS-01 TXT).
    Cert {
        #[command(subcommand)]
        command: CertCommands,
    },
}

#[derive(Debug, Subcommand)]
enum CertCommands {
    /// Issue a certificate. Default is HTTP-01 (name must already reach this
    /// gateway). `--manual` runs ACME DNS-01, prints the required TXT records,
    /// and waits for the operator to add them (no Cloudflare token needed).
    Issue {
        /// Manual DNS-01: print TXT records and wait for operator confirmation.
        #[arg(long)]
        manual: bool,
        /// Domain (SAN). Repeat for multiple: `--domain a --domain b`.
        #[arg(long = "domain")]
        domains: Vec<String>,
        /// ACME account contact email.
        #[arg(long)]
        email: String,
        /// Output directory for fullchain.pem + privkey.pem (and ACME state).
        #[arg(long)]
        out: PathBuf,
        /// Use Let's Encrypt staging directory.
        #[arg(long)]
        staging: bool,
        /// HTTP-01 webroot. The running daemon serves this dir; the one-shot
        /// issuer plants challenge files here. Ignored with `--manual`.
        #[arg(long, default_value = "/var/lib/mjolnir-gateway/http-01")]
        http01_dir: PathBuf,
    },
}

/// HTTP-01 cannot prove `*.example.com`. Refuse before we talk to LE.
fn reject_http01_wildcards(domains: &[String]) -> Result<(), String> {
    if domains.iter().any(|d| d.starts_with("*.")) {
        Err("HTTP-01 cannot issue wildcards (v1); use --manual for DNS-01 TXT".into())
    } else {
        Ok(())
    }
}

/// Run the cert-issuance subcommand. Returns without starting the server.
async fn run_cert_issue(
    manual: bool,
    domains: Vec<String>,
    email: String,
    out: PathBuf,
    staging: bool,
    http01_dir: PathBuf,
) -> Result<(), Box<dyn std::error::Error>> {
    if domains.is_empty() {
        return Err("at least one --domain is required".into());
    }
    if !manual {
        reject_http01_wildcards(&domains)?;
    }

    let directory_url = if staging {
        "https://acme-staging-v02.api.letsencrypt.org/directory".to_owned()
    } else {
        "https://acme-v02.api.letsencrypt.org/directory".to_owned()
    };

    let cfg = AcmeConfig {
        directory_url,
        email,
        domains,
        state_dir: out.clone(),
        renew_before: Duration::from_secs(30 * 24 * 3600),
    };

    let issued = if manual {
        mjolnir_gateway::acme::issue_manual(&cfg, |records| {
            use std::io::Write as _;
            let instructions = mjolnir_gateway::acme::manual_dns_instructions(records);
            eprint!("{}", instructions);
            let _ = std::io::stderr().flush();
            // Block on the operator: read (and discard) a line from stdin.
            let mut line = String::new();
            std::io::stdin().read_line(&mut line)?;
            Ok(())
        })
        .await?
    } else {
        mjolnir_gateway::acme::issue_http01(&cfg, &http01_dir).await?
    };

    let fullchain = out.join("fullchain.pem");
    let privkey = out.join("privkey.pem");
    println!("Certificate issued:");
    println!("  fullchain: {}", fullchain.display());
    println!("  privkey:   {}", privkey.display());
    println!(
        "  not_after: {}",
        humantime::format_rfc3339_seconds(issued.not_after)
    );
    Ok(())
}

// ── Main ─────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("failed to install rustls crypto provider");

    // ── CLI dispatch ──────────────────────────────────────────────────────────
    // With no subcommand, fall through to the server path (unchanged).
    let cli = Cli::parse();
    if let Some(Commands::Cert {
        command:
            CertCommands::Issue {
                manual,
                domains,
                email,
                out,
                staging,
                http01_dir,
            },
    }) = cli.command
    {
        return run_cert_issue(manual, domains, email, out, staging, http01_dir).await;
    }

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
        let base = std::env::var("STATE_DIRECTORY")
            .unwrap_or_else(|_| "/var/lib/mjolnir-gateway".to_owned());
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

    // ── Bring-your-own (SNI) certs ────────────────────────────────────────────
    // Load per-host certs and install them into the primary's SNI resolver.
    // Files missing/unparseable are warn-and-skipped so startup never crashes.
    if let Some(ref tls) = tls_state {
        let map = build_extra_cert_map(&loaded.extra_certs);
        let hosts: Vec<&String> = map.keys().collect();
        info!(
            event = "cert.sni_loaded",
            count = map.len(),
            hosts = ?hosts,
            "bring-your-own SNI certs loaded"
        );
        tls.swap_extra_certs(map);
    }

    let tls_listener: Option<TcpListener> = if let Some(addr) = loaded.listen_tls {
        let l = TcpListener::bind(addr).await?;
        info!("TLS listener on {}", addr);
        Some(l)
    } else {
        None
    };

    // ── Iroh endpoint + pool ──────────────────────────────────────────────────
    info!("Starting Iroh endpoint...");
    let endpoint = Endpoint::builder(iroh::endpoint::presets::N0)
        .bind()
        .await?;
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
                if new_loaded.listen != initial_listen
                    || new_loaded.listen_tls != initial_listen_tls
                {
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
                    apex_count, route_count, "route table swapped"
                );

                // Step 3b: rebuild + hot-swap the bring-your-own (SNI) cert map.
                // Dropping in a new cert file + SIGHUP hot-loads it.
                if let Some(tls) = tls_state.as_ref() {
                    let map = build_extra_cert_map(&new_loaded.extra_certs);
                    let hosts: Vec<&String> = map.keys().collect();
                    info!(
                        event = "cert.sni_reloaded",
                        count = map.len(),
                        hosts = ?hosts,
                        "bring-your-own SNI certs reloaded"
                    );
                    tls.swap_extra_certs(map);
                }

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
                            // Route through the cache-aware path: reuse a still-valid
                            // cert that already covers the (possibly-changed) SAN set,
                            // and only hit Let's Encrypt when the cert is missing, near
                            // expiry, or the SAN set changed. Prevents duplicate-cert
                            // rate-limit churn from repeated SIGHUP reloads.
                            match mjolnir_gateway::acme::load_or_issue(&snapshot, &acme_clone.cf)
                                .await
                            {
                                Ok(cert) => {
                                    if let Err(e) = tls_clone.swap_from_pem(
                                        cert.chain_pem.as_bytes(),
                                        cert.key_pem.as_bytes(),
                                        cert.not_after,
                                    ) {
                                        error!("SIGHUP acme.swap_failed: {}", e);
                                    } else {
                                        info!(
                                            "SIGHUP acme.renewed: fingerprint {}",
                                            cert.fingerprint_sha256
                                        );
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
    use mjolnir_gateway::config::{Alias, Apex, Fallthrough, LoadedConfig, Route};

    // ── extract_host: binary request bodies ──────────────────────────────────
    //
    // read_until_headers hands us the header block plus whatever of the BODY
    // shared the same read. These guard the regression where decoding that
    // whole buffer as UTF-8 failed on binary uploads and surfaced as a 400
    // "Missing Host header" — which broke `mj deploy` entirely.

    fn req_with_body(body: &[u8]) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(b"POST /api/deploy HTTP/1.1\r\nHost: api.vm.worldtree.network\r\n");
        v.extend_from_slice(b"Content-Type: application/octet-stream\r\n\r\n");
        v.extend_from_slice(body);
        v
    }

    #[test]
    fn extract_host_handles_a_gzip_body_in_the_same_read() {
        // 1f 8b is gzip's magic; 0x8b alone is an invalid UTF-8 continuation.
        let req = req_with_body(&[0x1f, 0x8b, 0x08, 0x00, 0xff, 0xfe, 0x00, 0x42]);
        assert_eq!(
            extract_host(&req).as_deref(),
            Some("api.vm.worldtree.network")
        );
    }

    #[test]
    fn extract_host_handles_arbitrary_binary_bodies() {
        let body: Vec<u8> = (0u16..=255).map(|b| b as u8).collect();
        assert_eq!(
            extract_host(&req_with_body(&body)).as_deref(),
            Some("api.vm.worldtree.network")
        );
    }

    #[test]
    fn extract_host_ignores_a_host_line_inside_the_body() {
        // Only the header block is parsed, so a body that happens to contain a
        // Host: line cannot spoof routing.
        let req = req_with_body(b"Host: evil.example.com\r\n");
        assert_eq!(
            extract_host(&req).as_deref(),
            Some("api.vm.worldtree.network")
        );
    }

    #[test]
    fn extract_host_still_works_for_a_plain_bodyless_request() {
        let req = b"GET / HTTP/1.1\r\nHost: zine.identikey.io\r\n\r\n";
        assert_eq!(extract_host(req).as_deref(), Some("zine.identikey.io"));
    }

    #[test]
    fn extract_host_is_case_insensitive_and_trims() {
        let req = b"GET / HTTP/1.1\r\nhOsT:   example.com  \r\n\r\n";
        assert_eq!(extract_host(req).as_deref(), Some("example.com"));
    }

    #[test]
    fn extract_host_returns_none_when_genuinely_absent() {
        let req = b"GET / HTTP/1.1\r\nUser-Agent: x\r\n\r\n";
        assert_eq!(extract_host(req), None);
    }

    #[test]
    fn extract_acme_http01_token_from_get() {
        let req =
            b"GET /.well-known/acme-challenge/Ab_12-x HTTP/1.1\r\nHost: taskmaster.dev\r\n\r\n";
        assert_eq!(extract_acme_http01_token(req).as_deref(), Some("Ab_12-x"));
    }

    #[test]
    fn extract_acme_http01_token_rejects_path_escape() {
        let req = b"GET /.well-known/acme-challenge/../etc/passwd HTTP/1.1\r\nHost: x\r\n\r\n";
        assert_eq!(extract_acme_http01_token(req), None);
    }

    #[test]
    fn extract_acme_http01_token_ignores_normal_gets() {
        let req = b"GET / HTTP/1.1\r\nHost: taskmaster.dev\r\n\r\n";
        assert_eq!(extract_acme_http01_token(req), None);
    }

    #[test]
    fn reject_http01_wildcards_refuses_star_dot() {
        assert!(reject_http01_wildcards(&["taskmaster.dev".into()]).is_ok());
        assert!(reject_http01_wildcards(&["*.taskmaster.dev".into()]).is_err());
        assert!(reject_http01_wildcards(&["a.dev".into(), "*.b.dev".into()]).is_err());
    }

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
            aliases: Vec::new(),
            extra_certs: Vec::new(),
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
        let secret = iroh::SecretKey::generate();
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

        let tls_state = TlsState::load(
            cert_path.clone(),
            key_path.clone(),
            128,
            Duration::from_secs(86400),
        )
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

        let state = TlsState::load(cert_path, key_path, 128, Duration::from_secs(60))
            .expect("TlsState::load");

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

        let state = TlsState::load(cert_path, key_path, 128, Duration::from_secs(60))
            .expect("TlsState::load");

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
            fallback_node: None,
            fallback_port: None,
        }
    }

    /// Like `route` but with a retained Iroh fallback (a shadowed alias).
    fn route_with_fallback(
        apex: &str,
        sub: &str,
        backend: &str,
        node: &str,
        port: Option<u16>,
    ) -> Route {
        Route {
            apex: apex.to_owned(),
            subdomain: sub.to_owned(),
            backend: backend.parse().unwrap(),
            fallback_node: Some(node.to_owned()),
            fallback_port: port,
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
        assert!(matches!(d, Disposition::Local(_, _, _, _)));

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
        assert!(matches!(d, Disposition::Local(_, _, _, _)));

        // Unpinned → 404 (NotFound)
        let d = classify(&table, "unknown.worldtree.network");
        assert!(matches!(d, Disposition::Reject(ProxyError::NotFound)));
    }

    #[test]
    fn alias_resolves_under_fallthrough_none() {
        // The motivating case: `zine.identikey.io` on a `none` apex with no
        // local route. The alias must short-circuit the 404 and produce an
        // Iroh disposition carrying the synthetic `<node>-<port>` subdomain.
        const NODE: &str = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u";
        let mut cfg = loaded_with(vec![apex("identikey.io", Fallthrough::None)], vec![]);
        cfg.aliases = vec![Alias {
            apex: "identikey.io".into(),
            subdomain: "zine".into(),
            node_z32: NODE.into(),
            port: Some(3000),
        }];
        let table = RouteTable::from_config(&cfg);

        match classify(&table, "zine.identikey.io") {
            Disposition::Iroh(a, sub) => {
                assert_eq!(a.suffix, "identikey.io");
                assert_eq!(sub, format!("{NODE}-3000"));
            }
            _ => panic!("expected Iroh disposition from alias hit"),
        }

        // A non-aliased subdomain on the same `none` apex still 404s.
        assert!(matches!(
            classify(&table, "other.identikey.io"),
            Disposition::Reject(ProxyError::NotFound)
        ));
    }

    #[test]
    fn local_disposition_carries_retained_iroh_fallback() {
        // Phase 3: a route that shadowed an alias classifies as Local AND carries
        // the synthetic `<node>-<port>` fallback target for failover.
        const NODE: &str = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u";
        let cfg = loaded_with(
            vec![apex("identikey.io", Fallthrough::None)],
            vec![route_with_fallback(
                "identikey.io",
                "zine",
                "10.0.0.5:3000",
                NODE,
                Some(3000),
            )],
        );
        let table = RouteTable::from_config(&cfg);
        match classify(&table, "zine.identikey.io") {
            Disposition::Local(a, sub, _backend, fallback) => {
                assert_eq!(a.suffix, "identikey.io");
                assert_eq!(sub, "zine");
                assert_eq!(fallback.as_deref(), Some(format!("{NODE}-3000").as_str()));
            }
            _ => panic!("expected Local disposition with fallback"),
        }
    }

    #[test]
    fn local_disposition_without_alias_has_no_fallback() {
        let cfg = loaded_with(
            vec![apex("worldtree.network", Fallthrough::None)],
            vec![route("worldtree.network", "git", "127.0.0.1:3000")],
        );
        let table = RouteTable::from_config(&cfg);
        match classify(&table, "git.worldtree.network") {
            Disposition::Local(_, _, _, fallback) => assert!(fallback.is_none()),
            _ => panic!("expected Local disposition"),
        }
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
    fn bare_apex_with_apex_route_classifies_local() {
        // A bare apex host served by a matching apex-level route (subdomain="")
        // classifies as Local → its backend, exactly like a subdomain route.
        let cfg = loaded_with(
            vec![apex("startupcentral.build", Fallthrough::None)],
            vec![route("startupcentral.build", "", "127.0.0.1:3000")],
        );
        let table = RouteTable::from_config(&cfg);
        match classify(&table, "startupcentral.build") {
            Disposition::Local(a, sub, backend, fallback) => {
                assert_eq!(a.suffix, "startupcentral.build");
                assert_eq!(sub, "");
                assert_eq!(backend, "127.0.0.1:3000".parse().unwrap());
                assert!(fallback.is_none());
            }
            _ => panic!("expected Local disposition for bare apex with apex route"),
        }
    }

    #[test]
    fn bare_apex_without_apex_route_still_returns_400() {
        // Bare apex host with NO apex route falls through to EmptySubdomain,
        // even when the apex is iroh-fallthrough (the Iroh path needs a subdomain).
        let cfg = loaded_with(
            vec![apex("startupcentral.build", Fallthrough::Iroh)],
            vec![route("startupcentral.build", "git", "127.0.0.1:3000")],
        );
        let table = RouteTable::from_config(&cfg);
        let d = classify(&table, "startupcentral.build");
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
                let _ = s
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                    .await;
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

        assert!(
            got_str.contains("Host: git.worldtree.network"),
            "original Host must reach backend, got: {:?}",
            got_str
        );
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
            other => panic!(
                "expected Reject(NotFound), got variant that is not: {:?}",
                match other {
                    Disposition::Local(_, _, _, _) => "Local",
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
        let cfg = loaded_with(
            vec![apex("vm.worldtree.network", Fallthrough::Iroh)],
            vec![],
        );
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

        let ep = iroh::endpoint::Endpoint::builder(iroh::endpoint::presets::N0)
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
        let ep = iroh::endpoint::Endpoint::builder(iroh::endpoint::presets::N0)
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

    // ── Sites: materialized static serving vs. backend fallback ───────────────

    /// Build a `LoadedConfig` whose only apex is unrelated to the test host, so
    /// `classify` rejects with `DomainMismatch` and the sites resolver runs.
    fn sites_ctx(resolver: SitesResolver) -> Arc<AppCtx> {
        sites_ctx_with(
            resolver,
            vec![apex("vm.worldtree.network", Fallthrough::None)],
            vec![],
        )
    }

    /// As `sites_ctx`, but with an explicit apex/route table so a test can
    /// reproduce a real production config.
    fn sites_ctx_with(
        resolver: SitesResolver,
        apexes: Vec<Apex>,
        routes: Vec<Route>,
    ) -> Arc<AppCtx> {
        let cfg = loaded_with(apexes, routes);
        let table = Arc::new(ArcSwap::from_pointee(RouteTable::from_config(&cfg)));
        let ep = futures_block_on_endpoint();
        Arc::new(AppCtx {
            ep: Arc::new(ep),
            pool: Arc::new(ConnectionPool::new(Duration::from_secs(300), 256)),
            routes: table,
            iroh_cfg: Arc::new(IrohConfig {
                connect_timeout: Duration::from_millis(500),
                response_timeout: Duration::from_secs(5),
                pool_probe_timeout: Duration::from_secs(5),
                default_port: 80,
            }),
            sites_resolver: Some(resolver),
        })
    }

    /// The Iroh endpoint is irrelevant to the sites path but `AppCtx` requires
    /// one; bind a throwaway.
    fn futures_block_on_endpoint() -> iroh::endpoint::Endpoint {
        tokio::task::block_in_place(|| {
            tokio::runtime::Handle::current().block_on(async {
                iroh::endpoint::Endpoint::builder(iroh::endpoint::presets::N0)
                    .bind()
                    .await
                    .expect("iroh endpoint")
            })
        })
    }

    /// Drive one request through `handle_connection` and return the response.
    async fn sites_round_trip(ctx: Arc<AppCtx>, request: &'static [u8]) -> String {
        let (client_end, proxy_side) = tokio::io::duplex(65536);
        let collected: Arc<tokio::sync::Mutex<Vec<u8>>> =
            Arc::new(tokio::sync::Mutex::new(Vec::new()));
        let sink = collected.clone();
        tokio::spawn(async move {
            let (mut cr, mut cw) = tokio::io::split(client_end);
            cw.write_all(request).await.unwrap();
            let mut buf = Vec::new();
            let _ = tokio::io::copy(&mut cr, &mut buf).await;
            *sink.lock().await = buf;
        });

        handle_connection(proxy_side, "127.0.0.1:9999".parse().unwrap(), ctx, None).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        let bytes = collected.lock().await.clone();
        String::from_utf8_lossy(&bytes).into_owned()
    }

    /// Materialize `<root>/<fp>/<site>/current -> snapshots/h1` holding `index.html`.
    fn materialize(root: &std::path::Path, fp: &str, site: &str, body: &str) {
        let snap = root.join(fp).join(site).join("snapshots").join("h1");
        std::fs::create_dir_all(&snap).unwrap();
        std::fs::write(snap.join("index.html"), body).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&snap, root.join(fp).join(site).join("current")).unwrap();
    }

    /// An alias hit whose materialized snapshot exists is served off disk — the
    /// Mjolnir backend is never dialled (it points at a closed port here, so a
    /// forward would surface as a 502).
    #[tokio::test(flavor = "multi_thread")]
    async fn sites_alias_hit_serves_materialized_snapshot() {
        let mut api = mockito::Server::new_async().await;
        let _m = api
            .mock("GET", "/api/sites/aliases/lookup?host=blog.duke.io")
            .with_status(200)
            .with_body(r#"{"identikey_fp":"fp1","site_name":"mysite"}"#)
            .create_async()
            .await;

        let tmp = tempfile::tempdir().unwrap();
        materialize(tmp.path(), "fp1", "mysite", "<h1>from-disk</h1>");

        // Guaranteed-unbound backend: proves nothing was forwarded.
        let probe = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let dead = probe.local_addr().unwrap();
        drop(probe);

        let ctx = sites_ctx(SitesResolver {
            api_url: api.url(),
            backend: dead,
            sites_root: tmp.path().to_path_buf(),
        });

        let resp = sites_round_trip(
            ctx,
            b"GET / HTTP/1.1\r\nHost: blog.duke.io\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(resp.starts_with("HTTP/1.1 200 OK"), "got: {resp}");
        assert!(resp.contains("<h1>from-disk</h1>"), "got: {resp}");
        assert!(
            resp.contains("public, max-age=0, must-revalidate"),
            "got: {resp}"
        );
    }

    /// No materialized directory → the pre-existing behavior is preserved: the
    /// bytes are forwarded verbatim to the Mjolnir backend.
    #[tokio::test(flavor = "multi_thread")]
    async fn sites_alias_hit_without_materialized_dir_forwards_to_backend() {
        let mut api = mockito::Server::new_async().await;
        let _m = api
            .mock("GET", "/api/sites/aliases/lookup?host=blog.duke.io")
            .with_status(200)
            .with_body(r#"{"identikey_fp":"fp1","site_name":"notmaterialized"}"#)
            .create_async()
            .await;

        // sites_root exists but holds no snapshot for this site.
        let tmp = tempfile::tempdir().unwrap();
        materialize(tmp.path(), "fp1", "someothersite", "<h1>irrelevant</h1>");

        // Stub Mjolnir backend that answers every connection.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let backend = listener.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut sock, _)) = listener.accept().await {
                let mut buf = [0u8; 1024];
                let _ = sock.read(&mut buf).await;
                let _ = sock
                    .write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nFROM-BACKEND",
                    )
                    .await;
                let _ = sock.shutdown().await;
            }
        });

        let ctx = sites_ctx(SitesResolver {
            api_url: api.url(),
            backend,
            sites_root: tmp.path().to_path_buf(),
        });

        let resp = sites_round_trip(
            ctx,
            b"GET / HTTP/1.1\r\nHost: blog.duke.io\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(
            resp.contains("FROM-BACKEND"),
            "expected backend fallback, got: {resp}"
        );
    }

    /// Reproduces the production `worldtree.network` config exactly: the apex is
    /// DECLARED with fallthrough="none" and carries one unrelated route
    /// (`mimir` → Forgejo). A request for the BARE APEX must reach the sites
    /// resolver and be served from the materialized snapshot.
    ///
    /// Before the resolver arm was widened this returned 400 "Empty subdomain":
    /// `classify` short-circuits at main.rs:585 for an empty subdomain, which
    /// landed in the catch-all `Reject` arm and never consulted Sites.
    #[tokio::test(flavor = "multi_thread")]
    async fn bare_apex_reaches_sites_resolver_and_is_served() {
        let mut api = mockito::Server::new_async().await;
        let _m = api
            .mock("GET", "/api/sites/aliases/lookup?host=worldtree.network")
            .with_status(200)
            .with_body(r#"{"identikey_fp":"fp1","site_name":"wtnf"}"#)
            .create_async()
            .await;

        let tmp = tempfile::tempdir().unwrap();
        materialize(tmp.path(), "fp1", "wtnf", "<h1>apex-from-sites</h1>");

        let probe = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let dead = probe.local_addr().unwrap();
        drop(probe);

        let ctx = sites_ctx_with(
            SitesResolver {
                api_url: api.url(),
                backend: dead,
                sites_root: tmp.path().to_path_buf(),
            },
            vec![apex("worldtree.network", Fallthrough::None)],
            vec![route("worldtree.network", "mimir", "127.0.0.1:3000")],
        );

        let resp = sites_round_trip(
            ctx,
            b"GET / HTTP/1.1\r\nHost: worldtree.network\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(resp.starts_with("HTTP/1.1 200 OK"), "got: {resp}");
        assert!(resp.contains("<h1>apex-from-sites</h1>"), "got: {resp}");
        assert!(
            !resp.contains("Empty subdomain"),
            "bare apex must not short-circuit to 400: {resp}"
        );
    }

    /// The existing `mimir` route on the same apex must be unaffected by
    /// widening the resolver arm — a declared [[route]] still wins and never
    /// consults Sites.
    #[tokio::test(flavor = "multi_thread")]
    async fn declared_route_on_same_apex_still_wins_over_sites() {
        // Alias lookup that would answer if (wrongly) consulted.
        let mut api = mockito::Server::new_async().await;
        let _m = api
            .mock(
                "GET",
                "/api/sites/aliases/lookup?host=mimir.worldtree.network",
            )
            .with_status(200)
            .with_body(r#"{"identikey_fp":"fp1","site_name":"wtnf"}"#)
            .expect(0)
            .create_async()
            .await;

        let tmp = tempfile::tempdir().unwrap();
        materialize(tmp.path(), "fp1", "wtnf", "<h1>WRONG-sites-content</h1>");

        // Stub Forgejo.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let forgejo = listener.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut sock, _)) = listener.accept().await {
                let mut buf = [0u8; 1024];
                let _ = sock.read(&mut buf).await;
                let _ = sock
                    .write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nFORGEJO",
                    )
                    .await;
                let _ = sock.shutdown().await;
            }
        });

        let ctx = sites_ctx_with(
            SitesResolver {
                api_url: api.url(),
                backend: forgejo,
                sites_root: tmp.path().to_path_buf(),
            },
            vec![apex("worldtree.network", Fallthrough::None)],
            vec![route("worldtree.network", "mimir", &forgejo.to_string())],
        );

        let resp = sites_round_trip(
            ctx,
            b"GET / HTTP/1.1\r\nHost: mimir.worldtree.network\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(
            resp.contains("FORGEJO"),
            "declared route must still win: {resp}"
        );
        assert!(!resp.contains("WRONG-sites-content"), "got: {resp}");
        _m.assert_async().await; // resolver never consulted
    }

    /// A miss on the widened arm must still produce the ORIGINAL status, not a
    /// blanket 400/404 — proves widening changed nothing for non-Sites hosts.
    #[tokio::test(flavor = "multi_thread")]
    async fn resolver_miss_preserves_original_reject_status() {
        let mut api = mockito::Server::new_async().await;
        let _m = api
            .mock("GET", "/api/sites/aliases/lookup?host=worldtree.network")
            .with_status(404)
            .with_body(r#"{"error":"not_found"}"#)
            .create_async()
            .await;

        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path()).unwrap();

        let ctx = sites_ctx_with(
            SitesResolver {
                api_url: api.url(),
                backend: "127.0.0.1:1".parse().unwrap(),
                sites_root: tmp.path().to_path_buf(),
            },
            vec![apex("worldtree.network", Fallthrough::None)],
            vec![route("worldtree.network", "mimir", "127.0.0.1:3000")],
        );

        let resp = sites_round_trip(
            ctx,
            b"GET / HTTP/1.1\r\nHost: worldtree.network\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(
            resp.starts_with("HTTP/1.1 400 Bad Request") && resp.contains("Empty subdomain"),
            "a Sites miss on the bare apex must still yield the original 400: {resp}"
        );
    }
}

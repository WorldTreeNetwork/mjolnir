//! TOML-first configuration loader for mjolnir-gateway with env-var fallback.
//!
//! - If a TOML file exists at the resolved path (default `/etc/mjolnir/gateway.toml`,
//!   overridable via `GATEWAY_CONFIG`), TOML is authoritative and env vars are
//!   ignored (spec Decision 10, startup-only).
//! - Otherwise, fall back to the legacy env-var + clap-driven shape.
//!
//! The primary consumer type is [`LoadedConfig`] — a validated, normalized view
//! of the gateway's runtime configuration.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use thiserror::Error;
use tracing::{info, warn};

// ── Errors ────────────────────────────────────────────────────────────────────

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("I/O error reading config: {0}")]
    Io(#[from] std::io::Error),
    #[error("TOML parse error: {0}")]
    TomlParse(String),
    #[error("invalid config: {0}")]
    Invalid(String),
    #[error("invalid address {addr}: {source}")]
    InvalidAddr {
        addr: String,
        source: std::net::AddrParseError,
    },
}

// ── TOML shape (wire types) ───────────────────────────────────────────────────

/// Raw TOML file shape. Validation and normalization happen in [`LoadedConfig`].
#[derive(Debug, Deserialize, Default, Clone)]
pub struct FileConfig {
    #[serde(default)]
    pub listen: Option<String>,
    #[serde(default)]
    pub listen_tls: Option<String>,
    #[serde(default)]
    pub vm_default_port: Option<u16>,
    #[serde(default)]
    pub connect_timeout_secs: Option<u64>,
    #[serde(default)]
    pub response_timeout_secs: Option<u64>,
    #[serde(default)]
    pub pool_ttl_secs: Option<u64>,
    #[serde(default)]
    pub pool_max: Option<usize>,
    #[serde(default)]
    pub pool_probe_timeout_secs: Option<u64>,
    #[serde(default)]
    pub tls_expiry_fail_secs: Option<u64>,
    #[serde(default)]
    pub tls_session_cache: Option<usize>,

    #[serde(default)]
    pub acme: Option<AcmeSection>,
    #[serde(default)]
    pub tls: Option<TlsSection>,
    #[serde(default)]
    pub sites: Option<SitesSection>,

    #[serde(default, rename = "domain")]
    pub domains: Vec<DomainDecl>,

    #[serde(default, rename = "route")]
    pub routes: Vec<RouteDecl>,

    #[serde(default, rename = "alias")]
    pub aliases: Vec<AliasDecl>,

    #[serde(default, rename = "cert")]
    pub certs: Vec<CertDecl>,
}

impl FileConfig {
    /// True if this (drop-in) config declares anything beyond `[[route]]` /
    /// `[[alias]]` — i.e. an apex, a cert, or any server/ACME/TLS scalar. Used to
    /// enforce the drop-in security boundary.
    fn declares_non_route_alias_content(&self) -> bool {
        !self.domains.is_empty()
            || !self.certs.is_empty()
            || self.acme.is_some()
            || self.tls.is_some()
            || self.sites.is_some()
            || self.listen.is_some()
            || self.listen_tls.is_some()
            || self.vm_default_port.is_some()
            || self.connect_timeout_secs.is_some()
            || self.response_timeout_secs.is_some()
            || self.pool_ttl_secs.is_some()
            || self.pool_max.is_some()
            || self.pool_probe_timeout_secs.is_some()
            || self.tls_expiry_fail_secs.is_some()
            || self.tls_session_cache.is_some()
    }
}

#[derive(Debug, Deserialize, Default, Clone)]
pub struct AcmeSection {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub directory: Option<String>,
    #[serde(default)]
    pub renew_before_secs: Option<u64>,
    #[serde(default)]
    pub cloudflare_api_token_file: Option<PathBuf>,
    /// Optional explicit SAN list override. When set, skips auto-derivation.
    #[serde(default)]
    pub domains: Option<Vec<String>>,
}

#[derive(Debug, Deserialize, Default, Clone)]
pub struct TlsSection {
    #[serde(default)]
    pub cert: Option<PathBuf>,
    #[serde(default)]
    pub key: Option<PathBuf>,
}

#[derive(Debug, Deserialize, Default, Clone)]
pub struct SitesSection {
    #[serde(default)]
    pub mjolnir_api: Option<String>,
    #[serde(default)]
    pub mjolnir_backend: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct DomainDecl {
    pub suffix: String,
    #[serde(default)]
    pub fallthrough: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct RouteDecl {
    pub apex: String,
    pub subdomain: String,
    pub backend: String,
}

/// A vanity-subdomain → Iroh node alias as declared in TOML. Unlike a
/// `[[route]]` (which targets a local TCP backend), an `[[alias]]` pins a
/// friendly subdomain to a specific Iroh `node` ID so the request is tunneled
/// over Iroh — exactly as if the subdomain had been the raw z32 node ID.
#[derive(Debug, Deserialize, Clone)]
pub struct AliasDecl {
    pub apex: String,
    pub subdomain: String,
    /// z32-encoded Iroh node ID (the VM's stable identity, e.g. `mj info`'s ticket).
    pub node: String,
    /// Optional target port inside the VM. Omitted → gateway's `vm_default_port`.
    #[serde(default)]
    pub port: Option<u16>,
}

/// A bring-your-own TLS certificate as declared in TOML. The gateway serves
/// this cert when the TLS ClientHello's SNI exactly matches `host`, falling back
/// to the primary (ACME/static) cert otherwise. Lets an operator front a
/// hostname pointed at the gateway WITHOUT the gateway holding a Cloudflare API
/// token for that host's zone.
#[derive(Debug, Deserialize, Clone)]
pub struct CertDecl {
    pub host: String,
    pub cert: String,
    pub key: String,
}

// ── Normalized / validated view ──────────────────────────────────────────────

/// Fallthrough behavior for an apex when no explicit route matches a subdomain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fallthrough {
    /// Default — decode the subdomain as a z32 Iroh node ID.
    Iroh,
    /// Reject unmatched subdomains with 404.
    None,
}

/// A single configured apex (normalized: lowercased).
#[derive(Debug, Clone)]
pub struct Apex {
    pub suffix: String,
    pub fallthrough: Fallthrough,
}

/// A single configured local-route entry. `subdomain` is lowercased and
/// does NOT contain the apex.
#[derive(Debug, Clone)]
pub struct Route {
    pub apex: String,
    pub subdomain: String,
    pub backend: SocketAddr,
    /// If a `[[route]]` shadows an `[[alias]]` for the same `(apex, subdomain)`,
    /// the alias's Iroh node is retained here so the gateway can fail over to
    /// the global overlay when the local backend is unreachable (Phase 3).
    /// `None` when no alias was shadowed.
    pub fallback_node: Option<String>,
    /// Target port for the retained Iroh `fallback_node` (mirrors `Alias::port`).
    pub fallback_port: Option<u16>,
}

impl Route {
    /// Render the synthetic `<node>[-<port>]` subdomain for the retained Iroh
    /// fallback, ready to feed into the same Iroh proxy path an alias uses.
    /// `None` when this route has no fallback node.
    pub fn fallback_target_subdomain(&self) -> Option<String> {
        self.fallback_node.as_ref().map(|node| match self.fallback_port {
            Some(p) => format!("{}-{}", node, p),
            None => node.clone(),
        })
    }
}

/// A validated vanity-subdomain → Iroh node alias. `node_z32` has been verified
/// to decode to a 32-byte key. `subdomain`/`apex` are lowercased.
#[derive(Debug, Clone)]
pub struct Alias {
    pub apex: String,
    pub subdomain: String,
    pub node_z32: String,
    pub port: Option<u16>,
}

impl Alias {
    /// Render the synthetic subdomain string the Iroh proxy path consumes:
    /// `<node>` or `<node>-<port>`. This is fed verbatim into the same
    /// `parse_z32_subdomain` used for raw node-ID subdomains, so the entire
    /// dial/pool/forward machinery is reused unchanged.
    pub fn target_subdomain(&self) -> String {
        match self.port {
            Some(p) => format!("{}-{}", self.node_z32, p),
            None => self.node_z32.clone(),
        }
    }
}

/// A validated bring-your-own cert entry. `host` is lowercased; paths are not
/// required to exist at parse time (files may be dropped in before a SIGHUP).
#[derive(Debug, Clone)]
pub struct CertEntry {
    pub host: String,
    pub cert_path: PathBuf,
    pub key_path: PathBuf,
}

/// ACME configuration in a normalized, ready-to-use shape.
#[derive(Debug, Clone)]
pub struct AcmeSettings {
    pub enabled: bool,
    pub email: String,
    pub directory: String,
    pub renew_before_secs: u64,
    pub cloudflare_api_token_file: Option<PathBuf>,
    /// Explicit SAN override, if the user set `[acme].domains`. Otherwise the
    /// SAN list is auto-derived from the apex/route list (see [`derive_san_list`]).
    pub explicit_domains: Option<Vec<String>>,
}

/// Validated sites-alias resolver config. Present only when both `mjolnir_api`
/// and `mjolnir_backend` are set in the `[sites]` section.
#[derive(Debug, Clone)]
pub struct SitesResolver {
    /// Base URL of Mjolnir's HTTP API, e.g. `"http://127.0.0.1:4000"`.
    pub api_url: String,
    /// TCP address to forward bytes to on an alias hit.
    pub backend: SocketAddr,
}

/// Fully-validated runtime config consumed by `main.rs`.
#[derive(Debug, Clone)]
pub struct LoadedConfig {
    pub source: ConfigSource,
    pub listen: Option<SocketAddr>,
    pub listen_tls: Option<SocketAddr>,
    pub vm_default_port: u16,
    pub connect_timeout_secs: u64,
    pub response_timeout_secs: u64,
    pub pool_ttl_secs: u64,
    pub pool_max: usize,
    pub pool_probe_timeout_secs: u64,
    pub tls_expiry_fail_secs: u64,
    pub tls_session_cache: usize,
    pub tls_cert_path: Option<PathBuf>,
    pub tls_key_path: Option<PathBuf>,
    pub acme: AcmeSettings,
    pub apexes: Vec<Apex>,
    pub routes: Vec<Route>,
    pub aliases: Vec<Alias>,
    pub extra_certs: Vec<CertEntry>,
    pub sites_resolver: Option<SitesResolver>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigSource {
    Toml,
    Env,
}

// ── Default path resolution ───────────────────────────────────────────────────

/// The resolved path the loader will consult at startup. Respects
/// `GATEWAY_CONFIG` if set.
pub fn resolve_config_path() -> PathBuf {
    std::env::var("GATEWAY_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/etc/mjolnir/gateway.toml"))
}

// ── Validation helpers ────────────────────────────────────────────────────────

fn is_ascii_fqdn(s: &str) -> bool {
    if s.is_empty() || s.len() > 253 {
        return false;
    }
    // No leading/trailing dots, no empty labels.
    if s.starts_with('.') || s.ends_with('.') {
        return false;
    }
    // ASCII only, letters/digits/hyphens/dots; no underscores, no wildcards.
    if !s.is_ascii() {
        return false;
    }
    for label in s.split('.') {
        if label.is_empty() || label.len() > 63 {
            return false;
        }
        // Labels cannot start or end with hyphen.
        if label.starts_with('-') || label.ends_with('-') {
            return false;
        }
        if !label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return false;
        }
    }
    true
}

fn is_ascii_label(s: &str) -> bool {
    // A bare subdomain label set (may contain dots for multi-level subdomains like "git.api").
    if s.is_empty() || s.len() > 253 {
        return false;
    }
    if s.starts_with('.') || s.ends_with('.') {
        return false;
    }
    if !s.is_ascii() {
        return false;
    }
    for label in s.split('.') {
        if label.is_empty() || label.len() > 63 {
            return false;
        }
        if label.starts_with('-') || label.ends_with('-') {
            return false;
        }
        if !label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return false;
        }
    }
    true
}

/// True if `s` is a z32 string that decodes to exactly 32 bytes — the shape of
/// an Iroh node ID / ed25519 public key. Mirrors `main.rs::resolve_ticket`'s
/// decode so a bad `[[alias]]` node is rejected at load time, not per-request.
fn is_valid_node_z32(s: &str) -> bool {
    matches!(z32::decode(s.as_bytes()), Ok(bytes) if bytes.len() == 32)
}

fn parse_fallthrough(s: Option<&str>) -> Result<Fallthrough, ConfigError> {
    match s {
        None => Ok(Fallthrough::Iroh),
        Some("iroh") => Ok(Fallthrough::Iroh),
        Some("none") => Ok(Fallthrough::None),
        Some(other) => Err(ConfigError::Invalid(format!(
            "invalid fallthrough value {:?}; must be \"iroh\" or \"none\"",
            other
        ))),
    }
}

fn parse_optional_socketaddr(s: &Option<String>) -> Result<Option<SocketAddr>, ConfigError> {
    match s {
        None => Ok(None),
        Some(v) if v.is_empty() => Ok(None),
        Some(v) => {
            let addr = v
                .parse::<SocketAddr>()
                .map_err(|e| ConfigError::InvalidAddr {
                    addr: v.clone(),
                    source: e,
                })?;
            Ok(Some(addr))
        }
    }
}

// ── SAN list auto-derivation ──────────────────────────────────────────────────

/// Derive the cert SAN list from the declared apex list + route list + alias
/// list, honoring each apex's fallthrough mode (Decision 7).
pub fn derive_san_list(apexes: &[Apex], routes: &[Route], aliases: &[Alias]) -> Vec<String> {
    fn push_unique(out: &mut Vec<String>, v: String) {
        if !out.iter().any(|e| e == &v) {
            out.push(v);
        }
    }
    let mut out: Vec<String> = Vec::new();

    for apex in apexes {
        match apex.fallthrough {
            Fallthrough::Iroh => {
                push_unique(&mut out, format!("*.{}", apex.suffix));
                push_unique(&mut out, apex.suffix.clone());
            }
            Fallthrough::None => {
                push_unique(&mut out, apex.suffix.clone());
                for r in routes.iter().filter(|r| r.apex == apex.suffix) {
                    push_unique(&mut out, format!("{}.{}", r.subdomain, apex.suffix));
                }
            }
        }
        // Aliases need an explicit SAN under any apex: a `none` apex has no
        // wildcard, and an `iroh` apex's `*.apex` wildcard only covers
        // single-label subdomains — an alias may be multi-label.
        for al in aliases.iter().filter(|al| al.apex == apex.suffix) {
            push_unique(&mut out, format!("{}.{}", al.subdomain, apex.suffix));
        }
    }

    out
}

// ── Loader entry points ───────────────────────────────────────────────────────

/// Load the gateway configuration.
///
/// If `path` exists, TOML is authoritative: the base file is parsed, then every
/// `*.toml` in the sibling drop-in directory (default `<parent>/gateway.d/`,
/// overridable via `GATEWAY_CONFIG_D`) is merged in — but drop-ins may declare
/// ONLY `[[route]]`/`[[alias]]` entries (a security boundary: they cannot add
/// apexes or change server/ACME/TLS/cert settings). Merging happens *before*
/// validation so a generated route uniformly shadows a base alias.
///
/// Otherwise the env-var fallback path is used (see [`load_from_env`]).
pub fn load(path: &Path) -> Result<LoadedConfig, ConfigError> {
    if path.exists() {
        let bytes = std::fs::read(path)?;
        let text = std::str::from_utf8(&bytes)
            .map_err(|e| ConfigError::TomlParse(format!("invalid UTF-8 in {}: {}", path.display(), e)))?;
        let mut file: FileConfig =
            toml::from_str(text).map_err(|e| ConfigError::TomlParse(e.to_string()))?;
        merge_dropins(&mut file, &config_d_dir(path));
        validate_and_normalize(file, ConfigSource::Toml)
    } else {
        load_from_env()
    }
}

/// Resolve the drop-in directory: `GATEWAY_CONFIG_D` if set, else
/// `<parent-of-base>/gateway.d/`.
fn config_d_dir(base: &Path) -> PathBuf {
    if let Ok(dir) = std::env::var("GATEWAY_CONFIG_D") {
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }
    base.parent()
        .unwrap_or_else(|| Path::new("."))
        .join("gateway.d")
}

/// Merge `[[route]]`/`[[alias]]` entries from every `*.toml` in `dir` into
/// `base`, in sorted filename order for determinism. Resilient (mirrors the
/// `[[cert]]` posture): a missing directory is a no-op, and a drop-in that fails
/// to read/parse is WARN-logged and skipped — never fatal. Any non-route/alias
/// content in a drop-in (apex, cert, server/ACME/TLS settings) is rejected with
/// a warning and ignored; only routes and aliases ever merge.
fn merge_dropins(base: &mut FileConfig, dir: &Path) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return, // missing directory = no-op
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("toml"))
        .collect();
    files.sort();

    for path in files {
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) => {
                warn!(
                    event = "config.dropin_read_error",
                    path = %path.display(),
                    error = %e,
                    "could not read gateway drop-in — skipping"
                );
                continue;
            }
        };
        let dropin: FileConfig = match toml::from_str(&text) {
            Ok(f) => f,
            Err(e) => {
                warn!(
                    event = "config.dropin_parse_error",
                    path = %path.display(),
                    error = %e,
                    "malformed gateway drop-in — skipping"
                );
                continue;
            }
        };
        // Security boundary: drop-ins must NOT declare apexes, certs, or any
        // server/ACME/TLS settings. Warn and ignore those; merge only routes/aliases.
        if dropin.declares_non_route_alias_content() {
            warn!(
                event = "config.dropin_forbidden_section",
                path = %path.display(),
                "gateway drop-in declares apex/cert/server settings — ignoring those; only [[route]]/[[alias]] are merged"
            );
        }
        let n_routes = dropin.routes.len();
        let n_aliases = dropin.aliases.len();
        base.routes.extend(dropin.routes);
        base.aliases.extend(dropin.aliases);
        info!(
            event = "config.dropin_merged",
            path = %path.display(),
            routes = n_routes,
            aliases = n_aliases,
            "merged gateway drop-in"
        );
    }
}

/// Parse and validate a TOML document string. Surfaces Decision-6 warnings via
/// the `tracing` crate.
pub fn load_from_toml_str(text: &str) -> Result<LoadedConfig, ConfigError> {
    let file: FileConfig = toml::from_str(text).map_err(|e| ConfigError::TomlParse(e.to_string()))?;
    validate_and_normalize(file, ConfigSource::Toml)
}

/// Build a `LoadedConfig` from process environment variables. Preserves the
/// pre-upgrade single-apex deployment semantics (AC 1).
pub fn load_from_env() -> Result<LoadedConfig, ConfigError> {
    // Legacy env-var shape. We read vars manually rather than via clap because
    // we're already inside the unified loader; clap is reserved for env-fallback
    // callers that still use the old argv interface.
    fn env_opt(name: &str) -> Option<String> {
        std::env::var(name).ok().filter(|v| !v.is_empty())
    }

    let domain = env_opt("GATEWAY_DOMAIN").unwrap_or_else(|| "vm.worldtree.network".to_owned());
    let listen = env_opt("GATEWAY_LISTEN").unwrap_or_else(|| "0.0.0.0:8080".to_owned());
    let tls_listen = env_opt("GATEWAY_TLS_LISTEN").unwrap_or_else(|| "0.0.0.0:443".to_owned());

    let vm_default_port: u16 = env_opt("GATEWAY_DEFAULT_PORT")
        .map(|v| v.parse().unwrap_or(80))
        .unwrap_or(80);
    let connect_timeout_secs: u64 = env_opt("GATEWAY_CONNECT_TIMEOUT")
        .map(|v| v.parse().unwrap_or(15))
        .unwrap_or(15);
    let response_timeout_secs: u64 = env_opt("GATEWAY_RESPONSE_TIMEOUT")
        .map(|v| v.parse().unwrap_or(30))
        .unwrap_or(30);
    let pool_ttl_secs: u64 = env_opt("GATEWAY_POOL_TTL")
        .map(|v| v.parse().unwrap_or(300))
        .unwrap_or(300);
    let pool_max: usize = env_opt("GATEWAY_POOL_MAX")
        .map(|v| v.parse().unwrap_or(256))
        .unwrap_or(256);
    let pool_probe_timeout_secs: u64 = env_opt("GATEWAY_POOL_PROBE_TIMEOUT")
        .map(|v| v.parse().unwrap_or(10))
        .unwrap_or(10);
    let tls_expiry_fail_secs: u64 = env_opt("GATEWAY_TLS_EXPIRY_FAIL_SECS")
        .map(|v| v.parse().unwrap_or(86400))
        .unwrap_or(86400);
    let tls_session_cache: usize = env_opt("GATEWAY_TLS_SESSION_CACHE")
        .map(|v| v.parse().unwrap_or(4096))
        .unwrap_or(4096);

    let tls_cert = env_opt("GATEWAY_TLS_CERT").map(PathBuf::from);
    let tls_key = env_opt("GATEWAY_TLS_KEY").map(PathBuf::from);

    let acme_enabled = env_opt("GATEWAY_ACME").as_deref() == Some("enabled");
    let acme_email = env_opt("GATEWAY_ACME_EMAIL").unwrap_or_default();
    let acme_directory = env_opt("GATEWAY_ACME_DIRECTORY")
        .unwrap_or_else(|| "https://acme-v02.api.letsencrypt.org/directory".to_owned());
    let acme_renew_before_secs: u64 = env_opt("GATEWAY_ACME_RENEW_BEFORE_SECS")
        .map(|v| v.parse().unwrap_or(2_592_000))
        .unwrap_or(2_592_000);
    let acme_domains_env = env_opt("GATEWAY_ACME_DOMAINS")
        .map(|v| {
            v.split(',')
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
        })
        .filter(|v: &Vec<String>| !v.is_empty());

    // Env-mode always yields exactly one apex, derived from GATEWAY_DOMAIN, with
    // Iroh fallthrough (matches pre-upgrade behavior).
    let suffix_lower = domain.to_ascii_lowercase();
    if !is_ascii_fqdn(&suffix_lower) {
        return Err(ConfigError::Invalid(format!(
            "GATEWAY_DOMAIN {:?} is not a valid FQDN",
            domain
        )));
    }
    let apexes = vec![Apex {
        suffix: suffix_lower,
        fallthrough: Fallthrough::Iroh,
    }];

    let listen = parse_optional_socketaddr(&Some(listen))?;
    let listen_tls = parse_optional_socketaddr(&Some(tls_listen))?;

    Ok(LoadedConfig {
        source: ConfigSource::Env,
        listen,
        listen_tls,
        vm_default_port,
        connect_timeout_secs,
        response_timeout_secs,
        pool_ttl_secs,
        pool_max,
        pool_probe_timeout_secs,
        tls_expiry_fail_secs,
        tls_session_cache,
        tls_cert_path: tls_cert,
        tls_key_path: tls_key,
        acme: AcmeSettings {
            enabled: acme_enabled,
            email: acme_email,
            directory: acme_directory,
            renew_before_secs: acme_renew_before_secs,
            cloudflare_api_token_file: None,
            explicit_domains: acme_domains_env,
        },
        apexes,
        routes: Vec::new(),
        aliases: Vec::new(),
        extra_certs: Vec::new(),
        sites_resolver: None,
    })
}

// ── TOML validation ───────────────────────────────────────────────────────────

fn validate_and_normalize(file: FileConfig, source: ConfigSource) -> Result<LoadedConfig, ConfigError> {
    // ── Apexes ────────────────────────────────────────────────────────────────
    if file.domains.is_empty() {
        return Err(ConfigError::Invalid(
            "empty [[domain]] list — gateway has nothing to serve".into(),
        ));
    }

    let mut apexes: Vec<Apex> = Vec::with_capacity(file.domains.len());
    for d in &file.domains {
        // Fatal: wildcard or invalid FQDN.
        if d.suffix.contains('*') {
            return Err(ConfigError::Invalid(format!(
                "[[domain]] suffix {:?} contains wildcard; use a bare FQDN (wildcards are added to the cert SAN list automatically)",
                d.suffix
            )));
        }
        let lower = d.suffix.to_ascii_lowercase();
        if !is_ascii_fqdn(&lower) {
            return Err(ConfigError::Invalid(format!(
                "[[domain]] suffix {:?} is not a valid ASCII FQDN (IDN/punycode is not supported)",
                d.suffix
            )));
        }
        let fallthrough = parse_fallthrough(d.fallthrough.as_deref())?;

        // Warn on duplicate apex; keep first.
        if apexes.iter().any(|a| a.suffix == lower) {
            warn!(
                event = "config.duplicate_apex",
                apex = %lower,
                "duplicate [[domain]] suffix — keeping first declaration"
            );
            continue;
        }

        apexes.push(Apex {
            suffix: lower,
            fallthrough,
        });
    }

    if apexes.is_empty() {
        return Err(ConfigError::Invalid(
            "no valid apexes after deduplication".into(),
        ));
    }

    // ── Routes ────────────────────────────────────────────────────────────────
    let mut routes: Vec<Route> = Vec::new();
    for r in &file.routes {
        let apex_lower = r.apex.to_ascii_lowercase();
        let sub_lower = r.subdomain.to_ascii_lowercase();

        if !apexes.iter().any(|a| a.suffix == apex_lower) {
            warn!(
                event = "config.orphan_route",
                apex = %r.apex,
                subdomain = %r.subdomain,
                "[[route]] apex does not match any [[domain]] — skipping"
            );
            continue;
        }
        // An EMPTY subdomain is a valid apex-level route: it serves the bare
        // apex host (e.g. `startupcentral.build` itself) from a local backend.
        // Only a NON-EMPTY string that isn't a valid ASCII label is rejected.
        // (Contrast [[alias]] below, which keeps rejecting empty: an alias is
        // an Iroh vanity subdomain, so an empty one is meaningless.)
        if !sub_lower.is_empty() && !is_ascii_label(&sub_lower) {
            warn!(
                event = "config.invalid_subdomain",
                apex = %apex_lower,
                subdomain = %r.subdomain,
                "[[route]] subdomain is not a valid ASCII hostname label — skipping"
            );
            continue;
        }
        let backend: SocketAddr = match r.backend.parse() {
            Ok(a) => a,
            Err(e) => {
                warn!(
                    event = "config.bad_backend",
                    apex = %apex_lower,
                    subdomain = %sub_lower,
                    backend = %r.backend,
                    error = %e,
                    "[[route]] backend is not a valid socket address — skipping"
                );
                continue;
            }
        };
        if routes
            .iter()
            .any(|existing| existing.apex == apex_lower && existing.subdomain == sub_lower)
        {
            warn!(
                event = "config.duplicate_route",
                apex = %apex_lower,
                subdomain = %sub_lower,
                "duplicate [[route]] (apex, subdomain) — keeping first declaration"
            );
            continue;
        }
        routes.push(Route {
            apex: apex_lower,
            subdomain: sub_lower,
            backend,
            fallback_node: None,
            fallback_port: None,
        });
    }

    // ── Aliases (vanity subdomain → Iroh node) ────────────────────────────────
    let mut aliases: Vec<Alias> = Vec::new();
    for a in &file.aliases {
        let apex_lower = a.apex.to_ascii_lowercase();
        let sub_lower = a.subdomain.to_ascii_lowercase();

        if !apexes.iter().any(|ap| ap.suffix == apex_lower) {
            warn!(
                event = "config.orphan_alias",
                apex = %a.apex,
                subdomain = %a.subdomain,
                "[[alias]] apex does not match any [[domain]] — skipping"
            );
            continue;
        }
        if !is_ascii_label(&sub_lower) {
            warn!(
                event = "config.invalid_alias_subdomain",
                apex = %apex_lower,
                subdomain = %a.subdomain,
                "[[alias]] subdomain is not a valid ASCII hostname label — skipping"
            );
            continue;
        }
        if !is_valid_node_z32(&a.node) {
            warn!(
                event = "config.bad_alias_node",
                apex = %apex_lower,
                subdomain = %sub_lower,
                node = %a.node,
                "[[alias]] node is not a valid z32 32-byte Iroh node ID — skipping"
            );
            continue;
        }
        // A [[route]] for the same (apex, subdomain) wins — classify() checks
        // local routes before aliases. The alias is dropped from the standalone
        // list, but its Iroh node is RETAINED on the shadowing route as a
        // fallback so the gateway can fail over to the overlay when the local
        // backend is unreachable (Phase 3).
        if let Some(route) = routes
            .iter_mut()
            .find(|r| r.apex == apex_lower && r.subdomain == sub_lower)
        {
            route.fallback_node = Some(a.node.clone());
            route.fallback_port = a.port;
            warn!(
                event = "config.alias_shadowed_by_route",
                apex = %apex_lower,
                subdomain = %sub_lower,
                "[[alias]] shadowed by a [[route]] with the same (apex, subdomain) — retaining Iroh node as route fallback"
            );
            continue;
        }
        if aliases
            .iter()
            .any(|existing| existing.apex == apex_lower && existing.subdomain == sub_lower)
        {
            warn!(
                event = "config.duplicate_alias",
                apex = %apex_lower,
                subdomain = %sub_lower,
                "duplicate [[alias]] (apex, subdomain) — keeping first declaration"
            );
            continue;
        }
        aliases.push(Alias {
            apex: apex_lower,
            subdomain: sub_lower,
            node_z32: a.node.clone(),
            port: a.port,
        });
    }

    // ── Bring-your-own certs ([[cert]]) ───────────────────────────────────────
    // Validate host (lowercased FQDN) + non-empty cert/key paths; dedup by host.
    // Files are NOT required to exist at parse time — they may be dropped in
    // before a SIGHUP. main.rs warn-and-skips any whose files are
    // missing/unparseable at load.
    let mut extra_certs: Vec<CertEntry> = Vec::new();
    for c in &file.certs {
        let host_lower = c.host.to_ascii_lowercase();
        if !is_ascii_fqdn(&host_lower) {
            warn!(
                event = "config.bad_cert_host",
                host = %c.host,
                "[[cert]] host is not a valid ASCII FQDN — skipping"
            );
            continue;
        }
        if c.cert.trim().is_empty() || c.key.trim().is_empty() {
            warn!(
                event = "config.bad_cert_paths",
                host = %host_lower,
                "[[cert]] requires non-empty cert and key paths — skipping"
            );
            continue;
        }
        if extra_certs.iter().any(|e| e.host == host_lower) {
            warn!(
                event = "config.duplicate_cert",
                host = %host_lower,
                "duplicate [[cert]] host — keeping first declaration"
            );
            continue;
        }
        extra_certs.push(CertEntry {
            host: host_lower,
            cert_path: PathBuf::from(&c.cert),
            key_path: PathBuf::from(&c.key),
        });
    }

    // ── Scalars ───────────────────────────────────────────────────────────────
    // When a TOML key is absent we disable that listener (explicit opt-in).
    // An explicit empty string also disables. The spec's sample TOML shows
    // `listen = "0.0.0.0:80"` + `listen_tls = "0.0.0.0:443"`; those are the
    // *operator's* choices, not implicit defaults.
    let listen = parse_optional_socketaddr(&file.listen)?;
    let listen_tls = parse_optional_socketaddr(&file.listen_tls)?;

    let vm_default_port = file.vm_default_port.unwrap_or(80);
    let connect_timeout_secs = file.connect_timeout_secs.unwrap_or(15);
    let response_timeout_secs = file.response_timeout_secs.unwrap_or(0);
    let pool_ttl_secs = file.pool_ttl_secs.unwrap_or(300);
    let pool_max = file.pool_max.unwrap_or(256);
    let pool_probe_timeout_secs = file.pool_probe_timeout_secs.unwrap_or(10);
    let tls_expiry_fail_secs = file.tls_expiry_fail_secs.unwrap_or(86400);
    let tls_session_cache = file.tls_session_cache.unwrap_or(4096);

    let (tls_cert_path, tls_key_path) = match file.tls {
        Some(t) => (t.cert, t.key),
        None => (None, None),
    };

    // ── ACME ──────────────────────────────────────────────────────────────────
    let acme = file.acme.unwrap_or_default();
    if acme.enabled && acme.email.as_deref().unwrap_or("").trim().is_empty() {
        return Err(ConfigError::Invalid(
            "[acme].enabled=true requires a non-empty [acme].email".into(),
        ));
    }
    if let Some(ref explicit) = acme.domains {
        for d in explicit {
            let stripped = d.strip_prefix("*.").unwrap_or(d.as_str());
            if !is_ascii_fqdn(&stripped.to_ascii_lowercase()) {
                return Err(ConfigError::Invalid(format!(
                    "[acme].domains entry {:?} is not a valid ASCII FQDN",
                    d
                )));
            }
        }
    }
    let acme_settings = AcmeSettings {
        enabled: acme.enabled,
        email: acme.email.unwrap_or_default(),
        directory: acme
            .directory
            .unwrap_or_else(|| "https://acme-v02.api.letsencrypt.org/directory".to_owned()),
        renew_before_secs: acme.renew_before_secs.unwrap_or(2_592_000),
        cloudflare_api_token_file: acme.cloudflare_api_token_file,
        explicit_domains: acme.domains,
    };

    // ── TLS listener requires a cert source ───────────────────────────────────
    if listen_tls.is_some()
        && !acme_settings.enabled
        && (tls_cert_path.is_none() || tls_key_path.is_none())
    {
        return Err(ConfigError::Invalid(
            "listen_tls is set but [acme].enabled=false and [tls].cert/[tls].key are missing \
             — either enable ACME or configure a static cert"
                .into(),
        ));
    }

    // ── Sites resolver ────────────────────────────────────────────────────────
    let sites_resolver = match file.sites {
        Some(s) => match (s.mjolnir_api, s.mjolnir_backend) {
            (Some(api_url), Some(backend_str)) => {
                let backend = backend_str.parse::<SocketAddr>().map_err(|e| {
                    ConfigError::InvalidAddr {
                        addr: backend_str.clone(),
                        source: e,
                    }
                })?;
                Some(SitesResolver { api_url, backend })
            }
            _ => None,
        },
        None => None,
    };

    info!(
        event = "config.loaded",
        source = ?source,
        apex_count = apexes.len(),
        route_count = routes.len(),
        alias_count = aliases.len(),
        acme = acme_settings.enabled,
        sites = sites_resolver.is_some(),
        "gateway config loaded"
    );

    Ok(LoadedConfig {
        source,
        listen,
        listen_tls,
        vm_default_port,
        connect_timeout_secs,
        response_timeout_secs,
        pool_ttl_secs,
        pool_max,
        pool_probe_timeout_secs,
        tls_expiry_fail_secs,
        tls_session_cache,
        tls_cert_path,
        tls_key_path,
        acme: acme_settings,
        apexes,
        routes,
        aliases,
        extra_certs,
        sites_resolver,
    })
}

impl LoadedConfig {
    /// Build the effective ACME SAN list: the explicit override if present,
    /// otherwise the auto-derived list.
    pub fn effective_acme_domains(&self) -> Vec<String> {
        if let Some(ref explicit) = self.acme.explicit_domains {
            return explicit.clone();
        }
        derive_san_list(&self.apexes, &self.routes, &self.aliases)
    }

    pub fn connect_timeout(&self) -> Duration {
        Duration::from_secs(self.connect_timeout_secs)
    }
    pub fn response_timeout(&self) -> Duration {
        Duration::from_secs(self.response_timeout_secs)
    }
    pub fn pool_ttl(&self) -> Duration {
        Duration::from_secs(self.pool_ttl_secs)
    }
    pub fn pool_probe_timeout(&self) -> Duration {
        Duration::from_secs(self.pool_probe_timeout_secs)
    }
    pub fn tls_expiry_fail(&self) -> Duration {
        Duration::from_secs(self.tls_expiry_fail_secs)
    }
    pub fn acme_renew_before(&self) -> Duration {
        Duration::from_secs(self.acme.renew_before_secs)
    }
}

/// Load the Cloudflare API token: prefer `[acme].cloudflare_api_token_file`,
/// fall back to `CLOUDFLARE_API_TOKEN`. Returns `Err` if neither is set/usable.
pub fn load_cloudflare_token(cfg: &LoadedConfig) -> Result<String, ConfigError> {
    if let Some(path) = &cfg.acme.cloudflare_api_token_file {
        let text = std::fs::read_to_string(path).map_err(|e| {
            ConfigError::Invalid(format!(
                "could not read cloudflare_api_token_file {}: {}",
                path.display(),
                e
            ))
        })?;
        let token = text.trim().to_owned();
        if token.is_empty() {
            return Err(ConfigError::Invalid(format!(
                "cloudflare_api_token_file {} is empty after trimming",
                path.display()
            )));
        }
        return Ok(token);
    }
    let token = std::env::var("CLOUDFLARE_API_TOKEN").map_err(|_| {
        ConfigError::Invalid(
            "no Cloudflare API token — set [acme].cloudflare_api_token_file or CLOUDFLARE_API_TOKEN"
                .into(),
        )
    })?;
    let token = token.trim().to_owned();
    if token.is_empty() {
        return Err(ConfigError::Invalid(
            "CLOUDFLARE_API_TOKEN is empty".into(),
        ));
    }
    Ok(token)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn toml_minimal_valid() {
        let text = r#"
            [[domain]]
            suffix = "vm.worldtree.network"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert_eq!(cfg.apexes.len(), 1);
        assert_eq!(cfg.apexes[0].suffix, "vm.worldtree.network");
        assert_eq!(cfg.apexes[0].fallthrough, Fallthrough::Iroh);
        assert!(cfg.routes.is_empty());
    }

    #[test]
    fn toml_full_valid() {
        let text = r#"
            listen = "0.0.0.0:80"
            listen_tls = "0.0.0.0:443"
            vm_default_port = 80
            connect_timeout_secs = 15

            [acme]
            enabled = true
            email = "duke@worldtree.io"
            directory = "https://acme-v02.api.letsencrypt.org/directory"
            renew_before_secs = 2592000
            cloudflare_api_token_file = "/etc/mjolnir/cloudflare-token"

            [[domain]]
            suffix = "vm.worldtree.network"
            fallthrough = "iroh"

            [[domain]]
            suffix = "worldtree.network"
            fallthrough = "none"

            [[route]]
            apex = "worldtree.network"
            subdomain = "git"
            backend = "127.0.0.1:3000"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert_eq!(cfg.apexes.len(), 2);
        assert_eq!(cfg.routes.len(), 1);
        assert_eq!(cfg.routes[0].subdomain, "git");
        assert_eq!(cfg.routes[0].apex, "worldtree.network");
        assert!(cfg.acme.enabled);
        assert_eq!(cfg.acme.email, "duke@worldtree.io");
    }

    #[test]
    fn toml_duplicate_apex_warn() {
        let text = r#"
            [[domain]]
            suffix = "a.com"
            fallthrough = "iroh"

            [[domain]]
            suffix = "a.com"
            fallthrough = "none"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert_eq!(cfg.apexes.len(), 1);
        // Kept first → iroh.
        assert_eq!(cfg.apexes[0].fallthrough, Fallthrough::Iroh);
    }

    #[test]
    fn toml_duplicate_route_warn() {
        let text = r#"
            [[domain]]
            suffix = "a.com"

            [[route]]
            apex = "a.com"
            subdomain = "git"
            backend = "127.0.0.1:3000"

            [[route]]
            apex = "a.com"
            subdomain = "git"
            backend = "127.0.0.1:3001"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert_eq!(cfg.routes.len(), 1);
        assert_eq!(cfg.routes[0].backend.port(), 3000);
    }

    #[test]
    fn toml_orphan_apex_warn() {
        let text = r#"
            [[domain]]
            suffix = "a.com"

            [[route]]
            apex = "b.com"
            subdomain = "git"
            backend = "127.0.0.1:3000"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert_eq!(cfg.apexes.len(), 1);
        assert!(cfg.routes.is_empty());
    }

    #[test]
    fn toml_bad_backend_warn() {
        let text = r#"
            [[domain]]
            suffix = "a.com"

            [[route]]
            apex = "a.com"
            subdomain = "git"
            backend = "not-an-addr"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert!(cfg.routes.is_empty(), "bad backend must be skipped");
    }

    #[test]
    fn toml_apex_route_empty_subdomain_accepted() {
        // A [[route]] with an empty subdomain is a valid apex-level route: it
        // serves the bare apex host itself from a local backend.
        let text = r#"
            [[domain]]
            suffix = "startupcentral.build"

            [[route]]
            apex = "startupcentral.build"
            subdomain = ""
            backend = "127.0.0.1:3000"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert_eq!(cfg.routes.len(), 1, "empty-subdomain apex route must be kept");
        assert_eq!(cfg.routes[0].subdomain, "");
        assert_eq!(cfg.routes[0].apex, "startupcentral.build");
        assert_eq!(cfg.routes[0].backend.port(), 3000);
    }

    #[test]
    fn toml_route_non_empty_invalid_subdomain_skipped() {
        // A NON-EMPTY subdomain that isn't a valid ASCII label is still rejected;
        // only the empty case is now accepted as an apex route.
        let text = r#"
            [[domain]]
            suffix = "a.com"

            [[route]]
            apex = "a.com"
            subdomain = "not_a_label"
            backend = "127.0.0.1:3000"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert!(cfg.routes.is_empty(), "invalid non-empty label must be skipped");
    }

    #[test]
    fn toml_wildcard_apex_fatal() {
        let text = r#"
            [[domain]]
            suffix = "*.worldtree.network"
        "#;
        let result = load_from_toml_str(text);
        assert!(matches!(result, Err(ConfigError::Invalid(_))));
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("wildcard"), "error message should mention wildcard, got: {}", msg);
    }

    #[test]
    fn toml_empty_apex_list_fatal() {
        let text = "";
        let result = load_from_toml_str(text);
        assert!(matches!(result, Err(ConfigError::Invalid(_))));
    }

    #[test]
    fn toml_parse_error_fatal() {
        let text = "this is not : valid = toml = at all";
        let result = load_from_toml_str(text);
        assert!(matches!(result, Err(ConfigError::TomlParse(_))));
    }

    #[test]
    fn toml_bad_fallthrough_fatal() {
        let text = r#"
            [[domain]]
            suffix = "a.com"
            fallthrough = "wat"
        "#;
        let result = load_from_toml_str(text);
        assert!(matches!(result, Err(ConfigError::Invalid(_))));
    }

    #[test]
    fn toml_non_ascii_apex_fatal() {
        let text = r#"
            [[domain]]
            suffix = "exämple.com"
        "#;
        let result = load_from_toml_str(text);
        assert!(matches!(result, Err(ConfigError::Invalid(_))));
    }

    /// Decision 6: [acme].enabled=true with no email must be fatal at config-load.
    #[test]
    fn toml_acme_enabled_without_email_fatal() {
        let text = r#"
            [[domain]]
            suffix = "a.com"

            [acme]
            enabled = true
        "#;
        let result = load_from_toml_str(text);
        assert!(
            matches!(result, Err(ConfigError::Invalid(_))),
            "expected ConfigError::Invalid, got: {:?}",
            result
        );
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("email"),
            "error should mention email, got: {}",
            msg
        );
    }

    /// listen_tls without any cert source must be fatal at config-load.
    #[test]
    fn toml_tls_listener_without_cert_source_fatal() {
        let text = r#"
            listen_tls = "0.0.0.0:443"

            [[domain]]
            suffix = "a.com"
        "#;
        let result = load_from_toml_str(text);
        assert!(
            matches!(result, Err(ConfigError::Invalid(_))),
            "expected ConfigError::Invalid for TLS listener without cert, got: {:?}",
            result
        );
    }

    /// IPv6 backend address must parse cleanly and round-trip as SocketAddr::V6.
    #[test]
    fn ipv6_backend_parses() {
        let text = r#"
            [[domain]]
            suffix = "worldtree.network"

            [[route]]
            apex = "worldtree.network"
            subdomain = "api"
            backend = "[::1]:3000"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert_eq!(cfg.routes.len(), 1);
        let backend = cfg.routes[0].backend;
        assert!(backend.is_ipv6(), "expected IPv6 backend, got {:?}", backend);
        assert_eq!(backend.port(), 3000);
    }

    #[test]
    fn san_derivation_iroh_mode_wildcard_plus_apex() {
        let apexes = vec![Apex {
            suffix: "vm.worldtree.network".into(),
            fallthrough: Fallthrough::Iroh,
        }];
        let sans = derive_san_list(&apexes, &[], &[]);
        assert_eq!(sans, vec!["*.vm.worldtree.network", "vm.worldtree.network"]);
    }

    #[test]
    fn san_derivation_none_mode_apex_plus_routes_no_wildcard() {
        let apexes = vec![Apex {
            suffix: "worldtree.network".into(),
            fallthrough: Fallthrough::None,
        }];
        let routes = vec![
            Route {
                apex: "worldtree.network".into(),
                subdomain: "git".into(),
                backend: "127.0.0.1:3000".parse().unwrap(),
                fallback_node: None,
                fallback_port: None,
            },
            Route {
                apex: "worldtree.network".into(),
                subdomain: "chat".into(),
                backend: "127.0.0.1:4000".parse().unwrap(),
                fallback_node: None,
                fallback_port: None,
            },
        ];
        let sans = derive_san_list(&apexes, &routes, &[]);
        // No wildcard; apex + two route subdomains.
        assert!(!sans.iter().any(|s| s.starts_with("*.")));
        assert!(sans.iter().any(|s| s == "worldtree.network"));
        assert!(sans.iter().any(|s| s == "git.worldtree.network"));
        assert!(sans.iter().any(|s| s == "chat.worldtree.network"));
    }

    #[test]
    fn san_derivation_mixed_apexes() {
        let apexes = vec![
            Apex {
                suffix: "vm.worldtree.network".into(),
                fallthrough: Fallthrough::Iroh,
            },
            Apex {
                suffix: "worldtree.network".into(),
                fallthrough: Fallthrough::None,
            },
        ];
        let routes = vec![Route {
            apex: "worldtree.network".into(),
            subdomain: "git".into(),
            backend: "127.0.0.1:3000".parse().unwrap(),
            fallback_node: None,
            fallback_port: None,
        }];
        let sans = derive_san_list(&apexes, &routes, &[]);
        assert!(sans.contains(&"*.vm.worldtree.network".to_owned()));
        assert!(sans.contains(&"vm.worldtree.network".to_owned()));
        assert!(sans.contains(&"worldtree.network".to_owned()));
        assert!(sans.contains(&"git.worldtree.network".to_owned()));
        // No wildcard for the `none`-mode apex.
        assert!(!sans.contains(&"*.worldtree.network".to_owned()));
    }

    // A valid 52-char z32 node ID (decodes to 32 bytes).
    const TEST_NODE_Z32: &str = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u";

    #[test]
    fn toml_alias_parsed_and_normalized() {
        let toml = format!(
            r#"
            [[domain]]
            suffix = "identikey.io"
            fallthrough = "none"

            [[alias]]
            apex = "identikey.io"
            subdomain = "Zine"
            node = "{TEST_NODE_Z32}"
            port = 3000
            "#
        );
        let cfg = load_from_toml_str(&toml).expect("valid config");
        assert_eq!(cfg.aliases.len(), 1);
        let a = &cfg.aliases[0];
        assert_eq!(a.apex, "identikey.io");
        assert_eq!(a.subdomain, "zine", "subdomain lowercased");
        assert_eq!(a.node_z32, TEST_NODE_Z32);
        assert_eq!(a.target_subdomain(), format!("{TEST_NODE_Z32}-3000"));
    }

    #[test]
    fn toml_alias_bad_node_skipped() {
        let toml = r#"
            [[domain]]
            suffix = "identikey.io"
            fallthrough = "none"

            [[alias]]
            apex = "identikey.io"
            subdomain = "zine"
            node = "not-a-valid-z32-node-id"
        "#;
        let cfg = load_from_toml_str(toml).expect("loads, bad alias warn-skipped");
        assert!(cfg.aliases.is_empty(), "invalid node ID alias is dropped");
    }

    #[test]
    fn toml_alias_orphan_apex_skipped() {
        let toml = format!(
            r#"
            [[domain]]
            suffix = "identikey.io"
            fallthrough = "none"

            [[alias]]
            apex = "nope.example.com"
            subdomain = "zine"
            node = "{TEST_NODE_Z32}"
            "#
        );
        let cfg = load_from_toml_str(&toml).expect("loads");
        assert!(cfg.aliases.is_empty(), "alias under undeclared apex is dropped");
    }

    #[test]
    fn toml_alias_shadowed_by_route_retained_as_fallback() {
        let toml = format!(
            r#"
            [[domain]]
            suffix = "identikey.io"
            fallthrough = "none"

            [[route]]
            apex = "identikey.io"
            subdomain = "zine"
            backend = "127.0.0.1:3000"

            [[alias]]
            apex = "identikey.io"
            subdomain = "zine"
            node = "{TEST_NODE_Z32}"
            port = 3000
            "#
        );
        let cfg = load_from_toml_str(&toml).expect("loads");
        assert_eq!(cfg.routes.len(), 1);
        // The alias is dropped from the standalone list...
        assert!(
            cfg.aliases.is_empty(),
            "route wins; shadowed alias dropped from standalone list"
        );
        // ...but its Iroh node/port is retained on the route as a fallback.
        let r = &cfg.routes[0];
        assert_eq!(r.fallback_node.as_deref(), Some(TEST_NODE_Z32));
        assert_eq!(r.fallback_port, Some(3000));
        assert_eq!(
            r.fallback_target_subdomain().as_deref(),
            Some(format!("{TEST_NODE_Z32}-3000").as_str())
        );
    }

    #[test]
    fn toml_unshadowed_route_has_no_fallback() {
        let toml = r#"
            [[domain]]
            suffix = "identikey.io"
            fallthrough = "none"

            [[route]]
            apex = "identikey.io"
            subdomain = "git"
            backend = "127.0.0.1:3000"
        "#;
        let cfg = load_from_toml_str(toml).expect("loads");
        assert_eq!(cfg.routes.len(), 1);
        assert_eq!(cfg.routes[0].fallback_node, None);
        assert_eq!(cfg.routes[0].fallback_port, None);
        assert_eq!(cfg.routes[0].fallback_target_subdomain(), None);
    }

    #[test]
    fn san_derivation_includes_alias_under_none_apex() {
        let apexes = vec![Apex {
            suffix: "identikey.io".into(),
            fallthrough: Fallthrough::None,
        }];
        let aliases = vec![Alias {
            apex: "identikey.io".into(),
            subdomain: "zine".into(),
            node_z32: TEST_NODE_Z32.into(),
            port: Some(3000),
        }];
        let sans = derive_san_list(&apexes, &[], &aliases);
        // The alias FQDN must be a SAN so ACME can issue the cert — there is no
        // wildcard for a `none` apex.
        assert!(sans.iter().any(|s| s == "zine.identikey.io"));
        assert!(!sans.iter().any(|s| s.starts_with("*.")));
    }

    /// Spec AC 1: env-fallback mode preserves the pre-upgrade single-apex
    /// deployment for `vm.worldtree.network`.
    #[test]
    fn env_fallback_default_apex_is_vm_worldtree_network() {
        // Make sure GATEWAY_DOMAIN doesn't leak from the surrounding env.
        // SAFETY: tests that touch env vars serialize through a thread-local
        // mutex in Rust stdlib; unit tests here do not contend.
        let guard = std::env::var("GATEWAY_DOMAIN").ok();
        // SAFETY: mutating process env in tests is inherently racy with other
        // env-reading tests; we accept the small risk for this one focused check.
        unsafe {
            std::env::remove_var("GATEWAY_DOMAIN");
        }
        let cfg = load_from_env().expect("env fallback");
        assert_eq!(cfg.apexes.len(), 1);
        assert_eq!(cfg.apexes[0].suffix, "vm.worldtree.network");
        assert_eq!(cfg.apexes[0].fallthrough, Fallthrough::Iroh);
        assert!(matches!(cfg.source, ConfigSource::Env));
        // Restore so other tests aren't disturbed.
        if let Some(v) = guard {
            unsafe {
                std::env::set_var("GATEWAY_DOMAIN", v);
            }
        }
    }

    // ── [[cert]] bring-your-own-cert tests ────────────────────────────────

    #[test]
    fn toml_cert_parsed_and_host_lowercased() {
        let text = r#"
            [[domain]]
            suffix = "vm.worldtree.network"

            [[cert]]
            host = "Zine.IdentiKey.IO"
            cert = "/etc/mjolnir/certs/zine/fullchain.pem"
            key  = "/etc/mjolnir/certs/zine/privkey.pem"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert_eq!(cfg.extra_certs.len(), 1);
        let c = &cfg.extra_certs[0];
        assert_eq!(c.host, "zine.identikey.io", "host lowercased");
        assert_eq!(
            c.cert_path,
            PathBuf::from("/etc/mjolnir/certs/zine/fullchain.pem")
        );
        assert_eq!(
            c.key_path,
            PathBuf::from("/etc/mjolnir/certs/zine/privkey.pem")
        );
    }

    #[test]
    fn toml_cert_duplicate_host_skipped() {
        let text = r#"
            [[domain]]
            suffix = "vm.worldtree.network"

            [[cert]]
            host = "zine.identikey.io"
            cert = "/a/fullchain.pem"
            key  = "/a/privkey.pem"

            [[cert]]
            host = "ZINE.identikey.io"
            cert = "/b/fullchain.pem"
            key  = "/b/privkey.pem"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert_eq!(cfg.extra_certs.len(), 1, "dupe host (case-insensitive) skipped");
        assert_eq!(cfg.extra_certs[0].cert_path, PathBuf::from("/a/fullchain.pem"));
    }

    #[test]
    fn toml_cert_bad_host_skipped() {
        let text = r#"
            [[domain]]
            suffix = "vm.worldtree.network"

            [[cert]]
            host = "not a valid host"
            cert = "/a/fullchain.pem"
            key  = "/a/privkey.pem"
        "#;
        let cfg = load_from_toml_str(text).expect("loads, bad cert host warn-skipped");
        assert!(cfg.extra_certs.is_empty(), "invalid host cert is dropped");
    }

    #[test]
    fn toml_cert_empty_paths_skipped() {
        let text = r#"
            [[domain]]
            suffix = "vm.worldtree.network"

            [[cert]]
            host = "zine.identikey.io"
            cert = ""
            key  = "/a/privkey.pem"
        "#;
        let cfg = load_from_toml_str(text).expect("loads");
        assert!(cfg.extra_certs.is_empty(), "empty cert path is dropped");
    }

    #[test]
    fn toml_case_normalized_on_load() {
        let text = r#"
            [[domain]]
            suffix = "A.COM"

            [[route]]
            apex = "a.com"
            subdomain = "Git"
            backend = "127.0.0.1:3000"
        "#;
        let cfg = load_from_toml_str(text).expect("parse");
        assert_eq!(cfg.apexes[0].suffix, "a.com");
        assert_eq!(cfg.routes[0].subdomain, "git");
    }

    // ── Drop-in directory loader tests (Phase 1) ──────────────────────────────

    const BASE_TOML: &str = r#"
        [[domain]]
        suffix = "identikey.io"
        fallthrough = "none"

        [[route]]
        apex = "identikey.io"
        subdomain = "base"
        backend = "127.0.0.1:1000"
    "#;

    /// Write `gateway.toml` plus the named drop-in files under `gateway.d/` in a
    /// fresh temp dir, then `load()` the base path so the drop-in merge runs.
    fn load_with_dropins(base: &str, dropins: &[(&str, &str)]) -> (tempfile::TempDir, LoadedConfig) {
        let dir = tempfile::tempdir().expect("tempdir");
        let base_path = dir.path().join("gateway.toml");
        std::fs::write(&base_path, base).expect("write base");
        let dropin_dir = dir.path().join("gateway.d");
        std::fs::create_dir_all(&dropin_dir).expect("mkdir gateway.d");
        for (name, body) in dropins {
            std::fs::write(dropin_dir.join(name), body).expect("write dropin");
        }
        let cfg = load(&base_path).expect("load");
        (dir, cfg)
    }

    #[test]
    fn dropin_merges_routes_and_aliases() {
        let dropin = format!(
            r#"
            [[route]]
            apex = "identikey.io"
            subdomain = "zine"
            backend = "10.0.0.5:3000"

            [[alias]]
            apex = "identikey.io"
            subdomain = "vanity"
            node = "{TEST_NODE_Z32}"
            port = 8080
            "#
        );
        let (_dir, cfg) = load_with_dropins(BASE_TOML, &[("10-apps.toml", &dropin)]);
        // Base route still present, drop-in route merged in.
        assert!(cfg.routes.iter().any(|r| r.subdomain == "base"));
        let zine = cfg
            .routes
            .iter()
            .find(|r| r.subdomain == "zine")
            .expect("drop-in route merged");
        assert_eq!(zine.backend, "10.0.0.5:3000".parse().unwrap());
        // Drop-in alias merged in.
        let alias = cfg
            .aliases
            .iter()
            .find(|a| a.subdomain == "vanity")
            .expect("drop-in alias merged");
        assert_eq!(alias.node_z32, TEST_NODE_Z32);
        assert_eq!(alias.port, Some(8080));
    }

    #[test]
    fn dropin_generated_route_shadows_base_alias() {
        // A base alias for `zine` plus a generated drop-in route for the same
        // (apex, subdomain): the route must win and retain the alias as fallback,
        // proving the merge happens BEFORE validation.
        let base = format!(
            r#"
            [[domain]]
            suffix = "identikey.io"
            fallthrough = "none"

            [[alias]]
            apex = "identikey.io"
            subdomain = "zine"
            node = "{TEST_NODE_Z32}"
            port = 3000
            "#
        );
        let dropin = r#"
            [[route]]
            apex = "identikey.io"
            subdomain = "zine"
            backend = "10.0.0.9:3000"
        "#;
        let (_dir, cfg) = load_with_dropins(&base, &[("10-apps.toml", dropin)]);
        assert_eq!(cfg.routes.len(), 1);
        assert!(cfg.aliases.is_empty(), "route shadows base alias");
        let r = &cfg.routes[0];
        assert_eq!(r.backend, "10.0.0.9:3000".parse().unwrap());
        assert_eq!(r.fallback_node.as_deref(), Some(TEST_NODE_Z32));
        assert_eq!(r.fallback_port, Some(3000));
    }

    #[test]
    fn dropin_cannot_inject_apex_cert_or_server_settings() {
        // A hostile drop-in tries to add an apex, a cert, and change server +
        // ACME + TLS settings. All must be ignored; only the route merges.
        let dropin = r#"
            listen = "0.0.0.0:9999"
            vm_default_port = 9
            connect_timeout_secs = 1

            [acme]
            enabled = true
            email = "evil@example.com"

            [tls]
            cert = "/evil/cert.pem"
            key = "/evil/key.pem"

            [[domain]]
            suffix = "evil.example.com"

            [[cert]]
            host = "evil.example.com"
            cert = "/evil/c.pem"
            key = "/evil/k.pem"

            [[route]]
            apex = "identikey.io"
            subdomain = "ok"
            backend = "10.0.0.7:80"
        "#;
        let (_dir, cfg) = load_with_dropins(BASE_TOML, &[("10-evil.toml", dropin)]);
        // Only the base apex survives — no apex injection.
        assert_eq!(cfg.apexes.len(), 1);
        assert_eq!(cfg.apexes[0].suffix, "identikey.io");
        // No cert injection.
        assert!(cfg.extra_certs.is_empty(), "drop-in cert ignored");
        // Server/ACME/TLS settings untouched (base declared none → defaults).
        assert!(!cfg.acme.enabled, "drop-in ACME ignored");
        assert_eq!(cfg.vm_default_port, 80, "drop-in vm_default_port ignored");
        assert!(cfg.listen.is_none(), "drop-in listen ignored");
        assert!(cfg.tls_cert_path.is_none(), "drop-in tls cert ignored");
        // But the route IS merged.
        assert!(cfg.routes.iter().any(|r| r.subdomain == "ok"));
    }

    #[test]
    fn dropin_malformed_is_skipped_not_fatal() {
        let good = r#"
            [[route]]
            apex = "identikey.io"
            subdomain = "good"
            backend = "10.0.0.1:80"
        "#;
        let bad = "this is = not : valid toml = at = all";
        // `00-bad` sorts first; the loader must skip it and still merge `10-good`.
        let (_dir, cfg) =
            load_with_dropins(BASE_TOML, &[("00-bad.toml", bad), ("10-good.toml", good)]);
        assert!(
            cfg.routes.iter().any(|r| r.subdomain == "good"),
            "good drop-in merged despite a malformed sibling"
        );
    }

    #[test]
    fn dropin_sorted_deterministic_order() {
        // Two drop-ins declare the same (apex, subdomain) with different backends.
        // Files merge in sorted filename order; validation keeps the first, so the
        // lexicographically-earlier filename wins deterministically.
        let first = r#"
            [[route]]
            apex = "identikey.io"
            subdomain = "dup"
            backend = "10.0.0.1:3001"
        "#;
        let second = r#"
            [[route]]
            apex = "identikey.io"
            subdomain = "dup"
            backend = "10.0.0.2:3002"
        "#;
        let (_dir, cfg) =
            load_with_dropins(BASE_TOML, &[("01-a.toml", first), ("02-b.toml", second)]);
        let dup: Vec<_> = cfg.routes.iter().filter(|r| r.subdomain == "dup").collect();
        assert_eq!(dup.len(), 1, "duplicate route deduplicated");
        assert_eq!(
            dup[0].backend,
            "10.0.0.1:3001".parse().unwrap(),
            "earlier filename wins"
        );
    }

    #[test]
    fn dropin_missing_directory_is_noop() {
        // load() against a base path whose sibling gateway.d/ does not exist must
        // succeed with just the base routes.
        let dir = tempfile::tempdir().expect("tempdir");
        let base_path = dir.path().join("gateway.toml");
        std::fs::write(&base_path, BASE_TOML).expect("write base");
        let cfg = load(&base_path).expect("load with no gateway.d");
        assert_eq!(cfg.routes.len(), 1);
        assert_eq!(cfg.routes[0].subdomain, "base");
    }

    #[test]
    fn dropin_non_toml_files_ignored() {
        let dropin = r#"
            [[route]]
            apex = "identikey.io"
            subdomain = "yes"
            backend = "10.0.0.1:80"
        "#;
        // A non-.toml sibling must be skipped entirely.
        let (_dir, cfg) =
            load_with_dropins(BASE_TOML, &[("README.md", "not toml"), ("10-x.toml", dropin)]);
        assert!(cfg.routes.iter().any(|r| r.subdomain == "yes"));
    }
}

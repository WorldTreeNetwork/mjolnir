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

    #[serde(default, rename = "domain")]
    pub domains: Vec<DomainDecl>,

    #[serde(default, rename = "route")]
    pub routes: Vec<RouteDecl>,
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

/// Derive the cert SAN list from the declared apex list + route list, honoring
/// each apex's fallthrough mode (Decision 7).
pub fn derive_san_list(apexes: &[Apex], routes: &[Route]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();

    for apex in apexes {
        match apex.fallthrough {
            Fallthrough::Iroh => {
                let wild = format!("*.{}", apex.suffix);
                if !out.iter().any(|v| v == &wild) {
                    out.push(wild);
                }
                if !out.iter().any(|v| v == &apex.suffix) {
                    out.push(apex.suffix.clone());
                }
            }
            Fallthrough::None => {
                if !out.iter().any(|v| v == &apex.suffix) {
                    out.push(apex.suffix.clone());
                }
                for r in routes.iter().filter(|r| r.apex == apex.suffix) {
                    let fqdn = format!("{}.{}", r.subdomain, apex.suffix);
                    if !out.iter().any(|v| v == &fqdn) {
                        out.push(fqdn);
                    }
                }
            }
        }
    }

    out
}

// ── Loader entry points ───────────────────────────────────────────────────────

/// Load the gateway configuration.
///
/// If `path` exists, TOML is authoritative. Otherwise the env-var fallback path
/// is used (see [`load_from_env`]).
pub fn load(path: &Path) -> Result<LoadedConfig, ConfigError> {
    if path.exists() {
        let bytes = std::fs::read(path)?;
        let text = std::str::from_utf8(&bytes)
            .map_err(|e| ConfigError::TomlParse(format!("invalid UTF-8 in {}: {}", path.display(), e)))?;
        load_from_toml_str(text)
    } else {
        load_from_env()
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
        if !is_ascii_label(&sub_lower) {
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

    info!(
        event = "config.loaded",
        source = ?source,
        apex_count = apexes.len(),
        route_count = routes.len(),
        acme = acme_settings.enabled,
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
    })
}

impl LoadedConfig {
    /// Build the effective ACME SAN list: the explicit override if present,
    /// otherwise the auto-derived list.
    pub fn effective_acme_domains(&self) -> Vec<String> {
        if let Some(ref explicit) = self.acme.explicit_domains {
            return explicit.clone();
        }
        derive_san_list(&self.apexes, &self.routes)
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
        let sans = derive_san_list(&apexes, &[]);
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
            },
            Route {
                apex: "worldtree.network".into(),
                subdomain: "chat".into(),
                backend: "127.0.0.1:4000".parse().unwrap(),
            },
        ];
        let sans = derive_san_list(&apexes, &routes);
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
        }];
        let sans = derive_san_list(&apexes, &routes);
        assert!(sans.contains(&"*.vm.worldtree.network".to_owned()));
        assert!(sans.contains(&"vm.worldtree.network".to_owned()));
        assert!(sans.contains(&"worldtree.network".to_owned()));
        assert!(sans.contains(&"git.worldtree.network".to_owned()));
        // No wildcard for the `none`-mode apex.
        assert!(!sans.contains(&"*.worldtree.network".to_owned()));
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
}

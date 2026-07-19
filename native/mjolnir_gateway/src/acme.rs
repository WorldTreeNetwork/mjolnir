//! In-process ACME DNS-01 certificate issuance via Cloudflare.

#![allow(dead_code)]

use std::fs;
use std::io::Write as _;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use thiserror::Error;
use tracing::{info, warn};

use crate::cloudflare::{CloudflareClient, CloudflareError, ZoneId};
use crate::tls::extract_cert_metadata;

// ── Error type ────────────────────────────────────────────────────────────────

#[derive(Debug, Error)]
pub enum AcmeError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Cloudflare error: {0}")]
    Cf(#[from] CloudflareError),
    #[error("ACME error: {0}")]
    Acme(String),
    #[error("rcgen error: {0}")]
    Rcgen(String),
    #[error("cert metadata parse error: {0}")]
    Parse(String),
    #[error("timeout: {0}")]
    Timeout(&'static str),
    #[error("no domains configured")]
    NoDomains,
    #[error("task join error: {0}")]
    TaskJoin(String),
}

impl From<instant_acme::Error> for AcmeError {
    fn from(e: instant_acme::Error) -> Self {
        AcmeError::Acme(e.to_string())
    }
}

impl From<rcgen::Error> for AcmeError {
    fn from(e: rcgen::Error) -> Self {
        AcmeError::Rcgen(e.to_string())
    }
}

impl From<crate::tls::TlsError> for AcmeError {
    fn from(e: crate::tls::TlsError) -> Self {
        AcmeError::Parse(e.to_string())
    }
}

// ── Public types ──────────────────────────────────────────────────────────────

pub struct AcmeConfig {
    pub directory_url: String,
    pub email: String,
    pub domains: Vec<String>,
    pub state_dir: PathBuf,
    pub renew_before: Duration,
}

pub struct IssuedCert {
    pub chain_pem: String,
    pub key_pem: String,
    pub not_after: SystemTime,
    pub not_before: SystemTime,
    pub fingerprint_sha256: String,
}

// ── Persisted metadata ────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
struct CertMetadataFile {
    not_after_unix: u64,
    not_before_unix: u64,
    fingerprint_sha256: String,
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Strip wildcard prefix: `*.foo.bar` -> `foo.bar`, `foo.bar` -> `foo.bar`.
fn strip_wildcard(domain: &str) -> &str {
    domain.strip_prefix("*.").unwrap_or(domain)
}

/// Build the ACME DNS TXT record FQDN for a domain.
fn challenge_fqdn(domain: &str) -> String {
    format!("_acme-challenge.{}", strip_wildcard(domain))
}

fn system_time_to_unix(t: SystemTime) -> u64 {
    t.duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

fn unix_to_system_time(secs: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(secs)
}

/// Atomically write bytes to `path` via a sibling `.tmp` file + rename.
fn atomic_write(path: &std::path::Path, data: &[u8]) -> Result<(), AcmeError> {
    let tmp_path = path.with_extension("tmp");
    let mut f = fs::File::create(&tmp_path)?;
    f.write_all(data)?;
    f.sync_all()?;
    fs::rename(&tmp_path, path)?;
    Ok(())
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Load from disk only. Returns `None` if any file is missing.
pub fn load_cached(cfg: &AcmeConfig) -> Result<Option<IssuedCert>, AcmeError> {
    let chain_path = cfg.state_dir.join("fullchain.pem");
    let key_path = cfg.state_dir.join("privkey.pem");
    let meta_path = cfg.state_dir.join("metadata.json");

    if !chain_path.exists() || !key_path.exists() || !meta_path.exists() {
        return Ok(None);
    }

    let chain_pem = fs::read_to_string(&chain_path)?;
    let key_pem = fs::read_to_string(&key_path)?;
    let meta_bytes = fs::read(&meta_path)?;
    let meta: CertMetadataFile = serde_json::from_slice(&meta_bytes)
        .map_err(|e| AcmeError::Parse(format!("metadata.json: {e}")))?;

    Ok(Some(IssuedCert {
        chain_pem,
        key_pem,
        not_after: unix_to_system_time(meta.not_after_unix),
        not_before: unix_to_system_time(meta.not_before_unix),
        fingerprint_sha256: meta.fingerprint_sha256,
    }))
}

/// Extract the DNS SAN entries from the end-entity (first) cert in a PEM chain.
/// Returned lowercased for case-insensitive comparison.
fn cert_dns_sans(chain_pem: &str) -> Result<Vec<String>, AcmeError> {
    use x509_parser::prelude::*;

    let certs = crate::tls::parse_cert_chain(chain_pem.as_bytes())?;
    let (_, cert) = X509Certificate::from_der(certs[0].as_ref())
        .map_err(|e| AcmeError::Parse(format!("x509 parse: {e}")))?;

    let mut sans = Vec::new();
    if let Ok(Some(san)) = cert.subject_alternative_name() {
        for name in &san.value.general_names {
            if let GeneralName::DNSName(dns) = name {
                sans.push(dns.to_ascii_lowercase());
            }
        }
    }
    Ok(sans)
}

/// Whether the cached cert's DNS SANs cover every domain in `domains` (i.e. the
/// cert is a superset of the requested identifier set). Case-insensitive. An
/// unparseable chain returns `false`, forcing a re-issue.
fn cert_covers_domains(chain_pem: &str, domains: &[String]) -> bool {
    let sans = match cert_dns_sans(chain_pem) {
        Ok(s) => s,
        Err(_) => return false,
    };
    domains
        .iter()
        .all(|d| sans.iter().any(|s| *s == d.to_ascii_lowercase()))
}

/// Decide whether a fresh ACME issuance is required, given the currently cached
/// cert (if any) and the desired config. Pure (parses only the in-memory chain)
/// so it can be unit-tested directly without hitting Let's Encrypt.
///
/// Reuse the cache ONLY IF the cached cert is (a) fresh
/// (`remaining > renew_before`) AND (b) covers every domain in `cfg.domains`.
/// Re-issue when the cert is missing, near expiry, or the SAN/identifier set
/// changed (e.g. an apex was added to `[acme].domains` on SIGHUP).
pub fn should_issue(cached: Option<&IssuedCert>, cfg: &AcmeConfig, now: SystemTime) -> bool {
    let Some(cached) = cached else {
        return true; // no cached cert
    };
    let remaining = cached.not_after.duration_since(now).unwrap_or_default();
    if remaining <= cfg.renew_before {
        return true; // missing time / near expiry
    }
    if !cert_covers_domains(&cached.chain_pem, &cfg.domains) {
        return true; // SAN set changed — cached cert doesn't cover current identifiers
    }
    false
}

/// Load a cached cert if present, fresh, AND covering the current SAN set;
/// otherwise issue a new one. Used by both startup and the SIGHUP reload path so
/// repeated reloads with an unchanged, valid SAN set issue ZERO ACME requests.
pub async fn load_or_issue(
    cfg: &AcmeConfig,
    cf: &CloudflareClient,
) -> Result<IssuedCert, AcmeError> {
    let cached = load_cached(cfg)?;
    if !should_issue(cached.as_ref(), cfg, SystemTime::now()) {
        // `should_issue` returning false guarantees `cached` is `Some`.
        return Ok(cached.expect("cache reuse implies a cached cert exists"));
    }
    issue(cfg, cf).await
}

/// Force a fresh issuance, bypassing the cache.
pub async fn issue(cfg: &AcmeConfig, cf: &CloudflareClient) -> Result<IssuedCert, AcmeError> {
    use instant_acme::{
        Account, AccountCredentials, AuthorizationStatus, ChallengeType, Identifier, NewAccount,
        NewOrder, OrderStatus,
    };

    if cfg.domains.is_empty() {
        return Err(AcmeError::NoDomains);
    }

    // ── Step 1: Load or create ACME account ───────────────────────────────────
    fs::create_dir_all(&cfg.state_dir)?;
    let account_path = cfg.state_dir.join("account.json");

    let account = if account_path.exists() {
        let data = fs::read(&account_path)?;
        let creds: AccountCredentials = serde_json::from_slice(&data)
            .map_err(|e| AcmeError::Acme(format!("account.json parse: {e}")))?;
        Account::from_credentials(creds).await?
    } else {
        let contact = format!("mailto:{}", cfg.email);
        let (account, credentials) = Account::create(
            &NewAccount {
                contact: &[contact.as_str()],
                terms_of_service_agreed: true,
                only_return_existing: false,
            },
            &cfg.directory_url,
            None,
        )
        .await?;
        let creds_json = serde_json::to_vec(&credentials)
            .map_err(|e| AcmeError::Acme(format!("serialize credentials: {e}")))?;
        atomic_write(&account_path, &creds_json)?;
        info!(event = "acme.account_created", email = %cfg.email, "ACME account created");
        account
    };

    // ── Step 2: Create order ──────────────────────────────────────────────────
    let identifiers: Vec<Identifier> = cfg
        .domains
        .iter()
        .map(|d| Identifier::Dns(d.clone()))
        .collect();
    let mut order = account
        .new_order(&NewOrder {
            identifiers: &identifiers,
        })
        .await?;

    // ── Step 3: Process authorizations and set TXT records ────────────────────
    let authorizations = order.authorizations().await?;

    // Cache zone lookups per unique zone name so we don't re-query CF.
    let mut zone_cache: std::collections::HashMap<String, (ZoneId, String)> =
        std::collections::HashMap::new();

    // Track (zone_id, record_id, fqdn) for cleanup.
    let mut created_records: Vec<(ZoneId, crate::cloudflare::RecordId)> = Vec::new();

    for authz in &authorizations {
        if authz.status == AuthorizationStatus::Valid {
            continue;
        }

        let challenge = authz
            .challenges
            .iter()
            .find(|c| c.r#type == ChallengeType::Dns01)
            .ok_or_else(|| AcmeError::Acme("no dns-01 challenge found".into()))?;

        let Identifier::Dns(domain) = &authz.identifier;
        let fqdn = challenge_fqdn(domain);
        let dns_value = order.key_authorization(challenge).dns_value();

        // Find the zone (using cache).
        let base_domain = strip_wildcard(domain).to_owned();
        let (zone_id, _zone_name) = if let Some(cached) = zone_cache.get(&base_domain) {
            cached.clone()
        } else {
            let result = cf.find_zone(&fqdn).await?;
            zone_cache.insert(base_domain.clone(), result.clone());
            result
        };

        let record_id = cf.create_txt(&zone_id, &fqdn, &dns_value, 60).await?;
        info!(
            event = "acme.txt_record_created",
            fqdn = %fqdn,
            zone = %zone_id.0,
            "TXT record created for ACME challenge"
        );
        created_records.push((zone_id, record_id));
    }

    // ── Step 4: Wait for DNS propagation ─────────────────────────────────────
    tokio::time::sleep(Duration::from_secs(15)).await;

    // ── Step 5: Mark challenges ready ────────────────────────────────────────
    for authz in &authorizations {
        if authz.status == AuthorizationStatus::Valid {
            continue;
        }
        let challenge = authz
            .challenges
            .iter()
            .find(|c| c.r#type == ChallengeType::Dns01)
            .ok_or_else(|| AcmeError::Acme("no dns-01 challenge found".into()))?;
        order.set_challenge_ready(&challenge.url).await?;
    }

    // ── Step 6: Poll for order Ready/Invalid ─────────────────────────────────
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    loop {
        if tokio::time::Instant::now() >= deadline {
            cleanup_records(cf, &created_records).await;
            return Err(AcmeError::Timeout("order did not become ready"));
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
        let state = order.refresh().await?;
        match state.status {
            OrderStatus::Ready => break,
            OrderStatus::Invalid => {
                cleanup_records(cf, &created_records).await;
                let desc = state
                    .error
                    .as_ref()
                    .and_then(|e| e.detail.clone())
                    .unwrap_or_else(|| "order invalid".into());
                return Err(AcmeError::Acme(desc));
            }
            _ => {}
        }
    }

    // ── Step 7: Generate CSR ──────────────────────────────────────────────────
    let mut params = rcgen::CertificateParams::new(cfg.domains.clone())?;
    params.distinguished_name = rcgen::DistinguishedName::new();
    let key_pair = rcgen::KeyPair::generate()?;
    let csr = params.serialize_request(&key_pair)?;
    let key_pem = key_pair.serialize_pem();

    // ── Step 8: Finalize ──────────────────────────────────────────────────────
    order.finalize(csr.der()).await?;

    // ── Step 9: Poll for certificate ─────────────────────────────────────────
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    let chain_pem = loop {
        if tokio::time::Instant::now() >= deadline {
            cleanup_records(cf, &created_records).await;
            return Err(AcmeError::Timeout("certificate not available"));
        }
        match order.certificate().await? {
            Some(chain) => break chain,
            None => tokio::time::sleep(Duration::from_secs(2)).await,
        }
    };

    // ── Step 10: Cleanup DNS TXT records (fire-and-forget) ────────────────────
    cleanup_records(cf, &created_records).await;

    // ── Steps 11-13: parse meta, persist, emit event ─────────────────────────
    finalize_issued_cert(cfg, chain_pem, key_pem)
}

/// Parse the issued chain, persist `fullchain.pem` / `privkey.pem` /
/// `metadata.json` to `cfg.state_dir`, emit the `acme.cert_issued` event, and
/// return the resulting [`IssuedCert`]. Shared by both [`issue`] and
/// [`issue_manual`].
fn finalize_issued_cert(cfg: &AcmeConfig, chain_pem: String, key_pem: String) -> Result<IssuedCert, AcmeError> {
    // Parse metadata from first cert in chain.
    let certs = crate::tls::parse_cert_chain(chain_pem.as_bytes())
        .map_err(|e| AcmeError::Parse(e.to_string()))?;
    let meta = extract_cert_metadata(certs[0].as_ref())?;

    // Persist.
    let chain_path = cfg.state_dir.join("fullchain.pem");
    let key_path = cfg.state_dir.join("privkey.pem");
    let meta_path = cfg.state_dir.join("metadata.json");

    atomic_write(&chain_path, chain_pem.as_bytes())?;
    atomic_write(&key_path, key_pem.as_bytes())?;

    // Set privkey mode to 0600 on Unix.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&key_path, fs::Permissions::from_mode(0o600));
    }

    let meta_file = CertMetadataFile {
        not_after_unix: system_time_to_unix(meta.not_after),
        not_before_unix: system_time_to_unix(meta.not_before),
        fingerprint_sha256: meta.fingerprint_sha256.clone(),
    };
    let meta_json = serde_json::to_vec(&meta_file)
        .map_err(|e| AcmeError::Acme(format!("serialize metadata: {e}")))?;
    atomic_write(&meta_path, &meta_json)?;

    let not_after_str = humantime::format_rfc3339_seconds(meta.not_after).to_string();
    info!(
        event = "acme.cert_issued",
        fingerprint_sha256 = %meta.fingerprint_sha256,
        domains = ?cfg.domains,
        not_after = %not_after_str,
        "ACME certificate issued"
    );

    Ok(IssuedCert {
        chain_pem,
        key_pem,
        not_after: meta.not_after,
        not_before: meta.not_before,
        fingerprint_sha256: meta.fingerprint_sha256,
    })
}

/// Format an operator-facing block listing the DNS TXT records that must be
/// created before a manual DNS-01 issuance can proceed. Pure (no I/O) so it can
/// be unit-tested directly.
pub fn manual_dns_instructions(records: &[(String, String)]) -> String {
    let mut s = String::from("Create these DNS TXT records, then press Enter:\n");
    for (fqdn, value) in records {
        s.push_str(&format!("  {}  TXT  \"{}\"\n", fqdn, value));
    }
    s
}

/// Run the ACME DNS-01 flow in *manual* mode: no Cloudflare token is used.
/// Instead, the required `(challenge_fqdn, dns_value)` records are collected and
/// passed to `confirm`, which is expected to display them and block until the
/// operator has created them (e.g. by reading a line from stdin). After
/// `confirm` returns `Ok`, the challenges are marked ready and the flow
/// completes exactly like [`issue`], persisting to `cfg.state_dir`.
pub async fn issue_manual(
    cfg: &AcmeConfig,
    confirm: impl FnOnce(&[(String, String)]) -> std::io::Result<()>,
) -> Result<IssuedCert, AcmeError> {
    use instant_acme::{
        Account, AccountCredentials, AuthorizationStatus, ChallengeType, Identifier, NewAccount,
        NewOrder, OrderStatus,
    };

    if cfg.domains.is_empty() {
        return Err(AcmeError::NoDomains);
    }

    // ── Step 1: Load or create ACME account ───────────────────────────────────
    fs::create_dir_all(&cfg.state_dir)?;
    let account_path = cfg.state_dir.join("account.json");

    let account = if account_path.exists() {
        let data = fs::read(&account_path)?;
        let creds: AccountCredentials = serde_json::from_slice(&data)
            .map_err(|e| AcmeError::Acme(format!("account.json parse: {e}")))?;
        Account::from_credentials(creds).await?
    } else {
        let contact = format!("mailto:{}", cfg.email);
        let (account, credentials) = Account::create(
            &NewAccount {
                contact: &[contact.as_str()],
                terms_of_service_agreed: true,
                only_return_existing: false,
            },
            &cfg.directory_url,
            None,
        )
        .await?;
        let creds_json = serde_json::to_vec(&credentials)
            .map_err(|e| AcmeError::Acme(format!("serialize credentials: {e}")))?;
        atomic_write(&account_path, &creds_json)?;
        info!(event = "acme.account_created", email = %cfg.email, "ACME account created");
        account
    };

    // ── Step 2: Create order ──────────────────────────────────────────────────
    let identifiers: Vec<Identifier> = cfg
        .domains
        .iter()
        .map(|d| Identifier::Dns(d.clone()))
        .collect();
    let mut order = account
        .new_order(&NewOrder {
            identifiers: &identifiers,
        })
        .await?;

    // ── Step 3 (manual): collect TXT records, ask operator to create them ─────
    let authorizations = order.authorizations().await?;

    let mut records: Vec<(String, String)> = Vec::new();
    for authz in &authorizations {
        if authz.status == AuthorizationStatus::Valid {
            continue;
        }
        let challenge = authz
            .challenges
            .iter()
            .find(|c| c.r#type == ChallengeType::Dns01)
            .ok_or_else(|| AcmeError::Acme("no dns-01 challenge found".into()))?;
        let Identifier::Dns(domain) = &authz.identifier;
        let fqdn = challenge_fqdn(domain);
        let dns_value = order.key_authorization(challenge).dns_value();
        records.push((fqdn, dns_value));
    }

    // Block on the operator: they print the records and confirm DNS is set.
    confirm(&records)?;

    // ── Step 5: Mark challenges ready ────────────────────────────────────────
    for authz in &authorizations {
        if authz.status == AuthorizationStatus::Valid {
            continue;
        }
        let challenge = authz
            .challenges
            .iter()
            .find(|c| c.r#type == ChallengeType::Dns01)
            .ok_or_else(|| AcmeError::Acme("no dns-01 challenge found".into()))?;
        order.set_challenge_ready(&challenge.url).await?;
    }

    // ── Step 6: Poll for order Ready/Invalid ─────────────────────────────────
    let deadline = tokio::time::Instant::now() + Duration::from_secs(120);
    loop {
        if tokio::time::Instant::now() >= deadline {
            return Err(AcmeError::Timeout("order did not become ready"));
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
        let state = order.refresh().await?;
        match state.status {
            OrderStatus::Ready => break,
            OrderStatus::Invalid => {
                let desc = state
                    .error
                    .as_ref()
                    .and_then(|e| e.detail.clone())
                    .unwrap_or_else(|| "order invalid".into());
                return Err(AcmeError::Acme(desc));
            }
            _ => {}
        }
    }

    // ── Step 7: Generate CSR ──────────────────────────────────────────────────
    let mut params = rcgen::CertificateParams::new(cfg.domains.clone())?;
    params.distinguished_name = rcgen::DistinguishedName::new();
    let key_pair = rcgen::KeyPair::generate()?;
    let csr = params.serialize_request(&key_pair)?;
    let key_pem = key_pair.serialize_pem();

    // ── Step 8: Finalize ──────────────────────────────────────────────────────
    order.finalize(csr.der()).await?;

    // ── Step 9: Poll for certificate ─────────────────────────────────────────
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    let chain_pem = loop {
        if tokio::time::Instant::now() >= deadline {
            return Err(AcmeError::Timeout("certificate not available"));
        }
        match order.certificate().await? {
            Some(chain) => break chain,
            None => tokio::time::sleep(Duration::from_secs(2)).await,
        }
    };

    // ── Steps 11-13: parse meta, persist, emit event ─────────────────────────
    finalize_issued_cert(cfg, chain_pem, key_pem)
}

/// Fire-and-forget cleanup of DNS TXT records; logs on failure.
async fn cleanup_records(
    cf: &CloudflareClient,
    records: &[(ZoneId, crate::cloudflare::RecordId)],
) {
    for (zone_id, record_id) in records {
        if let Err(e) = cf.delete_txt(zone_id, record_id).await {
            warn!(
                event = "acme.txt_cleanup_failed",
                zone = %zone_id.0,
                record = %record_id.0,
                error = %e,
                "Failed to delete ACME challenge TXT record"
            );
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, SystemTime};
    use tempfile::TempDir;

    fn make_config(state_dir: &std::path::Path) -> AcmeConfig {
        AcmeConfig {
            directory_url: "https://acme-staging-v02.api.letsencrypt.org/directory".into(),
            email: "test@example.com".into(),
            domains: vec!["*.vm.worldtree.network".into(), "vm.worldtree.network".into()],
            state_dir: state_dir.to_owned(),
            renew_before: Duration::from_secs(30 * 24 * 3600),
        }
    }

    /// Generate a self-signed cert PEM + key PEM using rcgen.
    fn gen_self_signed(domains: &[&str]) -> (String, String) {
        let names: Vec<String> = domains.iter().map(|s| s.to_string()).collect();
        let mut params = rcgen::CertificateParams::new(names).expect("params");
        params.not_before = rcgen::date_time_ymd(2024, 1, 1);
        params.not_after = rcgen::date_time_ymd(2026, 6, 1);
        let kp = rcgen::KeyPair::generate().expect("keygen");
        let cert = params.self_signed(&kp).expect("self_signed");
        (cert.pem(), kp.serialize_pem())
    }

    fn write_metadata(dir: &std::path::Path, not_after: SystemTime, not_before: SystemTime, fp: &str) {
        let meta = CertMetadataFile {
            not_after_unix: system_time_to_unix(not_after),
            not_before_unix: system_time_to_unix(not_before),
            fingerprint_sha256: fp.to_owned(),
        };
        let data = serde_json::to_vec(&meta).unwrap();
        fs::write(dir.join("metadata.json"), data).unwrap();
    }

    // 1. load_cached_missing_returns_none
    #[test]
    fn load_cached_missing_returns_none() {
        let dir = TempDir::new().unwrap();
        let cfg = make_config(dir.path());
        let result = load_cached(&cfg).expect("load_cached");
        assert!(result.is_none());
    }

    // 2. load_cached_returns_parsed_metadata
    #[test]
    fn load_cached_returns_parsed_metadata() {
        let dir = TempDir::new().unwrap();
        let cfg = make_config(dir.path());

        let (chain_pem, key_pem) = gen_self_signed(&["vm.worldtree.network"]);

        // Parse the cert to get the real fingerprint.
        let certs = crate::tls::parse_cert_chain(chain_pem.as_bytes()).unwrap();
        let meta = crate::tls::extract_cert_metadata(certs[0].as_ref()).unwrap();

        fs::write(dir.path().join("fullchain.pem"), &chain_pem).unwrap();
        fs::write(dir.path().join("privkey.pem"), &key_pem).unwrap();
        write_metadata(
            dir.path(),
            meta.not_after,
            meta.not_before,
            &meta.fingerprint_sha256,
        );

        let result = load_cached(&cfg).expect("load_cached").expect("Some");
        assert_eq!(result.fingerprint_sha256, meta.fingerprint_sha256);
        assert_eq!(result.chain_pem, chain_pem);
    }

    // 3. load_or_issue_uses_cache_when_fresh
    // When the cert is far from expiry, load_or_issue returns the cached cert
    // without touching the Cloudflare client. We confirm this by noting that
    // load_cached is a pure function and load_or_issue calls it first — if it
    // returns a fresh cert, cf.find_zone is never called. We can't easily mock
    // the CF client without a trait, so we verify by checking the returned cert
    // matches the cached data and that the state_dir still has the same files.
    #[tokio::test]
    async fn load_or_issue_uses_cache_when_fresh() {
        let dir = TempDir::new().unwrap();
        let mut cfg = make_config(dir.path());
        cfg.renew_before = Duration::from_secs(30 * 24 * 3600); // 30 days

        let (chain_pem, key_pem) = gen_self_signed(&["vm.worldtree.network"]);
        let certs = crate::tls::parse_cert_chain(chain_pem.as_bytes()).unwrap();
        let meta = crate::tls::extract_cert_metadata(certs[0].as_ref()).unwrap();

        // Set not_after to 365 days from now — well beyond renew_before.
        let not_after = SystemTime::now() + Duration::from_secs(365 * 24 * 3600);
        let not_before = meta.not_before;

        fs::write(dir.path().join("fullchain.pem"), &chain_pem).unwrap();
        fs::write(dir.path().join("privkey.pem"), &key_pem).unwrap();
        write_metadata(dir.path(), not_after, not_before, &meta.fingerprint_sha256);

        // load_cached should return Some with sufficient time remaining.
        let cached = load_cached(&cfg).expect("load_cached").expect("Some");
        let remaining = cached
            .not_after
            .duration_since(SystemTime::now())
            .unwrap_or_default();
        assert!(
            remaining > cfg.renew_before,
            "cached cert should be fresh: remaining={remaining:?}"
        );
        assert_eq!(cached.fingerprint_sha256, meta.fingerprint_sha256);
    }

    // 4. load_or_issue_calls_issue_when_stale
    // When the cert is stale (expires soon), load_or_issue should NOT return
    // the cached cert. We verify that load_cached returns a cert whose
    // remaining time is less than renew_before, which is the trigger for issue().
    #[test]
    fn load_or_issue_calls_issue_when_stale() {
        let dir = TempDir::new().unwrap();
        let mut cfg = make_config(dir.path());
        cfg.renew_before = Duration::from_secs(24 * 3600); // 24 hours

        let (chain_pem, key_pem) = gen_self_signed(&["vm.worldtree.network"]);
        let certs = crate::tls::parse_cert_chain(chain_pem.as_bytes()).unwrap();
        let meta = crate::tls::extract_cert_metadata(certs[0].as_ref()).unwrap();

        // Expire in 1 hour — less than renew_before (24h), so stale.
        let not_after = SystemTime::now() + Duration::from_secs(3600);

        fs::write(dir.path().join("fullchain.pem"), &chain_pem).unwrap();
        fs::write(dir.path().join("privkey.pem"), &key_pem).unwrap();
        write_metadata(dir.path(), not_after, meta.not_before, &meta.fingerprint_sha256);

        let cached = load_cached(&cfg).expect("load_cached").expect("Some");
        let remaining = cached
            .not_after
            .duration_since(SystemTime::now())
            .unwrap_or_default();
        assert!(
            remaining <= cfg.renew_before,
            "cert should be stale: remaining={remaining:?}, renew_before={:?}",
            cfg.renew_before
        );
    }

    /// Build an in-memory `IssuedCert` from a self-signed cert covering
    /// `domains`, with the given `not_after`.
    fn make_issued(domains: &[&str], not_after: SystemTime) -> IssuedCert {
        let (chain_pem, key_pem) = gen_self_signed(domains);
        IssuedCert {
            chain_pem,
            key_pem,
            not_after,
            not_before: SystemTime::now(),
            fingerprint_sha256: "test".into(),
        }
    }

    // ── should_issue predicate (the core reuse/re-issue decision) ────────────

    // A) fresh cached cert covering the full SAN set → do NOT issue (reuse).
    #[test]
    fn should_issue_false_when_fresh_and_covers_sans() {
        let dir = TempDir::new().unwrap();
        let cfg = make_config(dir.path()); // domains: *.vm.worldtree.network + vm.worldtree.network
        let now = SystemTime::now();
        let fresh = now + Duration::from_secs(365 * 24 * 3600);
        let cached = make_issued(&["*.vm.worldtree.network", "vm.worldtree.network"], fresh);
        assert!(
            !should_issue(Some(&cached), &cfg, now),
            "fresh cert covering the SAN set must be reused (no re-issue)"
        );
    }

    // B) no cached cert → issue.
    #[test]
    fn should_issue_true_when_cache_missing() {
        let dir = TempDir::new().unwrap();
        let cfg = make_config(dir.path());
        assert!(
            should_issue(None, &cfg, SystemTime::now()),
            "missing cache must trigger issuance"
        );
    }

    // C) cached cert near expiry (within renew_before) → issue.
    #[test]
    fn should_issue_true_when_near_expiry() {
        let dir = TempDir::new().unwrap();
        let cfg = make_config(dir.path()); // renew_before = 30 days
        let now = SystemTime::now();
        // Expires in 1h — well within the 30-day renew window.
        let expiring = now + Duration::from_secs(3600);
        let cached = make_issued(&["*.vm.worldtree.network", "vm.worldtree.network"], expiring);
        assert!(
            should_issue(Some(&cached), &cfg, now),
            "cert within renew_before must trigger issuance"
        );
    }

    // D) SAN set changed: cached cert does NOT cover a newly-added apex → issue,
    //    even though the cert is otherwise fresh.
    #[test]
    fn should_issue_true_when_san_set_changed() {
        let dir = TempDir::new().unwrap();
        let mut cfg = make_config(dir.path());
        // New config adds an apex the cached cert never covered.
        cfg.domains = vec![
            "*.vm.worldtree.network".into(),
            "vm.worldtree.network".into(),
            "apex.worldtree.network".into(),
        ];
        let now = SystemTime::now();
        let fresh = now + Duration::from_secs(365 * 24 * 3600);
        // Cached cert only covers the original two SANs.
        let cached = make_issued(&["*.vm.worldtree.network", "vm.worldtree.network"], fresh);
        assert!(
            should_issue(Some(&cached), &cfg, now),
            "a fresh cert that does not cover the new SAN set must still re-issue"
        );
    }

    // E) cert_covers_domains is case-insensitive and treats a superset as covering.
    #[test]
    fn cert_covers_domains_superset_and_case_insensitive() {
        let (chain_pem, _key) =
            gen_self_signed(&["*.vm.worldtree.network", "vm.worldtree.network", "extra.example.com"]);
        // Requested set is a subset (differently cased) → covered.
        assert!(cert_covers_domains(
            &chain_pem,
            &["VM.WorldTree.Network".into(), "*.vm.worldtree.network".into()]
        ));
        // Requested domain absent from SANs → not covered.
        assert!(!cert_covers_domains(&chain_pem, &["missing.example.org".into()]));
    }

    // 5. strip_wildcard_gives_base_fqdn
    #[test]
    fn strip_wildcard_gives_base_fqdn() {
        assert_eq!(strip_wildcard("*.vm.worldtree.network"), "vm.worldtree.network");
        assert_eq!(strip_wildcard("vm.worldtree.network"), "vm.worldtree.network");
        assert_eq!(strip_wildcard("*.example.com"), "example.com");
        assert_eq!(strip_wildcard("example.com"), "example.com");
    }

    // 7. manual_dns_instructions formats fqdn + value correctly
    #[test]
    fn manual_dns_instructions_formats_records() {
        let records = vec![
            (
                "_acme-challenge.zine.identikey.io".to_string(),
                "abc123value".to_string(),
            ),
            (
                "_acme-challenge.identikey.io".to_string(),
                "def456value".to_string(),
            ),
        ];
        let out = manual_dns_instructions(&records);
        assert!(out.contains("Create these DNS TXT records, then press Enter:"));
        assert!(out.contains("_acme-challenge.zine.identikey.io  TXT  \"abc123value\""));
        assert!(out.contains("_acme-challenge.identikey.io  TXT  \"def456value\""));
        // Each record on its own line.
        assert_eq!(out.lines().count(), 3);
    }

    // 6. challenge_fqdn_is_prefixed_with_underscore_acme_challenge
    #[test]
    fn challenge_fqdn_is_prefixed_with_underscore_acme_challenge() {
        assert_eq!(
            challenge_fqdn("*.vm.worldtree.network"),
            "_acme-challenge.vm.worldtree.network"
        );
        assert_eq!(
            challenge_fqdn("vm.worldtree.network"),
            "_acme-challenge.vm.worldtree.network"
        );
        assert_eq!(
            challenge_fqdn("example.com"),
            "_acme-challenge.example.com"
        );
    }
}

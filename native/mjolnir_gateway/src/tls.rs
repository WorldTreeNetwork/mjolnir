//! TLS support for mjolnir-gateway: static cert loading and expiry-aware cert resolution.
//!
//! Caller must install a default CryptoProvider before calling `load_server_config`.
//! Typically: `rustls::crypto::ring::default_provider().install_default().expect("crypto provider")`.

// Items are pub for Task 1d wiring; dead_code is expected until then.
#![allow(dead_code)]

use arc_swap::ArcSwap;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::server::ResolvesServerCert;
use rustls::sign::CertifiedKey;
use rustls::ServerConfig;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fmt;
use std::io;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tracing::info;

// ── Error type ──────────────────────────────────────────────────────────────

/// Errors that can occur while loading or resolving TLS certificates.
#[derive(Debug)]
pub enum TlsError {
    Io(io::Error),
    CertParse(String),
    KeyParse(String),
    NoValidCerts,
    NoPrivateKey,
    KeyMismatch(String),
}

impl fmt::Display for TlsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TlsError::Io(e) => write!(f, "I/O error: {e}"),
            TlsError::CertParse(msg) => write!(f, "certificate parse error: {msg}"),
            TlsError::KeyParse(msg) => write!(f, "private key parse error: {msg}"),
            TlsError::NoValidCerts => write!(f, "no valid certificates found in PEM"),
            TlsError::NoPrivateKey => write!(f, "no private key found in PEM"),
            TlsError::KeyMismatch(msg) => write!(f, "certificate/key mismatch: {msg}"),
        }
    }
}

impl std::error::Error for TlsError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            TlsError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for TlsError {
    fn from(e: io::Error) -> Self {
        TlsError::Io(e)
    }
}

// ── Cert metadata ────────────────────────────────────────────────────────────

/// Metadata extracted from an X.509 end-entity certificate.
pub struct CertMetadata {
    pub fingerprint_sha256: String,
    pub not_before: SystemTime,
    pub not_after: SystemTime,
    pub issuer_cn: String,
}

// ── Parsing helpers ──────────────────────────────────────────────────────────

/// Parse a PEM-encoded certificate chain. Returns all certs found (at least one required).
pub fn parse_cert_chain(pem_bytes: &[u8]) -> Result<Vec<CertificateDer<'static>>, TlsError> {
    let mut reader = io::Cursor::new(pem_bytes);
    let certs: Vec<CertificateDer<'static>> = rustls_pemfile::certs(&mut reader)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| TlsError::CertParse(e.to_string()))?;

    if certs.is_empty() {
        return Err(TlsError::NoValidCerts);
    }
    Ok(certs)
}

/// Parse a PEM-encoded private key. Accepts PKCS#8, RSA, and SEC1/EC formats.
pub fn parse_private_key(pem_bytes: &[u8]) -> Result<PrivateKeyDer<'static>, TlsError> {
    let mut reader = io::Cursor::new(pem_bytes);
    rustls_pemfile::private_key(&mut reader)
        .map_err(|e| TlsError::KeyParse(e.to_string()))?
        .ok_or(TlsError::NoPrivateKey)
}

/// Extract metadata from a DER-encoded X.509 certificate.
pub fn extract_cert_metadata(cert_der: &[u8]) -> Result<CertMetadata, TlsError> {
    use x509_parser::prelude::*;

    // SHA-256 fingerprint of the raw DER bytes.
    let mut hasher = Sha256::new();
    hasher.update(cert_der);
    let digest = hasher.finalize();
    let fingerprint_sha256 = hex::encode(digest);

    let (_, cert) = X509Certificate::from_der(cert_der)
        .map_err(|e| TlsError::CertParse(format!("x509 parse: {e}")))?;

    // Convert ASN.1 GeneralizedTime -> SystemTime via unix timestamp.
    let not_before = asn1_time_to_system_time(cert.validity().not_before.timestamp())
        .ok_or_else(|| TlsError::CertParse("invalid not_before timestamp".into()))?;
    let not_after = asn1_time_to_system_time(cert.validity().not_after.timestamp())
        .ok_or_else(|| TlsError::CertParse("invalid not_after timestamp".into()))?;

    // Pull the issuer CN (first CN value found, or empty string).
    let issuer_cn = cert
        .issuer()
        .iter_common_name()
        .next()
        .and_then(|attr| attr.as_str().ok())
        .unwrap_or("")
        .to_owned();

    Ok(CertMetadata {
        fingerprint_sha256,
        not_before,
        not_after,
        issuer_cn,
    })
}

fn asn1_time_to_system_time(unix_secs: i64) -> Option<SystemTime> {
    if unix_secs >= 0 {
        SystemTime::UNIX_EPOCH.checked_add(Duration::from_secs(unix_secs as u64))
    } else {
        SystemTime::UNIX_EPOCH.checked_sub(Duration::from_secs(unix_secs.unsigned_abs()))
    }
}

// ── Expiry-aware resolver ────────────────────────────────────────────────────

/// Returns `true` when the certificate is within `fail_within` of `not_after`
/// (or already expired). Extracted as a pure function for testability.
pub(crate) fn should_refuse_handshake(
    not_after: SystemTime,
    fail_within: Duration,
    now: SystemTime,
) -> bool {
    match not_after.duration_since(now) {
        Ok(remaining) => remaining < fail_within,
        Err(_) => true, // already expired
    }
}

/// A `ResolvesServerCert` that refuses handshakes when the certificate is
/// close to expiry, and supports atomic hot-swap for SIGHUP-driven reload.
pub struct ExpiryAwareResolver {
    certified_key: ArcSwap<CertifiedKey>,
    fail_within: Duration,
    pub not_after: std::sync::RwLock<SystemTime>,
}

impl ExpiryAwareResolver {
    pub(crate) fn new(key: Arc<CertifiedKey>, fail_within: Duration, not_after: SystemTime) -> Self {
        Self {
            certified_key: ArcSwap::from(key),
            fail_within,
            not_after: std::sync::RwLock::new(not_after),
        }
    }

    /// Read the expiry time of the currently-loaded certificate.
    pub fn current_not_after(&self) -> SystemTime {
        self.not_after.read().map(|g| *g).unwrap_or(SystemTime::UNIX_EPOCH)
    }

    /// Atomically replace the active certificate. Called by the SIGHUP handler.
    pub fn swap(&self, new: Arc<CertifiedKey>, new_not_after: SystemTime) {
        self.certified_key.store(new);
        if let Ok(mut guard) = self.not_after.write() {
            *guard = new_not_after;
        }
    }
}

impl ResolvesServerCert for ExpiryAwareResolver {
    fn resolve(
        &self,
        _client_hello: rustls::server::ClientHello<'_>,
    ) -> Option<Arc<CertifiedKey>> {
        let not_after = *self.not_after.read().ok()?;
        if should_refuse_handshake(not_after, self.fail_within, SystemTime::now()) {
            return None;
        }
        Some(self.certified_key.load_full())
    }
}

// Ensure the compiler sees the impl without warnings.
impl fmt::Debug for ExpiryAwareResolver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ExpiryAwareResolver")
            .field("fail_within", &self.fail_within)
            .finish_non_exhaustive()
    }
}

// ── SNI multi-cert resolver ──────────────────────────────────────────────────

/// A bring-your-own certificate keyed by SNI hostname. `not_after` is the
/// end-entity cert's expiry, used to refuse handshakes near expiry (mirrors the
/// primary's policy).
#[derive(Clone)]
pub struct CertEntryRuntime {
    pub key: Arc<CertifiedKey>,
    pub not_after: SystemTime,
}

/// Build a `CertifiedKey` from PEM chain + key bytes, returning the key together
/// with the end-entity cert's `not_after`. Shared by the static, ACME, and BYO
/// (SNI) load paths.
pub fn build_certified_key(
    chain_pem: &[u8],
    key_pem: &[u8],
) -> Result<(Arc<CertifiedKey>, SystemTime), TlsError> {
    let cert_chain = parse_cert_chain(chain_pem)?;
    let key_der = parse_private_key(key_pem)?;
    let meta = extract_cert_metadata(cert_chain[0].as_ref())?;
    let signing_key = rustls::crypto::ring::sign::any_supported_type(&key_der)
        .map_err(|e| TlsError::KeyMismatch(e.to_string()))?;
    let certified_key = Arc::new(CertifiedKey::new(cert_chain, signing_key));
    Ok((certified_key, meta.not_after))
}

/// Pure SNI → extra-cert selection. Returns the matching extra cert's key when
/// `sni` exactly matches a map entry (case-insensitive) and that cert is not
/// within `fail_within` of expiry; otherwise `None` (caller falls back to the
/// primary). Factored out so it can be unit-tested without a real `ClientHello`.
pub(crate) fn select_extra(
    extra: &HashMap<String, CertEntryRuntime>,
    sni: Option<&str>,
    fail_within: Duration,
    now: SystemTime,
) -> Option<Arc<CertifiedKey>> {
    let sni = sni?;
    let entry = extra.get(&sni.to_ascii_lowercase())?;
    if should_refuse_handshake(entry.not_after, fail_within, now) {
        return None;
    }
    Some(Arc::clone(&entry.key))
}

/// A `ResolvesServerCert` that serves a per-host certificate selected by SNI,
/// falling back to a primary `ExpiryAwareResolver` (ACME wildcard or static)
/// when no extra cert matches. The extra-cert map is hot-swappable for SIGHUP;
/// the primary is hot-swappable for ACME renewal.
pub struct SniCertResolver {
    primary: Arc<ExpiryAwareResolver>,
    extra: ArcSwap<HashMap<String, CertEntryRuntime>>,
    fail_within: Duration,
}

impl SniCertResolver {
    pub fn new(
        primary: Arc<ExpiryAwareResolver>,
        fail_within: Duration,
        extra: HashMap<String, CertEntryRuntime>,
    ) -> Self {
        Self {
            primary,
            extra: ArcSwap::from_pointee(extra),
            fail_within,
        }
    }

    /// Swap the primary cert (ACME renewal). The extra-cert map is unaffected.
    pub fn swap_primary(&self, key: Arc<CertifiedKey>, not_after: SystemTime) {
        self.primary.swap(key, not_after);
    }

    /// Atomically replace the extra-cert map (SIGHUP hot-load).
    pub fn swap_extra(&self, map: HashMap<String, CertEntryRuntime>) {
        self.extra.store(Arc::new(map));
    }
}

impl ResolvesServerCert for SniCertResolver {
    fn resolve(&self, client_hello: rustls::server::ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        let extra = self.extra.load();
        if let Some(key) = select_extra(
            &extra,
            client_hello.server_name(),
            self.fail_within,
            SystemTime::now(),
        ) {
            return Some(key);
        }
        self.primary.resolve(client_hello)
    }
}

impl fmt::Debug for SniCertResolver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SniCertResolver")
            .field("fail_within", &self.fail_within)
            .field("extra_count", &self.extra.load().len())
            .finish_non_exhaustive()
    }
}

// ── Main entry points ─────────────────────────────────────────────────────────

/// Build a TLS `ServerConfig` from in-memory PEM bytes (ACME / hot-swap path).
/// Returns the `ServerConfig` and the `ExpiryAwareResolver` so callers can
/// read `not_after` and call `swap()` on renewal.
pub fn load_server_config_from_bytes(
    chain_pem: &[u8],
    key_pem: &[u8],
    session_cache: usize,
    fail_within: Duration,
) -> Result<(Arc<ServerConfig>, Arc<ExpiryAwareResolver>), TlsError> {
    let cert_chain = parse_cert_chain(chain_pem)?;
    let key_der = parse_private_key(key_pem)?;

    let meta = extract_cert_metadata(cert_chain[0].as_ref())?;

    let signing_key = rustls::crypto::ring::sign::any_supported_type(&key_der)
        .map_err(|e| TlsError::KeyMismatch(e.to_string()))?;

    let certified_key = Arc::new(CertifiedKey::new(cert_chain, signing_key));

    let resolver = Arc::new(ExpiryAwareResolver::new(
        certified_key,
        fail_within,
        meta.not_after,
    ));

    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_cert_resolver(Arc::clone(&resolver) as Arc<dyn ResolvesServerCert>);

    config.session_storage = rustls::server::ServerSessionMemoryCache::new(session_cache);
    // HTTP/1.1 only. `sites_serve::serve_connection` runs a hyper http1 server,
    // so adding b"h2" here breaks statically-served Sites (worldtree.network)
    // and NOTHING else — every other gateway path byte-shovels and is
    // ALPN-agnostic, so the breakage would look unrelated to this line.
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    config.max_early_data_size = 0;

    info!(
        event = "cert.loaded",
        fingerprint_sha256 = %meta.fingerprint_sha256,
        not_after = %humantime::format_rfc3339_seconds(meta.not_after),
        source = "acme",
        "TLS certificate loaded from memory"
    );

    Ok((Arc::new(config), resolver))
}

/// Build a TLS `ServerConfig` whose cert resolver is an [`SniCertResolver`]:
/// per-host bring-your-own certs selected by SNI, falling back to a primary
/// `ExpiryAwareResolver` (built from `primary_chain_pem`/`primary_key_pem`).
///
/// Returns the `ServerConfig` and the `SniCertResolver` so the caller can
/// `swap_primary` on ACME renewal and `swap_extra` on SIGHUP.
pub fn load_server_config_with_sni(
    primary_chain_pem: &[u8],
    primary_key_pem: &[u8],
    extra: HashMap<String, CertEntryRuntime>,
    session_cache: usize,
    fail_within: Duration,
) -> Result<(Arc<ServerConfig>, Arc<SniCertResolver>), TlsError> {
    let cert_chain = parse_cert_chain(primary_chain_pem)?;
    let key_der = parse_private_key(primary_key_pem)?;
    let meta = extract_cert_metadata(cert_chain[0].as_ref())?;

    let signing_key = rustls::crypto::ring::sign::any_supported_type(&key_der)
        .map_err(|e| TlsError::KeyMismatch(e.to_string()))?;
    let certified_key = Arc::new(CertifiedKey::new(cert_chain, signing_key));

    let primary = Arc::new(ExpiryAwareResolver::new(
        certified_key,
        fail_within,
        meta.not_after,
    ));
    let sni_resolver = Arc::new(SniCertResolver::new(primary, fail_within, extra));

    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_cert_resolver(Arc::clone(&sni_resolver) as Arc<dyn ResolvesServerCert>);

    config.session_storage = rustls::server::ServerSessionMemoryCache::new(session_cache);
    // HTTP/1.1 only — see the note on the other alpn_protocols assignments in
    // this file. `sites_serve::serve_connection` is a hyper http1 server and is
    // the only path that breaks if b"h2" is added here.
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    config.max_early_data_size = 0;

    info!(
        event = "cert.loaded",
        fingerprint_sha256 = %meta.fingerprint_sha256,
        not_after = %humantime::format_rfc3339_seconds(meta.not_after),
        source = "sni_primary",
        "TLS primary certificate loaded (SNI resolver)"
    );

    Ok((Arc::new(config), sni_resolver))
}

/// Load a TLS `ServerConfig` from PEM files and return it together with the
/// `ExpiryAwareResolver` so the caller can read cert metadata.
///
/// # Parameters
/// - `cert_path` — PEM file containing one or more X.509 certificates (chain).
/// - `key_path`  — PEM file containing the matching private key.
/// - `session_cache` — capacity of the TLS session cache.
/// - `fail_within` — refuse handshakes when the cert expires within this duration.
pub fn load_server_config(
    cert_path: &Path,
    key_path: &Path,
    session_cache: usize,
    fail_within: Duration,
) -> Result<(Arc<ServerConfig>, Arc<ExpiryAwareResolver>), TlsError> {
    let cert_pem = std::fs::read(cert_path)?;
    let key_pem = std::fs::read(key_path)?;

    let cert_chain = parse_cert_chain(&cert_pem)?;
    let key_der = parse_private_key(&key_pem)?;

    // Extract metadata from the end-entity cert (first in chain).
    let meta = extract_cert_metadata(cert_chain[0].as_ref())?;

    // Build signing key from the private key DER.
    let signing_key = rustls::crypto::ring::sign::any_supported_type(&key_der)
        .map_err(|e| TlsError::KeyMismatch(e.to_string()))?;

    let certified_key = Arc::new(CertifiedKey::new(cert_chain, signing_key));

    let resolver = Arc::new(ExpiryAwareResolver::new(
        certified_key,
        fail_within,
        meta.not_after,
    ));

    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_cert_resolver(Arc::clone(&resolver) as Arc<dyn ResolvesServerCert>);

    // Session resumption cache.
    config.session_storage = rustls::server::ServerSessionMemoryCache::new(session_cache);

    // ALPN: HTTP/1.1 only (h2 is gated behind a future feature flag).
    // TRIPWIRE: `sites_serve::serve_connection` is a hyper http1 server, so
    // adding b"h2" here breaks statically-served Sites (worldtree.network) and
    // NOTHING else — every other gateway path byte-shovels and is
    // ALPN-agnostic, so the breakage would look unrelated to this line.
    config.alpn_protocols = vec![b"http/1.1".to_vec()];

    // Explicitly disable TLS 1.3 early data / 0-RTT (default in rustls 0.23,
    // set explicitly for documentation and safety).
    config.max_early_data_size = 0;

    // Emit cert.loaded tracing event.
    let not_before_str = humantime::format_rfc3339_seconds(meta.not_before).to_string();
    let not_after_str = humantime::format_rfc3339_seconds(meta.not_after).to_string();
    info!(
        event = "cert.loaded",
        fingerprint_sha256 = %meta.fingerprint_sha256,
        not_before = %not_before_str,
        not_after = %not_after_str,
        issuer_cn = %meta.issuer_cn,
        source = "static",
        "TLS certificate loaded"
    );

    Ok((Arc::new(config), resolver))
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    // ── helpers ──────────────────────────────────────────────────────────────

    fn generate_self_signed(cn: &str) -> (Vec<u8>, Vec<u8>) {
        use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair};

        let mut params = CertificateParams::default();
        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, cn);
        params.distinguished_name = dn;
        params.not_before = rcgen::date_time_ymd(2024, 1, 1);
        params.not_after = rcgen::date_time_ymd(2026, 1, 1);

        let kp = KeyPair::generate().expect("keygen");
        let cert = params.self_signed(&kp).expect("self-sign");
        (cert.pem().into_bytes(), kp.serialize_pem().into_bytes())
    }

    fn install_provider() {
        let _ = rustls::crypto::ring::default_provider().install_default();
    }

    // ── Test 1: loads_valid_pem_chain_and_key ─────────────────────────────

    #[test]
    fn loads_valid_pem_chain_and_key() {
        install_provider();
        let (cert_pem, key_pem) = generate_self_signed("test-gateway");

        let dir = tempfile::tempdir().expect("tempdir");
        let cert_path = dir.path().join("cert.pem");
        let key_path = dir.path().join("key.pem");
        std::fs::write(&cert_path, &cert_pem).unwrap();
        std::fs::write(&key_path, &key_pem).unwrap();

        let result = load_server_config(&cert_path, &key_path, 128, Duration::from_secs(3600));
        assert!(result.is_ok(), "expected Ok, got: {:?}", result.err());

        let (_config, resolver) = result.unwrap();
        let na = *resolver.not_after.read().unwrap();
        assert!(na > SystemTime::UNIX_EPOCH);
    }

    // ── Test 2: rejects_malformed_cert ────────────────────────────────────

    #[test]
    fn rejects_malformed_cert() {
        install_provider();
        let dir = tempfile::tempdir().expect("tempdir");
        let cert_path = dir.path().join("bad_cert.pem");
        let key_path = dir.path().join("key.pem");

        std::fs::write(&cert_path, b"this is not a valid PEM cert").unwrap();
        // Key doesn't matter — cert parse should fail first.
        std::fs::write(&key_path, b"").unwrap();

        let result = load_server_config(&cert_path, &key_path, 128, Duration::from_secs(3600));
        assert!(
            matches!(
                result,
                Err(TlsError::NoValidCerts) | Err(TlsError::CertParse(_))
            ),
            "expected CertParse or NoValidCerts, got: {:?}",
            result
        );
    }

    // ── Test 3: rejects_missing_key ───────────────────────────────────────

    #[test]
    fn rejects_missing_key() {
        install_provider();
        let (cert_pem, _) = generate_self_signed("test-no-key");

        let dir = tempfile::tempdir().expect("tempdir");
        let cert_path = dir.path().join("cert.pem");
        let key_path = dir.path().join("key.pem");

        std::fs::write(&cert_path, &cert_pem).unwrap();
        // Write a cert PEM where a key is expected — no private key block.
        std::fs::write(&key_path, &cert_pem).unwrap();

        let result = load_server_config(&cert_path, &key_path, 128, Duration::from_secs(3600));
        assert!(
            matches!(result, Err(TlsError::NoPrivateKey)),
            "expected NoPrivateKey, got: {:?}",
            result
        );
    }

    // ── Test 4: expiry_policy_returns_none_when_within_fail_window ────────

    #[test]
    fn expiry_policy_returns_none_when_within_fail_window() {
        let now = SystemTime::now();
        let not_after = now + Duration::from_secs(3600); // expires in 1h
        let fail_within = Duration::from_secs(7200); // refuse if < 2h remaining

        assert!(
            should_refuse_handshake(not_after, fail_within, now),
            "should refuse when cert expires in 1h but fail_within=2h"
        );
    }

    // ── Test 5: expiry_policy_serves_when_cert_fresh ──────────────────────

    #[test]
    fn expiry_policy_serves_when_cert_fresh() {
        let now = SystemTime::now();
        let not_after = now + Duration::from_secs(365 * 24 * 3600); // 1 year out
        let fail_within = Duration::from_secs(24 * 3600); // refuse if < 1d remaining

        assert!(
            !should_refuse_handshake(not_after, fail_within, now),
            "should serve when cert is fresh"
        );
    }

    // ── Test 6: extract_cert_metadata_computes_sha256_fingerprint ─────────

    #[test]
    fn extract_cert_metadata_computes_sha256_fingerprint() {
        install_provider();
        let (cert_pem, _) = generate_self_signed("fingerprint-test");
        let certs = parse_cert_chain(&cert_pem).expect("parse chain");
        let meta = extract_cert_metadata(certs[0].as_ref()).expect("metadata");

        assert_eq!(
            meta.fingerprint_sha256.len(),
            64,
            "SHA-256 fingerprint should be 64 hex chars"
        );
        assert!(
            meta.fingerprint_sha256
                .chars()
                .all(|c| c.is_ascii_hexdigit()),
            "fingerprint should be lowercase hex"
        );
    }

    // ── Test 7: cert_loaded_event_emitted ─────────────────────────────────

    #[test]
    #[tracing_test::traced_test]
    fn cert_loaded_event_emitted() {
        install_provider();
        let (cert_pem, key_pem) = generate_self_signed("event-test-cn");

        let dir = tempfile::tempdir().expect("tempdir");
        let cert_path = dir.path().join("cert.pem");
        let key_path = dir.path().join("key.pem");
        std::fs::write(&cert_path, &cert_pem).unwrap();
        std::fs::write(&key_path, &key_pem).unwrap();

        load_server_config(&cert_path, &key_path, 128, Duration::from_secs(3600))
            .expect("load_server_config");

        assert!(logs_contain("cert.loaded"));
        assert!(logs_contain("source"));
        assert!(logs_contain("fingerprint_sha256"));
    }

    // ── SNI resolver selection (pure helper) ──────────────────────────────

    /// Build an `extra` map entry from a self-signed cert for `cn`, with the
    /// given `not_after`. The `not_after` is supplied explicitly so tests can
    /// simulate expired certs independent of the cert's real validity.
    fn extra_entry(cn: &str, not_after: SystemTime) -> CertEntryRuntime {
        install_provider();
        let (cert_pem, key_pem) = generate_self_signed(cn);
        let (key, _real_not_after) = build_certified_key(&cert_pem, &key_pem).expect("build key");
        CertEntryRuntime { key, not_after }
    }

    #[test]
    fn select_extra_returns_match_for_known_sni() {
        let now = SystemTime::now();
        let fresh = now + Duration::from_secs(365 * 24 * 3600);
        let mut extra = HashMap::new();
        extra.insert("zine.identikey.io".to_string(), extra_entry("zine", fresh));

        let got = select_extra(
            &extra,
            Some("zine.identikey.io"),
            Duration::from_secs(24 * 3600),
            now,
        );
        assert!(got.is_some(), "exact SNI match should return the extra cert");
    }

    #[test]
    fn select_extra_is_case_insensitive() {
        let now = SystemTime::now();
        let fresh = now + Duration::from_secs(365 * 24 * 3600);
        let mut extra = HashMap::new();
        extra.insert("zine.identikey.io".to_string(), extra_entry("zine", fresh));

        let got = select_extra(
            &extra,
            Some("ZINE.IdentiKey.IO"),
            Duration::from_secs(24 * 3600),
            now,
        );
        assert!(got.is_some(), "SNI match must be case-insensitive");
    }

    #[test]
    fn select_extra_returns_none_when_sni_absent() {
        let now = SystemTime::now();
        let fresh = now + Duration::from_secs(365 * 24 * 3600);
        let mut extra = HashMap::new();
        extra.insert("zine.identikey.io".to_string(), extra_entry("zine", fresh));

        let got = select_extra(&extra, None, Duration::from_secs(24 * 3600), now);
        assert!(got.is_none(), "no SNI → fall back to primary");
    }

    #[test]
    fn select_extra_returns_none_for_unmatched_sni() {
        let now = SystemTime::now();
        let fresh = now + Duration::from_secs(365 * 24 * 3600);
        let mut extra = HashMap::new();
        extra.insert("zine.identikey.io".to_string(), extra_entry("zine", fresh));

        let got = select_extra(
            &extra,
            Some("other.identikey.io"),
            Duration::from_secs(24 * 3600),
            now,
        );
        assert!(got.is_none(), "unmatched SNI → fall back to primary");
    }

    #[test]
    fn select_extra_refuses_expired_cert() {
        let now = SystemTime::now();
        // Expires in 1h, but fail_within is 24h → refuse, fall back to primary.
        let expiring = now + Duration::from_secs(3600);
        let mut extra = HashMap::new();
        extra.insert("zine.identikey.io".to_string(), extra_entry("zine", expiring));

        let got = select_extra(
            &extra,
            Some("zine.identikey.io"),
            Duration::from_secs(24 * 3600),
            now,
        );
        assert!(
            got.is_none(),
            "an extra cert within fail_within of expiry must fall back to primary"
        );
    }

    #[test]
    fn sni_resolver_swap_extra_replaces_map() {
        let now = SystemTime::now();
        let fresh = now + Duration::from_secs(365 * 24 * 3600);

        let (primary_cert, primary_key) = generate_self_signed("primary");
        let (sni_config, resolver) = load_server_config_with_sni(
            &primary_cert,
            &primary_key,
            HashMap::new(),
            128,
            Duration::from_secs(24 * 3600),
        )
        .expect("build sni config");
        // ServerConfig built and is usable.
        let _ = sni_config;

        let mut map = HashMap::new();
        map.insert("zine.identikey.io".to_string(), extra_entry("zine", fresh));
        resolver.swap_extra(map);

        // After swap, the pure selection over the live map should match.
        let live = resolver.extra.load();
        let got = select_extra(
            &live,
            Some("zine.identikey.io"),
            Duration::from_secs(24 * 3600),
            now,
        );
        assert!(got.is_some(), "swapped-in extra cert should be selectable");
    }
}

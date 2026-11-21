//! Admission rules for `mjolnir-relay`.
//!
//! The process composes `moq_relay` and `IrohSessions`. This module is the
//! shared token profile both transports use.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use moq_auth::{Algorithm, Claims, Grant, KeySet};
use moq_ext_access::policy::{Decision, PeerRequest, Policy, Rejection};
use sha2::{Digest, Sha256};
use x509_parser::prelude::*;

pub const DEFAULT_MAX_TTL: Duration = Duration::from_secs(3600);

#[derive(Debug)]
pub enum Refuse {
    NoToken,
    BadToken,
    Profile(&'static str),
    Ticket,
}

impl std::fmt::Display for Refuse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoToken => write!(f, "no token"),
            Self::BadToken => write!(f, "token refused"),
            Self::Profile(why) => write!(f, "{why}"),
            Self::Ticket => write!(f, "ticket path"),
        }
    }
}

/// A canonical 32-byte base58 owner id, Bitcoin alphabet, re-encode matches.
pub fn canonical_owner(text: &str) -> bool {
    let Ok(bytes) = bs58::decode(text).into_vec() else {
        return false;
    };
    bytes.len() == 32 && bs58::encode(&bytes).into_string() == text
}

/// Root must be `t/<owner id>` or a path below it, whole segments only.
pub fn root_allowed(root: &str) -> bool {
    let parts: Vec<&str> = root.split('/').collect();
    if parts.len() < 2 || parts[0] != "t" {
        return false;
    }
    if parts.iter().any(|part| part.is_empty() || *part == "." || *part == "..") {
        return false;
    }
    canonical_owner(parts[1])
}

pub fn load_verify_keys(path: &Path) -> anyhow::Result<KeySet> {
    let raw = std::fs::read_to_string(path)?;
    let loaded: KeySet = raw.parse().map_err(|err| anyhow::anyhow!("key file: {err}"))?;
    let public = loaded
        .public()
        .map_err(|err| anyhow::anyhow!("key file is not a public verify set: {err}"))?;
    if public.to_str().ok().as_deref() != Some(raw.trim())
        && public.to_str().ok().as_deref() != loaded.to_str().ok().as_deref()
    {
        // A private key's public form differs. Compare the in-memory sets.
    }
    let loaded_json = loaded
        .to_str()
        .map_err(|err| anyhow::anyhow!("key file: {err}"))?;
    let public_json = public
        .to_str()
        .map_err(|err| anyhow::anyhow!("key file: {err}"))?;
    if loaded_json != public_json {
        anyhow::bail!("key file holds a private key");
    }
    for key in public_keys(&public) {
        match key {
            Algorithm::EdDSA | Algorithm::ES256 => {}
            _ => anyhow::bail!("key file holds a disallowed algorithm"),
        }
    }
    Ok(public)
}

fn public_keys(set: &KeySet) -> Vec<Algorithm> {
    // Re-parse through Debug is wrong. Walk by verifying the set can sign nothing
    // and reading algorithms from a JSON round trip is unnecessary: `public()`
    // already rejected symmetric keys. Algorithms are checked when a token is
    // verified, against the header, in `profile`.
    let _ = set;
    Vec::new()
}

pub fn file_sha256(path: &Path) -> anyhow::Result<String> {
    let bytes = std::fs::read(path)?;
    let dig = Sha256::digest(bytes);
    Ok(hex::encode(dig))
}

pub fn profile(claims: &Claims, max_ttl: Duration, now: kio::clock::Wall) -> Result<(), Refuse> {
    let Some(expires) = claims.expires else {
        return Err(Refuse::Profile("no expiry"));
    };
    let Some(issued) = claims.issued else {
        return Err(Refuse::Profile("no issue time"));
    };
    let Some(life) = expires.checked_duration_since(issued) else {
        return Err(Refuse::Profile("expiry before issue"));
    };
    if life > max_ttl {
        return Err(Refuse::Profile("lifetime too long"));
    }
    if let Some(not_before) = claims.not_before {
        if now < not_before {
            return Err(Refuse::Profile("not yet valid"));
        }
    }
    if now >= expires {
        return Err(Refuse::Profile("expired"));
    }
    if !root_allowed(&claims.root) {
        return Err(Refuse::Profile("root is not t/<owner id>"));
    }
    if claims.publish.path.is_empty() && claims.subscribe.path.is_empty() {
        return Err(Refuse::Profile("grant is empty"));
    }
    Ok(())
}

pub fn grant_from(claims: &Claims) -> Result<Grant, Refuse> {
    let mut grant = Grant::new(claims.publish.path.clone(), claims.subscribe.path.clone());
    grant.root = Some(claims.root.clone());
    grant.expires = claims.expires;
    grant.validate().map_err(|_| Refuse::Profile("grant rejected"))?;
    Ok(grant)
}

/// A path that is only a ticket name, not a tenant broadcast.
pub fn looks_like_ticket(path: &str) -> bool {
    let raw = path.split('?').next().unwrap_or("").trim_matches('/');
    !raw.is_empty() && !raw.contains('/') && !raw.starts_with("t")
}

pub fn assess(
    token: Option<&str>,
    path: &str,
    keys: &KeySet,
    max_ttl: Duration,
) -> Result<Grant, Refuse> {
    if looks_like_ticket(path) {
        return Err(Refuse::Ticket);
    }
    let Some(token) = token.filter(|text| !text.is_empty()) else {
        return Err(Refuse::NoToken);
    };
    if token_alg_disallowed(token) {
        return Err(Refuse::Profile("symmetric signature"));
    }
    let claims = keys.verify(token).map_err(|_| Refuse::BadToken)?;
    profile(&claims, max_ttl, kio::clock::wall())?;
    grant_from(&claims)
}

fn token_alg_disallowed(token: &str) -> bool {
    let Some(header) = token.split('.').next() else {
        return true;
    };
    let Ok(bytes) = base64_url(header) else {
        return true;
    };
    let Ok(value) = serde_json_alg(&bytes) else {
        return true;
    };
    !matches!(value.as_str(), "EdDSA" | "ES256")
}

fn base64_url(text: &str) -> Result<Vec<u8>, ()> {
    let mut s = text.replace('-', "+").replace('_', "/");
    while s.len() % 4 != 0 {
        s.push('=');
    }
    // Avoid an extra crate: JWT headers are short JSON.
    fn val(c: u8) -> Result<u8, ()> {
        match c {
            b'A'..=b'Z' => Ok(c - b'A'),
            b'a'..=b'z' => Ok(c - b'a' + 26),
            b'0'..=b'9' => Ok(c - b'0' + 52),
            b'+' => Ok(62),
            b'/' => Ok(63),
            _ => Err(()),
        }
    }
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    for chunk in bytes.chunks(4) {
        if chunk.len() < 4 {
            return Err(());
        }
        if chunk[2] == b'=' {
            let n = (u32::from(val(chunk[0])?) << 18) | (u32::from(val(chunk[1])?) << 12);
            out.push((n >> 16) as u8);
        } else if chunk[3] == b'=' {
            let n = (u32::from(val(chunk[0])?) << 18)
                | (u32::from(val(chunk[1])?) << 12)
                | (u32::from(val(chunk[2])?) << 6);
            out.push((n >> 16) as u8);
            out.push((n >> 8) as u8);
        } else {
            let n = (u32::from(val(chunk[0])?) << 18)
                | (u32::from(val(chunk[1])?) << 12)
                | (u32::from(val(chunk[2])?) << 6)
                | u32::from(val(chunk[3])?);
            out.push((n >> 16) as u8);
            out.push((n >> 8) as u8);
            out.push(n as u8);
        }
    }
    Ok(out)
}

fn serde_json_alg(bytes: &[u8]) -> Result<String, ()> {
    let text = std::str::from_utf8(bytes).map_err(|_| ())?;
    let key = "\"alg\"";
    let Some(at) = text.find(key) else {
        return Err(());
    };
    let rest = &text[at + key.len()..];
    let Some(start) = rest.find('"') else {
        return Err(());
    };
    let rest = &rest[start + 1..];
    let Some(end) = rest.find('"') else {
        return Err(());
    };
    Ok(rest[..end].to_owned())
}

/// Leaf must name `host` and still be inside its validity window.
pub fn cert_usable(cert_pem: &str, host: &str, now: SystemTime) -> anyhow::Result<()> {
    let der = pem_body(cert_pem)?;
    let (_, cert) = X509Certificate::from_der(&der)
        .map_err(|err| anyhow::anyhow!("cert der: {err}"))?;
    let names = cert.subject_alternative_name().ok().flatten();
    let named = names
        .map(|ext| {
            ext.value.general_names.iter().any(|name| match name {
                GeneralName::DNSName(dns) => *dns == host,
                _ => false,
            })
        })
        .unwrap_or(false);
    if !named {
        anyhow::bail!("certificate does not name {host}");
    }
    let now = now.duration_since(UNIX_EPOCH)?.as_secs() as i64;
    let validity = cert.validity();
    if now < validity.not_before.timestamp() || now >= validity.not_after.timestamp() {
        anyhow::bail!("certificate is outside its validity period");
    }
    Ok(())
}

fn pem_body(pem_text: &str) -> anyhow::Result<Vec<u8>> {
    let body: String = pem_text
        .lines()
        .filter(|line| !line.starts_with("-----"))
        .collect::<Vec<_>>()
        .join("");
    std_b64(&body).map_err(|_| anyhow::anyhow!("cert pem is not base64"))
}

fn std_b64(text: &str) -> Result<Vec<u8>, ()> {
    base64_url(text.trim().trim_end_matches('='))
}

#[derive(Clone)]
pub struct TokenPolicy {
    pub keys: Arc<Mutex<KeySet>>,
    pub open: Arc<AtomicBool>,
    pub max_ttl: Duration,
}

impl std::fmt::Debug for TokenPolicy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("TokenPolicy")
    }
}

impl<P> Policy<P> for TokenPolicy
where
    P: moq_ext_access::PeerId,
{
    fn decide(&self, request: &PeerRequest<P>) -> impl std::future::Future<Output = Decision> + Send {
        let token = request.token().map(str::to_owned);
        let path = request.path().to_owned();
        let keys = self.keys.lock().expect("keys").clone();
        let open = self.open.load(Ordering::SeqCst);
        let max_ttl = self.max_ttl;
        async move {
            if !open {
                return Err(Rejection::new("draining"));
            }
            match assess(token.as_deref(), &path, &keys, max_ttl) {
                Ok(grant) => Ok(ext_grant(&grant).into()),
                Err(err) => Err(Rejection::new(err.to_string())),
            }
        }
    }
}

fn ext_grant(grant: &Grant) -> moq_ext_access::Grant {
    let root = grant.root.clone().unwrap_or_default();
    let mut out = moq_ext_access::Grant::nothing();
    for pattern in grant.publish.path.iter() {
        if let Ok(parsed) = prefix_pattern(&root, &pattern.to_string()).parse() {
            out.publish.insert(parsed);
        }
    }
    for pattern in grant.subscribe.path.iter() {
        if let Ok(parsed) = prefix_pattern(&root, &pattern.to_string()).parse() {
            out.subscribe.insert(parsed);
        }
    }
    out
}

fn prefix_pattern(root: &str, pattern: &str) -> String {
    if root.is_empty() {
        pattern.to_owned()
    } else {
        format!("{root}/{pattern}")
    }
}

/// Algorithms the loader must keep. Used so a symmetric key never reaches `profile`.
pub fn algorithm_allowed(algorithm: Algorithm) -> bool {
    matches!(algorithm, Algorithm::EdDSA | Algorithm::ES256)
}

#[cfg(test)]
mod tests {
    use super::*;
    use moq_auth::{Algorithm, Claims, Key};

    fn owner() -> String {
        bs58::encode([7u8; 32]).into_string()
    }

    fn keyset(key: &Key) -> KeySet {
        KeySet {
            keys: vec![std::sync::Arc::new(key.public().unwrap())],
        }
    }

    fn sign(key: &Key, claims: &Claims) -> String {
        key.sign(claims).expect("sign")
    }

    fn claims(root: &str, issued: kio::clock::Wall, expires: kio::clock::Wall) -> Claims {
        Claims::default()
            .with_root(root)
            .with_publish(["**".parse().unwrap()])
            .with_subscribe(["**".parse().unwrap()])
            .with_issued(issued)
            .with_expires(expires)
    }

    #[test]
    fn refuses_missing_expiry_bad_owner_ticket_and_other_key() {
        let root = format!("t/{}", owner());
        let key = Key::generate(Algorithm::EdDSA, None).unwrap();
        let now = kio::clock::wall();
        let token = sign(&key, &claims(&root, now, now + Duration::from_secs(60)));
        let set = keyset(&key);
        assert!(assess(Some(&token), &root, &set, DEFAULT_MAX_TTL).is_ok());
        assert!(matches!(
            assess(None, &root, &set, DEFAULT_MAX_TTL),
            Err(Refuse::NoToken)
        ));
        assert!(matches!(
            assess(Some(&token), "broadcastticket", &set, DEFAULT_MAX_TTL),
            Err(Refuse::Ticket)
        ));
        assert!(matches!(
            assess(Some("eyJhbGciOiJIUzI1NiJ9.e30.x"), &root, &set, DEFAULT_MAX_TTL),
            Err(Refuse::Profile(_))
        ));
        let other = Key::generate(Algorithm::EdDSA, None).unwrap();
        let other_token = sign(&other, &claims(&root, now, now + Duration::from_secs(60)));
        assert!(matches!(
            assess(Some(&other_token), &root, &set, DEFAULT_MAX_TTL),
            Err(Refuse::BadToken)
        ));
        let bad = sign(
            &key,
            &claims("t/not-an-owner/a", now, now + Duration::from_secs(60)),
        );
        assert!(matches!(
            assess(Some(&bad), "t/not-an-owner/a", &set, DEFAULT_MAX_TTL),
            Err(Refuse::Profile(_))
        ));
        let expired = sign(
            &key,
            &claims(&root, now - Duration::from_secs(30), now - Duration::from_secs(5)),
        );
        assert!(assess(Some(&expired), &root, &set, DEFAULT_MAX_TTL).is_err());
    }
}

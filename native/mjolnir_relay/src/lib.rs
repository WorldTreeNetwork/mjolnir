//! Admission rules for `mjolnir-relay`.
//!
//! The process composes `moq_relay` and `IrohSessions`. This module is the
//! shared token profile both transports use.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

mod iroh_sessions;
pub mod edge;
pub mod moq_session;

use moq_auth::{Algorithm, Claims, Grant, KeySet};
use moq_ext_access::policy::{Authorization, Decision, PeerRequest, Policy, Rejection};
use sha2::{Digest, Sha256};
use x509_parser::prelude::*;

pub const DEFAULT_MAX_TTL: Duration = Duration::from_secs(3600);

pub use iroh_sessions::IrohSessions;

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
    let loaded_json = loaded
        .to_str()
        .map_err(|err| anyhow::anyhow!("key file: {err}"))?;
    let public_json = public
        .to_str()
        .map_err(|err| anyhow::anyhow!("key file: {err}"))?;
    if loaded_json != public_json {
        anyhow::bail!("key file holds a private key");
    }
    let mut seen_kids = std::collections::BTreeSet::new();
    for key in &public.keys {
        let Some(kid) = &key.kid else {
            anyhow::bail!("key file holds a key with no kid");
        };
        if !algorithm_allowed(key.algorithm) {
            anyhow::bail!("key file holds a disallowed algorithm");
        }
        if !seen_kids.insert(format!("{kid:?}")) {
            anyhow::bail!("key file holds a duplicate kid");
        }
    }
    if public.keys.is_empty() {
        anyhow::bail!("key file holds no keys");
    }
    Ok(public)
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
    if issued > now + Duration::from_secs(5) {
        return Err(Refuse::Profile("issued in the future"));
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

/// The request path with the query removed and slashes trimmed.
pub fn request_path(path: &str) -> &str {
    path.split('?').next().unwrap_or("").trim_matches('/')
}

/// True when every segment is a tenant path `t/<canonical owner>/...`.
pub fn tenant_path(path: &str) -> bool {
    let raw = request_path(path);
    !raw.is_empty() && root_allowed(raw)
}

/// WebTransport admission. `attached` is a second token on a session that
/// is already open. The decider used to ignore that flag.
pub fn spawn_web_decider(
    mut admissions: moq_relay::auth::Admissions,
    keys: Arc<Mutex<KeySet>>,
    draining: Arc<AtomicBool>,
    keys_ok: Arc<AtomicBool>,
    max_ttl: Duration,
) {
    tokio::spawn(async move {
        while let Some(admission) = admissions.next().await {
            if draining.load(Ordering::SeqCst) {
                admission.refuse(moq_relay::auth::Error::Unavailable("draining".into()));
                continue;
            }
            if !keys_ok.load(Ordering::SeqCst) {
                admission.refuse(moq_relay::auth::Error::Unavailable("keys unavailable".into()));
                continue;
            }
            let path = admission.request.path.clone();
            let from_setup = admission.request.token.as_ref().and_then(|token| {
                String::from_utf8(token.value.clone()).ok()
            });
            let from_query = admission
                .request
                .query
                .as_deref()
                .and_then(jwt_query);
            let token = from_setup.or(from_query);
            let set = keys.lock().expect("keys").clone();
            match web_grant(admission.attached(), token.as_deref(), &path, &set, max_ttl) {
                Ok(grant) => match grant.validate() {
                    Ok(()) => admission.grant(moq_auth::lease::Consumer::fixed(grant)),
                    Err(err) => admission.refuse(err.into()),
                },
                Err(err) => {
                    admission.refuse(moq_relay::auth::Error::Forbidden(err.to_string()));
                }
            }
        }
    });
}

fn jwt_query(query: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == "jwt").then(|| value.to_string())
    })
}

pub fn web_grant(
    attached: bool,
    token: Option<&str>,
    path: &str,
    keys: &KeySet,
    max_ttl: Duration,
) -> Result<Grant, Refuse> {
    if attached {
        return Err(Refuse::Profile("in-band token"));
    }
    assess(token, path, keys, max_ttl)
}

pub fn assess(
    token: Option<&str>,
    path: &str,
    keys: &KeySet,
    max_ttl: Duration,
) -> Result<Grant, Refuse> {
    let raw = request_path(path);
    // A missing token is "no token" even when the path is not a tenant path.
    let Some(token) = token.filter(|text| !text.is_empty()) else {
        return Err(Refuse::NoToken);
    };
    // Tickets are not tenant paths. Pulls are off, and any other path is refused too.
    if !raw.is_empty() && !tenant_path(raw) {
        return Err(Refuse::Ticket);
    };
    if token_alg_disallowed(token) {
        return Err(Refuse::Profile("symmetric signature"));
    }
    let claims = keys.verify(token).map_err(|_| Refuse::BadToken)?;
    profile(&claims, max_ttl, kio::clock::wall())?;
    if !raw.is_empty() && !path_in_root(raw, &claims.root) {
        return Err(Refuse::Profile("path outside the grant"));
    }
    grant_from(&claims)
}

fn path_in_root(path: &str, root: &str) -> bool {
    path == root || path.starts_with(&format!("{root}/"))
}

fn token_alg_disallowed(token: &str) -> bool {
    let Some(header) = token.split('.').next() else {
        return true;
    };
    let Ok(bytes) = base64::Engine::decode(
        &base64::engine::general_purpose::URL_SAFE_NO_PAD,
        header,
    ) else {
        return true;
    };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return true;
    };
    !matches!(value.get("alg").and_then(|alg| alg.as_str()), Some("EdDSA" | "ES256"))
}

/// Leaf must name `host` and still be inside its validity window.
pub fn cert_usable(cert_pem: &str, host: &str, now: SystemTime) -> anyhow::Result<()> {
    let (_, der) = x509_parser::pem::parse_x509_pem(cert_pem.as_bytes())
        .map_err(|err| anyhow::anyhow!("cert pem: {err}"))?;
    let (_, cert) = X509Certificate::from_der(&der.contents)
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

/// The key file and its directory are root-owned and not writable by group
/// or other. A directory owner can replace the file even when the file
/// itself is not writable.
/// Remembers the mtime of the last key file that loaded. A failed load does
/// not update that mtime, so a later chmod of the same inode is tried again.
#[derive(Default)]
pub struct KeyWatch {
    loaded_mtime: Option<std::time::SystemTime>,
}

impl KeyWatch {
    pub fn observe(&mut self, path: &Path) -> anyhow::Result<Option<(KeySet, String)>> {
        let modified = std::fs::metadata(path).ok().and_then(|meta| meta.modified().ok());
        if self.loaded_mtime.is_some() && modified == self.loaded_mtime {
            return Ok(None);
        }
        match load_verify_keys(path).and_then(|set| {
            let hash = file_sha256(path)?;
            Ok((set, hash))
        }) {
            Ok(loaded) => {
                self.loaded_mtime = modified;
                Ok(Some(loaded))
            }
            Err(err) => Err(err),
        }
    }
}

pub fn key_file_trusted(path: &Path) -> anyhow::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let dir = path.parent().filter(|dir| !dir.as_os_str().is_empty()).ok_or_else(|| {
        anyhow::anyhow!("key file has no directory")
    })?;
    let dir_meta = std::fs::metadata(dir)?;
    if dir_meta.mode() & 0o022 != 0 {
        anyhow::bail!("key directory is writable by group or other");
    }
    if dir_meta.uid() != 0 {
        anyhow::bail!("key directory is not owned by root");
    }
    let meta = std::fs::metadata(path)?;
    if meta.mode() & 0o022 != 0 {
        anyhow::bail!("key file is writable by group or other");
    }
    if meta.uid() != 0 {
        anyhow::bail!("key file is not owned by root");
    }
    Ok(())
}

#[derive(Clone)]
pub struct TokenPolicy {
    pub keys: Arc<Mutex<KeySet>>,
    pub draining: Arc<AtomicBool>,
    pub keys_ok: Arc<AtomicBool>,
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
        let draining = self.draining.load(Ordering::SeqCst);
        let keys_ok = self.keys_ok.load(Ordering::SeqCst);
        let max_ttl = self.max_ttl;
        async move {
            if draining {
                return Err(Rejection::new("draining"));
            }
            if !keys_ok {
                return Err(Rejection::new("keys unavailable"));
            }
            match assess(token.as_deref(), &path, &keys, max_ttl) {
                Ok(grant) => {
                    let expires = grant.expires.map(SystemTime::from);
                    let mut authorization: Authorization = ext_grant(&grant).into();
                    authorization.expires = expires;
                    Ok(authorization)
                }
                Err(err) => Err(Rejection::new(err.to_string())),
            }
        }
    }
}

/// Reserved top-level segment. It is not `t/<owner id>`, so no token
/// subscribe pattern can name it. The client is not told the random child.
pub const NO_PUBLISH_SEGMENT: &str = "mjolnir-nopublish";

fn no_publish_pattern() -> String {
    let mut bytes = [0u8; 16];
    if std::fs::File::open("/dev/urandom")
        .and_then(|mut file| {
            use std::io::Read;
            file.read_exact(&mut bytes)
        })
        .is_err()
    {
        bytes = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos().to_le_bytes())
            .unwrap_or([0; 16]);
    }
    format!("{NO_PUBLISH_SEGMENT}/{}", hex::encode(bytes))
}

fn ext_grant(grant: &Grant) -> moq_ext_access::Grant {
    let root = grant.root.clone().unwrap_or_default();
    let mut out = moq_ext_access::Grant::nothing();
    // iroh-live calls origin.scope on the publish set. An empty set drops
    // the handshake. The stand-in is outside every token root and is a new
    // random path each session, so it cannot carry a broadcast a subscriber
    // can be told about, and the client cannot aim at it.
    let publish: Vec<String> = if grant.publish.path.is_empty() {
        vec![no_publish_pattern()]
    } else {
        grant.publish
            .path
            .iter()
            .map(|pattern| prefix_pattern(&root, &pattern.to_string()))
            .collect()
    };
    for pattern in &publish {
        if let Ok(parsed) = pattern.parse() {
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
            assess(None, "not-a-tenant", &set, DEFAULT_MAX_TTL),
            Err(Refuse::NoToken)
        ));
        let all: moq_auth::Pattern = "**".parse().unwrap();
        let mut empty = moq_auth::Grant::new(all.clone(), all);
        empty.publish = Default::default();
        empty.root = Some(root.clone());
        let first = format!("{:?}", ext_grant(&empty).publish);
        let second = format!("{:?}", ext_grant(&empty).publish);
        assert!(first.contains("mjolnir-nopublish/"), "{first}");
        assert!(!first.contains(&root), "{first}");
        assert_ne!(first, second);
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
            assess(Some(&bad), "", &set, DEFAULT_MAX_TTL),
            Err(Refuse::Profile(_))
        ));
        let expired = sign(
            &key,
            &claims(&root, now - Duration::from_secs(30), now - Duration::from_secs(5)),
        );
        assert!(assess(Some(&expired), &root, &set, DEFAULT_MAX_TTL).is_err());
        let no_exp = Claims::default()
            .with_root(&root)
            .with_publish(["**".parse().unwrap()])
            .with_subscribe(["**".parse().unwrap()])
            .with_issued(now);
        assert!(assess(Some(&sign(&key, &no_exp)), &root, &set, DEFAULT_MAX_TTL).is_err());
        let no_iat = Claims::default()
            .with_root(&root)
            .with_publish(["**".parse().unwrap()])
            .with_subscribe(["**".parse().unwrap()])
            .with_expires(now + Duration::from_secs(60));
        assert!(assess(Some(&sign(&key, &no_iat)), &root, &set, DEFAULT_MAX_TTL).is_err());
        let future = sign(
            &key,
            &claims(&root, now + Duration::from_secs(3600), now + Duration::from_secs(7200)),
        );
        assert!(
            matches!(
                assess(Some(&future), &root, &set, DEFAULT_MAX_TTL),
                Err(Refuse::Profile(_))
            ),
            "a future iat was accepted"
        );
        assert!(
            web_grant(true, Some(&token), &root, &set, DEFAULT_MAX_TTL).is_err(),
            "in-band token was admitted"
        );
        let long = sign(
            &key,
            &claims(&root, now, now + Duration::from_secs(7200)),
        );
        assert!(matches!(
            assess(Some(&long), &root, &set, Duration::from_secs(3600)),
            Err(Refuse::Profile(_))
        ));
        let outside = format!("{root}x/nope");
        assert!(assess(Some(&token), &outside, &set, DEFAULT_MAX_TTL).is_err());
    }

    #[test]
    fn room_rooted_token_isolates_rooms_and_participants_on_both_deciders() {
        let owner = owner();
        let room = format!("t/{owner}/standup");
        let other = format!("t/{owner}/other");
        let kid = moq_auth::KeyId::decode("room-kid").unwrap();
        let key = Key::generate(Algorithm::EdDSA, Some(kid)).unwrap();
        let now = kio::clock::wall();
        let claims = Claims::default()
            .with_root(&room)
            .with_publish(["alice/**".parse().unwrap()])
            .with_subscribe(["**".parse().unwrap()])
            .with_issued(now)
            .with_expires(now + Duration::from_secs(60));
        let token = sign(&key, &claims);
        let set = keyset(&key);
        // WebTransport calls web_grant. Iroh calls assess and then ext_grant.
        let grant = assess(Some(&token), &room, &set, DEFAULT_MAX_TTL).expect("own room");
        assert!(web_grant(false, Some(&token), &room, &set, DEFAULT_MAX_TTL).is_ok());
        assert!(
            assess(Some(&token), &other, &set, DEFAULT_MAX_TTL).is_err(),
            "cross-room read was admitted"
        );
        assert!(web_grant(false, Some(&token), &other, &set, DEFAULT_MAX_TTL).is_err());
        let published = format!("{:?}", ext_grant(&grant).publish);
        assert!(published.contains("standup/alice"), "{published}");
        assert!(!published.contains("bob"), "{published}");
        let subscribed = format!("{:?}", ext_grant(&grant).subscribe);
        assert!(subscribed.contains(&room), "{subscribed}");
        assert!(!subscribed.contains("other"), "{subscribed}");
    }

    #[test]
    fn elixir_eddsa_token_verifies() {
        let raw = include_str!("../tests/fixtures/elixir-eddsa.json");
        let value: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let token = value["token"].as_str().unwrap();
        let public = serde_json::json!({"keys": [value["public"]]}).to_string();
        let set: KeySet = public.parse().expect("public jwk");
        let claims = set.verify(token).expect("verify");
        assert_eq!(claims.root, "t/room");
        assert!(claims.expires.is_some());
        assert!(claims.issued.is_some());
    }

    #[test]
    fn loader_rejects_a_key_with_no_kid() {
        let dir = tempfile::tempdir().unwrap();
        let key = Key::generate(Algorithm::EdDSA, None).unwrap();
        let path = dir.path().join("keys.json");
        keyset(&key).to_file(&path).unwrap();
        match load_verify_keys(&path) {
            Ok(_) => panic!("a key with no kid was accepted"),
            Err(err) => assert!(err.to_string().contains("kid"), "{err}"),
        }
    }

    #[test]
    fn loader_rejects_a_disallowed_algorithm() {
        let dir = tempfile::tempdir().unwrap();
        let kid = moq_auth::KeyId::decode("wide-key").unwrap();
        let key = Key::generate(Algorithm::ES384, Some(kid)).unwrap();
        let path = dir.path().join("keys.json");
        keyset(&key).to_file(&path).unwrap();
        match load_verify_keys(&path) {
            Ok(_) => panic!("ES384 was accepted"),
            Err(err) => assert!(err.to_string().contains("algorithm"), "{err}"),
        }
    }

    #[test]
    fn loader_rejects_a_private_key_an_empty_set_and_a_duplicate_kid() {
        let dir = tempfile::tempdir().unwrap();
        let kid = moq_auth::KeyId::decode("same-kid").unwrap();
        let key = Key::generate(Algorithm::EdDSA, Some(kid)).unwrap();
        let private_path = dir.path().join("private.json");
        keyset(&key).to_file(&private_path).unwrap();
        let mut value: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&private_path).unwrap()).unwrap();
        value["keys"][0]["d"] = serde_json::json!("c2VjcmV0");
        std::fs::write(&private_path, value.to_string()).unwrap();
        let err = match load_verify_keys(&private_path) {
            Err(err) => err.to_string(),
            Ok(_) => panic!("private key accepted"),
        };
        assert!(err.contains("private"), "{err}");

        let empty = dir.path().join("empty.json");
        std::fs::write(&empty, r#"{"keys":[]}"#).unwrap();
        let err = match load_verify_keys(&empty) {
            Err(err) => err.to_string(),
            Ok(_) => panic!("empty set accepted"),
        };
        assert!(err.contains("no keys"), "{err}");

        let public = key.public().unwrap();
        let dup = dir.path().join("dup.json");
        let one = serde_json::to_value(&public).unwrap();
        std::fs::write(&dup, serde_json::json!({"keys": [one.clone(), one]}).to_string()).unwrap();
        let err = match load_verify_keys(&dup) {
            Err(err) => err.to_string(),
            Ok(_) => panic!("duplicate kid accepted"),
        };
        assert!(err.contains("duplicate kid"), "{err}");
    }

    #[test]
    fn a_key_file_that_becomes_readable_is_picked_up() {
        let dir = tempfile::tempdir().unwrap();
        let kid = moq_auth::KeyId::decode("readable").unwrap();
        let key = Key::generate(Algorithm::EdDSA, Some(kid)).unwrap();
        let path = dir.path().join("keys.json");
        keyset(&key).to_file(&path).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o000)).unwrap();
        let mut watch = KeyWatch::default();
        assert!(watch.observe(&path).is_err(), "an unreadable key file loaded");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let loaded = watch.observe(&path).expect("readable file");
        assert!(loaded.is_some(), "the same mtime was latched after the failed load");
    }

    #[test]
    fn group_writable_key_file_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("keys.json");
        std::fs::write(&path, "{}").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o664)).unwrap();
        let err = key_file_trusted(&path).unwrap_err().to_string();
        assert!(
            err.contains("writable") || err.contains("not owned by root"),
            "{err}"
        );
    }

    #[test]
    fn key_directory_writable_by_others_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("keys.json");
        std::fs::write(&path, "{}").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o777)).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let err = key_file_trusted(&path).unwrap_err().to_string();
        assert!(
            err.contains("key directory is writable by group or other"),
            "{err}"
        );
    }
}

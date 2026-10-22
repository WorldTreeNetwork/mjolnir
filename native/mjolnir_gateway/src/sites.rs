//! Sites-alias fallback resolver for custom-domain mappings.
//!
//! When the apex match table doesn't cover an incoming Host, the gateway can
//! optionally pull `(identikey_fp, site_name)` from Mjolnir's API and forward
//! the request to the configured Mjolnir backend.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::Deserialize;
use tokio::sync::Mutex;

use crate::config::SitesResolver;

pub const PARK_HOST: &str = "park.worldtree.network";

#[derive(Debug)]
struct CachedPark {
    dir: Option<PathBuf>,
    expires_at: Instant,
}

#[derive(Debug, Default)]
pub struct ParkSnapshotCache {
    entry: Mutex<Option<CachedPark>>,
}

impl ParkSnapshotCache {
    pub async fn resolve(&self, resolver: &SitesResolver) -> Option<PathBuf> {
        let mut entry = self.entry.lock().await;
        let now = Instant::now();
        if let Some(cached) = entry.as_ref() {
            if cached.expires_at > now {
                return cached.dir.clone();
            }
        }
        let dir = match lookup(resolver, PARK_HOST).await {
            LookupResult::Hit(_, site) => {
                let current = site.current_dir(&resolver.sites_root);
                crate::sites_serve::resolve_snapshot_dir(&resolver.sites_root, &current).await
            }
            LookupResult::Miss | LookupResult::Error => None,
        };
        let ttl = if dir.is_some() {
            Duration::from_secs(60)
        } else {
            Duration::from_secs(5)
        };
        *entry = Some(CachedPark {
            dir: dir.clone(),
            expires_at: now + ttl,
        });
        dir
    }
}

/// The `(identikey_fp, site_name)` pair an alias resolves to, already validated
/// as safe to use as filesystem path components (see [`validate_component`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SiteRef {
    pub identikey_fp: String,
    pub site_name: String,
}

impl SiteRef {
    /// The materialized snapshot directory for this site:
    /// `<sites_root>/<fp>/<site>/current`. Both components have already been
    /// validated, so this can never escape `sites_root`.
    pub fn current_dir(&self, sites_root: &Path) -> PathBuf {
        sites_root
            .join(&self.identikey_fp)
            .join(&self.site_name)
            .join("current")
    }
}

/// Result of an alias lookup. On hit the gateway knows *which* site the host
/// maps to; it serves that site from the materialized directory when one
/// exists, and otherwise forwards bytes unmodified to `resolver.backend`
/// (Mjolnir does the decrypt-per-request serving via its vanity-host handler).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LookupResult {
    Hit(SocketAddr, SiteRef),
    Miss,
    Error,
}

/// Wire shape of the `/api/sites/aliases/lookup` 200 response
/// (`lib/mjolnir/api/sites_router.ex`).
#[derive(Debug, Deserialize)]
struct LookupBody {
    identikey_fp: String,
    site_name: String,
}

/// True if `s` is safe to use verbatim as a single filesystem path component.
///
/// This is a real security boundary: a malicious or compromised Mjolnir
/// response must not be able to turn into an arbitrary filesystem read. We
/// allow only an explicit ASCII set and reject anything with a separator, a
/// NUL, a leading dot, or a `..` sequence.
pub fn validate_component(s: &str) -> bool {
    if s.is_empty() || s.len() > 128 {
        return false;
    }
    if s.starts_with('.') {
        return false;
    }
    s.bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
}

/// Hit Mjolnir's `/api/sites/aliases/lookup?host=<host>` endpoint.
///
/// Returns:
/// - `Hit(backend, site_ref)` on HTTP 200 with a well-formed, path-safe body
/// - `Miss` on HTTP 404
/// - `Error` on any other status, a transport failure, or a 200 whose body is
///   unparseable or carries a path-unsafe `identikey_fp`/`site_name` (caller
///   may log and fall through to its existing 404 response)
pub async fn lookup(resolver: &SitesResolver, host: &str) -> LookupResult {
    let encoded_host = percent_encode(host);
    let url = format!(
        "{}/api/sites/aliases/lookup?host={}",
        resolver.api_url.trim_end_matches('/'),
        encoded_host,
    );

    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(3))
        .build()
    {
        Ok(c) => c,
        Err(_) => return LookupResult::Error,
    };

    match client.get(&url).send().await {
        Ok(resp) if resp.status() == reqwest::StatusCode::OK => match resp
            .json::<LookupBody>()
            .await
        {
            Ok(body) => {
                if !validate_component(&body.identikey_fp) || !validate_component(&body.site_name) {
                    tracing::warn!(
                        event = "sites.unsafe_lookup_body",
                        host = %host,
                        identikey_fp = %body.identikey_fp,
                        site_name = %body.site_name,
                        "alias lookup returned a path-unsafe identity — refusing"
                    );
                    return LookupResult::Error;
                }
                LookupResult::Hit(
                    resolver.backend,
                    SiteRef {
                        identikey_fp: body.identikey_fp,
                        site_name: body.site_name,
                    },
                )
            }
            Err(_) => LookupResult::Error,
        },
        Ok(resp) if resp.status() == reqwest::StatusCode::NOT_FOUND => LookupResult::Miss,
        Ok(_) => LookupResult::Error,
        Err(_) => LookupResult::Error,
    }
}

/// Minimal percent-encoder: encodes characters that are not unreserved
/// (RFC 3986 §2.3) using `%XX` encoding. Sufficient for FQDN query values.
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            other => {
                use std::fmt::Write as _;
                let _ = write!(out, "%{:02X}", other);
            }
        }
    }
    out
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::SitesResolver;

    fn resolver_for(base_url: &str) -> SitesResolver {
        SitesResolver {
            api_url: base_url.to_owned(),
            backend: "127.0.0.1:4000".parse().unwrap(),
            sites_root: PathBuf::from(crate::config::DEFAULT_SITES_ROOT),
        }
    }

    #[tokio::test]
    async fn lookup_returns_hit_on_200() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/api/sites/aliases/lookup?host=blog.duke.io")
            .with_status(200)
            .with_body(r#"{"identikey_fp":"abc","site_name":"myblog"}"#)
            .create_async()
            .await;

        let resolver = resolver_for(&server.url());
        let result = lookup(&resolver, "blog.duke.io").await;
        assert_eq!(
            result,
            LookupResult::Hit(
                "127.0.0.1:4000".parse().unwrap(),
                SiteRef {
                    identikey_fp: "abc".into(),
                    site_name: "myblog".into(),
                },
            )
        );
    }

    /// A 200 whose body is not the expected JSON shape must not be treated as a
    /// hit — we have no identity to serve from.
    #[tokio::test]
    async fn lookup_returns_error_on_malformed_body() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/api/sites/aliases/lookup?host=blog.duke.io")
            .with_status(200)
            .with_body("not json")
            .create_async()
            .await;

        let resolver = resolver_for(&server.url());
        assert_eq!(lookup(&resolver, "blog.duke.io").await, LookupResult::Error);
    }

    /// Security: a compromised Mjolnir must not be able to walk the gateway out
    /// of `sites_root` via the lookup response.
    #[tokio::test]
    async fn lookup_rejects_traversal_in_response_body() {
        for body in [
            r#"{"identikey_fp":"../../etc","site_name":"myblog"}"#,
            r#"{"identikey_fp":"abc","site_name":"../../../etc/passwd"}"#,
            r#"{"identikey_fp":"a/b","site_name":"myblog"}"#,
            r#"{"identikey_fp":"abc","site_name":""}"#,
        ] {
            let mut server = mockito::Server::new_async().await;
            let _m = server
                .mock("GET", "/api/sites/aliases/lookup?host=evil.example.com")
                .with_status(200)
                .with_body(body)
                .create_async()
                .await;

            let resolver = resolver_for(&server.url());
            assert_eq!(
                lookup(&resolver, "evil.example.com").await,
                LookupResult::Error,
                "path-unsafe body must not produce a Hit: {body}"
            );
        }
    }

    #[test]
    fn validate_component_accepts_realistic_identities() {
        assert!(validate_component("z6MkfSomeBase58Fingerprint"));
        assert!(validate_component("wtnf-web"));
        assert!(validate_component("my_site.v2"));
    }

    #[test]
    fn validate_component_rejects_path_escapes() {
        assert!(!validate_component(""));
        assert!(!validate_component(".."));
        assert!(!validate_component("."));
        assert!(!validate_component("../etc"));
        assert!(!validate_component("a/b"));
        assert!(!validate_component("a\\b"));
        assert!(!validate_component("a\0b"));
        assert!(!validate_component(".hidden"));
        assert!(!validate_component(&"a".repeat(129)));
    }

    #[test]
    fn current_dir_is_confined_to_sites_root() {
        let site = SiteRef {
            identikey_fp: "abc".into(),
            site_name: "myblog".into(),
        };
        assert_eq!(
            site.current_dir(Path::new("/srv/sites")),
            PathBuf::from("/srv/sites/abc/myblog/current")
        );
    }

    #[tokio::test]
    async fn lookup_returns_miss_on_404() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/api/sites/aliases/lookup?host=unknown.example.com")
            .with_status(404)
            .with_body(r#"{"error":"not_found"}"#)
            .create_async()
            .await;

        let resolver = resolver_for(&server.url());
        let result = lookup(&resolver, "unknown.example.com").await;
        assert_eq!(result, LookupResult::Miss);
    }

    #[tokio::test]
    async fn lookup_returns_error_on_500() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/api/sites/aliases/lookup?host=broken.example.com")
            .with_status(500)
            .create_async()
            .await;

        let resolver = resolver_for(&server.url());
        let result = lookup(&resolver, "broken.example.com").await;
        assert_eq!(result, LookupResult::Error);
    }

    #[tokio::test]
    async fn lookup_returns_error_on_connection_failure() {
        // Port 1 is reserved; connection will be refused.
        let resolver = SitesResolver {
            api_url: "http://127.0.0.1:1".to_owned(),
            backend: "127.0.0.1:4000".parse().unwrap(),
            sites_root: PathBuf::from(crate::config::DEFAULT_SITES_ROOT),
        };
        let result = lookup(&resolver, "any.example.com").await;
        assert_eq!(result, LookupResult::Error);
    }

    #[test]
    fn percent_encode_plain_fqdn_unchanged() {
        assert_eq!(percent_encode("blog.duke.io"), "blog.duke.io");
    }

    #[test]
    fn percent_encode_encodes_special_chars() {
        // Spaces and slashes must be encoded.
        assert_eq!(percent_encode("a b"), "a%20b");
        assert_eq!(percent_encode("a/b"), "a%2Fb");
    }

    #[tokio::test]
    async fn lookup_url_encodes_host_with_special_chars() {
        let mut server = mockito::Server::new_async().await;
        // The host "foo bar.io" should arrive percent-encoded.
        let _m = server
            .mock("GET", "/api/sites/aliases/lookup?host=foo%20bar.io")
            .with_status(404)
            .create_async()
            .await;

        let resolver = resolver_for(&server.url());
        // We don't care about the result — just that mockito matched the URL.
        let _ = lookup(&resolver, "foo bar.io").await;
        _m.assert_async().await;
    }

    #[tokio::test]
    async fn park_failure_is_negative_cached() {
        let mut server = mockito::Server::new_async().await;
        let mock = server
            .mock(
                "GET",
                "/api/sites/aliases/lookup?host=park.worldtree.network",
            )
            .with_status(404)
            .expect(1)
            .create_async()
            .await;
        let resolver = resolver_for(&server.url());
        let cache = ParkSnapshotCache::default();
        assert!(cache.resolve(&resolver).await.is_none());
        assert!(cache.resolve(&resolver).await.is_none());
        mock.assert_async().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn park_success_is_cached_as_contained_snapshot_directory() {
        let mut server = mockito::Server::new_async().await;
        let mock = server
            .mock(
                "GET",
                "/api/sites/aliases/lookup?host=park.worldtree.network",
            )
            .with_status(200)
            .with_body(r#"{"identikey_fp":"parkfp","site_name":"park"}"#)
            .expect(1)
            .create_async()
            .await;
        let tmp = tempfile::tempdir().unwrap();
        let snapshot = tmp.path().join("parkfp/park/snapshots/h1");
        std::fs::create_dir_all(&snapshot).unwrap();
        std::fs::write(snapshot.join("404.html"), b"park").unwrap();
        std::os::unix::fs::symlink(&snapshot, tmp.path().join("parkfp/park/current")).unwrap();
        let resolver = SitesResolver {
            api_url: server.url(),
            backend: "127.0.0.1:4000".parse().unwrap(),
            sites_root: tmp.path().to_path_buf(),
        };
        let cache = ParkSnapshotCache::default();
        let canonical = tokio::fs::canonicalize(&snapshot).await.unwrap();
        assert_eq!(cache.resolve(&resolver).await.as_deref(), Some(canonical.as_path()));
        assert_eq!(cache.resolve(&resolver).await.as_deref(), Some(canonical.as_path()));
        mock.assert_async().await;
    }
}

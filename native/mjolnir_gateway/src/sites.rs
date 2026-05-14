//! Sites-alias fallback resolver for custom-domain mappings.
//!
//! When the apex match table doesn't cover an incoming Host, the gateway can
//! optionally pull `(identikey_fp, site_name)` from Mjolnir's API and forward
//! the request to the configured Mjolnir backend.

use std::net::SocketAddr;
use std::time::Duration;

use crate::config::SitesResolver;

/// Result of an alias lookup. On hit, the gateway forwards bytes unmodified
/// to the returned backend (Mjolnir does the actual serving via its own
/// vanity-host handler).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LookupResult {
    Hit(SocketAddr),
    Miss,
    Error,
}

/// Hit Mjolnir's `/api/sites/aliases/lookup?host=<host>` endpoint.
///
/// Returns:
/// - `Hit(backend)` on HTTP 200
/// - `Miss` on HTTP 404
/// - `Error` on any other status or transport failure (caller may log and fall
///   through to its existing 404 response)
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
        Ok(resp) if resp.status() == reqwest::StatusCode::OK => LookupResult::Hit(resolver.backend),
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
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'-'
            | b'.'
            | b'_'
            | b'~' => out.push(b as char),
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
        assert_eq!(result, LookupResult::Hit("127.0.0.1:4000".parse().unwrap()));
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
}

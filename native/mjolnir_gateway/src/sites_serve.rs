//! Serve IdentiKey Sites straight off disk from the materialized-plaintext tree.
//!
//! The Elixir publisher materializes every published snapshot to:
//!
//! ```text
//! <sites_root>/<identikey_fp>/<site_name>/snapshots/<snapshot_hash>/
//! <sites_root>/<identikey_fp>/<site_name>/current    -> symlink to the active snapshot
//! ```
//!
//! with precompressed `.br`/`.gz` siblings next to compressible files. When an
//! alias lookup resolves a Host to `(fp, site)` and that directory exists, the
//! gateway serves the request itself — no per-request decrypt round-trip to the
//! Mjolnir backend. When it doesn't exist (site published before materialization
//! existed, or mid-publish), the caller falls back to forwarding.
//!
//! Unlike the proxy paths in `main.rs` this one speaks HTTP rather than shovelling
//! bytes, so the already-consumed request header block is replayed into a hyper
//! HTTP/1 connection via [`PrefixedStream`].

use std::convert::Infallible;
use std::io;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

use bytes::Bytes;
use http::{header, HeaderMap, HeaderValue, Request, Response, StatusCode};
use http_body_util::{combinators::UnsyncBoxBody, BodyExt, Empty, Full};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper_util::rt::TokioIo;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tower::ServiceExt as _;
use tower_http::services::{ServeDir, ServeFile};
use tracing::{debug, warn};

/// Response body type after boxing — lets a `ServeDir` body and a synthesized
/// error body share one return type.
type SiteBody = UnsyncBoxBody<Bytes, io::Error>;

// ── Cache-Control policy ─────────────────────────────────────────────────────

/// SvelteKit content-hashes everything under this prefix, so it is safe to cache
/// forever at the edge and in the browser.
const IMMUTABLE_PREFIX: &str = "/_app/immutable/";

/// Content-hashed assets: cache forever.
const CC_IMMUTABLE: &str = "public, max-age=31536000, immutable";
/// HTML and directory indexes: always revalidate so a deploy goes live at once.
const CC_REVALIDATE: &str = "public, max-age=0, must-revalidate";
/// Everything else (favicons, images, fonts dropped at a stable path): a sane
/// middle default — cached for an hour, revalidated after.
const CC_DEFAULT: &str = "public, max-age=3600";

/// Pick the `Cache-Control` value for a request path. Driven purely by the path
/// (not the on-disk file), because Cloudflare keys its edge cache the same way.
fn cache_control_for(path: &str) -> &'static str {
    if path.starts_with(IMMUTABLE_PREFIX) {
        return CC_IMMUTABLE;
    }
    if path.ends_with('/') || path.ends_with(".html") {
        return CC_REVALIDATE;
    }
    // Extensionless paths are SvelteKit prerendered routes → HTML.
    match path.rsplit('/').next() {
        Some(last) if last.contains('.') => CC_DEFAULT,
        _ => CC_REVALIDATE,
    }
}

// ── Snapshot directory resolution ────────────────────────────────────────────

/// Resolve `<sites_root>/<fp>/<site>/current` to a canonical directory, or
/// `None` if it isn't a usable materialized snapshot.
///
/// `fp` and `site_name` have already been validated as single, separator-free
/// path components by [`crate::sites::validate_component`]. We canonicalize
/// anyway and re-assert containment in `sites_root`, so a hostile symlink
/// planted at `current` cannot point the gateway at, say, `/etc`.
pub async fn resolve_snapshot_dir(sites_root: &Path, current: &Path) -> Option<PathBuf> {
    let root = tokio::fs::canonicalize(sites_root).await.ok()?;
    let dir = tokio::fs::canonicalize(current).await.ok()?;
    if !tokio::fs::metadata(&dir).await.ok()?.is_dir() {
        return None;
    }
    if !dir.starts_with(&root) {
        warn!(
            event = "sites.snapshot_escapes_root",
            dir = %dir.display(),
            root = %root.display(),
            "materialized snapshot resolves outside sites_root — refusing to serve"
        );
        return None;
    }
    Some(dir)
}

// ── PrefixedStream ───────────────────────────────────────────────────────────

/// A stream that replays an already-consumed byte prefix before delegating to
/// the underlying transport. `handle_connection` reads the request header block
/// off the wire to route on `Host`; hyper needs to see those bytes again.
pub struct PrefixedStream<S> {
    prefix: Vec<u8>,
    pos: usize,
    inner: S,
}

impl<S> PrefixedStream<S> {
    pub fn new(prefix: Vec<u8>, inner: S) -> Self {
        Self {
            prefix,
            pos: 0,
            inner,
        }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for PrefixedStream<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let me = self.get_mut();
        if me.pos < me.prefix.len() {
            let remaining = &me.prefix[me.pos..];
            let n = remaining.len().min(buf.remaining());
            buf.put_slice(&remaining[..n]);
            me.pos += n;
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut me.inner).poll_read(cx, buf)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for PrefixedStream<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().inner).poll_write(cx, buf)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().inner).poll_write_vectored(cx, bufs)
    }
    fn is_write_vectored(&self) -> bool {
        self.inner.is_write_vectored()
    }
}

// ── Connection serving ───────────────────────────────────────────────────────

/// Serve an entire client connection from `dir` over HTTP/1.
///
/// `header_buf` is the request header block `handle_connection` already read;
/// it is replayed so hyper can parse the request. `expected_host` is the bare
/// (port-stripped, lowercased) Host the alias lookup was performed for — any
/// keep-alive request on this connection claiming a different Host gets a 421
/// rather than being served another site's content.
pub async fn serve_connection<S>(
    stream: S,
    header_buf: Vec<u8>,
    dir: PathBuf,
    expected_host: String,
) where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let dir = Arc::new(dir);
    let expected_host = Arc::new(expected_host);
    let io = TokioIo::new(PrefixedStream::new(header_buf, stream));

    let service = service_fn(move |req: Request<Incoming>| {
        let dir = dir.clone();
        let expected_host = expected_host.clone();
        async move { serve_request(&dir, &expected_host, req).await }
    });

    if let Err(e) = hyper::server::conn::http1::Builder::new()
        .serve_connection(io, service)
        .await
    {
        debug!(event = "sites.connection_error", error = %e, "static site connection ended");
    }
}

/// Handle one request against the snapshot directory.
async fn serve_request(
    dir: &Path,
    expected_host: &str,
    req: Request<Incoming>,
) -> Result<Response<SiteBody>, Infallible> {
    let host_ok = req
        .headers()
        .get(header::HOST)
        .and_then(|v| v.to_str().ok())
        .map(|h| {
            h.split(':')
                .next()
                .unwrap_or(h)
                .eq_ignore_ascii_case(expected_host)
        })
        .unwrap_or(false);
    if !host_ok {
        return Ok(text_response(
            StatusCode::MISDIRECTED_REQUEST,
            "Misdirected Request",
        ));
    }

    let path = req.uri().path().to_owned();
    let req_headers = req.headers().clone();

    let serve = ServeDir::new(dir)
        .precompressed_br()
        .precompressed_gzip()
        .append_index_html_on_directories(true);

    let mut resp = match serve.oneshot(req).await {
        Ok(r) => r.map(|body| body.boxed_unsync()),
        Err(e) => {
            warn!(event = "sites.serve_error", error = %e, "ServeDir failed");
            return Ok(text_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Internal Server Error",
            ));
        }
    };

    // A static site's miss is a 404, not an SPA rewrite: serve the snapshot's
    // own 404.html but keep the 404 status.
    if resp.status() == StatusCode::NOT_FOUND {
        return Ok(not_found_response(dir, &req_headers).await);
    }

    // tower-http emits Last-Modified but no ETag. Synthesize a strong-enough
    // validator from the two fields that do change when the bytes change, and
    // answer If-None-Match ourselves. Only for 200 — a 206 carries a partial
    // Content-Length and must not share the full entity's tag.
    if resp.status() == StatusCode::OK {
        if let Some(etag) = derive_etag(resp.headers()) {
            if if_none_match_matches(&req_headers, &etag) {
                let mut not_modified = Response::new(empty_body());
                *not_modified.status_mut() = StatusCode::NOT_MODIFIED;
                copy_validators(resp.headers(), not_modified.headers_mut());
                not_modified.headers_mut().insert(header::ETAG, etag);
                finish(&mut not_modified, &path);
                return Ok(not_modified);
            }
            resp.headers_mut().insert(header::ETAG, etag);
        }
    }

    finish(&mut resp, &path);
    Ok(resp)
}

/// Apply the Cache-Control policy and the `Vary` that precompression requires.
fn finish(resp: &mut Response<SiteBody>, path: &str) {
    resp.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static(cache_control_for(path)),
    );
    resp.headers_mut()
        .insert(header::VARY, HeaderValue::from_static("accept-encoding"));
}

/// Build the 404 response: the snapshot's `404.html` if it has one (honoring
/// precompressed siblings), with status 404 — never 200.
async fn not_found_response(dir: &Path, req_headers: &HeaderMap) -> Response<SiteBody> {
    let mut req = Request::new(Empty::<Bytes>::new());
    *req.uri_mut() = "/404.html".parse().expect("static uri");
    if let Some(ae) = req_headers.get(header::ACCEPT_ENCODING) {
        req.headers_mut()
            .insert(header::ACCEPT_ENCODING, ae.clone());
    }

    let serve = ServeFile::new(dir.join("404.html"))
        .precompressed_br()
        .precompressed_gzip();

    let mut resp = match serve.oneshot(req).await {
        Ok(r) if r.status() == StatusCode::OK => r.map(|body| body.boxed_unsync()),
        _ => {
            let mut plain = text_response(StatusCode::NOT_FOUND, "Not Found");
            finish(&mut plain, "/404.html");
            return plain;
        }
    };
    // ServeFile answers 200; this is a miss, so correct the status.
    *resp.status_mut() = StatusCode::NOT_FOUND;
    finish(&mut resp, "/404.html");
    resp
}

// ── ETag helpers ─────────────────────────────────────────────────────────────

/// Derive a validator from `Content-Length` + `Last-Modified`. Both change
/// whenever a publish rewrites the file, and each precompressed variant gets a
/// distinct tag because its length differs.
fn derive_etag(headers: &HeaderMap) -> Option<HeaderValue> {
    let len = headers.get(header::CONTENT_LENGTH)?.to_str().ok()?;
    let modified = headers.get(header::LAST_MODIFIED)?.to_str().ok()?;
    let digest = {
        use sha2::{Digest, Sha256};
        let mut h = Sha256::new();
        h.update(len.as_bytes());
        h.update(b"\0");
        h.update(modified.as_bytes());
        hex::encode(&h.finalize()[..16])
    };
    HeaderValue::from_str(&format!("\"{digest}\"")).ok()
}

/// RFC 9110 §13.1.2: `*` matches anything; otherwise compare against each
/// comma-separated candidate, ignoring a `W/` weakness prefix.
fn if_none_match_matches(headers: &HeaderMap, etag: &HeaderValue) -> bool {
    let Some(raw) = headers
        .get(header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
    else {
        return false;
    };
    let want = etag.to_str().unwrap_or_default();
    raw.split(',').any(|candidate| {
        let c = candidate.trim();
        c == "*" || c.strip_prefix("W/").unwrap_or(c) == want
    })
}

/// A 304 must carry the same validators the 200 would have.
fn copy_validators(from: &HeaderMap, to: &mut HeaderMap) {
    for name in [header::LAST_MODIFIED, header::CONTENT_TYPE] {
        if let Some(v) = from.get(&name) {
            to.insert(name, v.clone());
        }
    }
}

// ── Small response builders ──────────────────────────────────────────────────

fn empty_body() -> SiteBody {
    Empty::<Bytes>::new()
        .map_err(|never| match never {})
        .boxed_unsync()
}

fn text_response(status: StatusCode, body: &'static str) -> Response<SiteBody> {
    let mut resp = Response::new(
        Full::new(Bytes::from_static(body.as_bytes()))
            .map_err(|never| match never {})
            .boxed_unsync(),
    );
    *resp.status_mut() = status;
    resp.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    resp
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// Build a minimal materialized snapshot tree and return `(root, current)`.
    fn make_site(tmp: &tempfile::TempDir) -> (PathBuf, PathBuf) {
        let root = tmp.path().to_path_buf();
        let snap = root.join("fp1").join("mysite").join("snapshots").join("h1");
        std::fs::create_dir_all(snap.join("_app").join("immutable")).unwrap();
        std::fs::write(snap.join("index.html"), b"<h1>home</h1>").unwrap();
        std::fs::write(snap.join("index.html.br"), b"BROTLI-INDEX").unwrap();
        std::fs::write(snap.join("index.html.gz"), b"GZIP-INDEX").unwrap();
        std::fs::write(snap.join("404.html"), b"<h1>nope</h1>").unwrap();
        std::fs::write(snap.join("logo.png"), b"PNGDATA").unwrap();
        std::fs::write(
            snap.join("_app").join("immutable").join("app.abc123.js"),
            b"console.log(1)",
        )
        .unwrap();

        let current = root.join("fp1").join("mysite").join("current");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&snap, &current).unwrap();
        (root, current)
    }

    /// Drive one request through `serve_connection` over a duplex pair and
    /// return the raw response bytes — mirrors the connection-level tests in
    /// `main.rs`.
    async fn round_trip(dir: &Path, request: &str) -> String {
        let (client_end, server_end) = tokio::io::duplex(65536);
        let dir = dir.to_path_buf();

        let collected = Arc::new(tokio::sync::Mutex::new(Vec::new()));
        let sink = collected.clone();
        let req_bytes = request.as_bytes().to_vec();
        tokio::spawn(async move {
            let (mut cr, mut cw) = tokio::io::split(client_end);
            cw.write_all(&req_bytes).await.unwrap();
            let mut buf = Vec::new();
            let _ = cr.read_to_end(&mut buf).await;
            *sink.lock().await = buf;
        });

        // handle_connection reads the header block first, then hands the rest
        // (plus the replayed prefix) to hyper — do the same here.
        let header_end = request.find("\r\n\r\n").expect("header block") + 4;
        let header_buf = request.as_bytes()[..header_end].to_vec();
        let mut server_end = server_end;
        {
            // Consume exactly the header bytes off the wire so the prefix replay
            // is the only source of them.
            let mut scratch = vec![0u8; header_end];
            server_end.read_exact(&mut scratch).await.unwrap();
        }

        serve_connection(server_end, header_buf, dir, "blog.duke.io".into()).await;
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let bytes = collected.lock().await.clone();
        String::from_utf8_lossy(&bytes).into_owned()
    }

    #[tokio::test]
    async fn resolve_snapshot_dir_follows_current_symlink() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        let dir = resolve_snapshot_dir(&root, &current)
            .await
            .expect("resolves");
        assert!(dir.join("index.html").exists());
    }

    #[tokio::test]
    async fn resolve_snapshot_dir_none_when_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().to_path_buf();
        std::fs::create_dir_all(&root).unwrap();
        let missing = root.join("nobody").join("nosite").join("current");
        assert!(resolve_snapshot_dir(&root, &missing).await.is_none());
    }

    /// Security: a `current` symlink pointing outside `sites_root` must be
    /// refused rather than serving arbitrary files.
    #[cfg(unix)]
    #[tokio::test]
    async fn resolve_snapshot_dir_refuses_escape_via_symlink() {
        let tmp = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let root = tmp.path().join("sites");
        std::fs::create_dir_all(root.join("fp1").join("mysite")).unwrap();
        let current = root.join("fp1").join("mysite").join("current");
        std::os::unix::fs::symlink(outside.path(), &current).unwrap();
        assert!(
            resolve_snapshot_dir(&root, &current).await.is_none(),
            "a snapshot symlink escaping sites_root must not be served"
        );
    }

    #[tokio::test]
    async fn serves_index_html_for_root() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        let dir = resolve_snapshot_dir(&root, &current).await.unwrap();
        let resp = round_trip(
            &dir,
            "GET / HTTP/1.1\r\nHost: blog.duke.io\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(resp.starts_with("HTTP/1.1 200 OK"), "got: {resp}");
        assert!(resp.contains("<h1>home</h1>"), "got: {resp}");
    }

    #[tokio::test]
    async fn serves_precompressed_brotli_when_accepted() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        let dir = resolve_snapshot_dir(&root, &current).await.unwrap();
        let resp = round_trip(
            &dir,
            "GET / HTTP/1.1\r\nHost: blog.duke.io\r\nAccept-Encoding: br, gzip\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(
            resp.to_ascii_lowercase().contains("content-encoding: br"),
            "got: {resp}"
        );
        assert!(resp.contains("BROTLI-INDEX"), "got: {resp}");
    }

    #[tokio::test]
    async fn serves_precompressed_gzip_when_brotli_not_accepted() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        let dir = resolve_snapshot_dir(&root, &current).await.unwrap();
        let resp = round_trip(
            &dir,
            "GET / HTTP/1.1\r\nHost: blog.duke.io\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(
            resp.to_ascii_lowercase().contains("content-encoding: gzip"),
            "got: {resp}"
        );
        assert!(resp.contains("GZIP-INDEX"), "got: {resp}");
    }

    #[tokio::test]
    async fn missing_path_serves_404_html_with_404_status() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        let dir = resolve_snapshot_dir(&root, &current).await.unwrap();
        let resp = round_trip(
            &dir,
            "GET /nope HTTP/1.1\r\nHost: blog.duke.io\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(resp.starts_with("HTTP/1.1 404 Not Found"), "got: {resp}");
        assert!(
            resp.contains("<h1>nope</h1>"),
            "404.html body must be served: {resp}"
        );
    }

    #[tokio::test]
    async fn immutable_assets_get_immutable_cache_control() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        let dir = resolve_snapshot_dir(&root, &current).await.unwrap();
        let resp = round_trip(
            &dir,
            "GET /_app/immutable/app.abc123.js HTTP/1.1\r\nHost: blog.duke.io\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(resp.starts_with("HTTP/1.1 200 OK"), "got: {resp}");
        assert!(resp.contains(CC_IMMUTABLE), "got: {resp}");
    }

    #[tokio::test]
    async fn html_gets_revalidate_cache_control() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        let dir = resolve_snapshot_dir(&root, &current).await.unwrap();
        let resp = round_trip(
            &dir,
            "GET / HTTP/1.1\r\nHost: blog.duke.io\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(resp.contains(CC_REVALIDATE), "got: {resp}");
        assert!(
            !resp.contains("immutable"),
            "html must not be immutable: {resp}"
        );
    }

    #[tokio::test]
    async fn other_assets_get_default_cache_control() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        let dir = resolve_snapshot_dir(&root, &current).await.unwrap();
        let resp = round_trip(
            &dir,
            "GET /logo.png HTTP/1.1\r\nHost: blog.duke.io\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(resp.contains(CC_DEFAULT), "got: {resp}");
    }

    #[tokio::test]
    async fn conditional_get_returns_304() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        let dir = resolve_snapshot_dir(&root, &current).await.unwrap();

        let first = round_trip(
            &dir,
            "GET / HTTP/1.1\r\nHost: blog.duke.io\r\nConnection: close\r\n\r\n",
        )
        .await;
        let etag = first
            .lines()
            .find_map(|l| {
                l.strip_prefix("etag: ")
                    .or_else(|| l.strip_prefix("ETag: "))
            })
            .expect("etag header present")
            .trim()
            .to_owned();

        let second = round_trip(
            &dir,
            &format!("GET / HTTP/1.1\r\nHost: blog.duke.io\r\nIf-None-Match: {etag}\r\nConnection: close\r\n\r\n"),
        )
        .await;
        assert!(
            second.starts_with("HTTP/1.1 304 Not Modified"),
            "got: {second}"
        );
        assert!(
            !second.contains("<h1>home</h1>"),
            "304 must have no body: {second}"
        );
    }

    #[tokio::test]
    async fn range_request_returns_206() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        let dir = resolve_snapshot_dir(&root, &current).await.unwrap();
        let resp = round_trip(
            &dir,
            "GET /logo.png HTTP/1.1\r\nHost: blog.duke.io\r\nRange: bytes=0-2\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(
            resp.starts_with("HTTP/1.1 206 Partial Content"),
            "got: {resp}"
        );
        assert!(
            resp.to_ascii_lowercase()
                .contains("content-range: bytes 0-2/7"),
            "got: {resp}"
        );
    }

    /// Path traversal must not escape the snapshot directory.
    #[tokio::test]
    async fn path_traversal_is_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        std::fs::write(root.join("secret.txt"), b"TOP-SECRET").unwrap();
        let dir = resolve_snapshot_dir(&root, &current).await.unwrap();

        for target in [
            "/../../../secret.txt",
            "/..%2f..%2f..%2fsecret.txt",
            "/%2e%2e/%2e%2e/%2e%2e/secret.txt",
        ] {
            let resp = round_trip(
                &dir,
                &format!(
                    "GET {target} HTTP/1.1\r\nHost: blog.duke.io\r\nConnection: close\r\n\r\n"
                ),
            )
            .await;
            assert!(
                !resp.contains("TOP-SECRET"),
                "traversal {target} leaked a file outside the snapshot: {resp}"
            );
        }
    }

    /// A keep-alive request claiming a different Host must not be served this
    /// site's content.
    #[tokio::test]
    async fn wrong_host_returns_421() {
        let tmp = tempfile::tempdir().unwrap();
        let (root, current) = make_site(&tmp);
        let dir = resolve_snapshot_dir(&root, &current).await.unwrap();
        let resp = round_trip(
            &dir,
            "GET / HTTP/1.1\r\nHost: someone-else.example.com\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(
            resp.starts_with("HTTP/1.1 421 Misdirected Request"),
            "got: {resp}"
        );
    }

    #[test]
    fn cache_control_policy() {
        assert_eq!(
            cache_control_for("/_app/immutable/chunk.abc.js"),
            CC_IMMUTABLE
        );
        assert_eq!(cache_control_for("/"), CC_REVALIDATE);
        assert_eq!(cache_control_for("/about.html"), CC_REVALIDATE);
        assert_eq!(cache_control_for("/about"), CC_REVALIDATE);
        assert_eq!(cache_control_for("/logo.png"), CC_DEFAULT);
        assert_eq!(cache_control_for("/fonts/inter.woff2"), CC_DEFAULT);
    }

    #[tokio::test]
    async fn prefixed_stream_replays_then_delegates() {
        let (mut client, server) = tokio::io::duplex(1024);
        client.write_all(b"TAIL").await.unwrap();
        client.shutdown().await.unwrap();

        let mut s = PrefixedStream::new(b"HEAD".to_vec(), server);
        let mut out = Vec::new();
        s.read_to_end(&mut out).await.unwrap();
        assert_eq!(&out, b"HEADTAIL");
    }
}

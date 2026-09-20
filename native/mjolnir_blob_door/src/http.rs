use std::sync::Arc;

use axum::body::Body;
use axum::extract::{DefaultBodyLimit, Path, Request, State};
use axum::http::header::{CONTENT_LENGTH, CONTENT_TYPE};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get};
use axum::Router;
use futures_util::StreamExt;
use tokio_util::io::ReaderStream;

use crate::cache::DiskCache;
use crate::hash_from_base58;
use crate::pump::{pump_body, PumpError};
use crate::put::{put_file, PutError, PutOutcome};
use crate::store::{object_key, outboard_key, CanonicalStore, StoreError};

pub struct AppState<S> {
    pub store: Arc<S>,
    pub cache: Arc<DiskCache>,
    pub max_bytes: u64,
}

pub fn router<S: CanonicalStore + 'static>(state: AppState<S>) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/storage/blob/b3/{hash}", any(object::<S>))
        .layer(DefaultBodyLimit::disable())
        .with_state(Arc::new(state))
}

async fn health() -> &'static str {
    "ok"
}

fn split_obao(hash: &str) -> (&str, bool) {
    hash.strip_suffix(".obao")
        .map(|h| (h, true))
        .unwrap_or((hash, false))
}

fn content_length(headers: &HeaderMap) -> Option<u64> {
    headers
        .get(CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse().ok())
}

async fn object<S: CanonicalStore>(
    State(state): State<Arc<AppState<S>>>,
    Path(hash): Path<String>,
    req: Request,
) -> Response {
    let (hash, obao) = split_obao(&hash);
    let hash = hash.to_string();
    let method = req.method().clone();
    let headers = req.headers().clone();
    let body = req.into_body();

    match method.as_str() {
        "PUT" => put_one(state, &hash, obao, headers, body).await,
        "GET" => get_one(state, &hash, obao).await,
        "HEAD" if !obao => head_one(state, &hash).await,
        _ => StatusCode::METHOD_NOT_ALLOWED.into_response(),
    }
}

async fn put_one<S: CanonicalStore>(
    state: Arc<AppState<S>>,
    hash: &str,
    obao: bool,
    headers: HeaderMap,
    body: Body,
) -> Response {
    if let Some(n) = content_length(&headers) {
        if n > state.max_bytes {
            return (StatusCode::PAYLOAD_TOO_LARGE, "too large").into_response();
        }
    }
    let Some(claimed) = hash_from_base58(hash) else {
        return (StatusCode::BAD_REQUEST, "hash").into_response();
    };

    let mut incoming = match state.cache.create_incoming().await {
        Ok(inc) => inc,
        Err(e) if e.kind() == std::io::ErrorKind::StorageFull => {
            return (StatusCode::INSUFFICIENT_STORAGE, "disk full").into_response();
        }
        Err(e) => {
            tracing::error!(error = %e, "incoming create");
            return (StatusCode::INTERNAL_SERVER_ERROR, "cache").into_response();
        }
    };

    let mut hasher = blake3::Hasher::new();
    let hash_opt = if obao { None } else { Some(&mut hasher) };
    let len = match pump_body(body, incoming.file(), hash_opt, state.max_bytes).await {
        Ok(n) => n,
        Err(PumpError::TooLarge) => {
            return (StatusCode::PAYLOAD_TOO_LARGE, "too large").into_response();
        }
        Err(e) if e.is_full() => {
            return (StatusCode::INSUFFICIENT_STORAGE, "disk full").into_response();
        }
        Err(PumpError::Io(e)) => {
            tracing::error!(error = %e, "pump");
            return (StatusCode::BAD_GATEWAY, "read").into_response();
        }
    };

    if !obao {
        let actual = *hasher.finalize().as_bytes();
        if actual != claimed {
            return (StatusCode::BAD_REQUEST, "hash mismatch").into_response();
        }
    }

    if let Err(e) = incoming.close().await {
        tracing::error!(error = %e, "incoming close");
        return (StatusCode::INTERNAL_SERVER_ERROR, "cache").into_response();
    }

    let result = put_file(state.store.as_ref(), hash, &incoming.path, len, obao).await;
    match result {
        Ok(outcome) => {
            if let Err(e) = state.cache.promote(&mut incoming, hash, obao, len).await {
                tracing::warn!(error = %e, "cache promote");
            }
            match outcome {
                PutOutcome::Created => StatusCode::CREATED.into_response(),
                PutOutcome::AlreadyPresent => StatusCode::OK.into_response(),
            }
        }
        Err(PutError::HashMismatch) => (StatusCode::BAD_REQUEST, "hash mismatch").into_response(),
        Err(PutError::NotConfirmed) => {
            (StatusCode::SERVICE_UNAVAILABLE, "not confirmed").into_response()
        }
        Err(PutError::Backend(s)) => (StatusCode::BAD_GATEWAY, s).into_response(),
    }
}

async fn get_one<S: CanonicalStore>(state: Arc<AppState<S>>, hash: &str, obao: bool) -> Response {
    if let Some(path) = state.cache.get(hash, obao).await {
        return file_response(path).await;
    }

    let key = if obao {
        outboard_key(hash)
    } else {
        object_key(hash)
    };
    match state.store.get_stream(&key).await {
        Ok((len, upstream)) => {
            tee_and_cache(state.cache.clone(), hash.to_string(), obao, len, upstream).await
        }
        Err(StoreError::NotFound) => StatusCode::NOT_FOUND.into_response(),
        Err(StoreError::Backend(s)) => (StatusCode::BAD_GATEWAY, s).into_response(),
    }
}

async fn head_one<S: CanonicalStore>(state: Arc<AppState<S>>, hash: &str) -> Response {
    if let Some(path) = state.cache.get(hash, false).await {
        match tokio::fs::metadata(&path).await {
            Ok(meta) => {
                return Response::builder()
                    .status(StatusCode::OK)
                    .header(CONTENT_TYPE, "application/octet-stream")
                    .header(CONTENT_LENGTH, meta.len())
                    .body(Body::empty())
                    .unwrap_or_else(|_| StatusCode::OK.into_response());
            }
            Err(_) => {}
        }
    }
    match state.store.head(&object_key(hash)).await {
        Ok(len) => Response::builder()
            .status(StatusCode::OK)
            .header(CONTENT_TYPE, "application/octet-stream")
            .header(CONTENT_LENGTH, len)
            .body(Body::empty())
            .unwrap_or_else(|_| StatusCode::OK.into_response()),
        Err(StoreError::NotFound) => StatusCode::NOT_FOUND.into_response(),
        Err(StoreError::Backend(s)) => (StatusCode::BAD_GATEWAY, s).into_response(),
    }
}

async fn file_response(path: std::path::PathBuf) -> Response {
    let meta = match tokio::fs::metadata(&path).await {
        Ok(m) => m,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let file = match tokio::fs::File::open(&path).await {
        Ok(f) => f,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let stream = ReaderStream::new(file);
    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "application/octet-stream")
        .header(CONTENT_LENGTH, meta.len())
        .body(Body::from_stream(stream))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

async fn tee_and_cache(
    cache: Arc<DiskCache>,
    hash: String,
    obao: bool,
    len: u64,
    mut upstream: crate::store::BlobStream,
) -> Response {
    let mut incoming = match cache.create_incoming().await {
        Ok(inc) => inc,
        Err(_) => {
            // Cache unusable — still stream from origin.
            let stream = async_stream::stream! {
                while let Some(item) = upstream.next().await {
                    yield item;
                }
            };
            return stream_response(len, stream);
        }
    };
    let dest = cache.object_path(&hash, obao);
    let incoming_path = incoming.path.clone();
    // Drop Incoming without persist so Drop would delete — we take
    // ownership of the path and handle it in the stream. Forget Drop
    // by persisting only after a full fill; leak the Incoming file
    // handle by closing it into a tokio File we write in the stream.
    let mut file = incoming.take_file().expect("incoming file");
    // Incoming would Drop-delete the path when this function returns
    // (before the body stream runs). Mark persist; the stream
    // renames or unlinks.
    incoming.persist();

    let cache2 = cache.clone();
    let stream = async_stream::stream! {
        use tokio::io::AsyncWriteExt;
        let mut ok = true;
        let mut written = 0u64;
        while let Some(item) = upstream.next().await {
            match item {
                Ok(bytes) => {
                    if ok && file.write_all(&bytes).await.is_err() {
                        ok = false;
                    }
                    written += bytes.len() as u64;
                    yield Ok::<bytes::Bytes, std::io::Error>(bytes);
                }
                Err(e) => {
                    yield Err(e);
                    let _ = tokio::fs::remove_file(&incoming_path).await;
                    return;
                }
            }
        }
        if ok {
            let _ = file.flush().await;
            let _ = file.sync_all().await;
            drop(file);
            if len > 0 && written != len {
                let _ = tokio::fs::remove_file(&incoming_path).await;
                return;
            }
            if tokio::fs::rename(&incoming_path, &dest).await.is_ok() {
                cache2.account(written);
            } else {
                let _ = tokio::fs::remove_file(&incoming_path).await;
            }
        } else {
            drop(file);
            let _ = tokio::fs::remove_file(&incoming_path).await;
        }
    };
    stream_response(len, stream)
}

fn stream_response<St>(len: u64, stream: St) -> Response
where
    St: futures_util::Stream<Item = Result<bytes::Bytes, std::io::Error>> + Send + 'static,
{
    let mut builder = Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "application/octet-stream");
    if len > 0 {
        builder = builder.header(CONTENT_LENGTH, len);
    }
    builder
        .body(Body::from_stream(stream))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

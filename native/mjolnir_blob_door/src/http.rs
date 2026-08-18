use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::{Method, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get};
use axum::Router;
use bytes::Bytes;

use crate::put::{put_bytes, put_outboard, PutError, PutOutcome};
use crate::store::{object_key, outboard_key, CanonicalStore, StoreError};
use crate::{hash_from_base58, DEFAULT_MAX_BYTES};

pub struct AppState<S> {
    pub store: Arc<S>,
    pub max_bytes: usize,
}

impl<S> Default for AppState<S>
where
    S: Default,
{
    fn default() -> Self {
        Self {
            store: Arc::new(S::default()),
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }
}

pub fn router<S: CanonicalStore + 'static>(state: AppState<S>) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/storage/blob/b3/{hash}", any(object::<S>))
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

async fn object<S: CanonicalStore>(
    State(state): State<Arc<AppState<S>>>,
    Path(hash): Path<String>,
    method: Method,
    body: Bytes,
) -> Response {
    let (hash, obao) = split_obao(&hash);
    let hash = hash.to_string();

    match method.as_str() {
        "PUT" => put_one(state, &hash, obao, body).await,
        "GET" => get_one(state, &hash, obao).await,
        "HEAD" if !obao => head_one(state, &hash).await,
        _ => StatusCode::METHOD_NOT_ALLOWED.into_response(),
    }
}

async fn put_one<S: CanonicalStore>(
    state: Arc<AppState<S>>,
    hash: &str,
    obao: bool,
    body: Bytes,
) -> Response {
    if body.len() > state.max_bytes {
        return (StatusCode::PAYLOAD_TOO_LARGE, "too large").into_response();
    }
    let Some(claimed) = hash_from_base58(hash) else {
        return (StatusCode::BAD_REQUEST, "hash").into_response();
    };
    let result = if obao {
        put_outboard(state.store.as_ref(), &claimed, &body).await
    } else {
        put_bytes(state.store.as_ref(), &claimed, &body).await
    };
    match result {
        Ok(PutOutcome::Created) => StatusCode::CREATED.into_response(),
        Ok(PutOutcome::AlreadyPresent) => StatusCode::OK.into_response(),
        Err(PutError::HashMismatch) => (StatusCode::BAD_REQUEST, "hash mismatch").into_response(),
        Err(PutError::NotConfirmed) => {
            (StatusCode::SERVICE_UNAVAILABLE, "not confirmed").into_response()
        }
        Err(PutError::Backend(s)) => (StatusCode::BAD_GATEWAY, s).into_response(),
    }
}

async fn get_one<S: CanonicalStore>(state: Arc<AppState<S>>, hash: &str, obao: bool) -> Response {
    let key = if obao {
        outboard_key(hash)
    } else {
        object_key(hash)
    };
    match state.store.get(&key).await {
        Ok(bytes) => bytes.into_response(),
        Err(StoreError::NotFound) => StatusCode::NOT_FOUND.into_response(),
        Err(StoreError::Backend(s)) => (StatusCode::BAD_GATEWAY, s).into_response(),
    }
}

async fn head_one<S: CanonicalStore>(state: Arc<AppState<S>>, hash: &str) -> Response {
    match state.store.head(&object_key(hash)).await {
        Ok(_) => StatusCode::OK.into_response(),
        Err(StoreError::NotFound) => StatusCode::NOT_FOUND.into_response(),
        Err(StoreError::Backend(s)) => (StatusCode::BAD_GATEWAY, s).into_response(),
    }
}

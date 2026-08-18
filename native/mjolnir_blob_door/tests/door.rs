use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use mjolnir_blob_door::{
    blake3_bytes, hash_to_base58, router, AppState, CanonicalStore, MemoryStore,
};
use tower::ServiceExt;

fn state(store: MemoryStore) -> AppState<MemoryStore> {
    AppState {
        store: Arc::new(store),
        max_bytes: 1024 * 1024,
    }
}

async fn call(
    app: axum::Router,
    method: &str,
    uri: &str,
    body: Vec<u8>,
) -> (StatusCode, Vec<u8>) {
    let response = app
        .oneshot(
            Request::builder()
                .method(method)
                .uri(uri)
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, bytes.to_vec())
}

#[tokio::test]
async fn put_get_round_trip() {
    let body = b"hello blobs".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    let uri = format!("/storage/blob/b3/{h}");
    let app = router(AppState {
        store: store.clone(),
        max_bytes: 1024 * 1024,
    });
    let (st, _) = call(app, "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::CREATED);
    let app = router(AppState {
        store: store.clone(),
        max_bytes: 1024 * 1024,
    });
    let (st, got) = call(app, "GET", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, body);
}

#[tokio::test]
async fn put_accepted_survives_dropping_http() {
    let body = b"durable".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    let app = router(AppState {
        store: store.clone(),
        max_bytes: 1024 * 1024,
    });
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{h}"), body.clone()).await;
    assert_eq!(st, StatusCode::CREATED);

    // Door is gone (app dropped). Canonical store still has the bytes.
    let key = format!("blob/b3/{h}");
    let got = store.get(&key).await.expect("canonical copy");
    assert_eq!(got, body);
}

#[tokio::test]
async fn hash_mismatch_refused() {
    let body = b"payload".to_vec();
    let wrong = hash_to_base58(&blake3_bytes(b"other"));
    let store = MemoryStore::new();
    let app = router(state(store));
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{wrong}"), body).await;
    assert_eq!(st, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn reput_is_noop() {
    let body = b"once".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    let uri = format!("/storage/blob/b3/{h}");

    let app = router(AppState {
        store: store.clone(),
        max_bytes: 1024 * 1024,
    });
    let (st, _) = call(app, "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::CREATED);

    let app = router(AppState {
        store: store.clone(),
        max_bytes: 1024 * 1024,
    });
    let (st, _) = call(app, "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(store.version_count(&format!("blob/b3/{h}")), 1);

    let app = router(AppState {
        store: store.clone(),
        max_bytes: 1024 * 1024,
    });
    let (st, got) = call(app, "GET", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, body);
}

#[tokio::test]
async fn no_delete_route() {
    let store = MemoryStore::new();
    let app = router(state(store));
    let (st, _) = call(app, "DELETE", "/storage/blob/b3/abc", Vec::new()).await;
    assert_eq!(st, StatusCode::METHOD_NOT_ALLOWED);
}

#[tokio::test]
async fn too_large_refused() {
    let store = MemoryStore::new();
    let app = router(AppState {
        store: Arc::new(store),
        max_bytes: 4,
    });
    let body = b"12345".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{h}"), body).await;
    assert_eq!(st, StatusCode::PAYLOAD_TOO_LARGE);
}

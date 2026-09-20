use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use mjolnir_blob_door::{
    blake3_bytes, hash_to_base58, router, AppState, CanonicalStore, DiskCache, MemoryStore,
};
use tower::ServiceExt;

async fn setup(store: MemoryStore, max_bytes: u64) -> (tempfile::TempDir, AppState<MemoryStore>) {
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::open(dir.path().to_path_buf(), 32 * 1024 * 1024)
        .await
        .expect("cache");
    (
        dir,
        AppState {
            store: Arc::new(store),
            cache: Arc::new(cache),
            max_bytes,
        },
    )
}

async fn setup_shared(
    store: Arc<MemoryStore>,
    max_bytes: u64,
) -> (tempfile::TempDir, AppState<MemoryStore>) {
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::open(dir.path().to_path_buf(), 32 * 1024 * 1024)
        .await
        .expect("cache");
    (
        dir,
        AppState {
            store,
            cache: Arc::new(cache),
            max_bytes,
        },
    )
}

async fn call(app: axum::Router, method: &str, uri: &str, body: Vec<u8>) -> (StatusCode, Vec<u8>) {
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
    let (_dir, state) = setup_shared(store.clone(), 1024 * 1024).await;
    let app = router(state);
    let (st, _) = call(app, "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::CREATED);
    let (_dir2, state) = setup_shared(store.clone(), 1024 * 1024).await;
    let app = router(state);
    let (st, got) = call(app, "GET", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, body);
}

#[tokio::test]
async fn put_accepted_survives_dropping_http() {
    let body = b"durable".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    let (_dir, state) = setup_shared(store.clone(), 1024 * 1024).await;
    let app = router(state);
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{h}"), body.clone()).await;
    assert_eq!(st, StatusCode::CREATED);

    let key = format!("blob/b3/{h}");
    let got = store.get(&key).await.expect("canonical copy");
    assert_eq!(got, body);
}

#[tokio::test]
async fn hash_mismatch_refused() {
    let body = b"payload".to_vec();
    let wrong = hash_to_base58(&blake3_bytes(b"other"));
    let (_dir, state) = setup(MemoryStore::new(), 1024 * 1024).await;
    let app = router(state);
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{wrong}"), body).await;
    assert_eq!(st, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn reput_is_noop() {
    let body = b"once".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    let uri = format!("/storage/blob/b3/{h}");

    let (_dir, state) = setup_shared(store.clone(), 1024 * 1024).await;
    let app = router(state);
    let (st, _) = call(app, "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::CREATED);

    let (_dir2, state) = setup_shared(store.clone(), 1024 * 1024).await;
    let app = router(state);
    let (st, _) = call(app, "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(store.version_count(&format!("blob/b3/{h}")), 1);

    let (_dir3, state) = setup_shared(store.clone(), 1024 * 1024).await;
    let app = router(state);
    let (st, got) = call(app, "GET", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, body);
}

#[tokio::test]
async fn no_delete_route() {
    let (_dir, state) = setup(MemoryStore::new(), 1024 * 1024).await;
    let app = router(state);
    let (st, _) = call(app, "DELETE", "/storage/blob/b3/abc", Vec::new()).await;
    assert_eq!(st, StatusCode::METHOD_NOT_ALLOWED);
}

#[tokio::test]
async fn too_large_refused() {
    let (_dir, state) = setup(MemoryStore::new(), 4).await;
    let app = router(state);
    let body = b"12345".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{h}"), body).await;
    assert_eq!(st, StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn put_lands_in_cache() {
    let body = vec![7u8; 256 * 1024];
    let h = hash_to_base58(&blake3_bytes(&body));
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::open(dir.path().to_path_buf(), 32 * 1024 * 1024)
        .await
        .unwrap();
    let store = MemoryStore::new();
    let app = router(AppState {
        store: Arc::new(store),
        cache: Arc::new(cache),
        max_bytes: 1024 * 1024,
    });
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{h}"), body.clone()).await;
    assert_eq!(st, StatusCode::CREATED);
    let cached = dir.path().join("objects").join(&h);
    let got = std::fs::read(&cached).expect("cache file");
    assert_eq!(got, body);
}

#[tokio::test]
async fn get_miss_fills_cache() {
    let body = b"origin-only".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    store
        .put(&format!("blob/b3/{h}"), body.clone())
        .await
        .unwrap();

    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::open(dir.path().to_path_buf(), 32 * 1024 * 1024)
        .await
        .unwrap();
    let app = router(AppState {
        store: store.clone(),
        cache: Arc::new(cache),
        max_bytes: 1024 * 1024,
    });
    let (st, got) = call(app, "GET", &format!("/storage/blob/b3/{h}"), Vec::new()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, body);
    let cached = dir.path().join("objects").join(&h);
    // Tee fill is async with the response; wait briefly for rename.
    for _ in 0..50 {
        if cached.exists() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    let on_disk = std::fs::read(&cached).expect("filled cache");
    assert_eq!(on_disk, body);
}

#[tokio::test]
async fn mismatch_leaves_no_cache_object() {
    let body = b"payload".to_vec();
    let wrong = hash_to_base58(&blake3_bytes(b"other"));
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::open(dir.path().to_path_buf(), 32 * 1024 * 1024)
        .await
        .unwrap();
    let app = router(AppState {
        store: Arc::new(MemoryStore::new()),
        cache: Arc::new(cache),
        max_bytes: 1024 * 1024,
    });
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{wrong}"), body).await;
    assert_eq!(st, StatusCode::BAD_REQUEST);
    let objects = dir.path().join("objects");
    let mut found = false;
    if let Ok(rd) = std::fs::read_dir(&objects) {
        found = rd.filter_map(|e| e.ok()).next().is_some();
    }
    assert!(!found, "mismatch must not promote");
}

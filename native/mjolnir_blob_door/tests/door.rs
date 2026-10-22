mod common;

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use mjolnir_blob_door::{
    blake3_bytes, hash_to_base58, resolve_cache_dir, router, AppState, CanonicalStore, MemoryStore,
    StoreError,
};
use tower::ServiceExt;

use common::{call, incoming_count, object_count, objects_dir, state, state_shared};

struct CountingStore {
    inner: MemoryStore,
    puts: AtomicU64,
    gets: AtomicU64,
    heads: AtomicU64,
}

impl CountingStore {
    fn new() -> Self {
        Self {
            inner: MemoryStore::new(),
            puts: AtomicU64::new(0),
            gets: AtomicU64::new(0),
            heads: AtomicU64::new(0),
        }
    }
}

#[async_trait]
impl CanonicalStore for CountingStore {
    async fn get(&self, key: &str) -> Result<Vec<u8>, StoreError> {
        self.gets.fetch_add(1, Ordering::SeqCst);
        self.inner.get(key).await
    }
    async fn get_stream(
        &self,
        key: &str,
    ) -> Result<(u64, mjolnir_blob_door::store::BlobStream), StoreError> {
        self.gets.fetch_add(1, Ordering::SeqCst);
        self.inner.get_stream(key).await
    }
    async fn head(&self, key: &str) -> Result<u64, StoreError> {
        self.heads.fetch_add(1, Ordering::SeqCst);
        self.inner.head(key).await
    }
    async fn put(&self, key: &str, bytes: Vec<u8>) -> Result<(), StoreError> {
        self.puts.fetch_add(1, Ordering::SeqCst);
        self.inner.put(key, bytes).await
    }
    async fn put_path(&self, key: &str, path: &Path) -> Result<(), StoreError> {
        self.puts.fetch_add(1, Ordering::SeqCst);
        self.inner.put_path(key, path).await
    }
}

struct PutFailStore;

#[async_trait]
impl CanonicalStore for PutFailStore {
    async fn get(&self, _key: &str) -> Result<Vec<u8>, StoreError> {
        Err(StoreError::NotFound)
    }
    async fn get_stream(
        &self,
        _key: &str,
    ) -> Result<(u64, mjolnir_blob_door::store::BlobStream), StoreError> {
        Err(StoreError::NotFound)
    }
    async fn head(&self, _key: &str) -> Result<u64, StoreError> {
        Err(StoreError::NotFound)
    }
    async fn put(&self, _key: &str, _bytes: Vec<u8>) -> Result<(), StoreError> {
        Err(StoreError::Backend("nope".into()))
    }
    async fn put_path(&self, _key: &str, _path: &Path) -> Result<(), StoreError> {
        Err(StoreError::Backend("nope".into()))
    }
}

struct ConfirmFailStore {
    inner: MemoryStore,
}

#[async_trait]
impl CanonicalStore for ConfirmFailStore {
    async fn get(&self, key: &str) -> Result<Vec<u8>, StoreError> {
        self.inner.get(key).await
    }
    async fn get_stream(
        &self,
        key: &str,
    ) -> Result<(u64, mjolnir_blob_door::store::BlobStream), StoreError> {
        self.inner.get_stream(key).await
    }
    async fn head(&self, _key: &str) -> Result<u64, StoreError> {
        Err(StoreError::NotFound)
    }
    async fn put(&self, key: &str, bytes: Vec<u8>) -> Result<(), StoreError> {
        self.inner.put(key, bytes).await
    }
    async fn put_path(&self, key: &str, path: &Path) -> Result<(), StoreError> {
        self.inner.put_path(key, path).await
    }
}

#[tokio::test]
async fn put_get_round_trip() {
    let body = b"hello blobs".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    let uri = format!("/storage/blob/b3/{h}");
    let (_dir, state) = state_shared(store.clone(), 32 << 20, 1 << 20).await;
    let (st, _) = call(router(state), "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::CREATED);
    let (_dir2, state) = state_shared(store, 32 << 20, 1 << 20).await;
    let (st, got) = call(router(state), "GET", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, body);
}

#[tokio::test]
async fn put_accepted_survives_dropping_http() {
    let body = b"durable".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    let (_dir, state) = state_shared(store.clone(), 32 << 20, 1 << 20).await;
    let (st, _) = call(
        router(state),
        "PUT",
        &format!("/storage/blob/b3/{h}"),
        body.clone(),
    )
    .await;
    assert_eq!(st, StatusCode::CREATED);
    let got = store
        .get(&format!("blob/b3/{h}"))
        .await
        .expect("canonical copy");
    assert_eq!(got, body);
}

#[tokio::test]
async fn hash_mismatch_refused() {
    let body = b"payload".to_vec();
    let wrong = hash_to_base58(&blake3_bytes(b"other"));
    let (_dir, state) = state(MemoryStore::new(), 32 << 20, 1 << 20).await;
    let (st, _) = call(
        router(state),
        "PUT",
        &format!("/storage/blob/b3/{wrong}"),
        body,
    )
    .await;
    assert_eq!(st, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn invalid_hash_refused() {
    let (_dir, state) = state(MemoryStore::new(), 32 << 20, 1 << 20).await;
    let (st, _) = call(
        router(state),
        "PUT",
        "/storage/blob/b3/not-a-hash!!!",
        b"x".to_vec(),
    )
    .await;
    assert_eq!(st, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn reput_is_noop() {
    let body = b"once".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    let uri = format!("/storage/blob/b3/{h}");

    let (_dir, state) = state_shared(store.clone(), 32 << 20, 1 << 20).await;
    let (st, _) = call(router(state), "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::CREATED);

    let (_dir2, state) = state_shared(store.clone(), 32 << 20, 1 << 20).await;
    let (st, _) = call(router(state), "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(store.version_count(&format!("blob/b3/{h}")), 1);

    let (_dir3, state) = state_shared(store, 32 << 20, 1 << 20).await;
    let (st, got) = call(router(state), "GET", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, body);
}

#[tokio::test]
async fn no_delete_route() {
    let (_dir, state) = state(MemoryStore::new(), 32 << 20, 1 << 20).await;
    let (st, _) = call(router(state), "DELETE", "/storage/blob/b3/abc", Vec::new()).await;
    assert_eq!(st, StatusCode::METHOD_NOT_ALLOWED);
}

#[tokio::test]
async fn too_large_refused() {
    let (_dir, state) = state(MemoryStore::new(), 32 << 20, 4).await;
    let body = b"12345".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let (st, _) = call(router(state), "PUT", &format!("/storage/blob/b3/{h}"), body).await;
    assert_eq!(st, StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn put_lands_in_cache() {
    let body = vec![7u8; 256 * 1024];
    let h = hash_to_base58(&blake3_bytes(&body));
    let dir = tempfile::tempdir().unwrap();
    let cache = mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 32 << 20)
        .await
        .unwrap();
    let app = router(AppState {
        store: Arc::new(MemoryStore::new()),
        cache: Arc::new(cache),
        max_bytes: 1 << 20,
    });
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{h}"), body.clone()).await;
    assert_eq!(st, StatusCode::CREATED);
    let got = std::fs::read(objects_dir(dir.path()).join(&h)).expect("cache file");
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
    let cache = mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 32 << 20)
        .await
        .unwrap();
    let app = router(AppState {
        store: store.clone(),
        cache: Arc::new(cache),
        max_bytes: 1 << 20,
    });
    let (st, got) = call(app, "GET", &format!("/storage/blob/b3/{h}"), Vec::new()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, body);
    let cached = objects_dir(dir.path()).join(&h);
    for _ in 0..50 {
        if cached.exists() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert_eq!(std::fs::read(&cached).expect("filled cache"), body);
}

#[tokio::test]
async fn mismatch_leaves_no_cache_object() {
    let body = b"payload".to_vec();
    let wrong = hash_to_base58(&blake3_bytes(b"other"));
    let dir = tempfile::tempdir().unwrap();
    let cache = mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 32 << 20)
        .await
        .unwrap();
    let app = router(AppState {
        store: Arc::new(MemoryStore::new()),
        cache: Arc::new(cache),
        max_bytes: 1 << 20,
    });
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{wrong}"), body).await;
    assert_eq!(st, StatusCode::BAD_REQUEST);
    assert_eq!(object_count(dir.path()), 0);
}

#[tokio::test]
async fn backend_fail_leaves_no_cache_object() {
    let body = b"payload".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let dir = tempfile::tempdir().unwrap();
    let cache = mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 32 << 20)
        .await
        .unwrap();
    let app = router(AppState {
        store: Arc::new(PutFailStore),
        cache: Arc::new(cache),
        max_bytes: 1 << 20,
    });
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{h}"), body).await;
    assert_eq!(st, StatusCode::BAD_GATEWAY);
    assert_eq!(object_count(dir.path()), 0);
    assert_eq!(incoming_count(dir.path()), 0);
}

#[tokio::test]
async fn unconfirmed_put_is_not_accepted() {
    let body = b"payload".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let dir = tempfile::tempdir().unwrap();
    let cache = mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 32 << 20)
        .await
        .unwrap();
    let app = router(AppState {
        store: Arc::new(ConfirmFailStore {
            inner: MemoryStore::new(),
        }),
        cache: Arc::new(cache),
        max_bytes: 1 << 20,
    });
    let (st, _) = call(app, "PUT", &format!("/storage/blob/b3/{h}"), body).await;
    assert_eq!(st, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(object_count(dir.path()), 0);
}

#[tokio::test]
async fn head_missing_and_present() {
    let body = b"headed".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let uri = format!("/storage/blob/b3/{h}");
    let (_dir, state) = state(MemoryStore::new(), 32 << 20, 1 << 20).await;
    let store = state.store.clone();
    let cache = state.cache.clone();
    let max_bytes = state.max_bytes;

    let (st, _) = call(router(state), "HEAD", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::NOT_FOUND);

    let (st, _) = call(
        router(AppState {
            store: store.clone(),
            cache: cache.clone(),
            max_bytes,
        }),
        "PUT",
        &uri,
        body,
    )
    .await;
    assert_eq!(st, StatusCode::CREATED);

    let (st, body_out) = call(
        router(AppState {
            store,
            cache,
            max_bytes,
        }),
        "HEAD",
        &uri,
        Vec::new(),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert!(body_out.is_empty());
}

#[tokio::test]
async fn obao_round_trip() {
    let payload = b"cipher".to_vec();
    let obao = b"outboard-bytes".to_vec();
    let h = hash_to_base58(&blake3_bytes(&payload));
    let store = Arc::new(MemoryStore::new());
    let (_dir, state) = state_shared(store.clone(), 32 << 20, 1 << 20).await;
    let (st, _) = call(
        router(state),
        "PUT",
        &format!("/storage/blob/b3/{h}"),
        payload.clone(),
    )
    .await;
    assert_eq!(st, StatusCode::CREATED);

    let (_dir2, state) = state_shared(store.clone(), 32 << 20, 1 << 20).await;
    let (st, _) = call(
        router(state),
        "PUT",
        &format!("/storage/blob/b3/{h}.obao"),
        obao.clone(),
    )
    .await;
    assert_eq!(st, StatusCode::CREATED);

    let (_dir3, state) = state_shared(store, 32 << 20, 1 << 20).await;
    let (st, got) = call(
        router(state),
        "GET",
        &format!("/storage/blob/b3/{h}.obao"),
        Vec::new(),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, obao);
}

#[tokio::test]
async fn cache_hit_does_not_touch_origin_get() {
    let body = b"cached".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(CountingStore::new());
    let dir = tempfile::tempdir().unwrap();
    let cache = mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 32 << 20)
        .await
        .unwrap();
    let app = router(AppState {
        store: store.clone(),
        cache: Arc::new(cache),
        max_bytes: 1 << 20,
    });
    let uri = format!("/storage/blob/b3/{h}");
    let (st, _) = call(app, "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::CREATED);
    let gets_after_put = store.gets.load(Ordering::SeqCst);

    let cache = mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 32 << 20)
        .await
        .unwrap();
    let app = router(AppState {
        store: store.clone(),
        cache: Arc::new(cache),
        max_bytes: 1 << 20,
    });
    let (st, got) = call(app, "GET", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, body);
    assert_eq!(
        store.gets.load(Ordering::SeqCst),
        gets_after_put,
        "cache hit must not get_stream the origin"
    );
}

#[tokio::test]
async fn dropped_get_does_not_leave_incoming() {
    let body = b"stream-me".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    store.put(&format!("blob/b3/{h}"), body).await.unwrap();
    let dir = tempfile::tempdir().unwrap();
    let cache = mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 32 << 20)
        .await
        .unwrap();
    let app = router(AppState {
        store,
        cache: Arc::new(cache),
        max_bytes: 1 << 20,
    });
    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/storage/blob/b3/{h}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    drop(response);
    assert_eq!(incoming_count(dir.path()), 0);
}

#[tokio::test]
async fn concurrent_put_same_hash_get_succeeds() {
    let body = b"same-bytes".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    let uri = format!("/storage/blob/b3/{h}");
    let (_dir, state) = state_shared(store.clone(), 32 << 20, 1 << 20).await;
    let app = router(state);

    let a = app.clone().oneshot(
        Request::builder()
            .method("PUT")
            .uri(&uri)
            .body(Body::from(body.clone()))
            .unwrap(),
    );
    let b = app.oneshot(
        Request::builder()
            .method("PUT")
            .uri(&uri)
            .body(Body::from(body.clone()))
            .unwrap(),
    );
    let (ra, rb) = tokio::join!(a, b);
    let sa = ra.unwrap().status();
    let sb = rb.unwrap().status();
    assert!(sa.is_success(), "{sa}");
    assert!(sb.is_success(), "{sb}");

    let (_dir2, state) = state_shared(store, 32 << 20, 1 << 20).await;
    let (st, got) = call(router(state), "GET", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, body);
}

#[tokio::test]
async fn get_oversize_is_not_cached() {
    let body = vec![9u8; 200];
    let h = hash_to_base58(&blake3_bytes(&body));
    let store = Arc::new(MemoryStore::new());
    store
        .put(&format!("blob/b3/{h}"), body.clone())
        .await
        .unwrap();
    let dir = tempfile::tempdir().unwrap();
    let cache = mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 100)
        .await
        .unwrap();
    let app = router(AppState {
        store,
        cache: Arc::new(cache),
        max_bytes: 1 << 20,
    });
    let (st, got) = call(app, "GET", &format!("/storage/blob/b3/{h}"), Vec::new()).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got, body);
    assert_eq!(object_count(dir.path()), 0);
}

#[tokio::test]
async fn get_and_head_reject_non_hash_paths_before_cache_or_store_access() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("marker"), b"absolute-marker").unwrap();
    let store = Arc::new(CountingStore::new());
    let cache = Arc::new(
        mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 1024)
            .await
            .unwrap(),
    );
    std::fs::write(
        dir.path().join("incoming").join("marker"),
        b"incoming-marker",
    )
    .unwrap();
    let app = router(AppState {
        store: store.clone(),
        cache,
        max_bytes: 1024,
    });
    let absolute = format!(
        "{}{}",
        "%2F",
        dir.path()
            .join("marker")
            .display()
            .to_string()
            .trim_start_matches('/')
            .replace('/', "%2F")
    );
    let cases = [
        format!("/storage/blob/b3/{absolute}"),
        "/storage/blob/b3/%2E%2E%2Fincoming%2Fmarker".to_string(),
        "/storage/blob/b3/not-a-hash!!!".to_string(),
        format!("/storage/blob/b3/{absolute}.obao"),
        "/storage/blob/b3/%2E%2E%2Fincoming%2Fmarker.obao".to_string(),
        "/storage/blob/b3/not-a-hash!!!.obao".to_string(),
    ];
    for method in ["GET", "HEAD"] {
        for uri in &cases {
            let (status, body) = call(app.clone(), method, uri, Vec::new()).await;
            assert!(status.is_client_error(), "{method} {uri}: {status}");
            assert_ne!(body, b"absolute-marker");
            assert_ne!(body, b"incoming-marker");
        }
    }
    assert_eq!(store.gets.load(Ordering::SeqCst), 0);
    assert_eq!(store.heads.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn cache_open_race_falls_back_to_origin() {
    let body = b"origin survives eviction".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let uri = format!("/storage/blob/b3/{h}");
    let store = Arc::new(CountingStore::new());
    store
        .inner
        .put(&format!("blob/b3/{h}"), body.clone())
        .await
        .unwrap();
    let dir = tempfile::tempdir().unwrap();
    let cache = Arc::new(
        mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 1024)
            .await
            .unwrap(),
    );
    let mut incoming = cache.create_incoming().await.unwrap();
    use tokio::io::AsyncWriteExt;
    incoming.file().write_all(&body).await.unwrap();
    cache
        .promote(&mut incoming, &h, false, body.len() as u64)
        .await
        .unwrap();
    cache.evict_next_open_for_test();

    let app = router(AppState {
        store: store.clone(),
        cache,
        max_bytes: 1024,
    });
    let (status, got) = call(app, "GET", &uri, Vec::new()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(got, body);
    assert_eq!(store.gets.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn failed_fill_completion_is_discarded_and_next_get_uses_origin() {
    let body = b"never publish a failed fill".to_vec();
    let h = hash_to_base58(&blake3_bytes(&body));
    let uri = format!("/storage/blob/b3/{h}");
    let store = Arc::new(CountingStore::new());
    store
        .inner
        .put(&format!("blob/b3/{h}"), body.clone())
        .await
        .unwrap();
    let dir = tempfile::tempdir().unwrap();
    let cache = Arc::new(
        mjolnir_blob_door::DiskCache::open(dir.path().to_path_buf(), 1024)
            .await
            .unwrap(),
    );
    cache.fail_next_fill_completion_for_test();
    let app = router(AppState {
        store: store.clone(),
        cache,
        max_bytes: 1024,
    });

    let (status, got) = call(app.clone(), "GET", &uri, Vec::new()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(got, body);
    assert_eq!(object_count(dir.path()), 0);
    assert_eq!(incoming_count(dir.path()), 0);

    let (status, got) = call(app, "GET", &uri, Vec::new()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(got, body);
    assert_eq!(store.gets.load(Ordering::SeqCst), 2);
}

#[test]
fn resolved_cache_root_rejects_symlink_dotdot_and_unsafe_fallbacks() {
    let dir = tempfile::tempdir().unwrap();
    let btrfs = dir.path().join("data");
    let safe = dir.path().join("safe");
    std::fs::create_dir_all(&btrfs).unwrap();
    std::fs::create_dir_all(&safe).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&btrfs, dir.path().join("alias")).unwrap();

    #[cfg(unix)]
    assert!(resolve_cache_dir(&dir.path().join("alias/cache"), &btrfs).is_err());
    assert!(resolve_cache_dir(&safe.join("../data/cache"), &btrfs).is_err());
    assert!(resolve_cache_dir(&btrfs.join("fallback"), &btrfs).is_err());
    assert_eq!(
        resolve_cache_dir(&safe.join("cache"), &btrfs).unwrap(),
        std::fs::canonicalize(&safe).unwrap().join("cache")
    );
}

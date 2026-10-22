//! Live B2 through the door crate. Skips unless `BLOB_DOOR_B2_TEST=1`
//! and `B2_*` are set (source `/etc/mjolnir/blob-door.env` on the host).
//!
//!     BLOB_DOOR_B2_TEST=1 cargo test -p mjolnir-blob-door --test b2 -- --nocapture
//!     BLOB_DOOR_B2_LARGE=1  # also the 65 MiB multipart case

mod common;

use std::sync::Arc;

use axum::http::StatusCode;
use mjolnir_blob_door::s3::{S3Canonical, MULTIPART_THRESHOLD};
use mjolnir_blob_door::{
    blake3_bytes, hash_to_base58, router, AppState, CanonicalStore, DiskCache,
};

fn enabled() -> bool {
    std::env::var("BLOB_DOOR_B2_TEST").as_deref() == Ok("1")
}

fn large_enabled() -> bool {
    enabled() && std::env::var("BLOB_DOOR_B2_LARGE").as_deref() == Ok("1")
}

async fn door(store: Arc<S3Canonical>) -> (tempfile::TempDir, axum::Router) {
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::open(dir.path().to_path_buf(), 128 << 20)
        .await
        .unwrap();
    let app = router(AppState {
        store,
        cache: Arc::new(cache),
        max_bytes: 1 << 30,
    });
    (dir, app)
}

#[tokio::test]
async fn b2_put_get_head_reput() {
    if !enabled() {
        eprintln!("skip: set BLOB_DOOR_B2_TEST=1 and B2_*");
        return;
    }
    let store = Arc::new(
        S3Canonical::from_env()
            .await
            .expect("B2_* (source /etc/mjolnir/blob-door.env)"),
    );
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let body = format!("blob-door-e2e-{nonce}").into_bytes();
    let h = hash_to_base58(&blake3_bytes(&body));
    let key = format!("blob/b3/{h}");
    let uri = format!("/storage/blob/b3/{h}");

    let (_dir, app) = door(store.clone()).await;
    let (st, _) = common::call(app, "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::CREATED, "put");

    let (_dir, app) = door(store.clone()).await;
    let (st, _) = common::call(app, "HEAD", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::OK, "head");

    let (_dir, app) = door(store.clone()).await;
    let (st, got) = common::call(app, "GET", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::OK, "get");
    assert_eq!(got, body, "bytes");

    let (_dir, app) = door(store.clone()).await;
    let (st, _) = common::call(app, "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::OK, "reput");

    let from_b2 = store.get(&key).await.expect("canonical get");
    assert_eq!(from_b2, body);
    let _ = store.delete_object(&key).await;
}

#[tokio::test]
async fn b2_hash_mismatch_not_on_b2() {
    if !enabled() {
        eprintln!("skip: set BLOB_DOOR_B2_TEST=1 and B2_*");
        return;
    }
    let store = Arc::new(S3Canonical::from_env().await.expect("B2_*"));
    let body = b"mismatch-e2e".to_vec();
    let wrong = hash_to_base58(&blake3_bytes(b"other-e2e"));
    let uri = format!("/storage/blob/b3/{wrong}");
    let (_dir, app) = door(store.clone()).await;
    let (st, _) = common::call(app, "PUT", &uri, body).await;
    assert_eq!(st, StatusCode::BAD_REQUEST);
    let (_dir, app) = door(store.clone()).await;
    let (st, _) = common::call(app, "GET", &uri, Vec::new()).await;
    assert_eq!(st, StatusCode::NOT_FOUND, "mismatch must 404 on GET");
    match store.get(&format!("blob/b3/{wrong}")).await {
        Err(mjolnir_blob_door::StoreError::NotFound) => {}
        Ok(_) => panic!("mismatch landed on B2"),
        Err(e) => panic!("unexpected get after mismatch: {e:?}"),
    }
}

#[tokio::test]
async fn b2_multipart_put_get() {
    if !large_enabled() {
        eprintln!("skip: set BLOB_DOOR_B2_TEST=1 BLOB_DOOR_B2_LARGE=1");
        return;
    }
    let store = Arc::new(S3Canonical::from_env().await.expect("B2_*"));
    let len = (MULTIPART_THRESHOLD + 1) as usize;
    let mut body = vec![0u8; len];
    for (i, b) in body.iter_mut().enumerate() {
        *b = (i % 251) as u8;
    }
    let h = hash_to_base58(&blake3_bytes(&body));
    let key = format!("blob/b3/{h}");
    let uri = format!("/storage/blob/b3/{h}");

    let (_dir, app) = door(store.clone()).await;
    let (st, _) = common::call(app, "PUT", &uri, body.clone()).await;
    assert_eq!(st, StatusCode::CREATED, "multipart put");

    let (_dir, app) = door(store.clone()).await;
    let (st, got) = common::call(app, "GET", &uri, Vec::new()).await;
    let _ = store.delete_object(&key).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(got.len(), body.len());
    assert_eq!(got, body);
}

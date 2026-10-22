#![allow(dead_code)]

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use mjolnir_blob_door::{AppState, DiskCache, MemoryStore};
use tower::ServiceExt;

pub async fn cache(budget: u64) -> (tempfile::TempDir, Arc<DiskCache>) {
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::open(dir.path().to_path_buf(), budget)
        .await
        .expect("cache");
    (dir, Arc::new(cache))
}

pub async fn state(
    store: MemoryStore,
    budget: u64,
    max_bytes: u64,
) -> (tempfile::TempDir, AppState<MemoryStore>) {
    let (dir, cache) = cache(budget).await;
    (
        dir,
        AppState {
            store: Arc::new(store),
            cache,
            max_bytes,
        },
    )
}

pub async fn state_shared(
    store: Arc<MemoryStore>,
    budget: u64,
    max_bytes: u64,
) -> (tempfile::TempDir, AppState<MemoryStore>) {
    let (dir, cache) = cache(budget).await;
    (
        dir,
        AppState {
            store,
            cache,
            max_bytes,
        },
    )
}

pub async fn call(
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

pub fn objects_dir(root: &std::path::Path) -> std::path::PathBuf {
    root.join("objects")
}

pub fn incoming_dir(root: &std::path::Path) -> std::path::PathBuf {
    root.join("incoming")
}

pub fn cache_size(root: &std::path::Path) -> u64 {
    let dir = objects_dir(root);
    let Ok(rd) = std::fs::read_dir(&dir) else {
        return 0;
    };
    rd.filter_map(|e| e.ok())
        .filter_map(|e| e.metadata().ok())
        .filter(|m| m.is_file())
        .map(|m| m.len())
        .sum()
}

pub fn object_count(root: &std::path::Path) -> usize {
    let dir = objects_dir(root);
    let Ok(rd) = std::fs::read_dir(&dir) else {
        return 0;
    };
    rd.filter_map(|e| e.ok())
        .filter(|e| e.metadata().map(|m| m.is_file()).unwrap_or(false))
        .count()
}

pub fn incoming_count(root: &std::path::Path) -> usize {
    let dir = incoming_dir(root);
    let Ok(rd) = std::fs::read_dir(&dir) else {
        return 0;
    };
    rd.filter_map(|e| e.ok())
        .filter(|e| e.path().is_file())
        .count()
}

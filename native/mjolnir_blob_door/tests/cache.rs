//! DiskCache in isolation — LRU, budget, sweep, oversize.

mod common;

use mjolnir_blob_door::DiskCache;
use tokio::io::AsyncWriteExt;

async fn put_named(cache: &DiskCache, name: &str, bytes: &[u8]) {
    let mut inc = cache.create_incoming().await.expect("incoming");
    inc.file().write_all(bytes).await.unwrap();
    inc.close().await.unwrap();
    cache
        .promote(&mut inc, name, false, bytes.len() as u64)
        .await
        .unwrap();
}

#[tokio::test]
async fn open_sweeps_incoming() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("incoming")).unwrap();
    std::fs::write(dir.path().join("incoming").join("junk"), b"leftover").unwrap();
    let _cache = DiskCache::open(dir.path().to_path_buf(), 1024)
        .await
        .unwrap();
    assert_eq!(common::incoming_count(dir.path()), 0);
}

#[tokio::test]
async fn lru_evicts_to_budget() {
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::open(dir.path().to_path_buf(), 1000)
        .await
        .unwrap();
    put_named(&cache, "aaa", &vec![1u8; 400]).await;
    put_named(&cache, "bbb", &vec![2u8; 400]).await;
    put_named(&cache, "ccc", &vec![3u8; 400]).await;
    let on_disk = common::cache_size(dir.path());
    assert!(
        on_disk <= 1000,
        "cache {on_disk} exceeded budget after third put"
    );
    assert_eq!(common::object_count(dir.path()), 2);
    assert!(
        dir.path().join("objects").join("ccc").exists(),
        "just-promoted object must stay"
    );
    let a = dir.path().join("objects").join("aaa").exists();
    let b = dir.path().join("objects").join("bbb").exists();
    assert!(
        a ^ b,
        "exactly one of the older objects should have been evicted"
    );
}

#[tokio::test]
async fn oversize_object_is_not_retained() {
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::open(dir.path().to_path_buf(), 100)
        .await
        .unwrap();
    put_named(&cache, "big", &vec![9u8; 200]).await;
    assert_eq!(common::object_count(dir.path()), 0);
    assert_eq!(cache.used(), 0);
}

#[tokio::test]
async fn commit_fill_evicts_like_put() {
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::open(dir.path().to_path_buf(), 1000)
        .await
        .unwrap();
    put_named(&cache, "aaa", &vec![1u8; 400]).await;
    put_named(&cache, "bbb", &vec![2u8; 400]).await;

    let incoming = dir.path().join("incoming").join("fill");
    std::fs::write(&incoming, vec![3u8; 400]).unwrap();
    cache
        .commit_fill(&incoming, "ccc", false, 400)
        .await
        .unwrap();

    assert!(common::cache_size(dir.path()) <= 1000);
    assert_eq!(common::object_count(dir.path()), 2);
    assert!(dir.path().join("objects").join("ccc").exists());
}

#[tokio::test]
async fn get_touch_does_not_panic() {
    let dir = tempfile::tempdir().unwrap();
    let cache = DiskCache::open(dir.path().to_path_buf(), 1000)
        .await
        .unwrap();
    put_named(&cache, "hot", b"hello").await;
    let path = cache.get("hot", false).await.expect("hit");
    assert!(path.ends_with("hot"));
    assert!(cache.get("missing", false).await.is_none());
}

use std::path::Path;
use std::pin::Pin;

use async_trait::async_trait;
use bytes::Bytes;
use futures_util::Stream;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("not found")]
    NotFound,
    #[error("backend: {0}")]
    Backend(String),
}

pub type BlobStream = Pin<Box<dyn Stream<Item = Result<Bytes, std::io::Error>> + Send>>;

#[async_trait]
pub trait CanonicalStore: Send + Sync {
    async fn get(&self, key: &str) -> Result<Vec<u8>, StoreError>;
    async fn get_stream(&self, key: &str) -> Result<(u64, BlobStream), StoreError>;
    async fn head(&self, key: &str) -> Result<u64, StoreError>;
    async fn put(&self, key: &str, bytes: Vec<u8>) -> Result<(), StoreError>;
    async fn put_path(&self, key: &str, path: &Path) -> Result<(), StoreError>;
}

pub fn object_key(hash_b58: &str) -> String {
    format!("blob/b3/{hash_b58}")
}

pub fn outboard_key(hash_b58: &str) -> String {
    format!("blob/b3/{hash_b58}.obao")
}

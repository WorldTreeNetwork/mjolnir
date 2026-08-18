use async_trait::async_trait;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("not found")]
    NotFound,
    #[error("backend: {0}")]
    Backend(String),
}

#[async_trait]
pub trait CanonicalStore: Send + Sync {
    async fn get(&self, key: &str) -> Result<Vec<u8>, StoreError>;
    async fn head(&self, key: &str) -> Result<u64, StoreError>;
    async fn put(&self, key: &str, bytes: Vec<u8>) -> Result<(), StoreError>;
}

pub fn object_key(hash_b58: &str) -> String {
    format!("blob/b3/{hash_b58}")
}

pub fn outboard_key(hash_b58: &str) -> String {
    format!("blob/b3/{hash_b58}.obao")
}

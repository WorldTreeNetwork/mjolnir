use std::path::Path;

use crate::store::{object_key, outboard_key, CanonicalStore, StoreError};

#[derive(Debug, thiserror::Error)]
pub enum PutError {
    #[error("hash mismatch")]
    HashMismatch,
    #[error("canonical store did not confirm the object")]
    NotConfirmed,
    #[error("backend: {0}")]
    Backend(String),
}

impl From<StoreError> for PutError {
    fn from(err: StoreError) -> Self {
        match err {
            StoreError::NotFound => PutError::NotConfirmed,
            StoreError::Backend(s) => PutError::Backend(s),
        }
    }
}

pub enum PutOutcome {
    Created,
    AlreadyPresent,
}

/// Exists-then-skip, write from a file, confirm. Never ack on write alone.
/// Caller already hashed the file (object PUT) or skipped hashing (.obao).
pub async fn put_file<S: CanonicalStore>(
    store: &S,
    hash_b58: &str,
    path: &Path,
    len: u64,
    obao: bool,
) -> Result<PutOutcome, PutError> {
    let key = if obao {
        outboard_key(hash_b58)
    } else {
        object_key(hash_b58)
    };
    if let Ok(existing) = store.head(&key).await {
        if existing == len {
            return Ok(PutOutcome::AlreadyPresent);
        }
        return Err(PutError::HashMismatch);
    }
    store.put_path(&key, path).await?;
    confirm(store, &key, len).await?;
    Ok(PutOutcome::Created)
}

async fn confirm<S: CanonicalStore>(store: &S, key: &str, len: u64) -> Result<(), PutError> {
    match store.head(key).await {
        Ok(n) if n == len => Ok(()),
        Ok(_) => Err(PutError::NotConfirmed),
        Err(StoreError::NotFound) => Err(PutError::NotConfirmed),
        Err(e) => Err(e.into()),
    }
}

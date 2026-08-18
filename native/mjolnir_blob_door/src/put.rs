use crate::store::{object_key, outboard_key, CanonicalStore, StoreError};
use crate::{blake3_bytes, hash_to_base58};

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

/// Hash-refuse, exists-then-skip, write, confirm. Never ack on write alone.
pub async fn put_bytes<S: CanonicalStore>(
    store: &S,
    claimed: &[u8; 32],
    body: &[u8],
) -> Result<PutOutcome, PutError> {
    let actual = blake3_bytes(body);
    if &actual != claimed {
        return Err(PutError::HashMismatch);
    }
    let key = object_key(&hash_to_base58(claimed));
    if store.head(&key).await.is_ok() {
        let existing = store.get(&key).await?;
        if blake3_bytes(&existing) == *claimed {
            return Ok(PutOutcome::AlreadyPresent);
        }
        return Err(PutError::HashMismatch);
    }
    store.put(&key, body.to_vec()).await?;
    confirm(store, &key, body.len() as u64).await?;
    Ok(PutOutcome::Created)
}

pub async fn put_outboard<S: CanonicalStore>(
    store: &S,
    claimed: &[u8; 32],
    body: &[u8],
) -> Result<PutOutcome, PutError> {
    let key = outboard_key(&hash_to_base58(claimed));
    if store.head(&key).await.is_ok() {
        return Ok(PutOutcome::AlreadyPresent);
    }
    store.put(&key, body.to_vec()).await?;
    confirm(store, &key, body.len() as u64).await?;
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

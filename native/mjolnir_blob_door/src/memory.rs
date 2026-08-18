use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;

use crate::store::{CanonicalStore, StoreError};

/// In-process stand-in for B2. Survives dropping the HTTP server.
#[derive(Default)]
pub struct MemoryStore {
    objects: Mutex<HashMap<String, Vec<u8>>>,
    versions: Mutex<HashMap<String, u32>>,
}

impl MemoryStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn version_count(&self, key: &str) -> u32 {
        self.versions
            .lock()
            .expect("memory store")
            .get(key)
            .copied()
            .unwrap_or(0)
    }
}

#[async_trait]
impl CanonicalStore for MemoryStore {
    async fn get(&self, key: &str) -> Result<Vec<u8>, StoreError> {
        self.objects
            .lock()
            .expect("memory store")
            .get(key)
            .cloned()
            .ok_or(StoreError::NotFound)
    }

    async fn head(&self, key: &str) -> Result<u64, StoreError> {
        self.objects
            .lock()
            .expect("memory store")
            .get(key)
            .map(|b| b.len() as u64)
            .ok_or(StoreError::NotFound)
    }

    async fn put(&self, key: &str, bytes: Vec<u8>) -> Result<(), StoreError> {
        let mut objects = self.objects.lock().expect("memory store");
        let mut versions = self.versions.lock().expect("memory store");
        objects.insert(key.to_string(), bytes);
        *versions.entry(key.to_string()).or_insert(0) += 1;
        Ok(())
    }
}

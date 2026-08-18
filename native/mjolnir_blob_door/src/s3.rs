use async_trait::async_trait;
use aws_sdk_s3::config::{BehaviorVersion, Credentials, Region};
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::Client;

use crate::store::{CanonicalStore, StoreError};

pub struct S3Canonical {
    client: Client,
    bucket: String,
}

impl S3Canonical {
    pub async fn from_env() -> Result<Self, StoreError> {
        let endpoint = required("B2_ENDPOINT")?;
        let region = std::env::var("B2_REGION").unwrap_or_else(|_| "us-west-004".into());
        let bucket = required("B2_BUCKET")?;
        let key_id = required("B2_KEY_ID")?;
        let app_key = required("B2_APPLICATION_KEY")?;

        let creds = Credentials::new(key_id, app_key, None, None, "blob-door");
        let config = aws_sdk_s3::Config::builder()
            .endpoint_url(endpoint)
            .region(Region::new(region))
            .credentials_provider(creds)
            .force_path_style(true)
            .behavior_version(BehaviorVersion::latest())
            .build();

        Ok(Self {
            client: Client::from_conf(config),
            bucket,
        })
    }
}

fn required(name: &str) -> Result<String, StoreError> {
    std::env::var(name)
        .ok()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| StoreError::Backend(format!("{name} is required")))
}

#[async_trait]
impl CanonicalStore for S3Canonical {
    async fn get(&self, key: &str) -> Result<Vec<u8>, StoreError> {
        let out = self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await
            .map_err(classify_aws)?;
        out.body
            .collect()
            .await
            .map(|d| d.to_vec())
            .map_err(|e| StoreError::Backend(e.to_string()))
    }

    async fn head(&self, key: &str) -> Result<u64, StoreError> {
        let out = self
            .client
            .head_object()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await
            .map_err(classify_aws)?;
        Ok(out.content_length().unwrap_or(0) as u64)
    }

    async fn put(&self, key: &str, bytes: Vec<u8>) -> Result<(), StoreError> {
        self.client
            .put_object()
            .bucket(&self.bucket)
            .key(key)
            .body(ByteStream::from(bytes))
            .send()
            .await
            .map_err(|e| StoreError::Backend(e.to_string()))?;
        Ok(())
    }
}

fn classify_aws<E: std::fmt::Display>(err: E) -> StoreError {
    let s = err.to_string();
    if s.contains("NotFound") || s.contains("404") || s.contains("NoSuchKey") {
        StoreError::NotFound
    } else {
        StoreError::Backend(s)
    }
}

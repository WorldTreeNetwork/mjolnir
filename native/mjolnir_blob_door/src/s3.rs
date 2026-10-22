use std::path::Path;

use async_trait::async_trait;
use aws_sdk_s3::config::{BehaviorVersion, Credentials, Region};
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::types::{CompletedMultipartUpload, CompletedPart};
use aws_sdk_s3::Client;
use futures_util::StreamExt;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

use crate::store::{BlobStream, CanonicalStore, StoreError};

/// Below this, a single PutObject. B2/S3 single-PUT max is 5 GiB;
/// 64 MiB is well under and matches the old RAM cap as the pump unit.
pub const MULTIPART_THRESHOLD: u64 = 64 * 1024 * 1024;
const MIN_PART: u64 = 16 * 1024 * 1024;
const MAX_PARTS: u64 = 10_000;

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

    /// Not on the HTTP surface. Tests delete objects they created.
    pub async fn delete_object(&self, key: &str) -> Result<(), StoreError> {
        self.client
            .delete_object()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| StoreError::Backend(e.to_string()))?;
        Ok(())
    }

    async fn put_simple(&self, key: &str, path: &Path, len: u64) -> Result<(), StoreError> {
        let body = ByteStream::from_path(path)
            .await
            .map_err(|e| StoreError::Backend(e.to_string()))?;
        self.client
            .put_object()
            .bucket(&self.bucket)
            .key(key)
            .content_length(len as i64)
            .body(body)
            .send()
            .await
            .map_err(|e| StoreError::Backend(e.to_string()))?;
        Ok(())
    }

    async fn put_multipart(&self, key: &str, path: &Path, len: u64) -> Result<(), StoreError> {
        let part_size = part_size_for(len);
        let created = self
            .client
            .create_multipart_upload()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| StoreError::Backend(e.to_string()))?;
        let upload_id = created
            .upload_id()
            .ok_or_else(|| StoreError::Backend("multipart upload id missing".into()))?
            .to_string();

        let abort = async {
            let _ = self
                .client
                .abort_multipart_upload()
                .bucket(&self.bucket)
                .key(key)
                .upload_id(&upload_id)
                .send()
                .await;
        };

        let mut file = File::open(path)
            .await
            .map_err(|e| StoreError::Backend(e.to_string()))?;
        let mut offset = 0u64;
        let mut part_number = 1i32;
        let mut parts: Vec<CompletedPart> = Vec::new();

        while offset < len {
            let this = (len - offset).min(part_size);
            file.seek(std::io::SeekFrom::Start(offset))
                .await
                .map_err(|e| StoreError::Backend(e.to_string()))?;
            let mut buf = vec![0u8; this as usize];
            file.read_exact(&mut buf)
                .await
                .map_err(|e| StoreError::Backend(e.to_string()))?;

            let resp = match self
                .client
                .upload_part()
                .bucket(&self.bucket)
                .key(key)
                .upload_id(&upload_id)
                .part_number(part_number)
                .content_length(this as i64)
                .body(ByteStream::from(buf))
                .send()
                .await
            {
                Ok(r) => r,
                Err(e) => {
                    abort.await;
                    return Err(StoreError::Backend(e.to_string()));
                }
            };
            let etag = resp
                .e_tag()
                .ok_or_else(|| StoreError::Backend("part etag missing".into()))?
                .to_string();
            parts.push(
                CompletedPart::builder()
                    .part_number(part_number)
                    .e_tag(etag)
                    .build(),
            );
            offset += this;
            part_number += 1;
        }

        self.client
            .complete_multipart_upload()
            .bucket(&self.bucket)
            .key(key)
            .upload_id(&upload_id)
            .multipart_upload(
                CompletedMultipartUpload::builder()
                    .set_parts(Some(parts))
                    .build(),
            )
            .send()
            .await
            .map_err(|e| StoreError::Backend(e.to_string()))?;
        Ok(())
    }
}

fn part_size_for(len: u64) -> u64 {
    let needed = len.div_ceil(MAX_PARTS).max(1);
    needed.max(MIN_PART)
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
        let (len, mut stream) = self.get_stream(key).await?;
        let mut out = Vec::with_capacity(len.min(64 * 1024 * 1024) as usize);
        while let Some(chunk) = stream.next().await {
            let bytes = chunk.map_err(|e| StoreError::Backend(e.to_string()))?;
            out.extend_from_slice(&bytes);
        }
        Ok(out)
    }

    async fn get_stream(&self, key: &str) -> Result<(u64, BlobStream), StoreError> {
        let out = self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| {
                classify_missing(e.as_service_error().map(|se| se.is_no_such_key()), &e)
            })?;
        let len = out.content_length().unwrap_or(0) as u64;
        let reader = out.body.into_async_read();
        let stream = ReaderStream::new(reader);
        Ok((len, Box::pin(stream)))
    }

    async fn head(&self, key: &str) -> Result<u64, StoreError> {
        let out = self
            .client
            .head_object()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| classify_missing(e.as_service_error().map(|se| se.is_not_found()), &e))?;
        Ok(out.content_length().unwrap_or(0) as u64)
    }

    async fn put(&self, key: &str, bytes: Vec<u8>) -> Result<(), StoreError> {
        let len = bytes.len() as u64;
        self.client
            .put_object()
            .bucket(&self.bucket)
            .key(key)
            .content_length(len as i64)
            .body(ByteStream::from(bytes))
            .send()
            .await
            .map_err(|e| StoreError::Backend(e.to_string()))?;
        Ok(())
    }

    async fn put_path(&self, key: &str, path: &Path) -> Result<(), StoreError> {
        let len = tokio::fs::metadata(path)
            .await
            .map_err(|e| StoreError::Backend(e.to_string()))?
            .len();
        if len <= MULTIPART_THRESHOLD {
            self.put_simple(key, path, len).await
        } else {
            self.put_multipart(key, path, len).await
        }
    }
}

#[cfg(test)]
mod part_size_tests {
    use super::{part_size_for, MAX_PARTS, MIN_PART, MULTIPART_THRESHOLD};

    #[test]
    fn small_object_uses_min_part() {
        assert_eq!(part_size_for(1), MIN_PART);
        assert_eq!(part_size_for(MULTIPART_THRESHOLD), MIN_PART);
    }

    #[test]
    fn tib_stays_under_max_parts() {
        let tib = 1u64 << 40;
        let part = part_size_for(tib);
        let parts = tib.div_ceil(part);
        assert!(parts <= MAX_PARTS, "parts={parts} part={part}");
        assert!(part >= MIN_PART);
    }
}

fn classify_missing(typed: Option<bool>, err: &impl std::fmt::Debug) -> StoreError {
    if typed == Some(true) {
        return StoreError::NotFound;
    }
    let debug = format!("{err:?}");
    if debug.contains("404") || debug.contains("NoSuchKey") || debug.contains("NotFound") {
        StoreError::NotFound
    } else {
        StoreError::Backend(debug)
    }
}

use axum::body::Body;
use futures_util::StreamExt;
use tokio::fs::File;
use tokio::io::AsyncWriteExt;

pub enum PumpError {
    TooLarge,
    Io(std::io::Error),
}

impl PumpError {
    pub fn is_full(&self) -> bool {
        matches!(self, PumpError::Io(e) if e.kind() == std::io::ErrorKind::StorageFull)
    }
}

/// Stream an HTTP body onto `file`, hashing as we go. `hasher` is
/// `None` for `.obao` (URL hash is the object's, not the outboard's).
pub async fn pump_body(
    body: Body,
    file: &mut File,
    mut hasher: Option<&mut blake3::Hasher>,
    max_bytes: u64,
) -> Result<u64, PumpError> {
    let mut written = 0u64;
    let mut stream = body.into_data_stream();
    while let Some(next) = stream.next().await {
        let chunk =
            next.map_err(|e| PumpError::Io(std::io::Error::new(std::io::ErrorKind::Other, e)))?;
        let add = chunk.len() as u64;
        if written.saturating_add(add) > max_bytes {
            return Err(PumpError::TooLarge);
        }
        if let Some(h) = hasher.as_mut() {
            h.update(&chunk);
        }
        file.write_all(&chunk).await.map_err(PumpError::Io)?;
        written += add;
    }
    file.flush().await.map_err(PumpError::Io)?;
    file.sync_all().await.map_err(PumpError::Io)?;
    Ok(written)
}

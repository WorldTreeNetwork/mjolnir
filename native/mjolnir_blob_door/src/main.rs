use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use mjolnir_blob_door::s3::S3Canonical;
use mjolnir_blob_door::{
    resolve_cache_dir, router, AppState, DiskCache, MemoryStore, DEFAULT_BIND, DEFAULT_BTRFS_ROOT,
    DEFAULT_CACHE_BYTES, DEFAULT_CACHE_DIR, DEFAULT_MAX_BYTES,
};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let bind: SocketAddr = std::env::var("BLOB_DOOR_BIND")
        .unwrap_or_else(|_| DEFAULT_BIND.to_owned())
        .parse()?;
    if !bind.ip().is_loopback() && std::env::var("BLOB_DOOR_ALLOW_NONLOCAL").as_deref() != Ok("1") {
        return Err("BLOB_DOOR_BIND must be loopback unless BLOB_DOOR_ALLOW_NONLOCAL=1".into());
    }

    let max_bytes = std::env::var("BLOB_DOOR_MAX_BYTES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_MAX_BYTES);
    let cache_budget = std::env::var("BLOB_DOOR_CACHE_BYTES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_CACHE_BYTES);

    let backend = std::env::var("BLOB_DOOR_BACKEND").unwrap_or_else(|_| "b2".into());
    let requested_cache_dir = std::env::var("BLOB_DOOR_CACHE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            if backend == "memory" {
                std::env::temp_dir().join("mjolnir-blob-door-memory")
            } else {
                PathBuf::from(DEFAULT_CACHE_DIR)
            }
        });
    let btrfs_root = std::env::var("MJOLNIR_BTRFS_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(DEFAULT_BTRFS_ROOT));
    let cache_dir = resolve_cache_dir(&requested_cache_dir, &btrfs_root)?;

    let cache = DiskCache::open(cache_dir.clone(), cache_budget).await?;
    tracing::info!(
        cache = %cache_dir.display(),
        cache_budget,
        max_bytes,
        "blob door cache"
    );

    match backend.as_str() {
        "memory" => {
            tracing::warn!("BLOB_DOOR_BACKEND=memory — not durable");
            serve(
                bind,
                AppState {
                    store: Arc::new(MemoryStore::new()),
                    cache: Arc::new(cache),
                    max_bytes,
                },
            )
            .await
        }
        "b2" => {
            let store = S3Canonical::from_env().await?;
            serve(
                bind,
                AppState {
                    store: Arc::new(store),
                    cache: Arc::new(cache),
                    max_bytes,
                },
            )
            .await
        }
        other => Err(format!("unknown BLOB_DOOR_BACKEND={other}").into()),
    }
}

async fn serve<S: mjolnir_blob_door::CanonicalStore + 'static>(
    bind: SocketAddr,
    state: AppState<S>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let listener = TcpListener::bind(bind).await?;
    tracing::info!(%bind, "blob door listening");
    axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown())
        .await?;
    Ok(())
}

async fn shutdown() {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("shutdown");
}

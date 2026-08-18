use std::net::SocketAddr;
use std::sync::Arc;

use mjolnir_blob_door::{router, AppState, MemoryStore, DEFAULT_BIND, DEFAULT_MAX_BYTES};
use mjolnir_blob_door::s3::S3Canonical;
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

    let backend = std::env::var("BLOB_DOOR_BACKEND").unwrap_or_else(|_| "b2".into());
    match backend.as_str() {
        "memory" => {
            tracing::warn!("BLOB_DOOR_BACKEND=memory — not durable");
            serve(
                bind,
                AppState {
                    store: Arc::new(MemoryStore::new()),
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

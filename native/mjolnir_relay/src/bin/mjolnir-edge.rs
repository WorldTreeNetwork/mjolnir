//! Local WebRTC edge admission process.
//! It does not mint tokens and it does not open a firewall.
//! A verified relay dial is not in this slice: media setup fails closed
//! (`setup_failed`) until that dial is reviewed. `/admit` never dials.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use mjolnir_relay::edge::Edge;
use mjolnir_relay::{key_file_trusted, load_verify_keys};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let keys_path = PathBuf::from(
        std::env::var("MJOLNIR_EDGE_KEYS").unwrap_or_else(|_| "/etc/mjolnir-relay/relay-keys.json".into()),
    );
    key_file_trusted(&keys_path)?;
    let keys = load_verify_keys(&keys_path)?;
    let edge = Edge::new(keys);
    let edge_reload = Arc::clone(&edge);
    let reload_path = keys_path.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(5));
        loop {
            tick.tick().await;
            if let Err(err) = edge_reload.reload_keys(&reload_path) {
                tracing::warn!("verify-set reload refused new admissions: {err}");
            }
        }
    });
    let bind = std::env::var("MJOLNIR_EDGE_BIND").unwrap_or_else(|_| "127.0.0.1:8444".into());
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!("edge admission listening on {bind}");
    axum::serve(listener, edge.router()).await?;
    Ok(())
}

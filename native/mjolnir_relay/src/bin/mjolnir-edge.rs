//! Local WebRTC edge. It does not mint tokens and it does not open a firewall.
//! Relay dials verify TLS. A disposable relay is trusted only through
//! `MJOLNIR_EDGE_TLS_ROOT` (system roots off). Otherwise the platform roots are used.
//! `/admit` never dials. Ingest keyframes use the adopted trial defaults.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use mjolnir_relay::edge::Edge;
use mjolnir_relay::moq_session::MoqConfig;
use mjolnir_relay::{key_file_trusted, load_verify_keys};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _ = moq_tokio::crypto::install_default();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".parse().unwrap()),
        )
        .init();
    let keys_path = PathBuf::from(
        std::env::var("MJOLNIR_EDGE_KEYS").unwrap_or_else(|_| "/etc/mjolnir-relay/relay-keys.json".into()),
    );
    key_file_trusted(&keys_path)?;
    let keys = load_verify_keys(&keys_path)?;
    let edge = Edge::new(keys);
    if let Ok(raw) = std::env::var("MJOLNIR_EDGE_MAX_TTL").or_else(|_| std::env::var("MJOLNIR_RELAY_TOKEN_MAX_TTL")) {
        let secs: u64 = raw.parse()?;
        edge.set_max_ttl(Duration::from_secs(secs)).map_err(|_| anyhow::anyhow!("max ttl must be non-zero"))?;
    }
    if let Ok(raw) = std::env::var("MJOLNIR_EDGE_ORIGINS") {
        let origins = raw.split(',').map(str::trim).filter(|origin| !origin.is_empty()).map(str::to_string).collect();
        edge.set_origins(origins);
    }
    let relay: url::Url = std::env::var("MJOLNIR_EDGE_RELAY")?.parse()?;
    let media_addr = std::env::var("MJOLNIR_EDGE_MEDIA")
        .unwrap_or_else(|_| "127.0.0.1:0".into())
        .parse()?;
    let media = moq_webrtc::Server::bind(media_addr, moq_webrtc::server::Config::default()).await?;
    let tls_root = std::env::var("MJOLNIR_EDGE_TLS_ROOT").ok().map(PathBuf::from);
    edge.set_moq(MoqConfig { relay, tls_root, media });
    let edge_drain = Arc::clone(&edge);
    tokio::spawn(async move {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{signal, SignalKind};
            let mut term = signal(SignalKind::terminate()).expect("sigterm");
            let mut int = signal(SignalKind::interrupt()).expect("sigint");
            tokio::select! {
                _ = term.recv() => {}
                _ = int.recv() => {}
            }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
        }
        tracing::warn!("edge drain: admissions closed, relay links dropped");
        edge_drain.drain();
    });
    let edge_reload = Arc::clone(&edge);
    let reload_path = keys_path.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(5));
        loop {
            tick.tick().await;
            edge_reload.sweep(std::time::SystemTime::now());
            if let Err(err) = edge_reload.reload_keys(&reload_path) {
                tracing::warn!("verify-set reload refused new admissions: {err}");
            }
        }
    });
    let bind = std::env::var("MJOLNIR_EDGE_BIND").unwrap_or_else(|_| "127.0.0.1:8444".into());
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!("edge admission listening on {bind}");
    // Plain HTTP/1. HTTP/2 is not advertised and is rejected by the HTTP/1 parser.
    mjolnir_relay::edge_http::serve(listener, edge.router()).await?;
    Ok(())
}

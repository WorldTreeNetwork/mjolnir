use std::{path::Path, sync::Arc};
use mjolnir_lan_files::{Share, http::router, REVISIONS};
#[tokio::main]
async fn main() {
    // Bind the guest TAP address explicitly; host publication is separate.
    let bind: std::net::SocketAddr = std::env::var("LAN_FILES_BIND").expect("LAN_FILES_BIND=guest-ip:port required").parse().expect("IPv4 socket address");
    assert!(bind.is_ipv4() && !bind.ip().is_unspecified() && bind.port() != 7222);
    let path = std::env::var("LAN_FILES_METADATA").unwrap_or_else(|_| "/var/lib/mjolnir/lan-files.sqlite".into());
    let share = Arc::new(Share::open(Path::new(&path)).expect("durable guest metadata"));
    eprintln!("identikey-auth={} recrypt-storage-auth={}", REVISIONS.0, REVISIONS.1);
    let listener = tokio::net::TcpListener::bind(bind).await.unwrap();
    axum::serve(listener, router(share)).with_graceful_shutdown(async { let _ = tokio::signal::ctrl_c().await; }).await.unwrap();
}

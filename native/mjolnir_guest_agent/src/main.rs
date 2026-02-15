//! Mjolnir Guest Agent
//!
//! Runs inside the Firecracker VM:
//! - Listens on vsock for host commands (exec, ping, configure_network)
//! - Optionally runs Iroh endpoint for remote shell access (if configured by host)
//! - Sends iroh_ready notification to host when shell is available

mod iroh;
mod protocol;
mod pty;
mod vsock;

use std::path::Path;
use tokio::sync::oneshot;
use tracing::{error, info};

const VSOCK_PORT: u32 = 5000;
const IROH_KEY_PATH: &str = "/etc/mjolnir/iroh.key";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    info!("Mjolnir guest agent starting");

    // Channel to send iroh_ready info to vsock task
    let (iroh_ready_tx, iroh_ready_rx) = oneshot::channel();

    // Channel to signal when to start Iroh (after configure_iroh message)
    let (iroh_start_tx, iroh_start_rx) = oneshot::channel();

    // Spawn vsock listener (handles all commands, waits for configure_iroh to start Iroh)
    let vsock_handle = tokio::spawn(vsock::run_vsock_listener(
        VSOCK_PORT,
        iroh_ready_rx,
        iroh_start_tx,
    ));

    // Wait for configure_iroh message from host
    info!("Waiting for configure_iroh message from host");
    let iroh_enabled = match iroh_start_rx.await {
        Ok(enabled) => enabled,
        Err(_) => {
            error!("Iroh start channel closed without signal - defaulting to disabled");
            false
        }
    };

    if iroh_enabled {
        info!("Starting Iroh endpoint");
        let key_path = Path::new(IROH_KEY_PATH);
        let iroh_handle = tokio::spawn(iroh::run_iroh_server(key_path, iroh_ready_tx));

        // Wait for either vsock or iroh to exit
        tokio::select! {
            res = vsock_handle => {
                match res {
                    Ok(Ok(())) => info!("Vsock listener exited normally"),
                    Ok(Err(e)) => error!("Vsock listener error: {}", e),
                    Err(e) => error!("Vsock task panicked: {}", e),
                }
            }
            res = iroh_handle => {
                match res {
                    Ok(Ok(())) => info!("Iroh server exited normally"),
                    Ok(Err(e)) => error!("Iroh server error: {}", e),
                    Err(e) => error!("Iroh task panicked: {}", e),
                }
            }
        }
    } else {
        info!("Iroh disabled - running vsock-only mode");
        // Just wait for vsock to exit
        match vsock_handle.await {
            Ok(Ok(())) => info!("Vsock listener exited normally"),
            Ok(Err(e)) => error!("Vsock listener error: {}", e),
            Err(e) => error!("Vsock task panicked: {}", e),
        }
    }

    Ok(())
}

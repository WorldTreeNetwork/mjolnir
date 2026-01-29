//! Mjolnir Guest Agent
//!
//! Runs inside the Firecracker VM:
//! - Listens on vsock for host commands (exec, ping, configure_network)
//! - Runs Iroh endpoint for remote shell access
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
    let (iroh_tx, iroh_rx) = oneshot::channel();

    // Spawn vsock listener (handles exec, ping, configure_network, sends iroh_ready)
    let vsock_handle = tokio::spawn(vsock::run_vsock_listener(VSOCK_PORT, iroh_rx));

    // Start Iroh endpoint (sends ticket via channel when ready)
    let key_path = Path::new(IROH_KEY_PATH);
    let iroh_handle = tokio::spawn(iroh::run_iroh_server(key_path, iroh_tx));

    // Wait for either to exit (shouldn't happen normally)
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

    Ok(())
}

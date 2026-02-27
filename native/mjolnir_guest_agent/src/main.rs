//! Mjolnir Guest Agent
//!
//! Runs inside the Firecracker VM:
//! - Listens on vsock for host commands (exec, ping, configure_network, pty)
//! - Optionally runs Iroh endpoint for remote shell access (if compiled with the `iroh` feature)
//! - Sends iroh_ready notification to host when shell is available
//! - Provides agent SDK HTTP server for in-VM agent applications

#[cfg(feature = "iroh")]
mod iroh;
mod agent;
mod protocol;
mod pty;
mod vsock;

use tracing::{error, info};

const VSOCK_PORT: u32 = 5000;
#[cfg(feature = "iroh")]
const IROH_KEY_PATH: &str = "/etc/mjolnir/iroh.key";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    info!("Mjolnir guest agent starting");

    // Channel to send iroh_ready info to vsock task
    #[cfg(feature = "iroh")]
    let (iroh_ready_tx, iroh_ready_rx) = tokio::sync::oneshot::channel();

    // Channel to signal when to start Iroh (after configure_iroh message)
    #[cfg(feature = "iroh")]
    let (iroh_start_tx, iroh_start_rx) = tokio::sync::oneshot::channel();

    // Shared bridge holder for agent SDK ↔ vsock communication
    let bridge_holder = vsock::new_bridge_holder();

    // Shared message inbox for inter-VM messaging
    let (message_inbox, message_notify) = vsock::new_message_inbox();

    // Spawn agent SDK HTTP server (with inbox for /recv and /messages endpoints)
    if let Err(e) = agent::run_agent_sdk(
        bridge_holder.clone(),
        message_inbox.clone(),
        message_notify.clone(),
    )
    .await
    {
        error!("Failed to start agent SDK: {}", e);
    }

    // Spawn vsock listener (handles all commands, waits for configure_iroh to start Iroh)
    let vsock_handle = tokio::spawn(vsock::run_vsock_listener(
        VSOCK_PORT,
        #[cfg(feature = "iroh")]
        iroh_ready_rx,
        #[cfg(feature = "iroh")]
        iroh_start_tx,
        bridge_holder,
        message_inbox,
        message_notify,
    ));

    #[cfg(feature = "iroh")]
    {
        use std::path::Path;

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
    }

    #[cfg(not(feature = "iroh"))]
    {
        info!("Running in vsock-only mode (Iroh not compiled in)");
        match vsock_handle.await {
            Ok(Ok(())) => info!("Vsock listener exited normally"),
            Ok(Err(e)) => error!("Vsock listener error: {}", e),
            Err(e) => error!("Vsock task panicked: {}", e),
        }
    }

    Ok(())
}

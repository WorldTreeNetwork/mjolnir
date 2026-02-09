//! Iroh endpoint for NAT-traversing shell access.

use crate::protocol::{IrohReady, ShellMessage};
use crate::pty::PtySession;
use iroh::endpoint::{Endpoint, Incoming};
use iroh::SecretKey;
use std::path::Path;
use tokio::sync::oneshot;
use tracing::{error, info, warn};

/// ALPN protocol identifier for Mjolnir shell
const SHELL_ALPN: &[u8] = b"mjolnir-shell/1";

/// Default shell to spawn
const DEFAULT_SHELL: &str = "/bin/bash";

pub async fn run_iroh_server(
    key_path: &Path,
    ready_tx: oneshot::Sender<IrohReady>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Load or generate keypair
    let (secret_key, generated) = load_or_generate_key(key_path)?;
    let node_id = secret_key.public();

    info!(
        "Iroh node_id: {} (key {})",
        node_id,
        if generated { "generated" } else { "loaded" }
    );

    // Build endpoint
    let endpoint = Endpoint::builder()
        .secret_key(secret_key)
        .alpns(vec![SHELL_ALPN.to_vec()])
        .bind()
        .await?;

    info!("Iroh endpoint bound, waiting for relay connection...");

    // Wait for relay connection (makes us reachable from internet)
    endpoint.online().await;

    // Get our endpoint address (includes relay info now that we're online)
    let endpoint_addr = endpoint.addr();
    let endpoint_id = endpoint.id();

    // Serialize EndpointAddr as JSON so clients can parse and connect
    let ticket = serde_json::to_string(&endpoint_addr)
        .expect("EndpointAddr serialization should not fail");

    info!("Shell ready. Endpoint ID: {}", endpoint_id);
    info!("Shell ticket: {}", ticket);

    // Send ready notification to vsock task
    let ready = IrohReady::new(endpoint_id.to_string(), ticket, generated);
    if ready_tx.send(ready).is_err() {
        warn!("Failed to send iroh_ready - receiver dropped");
    }

    // Accept incoming connections
    info!("Accepting shell connections...");
    while let Some(incoming) = endpoint.accept().await {
        tokio::spawn(handle_incoming(incoming));
    }

    Ok(())
}

fn load_or_generate_key(
    path: &Path,
) -> Result<(SecretKey, bool), Box<dyn std::error::Error + Send + Sync>> {
    if path.exists() {
        info!("Loading key from {:?}", path);
        let bytes = std::fs::read(path)?;
        if bytes.len() != 32 {
            return Err(format!("Invalid key length: {} (expected 32)", bytes.len()).into());
        }
        let key = SecretKey::from_bytes(&bytes.try_into().unwrap());
        Ok((key, false))
    } else {
        info!("Generating new key (file {:?} not found)", path);
        let key = SecretKey::generate(&mut rand::rng());

        // Try to save (might fail if /etc/mjolnir doesn't exist, that's ok)
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Err(e) = std::fs::write(path, key.to_bytes()) {
            warn!("Could not save key to {:?}: {}", path, e);
        } else {
            info!("Saved key to {:?}", path);
        }

        Ok((key, true))
    }
}

async fn handle_incoming(incoming: Incoming) {
    let conn = match incoming.await {
        Ok(conn) => conn,
        Err(e) => {
            warn!("Failed to accept connection: {}", e);
            return;
        }
    };

    let remote_id = conn.remote_id();
    info!("Shell connection from {:?}", remote_id);

    if let Err(e) = handle_shell_connection(conn).await {
        error!("Shell session error: {}", e);
    }

    info!("Shell connection from {:?} closed", remote_id);
}

async fn handle_shell_connection(
    conn: iroh::endpoint::Connection,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Accept bidirectional stream
    let (mut send, mut recv) = conn.accept_bi().await?;

    info!("Shell stream opened, spawning PTY");

    // Spawn PTY with default shell
    let mut pty = PtySession::spawn(DEFAULT_SHELL, 80, 24)?;

    // Bidirectional copy with message framing
    let mut recv_buf = vec![0u8; 4096];
    let mut pty_buf = vec![0u8; 4096];

    loop {
        tokio::select! {
            // Data from client
            result = recv.read(&mut recv_buf) => {
                match result {
                    Ok(Some(n)) if n > 0 => {
                        // Parse shell message
                        match serde_json::from_slice::<ShellMessage>(&recv_buf[..n]) {
                            Ok(ShellMessage::Data { payload }) => {
                                if let Err(e) = pty.write_all(&payload).await {
                                    error!("PTY write error: {}", e);
                                    break;
                                }
                            }
                            Ok(ShellMessage::Resize { rows, cols }) => {
                                if let Err(e) = pty.resize(rows, cols) {
                                    warn!("Resize failed: {}", e);
                                }
                            }
                            Ok(ShellMessage::Exit { .. }) => {
                                info!("Client requested exit");
                                break;
                            }
                            Err(e) => {
                                warn!("Invalid shell message: {}", e);
                            }
                        }
                    }
                    Ok(_) => {
                        info!("Client disconnected");
                        break;
                    }
                    Err(e) => {
                        error!("Recv error: {}", e);
                        break;
                    }
                }
            }

            // Data from PTY
            result = pty.read(&mut pty_buf) => {
                match result {
                    Ok(n) if n > 0 => {
                        let msg = ShellMessage::Data {
                            payload: pty_buf[..n].to_vec(),
                        };
                        let json = serde_json::to_vec(&msg)?;
                        if let Err(e) = send.write_all(&json).await {
                            error!("Send error: {}", e);
                            break;
                        }
                    }
                    Ok(_) => {
                        // PTY closed (shell exited)
                        let code = pty.wait_exit_code().await;
                        info!("Shell exited with code {}", code);
                        let msg = ShellMessage::Exit { code };
                        let json = serde_json::to_vec(&msg)?;
                        let _ = send.write_all(&json).await;
                        break;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        // No data available, check if process exited
                        if let Some(code) = pty.try_wait() {
                            info!("Shell exited with code {}", code);
                            let msg = ShellMessage::Exit { code };
                            let json = serde_json::to_vec(&msg)?;
                            let _ = send.write_all(&json).await;
                            break;
                        }
                        // Otherwise continue
                        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                    }
                    Err(e) => {
                        error!("PTY read error: {}", e);
                        break;
                    }
                }
            }
        }
    }

    Ok(())
}

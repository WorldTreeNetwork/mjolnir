//! Iroh endpoint for NAT-traversing shell access.

use crate::protocol::IrohReady;
use crate::pty::PtySession;
use iroh::endpoint::{Endpoint, Incoming};
use iroh::SecretKey;
use mjolnir_protocol::{read_frame, write_frame, Frame, PROTOCOL_VERSION, SHELL_ALPN, TCP_FWD_ALPN};
use std::path::Path;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::oneshot;
use tracing::{error, info, warn};

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
        .alpns(vec![SHELL_ALPN.to_vec(), TCP_FWD_ALPN.to_vec()])
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
    let alpn = conn.alpn();

    if alpn == SHELL_ALPN {
        info!("Shell connection from {:?}", remote_id);
        if let Err(e) = handle_shell_connection(conn).await {
            error!("Shell session error: {}", e);
        }
        info!("Shell connection from {:?} closed", remote_id);
    } else if alpn == TCP_FWD_ALPN {
        info!("TCP forward connection from {:?}", remote_id);
        if let Err(e) = handle_tcp_forward(conn).await {
            error!("TCP forward error: {}", e);
        }
        info!("TCP forward connection from {:?} closed", remote_id);
    } else {
        warn!("Unknown ALPN: {:?}", alpn);
    }
}

async fn handle_shell_connection(
    conn: iroh::endpoint::Connection,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Accept bidirectional stream
    let (mut send, mut recv) = conn.accept_bi().await?;

    info!("Shell stream opened, waiting for Hello");

    // Read Hello frame from client to get terminal size
    let (rows, cols) = match read_frame(&mut recv).await? {
        Some(Frame::Hello { rows, cols, version }) => {
            info!(
                "Client hello: {}x{}, protocol v{}",
                cols, rows, version
            );
            if version != PROTOCOL_VERSION {
                warn!(
                    "Protocol version mismatch: client v{}, server v{}",
                    version, PROTOCOL_VERSION
                );
            }
            (rows, cols)
        }
        Some(other) => {
            warn!("Expected Hello frame, got {:?}", other);
            return Err("expected Hello frame".into());
        }
        None => {
            info!("Client disconnected before Hello");
            return Ok(());
        }
    };

    // Spawn PTY with client-specified terminal size
    let mut pty = PtySession::spawn(DEFAULT_SHELL, cols, rows)?;
    info!("PTY spawned ({}x{})", cols, rows);

    // Bidirectional copy with binary framing
    let mut pty_buf = vec![0u8; 4096];

    loop {
        tokio::select! {
            // Frame from client
            result = read_frame(&mut recv) => {
                match result {
                    Ok(Some(Frame::Data(data))) => {
                        if let Err(e) = pty.write_all(&data).await {
                            error!("PTY write error: {}", e);
                            break;
                        }
                    }
                    Ok(Some(Frame::Resize { rows, cols })) => {
                        if let Err(e) = pty.resize(rows, cols) {
                            warn!("Resize failed: {}", e);
                        }
                    }
                    Ok(Some(Frame::Exit { .. })) => {
                        info!("Client requested exit");
                        break;
                    }
                    Ok(Some(Frame::Hello { .. })) => {
                        warn!("Unexpected Hello frame after handshake");
                    }
                    Ok(None) => {
                        info!("Client disconnected");
                        break;
                    }
                    Err(e) => {
                        error!("Frame read error: {}", e);
                        break;
                    }
                }
            }

            // Data from PTY
            result = pty.read(&mut pty_buf) => {
                match result {
                    Ok(n) if n > 0 => {
                        let frame = Frame::Data(pty_buf[..n].to_vec());
                        if let Err(e) = write_frame(&mut send, &frame).await {
                            error!("Send error: {}", e);
                            break;
                        }
                    }
                    Ok(_) => {
                        // PTY closed (shell exited)
                        let code = pty.wait_exit_code().await;
                        info!("Shell exited with code {}", code);
                        let _ = write_frame(&mut send, &Frame::Exit { code }).await;
                        break;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        // No data available, check if process exited
                        if let Some(code) = pty.try_wait() {
                            info!("Shell exited with code {}", code);
                            let _ = write_frame(&mut send, &Frame::Exit { code }).await;
                            break;
                        }
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

async fn handle_tcp_forward(
    conn: iroh::endpoint::Connection,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (mut quic_send, mut quic_recv) = conn.accept_bi().await?;

    // Read 2 bytes: target port (u16 big-endian)
    let mut port_buf = [0u8; 2];
    quic_recv.read_exact(&mut port_buf).await?;
    let port = u16::from_be_bytes(port_buf);

    info!("TCP forward to localhost:{}", port);

    let tcp_stream = TcpStream::connect(("127.0.0.1", port)).await?;
    let (mut tcp_read, mut tcp_write) = tokio::io::split(tcp_stream);

    // Bidirectional copy with graceful half-close
    let c2s = async {
        let r = tokio::io::copy(&mut quic_recv, &mut tcp_write).await;
        let _ = tcp_write.shutdown().await;
        r
    };
    let s2c = async {
        let r = tokio::io::copy(&mut tcp_read, &mut quic_send).await;
        let _ = quic_send.finish();
        r
    };

    let (c2s_result, s2c_result) = tokio::join!(c2s, s2c);
    if let Err(e) = c2s_result {
        info!("Client->server copy ended: {}", e);
    }
    if let Err(e) = s2c_result {
        info!("Server->client copy ended: {}", e);
    }

    Ok(())
}

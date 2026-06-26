//! Iroh endpoint for NAT-traversing shell access.
#![cfg(feature = "iroh")]

use crate::protocol::IrohReady;
use crate::pty::PtySession;
use iroh::endpoint::{Endpoint, Incoming};
use iroh::SecretKey;
use mjolnir_protocol::{
    read_frame, write_frame, Frame, PROTOCOL_VERSION, SECRET_INJECT_ALPN, SHELL_ALPN, TCP_FWD_ALPN,
};
use std::collections::HashSet;
use std::path::Path;
use std::sync::RwLock;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::sync::oneshot;
use tracing::{error, info, warn};

/// Authorized Iroh NodeIds that may use the SECRET_INJECT_ALPN.
/// Empty = reject all inject connections (default-deny).
static AUTHORIZED_INJECT_PEERS: std::sync::LazyLock<RwLock<HashSet<String>>> =
    std::sync::LazyLock::new(|| RwLock::new(HashSet::new()));

/// Add an authorized peer for secret injection.
pub fn authorize_inject_peer(node_id: &str) {
    let mut peers = AUTHORIZED_INJECT_PEERS.write().unwrap();
    peers.insert(node_id.to_string());
    info!("Authorized inject peer: {}", node_id);
}

/// Check if a peer is authorized for secret injection.
fn is_peer_authorized(node_id: &str) -> bool {
    let peers = AUTHORIZED_INJECT_PEERS.read().unwrap();
    peers.contains(node_id)
}

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
    let endpoint = Endpoint::builder(iroh::endpoint::presets::N0)
        .secret_key(secret_key)
        .alpns(vec![SHELL_ALPN.to_vec(), TCP_FWD_ALPN.to_vec(), SECRET_INJECT_ALPN.to_vec()])
        .bind()
        .await?;

    info!("Iroh endpoint bound, waiting for relay connection...");

    // Wait for relay connection (makes us reachable from internet)
    endpoint.online().await;

    // Get our endpoint address (includes relay info now that we're online)
    let endpoint_addr = endpoint.addr();
    let endpoint_id = endpoint.id();

    // Serialize EndpointAddr as JSON so clients can parse and connect
    let ticket =
        serde_json::to_string(&endpoint_addr).expect("EndpointAddr serialization should not fail");

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
        let key = SecretKey::generate();

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
    } else if alpn == SECRET_INJECT_ALPN {
        let remote_str = remote_id.to_string();
        if !is_peer_authorized(&remote_str) {
            warn!("Unauthorized secret inject attempt from {:?}", remote_id);
            return;
        }
        info!("Secret inject connection from {:?} (authorized)", remote_id);
        if let Err(e) = handle_secret_inject(conn).await {
            error!("Secret inject error: {:?}", e);
        }
        info!("Secret inject connection from {:?} closed", remote_id);
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
        Some(Frame::Hello {
            rows,
            cols,
            version,
        }) => {
            info!("Client hello: {}x{}, protocol v{}", cols, rows, version);
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

/// Handle a secret injection connection.
///
/// Protocol: simple JSON request/response over a bidirectional QUIC stream.
/// The passphrase is never logged.
async fn handle_secret_inject(
    conn: iroh::endpoint::Connection,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (mut send, mut recv) = conn.accept_bi().await?;

    // Read request (max 64KB — passphrase + JSON overhead)
    let mut buf = vec![0u8; 65536];
    let mut total = 0;
    loop {
        match recv.read(&mut buf[total..]).await? {
            Some(0) | None => break,
            Some(n) => {
                total += n;
                // Try to parse — the client may have finished sending
                if serde_json::from_slice::<serde_json::Value>(&buf[..total]).is_ok() {
                    break;
                }
                if total >= buf.len() {
                    break;
                }
            }
        }
    }

    let request: serde_json::Value = serde_json::from_slice(&buf[..total])
        .map_err(|e| format!("Invalid JSON request: {}", e))?;

    // Zero the read buffer after parsing to avoid leaving sensitive data (e.g. passphrase) in memory
    buf[..total].fill(0);

    let action = request
        .get("action")
        .and_then(|v| v.as_str())
        .unwrap_or("inject");

    let response = match action {
        "inject" => handle_inject_action(&request),
        "status" => handle_status_action(),
        "close" | "set_env" | "push_env" => {
            if !crate::secrets::is_injected() {
                serde_json::json!({ "ok": false, "error": "secrets not yet injected" })
            } else {
                match action {
                    "close" => handle_close_action(),
                    "set_env" => handle_set_env_action(&request),
                    "push_env" => handle_push_env_action(&request),
                    _ => unreachable!(),
                }
            }
        }
        _ => serde_json::json!({ "ok": false, "error": format!("unknown action: {}", action) }),
    };

    let response_bytes = serde_json::to_vec(&response)?;
    send.write_all(&response_bytes).await?;
    send.finish()?;

    Ok(())
}

fn handle_inject_action(request: &serde_json::Value) -> serde_json::Value {
    let passphrase = request
        .get("passphrase")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let init_size_mb = request
        .get("init_size_mb")
        .and_then(|v| v.as_u64())
        .map(|v| v as u32);

    match crate::secrets::inject(passphrase, init_size_mb) {
        Ok((created, mounted)) => serde_json::json!({
            "ok": true,
            "created": created,
            "mounted": mounted
        }),
        Err(e) => serde_json::json!({
            "ok": false,
            "error": e
        }),
    }
}

fn handle_status_action() -> serde_json::Value {
    use crate::secrets;
    serde_json::json!({
        "ok": true,
        "mounted": secrets::is_mounted(),
        "injected": secrets::is_injected(),
        "luks_exists": std::path::Path::new(secrets::SECRETS_LUKS_PATH).exists()
    })
}

fn handle_close_action() -> serde_json::Value {
    use crate::secrets;
    match secrets::close_secrets_volume() {
        Ok(()) => serde_json::json!({ "ok": true, "mounted": false }),
        Err(e) => serde_json::json!({ "ok": false, "error": e }),
    }
}

fn handle_set_env_action(request: &serde_json::Value) -> serde_json::Value {
    use crate::secrets;
    use std::collections::HashMap;

    let entries = match request.get("entries").and_then(|v| v.as_object()) {
        Some(obj) => {
            let mut map = HashMap::new();
            for (k, v) in obj {
                if let Some(val) = v.as_str() {
                    map.insert(k.clone(), val.to_string());
                }
            }
            map
        }
        None => {
            return serde_json::json!({
                "ok": false,
                "error": "entries object is required"
            });
        }
    };

    match secrets::set_env_vars(&entries) {
        Ok(()) => serde_json::json!({ "ok": true, "set": entries.len() }),
        Err(e) => serde_json::json!({ "ok": false, "error": e }),
    }
}

fn handle_push_env_action(request: &serde_json::Value) -> serde_json::Value {
    use crate::secrets;

    let content = match request.get("content").and_then(|v| v.as_str()) {
        Some(c) => c,
        None => {
            return serde_json::json!({
                "ok": false,
                "error": "content string is required"
            });
        }
    };

    match secrets::push_env_content(content) {
        Ok(()) => serde_json::json!({ "ok": true }),
        Err(e) => serde_json::json!({ "ok": false, "error": e }),
    }
}

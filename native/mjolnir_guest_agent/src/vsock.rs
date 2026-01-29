//! Vsock listener for host communication.

use crate::protocol::{IrohReady, VsockRequest, VsockResponse};
use std::process::Command;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::oneshot;
use tokio_vsock::{VsockListener, VsockStream};
use tracing::{error, info, warn};

const VMADDR_CID_ANY: u32 = 0xFFFFFFFF;

pub async fn run_vsock_listener(
    port: u32,
    mut iroh_ready_rx: oneshot::Receiver<IrohReady>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut listener = VsockListener::bind(VMADDR_CID_ANY, port)?;
    info!("Vsock listener started on port {}", port);

    // Track whether we've sent iroh_ready yet
    let mut iroh_ready_sent = false;

    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                info!("Vsock connection from {:?}", addr);

                // Check if iroh_ready is available (non-blocking)
                let ready_info = if !iroh_ready_sent {
                    match iroh_ready_rx.try_recv() {
                        Ok(info) => {
                            iroh_ready_sent = true;
                            Some(info)
                        }
                        Err(oneshot::error::TryRecvError::Empty) => None,
                        Err(oneshot::error::TryRecvError::Closed) => {
                            iroh_ready_sent = true; // Channel closed, won't get it
                            None
                        }
                    }
                } else {
                    None
                };

                tokio::spawn(handle_vsock_connection(stream, ready_info));
            }
            Err(e) => error!("Failed to accept vsock connection: {}", e),
        }
    }
}

async fn handle_vsock_connection(mut stream: VsockStream, iroh_ready: Option<IrohReady>) {
    // If we have iroh_ready, send it immediately as first message
    if let Some(ready) = iroh_ready {
        info!("Sending iroh_ready: node_id={}", ready.node_id);
        if let Err(e) = send_message(&mut stream, &ready).await {
            error!("Failed to send iroh_ready: {}", e);
            return;
        }
    }

    // Normal request/response loop
    let mut buf = vec![0u8; 65536];

    loop {
        // Read length prefix (4 bytes, big-endian)
        if let Err(e) = stream.read_exact(&mut buf[..4]).await {
            if e.kind() != std::io::ErrorKind::UnexpectedEof {
                error!("Failed to read length: {}", e);
            }
            return;
        }

        let length = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        if length > buf.len() {
            error!("Message too large: {}", length);
            return;
        }

        if let Err(e) = stream.read_exact(&mut buf[..length]).await {
            error!("Failed to read message: {}", e);
            return;
        }

        let response = match serde_json::from_slice::<VsockRequest>(&buf[..length]) {
            Ok(request) => handle_request(request),
            Err(e) => {
                warn!("Failed to parse request: {}", e);
                continue;
            }
        };

        if let Err(e) = send_message(&mut stream, &response).await {
            error!("Failed to send response: {}", e);
            return;
        }
    }
}

fn handle_request(request: VsockRequest) -> VsockResponse {
    match request {
        VsockRequest::Exec { id, command } => {
            info!("Exec: {}", command);
            let output = Command::new("sh").arg("-c").arg(&command).output();
            match output {
                Ok(out) => VsockResponse::ExecResponse {
                    id,
                    exit_code: out.status.code().unwrap_or(-1),
                    stdout: String::from_utf8_lossy(&out.stdout).to_string(),
                    stderr: String::from_utf8_lossy(&out.stderr).to_string(),
                },
                Err(e) => VsockResponse::ExecResponse {
                    id,
                    exit_code: -1,
                    stdout: String::new(),
                    stderr: format!("Failed to execute: {}", e),
                },
            }
        }
        VsockRequest::Ping { id } => {
            info!("Ping");
            VsockResponse::Pong { id }
        }
        VsockRequest::ConfigureNetwork { id, ip } => {
            info!("Configure network: {}", ip);
            let output = Command::new("/usr/local/bin/mjolnir-network-setup")
                .arg(&ip)
                .output();
            match output {
                Ok(out) => VsockResponse::ExecResponse {
                    id,
                    exit_code: out.status.code().unwrap_or(-1),
                    stdout: String::from_utf8_lossy(&out.stdout).to_string(),
                    stderr: String::from_utf8_lossy(&out.stderr).to_string(),
                },
                Err(e) => VsockResponse::ExecResponse {
                    id,
                    exit_code: -1,
                    stdout: String::new(),
                    stderr: format!("Failed to configure network: {}", e),
                },
            }
        }
    }
}

async fn send_message<T: serde::Serialize>(
    stream: &mut VsockStream,
    msg: &T,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let json = serde_json::to_vec(msg)?;
    let length = json.len() as u32;
    stream.write_all(&length.to_be_bytes()).await?;
    stream.write_all(&json).await?;
    stream.flush().await?;
    Ok(())
}

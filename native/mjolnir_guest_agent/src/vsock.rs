//! Vsock listener for host communication.

use crate::protocol::{IrohReady, VsockRequest, VsockResponse};
use std::os::unix::fs::PermissionsExt;
use std::process::Command;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{oneshot, RwLock};
use tokio_vsock::{VsockListener, VsockStream};
use tracing::{error, info, warn};

const VMADDR_CID_ANY: u32 = 0xFFFFFFFF;

/// Shared state for Iroh readiness
#[derive(Debug, Clone)]
pub enum IrohStatus {
    Disabled,
    Pending,
    Ready(IrohReady),
}

pub type IrohState = Arc<RwLock<IrohStatus>>;

pub async fn run_vsock_listener(
    port: u32,
    iroh_ready_rx: oneshot::Receiver<IrohReady>,
    iroh_start_tx: oneshot::Sender<bool>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut listener = VsockListener::bind(VMADDR_CID_ANY, port)?;
    info!("Vsock listener started on port {}", port);

    // Shared state for iroh status - starts as Pending
    let iroh_state: IrohState = Arc::new(RwLock::new(IrohStatus::Pending));

    // Spawn task to receive iroh_ready and update shared state
    let iroh_state_clone = iroh_state.clone();
    tokio::spawn(async move {
        match iroh_ready_rx.await {
            Ok(ready) => {
                info!("Iroh ready received, updating shared state");
                *iroh_state_clone.write().await = IrohStatus::Ready(ready);
            }
            Err(_) => {
                warn!("Iroh ready channel closed without sending");
            }
        }
    });

    // Accept connections, passing both state and the start trigger
    let iroh_start_tx = Arc::new(tokio::sync::Mutex::new(Some(iroh_start_tx)));

    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                info!("Vsock connection from {:?}", addr);
                let state = iroh_state.clone();
                let start_tx = iroh_start_tx.clone();
                tokio::spawn(handle_vsock_connection(stream, state, start_tx));
            }
            Err(e) => error!("Failed to accept vsock connection: {}", e),
        }
    }
}

async fn handle_vsock_connection(
    mut stream: VsockStream,
    iroh_state: IrohState,
    iroh_start_tx: Arc<tokio::sync::Mutex<Option<oneshot::Sender<bool>>>>,
) {
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
            Ok(request) => handle_request(request, &iroh_state, &iroh_start_tx).await,
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

async fn handle_request(
    request: VsockRequest,
    iroh_state: &IrohState,
    iroh_start_tx: &Arc<tokio::sync::Mutex<Option<oneshot::Sender<bool>>>>,
) -> VsockResponse {
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
        VsockRequest::GetIrohStatus { id } => {
            info!("GetIrohStatus");
            let state = iroh_state.read().await;
            match &*state {
                IrohStatus::Ready(ready) => VsockResponse::IrohStatus {
                    id,
                    ready: true,
                    node_id: Some(ready.node_id.clone()),
                    ticket: Some(ready.ticket.clone()),
                },
                IrohStatus::Pending => VsockResponse::IrohStatus {
                    id,
                    ready: false,
                    node_id: None,
                    ticket: None,
                },
                IrohStatus::Disabled => VsockResponse::IrohStatus {
                    id,
                    ready: false,
                    node_id: None,
                    ticket: None,
                },
            }
        }
        VsockRequest::ConfigureSsh { id, authorized_keys } => {
            info!("ConfigureSsh");
            let result = (|| -> std::io::Result<()> {
                std::fs::create_dir_all("/root/.ssh")?;
                std::fs::set_permissions("/root/.ssh", std::fs::Permissions::from_mode(0o700))?;
                let keys = if authorized_keys.ends_with('\n') {
                    authorized_keys.clone()
                } else {
                    format!("{}\n", authorized_keys)
                };
                std::fs::write("/root/.ssh/authorized_keys", keys)?;
                std::fs::set_permissions(
                    "/root/.ssh/authorized_keys",
                    std::fs::Permissions::from_mode(0o600),
                )?;
                Ok(())
            })();
            match result {
                Ok(()) => VsockResponse::ExecResponse {
                    id,
                    exit_code: 0,
                    stdout: "SSH keys configured".to_string(),
                    stderr: String::new(),
                },
                Err(e) => VsockResponse::ExecResponse {
                    id,
                    exit_code: -1,
                    stdout: String::new(),
                    stderr: format!("Failed to configure SSH: {}", e),
                },
            }
        }
        VsockRequest::ConfigureIdentity { id, vm_id, api_url } => {
            info!("ConfigureIdentity: vm_id={}, api_url={}", vm_id, api_url);
            let result = (|| -> std::io::Result<()> {
                std::fs::create_dir_all("/etc/mjolnir")?;
                let identity = serde_json::json!({
                    "vm_id": vm_id,
                    "api_url": api_url
                });
                std::fs::write(
                    "/etc/mjolnir/vm.json",
                    serde_json::to_string_pretty(&identity).unwrap(),
                )?;
                Ok(())
            })();
            match result {
                Ok(()) => VsockResponse::ExecResponse {
                    id,
                    exit_code: 0,
                    stdout: "Identity configured".to_string(),
                    stderr: String::new(),
                },
                Err(e) => VsockResponse::ExecResponse {
                    id,
                    exit_code: -1,
                    stdout: String::new(),
                    stderr: format!("Failed to configure identity: {}", e),
                },
            }
        }
        VsockRequest::ConfigureIroh { id, enabled } => {
            info!("ConfigureIroh: enabled={}", enabled);
            let mut tx_guard = iroh_start_tx.lock().await;
            if let Some(tx) = tx_guard.take() {
                // Send the start signal to main
                if tx.send(enabled).is_ok() {
                    if enabled {
                        info!("Iroh startup triggered");
                    } else {
                        info!("Iroh disabled");
                        *iroh_state.write().await = IrohStatus::Disabled;
                    }
                    VsockResponse::ConfigureIrohResponse { id, ok: true }
                } else {
                    warn!("Failed to send iroh start signal - channel closed");
                    VsockResponse::ConfigureIrohResponse { id, ok: false }
                }
            } else {
                warn!("ConfigureIroh called more than once");
                VsockResponse::ConfigureIrohResponse { id, ok: false }
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

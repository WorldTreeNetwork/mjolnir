//! Vsock listener for host communication.

#[cfg(feature = "iroh")]
use crate::protocol::IrohReady;
use crate::protocol::{VsockRequest, VsockResponse};
#[cfg(feature = "full")]
use crate::tmux;
use crate::pty::{PtySession, PtyWriter};
use std::collections::{HashMap, VecDeque};
use std::os::unix::fs::PermissionsExt;
use std::process::Command;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot, Mutex, Notify, RwLock};
use tokio::time::timeout;
use tokio_vsock::{VsockListener, VsockStream};
use tracing::{error, info, warn};

const VMADDR_CID_ANY: u32 = 0xFFFFFFFF;

/// Shared state for Iroh readiness
#[cfg(feature = "iroh")]
#[derive(Debug, Clone)]
pub enum IrohStatus {
    Disabled,
    Pending,
    Ready(IrohReady),
}

#[cfg(feature = "iroh")]
pub type IrohState = Arc<RwLock<IrohStatus>>;

/// Shared bridge allowing the agent SDK to send requests on the active vsock connection.
pub struct AgentBridge {
    write_tx: mpsc::Sender<FramedMsg>,
    pending_responses: Mutex<HashMap<String, oneshot::Sender<serde_json::Value>>>,
}

impl AgentBridge {
    /// Send a request over the vsock connection and wait for the response.
    /// The request JSON must contain an "id" field used to match the response.
    pub async fn send_request(
        &self,
        request: serde_json::Value,
    ) -> Result<serde_json::Value, Box<dyn std::error::Error + Send + Sync>> {
        let id = request
            .get("id")
            .and_then(|v| v.as_str())
            .ok_or("Request must contain an 'id' field")?
            .to_string();

        let (tx, rx) = oneshot::channel();

        // Register the pending response
        {
            let mut pending = self.pending_responses.lock().await;
            pending.insert(id.clone(), tx);
        }

        // Frame and send the request on channel 0
        let frame = frame_message(0, &request);
        if let Err(e) = self.write_tx.send(frame).await {
            // Clean up on send failure
            let mut pending = self.pending_responses.lock().await;
            pending.remove(&id);
            return Err(format!("Failed to send frame: {}", e).into());
        }

        // Wait for response with 30-second timeout
        match timeout(std::time::Duration::from_secs(30), rx).await {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(_)) => {
                // Sender was dropped (connection closed)
                Err("Connection closed while waiting for response".into())
            }
            Err(_) => {
                // Timeout — clean up pending entry
                let mut pending = self.pending_responses.lock().await;
                pending.remove(&id);
                Err("Request timed out after 30 seconds".into())
            }
        }
    }
}

/// Shared holder — set when host connection is established, cleared on disconnect.
pub type BridgeHolder = Arc<RwLock<Option<Arc<AgentBridge>>>>;

pub fn new_bridge_holder() -> BridgeHolder {
    Arc::new(RwLock::new(None))
}

/// A message delivered from another VM via the host.
#[derive(Debug, Clone)]
pub struct IncomingMessage {
    pub id: String,
    pub from_vm_id: String,
    pub payload: serde_json::Value,
}

/// Thread-safe inbox for messages delivered to this VM.
pub type MessageInbox = Arc<Mutex<VecDeque<IncomingMessage>>>;

/// Notification signal for when a new message arrives in the inbox.
pub type MessageNotify = Arc<Notify>;

pub fn new_message_inbox() -> (MessageInbox, MessageNotify) {
    (
        Arc::new(Mutex::new(VecDeque::new())),
        Arc::new(Notify::new()),
    )
}

/// Manages PTY write halves and channel allocation.
/// The read halves are owned by their respective output-forwarding tasks.
struct PtyManager {
    writers: HashMap<u8, Arc<Mutex<PtyWriter>>>,
    next_channel: u8,
}

impl PtyManager {
    fn new() -> Self {
        Self {
            writers: HashMap::new(),
            next_channel: 1,
        }
    }

    fn allocate_channel(&mut self) -> Option<u8> {
        for _ in 0..255 {
            let ch = self.next_channel;
            self.next_channel = self.next_channel.wrapping_add(1);
            if self.next_channel == 0 {
                self.next_channel = 1;
            }
            if !self.writers.contains_key(&ch) {
                return Some(ch);
            }
        }
        None
    }

    fn insert(&mut self, channel: u8, writer: Arc<Mutex<PtyWriter>>) {
        self.writers.insert(channel, writer);
    }

    fn remove(&mut self, channel: u8) -> Option<Arc<Mutex<PtyWriter>>> {
        self.writers.remove(&channel)
    }

    fn get(&self, channel: u8) -> Option<Arc<Mutex<PtyWriter>>> {
        self.writers.get(&channel).cloned()
    }
}

/// A pre-framed message ready to write to the vsock stream.
/// Contains the full wire format: [channel:u8][length:u32 BE][payload].
type FramedMsg = Vec<u8>;

/// Encode a serializable message into a framed wire message on a given channel.
fn frame_message<T: serde::Serialize>(channel: u8, msg: &T) -> FramedMsg {
    let json = serde_json::to_vec(msg).expect("JSON serialization failed");
    let length = json.len() as u32;
    let mut frame = Vec::with_capacity(5 + json.len());
    frame.push(channel);
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(&json);
    frame
}

/// Encode raw binary data into a framed wire message on a given channel.
fn frame_binary(channel: u8, data: &[u8]) -> FramedMsg {
    let length = data.len() as u32;
    let mut frame = Vec::with_capacity(5 + data.len());
    frame.push(channel);
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(data);
    frame
}

/// Boot agent vsock listener — handles Ping, PtyOpen, PtyResize, and PtyClose.
/// Rejects all other request types with an error response.
pub async fn run_boot_listener(port: u32) {
    let mut listener = match VsockListener::bind(VMADDR_CID_ANY, port) {
        Ok(l) => l,
        Err(e) => {
            error!("Failed to bind vsock boot listener on port {}: {}", port, e);
            return;
        }
    };
    eprintln!("[mjolnir-boot-agent] ready on vsock port {}", port);
    info!("Boot agent vsock listener started on port {}", port);

    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                info!("Boot agent: connection from {:?}", addr);
                tokio::spawn(handle_boot_connection(stream));
            }
            Err(e) => error!("Boot agent: failed to accept connection: {}", e),
        }
    }
}

async fn handle_boot_connection(mut stream: VsockStream) {
    let (write_tx, mut write_rx) = mpsc::channel::<FramedMsg>(64);
    let pty_manager = Arc::new(Mutex::new(PtyManager::new()));

    let mut read_buf = vec![0u8; 65536];
    let mut acc: Vec<u8> = Vec::new();

    'conn: loop {
        tokio::select! {
            result = stream.read(&mut read_buf) => {
                match result {
                    Ok(0) => {
                        info!("Boot agent: vsock connection closed");
                        break 'conn;
                    }
                    Ok(n) => {
                        acc.extend_from_slice(&read_buf[..n]);

                        while acc.len() >= 5 {
                            let channel = acc[0];
                            let length = u32::from_be_bytes([acc[1], acc[2], acc[3], acc[4]]) as usize;

                            if length > 65536 {
                                error!("Boot agent: message too large: {}", length);
                                break 'conn;
                            }

                            if acc.len() < 5 + length {
                                break;
                            }

                            let payload = acc[5..5 + length].to_vec();
                            acc.drain(..5 + length);

                            if channel == 0 {
                                // JSON control — handle Ping and PtyOpen only
                                let response = match serde_json::from_slice::<VsockRequest>(&payload) {
                                    Ok(VsockRequest::Ping { id }) => {
                                        VsockResponse::Pong { id, agent: Some("boot".to_string()) }
                                    }
                                    Ok(VsockRequest::PtyOpen { id, rows, cols }) => {
                                        let mut manager = pty_manager.lock().await;
                                        match manager.allocate_channel() {
                                            Some(ch) => {
                                                match PtySession::spawn("/bin/sh", cols, rows) {
                                                    Ok(session) => {
                                                        let (mut pty_reader, pty_writer) = session.into_split();
                                                        manager.insert(ch, Arc::new(Mutex::new(pty_writer)));
                                                        drop(manager);

                                                        let tx = write_tx.clone();
                                                        let pty_manager_clone = pty_manager.clone();
                                                        tokio::spawn(async move {
                                                            let mut buf = vec![0u8; 4096];
                                                            loop {
                                                                match pty_reader.read(&mut buf).await {
                                                                    Ok(0) => break,
                                                                    Ok(n) => {
                                                                        let frame = frame_binary(ch, &buf[..n]);
                                                                        if tx.send(frame).await.is_err() { break; }
                                                                    }
                                                                    Err(_) => break,
                                                                }
                                                            }
                                                            pty_manager_clone.lock().await.remove(ch);
                                                            let closed = frame_message(0, &VsockResponse::PtyClosed { channel: ch });
                                                            let _ = tx.send(closed).await;
                                                        });

                                                        VsockResponse::PtyOpened { id, channel: ch }
                                                    }
                                                    Err(e) => VsockResponse::ExecResponse {
                                                        id,
                                                        exit_code: -1,
                                                        stdout: String::new(),
                                                        stderr: format!("Failed to spawn PTY: {}", e),
                                                    },
                                                }
                                            }
                                            None => VsockResponse::ExecResponse {
                                                id,
                                                exit_code: -1,
                                                stdout: String::new(),
                                                stderr: "No available PTY channels".to_string(),
                                            },
                                        }
                                    }
                                    Ok(VsockRequest::PtyResize { id, channel, rows, cols }) => {
                                        let manager = pty_manager.lock().await;
                                        match manager.get(channel) {
                                            Some(writer) => {
                                                drop(manager);
                                                let w = writer.lock().await;
                                                match w.resize(rows, cols) {
                                                    Ok(()) => VsockResponse::ExecResponse {
                                                        id,
                                                        exit_code: 0,
                                                        stdout: "Resized".to_string(),
                                                        stderr: String::new(),
                                                    },
                                                    Err(e) => VsockResponse::ExecResponse {
                                                        id,
                                                        exit_code: -1,
                                                        stdout: String::new(),
                                                        stderr: format!("Resize failed: {}", e),
                                                    },
                                                }
                                            }
                                            None => VsockResponse::ExecResponse {
                                                id,
                                                exit_code: -1,
                                                stdout: String::new(),
                                                stderr: format!("Unknown PTY channel: {}", channel),
                                            },
                                        }
                                    }
                                    Ok(VsockRequest::PtyClose { channel }) => {
                                        pty_manager.lock().await.remove(channel);
                                        VsockResponse::PtyClosed { channel }
                                    }
                                    Ok(other) => {
                                        let id = match &other {
                                            VsockRequest::Exec { id, .. }
                                            | VsockRequest::ConfigureNetwork { id, .. }
                                            | VsockRequest::ConfigureSsh { id, .. }
                                            | VsockRequest::ConfigureIdentity { id, .. }
                                            | VsockRequest::DeliverMessage { id, .. }
                                            | VsockRequest::SignalDone { id }
                                            | VsockRequest::SignalDoneAck { id, .. }
                                            | VsockRequest::SpawnSubAgent { id, .. }
                                            | VsockRequest::SnapshotSelf { id, .. }
                                            | VsockRequest::EmitEvent { id, .. }
                                            | VsockRequest::SendMessage { id, .. } => id.clone(),
                                            _ => "unknown".to_string(),
                                        };
                                        warn!("Boot agent: rejecting unsupported request type");
                                        VsockResponse::ExecResponse {
                                            id,
                                            exit_code: -1,
                                            stdout: String::new(),
                                            stderr: "Not supported in boot agent".to_string(),
                                        }
                                    }
                                    Err(e) => {
                                        warn!("Boot agent: failed to parse request: {}", e);
                                        continue;
                                    }
                                };
                                let frame = frame_message(0, &response);
                                if write_tx.send(frame).await.is_err() {
                                    break 'conn;
                                }
                            } else {
                                // Binary data for PTY channel
                                let manager = pty_manager.lock().await;
                                if let Some(writer) = manager.get(channel) {
                                    drop(manager);
                                    let mut w = writer.lock().await;
                                    if let Err(e) = w.write_all(&payload).await {
                                        warn!("Boot agent: failed to write to PTY channel {}: {}", channel, e);
                                    }
                                } else {
                                    warn!("Boot agent: received data for unknown PTY channel: {}", channel);
                                }
                            }
                        }
                    }
                    Err(e) => {
                        if e.kind() != std::io::ErrorKind::UnexpectedEof {
                            error!("Boot agent: failed to read from vsock: {}", e);
                        }
                        break 'conn;
                    }
                }
            }
            Some(frame) = write_rx.recv() => {
                if let Err(e) = stream.write_all(&frame).await {
                    error!("Boot agent: failed to write to vsock: {}", e);
                    break 'conn;
                }
                while let Ok(frame) = write_rx.try_recv() {
                    if let Err(e) = stream.write_all(&frame).await {
                        error!("Boot agent: failed to write to vsock: {}", e);
                        break 'conn;
                    }
                }
                if let Err(e) = stream.flush().await {
                    error!("Boot agent: failed to flush vsock: {}", e);
                    break 'conn;
                }
            }
        }
    }
}

pub async fn run_vsock_listener(
    port: u32,
    #[cfg(feature = "iroh")] iroh_ready_rx: oneshot::Receiver<IrohReady>,
    #[cfg(feature = "iroh")] iroh_start_tx: oneshot::Sender<bool>,
    bridge_holder: BridgeHolder,
    message_inbox: MessageInbox,
    message_notify: MessageNotify,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut listener = VsockListener::bind(VMADDR_CID_ANY, port)?;
    info!("Vsock listener started on port {}", port);

    // Shared state for iroh status - starts as Pending
    #[cfg(feature = "iroh")]
    let iroh_state: IrohState = Arc::new(RwLock::new(IrohStatus::Pending));

    // Spawn task to receive iroh_ready and update shared state
    #[cfg(feature = "iroh")]
    {
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
    }

    // Accept connections, passing both state and the start trigger
    #[cfg(feature = "iroh")]
    let iroh_start_tx = Arc::new(tokio::sync::Mutex::new(Some(iroh_start_tx)));

    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                info!("Vsock connection from {:?}", addr);
                #[cfg(feature = "iroh")]
                let state = iroh_state.clone();
                #[cfg(feature = "iroh")]
                let start_tx = iroh_start_tx.clone();
                let bridge = bridge_holder.clone();
                let inbox = message_inbox.clone();
                let notify = message_notify.clone();
                tokio::spawn(handle_vsock_connection(
                    stream,
                    #[cfg(feature = "iroh")]
                    state,
                    #[cfg(feature = "iroh")]
                    start_tx,
                    bridge,
                    inbox,
                    notify,
                ));
            }
            Err(e) => error!("Failed to accept vsock connection: {}", e),
        }
    }
}

async fn handle_vsock_connection(
    mut stream: VsockStream,
    #[cfg(feature = "iroh")] iroh_state: IrohState,
    #[cfg(feature = "iroh")] iroh_start_tx: Arc<tokio::sync::Mutex<Option<oneshot::Sender<bool>>>>,
    bridge_holder: BridgeHolder,
    message_inbox: MessageInbox,
    message_notify: MessageNotify,
) {
    // Channel for outgoing writes. PTY output tasks and the reader loop
    // send pre-framed messages here; the writer half drains them.
    let (write_tx, mut write_rx) = mpsc::channel::<FramedMsg>(64);

    let pty_manager = Arc::new(Mutex::new(PtyManager::new()));

    // Set up the agent bridge so the SDK can send requests on this connection
    let bridge = Arc::new(AgentBridge {
        write_tx: write_tx.clone(),
        pending_responses: Mutex::new(HashMap::new()),
    });
    *bridge_holder.write().await = Some(bridge.clone());

    // We need to multiplex reading from the stream and writing queued
    // frames. We can't use tokio::io::split (shared internal mutex), so
    // we buffer incoming data and use select! to interleave read/write.
    let mut read_buf = vec![0u8; 65536];
    // Accumulator for incomplete frames
    let mut acc: Vec<u8> = Vec::new();

    'conn: loop {
        tokio::select! {
            // --- Read bytes from vsock ---
            result = stream.read(&mut read_buf) => {
                match result {
                    Ok(0) => {
                        info!("Vsock connection closed");
                        break 'conn;
                    }
                    Ok(n) => {
                        acc.extend_from_slice(&read_buf[..n]);

                        // Process all complete frames in the accumulator
                        while acc.len() >= 5 {
                            let channel = acc[0];
                            let length = u32::from_be_bytes([acc[1], acc[2], acc[3], acc[4]]) as usize;

                            if length > 65536 {
                                error!("Message too large: {}", length);
                                break 'conn;
                            }

                            if acc.len() < 5 + length {
                                break; // need more data
                            }

                            let payload = acc[5..5 + length].to_vec();
                            acc.drain(..5 + length);

                            if channel == 0 {
                                // JSON control message — first check if it's a response
                                // to a pending agent SDK request
                                let json_value: serde_json::Value = match serde_json::from_slice(&payload) {
                                    Ok(v) => v,
                                    Err(e) => {
                                        warn!("Failed to parse JSON: {}", e);
                                        continue;
                                    }
                                };

                                // Only check bridge for known response types to avoid
                                // consuming host-initiated requests (exec, ping, etc.)
                                let is_response = json_value
                                    .get("type")
                                    .and_then(|v| v.as_str())
                                    .map(|t| {
                                        t.ends_with("_response")
                                            || t == "event_ack"
                                            || t == "pong"
                                            || t == "deliver_message_ack"
                                            || t == "signal_done_ack"
                                    })
                                    .unwrap_or(false);

                                if is_response {
                                    if let Some(id) = json_value.get("id").and_then(|v| v.as_str()) {
                                        let id = id.to_string();
                                        let mut pending = bridge.pending_responses.lock().await;
                                        if let Some(sender) = pending.remove(&id) {
                                            let _ = sender.send(json_value);
                                            continue; // response routed, skip normal handling
                                        }
                                    }
                                }

                                // Not a pending response — handle as normal VsockRequest
                                match serde_json::from_value::<VsockRequest>(json_value) {
                                    Ok(request) => {
                                        let response = handle_request(
                                            request,
                                            #[cfg(feature = "iroh")]
                                            &iroh_state,
                                            #[cfg(feature = "iroh")]
                                            &iroh_start_tx,
                                            &pty_manager,
                                            &write_tx,
                                            &message_inbox,
                                            &message_notify,
                                        ).await;
                                        let frame = frame_message(0, &response);
                                        if write_tx.send(frame).await.is_err() {
                                            break 'conn;
                                        }
                                    }
                                    Err(e) => {
                                        warn!("Failed to parse request: {}", e);
                                    }
                                }
                            } else {
                                // Binary PTY data (input to PTY stdin)
                                let manager = pty_manager.lock().await;
                                if let Some(writer) = manager.get(channel) {
                                    drop(manager);
                                    let mut w = writer.lock().await;
                                    if let Err(e) = w.write_all(&payload).await {
                                        warn!("Failed to write to PTY channel {}: {}", channel, e);
                                    }
                                } else {
                                    warn!("Received data for unknown PTY channel: {}", channel);
                                }
                            }
                        }
                    }
                    Err(e) => {
                        if e.kind() != std::io::ErrorKind::UnexpectedEof {
                            error!("Failed to read from vsock: {}", e);
                        }
                        break 'conn;
                    }
                }
            }
            // --- Write queued frames to vsock ---
            Some(frame) = write_rx.recv() => {
                if let Err(e) = stream.write_all(&frame).await {
                    error!("Failed to write to vsock: {}", e);
                    break 'conn;
                }
                // Drain any additional queued frames before flushing
                while let Ok(frame) = write_rx.try_recv() {
                    if let Err(e) = stream.write_all(&frame).await {
                        error!("Failed to write to vsock: {}", e);
                        break 'conn;
                    }
                }
                if let Err(e) = stream.flush().await {
                    error!("Failed to flush vsock: {}", e);
                    break 'conn;
                }
            }
        }
    }

    // Clear bridge on disconnect — pending requests will fail via dropped oneshot senders
    info!("Clearing agent bridge");
    *bridge_holder.write().await = None;
}

async fn handle_request(
    request: VsockRequest,
    #[cfg(feature = "iroh")] iroh_state: &IrohState,
    #[cfg(feature = "iroh")] iroh_start_tx: &Arc<tokio::sync::Mutex<Option<oneshot::Sender<bool>>>>,
    pty_manager: &Arc<Mutex<PtyManager>>,
    write_tx: &mpsc::Sender<FramedMsg>,
    message_inbox: &MessageInbox,
    message_notify: &MessageNotify,
) -> VsockResponse {
    match request {
        VsockRequest::Exec { id, command } => {
            info!("Exec: {}", command);
            // Source secrets env before every command (no-op if file doesn't exist)
            // Note: must use `test -f` guard because `.` is a POSIX special builtin —
            // in dash (Ubuntu's /bin/sh), `. /nonexistent` exits the shell immediately.
            #[cfg(feature = "full")]
            let wrapped = format!("[ -f {} ] && . {}; {}", crate::secrets::SECRETS_ENV_PATH, crate::secrets::SECRETS_ENV_PATH, command);
            #[cfg(not(feature = "full"))]
            let wrapped = command.clone();
            let output = Command::new("sh").arg("-c").arg(&wrapped).output();
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
            VsockResponse::Pong { id, agent: None }
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
        #[cfg(feature = "iroh")]
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
        VsockRequest::ConfigureSsh {
            id,
            authorized_keys,
        } => {
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
        #[cfg(feature = "iroh")]
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
        VsockRequest::PtyOpen { id, rows, cols } => {
            info!("PtyOpen: rows={}, cols={}", rows, cols);
            let mut manager = pty_manager.lock().await;

            match manager.allocate_channel() {
                Some(channel) => {
                    // Spawn PTY session with /bin/bash
                    match PtySession::spawn("/bin/bash", cols, rows) {
                        Ok(session) => {
                            // Split into reader (for output task) and writer (for input/resize).
                            // No shared mutex — reader and writer use separate dup'd fds.
                            let (mut pty_reader, pty_writer) = session.into_split();
                            manager.insert(channel, Arc::new(Mutex::new(pty_writer)));
                            drop(manager);

                            // Spawn task to forward PTY output to vsock via the write channel.
                            // The reader is owned exclusively by this task — no locking needed.
                            let tx = write_tx.clone();
                            let pty_manager_clone = pty_manager.clone();
                            tokio::spawn(async move {
                                let mut buf = vec![0u8; 4096];
                                loop {
                                    match pty_reader.read(&mut buf).await {
                                        Ok(0) => {
                                            info!("PTY channel {} closed", channel);
                                            break;
                                        }
                                        Ok(n) => {
                                            let frame = frame_binary(channel, &buf[..n]);
                                            if tx.send(frame).await.is_err() {
                                                break;
                                            }
                                        }
                                        Err(e) => {
                                            error!("PTY read error on channel {}: {}", channel, e);
                                            break;
                                        }
                                    }
                                }

                                // Clean up
                                pty_manager_clone.lock().await.remove(channel);

                                // Send pty_closed notification
                                let closed =
                                    frame_message(0, &VsockResponse::PtyClosed { channel });
                                let _ = tx.send(closed).await;
                            });

                            VsockResponse::PtyOpened { id, channel }
                        }
                        Err(e) => {
                            error!("Failed to spawn PTY: {}", e);
                            VsockResponse::ExecResponse {
                                id,
                                exit_code: -1,
                                stdout: String::new(),
                                stderr: format!("Failed to spawn PTY: {}", e),
                            }
                        }
                    }
                }
                None => {
                    error!("No available PTY channels");
                    VsockResponse::ExecResponse {
                        id,
                        exit_code: -1,
                        stdout: String::new(),
                        stderr: "No available PTY channels".to_string(),
                    }
                }
            }
        }
        VsockRequest::PtyResize {
            id,
            channel,
            rows,
            cols,
        } => {
            info!(
                "PtyResize: channel={}, rows={}, cols={}",
                channel, rows, cols
            );
            let manager = pty_manager.lock().await;
            match manager.get(channel) {
                Some(writer) => {
                    drop(manager);
                    let w = writer.lock().await;
                    match w.resize(rows, cols) {
                        Ok(()) => VsockResponse::ExecResponse {
                            id,
                            exit_code: 0,
                            stdout: "Resized".to_string(),
                            stderr: String::new(),
                        },
                        Err(e) => VsockResponse::ExecResponse {
                            id,
                            exit_code: -1,
                            stdout: String::new(),
                            stderr: format!("Resize failed: {}", e),
                        },
                    }
                }
                None => VsockResponse::ExecResponse {
                    id,
                    exit_code: -1,
                    stdout: String::new(),
                    stderr: format!("Unknown PTY channel: {}", channel),
                },
            }
        }
        VsockRequest::PtyClose { channel } => {
            info!("PtyClose: channel={}", channel);
            let mut manager = pty_manager.lock().await;
            manager.remove(channel);
            VsockResponse::PtyClosed { channel }
        }
        VsockRequest::DeliverMessage {
            id,
            from_vm_id,
            payload,
        } => {
            info!("DeliverMessage from {}", from_vm_id);
            let msg = IncomingMessage {
                id: id.clone(),
                from_vm_id,
                payload,
            };
            message_inbox.lock().await.push_back(msg);
            message_notify.notify_waiters();
            VsockResponse::DeliverMessageAck { id }
        }
        #[cfg(feature = "full")]
        VsockRequest::TerminalOpen { id, session_name } => {
            info!("TerminalOpen: {}", session_name);
            match tmux::ensure_session(&session_name).await {
                Ok((name, status)) => VsockResponse::TerminalOpened { id, session_name: name, status },
                Err(e) => VsockResponse::TerminalError { id, error: e.to_string() },
            }
        }
        #[cfg(feature = "full")]
        VsockRequest::TerminalRead { id, session_name, scrollback_lines } => {
            let lines = scrollback_lines.unwrap_or(100);
            match tmux::capture_pane(&session_name, lines).await {
                Ok((content, pane_rows, pane_cols, running_command)) => {
                    VsockResponse::TerminalOutput { id, content, pane_rows, pane_cols, running_command }
                }
                Err(e) => VsockResponse::TerminalError { id, error: e.to_string() },
            }
        }
        #[cfg(feature = "full")]
        VsockRequest::TerminalSend { id, session_name, command, keys } => {
            match tmux::send_keys(&session_name, command.as_deref(), keys.as_deref()).await {
                Ok(()) => VsockResponse::TerminalSent { id, sent: true },
                Err(e) => VsockResponse::TerminalError { id, error: e.to_string() },
            }
        }
        #[cfg(feature = "full")]
        VsockRequest::TerminalSendAndRead { id, session_name, command, timeout_ms } => {
            let timeout = timeout_ms.unwrap_or(30_000);
            let sentinel_id = uuid::Uuid::new_v4().to_string();
            let write_tx = write_tx.clone();
            let id_for_ack = id.clone();

            tokio::spawn(async move {
                let result = tmux::send_and_read(&session_name, &command, timeout, &sentinel_id).await;
                let response = match result {
                    Ok(output) => VsockResponse::TerminalCommandOutput {
                        id,
                        output: output.output,
                        exit_code: output.exit_code,
                        duration_ms: output.duration_ms,
                        timed_out: output.timed_out,
                    },
                    Err(e) => {
                        warn!("TerminalSendAndRead error for session {}: {}", session_name, e);
                        VsockResponse::TerminalError { id, error: e.to_string() }
                    },
                };
                let frame = frame_message(0, &response);
                if let Err(e) = write_tx.send(frame).await {
                    warn!("TerminalSendAndRead failed to send frame: {}", e);
                }
            });

            VsockResponse::TerminalCommandAck { id: id_for_ack, status: "polling".to_string() }
        }
        #[cfg(feature = "full")]
        VsockRequest::TerminalList { id } => {
            match tmux::list_sessions().await {
                Ok(sessions) => VsockResponse::TerminalSessions { id, sessions },
                Err(e) => VsockResponse::TerminalError { id, error: e.to_string() },
            }
        }
        #[cfg(feature = "full")]
        VsockRequest::TerminalClose { id, session_name } => {
            match tmux::kill_session(&session_name).await {
                Ok(()) => VsockResponse::TerminalClosed { id, session_name },
                Err(e) => VsockResponse::TerminalError { id, error: e.to_string() },
            }
        }
        #[cfg(feature = "full")]
        VsockRequest::ConfigureSecretsAuth { id, authorized_peers } => {
            info!("ConfigureSecretsAuth: {} peers", authorized_peers.len());
            #[cfg(feature = "iroh")]
            {
                for peer in &authorized_peers {
                    crate::iroh::authorize_inject_peer(peer);
                }
            }
            VsockResponse::ExecResponse {
                id,
                exit_code: 0,
                stdout: format!("authorized {} peers", authorized_peers.len()),
                stderr: String::new(),
            }
        }
        VsockRequest::SpawnSubAgent { id, .. }
        | VsockRequest::SnapshotSelf { id, .. }
        | VsockRequest::EmitEvent { id, .. }
        | VsockRequest::SendMessage { id, .. }
        | VsockRequest::SignalDone { id, .. } => {
            warn!("Received guest-to-host message type as incoming request (unexpected)");
            VsockResponse::ExecResponse {
                id,
                exit_code: -1,
                stdout: String::new(),
                stderr: "This message type is guest-to-host only".to_string(),
            }
        }
        VsockRequest::SignalDoneAck { id, .. } => {
            // Host→guest response, handled via bridge pending_responses
            VsockResponse::ExecResponse {
                id,
                exit_code: 0,
                stdout: "ack received".to_string(),
                stderr: String::new(),
            }
        }
    }
}

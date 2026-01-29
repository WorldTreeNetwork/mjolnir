# Phase 2: Iroh Shell Server — Detailed Implementation

**Goal:** Interactive shell accessible via Iroh ticket from anywhere (NAT traversal)

**Dependencies:** Phase 1 complete (guest has outbound networking for relay connectivity)

**Estimated effort:** 3-5 focused sessions

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ANYWHERE                                        │
│                                                                             │
│   ┌─────────────────┐         ┌─────────────────┐                          │
│   │  User Terminal  │         │  n0 Relay       │                          │
│   │                 │◄───────►│  (QUIC)         │◄────────┐                │
│   │  mjolnir shell  │  QUIC   │                 │         │                │
│   └─────────────────┘         └─────────────────┘         │                │
│                                       ▲                    │ QUIC           │
│                                       │ fallback           │ (hole-punch    │
│                                       │                    │  or relay)     │
└───────────────────────────────────────┼────────────────────┼────────────────┘
                                        │                    │
┌───────────────────────────────────────┼────────────────────┼────────────────┐
│                              HOST     │                    ▼                │
│                                       │        ┌─────────────────┐          │
│   ┌─────────────────┐                 │        │   TAP + NAT     │          │
│   │  Mjolnir        │                 │        │   (Phase 1)     │          │
│   │  (Elixir)       │                 │        └────────┬────────┘          │
│   │                 │                 │                 │                   │
│   │  - VM Registry  │                 │                 │                   │
│   │  - ticket cache │                 │                 │                   │
│   └────────┬────────┘                 │                 │                   │
│            │ vsock                    │                 │                   │
│            │ iroh_ready msg           │                 │                   │
│            ▼                          │                 │                   │
│   ┌──────────────────────────────────────────────────────────────────┐     │
│   │                        FIRECRACKER VM                              │     │
│   │                                                                    │     │
│   │   ┌────────────────────────────────────────────────────────────┐  │     │
│   │   │                    Guest Agent (Rust)                       │  │     │
│   │   │                                                             │  │     │
│   │   │  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐ │  │     │
│   │   │  │ Vsock       │    │ Iroh        │    │ PTY Manager     │ │  │     │
│   │   │  │ Listener    │    │ Endpoint    │    │                 │ │  │     │
│   │   │  │ (port 5000) │    │             │    │ - forkpty()     │ │  │     │
│   │   │  │             │    │ - accept()  │───►│ - /bin/bash     │ │  │     │
│   │   │  │ - exec      │    │ - node_id   │    │ - stdin/stdout  │ │  │     │
│   │   │  │ - ping      │    │ - ticket    │    │ - SIGWINCH      │ │  │     │
│   │   │  │ - net_cfg   │    │             │    └─────────────────┘ │  │     │
│   │   │  └─────────────┘    └──────┬──────┘                        │  │     │
│   │   │         ▲                  │                                │  │     │
│   │   │         │ iroh_ready       │ QUIC streams                   │  │     │
│   │   │         │ {ticket, node_id}│ (ALPN: "mjolnir-shell/1")     │  │     │
│   │   └─────────┼──────────────────┼────────────────────────────────┘  │     │
│   │             │                  │                                   │     │
│   └─────────────┼──────────────────┼───────────────────────────────────┘     │
│                 │                  │                                         │
└─────────────────┼──────────────────┼─────────────────────────────────────────┘
                  │                  │
                  │                  └──── to relay / direct peer
                  └──── to host Elixir
```

### Connection Flow

```
1. VM boots, guest agent starts
2. Agent generates/loads keypair
3. Agent creates Iroh Endpoint (connects to relay)
4. Agent waits for home_relay to be available
5. Agent sends iroh_ready via vsock: {node_id, ticket}
6. Host caches ticket in VM registry

--- Later ---

7. Client connects using ticket (QUIC, ALPN: "mjolnir-shell/1")
8. Agent accepts connection, spawns PTY with /bin/zsh
9. Bidirectional stream: client stdin → PTY stdin, PTY stdout → client stdout
10. Window resize: client sends resize message → agent calls TIOCSWINSZ
11. On disconnect: PTY process killed, resources cleaned
```

---

## File Changes

### 1. `native/mjolnir_guest_agent/Cargo.toml` (MODIFY)

Add iroh-net and PTY dependencies:

```toml
[package]
name = "mjolnir-guest-agent"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
tokio = { version = "1", features = ["full", "signal"] }
tokio-vsock = "0.4"
tracing = "0.1"
tracing-subscriber = "0.3"

# Phase 2: Iroh shell
iroh-net = "0.28"
iroh-base = "0.28"           # For NodeTicket
futures-lite = "2"           # For stream utilities
nix = { version = "0.29", features = ["pty", "signal", "term"] }  # Unix syscalls, NOT NixOS
libc = "0.2"

[[bin]]
name = "mjolnir-agent"
path = "src/main.rs"
```

**Binary size measurement task:** Record size before/after adding iroh-net.

---

### 2. `native/mjolnir_guest_agent/src/main.rs` (MAJOR REWRITE)

Split into modules for clarity. New structure:

```
src/
├── main.rs           # Entry point, orchestration
├── vsock.rs          # Vsock listener & protocol (existing, extracted)
├── iroh.rs           # Iroh endpoint & shell server
├── pty.rs            # PTY allocation and management
└── protocol.rs       # Shared message types
```

#### `src/main.rs` (new)

```rust
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

    // Start Iroh endpoint (blocks until relay connected, then sends ticket via channel)
    let key_path = Path::new(IROH_KEY_PATH);
    let iroh_handle = tokio::spawn(iroh::run_iroh_server(key_path, iroh_tx));

    // Wait for either to exit (shouldn't happen normally)
    tokio::select! {
        res = vsock_handle => {
            error!("Vsock listener exited: {:?}", res);
        }
        res = iroh_handle => {
            error!("Iroh server exited: {:?}", res);
        }
    }

    Ok(())
}
```

#### `src/protocol.rs` (new)

```rust
//! Wire protocol messages for vsock and Iroh communication.

use serde::{Deserialize, Serialize};

/// Messages from host to guest (vsock)
#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum VsockRequest {
    #[serde(rename = "exec")]
    Exec { id: String, command: String },
    #[serde(rename = "ping")]
    Ping { id: String },
    #[serde(rename = "configure_network")]
    ConfigureNetwork { id: String, ip: String },
}

/// Messages from guest to host (vsock)
#[derive(Debug, Serialize)]
#[serde(tag = "type")]
pub enum VsockResponse {
    #[serde(rename = "exec_response")]
    ExecResponse {
        id: String,
        exit_code: i32,
        stdout: String,
        stderr: String,
    },
    #[serde(rename = "pong")]
    Pong { id: String },
}

/// Notification sent when Iroh is ready
#[derive(Debug, Serialize)]
pub struct IrohReady {
    #[serde(rename = "type")]
    pub msg_type: &'static str,
    pub node_id: String,
    pub ticket: String,
    pub generated_key: bool,
}

impl IrohReady {
    pub fn new(node_id: String, ticket: String, generated_key: bool) -> Self {
        Self {
            msg_type: "iroh_ready",
            node_id,
            ticket,
            generated_key,
        }
    }
}

/// Shell protocol messages (over Iroh QUIC stream)
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ShellMessage {
    /// Raw data from client stdin or to client stdout
    #[serde(rename = "data")]
    Data { payload: Vec<u8> },

    /// Window resize request from client
    #[serde(rename = "resize")]
    Resize { rows: u16, cols: u16 },

    /// Shell exited
    #[serde(rename = "exit")]
    Exit { code: i32 },
}
```

#### `src/vsock.rs` (extracted + modified)

```rust
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
    iroh_ready_rx: oneshot::Receiver<IrohReady>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut listener = VsockListener::bind(VMADDR_CID_ANY, port)?;
    info!("Vsock listener started on port {}", port);

    // Wait for first connection to send iroh_ready
    // (host connects immediately after boot)
    let mut iroh_ready = Some(iroh_ready_rx);

    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                info!("Vsock connection from {:?}", addr);

                // If we have iroh_ready info pending, try to receive it
                let ready_info = if let Some(rx) = iroh_ready.take() {
                    // Non-blocking check - if not ready yet, put receiver back
                    match rx.try_recv() {
                        Ok(info) => Some(info),
                        Err(oneshot::error::TryRecvError::Empty) => {
                            // Not ready yet, put it back (can't, it's consumed)
                            // We'll just spawn without it - host will poll
                            None
                        }
                        Err(oneshot::error::TryRecvError::Closed) => None,
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
        // Read length prefix
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
```

#### `src/iroh.rs` (new)

```rust
//! Iroh endpoint for NAT-traversing shell access.

use crate::protocol::{IrohReady, ShellMessage};
use crate::pty::PtySession;
use futures_lite::StreamExt;
use iroh_base::ticket::NodeTicket;
use iroh_net::endpoint::{Endpoint, Connection};
use iroh_net::key::SecretKey;
use std::path::Path;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::oneshot;
use tracing::{error, info, warn};

/// ALPN protocol identifier for Mjolnir shell
const SHELL_ALPN: &[u8] = b"mjolnir-shell/1";

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

    info!("Iroh endpoint bound, waiting for relay...");

    // Wait for home relay to be available (ensures we can be reached)
    let relay_url = endpoint.watch_home_relay().next().await;
    info!("Connected to relay: {:?}", relay_url);

    // Generate ticket for this node
    let node_addr = endpoint.node_addr().await?;
    let ticket = NodeTicket::new(node_addr)?;
    let ticket_str = ticket.to_string();

    info!("Shell ticket: {}", ticket_str);

    // Send ready notification to vsock task
    let ready = IrohReady::new(node_id.to_string(), ticket_str, generated);
    let _ = ready_tx.send(ready);

    // Accept incoming connections
    info!("Accepting shell connections...");
    while let Some(incoming) = endpoint.accept().await {
        let connecting = match incoming.accept() {
            Ok(c) => c,
            Err(e) => {
                warn!("Failed to accept incoming: {}", e);
                continue;
            }
        };

        tokio::spawn(async move {
            match connecting.await {
                Ok(conn) => {
                    info!("Shell connection from {}", conn.remote_node_id());
                    if let Err(e) = handle_shell_connection(conn).await {
                        error!("Shell session error: {}", e);
                    }
                }
                Err(e) => warn!("Connection failed: {}", e),
            }
        });
    }

    Ok(())
}

fn load_or_generate_key(
    path: &Path,
) -> Result<(SecretKey, bool), Box<dyn std::error::Error + Send + Sync>> {
    if path.exists() {
        let bytes = std::fs::read(path)?;
        let key = SecretKey::try_from_bytes(&bytes.try_into().map_err(|_| "invalid key length")?)?;
        Ok((key, false))
    } else {
        let key = SecretKey::generate();
        // Try to save (might fail if /etc/mjolnir doesn't exist, that's ok)
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(path, key.to_bytes());
        Ok((key, true))
    }
}

async fn handle_shell_connection(
    conn: Connection,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Accept bidirectional stream
    let (mut send, mut recv) = conn.accept_bi().await?;

    info!("Shell stream opened, spawning PTY");

    // Spawn PTY with zsh
    let mut pty = PtySession::spawn("/bin/zsh", 80, 24)?;

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
                                pty.write_all(&payload).await?;
                            }
                            Ok(ShellMessage::Resize { rows, cols }) => {
                                pty.resize(rows, cols)?;
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
                        send.write_all(&json).await?;
                    }
                    Ok(_) => {
                        // PTY closed (shell exited)
                        let code = pty.wait_exit_code().await.unwrap_or(-1);
                        info!("Shell exited with code {}", code);
                        let msg = ShellMessage::Exit { code };
                        let json = serde_json::to_vec(&msg)?;
                        let _ = send.write_all(&json).await;
                        break;
                    }
                    Err(e) => {
                        error!("PTY read error: {}", e);
                        break;
                    }
                }
            }

            // PTY process exited
            _ = pty.wait() => {
                let code = pty.exit_code().unwrap_or(-1);
                info!("PTY process exited with code {}", code);
                let msg = ShellMessage::Exit { code };
                let json = serde_json::to_vec(&msg)?;
                let _ = send.write_all(&json).await;
                break;
            }
        }
    }

    Ok(())
}
```

#### `src/pty.rs` (new)

```rust
//! PTY allocation and management using nix.

use nix::pty::{openpty, OpenptyResult, Winsize};
use nix::sys::signal::{kill, Signal};
use nix::sys::termios::{cfmakeraw, tcgetattr, tcsetattr, SetArg};
use nix::sys::wait::{waitpid, WaitPidFlag, WaitStatus};
use nix::unistd::{close, dup2, execvp, fork, setsid, ForkResult, Pid};
use std::ffi::CString;
use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tracing::info;

pub struct PtySession {
    master: File,
    child_pid: Pid,
    exit_code: Option<i32>,
}

impl PtySession {
    /// Spawn a new PTY session running the given command.
    pub fn spawn(
        cmd: &str,
        cols: u16,
        rows: u16,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let winsize = Winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };

        // Open PTY pair
        let OpenptyResult { master, slave } = openpty(&winsize, None)?;

        // Fork
        match unsafe { fork()? } {
            ForkResult::Parent { child } => {
                // Close slave in parent
                close(slave)?;

                // Make master non-blocking for async
                let master_file = unsafe { File::from_raw_fd(master) };

                Ok(Self {
                    master: master_file,
                    child_pid: child,
                    exit_code: None,
                })
            }
            ForkResult::Child => {
                // Close master in child
                close(master).ok();

                // Create new session
                setsid().ok();

                // Set controlling terminal
                unsafe {
                    libc::ioctl(slave, libc::TIOCSCTTY, 0);
                }

                // Dup slave to stdin/stdout/stderr
                dup2(slave, 0).ok();
                dup2(slave, 1).ok();
                dup2(slave, 2).ok();

                if slave > 2 {
                    close(slave).ok();
                }

                // Make raw (disable echo, line buffering)
                if let Ok(mut termios) = tcgetattr(0) {
                    cfmakeraw(&mut termios);
                    tcsetattr(0, SetArg::TCSANOW, &termios).ok();
                }

                // Exec shell
                let cmd_cstr = CString::new(cmd).unwrap();
                let args = [cmd_cstr.clone()];
                execvp(&cmd_cstr, &args).ok();

                // If exec fails, exit
                std::process::exit(127);
            }
        }
    }

    /// Write data to PTY stdin.
    pub async fn write_all(&mut self, data: &[u8]) -> std::io::Result<()> {
        self.master.write_all(data).await
    }

    /// Read data from PTY stdout.
    pub async fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.master.read(buf).await
    }

    /// Resize the PTY window.
    pub fn resize(&self, rows: u16, cols: u16) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let winsize = Winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        unsafe {
            if libc::ioctl(self.master.as_raw_fd(), libc::TIOCSWINSZ, &winsize) < 0 {
                return Err("ioctl TIOCSWINSZ failed".into());
            }
        }
        // Send SIGWINCH to child process group
        kill(self.child_pid, Signal::SIGWINCH).ok();
        Ok(())
    }

    /// Wait for child process to exit (non-blocking check).
    pub async fn wait(&mut self) -> Option<i32> {
        match waitpid(self.child_pid, Some(WaitPidFlag::WNOHANG)) {
            Ok(WaitStatus::Exited(_, code)) => {
                self.exit_code = Some(code);
                Some(code)
            }
            Ok(WaitStatus::Signaled(_, sig, _)) => {
                let code = 128 + sig as i32;
                self.exit_code = Some(code);
                Some(code)
            }
            _ => None,
        }
    }

    /// Get exit code if process has exited.
    pub fn exit_code(&self) -> Option<i32> {
        self.exit_code
    }

    /// Wait for exit code (blocking).
    pub async fn wait_exit_code(&mut self) -> Option<i32> {
        loop {
            if let Some(code) = self.wait().await {
                return Some(code);
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    }
}

impl Drop for PtySession {
    fn drop(&mut self) {
        // Kill child process if still running
        kill(self.child_pid, Signal::SIGTERM).ok();
    }
}
```

---

### 3. `lib/mjolnir/vsock/protocol.ex` (MODIFY)

Add iroh_ready message handling:

```elixir
@moduledoc """
Wire protocol for host↔guest communication over vsock.

Message format:
- 4 bytes: message length (big-endian uint32)
- N bytes: JSON-encoded message body

Message types (host → guest):
- exec: {type: "exec", id: "uuid", command: "string"}
- ping: {type: "ping", id: "uuid"}
- configure_network: {type: "configure_network", id: "uuid", ip: "string"}

Message types (guest → host):
- exec_response: {type: "exec_response", id: "uuid", exit_code: int, ...}
- pong: {type: "pong", id: "uuid"}
- iroh_ready: {type: "iroh_ready", node_id: "string", ticket: "string", generated_key: bool}
"""

# ... existing code ...

@doc """
Parse an iroh_ready message from the guest.
Returns {:ok, %{node_id: string, ticket: string, generated_key: bool}} or {:error, reason}
"""
def parse_iroh_ready(%{"type" => "iroh_ready", "node_id" => node_id, "ticket" => ticket} = msg) do
  {:ok, %{
    node_id: node_id,
    ticket: ticket,
    generated_key: Map.get(msg, "generated_key", true)
  }}
end

def parse_iroh_ready(_), do: {:error, :invalid_iroh_ready}
```

---

### 4. `lib/mjolnir/vm.ex` (MODIFY)

Add shell-related state and API:

```elixir
defstruct [
  :id,
  :config,
  :firecracker_pid,
  :firecracker_port,
  :socket_path,
  :vsock_path,
  :serial_path,
  :rootfs_path,
  :net_config,
  :state,
  :boot_time,
  # Phase 2: Iroh shell
  :iroh_node_id,
  :iroh_ticket,
  :shell_ready
]

# ... in do_boot, after configure_guest_network ...

:ok <- configure_guest_network(vsock_path, net_config.guest_ip),
iroh_info <- await_iroh_ready(vsock_path, 30_000) do
  {:ok,
   %{
     state
     | socket_path: socket_path,
       # ... existing fields ...
       iroh_node_id: iroh_info[:node_id],
       iroh_ticket: iroh_info[:ticket],
       shell_ready: iroh_info != nil
   }}
end

# New private function
defp await_iroh_ready(vsock_path, timeout) do
  # Connect to vsock and wait for iroh_ready message
  # This is sent proactively by the guest agent after Iroh connects to relay
  start_time = System.monotonic_time(:millisecond)
  do_await_iroh_ready(vsock_path, timeout, start_time)
end

defp do_await_iroh_ready(vsock_path, timeout, start_time) do
  elapsed = System.monotonic_time(:millisecond) - start_time

  if elapsed > timeout do
    Logger.warning("Timeout waiting for iroh_ready, shell access unavailable")
    nil
  else
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect({:local, vsock_path}, 0, opts, 5000),
         :ok <- :gen_tcp.send(sock, "CONNECT 5000\n"),
         {:ok, response} <- :gen_tcp.recv(sock, 0, 2000),
         true <- String.starts_with?(response, "OK"),
         {:ok, <<length::big-32>>} <- :gen_tcp.recv(sock, 4, timeout - elapsed),
         {:ok, body} <- :gen_tcp.recv(sock, length, 5000) do
      :gen_tcp.close(sock)

      case Jason.decode(body) do
        {:ok, %{"type" => "iroh_ready"} = msg} ->
          {:ok, info} = Mjolnir.Vsock.Protocol.parse_iroh_ready(msg)
          Logger.info("VM shell ready: node_id=#{info.node_id}")
          info

        {:ok, _other} ->
          # Not iroh_ready, retry
          Process.sleep(500)
          do_await_iroh_ready(vsock_path, timeout, start_time)

        {:error, _} ->
          Process.sleep(500)
          do_await_iroh_ready(vsock_path, timeout, start_time)
      end
    else
      _ ->
        Process.sleep(500)
        do_await_iroh_ready(vsock_path, timeout, start_time)
    end
  end
end
```

Add new public API:

```elixir
@doc """
Get the Iroh connection ticket for a VM.

Returns the ticket string that can be used to connect to the VM's shell
from anywhere with NAT traversal.

## Examples

    {:ok, ticket} = Mjolnir.VM.get_ticket(vm.id)
    # ticket can be used with `mjolnir connect <ticket>`
"""
@spec get_ticket(vm_id()) :: {:ok, String.t()} | {:error, :not_ready | :not_found}
def get_ticket(vm_id) do
  case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
    [{pid, _}] ->
      state = GenServer.call(pid, :get_state)
      if state.iroh_ticket do
        {:ok, state.iroh_ticket}
      else
        {:error, :not_ready}
      end

    [] ->
      {:error, :not_found}
  end
end

@doc """
Get the Iroh node ID for a VM.
"""
@spec node_id(vm_id()) :: {:ok, String.t()} | {:error, :not_ready | :not_found}
def node_id(vm_id) do
  case Registry.lookup(Mjolnir.VMRegistry, vm_id) do
    [{pid, _}] ->
      state = GenServer.call(pid, :get_state)
      if state.iroh_node_id do
        {:ok, state.iroh_node_id}
      else
        {:error, :not_ready}
      end

    [] ->
      {:error, :not_found}
  end
end

@doc """
Wait for shell to be ready, with timeout.

Returns {:ok, ticket} when ready, or {:error, :timeout}.
"""
@spec await_shell(vm_id(), timeout()) :: {:ok, String.t()} | {:error, :timeout | :not_found}
def await_shell(vm_id, timeout \\ 30_000) do
  start_time = System.monotonic_time(:millisecond)
  do_await_shell(vm_id, timeout, start_time)
end

defp do_await_shell(vm_id, timeout, start_time) do
  elapsed = System.monotonic_time(:millisecond) - start_time

  if elapsed > timeout do
    {:error, :timeout}
  else
    case get_ticket(vm_id) do
      {:ok, ticket} -> {:ok, ticket}
      {:error, :not_ready} ->
        Process.sleep(500)
        do_await_shell(vm_id, timeout, start_time)
      {:error, :not_found} -> {:error, :not_found}
    end
  end
end
```

---

### 5. `scripts/build-rootfs.sh` (MODIFY)

Ensure zsh is installed and `/etc/mjolnir` directory exists:

```bash
# In the package install section, add zsh:
apt-get install -y zsh

# After installing packages, before final cleanup:

# Create mjolnir config directory (for optional pre-generated Iroh keys)
mkdir -p "$ROOTFS/etc/mjolnir"
chmod 700 "$ROOTFS/etc/mjolnir"
```

---

## Testing Plan

### Unit Tests: `test/mjolnir/vm_iroh_test.exs`

```elixir
defmodule Mjolnir.VMIrohTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  describe "Iroh shell readiness" do
    test "VM reports shell ready after boot" do
      {:ok, vm} = Mjolnir.VM.spawn()

      assert vm.shell_ready == true
      assert vm.iroh_node_id != nil
      assert vm.iroh_ticket != nil
      assert String.length(vm.iroh_ticket) > 50  # tickets are long

      Mjolnir.VM.stop(vm.id)
    end

    test "get_ticket returns ticket for running VM" do
      {:ok, vm} = Mjolnir.VM.spawn()

      {:ok, ticket} = Mjolnir.VM.get_ticket(vm.id)
      assert ticket == vm.iroh_ticket

      Mjolnir.VM.stop(vm.id)
    end

    test "await_shell returns immediately if already ready" do
      {:ok, vm} = Mjolnir.VM.spawn()

      {time, {:ok, ticket}} = :timer.tc(fn ->
        Mjolnir.VM.await_shell(vm.id, 5000)
      end)

      assert ticket == vm.iroh_ticket
      assert time < 100_000  # < 100ms

      Mjolnir.VM.stop(vm.id)
    end

    test "node_id is valid iroh format" do
      {:ok, vm} = Mjolnir.VM.spawn()

      {:ok, node_id} = Mjolnir.VM.node_id(vm.id)
      # Iroh node IDs are 52 chars (base32 encoded public key)
      assert String.length(node_id) == 52

      Mjolnir.VM.stop(vm.id)
    end
  end
end
```

### Integration Tests: Shell Connectivity

These require a separate client binary (Phase 3), but can be tested manually:

```elixir
# Manual test in IEx:
{:ok, vm} = Mjolnir.VM.spawn()
{:ok, ticket} = Mjolnir.VM.get_ticket(vm.id)
IO.puts("Connect with: mjolnir connect #{ticket}")
# In another terminal: cargo run --bin mjolnir-client connect <ticket>
```

### Binary Size Measurement

Add to CI or run manually:

```bash
#!/bin/bash
# scripts/measure-agent-size.sh

cd native/mjolnir_guest_agent

# Build without iroh (baseline - use git stash or branch)
echo "Building baseline (no iroh)..."
cargo build --release 2>/dev/null
BASELINE=$(stat -c%s target/release/mjolnir-agent)
echo "Baseline: $BASELINE bytes ($(numfmt --to=iec $BASELINE))"

# Build with iroh
echo "Building with iroh..."
cargo build --release
WITH_IROH=$(stat -c%s target/release/mjolnir-agent)
echo "With iroh: $WITH_IROH bytes ($(numfmt --to=iec $WITH_IROH))"

# Delta
DELTA=$((WITH_IROH - BASELINE))
echo "Delta: +$DELTA bytes (+$(numfmt --to=iec $DELTA))"
```

---

## Debugging Guide

### Quick Checks

1. **Iroh endpoint started?**
   ```elixir
   Mjolnir.VM.exec(vm.id, "ps aux | grep mjolnir")
   # Should show mjolnir-agent process
   ```

2. **Network working?** (prerequisite for Iroh relay)
   ```elixir
   Mjolnir.VM.exec(vm.id, "curl -s https://example.com | head -1")
   ```

3. **Shell ready?**
   ```elixir
   vm = Mjolnir.VM.list() |> hd()
   IO.inspect(vm.shell_ready)
   IO.inspect(vm.iroh_ticket)
   ```

4. **Guest agent logs?**
   ```elixir
   Mjolnir.VM.exec(vm.id, "journalctl -u mjolnir-agent -n 50")
   ```

### Common Issues

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `shell_ready: false` | Network not configured | Check Phase 1 networking |
| Ticket is nil | Relay connection failed | Check guest can reach internet |
| Connection hangs | Firewall blocking UDP | Check iptables FORWARD rules |
| PTY not working | Missing /bin/zsh | Check rootfs has zsh installed |
| Resize not working | SIGWINCH not sent | Check PTY code sends signal |

### Packet Capture (Iroh traffic)

```bash
# On host, watch QUIC traffic (port 443 for relay, random for direct)
tcpdump -i any -n 'udp and (port 443 or portrange 49152-65535)'

# On guest, check Iroh is connecting
Mjolnir.VM.exec(vm.id, "ss -unp | grep mjolnir")
```

---

## Success Criteria

- [ ] `iroh_ready` message received within 10s of boot
- [ ] Ticket is valid and can be parsed by iroh-base
- [ ] Shell connection from same machine works (loopback test)
- [ ] Shell connection from different network works (NAT traversal)
- [ ] Interactive apps (vim, htop) render correctly
- [ ] Window resize propagates to PTY
- [ ] Shell exit code returned to client
- [ ] Multiple concurrent sessions work
- [ ] Binary size increase documented (target: < 15MB delta)

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| PTY handling complexity | High | Use well-tested nix crate; copy patterns from portable-pty |
| iroh-net binary bloat | Medium | Measure early; acceptable if < 20MB |
| Relay latency | Low | n0's relays are global; hole-punching reduces latency |
| Key management confusion | Low | Default to generate; document pre-gen option |

---

## Implementation Order

```
2.1 Measure baseline binary size
    │
2.2 Add iroh-net to Cargo.toml, verify it compiles
    │
2.3 Implement keypair load/generate
    │
2.4 Implement PTY module (can test standalone)
    │
2.5 Implement Iroh endpoint + shell handler
    │
2.6 Add iroh_ready message to vsock protocol
    │
2.7 Update VM.ex to await iroh_ready
    │
2.8 Integration tests
    │
2.9 Documentation updates
```

---

*Phase 2 detail spec created with SDD methodology*

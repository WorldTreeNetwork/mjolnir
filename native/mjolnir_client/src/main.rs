//! Mjolnir CLI — spawn VMs and connect to shells over Iroh QUIC.
//!
//! Usage:
//!   mjolnir login --api https://mjolnir.example.com   # authenticate + save API
//!   mjolnir spawn                                      # spawn a VM, print ticket
//!   mjolnir list                                       # list your VMs
//!   mjolnir shell <ticket>                             # connect to a VM shell
//!   mjolnir config                                     # show config
//!   mjolnir config set api https://...                 # change API URL

mod auth;
mod config;

use clap::{Parser, Subcommand};
use iroh::endpoint::Endpoint;
use iroh_base::{EndpointAddr, PublicKey, RelayUrl};
use mjolnir_protocol::{read_frame, write_frame, Frame, PROTOCOL_VERSION, SHELL_ALPN, TCP_FWD_ALPN};
#[cfg(unix)]
use nix::sys::termios;
use serde::Deserialize;
use std::io::Write;
use std::net::SocketAddr;
use tokio::io::AsyncReadExt;

#[derive(Parser)]
#[command(name = "mjolnir", about = "Mjolnir — VM shells over Iroh")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Connect to a VM shell using a ticket
    Shell {
        /// Ticket (base58 node ID), hex node ID, or full iroh JSON
        ticket: String,
        /// Relay URL hint (only needed for self-hosted relays)
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s) for faster hole-punching (ip:port, repeatable)
        #[arg(long)]
        ip: Vec<String>,
    },
    /// TCP proxy over Iroh QUIC (for use as SSH ProxyCommand)
    Proxy {
        /// Ticket (base58 node ID), hex node ID, or full iroh JSON
        ticket: String,
        /// Target port on the guest (default: 22 for SSH)
        #[arg(long, default_value = "22")]
        port: u16,
        /// Relay URL hint
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s) (ip:port, repeatable)
        #[arg(long)]
        ip: Vec<String>,
    },
    /// SSH into a VM via Iroh QUIC tunnel
    Ssh {
        /// Ticket (base58 node ID), hex node ID, or full iroh JSON
        ticket: String,
        /// SSH user (default: root)
        #[arg(long, default_value = "root")]
        user: String,
        /// Relay URL hint
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s) (ip:port, repeatable)
        #[arg(long)]
        ip: Vec<String>,
        /// Extra args passed to ssh
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        ssh_args: Vec<String>,
    },
    /// Spawn a new VM via the API
    Spawn {
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Connect to the shell immediately after spawn
        #[arg(long)]
        connect: bool,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
        /// Memory allocation in MB (default: 512)
        #[arg(long)]
        memory: Option<u32>,
        /// Spawn from a snapshot instead of base image
        #[arg(long)]
        snapshot: Option<String>,
    },
    /// List VMs via the API
    List {
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Get detailed info about a VM
    Info {
        /// VM ID or ticket
        id: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Stop and destroy a VM
    Kill {
        /// VM ID or ticket
        id: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Authenticate with the Mjolnir identity provider
    Login {
        /// OIDC issuer URL (default: identikey)
        #[arg(long)]
        issuer: Option<String>,
        /// Mjolnir API base URL (saved to config)
        #[arg(long)]
        api: Option<String>,
    },
    /// Remove stored credentials
    Logout,
    /// Show current auth and config status
    Status,
    /// View or update CLI configuration
    Config {
        #[command(subcommand)]
        action: Option<ConfigAction>,
    },
    /// Convert between ticket formats
    Ticket {
        #[command(subcommand)]
        action: TicketAction,
    },
    /// List available snapshots
    Snapshots {
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Create a snapshot of a running VM
    Snapshot {
        /// VM ID or ticket
        id: String,
        /// Snapshot name
        name: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
        /// Compact the snapshot (reclaim freed blocks)
        #[arg(long)]
        compact: bool,
    },
}

#[derive(Subcommand)]
enum ConfigAction {
    /// Set a config value
    Set {
        /// Config key (e.g. "api")
        key: String,
        /// Value to set
        value: String,
    },
}

#[derive(Subcommand)]
enum TicketAction {
    /// Decode iroh JSON to compact ticket (base58)
    Decode {
        /// Iroh JSON EndpointAddr string
        json: String,
    },
    /// Encode compact ticket to iroh JSON
    Encode {
        /// Base58 node ID ticket
        ticket: String,
        /// Relay URL
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s) (ip:port, repeatable)
        #[arg(long)]
        ip: Vec<String>,
    },
}

// --- API response types ---

#[derive(Deserialize)]
#[allow(dead_code)]
struct SpawnResponse {
    id: String,
    state: String,
    ticket: Option<String>,
    ticket_z32: Option<String>,
    shell_ready: Option<bool>,
}

#[derive(Deserialize)]
struct AwaitShellResponse {
    ticket: String,
}

#[derive(Deserialize)]
struct VmSummary {
    id: String,
    state: String,
    ticket: Option<String>,
    ticket_z32: Option<String>,
    guest_ip: Option<String>,
    shell_ready: Option<bool>,
}

#[derive(Deserialize)]
struct ListResponse {
    vms: Vec<VmSummary>,
}

#[derive(Deserialize)]
struct VmConfig {
    vcpu_count: u32,
    mem_size_mib: u32,
    base_image: String,
    snapshot: Option<String>,
    rootfs_size_mb: Option<u32>,
}

#[derive(Deserialize)]
struct VmInfo {
    id: String,
    state: String,
    ticket: Option<String>,
    ticket_z32: Option<String>,
    guest_ip: Option<String>,
    shell_ready: Option<bool>,
    config: Option<VmConfig>,
    boot_time: Option<i64>,
}

#[derive(Deserialize)]
struct SnapshotMetadata {
    name: String,
    source_vm_id: String,
    created_at: String,
    size_bytes: u64,
}

#[derive(Deserialize)]
struct SnapshotsResponse {
    snapshots: Vec<SnapshotMetadata>,
}

#[derive(Deserialize)]
struct SnapshotCreateResponse {
    name: String,
    source_vm_id: String,
    created_at: String,
    size_bytes: u64,
}

// --- Helpers ---

async fn api_client(token: &Option<String>) -> reqwest::Client {
    let effective = auth::resolve_token(token).await;
    let mut headers = reqwest::header::HeaderMap::new();
    if let Some(t) = effective {
        if let Ok(val) = reqwest::header::HeaderValue::from_str(&format!("Bearer {}", t)) {
            headers.insert(reqwest::header::AUTHORIZATION, val);
        }
    }
    reqwest::Client::builder()
        .default_headers(headers)
        .build()
        .expect("failed to build HTTP client")
}

#[cfg(unix)]
fn get_terminal_size() -> (u16, u16) {
    unsafe {
        let mut ws: libc::winsize = std::mem::zeroed();
        if libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) == 0
            && ws.ws_row > 0
            && ws.ws_col > 0
        {
            (ws.ws_row, ws.ws_col)
        } else {
            (24, 80)
        }
    }
}

#[cfg(windows)]
fn get_terminal_size() -> (u16, u16) {
    crossterm::terminal::size()
        .map(|(cols, rows)| (rows, cols))
        .unwrap_or((24, 80))
}

// --- Terminal raw mode (Unix) ---

#[cfg(unix)]
/// Set terminal to raw mode, return the original termios for restoration.
fn set_raw_mode() -> std::io::Result<termios::Termios> {
    let stdin = std::io::stdin();
    let original = termios::tcgetattr(&stdin)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, format!("tcgetattr: {}", e)))?;
    let mut raw = original.clone();
    termios::cfmakeraw(&mut raw);
    termios::tcsetattr(&stdin, termios::SetArg::TCSANOW, &raw)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, format!("tcsetattr: {}", e)))?;
    Ok(original)
}

#[cfg(unix)]
fn restore_terminal(original: &termios::Termios) {
    let stdin = std::io::stdin();
    let _ = termios::tcsetattr(&stdin, termios::SetArg::TCSANOW, original);
}

// --- Terminal raw mode (Windows) ---

#[cfg(windows)]
fn set_raw_mode() -> std::io::Result<u32> {
    use crossterm::terminal;
    terminal::enable_raw_mode()?;
    // Return 0 as a dummy "original mode" — crossterm tracks state internally
    Ok(0)
}

#[cfg(windows)]
fn restore_terminal(_original: &u32) {
    let _ = crossterm::terminal::disable_raw_mode();
}

/// Parse a ticket string into an EndpointAddr.
///
/// Accepts three formats:
/// - Full iroh JSON (starts with `{`)
/// - 64-char hex string (raw node ID)
/// - Base58-encoded node ID (the default compact format)
///
/// Optional relay URL and direct IP hints are appended to the resulting address.
fn resolve_addr(
    ticket: &str,
    relay: Option<String>,
    ips: &[String],
) -> Result<EndpointAddr, Box<dyn std::error::Error>> {
    let ticket = ticket.trim();

    // Full iroh JSON
    if ticket.starts_with('{') {
        return Ok(serde_json::from_str::<EndpointAddr>(ticket)?);
    }

    // Decode node ID bytes from hex or base58
    let bytes: Vec<u8> = if ticket.len() == 64 && ticket.chars().all(|c| c.is_ascii_hexdigit()) {
        hex::decode(ticket)?
    } else {
        bs58::decode(ticket)
            .into_vec()
            .map_err(|e| format!("Invalid ticket: not valid base58, hex, or iroh JSON ({e})"))?
    };

    let key_bytes: [u8; 32] = bytes
        .try_into()
        .map_err(|v: Vec<u8>| format!("Invalid key length: {} (expected 32)", v.len()))?;
    let pubkey = PublicKey::from_bytes(&key_bytes)?;

    let mut addr = EndpointAddr::new(pubkey);

    if let Some(relay_str) = relay {
        let relay_url: RelayUrl = relay_str
            .parse()
            .map_err(|e| format!("Invalid relay URL '{}': {}", relay_str, e))?;
        addr = addr.with_relay_url(relay_url);
    }

    for ip_str in ips {
        let sock: SocketAddr = ip_str
            .parse()
            .map_err(|e| format!("Invalid IP address '{}': {}", ip_str, e))?;
        addr = addr.with_ip_addr(sock);
    }

    Ok(addr)
}

/// Format an EndpointAddr for human display.
fn format_addr_info(addr: &EndpointAddr) -> String {
    let mut lines = Vec::new();
    let id_bytes = addr.id.as_bytes();
    lines.push(format!("Ticket: {}", bs58::encode(id_bytes).into_string()));
    lines.push(format!("   z32: {}", z32::encode(id_bytes)));
    lines.push(format!("   Hex: {}", hex::encode(id_bytes)));
    for relay in addr.relay_urls() {
        lines.push(format!(" Relay: {}", relay));
    }
    for ip in addr.ip_addrs() {
        lines.push(format!("    IP: {}", ip));
    }
    lines.join("\n")
}

// --- Shell connection ---

async fn connect_to_vm(addr: EndpointAddr) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("Connecting to VM...");

    let endpoint = Endpoint::builder().bind().await?;
    endpoint.online().await;

    let conn = endpoint.connect(addr, SHELL_ALPN).await?;
    eprintln!("Connected. Opening shell...");

    let (mut send, mut recv) = conn.open_bi().await?;

    let (rows, cols) = get_terminal_size();
    write_frame(
        &mut send,
        &Frame::Hello {
            rows,
            cols,
            version: PROTOCOL_VERSION,
        },
    )
    .await?;

    let original_termios = set_raw_mode()?;
    let orig_for_guard = original_termios.clone();
    let _guard = scopeguard::guard((), move |_| {
        restore_terminal(&orig_for_guard);
    });

    let result = run_shell_loop(&mut send, &mut recv).await;

    restore_terminal(&original_termios);

    match result {
        Ok(exit_code) => {
            if exit_code != 0 {
                eprintln!("Shell exited with code {}", exit_code);
            }
            std::process::exit(exit_code);
        }
        Err(e) => {
            eprintln!("Connection error: {}", e);
            std::process::exit(1);
        }
    }
}

#[cfg(unix)]
async fn run_shell_loop(
    send: &mut iroh::endpoint::SendStream,
    recv: &mut iroh::endpoint::RecvStream,
) -> Result<i32, Box<dyn std::error::Error>> {
    let mut stdin = tokio::io::stdin();
    let mut stdin_buf = vec![0u8; 4096];
    let mut sigwinch =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())?;

    loop {
        tokio::select! {
            result = read_frame(recv) => {
                match result {
                    Ok(Some(Frame::Data(data))) => {
                        let mut stdout = std::io::stdout().lock();
                        stdout.write_all(&data)?;
                        stdout.flush()?;
                    }
                    Ok(Some(Frame::Exit { code })) => {
                        return Ok(code);
                    }
                    Ok(Some(frame)) => {
                        eprintln!("\r\nUnexpected frame: {:?}\r\n", frame);
                    }
                    Ok(None) => {
                        return Ok(0);
                    }
                    Err(e) => {
                        return Err(e.into());
                    }
                }
            }
            result = stdin.read(&mut stdin_buf) => {
                match result {
                    Ok(0) => {
                        let _ = write_frame(send, &Frame::Exit { code: 0 }).await;
                        return Ok(0);
                    }
                    Ok(n) => {
                        write_frame(send, &Frame::Data(stdin_buf[..n].to_vec())).await?;
                    }
                    Err(e) => {
                        return Err(e.into());
                    }
                }
            }
            _ = sigwinch.recv() => {
                let (rows, cols) = get_terminal_size();
                let _ = write_frame(send, &Frame::Resize { rows, cols }).await;
            }
        }
    }
}

#[cfg(windows)]
async fn run_shell_loop(
    send: &mut iroh::endpoint::SendStream,
    recv: &mut iroh::endpoint::RecvStream,
) -> Result<i32, Box<dyn std::error::Error>> {
    let mut stdin = tokio::io::stdin();
    let mut stdin_buf = vec![0u8; 4096];

    loop {
        tokio::select! {
            result = read_frame(recv) => {
                match result {
                    Ok(Some(Frame::Data(data))) => {
                        let mut stdout = std::io::stdout().lock();
                        stdout.write_all(&data)?;
                        stdout.flush()?;
                    }
                    Ok(Some(Frame::Exit { code })) => {
                        return Ok(code);
                    }
                    Ok(Some(frame)) => {
                        eprintln!("\r\nUnexpected frame: {:?}\r\n", frame);
                    }
                    Ok(None) => {
                        return Ok(0);
                    }
                    Err(e) => {
                        return Err(e.into());
                    }
                }
            }
            result = stdin.read(&mut stdin_buf) => {
                match result {
                    Ok(0) => {
                        let _ = write_frame(send, &Frame::Exit { code: 0 }).await;
                        return Ok(0);
                    }
                    Ok(n) => {
                        write_frame(send, &Frame::Data(stdin_buf[..n].to_vec())).await?;
                    }
                    Err(e) => {
                        return Err(e.into());
                    }
                }
            }
        }
    }
}

// --- API commands ---

async fn cmd_spawn(
    api_flag: &Option<String>,
    token: &Option<String>,
    connect: bool,
    memory_mb: &Option<u32>,
    snapshot: &Option<String>,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = api_client(token).await;
    let api = config::resolve_api(api_flag);
    let base = api.trim_end_matches('/');

    // Include SSH public key if available
    let mut body = serde_json::json!({});
    if let Some(key_path) = config::resolve_ssh_key_path() {
        if let Some(ssh_key) = config::read_ssh_public_key() {
            eprintln!("Using SSH key: {}", key_path);
            body["ssh_public_key"] = serde_json::Value::String(ssh_key);
        }
    }

    // Include memory override if specified
    if let Some(memory) = memory_mb {
        body["memory_mb"] = serde_json::Value::Number((*memory).into());
    }

    // Include snapshot if specified
    if let Some(snap) = snapshot {
        eprintln!("Spawning from snapshot: {}", snap);
        body["snapshot"] = serde_json::Value::String(snap.clone());
    }

    eprintln!("Spawning VM...");
    let resp: SpawnResponse = client
        .post(format!("{}/api/vms", base))
        .json(&body)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    // If shell not ready yet, await it
    let ticket = if resp.shell_ready == Some(true) {
        resp.ticket.clone()
    } else {
        eprintln!("Waiting for shell...");
        let await_resp: AwaitShellResponse = client
            .post(format!("{}/api/vms/{}/await-shell", base, resp.id))
            .json(&serde_json::json!({"timeout": 30000}))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        Some(await_resp.ticket)
    };

    if let Some(ref t) = ticket {
        println!("{}", t);
    } else {
        eprintln!("VM {} (no ticket yet)", resp.id);
    }

    if connect {
        let ticket_str = ticket.ok_or("No ticket available")?;
        let addr = resolve_addr(&ticket_str, None, &[])?;
        connect_to_vm(addr).await?;
    }

    Ok(())
}

async fn cmd_list(
    api_flag: &Option<String>,
    token: &Option<String>,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = api_client(token).await;
    let api = config::resolve_api(api_flag);
    let base = api.trim_end_matches('/');

    let resp: ListResponse = client
        .get(format!("{}/api/vms", base))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    if resp.vms.is_empty() {
        eprintln!("No VMs running.");
        return Ok(());
    }

    // Header
    println!(
        "{:<46} {:<54} {:<10} {:<16} {:<6} {}",
        "TICKET", "Z32", "STATE", "IP", "SHELL", "ID"
    );

    for vm in &resp.vms {
        // Compute z32 locally from base58 ticket if the server didn't provide it
        let z32_display = vm.ticket_z32.clone().or_else(|| {
            vm.ticket.as_deref().and_then(|t| {
                bs58::decode(t).into_vec().ok().and_then(|bytes| {
                    if bytes.len() == 32 { Some(z32::encode(&bytes)) } else { None }
                })
            })
        });
        println!(
            "{:<46} {:<54} {:<10} {:<16} {:<6} {}",
            vm.ticket.as_deref().unwrap_or("-"),
            z32_display.as_deref().unwrap_or("-"),
            vm.state,
            vm.guest_ip.as_deref().unwrap_or("-"),
            if vm.shell_ready == Some(true) {
                "ready"
            } else {
                "-"
            },
            vm.id,
        );
    }

    Ok(())
}

/// Resolve a VM identifier: if it looks like a UUID, use it directly.
/// Otherwise treat it as a ticket and look up the VM ID from the list.
async fn resolve_vm_id(
    client: &reqwest::Client,
    base: &str,
    id_or_ticket: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    // UUIDs are 36 chars with hyphens
    if id_or_ticket.len() == 36 && id_or_ticket.contains('-') {
        return Ok(id_or_ticket.to_string());
    }
    // Look up by ticket
    let resp: ListResponse = client
        .get(format!("{}/api/vms", base))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    resp.vms
        .iter()
        .find(|vm| vm.ticket.as_deref() == Some(id_or_ticket))
        .map(|vm| vm.id.clone())
        .ok_or_else(|| format!("No VM found with ticket {}", id_or_ticket).into())
}

async fn cmd_info(
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = api_client(token).await;
    let api = config::resolve_api(api_flag);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    let resp: VmInfo = client
        .get(format!("{}/api/vms/{}", base, &id))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    // Display VM info in a human-readable format
    println!("VM Information");
    println!("═══════════════════════════════════════════════════════");
    println!("ID:           {}", resp.id);
    println!("State:        {}", resp.state);
    println!("Shell Ready:  {}", if resp.shell_ready == Some(true) { "yes" } else { "no" });

    if let Some(ip) = resp.guest_ip {
        println!("Guest IP:     {}", ip);
    }

    if let Some(ref ticket) = resp.ticket {
        println!("\nConnection");
        println!("───────────────────────────────────────────────────────");
        println!("Ticket:       {}", ticket);
        if let Some(ref z32) = resp.ticket_z32 {
            println!("Z32:          {}", z32);
        }
    }

    if let Some(config) = resp.config {
        println!("\nResources");
        println!("───────────────────────────────────────────────────────");
        println!("vCPUs:        {}", config.vcpu_count);
        println!("Memory:       {} MiB", config.mem_size_mib);
        println!("Base Image:   {}", config.base_image);
        if let Some(snapshot) = config.snapshot {
            println!("Snapshot:     {}", snapshot);
        }
        if let Some(size) = config.rootfs_size_mb {
            println!("Rootfs Size:  {} MiB", size);
        }
    }

    if let Some(boot_time) = resp.boot_time {
        println!("\nTiming");
        println!("───────────────────────────────────────────────────────");
        println!("Boot Time:    {} (unix timestamp)", boot_time);
    }

    Ok(())
}

async fn cmd_snapshot(
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
    name: &str,
    compact: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = api_client(token).await;
    let api = config::resolve_api(api_flag);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    eprintln!("Creating snapshot '{}'{}...", name, if compact { " (compact)" } else { "" });

    let mut body = serde_json::json!({
        "name": name
    });
    if compact {
        body["compact"] = serde_json::Value::Bool(true);
    }

    let resp: SnapshotCreateResponse = client
        .post(format!("{}/api/vms/{}/snapshots", base, &id))
        .json(&body)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    let size_mb = resp.size_bytes / 1024 / 1024;
    eprintln!("✓ Snapshot '{}' created successfully", resp.name);
    eprintln!("  Size: {} MB", size_mb);
    eprintln!("  Source VM: {}", resp.source_vm_id);
    eprintln!("  Created: {}", resp.created_at);

    Ok(())
}

async fn cmd_snapshots(
    api_flag: &Option<String>,
    token: &Option<String>,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = api_client(token).await;
    let api = config::resolve_api(api_flag);
    let base = api.trim_end_matches('/');

    let resp: SnapshotsResponse = client
        .get(format!("{}/api/snapshots", base))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    if resp.snapshots.is_empty() {
        eprintln!("No snapshots found.");
        return Ok(());
    }

    // Header
    println!(
        "{:<30} {:<38} {:<28} {:>12}",
        "NAME", "SOURCE VM", "CREATED AT", "SIZE"
    );

    for snap in &resp.snapshots {
        let size_mb = snap.size_bytes / 1024 / 1024;
        println!(
            "{:<30} {:<38} {:<28} {:>9} MB",
            snap.name,
            snap.source_vm_id,
            snap.created_at,
            size_mb
        );
    }

    Ok(())
}

async fn cmd_kill(
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = api_client(token).await;
    let api = config::resolve_api(api_flag);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    client
        .delete(format!("{}/api/vms/{}", base, &id))
        .send()
        .await?
        .error_for_status()?;

    eprintln!("Killed {}", id);
    Ok(())
}

// --- Proxy / SSH ---

/// Shell-escape a string for use in commands.
/// Unix: single quotes with embedded quote escaping.
/// Windows: double quotes with embedded quote escaping.
#[cfg(unix)]
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

#[cfg(windows)]
fn shell_quote(s: &str) -> String {
    format!("\"{}\"", s.replace('"', "\\\""))
}


async fn cmd_proxy(
    ticket: &str,
    port: u16,
    relay: Option<String>,
    ips: &[String],
) -> Result<(), Box<dyn std::error::Error>> {
    let addr = resolve_addr(ticket, relay, ips)?;

    let endpoint = Endpoint::builder().bind().await?;
    endpoint.online().await;

    let conn = endpoint.connect(addr, TCP_FWD_ALPN).await?;
    let (mut send, mut recv) = conn.open_bi().await?;

    // Send target port as 2 bytes (u16 big-endian)
    send.write_all(&port.to_be_bytes()).await?;

    // Bidirectional copy with graceful half-close: stdin <-> QUIC
    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();

    let c2s = async {
        let r = tokio::io::copy(&mut stdin, &mut send).await;
        let _ = send.finish();
        r
    };
    let s2c = async {
        let r = tokio::io::copy(&mut recv, &mut stdout).await;
        r
    };

    let (c2s_result, s2c_result) = tokio::join!(c2s, s2c);
    if let Err(e) = c2s_result {
        eprintln!("stdin->quic error: {}", e);
    }
    if let Err(e) = s2c_result {
        eprintln!("quic->stdout error: {}", e);
    }

    Ok(())
}

fn cmd_ssh(
    ticket: &str,
    user: &str,
    relay: Option<String>,
    ips: &[String],
    ssh_args: &[String],
) -> Result<(), Box<dyn std::error::Error>> {
    let self_exe = std::env::current_exe()?;

    // Build the ProxyCommand with shell-safe quoting
    let mut proxy_cmd = format!(
        "{} proxy {} --port 22",
        shell_quote(&self_exe.to_string_lossy()),
        shell_quote(ticket),
    );
    if let Some(ref r) = relay {
        proxy_cmd.push_str(&format!(" --relay {}", shell_quote(r)));
    }
    for ip in ips {
        proxy_cmd.push_str(&format!(" --ip {}", shell_quote(ip)));
    }

    // Null device path differs per platform
    #[cfg(unix)]
    let null_known_hosts = "/dev/null";
    #[cfg(windows)]
    let null_known_hosts = "NUL";

    let mut args = vec![
        "-o".to_string(),
        format!("ProxyCommand={}", proxy_cmd),
        "-o".to_string(),
        "StrictHostKeyChecking=no".to_string(),
        "-o".to_string(),
        format!("UserKnownHostsFile={}", null_known_hosts),
        "-o".to_string(),
        "RequestTTY=yes".to_string(),
        "-l".to_string(),
        user.to_string(),
        "mjolnir".to_string(),
    ];
    args.extend_from_slice(ssh_args);

    // On Unix, replace this process with ssh (exec)
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let err = std::process::Command::new("ssh").args(&args).exec();
        return Err(format!("Failed to exec ssh: {}", err).into());
    }

    // On Windows, spawn ssh.exe and wait for it
    #[cfg(windows)]
    {
        let status = std::process::Command::new("ssh.exe")
            .args(&args)
            .status()
            .map_err(|e| format!("Failed to run ssh: {}", e))?;
        std::process::exit(status.code().unwrap_or(1));
    }
}

// --- Main ---

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Command::Shell { ticket, relay, ip } => match resolve_addr(&ticket, relay, &ip) {
            Ok(addr) => connect_to_vm(addr).await,
            Err(e) => {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
        },
        Command::Proxy {
            ticket,
            port,
            relay,
            ip,
        } => cmd_proxy(&ticket, port, relay, &ip).await,
        Command::Ssh {
            ticket,
            user,
            relay,
            ip,
            ssh_args,
        } => cmd_ssh(&ticket, &user, relay, &ip, &ssh_args),
        Command::Spawn {
            api,
            connect,
            token,
            memory,
            snapshot,
        } => cmd_spawn(&api, &token, connect, &memory, &snapshot).await,
        Command::List { api, token } => cmd_list(&api, &token).await,
        Command::Info { id, api, token } => cmd_info(&api, &token, &id).await,
        Command::Snapshots { api, token } => cmd_snapshots(&api, &token).await,
        Command::Snapshot {
            id,
            name,
            api,
            token,
            compact,
        } => cmd_snapshot(&api, &token, &id, &name, compact).await,
        Command::Kill { id, api, token } => cmd_kill(&api, &token, &id).await,
        Command::Login { issuer, api } => {
            if let Some(ref url) = api {
                if let Err(e) = config::set("api", url) {
                    eprintln!("Warning: failed to save API config: {}", e);
                }
            }
            auth::login(issuer).await
        }
        Command::Logout => auth::logout().map_err(|e| e),
        Command::Status => {
            config::show();
            auth::status()
        }
        Command::Config { action } => match action {
            Some(ConfigAction::Set { key, value }) => config::set(&key, &value),
            None => {
                config::show();
                Ok(())
            }
        },
        Command::Ticket { action } => match action {
            TicketAction::Decode { json } => match serde_json::from_str::<EndpointAddr>(&json) {
                Ok(addr) => {
                    println!("{}", format_addr_info(&addr));
                    Ok(())
                }
                Err(e) => {
                    eprintln!("Failed to parse iroh JSON: {}", e);
                    std::process::exit(1);
                }
            },
            TicketAction::Encode { ticket, relay, ip } => {
                match resolve_addr(&ticket, relay, &ip) {
                    Ok(addr) => {
                        println!("{}", serde_json::to_string(&addr).unwrap());
                        Ok(())
                    }
                    Err(e) => {
                        eprintln!("Error: {}", e);
                        std::process::exit(1);
                    }
                }
            }
        },
    };

    if let Err(e) = result {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

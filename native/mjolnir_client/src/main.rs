//! Mjolnir CLI — spawn VMs and connect to shells over Iroh QUIC.
//!
//! Usage:
//!   mjolnir login                            # authenticate via browser
//!   mjolnir shell <ticket>                   # connect to a VM shell
//!   mjolnir spawn --api http://host:4000     # spawn a VM, print ticket
//!   mjolnir list --api http://host:4000      # list your VMs
//!   mjolnir ticket decode '<iroh-json>'      # JSON → base58

mod auth;

use clap::{Parser, Subcommand};
use iroh::endpoint::Endpoint;
use iroh_base::{EndpointAddr, PublicKey, RelayUrl};
use mjolnir_protocol::{read_frame, write_frame, Frame, PROTOCOL_VERSION, SHELL_ALPN};
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
    /// Spawn a new VM via the API
    Spawn {
        /// Mjolnir API base URL
        #[arg(long, default_value = "http://localhost:4000")]
        api: String,
        /// Connect to the shell immediately after spawn
        #[arg(long)]
        connect: bool,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// List VMs via the API
    List {
        /// Mjolnir API base URL
        #[arg(long, default_value = "http://localhost:4000")]
        api: String,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Authenticate with the Mjolnir identity provider
    Login {
        /// OIDC issuer URL (default: identikey)
        #[arg(long)]
        issuer: Option<String>,
    },
    /// Remove stored credentials
    Logout,
    /// Show current auth status
    Status,
    /// Convert between ticket formats
    Ticket {
        #[command(subcommand)]
        action: TicketAction,
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
    guest_ip: Option<String>,
    shell_ready: Option<bool>,
}

#[derive(Deserialize)]
struct ListResponse {
    vms: Vec<VmSummary>,
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

fn restore_terminal(original: &termios::Termios) {
    let stdin = std::io::stdin();
    let _ = termios::tcsetattr(&stdin, termios::SetArg::TCSANOW, original);
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
    let orig_clone = original_termios.clone();
    let _guard = scopeguard::guard((), move |_| {
        restore_terminal(&orig_clone);
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

// --- API commands ---

async fn cmd_spawn(
    api: &str,
    token: &Option<String>,
    connect: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = api_client(token).await;
    let base = api.trim_end_matches('/');

    eprintln!("Spawning VM...");
    let resp: SpawnResponse = client
        .post(format!("{}/api/vms", base))
        .json(&serde_json::json!({}))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    eprintln!("VM {} ({})", resp.id, resp.state);

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
    }

    if connect {
        let ticket_str = ticket.ok_or("No ticket available")?;
        let addr = resolve_addr(&ticket_str, None, &[])?;
        connect_to_vm(addr).await?;
    }

    Ok(())
}

async fn cmd_list(
    api: &str,
    token: &Option<String>,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = api_client(token).await;
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
        "{:<38} {:<10} {:<16} {:<6} {}",
        "ID", "STATE", "IP", "SHELL", "TICKET"
    );

    for vm in &resp.vms {
        println!(
            "{:<38} {:<10} {:<16} {:<6} {}",
            vm.id,
            vm.state,
            vm.guest_ip.as_deref().unwrap_or("-"),
            if vm.shell_ready == Some(true) {
                "ready"
            } else {
                "-"
            },
            vm.ticket.as_deref().unwrap_or("-"),
        );
    }

    Ok(())
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
        Command::Spawn {
            api,
            connect,
            token,
        } => cmd_spawn(&api, &token, connect).await,
        Command::List { api, token } => cmd_list(&api, &token).await,
        Command::Login { issuer } => auth::login(issuer).await,
        Command::Logout => auth::logout().map_err(|e| e),
        Command::Status => auth::status().map_err(|e| e),
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

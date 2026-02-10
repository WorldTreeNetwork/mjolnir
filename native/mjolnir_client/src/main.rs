//! Mjolnir CLI client — connects to a VM shell over Iroh QUIC.
//!
//! Usage:
//!   mjolnir connect '<json-ticket>'
//!   mjolnir shell <vm-id> --api http://localhost:4000

use clap::{Parser, Subcommand};
use iroh::endpoint::Endpoint;
use iroh_base::EndpointAddr;
use mjolnir_protocol::{read_frame, write_frame, Frame, PROTOCOL_VERSION, SHELL_ALPN};
use nix::sys::termios;
use serde::Deserialize;
use std::io::Write;
use tokio::io::AsyncReadExt;

#[derive(Parser)]
#[command(name = "mjolnir", about = "Mjolnir VM shell client")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Connect directly to a VM using an Iroh ticket
    Connect {
        /// JSON-serialized EndpointAddr ticket
        ticket: String,
    },
    /// Connect to a VM via the Mjolnir API
    Shell {
        /// VM ID (UUID)
        vm_id: String,
        /// Mjolnir API base URL
        #[arg(long, default_value = "http://localhost:4000")]
        api: String,
    },
}

#[derive(Deserialize)]
struct TicketResponse {
    ticket: String,
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
    let original = termios::tcgetattr(&stdin).map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::Other, format!("tcgetattr: {}", e))
    })?;
    let mut raw = original.clone();
    termios::cfmakeraw(&mut raw);
    termios::tcsetattr(&stdin, termios::SetArg::TCSANOW, &raw).map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::Other, format!("tcsetattr: {}", e))
    })?;
    Ok(original)
}

fn restore_terminal(original: &termios::Termios) {
    let stdin = std::io::stdin();
    let _ = termios::tcsetattr(&stdin, termios::SetArg::TCSANOW, original);
}

async fn fetch_ticket(api_url: &str, vm_id: &str) -> Result<String, Box<dyn std::error::Error>> {
    let url = format!("{}/api/vms/{}/ticket", api_url.trim_end_matches('/'), vm_id);
    eprintln!("Fetching ticket from {}...", url);
    let resp: TicketResponse = reqwest::get(&url).await?.json().await?;
    Ok(resp.ticket)
}

async fn connect_to_vm(
    ticket_str: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // Parse EndpointAddr from ticket JSON
    let addr: EndpointAddr = serde_json::from_str(ticket_str).map_err(|e| {
        format!("Failed to parse ticket: {}. Make sure the ticket is the JSON-serialized EndpointAddr.", e)
    })?;

    eprintln!("Connecting to VM...");

    // Create ephemeral client endpoint
    let endpoint = Endpoint::builder().bind().await?;
    endpoint.online().await;

    // Connect to the VM's Iroh endpoint
    let conn = endpoint.connect(addr, SHELL_ALPN).await?;
    eprintln!("Connected. Opening shell...");

    // Open bidirectional QUIC stream
    let (mut send, mut recv) = conn.open_bi().await?;

    // Get terminal size and send Hello
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

    // Set terminal to raw mode
    let original_termios = set_raw_mode()?;

    // Install cleanup on panic
    let orig_clone = original_termios.clone();
    let _guard = scopeguard::guard((), move |_| {
        restore_terminal(&orig_clone);
    });

    // Run the main I/O loop
    let result = run_shell_loop(&mut send, &mut recv).await;

    // Restore terminal (scopeguard handles this, but be explicit)
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

    // Set up SIGWINCH handler
    let mut sigwinch =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())?;

    loop {
        tokio::select! {
            // Data from VM (PTY output)
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
                        // Stream closed
                        return Ok(0);
                    }
                    Err(e) => {
                        return Err(e.into());
                    }
                }
            }

            // Data from local stdin (keyboard input)
            result = stdin.read(&mut stdin_buf) => {
                match result {
                    Ok(0) => {
                        // EOF on stdin
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

            // Terminal resize signal
            _ = sigwinch.recv() => {
                let (rows, cols) = get_terminal_size();
                let _ = write_frame(send, &Frame::Resize { rows, cols }).await;
            }
        }
    }
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Command::Connect { ticket } => connect_to_vm(&ticket).await,
        Command::Shell { vm_id, api } => {
            match fetch_ticket(&api, &vm_id).await {
                Ok(ticket) => connect_to_vm(&ticket).await,
                Err(e) => {
                    eprintln!("Failed to fetch ticket: {}", e);
                    std::process::exit(1);
                }
            }
        }
    };

    if let Err(e) = result {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

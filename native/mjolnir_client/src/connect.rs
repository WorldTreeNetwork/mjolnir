//! Connection-related commands: Iroh QUIC shell, WebSocket PTY, TCP proxy, SSH tunnel.

use anyhow::{Context, Result};
use iroh::endpoint::Endpoint;
use iroh_base::{EndpointAddr, PublicKey, RelayUrl};
use mjolnir_protocol::{read_frame, write_frame, Frame, PROTOCOL_VERSION, SHELL_ALPN, TCP_FWD_ALPN};
#[cfg(unix)]
use nix::sys::termios;
use std::io::Write;
use std::net::SocketAddr;
use tokio::io::AsyncReadExt;
use tokio_tungstenite::tungstenite::Message;
use futures_util::{SinkExt, StreamExt};

// --- Terminal size ---

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

// --- Address resolution ---

/// Parse a ticket string into an EndpointAddr.
///
/// Accepts three formats:
/// - Full iroh JSON (starts with `{`)
/// - 64-char hex string (raw node ID)
/// - z32-encoded node ID (the default compact format, 52 chars)
///
/// Optional relay URL and direct IP hints are appended to the resulting address.
pub fn resolve_addr(
    ticket: &str,
    relay: Option<String>,
    ips: &[String],
) -> Result<EndpointAddr> {
    let ticket = ticket.trim();

    // Full iroh JSON
    if ticket.starts_with('{') {
        return serde_json::from_str::<EndpointAddr>(ticket)
            .context("Failed to parse iroh JSON ticket");
    }

    // Decode node ID bytes from hex or z32
    let bytes: Vec<u8> = if ticket.len() == 64 && ticket.chars().all(|c| c.is_ascii_hexdigit()) {
        hex::decode(ticket).context("Failed to hex-decode ticket")?
    } else {
        z32::decode(ticket.as_bytes())
            .map_err(|e| anyhow::anyhow!("Invalid ticket: not valid z32, hex, or iroh JSON ({})", e))?
    };

    let key_bytes: [u8; 32] = bytes
        .try_into()
        .map_err(|v: Vec<u8>| anyhow::anyhow!("Invalid key length: {} (expected 32)", v.len()))?;
    let pubkey = PublicKey::from_bytes(&key_bytes).context("Failed to parse public key")?;

    let mut addr = EndpointAddr::new(pubkey);

    if let Some(relay_str) = relay {
        let relay_url: RelayUrl = relay_str
            .parse()
            .map_err(|e| anyhow::anyhow!("Invalid relay URL '{}': {}", relay_str, e))?;
        addr = addr.with_relay_url(relay_url);
    }

    for ip_str in ips {
        let sock: SocketAddr = ip_str
            .parse()
            .map_err(|e| anyhow::anyhow!("Invalid IP address '{}': {}", ip_str, e))?;
        addr = addr.with_ip_addr(sock);
    }

    Ok(addr)
}

/// Format an EndpointAddr for human display.
pub fn format_addr_info(addr: &EndpointAddr) -> String {
    let mut lines = Vec::new();
    let id_bytes = addr.id.as_bytes();
    lines.push(format!("Ticket: {}", z32::encode(id_bytes)));
    lines.push(format!("   Hex: {}", hex::encode(id_bytes)));
    for relay in addr.relay_urls() {
        lines.push(format!(" Relay: {}", relay));
    }
    for ip in addr.ip_addrs() {
        lines.push(format!("    IP: {}", ip));
    }
    lines.join("\n")
}

// --- Iroh QUIC shell connection ---

pub async fn connect_to_vm(addr: EndpointAddr, session: Option<String>) -> Result<()> {
    eprintln!("Connecting to VM...");

    let endpoint = Endpoint::builder().bind().await.context("Failed to bind Iroh endpoint")?;
    endpoint.online().await;

    let conn = endpoint.connect(addr, SHELL_ALPN).await.context("Failed to connect to VM")?;
    eprintln!("Connected. Opening shell...");

    let (mut send, mut recv) = conn.open_bi().await.context("Failed to open QUIC stream")?;

    let (rows, cols) = get_terminal_size();
    write_frame(
        &mut send,
        &Frame::Hello {
            rows,
            cols,
            version: PROTOCOL_VERSION,
        },
    )
    .await
    .context("Failed to send Hello frame")?;

    // Inject tmux session command if requested
    if let Some(ref name) = session {
        let cmd = format!("tmux attach -t {} || tmux new-session -s {}\n", name, name);
        write_frame(&mut send, &Frame::Data(cmd.into_bytes()))
            .await
            .context("Failed to send tmux session command")?;
    }

    let original_termios = set_raw_mode().context("Failed to set raw mode")?;
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
) -> Result<i32> {
    let mut stdin = tokio::io::stdin();
    let mut stdin_buf = vec![0u8; 4096];
    let mut sigwinch =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())
            .context("Failed to register SIGWINCH handler")?;

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
) -> Result<i32> {
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

// --- WebSocket PTY connection ---

/// Connect to a VM PTY via WebSocket.
///
/// This is the renamed version of `cmd_pty` from main.rs, accepting the API flag
/// and token as options, and the VM ID as a string.
pub async fn cmd_connect(
    profile: &crate::config::Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    vm_id: &str,
    session: Option<String>,
) -> Result<()> {
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    // Build WebSocket URL: convert http(s) to ws(s)
    let ws_url = if base.starts_with("https") {
        base.replacen("https", "wss", 1)
    } else {
        base.replacen("http", "ws", 1)
    };
    let url = format!("{}/api/vms/{}/pty", ws_url, vm_id);

    // Build request with auth header
    let effective_token = crate::auth::resolve_token(token).await;
    let mut request = tokio_tungstenite::tungstenite::client::IntoClientRequest::into_client_request(url.as_str())
        .context("Failed to build WebSocket request")?;
    if let Some(t) = effective_token {
        request.headers_mut().insert(
            "Authorization",
            format!("Bearer {}", t).parse().context("Invalid auth header value")?,
        );
    }

    eprintln!("Connecting to VM {}...", vm_id);

    let (ws_stream, _response) = tokio_tungstenite::connect_async(request)
        .await
        .context("Failed to connect WebSocket")?;

    eprintln!("Connected. PTY session active.");

    // Set raw mode
    let original_termios = set_raw_mode().context("Failed to set raw mode")?;
    let orig_for_guard = original_termios.clone();
    let _guard = scopeguard::guard((), move |_| {
        restore_terminal(&orig_for_guard);
    });

    let result = run_pty_loop(ws_stream, session).await;

    restore_terminal(&original_termios);

    match result {
        Ok(()) => Ok(()),
        Err(e) => {
            eprintln!("Connection error: {}", e);
            std::process::exit(1);
        }
    }
}

#[cfg(unix)]
async fn run_pty_loop<S>(ws_stream: S, session: Option<String>) -> Result<()>
where
    S: futures_util::Stream<Item = std::result::Result<Message, tokio_tungstenite::tungstenite::Error>>
        + futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error>
        + Unpin,
{
    let (mut ws_write, mut ws_read) = ws_stream.split();
    let mut stdin = tokio::io::stdin();
    let mut stdin_buf = vec![0u8; 4096];

    // Send initial resize
    let (rows, cols) = get_terminal_size();
    let resize_msg = serde_json::json!({"type": "resize", "rows": rows, "cols": cols});
    ws_write.send(Message::Text(resize_msg.to_string())).await
        .context("Failed to send initial resize")?;

    // Inject tmux session command if requested
    if let Some(ref name) = session {
        let cmd = format!("tmux attach -t {} || tmux new-session -s {}\n", name, name);
        ws_write.send(Message::Binary(cmd.into_bytes())).await
            .context("Failed to send tmux session command")?;
    }

    // Set up SIGWINCH handler
    let mut sigwinch = tokio::signal::unix::signal(
        tokio::signal::unix::SignalKind::window_change(),
    )
    .context("Failed to register SIGWINCH handler")?;

    loop {
        tokio::select! {
            msg = ws_read.next() => {
                match msg {
                    Some(Ok(Message::Binary(data))) => {
                        let mut stdout = std::io::stdout().lock();
                        stdout.write_all(&data)?;
                        stdout.flush()?;
                    }
                    Some(Ok(Message::Close(_))) | None => return Ok(()),
                    Some(Ok(_)) => {}
                    Some(Err(e)) => return Err(e.into()),
                }
            }
            result = stdin.read(&mut stdin_buf) => {
                match result {
                    Ok(0) => return Ok(()),
                    Ok(n) => {
                        ws_write.send(Message::Binary(stdin_buf[..n].to_vec())).await?;
                    }
                    Err(e) => return Err(e.into()),
                }
            }
            _ = sigwinch.recv() => {
                let (rows, cols) = get_terminal_size();
                let resize_msg = serde_json::json!({"type": "resize", "rows": rows, "cols": cols});
                ws_write.send(Message::Text(resize_msg.to_string())).await?;
            }
        }
    }
}

#[cfg(windows)]
async fn run_pty_loop<S>(ws_stream: S, session: Option<String>) -> Result<()>
where
    S: futures_util::Stream<Item = std::result::Result<Message, tokio_tungstenite::tungstenite::Error>>
        + futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error>
        + Unpin,
{
    let (mut ws_write, mut ws_read) = ws_stream.split();
    let mut stdin = tokio::io::stdin();
    let mut stdin_buf = vec![0u8; 4096];

    // Send initial resize
    let (rows, cols) = get_terminal_size();
    let resize_msg = serde_json::json!({
        "type": "resize",
        "rows": rows,
        "cols": cols
    });
    ws_write.send(Message::Text(resize_msg.to_string())).await
        .context("Failed to send initial resize")?;

    // Inject tmux session command if requested
    if let Some(ref name) = session {
        let cmd = format!("tmux attach -t {} || tmux new-session -s {}\n", name, name);
        ws_write.send(Message::Binary(cmd.into_bytes())).await
            .context("Failed to send tmux session command")?;
    }

    loop {
        tokio::select! {
            // Data from server (PTY output)
            msg = ws_read.next() => {
                match msg {
                    Some(Ok(Message::Binary(data))) => {
                        let mut stdout = std::io::stdout().lock();
                        stdout.write_all(&data)?;
                        stdout.flush()?;
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        return Ok(());
                    }
                    Some(Ok(_)) => {} // ignore text, ping, pong
                    Some(Err(e)) => return Err(e.into()),
                }
            }
            // Stdin (user typing)
            result = stdin.read(&mut stdin_buf) => {
                match result {
                    Ok(0) => return Ok(()), // EOF
                    Ok(n) => {
                        ws_write.send(Message::Binary(stdin_buf[..n].to_vec())).await?;
                    }
                    Err(e) => return Err(e.into()),
                }
            }
        }
    }
}

// --- Shell quote helper ---

/// Shell-escape a string for use in commands.
/// Unix: single quotes with embedded quote escaping.
/// Windows: double quotes with embedded quote escaping.
#[cfg(unix)]
pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

#[cfg(windows)]
pub fn shell_quote(s: &str) -> String {
    format!("\"{}\"", s.replace('"', "\\\""))
}

// --- TCP proxy over Iroh QUIC ---

pub async fn cmd_proxy(
    ticket: &str,
    port: u16,
    relay: Option<String>,
    ips: &[String],
) -> Result<()> {
    let addr = resolve_addr(ticket, relay, ips)?;

    let endpoint = Endpoint::builder().bind().await.context("Failed to bind Iroh endpoint")?;
    endpoint.online().await;

    let conn = endpoint.connect(addr, TCP_FWD_ALPN).await.context("Failed to connect to VM")?;
    let (mut send, mut recv) = conn.open_bi().await.context("Failed to open QUIC stream")?;

    // Send target port as 2 bytes (u16 big-endian)
    send.write_all(&port.to_be_bytes()).await.context("Failed to send port")?;

    // Bidirectional copy with graceful half-close: stdin <-> QUIC
    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();

    let c2s = async {
        let r = tokio::io::copy(&mut stdin, &mut send).await;
        let _ = send.finish();
        r
    };
    let s2c = async {
        tokio::io::copy(&mut recv, &mut stdout).await
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

// --- SSH via Iroh tunnel ---

pub fn cmd_ssh(
    ticket: &str,
    user: &str,
    relay: Option<String>,
    ips: &[String],
    ssh_args: &[String],
) -> Result<()> {
    let self_exe = std::env::current_exe().context("Failed to get current executable path")?;

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
        return Err(anyhow::anyhow!("Failed to exec ssh: {}", err));
    }

    // On Windows, spawn ssh.exe and wait for it
    #[cfg(windows)]
    {
        let status = std::process::Command::new("ssh.exe")
            .args(&args)
            .status()
            .map_err(|e| anyhow::anyhow!("Failed to run ssh: {}", e))?;
        std::process::exit(status.code().unwrap_or(1));
    }
}

//! Connection-related commands: Iroh QUIC shell, WebSocket PTY, TCP proxy, SSH tunnel.

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use iroh::endpoint::Endpoint;
use iroh::{EndpointAddr, PublicKey, RelayUrl};
use mjolnir_protocol::{
    read_frame, write_frame, Frame, PROTOCOL_VERSION, SHELL_ALPN, SHELL_ALPN_V2, TCP_FWD_ALPN,
};
#[cfg(unix)]
use nix::sys::termios;
use std::io::Write;
use std::net::SocketAddr;
use tokio::io::AsyncReadExt;
use tokio_tungstenite::tungstenite::Message;

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
pub fn resolve_addr(ticket: &str, relay: Option<String>, ips: &[String]) -> Result<EndpointAddr> {
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
        z32::decode(ticket.as_bytes()).map_err(|e| {
            anyhow::anyhow!("Invalid ticket: not valid z32, hex, or iroh JSON ({})", e)
        })?
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

    let endpoint = Endpoint::builder(iroh::endpoint::presets::N0)
        .bind()
        .await
        .context("Failed to bind Iroh endpoint")?;
    endpoint.online().await;

    // ALPN is the version handshake. A `--session` request needs an agent that can decode
    // a Hello carrying a session name, so we ask for SHELL_ALPN_V2 and let QUIC tell us
    // whether the far end speaks it — a v1 agent refuses the unknown ALPN during the TLS
    // handshake, before we have written a byte. Falling back to v1 (and to typing the
    // tmux command into the shell) degrades to the old behaviour instead of erroring.
    // Without a session there is nothing to negotiate, so we keep the single-round-trip
    // v1 path untouched.
    let (conn, negotiated_v2) = if session.is_some() {
        match endpoint.clone().connect(addr.clone(), SHELL_ALPN_V2).await {
            Ok(conn) => (conn, true),
            Err(e) => {
                // Could be an old agent (ALPN refused) or a genuinely unreachable VM.
                // Retrying on v1 distinguishes the two: if the VM is really unreachable
                // the second attempt fails too, and that error is the one we surface.
                eprintln!("Agent does not support shared sessions natively ({e}); falling back.");
                let conn = endpoint
                    .connect(addr, SHELL_ALPN)
                    .await
                    .context("Failed to connect to VM")?;
                (conn, false)
            }
        }
    } else {
        let conn = endpoint
            .connect(addr, SHELL_ALPN)
            .await
            .context("Failed to connect to VM")?;
        (conn, false)
    };
    eprintln!("Connected. Opening shell...");

    let (mut send, mut recv) = conn.open_bi().await.context("Failed to open QUIC stream")?;

    let (rows, cols) = get_terminal_size();
    write_frame(
        &mut send,
        &Frame::Hello {
            rows,
            cols,
            version: PROTOCOL_VERSION,
            // Only ever send a session name over v2 — a v1 agent rejects the longer
            // Hello payload outright rather than ignoring the trailing bytes.
            session: if negotiated_v2 { session.clone() } else { None },
        },
    )
    .await
    .context("Failed to send Hello frame")?;

    // On a v1 agent the session name could not ride on Hello, so fall back to typing the
    // attach command into the shell. It races shell startup and shows up in scrollback,
    // which is exactly why v2 exists — but it beats dropping the user in the wrong shell.
    if !negotiated_v2 {
        if let Some(ref name) = session {
            let cmd = format!("tmux new-session -A -s {}\n", name);
            write_frame(&mut send, &Frame::Data(cmd.into_bytes()))
                .await
                .context("Failed to send tmux session command")?;
        }
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

/// Percent-encode a query-parameter value.
///
/// The API is the authority on what a session name may contain
/// (`Mjolnir.API.Validation.validate_session_name/2`), so this deliberately does not
/// duplicate that policy — it only guarantees that whatever the user typed reaches the
/// server as one intact parameter, to be accepted or rejected there. Re-implementing the
/// charset rule in a third place would just give it somewhere new to drift.
fn percent_encode_query(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{:02X}", byte)),
        }
    }
    out
}

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
    // The PTY endpoint takes the tmux session name as a query parameter and threads it
    // all the way to the guest agent's PtyOpen, which attaches the PTY to that session
    // directly. Passing it here rather than typing `tmux new-session` into the shell
    // means there is no outer shell left behind to fall back into on detach, nothing
    // lands in scrollback, and the attach cannot race shell startup.
    let url = match session.as_deref() {
        Some(name) => format!(
            "{}/api/vms/{}/pty?session={}",
            ws_url,
            vm_id,
            percent_encode_query(name)
        ),
        None => format!("{}/api/vms/{}/pty", ws_url, vm_id),
    };

    // Build request with auth header
    let effective_token = crate::auth::resolve_token(token).await;
    let mut request =
        tokio_tungstenite::tungstenite::client::IntoClientRequest::into_client_request(
            url.as_str(),
        )
        .context("Failed to build WebSocket request")?;
    if let Some(t) = effective_token {
        request.headers_mut().insert(
            "Authorization",
            format!("Bearer {}", t)
                .parse()
                .context("Invalid auth header value")?,
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

    // No session argument: the server already opened the PTY attached to the right tmux
    // session, so this loop is a plain byte pump in both cases.
    let result = run_pty_loop(ws_stream).await;

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
async fn run_pty_loop<S>(ws_stream: S) -> Result<()>
where
    S: futures_util::Stream<
            Item = std::result::Result<Message, tokio_tungstenite::tungstenite::Error>,
        > + futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error>
        + Unpin,
{
    let (mut ws_write, mut ws_read) = ws_stream.split();
    let mut stdin = tokio::io::stdin();
    let mut stdin_buf = vec![0u8; 4096];

    // Send initial resize
    let (rows, cols) = get_terminal_size();
    let resize_msg = serde_json::json!({"type": "resize", "rows": rows, "cols": cols});
    ws_write
        .send(Message::Text(resize_msg.to_string()))
        .await
        .context("Failed to send initial resize")?;

    // Set up SIGWINCH handler
    let mut sigwinch =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())
            .context("Failed to register SIGWINCH handler")?;

    let mut ping = tokio::time::interval(std::time::Duration::from_secs(20));
    ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            msg = ws_read.next() => {
                match msg {
                    Some(Ok(Message::Binary(data))) => {
                        let mut stdout = std::io::stdout().lock();
                        stdout.write_all(&data)?;
                        stdout.flush()?;
                    }
                    Some(Ok(Message::Ping(payload))) => {
                        ws_write.send(Message::Pong(payload)).await?;
                    }
                    Some(Ok(Message::Pong(_))) => {}
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
            _ = ping.tick() => {
                ws_write.send(Message::Ping(Vec::new())).await?;
            }
        }
    }
}

#[cfg(windows)]
async fn run_pty_loop<S>(ws_stream: S) -> Result<()>
where
    S: futures_util::Stream<
            Item = std::result::Result<Message, tokio_tungstenite::tungstenite::Error>,
        > + futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error>
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
    ws_write
        .send(Message::Text(resize_msg.to_string()))
        .await
        .context("Failed to send initial resize")?;

    let mut ping = tokio::time::interval(std::time::Duration::from_secs(20));
    ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

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
                    Some(Ok(Message::Ping(payload))) => {
                        ws_write.send(Message::Pong(payload)).await?;
                    }
                    Some(Ok(Message::Pong(_))) => {}
                    Some(Ok(Message::Close(_))) | None => {
                        return Ok(());
                    }
                    Some(Ok(_)) => {}
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
            _ = ping.tick() => {
                ws_write.send(Message::Ping(Vec::new())).await?;
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

    let endpoint = Endpoint::builder(iroh::endpoint::presets::N0)
        .bind()
        .await
        .context("Failed to bind Iroh endpoint")?;
    endpoint.online().await;

    let conn = endpoint
        .connect(addr, TCP_FWD_ALPN)
        .await
        .context("Failed to connect to VM")?;
    let (mut send, mut recv) = conn.open_bi().await.context("Failed to open QUIC stream")?;

    // Send target port as 2 bytes (u16 big-endian)
    send.write_all(&port.to_be_bytes())
        .await
        .context("Failed to send port")?;

    // Bidirectional copy with graceful half-close: stdin <-> QUIC
    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();

    let c2s = async {
        let r = tokio::io::copy(&mut stdin, &mut send).await;
        let _ = send.finish();
        r
    };
    let s2c = async { tokio::io::copy(&mut recv, &mut stdout).await };

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

/// Dummy SSH hostname. Must not be `mjolnir` — that matches `Host mjolnir` in
/// a typical operator ssh_config and rewrites HostName to the hypervisor.
pub fn ssh_dummy_host(target: &str) -> String {
    if is_vm_id(target) {
        format!("mj-{target}")
    } else {
        "mj-iroh".to_string()
    }
}

pub fn cmd_ssh(
    ticket: &str,
    user: &str,
    relay: Option<String>,
    ips: &[String],
    ssh_args: &[String],
    dummy_host: &str,
    identity_file: Option<&str>,
) -> Result<()> {
    let self_exe = std::env::current_exe().context("Failed to get current executable path")?;

    // Build the ProxyCommand with shell-safe quoting.
    // Self-invokes `mj proxy <ticket>` — passing a ticket (already resolved by
    // the caller) so the proxy goes straight to the P2P path without a re-lookup.
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
    ];
    if let Some(id_file) = identity_file {
        args.push("-o".to_string());
        args.push("IdentitiesOnly=yes".to_string());
        args.push("-i".to_string());
        args.push(id_file.to_string());
    }
    args.push(dummy_host.to_string());
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

// --- Intent-level connection verbs (transport auto-selected) ---

/// True if `target` looks like a VM UUID (vs an Iroh ticket). Mirrors the
/// heuristic in `mjolnir_api::api::resolve_vm_id` (36 chars, contains '-').
pub fn is_vm_id(target: &str) -> bool {
    target.len() == 36 && target.contains('-')
}

/// Resolve a connection target (VM id OR ticket) to an Iroh ticket. If it's a
/// VM id, fetch the ticket from the API (requires auth on the owning account).
async fn target_to_ticket(
    profile: &crate::config::Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    target: &str,
) -> Result<String> {
    if is_vm_id(target) {
        let client = crate::api::api_client(token).await;
        let base = crate::config::resolve_api(api_flag, profile);
        crate::api::fetch_ticket(&client, &base, target).await
    } else {
        Ok(target.to_string())
    }
}

/// `mj connect <id|ticket>` — interactive shell. A VM id goes through the
/// gateway (WebSocket) unless `--p2p` is set; a ticket always goes peer-to-peer
/// (Iroh QUIC). The chosen transport is announced on stderr.
pub async fn cmd_shell(
    profile: &crate::config::Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    target: &str,
    p2p: bool,
    session: Option<String>,
    relay: Option<String>,
    ips: &[String],
) -> Result<()> {
    if is_vm_id(target) && !p2p {
        eprintln!("→ transport: gateway (WebSocket)");
        cmd_connect(profile, api_flag, token, target, session).await
    } else {
        eprintln!("→ transport: peer-to-peer (Iroh QUIC)");
        let ticket = target_to_ticket(profile, api_flag, token, target).await?;
        let addr = resolve_addr(&ticket, relay, ips)?;
        connect_to_vm(addr, session).await
    }
}

/// Hidden alias: exec system ssh with `mj proxy` as ProxyCommand.
/// Prefer `mj connect` for a shell.
pub async fn cmd_ssh_target(
    profile: &crate::config::Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    target: &str,
    user: &str,
    relay: Option<String>,
    ips: &[String],
    ssh_args: &[String],
) -> Result<()> {
    let ticket = target_to_ticket(profile, api_flag, token, target).await?;
    let host = ssh_dummy_host(target);
    let identity = crate::config::resolve_ssh_identity_file(profile);
    cmd_ssh(
        &ticket,
        user,
        relay,
        ips,
        ssh_args,
        &host,
        identity.as_deref(),
    )
}

/// `mj proxy <id|ticket>` — raw TCP proxy over the Iroh tunnel (used as an ssh
/// ProxyCommand). Always peer-to-peer; a VM id is resolved to a ticket first.
/// No status line — this is machine-facing plumbing.
pub async fn cmd_proxy_target(
    profile: &crate::config::Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    target: &str,
    port: u16,
    relay: Option<String>,
    ips: &[String],
) -> Result<()> {
    let ticket = target_to_ticket(profile, api_flag, token, target).await?;
    cmd_proxy(&ticket, port, relay, ips).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_encode_query_leaves_valid_session_names_untouched() {
        // Every name the API will actually accept is unreserved, so the common case must
        // not mangle anything — a name that round-trips differently would silently open a
        // *different* tmux session than the one the user asked for.
        assert_eq!(percent_encode_query("shared-term"), "shared-term");
        assert_eq!(percent_encode_query("dev_1-a"), "dev_1-a");
        assert_eq!(percent_encode_query("9"), "9");
    }

    #[test]
    fn percent_encode_query_escapes_query_structure() {
        // These are rejected by the API, but they must arrive as one parameter for it to
        // reject them — not smuggle a second query parameter into the request.
        assert_eq!(percent_encode_query("a&b=c"), "a%26b%3Dc");
        assert_eq!(percent_encode_query("a b"), "a%20b");
        assert_eq!(percent_encode_query("a#f"), "a%23f");
        assert_eq!(percent_encode_query("foo:0.0"), "foo%3A0.0");
    }

    #[test]
    fn percent_encode_query_escapes_non_ascii_bytewise() {
        assert_eq!(percent_encode_query("café"), "caf%C3%A9");
    }

    #[test]
    fn ssh_dummy_host_does_not_collide_with_ssh_config_mjolnir() {
        let id = "f9eb045b-8ffa-4a53-99db-e5450660913b";
        assert_eq!(ssh_dummy_host(id), format!("mj-{id}"));
        assert_ne!(ssh_dummy_host(id), "mjolnir");
        assert_eq!(
            ssh_dummy_host("pcwdqccp6ehuf4uiqb1ksitamd5z5byo6pgrmcdxkoyrty37p1co"),
            "mj-iroh"
        );
    }
}

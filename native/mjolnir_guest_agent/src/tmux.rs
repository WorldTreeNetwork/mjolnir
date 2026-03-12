//! Tmux session management for terminal operations.

use anyhow::{anyhow, Result};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;
use tokio::process::Command;
use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::protocol::TmuxSessionInfo;

/// Output from a send_and_read operation.
pub struct CommandOutput {
    pub output: String,
    pub exit_code: Option<i32>,
    pub duration_ms: u64,
    pub timed_out: bool,
}

/// Per-session mutex to prevent concurrent send_and_read from interleaving sentinels.
static SESSION_LOCKS: once_cell::sync::Lazy<Mutex<HashMap<String, Arc<Mutex<()>>>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(HashMap::new()));

async fn get_session_lock(session: &str) -> Arc<Mutex<()>> {
    let mut locks = SESSION_LOCKS.lock().await;
    locks
        .entry(session.to_string())
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone()
}

/// Ensure a tmux session exists, creating it if necessary.
/// Returns (session_name, status) where status is "created" or "attached".
pub async fn ensure_session(name: &str) -> Result<(String, String)> {
    let check = Command::new("tmux")
        .args(["has-session", "-t", name])
        .output()
        .await?;

    if check.status.success() {
        info!("Tmux session '{}' already exists", name);
        Ok((name.to_string(), "attached".to_string()))
    } else {
        info!("Creating tmux session '{}'", name);
        let create = Command::new("tmux")
            .args(["new-session", "-d", "-s", name, "-x", "200", "-y", "50"])
            .output()
            .await?;

        if create.status.success() {
            Ok((name.to_string(), "created".to_string()))
        } else {
            let stderr = String::from_utf8_lossy(&create.stderr);
            Err(anyhow!("Failed to create tmux session '{}': {}", name, stderr))
        }
    }
}

/// List all tmux sessions.
pub async fn list_sessions() -> Result<Vec<TmuxSessionInfo>> {
    let output = Command::new("tmux")
        .args([
            "list-sessions",
            "-F",
            "#{session_name}|#{session_windows}|#{session_created}|#{session_attached}",
        ])
        .output()
        .await?;

    if !output.status.success() {
        // No sessions — tmux exits non-zero
        return Ok(vec![]);
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let sessions = stdout
        .lines()
        .filter(|line| !line.is_empty())
        .filter_map(|line| {
            let parts: Vec<&str> = line.splitn(4, '|').collect();
            if parts.len() < 4 {
                warn!("Unexpected tmux list-sessions output: {}", line);
                return None;
            }
            let session_name = parts[0].to_string();
            let windows: u32 = parts[1].parse().unwrap_or(0);
            let created: u64 = parts[2].parse().unwrap_or(0);
            let attached = parts[3] != "0";
            Some(TmuxSessionInfo {
                session_name,
                windows,
                created,
                attached,
            })
        })
        .collect();

    Ok(sessions)
}

/// Kill a tmux session by name.
pub async fn kill_session(name: &str) -> Result<()> {
    let output = Command::new("tmux")
        .args(["kill-session", "-t", name])
        .output()
        .await?;

    if output.status.success() {
        info!("Killed tmux session '{}'", name);
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(anyhow!("Failed to kill tmux session '{}': {}", name, stderr))
    }
}

/// Send keys or a command to a tmux session.
/// Exactly one of `command` or `keys` must be provided.
pub async fn send_keys(
    session: &str,
    command: Option<&str>,
    keys: Option<&str>,
) -> Result<()> {
    match (command, keys) {
        (Some(_), Some(_)) => {
            return Err(anyhow!("Only one of 'command' or 'keys' may be specified"));
        }
        (None, None) => {
            return Err(anyhow!("One of 'command' or 'keys' must be specified"));
        }
        (Some(cmd), None) => {
            // Send command literally, then Enter
            let output = Command::new("tmux")
                .args(["send-keys", "-t", session, "-l", cmd])
                .output()
                .await?;
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                return Err(anyhow!("send-keys -l failed: {}", stderr));
            }
            // Send Enter separately
            let output = Command::new("tmux")
                .args(["send-keys", "-t", session, "Enter"])
                .output()
                .await?;
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                return Err(anyhow!("send-keys Enter failed: {}", stderr));
            }
        }
        (None, Some(k)) => {
            // Send special keys (C-c, Escape, etc.) without literal flag
            let output = Command::new("tmux")
                .args(["send-keys", "-t", session, k])
                .output()
                .await?;
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                return Err(anyhow!("send-keys failed: {}", stderr));
            }
        }
    }
    Ok(())
}

/// Strip ANSI escape sequences from a string.
fn strip_ansi(input: &str) -> String {
    strip_ansi_escapes::strip_str(input)
}

/// Capture pane content and dimensions for a tmux session.
/// Returns (content, pane_rows, pane_cols, running_command).
pub async fn capture_pane(
    session: &str,
    lines: i32,
) -> Result<(String, u16, u16, Option<String>)> {
    // Capture scrollback content
    let capture = Command::new("tmux")
        .args([
            "capture-pane",
            "-t",
            session,
            "-p",
            "-S",
            &format!("-{}", lines),
        ])
        .output()
        .await?;

    if !capture.status.success() {
        let stderr = String::from_utf8_lossy(&capture.stderr);
        return Err(anyhow!("capture-pane failed: {}", stderr));
    }

    let raw_content = String::from_utf8_lossy(&capture.stdout).to_string();
    let content = strip_ansi(&raw_content);

    // Get pane dimensions and current command
    let display = Command::new("tmux")
        .args([
            "display-message",
            "-t",
            session,
            "-p",
            "#{pane_width}|#{pane_height}|#{pane_current_command}",
        ])
        .output()
        .await?;

    let (pane_cols, pane_rows, running_command) = if display.status.success() {
        let info = String::from_utf8_lossy(&display.stdout);
        let info = info.trim();
        let parts: Vec<&str> = info.splitn(3, '|').collect();
        if parts.len() >= 3 {
            let cols: u16 = parts[0].parse().unwrap_or(200);
            let rows: u16 = parts[1].parse().unwrap_or(50);
            let cmd = parts[2].trim().to_string();
            let running = if cmd.is_empty() || cmd == "bash" || cmd == "sh" || cmd == "zsh" {
                None
            } else {
                Some(cmd)
            };
            (cols, rows, running)
        } else {
            (200, 50, None)
        }
    } else {
        (200, 50, None)
    };

    Ok((content, pane_rows, pane_cols, running_command))
}

/// Send a command and poll until it completes, returning its output.
pub async fn send_and_read(
    session: &str,
    command: &str,
    timeout_ms: u64,
    sentinel_id: &str,
) -> Result<CommandOutput> {
    // Acquire per-session lock to prevent sentinel interleaving
    let lock = get_session_lock(session).await;
    let _guard = lock.lock().await;

    let start = Instant::now();
    let sentinel = format!("__MJOLNIR_DONE_{}_$?__", sentinel_id);

    // Send the command with sentinel appended. We pass the full string to tmux
    // without -l so the shell receives and evaluates $?.
    let full_cmd = format!("{}; echo __MJOLNIR_DONE_{}_{}", command, sentinel_id, "$?__");
    let send_result = Command::new("tmux")
        .args(["send-keys", "-t", session, &full_cmd, "Enter"])
        .output()
        .await?;

    if !send_result.status.success() {
        let stderr = String::from_utf8_lossy(&send_result.stderr);
        return Err(anyhow!("Failed to send command: {}", stderr));
    }

    let sentinel_prefix = format!("__MJOLNIR_DONE_{}_", sentinel_id);
    let timeout_duration = std::time::Duration::from_millis(timeout_ms);

    loop {
        if start.elapsed() >= timeout_duration {
            // Timed out — capture whatever is there
            let (content, _, _, _) = capture_pane(session, 1000).await.unwrap_or_default();
            return Ok(CommandOutput {
                output: content,
                exit_code: None,
                duration_ms: start.elapsed().as_millis() as u64,
                timed_out: true,
            });
        }

        tokio::time::sleep(std::time::Duration::from_millis(250)).await;

        let (content, _, _, _) = capture_pane(session, 1000).await?;

        // Find the actual sentinel OUTPUT line, not the echoed command line.
        // The echoed command contains literal "$?": "echo __MJOLNIR_DONE_{uuid}_$?__"
        // The actual output has a resolved exit code: "__MJOLNIR_DONE_{uuid}_0__"
        // We distinguish them by checking that the suffix after the prefix
        // is a number followed by "__", not "$?__".
        if let Some(sentinel_line) = content
            .lines()
            .rfind(|line| {
                if let Some(rest) = line.find(&*sentinel_prefix).map(|pos| {
                    &line[pos + sentinel_prefix.len()..]
                }) {
                    // Resolved sentinel ends with "<digits>__"; echoed command has "$?__"
                    rest.starts_with(|c: char| c.is_ascii_digit())
                } else {
                    false
                }
            })
        {
            // Found sentinel — wait briefly for pane to settle
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            let (final_content, _, _, _) = capture_pane(session, 1000).await?;

            // Parse exit code from sentinel: __MJOLNIR_DONE_{id}_{exit_code}__
            let exit_code = sentinel_line
                .trim()
                .strip_prefix(&sentinel_prefix)
                .and_then(|s| s.strip_suffix("__"))
                .and_then(|s| s.parse::<i32>().ok());

            // Extract output: lines between command echo and sentinel
            let output = extract_output(&final_content, &full_cmd, &sentinel_prefix);

            return Ok(CommandOutput {
                output,
                exit_code,
                duration_ms: start.elapsed().as_millis() as u64,
                timed_out: false,
            });
        }
    }
}

/// Extract relevant output lines from captured pane content.
/// Looks for lines after the echoed command and before the sentinel.
fn extract_output(content: &str, sent_command: &str, sentinel_prefix: &str) -> String {
    let lines: Vec<&str> = content.lines().collect();

    // Find the last occurrence of the sent command (echoed by the shell)
    let cmd_start = sent_command
        .lines()
        .next()
        .unwrap_or("")
        .trim()
        .chars()
        .take(40)
        .collect::<String>();

    let start_idx = lines
        .iter()
        .rposition(|line| line.contains(&cmd_start))
        .map(|i| i + 1)
        .unwrap_or(0);

    let end_idx = lines
        .iter()
        .rposition(|line| line.contains(sentinel_prefix))
        .unwrap_or(lines.len());

    let end = end_idx.min(lines.len());
    let start = start_idx.min(end);
    lines[start..end]
        .join("\n")
        .trim()
        .to_string()
}

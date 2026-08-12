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

/// Validate a tmux session name to prevent target syntax injection.
///
/// Tmux interprets `-t` arguments with special syntax: `session:window.pane`.
/// A malicious session name like "foo:0.0" could target arbitrary windows/panes.
/// We restrict to ASCII alphanumerics, hyphens, and underscores only.
///
/// The name must also START with an alphanumeric: a leading hyphen would be parsed
/// by tmux as a flag rather than a value (`new-session -s -d` is not a session named
/// "-d"), which is argument injection by another route. ASCII-only, rather than
/// Unicode `is_alphanumeric`, keeps this identical to the API-layer check in
/// `Mjolnir.API.Validation.validate_session_name/2` and rules out confusables.
fn validate_session_name(name: &str) -> Result<()> {
    if name.is_empty() {
        return Err(anyhow!("Session name cannot be empty"));
    }
    if name.len() > 64 {
        return Err(anyhow!("Session name too long (max 64 characters)"));
    }
    if !name.starts_with(|c: char| c.is_ascii_alphanumeric()) {
        return Err(anyhow!(
            "Session name must start with an alphanumeric character"
        ));
    }
    if !name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(anyhow!(
            "Session name must contain only alphanumeric characters, hyphens, or underscores"
        ));
    }
    Ok(())
}

/// Build the argv that attaches a PTY to the named tmux session.
///
/// `new-session -A` attaches to an existing session instead of failing when one is
/// already there, so N callers naming the same session converge on ONE terminal —
/// that is the whole multiplayer mechanism. It also means the in-VM agent driving
/// this session through `send_keys`/`capture_pane` and a human on a PTY are looking
/// at the same pane.
pub fn attach_argv(session: &str) -> Result<Vec<String>> {
    validate_session_name(session)?;
    Ok(vec![
        "tmux".to_string(),
        "new-session".to_string(),
        "-A".to_string(),
        "-s".to_string(),
        session.to_string(),
    ])
}

/// Validate a command string for null bytes and length.
fn validate_command(cmd: &str) -> Result<()> {
    if cmd.len() > 65536 {
        return Err(anyhow!("Command too long (max 64KB)"));
    }
    if cmd.contains('\0') {
        return Err(anyhow!("Command must not contain null bytes"));
    }
    Ok(())
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
    validate_session_name(name)?;
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
            Err(anyhow!(
                "Failed to create tmux session '{}': {}",
                name,
                stderr
            ))
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
    validate_session_name(name)?;
    let output = Command::new("tmux")
        .args(["kill-session", "-t", name])
        .output()
        .await?;

    if output.status.success() {
        info!("Killed tmux session '{}'", name);
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(anyhow!(
            "Failed to kill tmux session '{}': {}",
            name,
            stderr
        ))
    }
}

/// Send keys or a command to a tmux session.
/// Exactly one of `command` or `keys` must be provided.
pub async fn send_keys(session: &str, command: Option<&str>, keys: Option<&str>) -> Result<()> {
    validate_session_name(session)?;
    if let Some(cmd) = command {
        validate_command(cmd)?;
    }
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
pub async fn capture_pane(session: &str, lines: i32) -> Result<(String, u16, u16, Option<String>)> {
    validate_session_name(session)?;

    // ORDER MATTERS. These are two separate tmux invocations, so they are not
    // atomic, and send_and_read uses running_command to gate whether a
    // sentinel match is trustworthy. Sampling busy-ness AFTER the content
    // would open a window: content captured while the command is mid-run (a
    // lookalike present, the real sentinel not yet written), the command then
    // finishes, and idleness sampled afterwards would vouch for stale
    // content. Sampling it FIRST can only err the safe way — "busy" against
    // content that has since completed just skips one 250ms poll.
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
            let running = if cmd.is_empty() || is_idle_shell(&cmd) {
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

    // Content second — see the ordering note above.
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

    let content = strip_ansi(&String::from_utf8_lossy(&capture.stdout));

    Ok((content, pane_rows, pane_cols, running_command))
}

/// Is `cmd` a shell sitting at a prompt, i.e. the pane is idle?
///
/// This used to be presentational — "what is this pane running" — where a
/// missed shell name cost nothing. `send_and_read` now GATES sentinel
/// matching on it, so an unrecognised shell means the pane never looks idle
/// and every call waits out its timeout. That is the safe direction (a
/// timeout is honest; a wrong exit code is not), but it is still a real loss
/// of function, and shared sessions are exactly where somebody's login shell
/// is not bash. Hence the wider list.
///
/// Still a heuristic: a shell not named here degrades to "busy". If that
/// bites, the durable fix is to ask tmux for the pane's own shell rather than
/// pattern-matching names (mjolnir-40c).
fn is_idle_shell(cmd: &str) -> bool {
    matches!(
        cmd,
        "bash"
            | "sh"
            | "zsh"
            | "dash"
            | "ash"
            | "busybox"
            | "fish"
            | "ksh"
            | "mksh"
            | "pdksh"
            | "tcsh"
            | "csh"
            | "elvish"
            | "nu"
            | "xonsh"
    )
}

/// Send a command and poll until it completes, returning its output.
pub async fn send_and_read(
    session: &str,
    command: &str,
    timeout_ms: u64,
    sentinel_id: &str,
) -> Result<CommandOutput> {
    validate_session_name(session)?;
    validate_command(command)?;

    // Acquire per-session lock to prevent sentinel interleaving
    let lock = get_session_lock(session).await;
    let _guard = lock.lock().await;

    let start = Instant::now();
    let sentinel = format!("__MJOLNIR_DONE_{}_$?__", sentinel_id);

    // Send the command with sentinel appended.
    // We use -l (literal) to prevent tmux from interpreting key names in the
    // command string, then send Enter separately. The shell evaluates $?.
    let full_cmd = format!(
        "{}; echo __MJOLNIR_DONE_{}_{}",
        command, sentinel_id, "$?__"
    );
    let send_result = Command::new("tmux")
        .args(["send-keys", "-t", session, "-l", &full_cmd])
        .output()
        .await?;

    if !send_result.status.success() {
        let stderr = String::from_utf8_lossy(&send_result.stderr);
        return Err(anyhow!("Failed to send command: {}", stderr));
    }

    // Send Enter separately (not literal — we want tmux to interpret it as a keypress)
    let enter_result = Command::new("tmux")
        .args(["send-keys", "-t", session, "Enter"])
        .output()
        .await?;

    if !enter_result.status.success() {
        let stderr = String::from_utf8_lossy(&enter_result.stderr);
        return Err(anyhow!("Failed to send Enter: {}", stderr));
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

        let (content, _, _, running_command) = capture_pane(session, 1000).await?;

        // Find the actual sentinel OUTPUT line, not the echoed command line,
        // and not a lookalike the command's own output might print.
        //
        // Shape alone is NOT enough: the echoed command line contains the
        // literal, un-resolved "$?" ("echo __MJOLNIR_DONE_{id}_$?__"), which
        // rules IT out, but a command can deliberately (or accidentally,
        // e.g. via `set -x`/history expansion) print a line that is shaped
        // exactly like a RESOLVED sentinel — "__MJOLNIR_DONE_{id}_<digits>__"
        // — on its own line, before the real command has finished. Verified
        // against a real pane (tmux 3.4): both the lookalike and the real
        // sentinel appear as bare whole lines with nothing else sharing the
        // line, so a whole-line match closes the old substring loophole but
        // cannot by itself tell the two apart — they are textually
        // identical in shape.
        //
        // What DOES distinguish them: `capture_pane`'s `running_command`
        // (from tmux's `#{pane_current_command}`). While a lookalike is
        // printed mid-command (e.g. during `sleep 1` before the shell
        // returns), the pane is still running a foreground process — verified
        // empirically: `pane_current_command` reports "sleep" at that point,
        // and only flips to "bash" once the shell is back at an idle prompt,
        // which happens strictly after our appended `echo` (the real
        // sentinel) has run. `capture_pane` already normalizes shell names
        // (bash/sh/zsh/empty) to `None`. So we only accept a sentinel match
        // when the pane has returned to an idle shell — a lookalike printed
        // while the command is still running cannot satisfy that gate.
        let sentinel_idle_gate = running_command.is_none();

        if sentinel_idle_gate {
            if let Some(exit_code) = content
                .lines()
                .rev()
                .find_map(|line| parse_sentinel_line(line, &sentinel_prefix))
            {
                // Found the real sentinel — wait briefly for pane to settle
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                let (final_content, _, _, _) = capture_pane(session, 1000).await?;

                // Extract output: lines between command echo and sentinel
                let output = extract_output(&final_content, &full_cmd, &sentinel_prefix);

                return Ok(CommandOutput {
                    output,
                    exit_code: Some(exit_code),
                    duration_ms: start.elapsed().as_millis() as u64,
                    timed_out: false,
                });
            }
        }
    }
}

/// Parse a single captured pane line as a RESOLVED sentinel, requiring the
/// sentinel to be the line's entire (trimmed) content — not a substring at
/// an arbitrary column. This is the single source of truth for "is this
/// line the sentinel", shared by the finder and the exit-code parser so
/// they can no longer disagree (the prior bug: the finder matched a
/// substring at any column, but the parser only accepted a match at column
/// 0 via `strip_prefix`, so an off-column match found by the finder yielded
/// `exit_code: None`).
fn parse_sentinel_line(line: &str, sentinel_prefix: &str) -> Option<i32> {
    let trimmed = line.trim();
    let digits = trimmed.strip_prefix(sentinel_prefix)?.strip_suffix("__")?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse::<i32>().ok()
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
    lines[start..end].join("\n").trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attach_argv_builds_a_shared_session() {
        assert_eq!(
            attach_argv("main").unwrap(),
            vec!["tmux", "new-session", "-A", "-s", "main"]
        );
    }

    #[test]
    fn attach_argv_accepts_hyphens_and_underscores_after_the_first_char() {
        assert!(attach_argv("dev_1-a").is_ok());
        assert!(attach_argv("9").is_ok());
    }

    #[test]
    fn attach_argv_rejects_leading_hyphen_argument_injection() {
        // Without the leading-alphanumeric rule these become tmux FLAGS, not values:
        // `new-session -A -s -d` detaches instead of naming a session.
        assert!(attach_argv("-d").is_err());
        assert!(attach_argv("-t").is_err());
    }

    #[test]
    fn attach_argv_rejects_target_syntax() {
        // `session:window.pane` would let a caller aim at an arbitrary pane.
        assert!(attach_argv("foo:0.0").is_err());
        assert!(attach_argv("foo.0").is_err());
        assert!(attach_argv("foo:0").is_err());
    }

    #[test]
    fn attach_argv_rejects_shell_metacharacters_and_whitespace() {
        assert!(attach_argv("a b").is_err());
        assert!(attach_argv("a;rm -rf /").is_err());
        assert!(attach_argv("a$(id)").is_err());
        assert!(attach_argv("a\nb").is_err());
    }

    #[test]
    fn attach_argv_rejects_empty_and_overlong() {
        assert!(attach_argv("").is_err());
        assert!(attach_argv(&"a".repeat(65)).is_err());
        assert!(attach_argv(&"a".repeat(64)).is_ok());
    }

    #[test]
    fn attach_argv_rejects_non_ascii_alphanumerics() {
        // Unicode `is_alphanumeric` would admit these; the API layer's
        // `[a-zA-Z0-9]` check would not. Keep the two ends identical so a name
        // that passes the host never fails in the guest (or vice versa).
        assert!(attach_argv("café").is_err());
        assert!(attach_argv("Ωmega").is_err());
    }

    // ------------------------------------------------------------------
    // send_and_read / capture_pane integration tests.
    //
    // These require a real `tmux` binary and are run on the Mjolnir server
    // (mjolnir-7hf). Every session name is unique per test invocation and
    // every test cleans up its own session, including on panic — see
    // `with_test_session` below. Do NOT reuse a plausible real session name
    // (e.g. "main", "dev") and never touch a session this test suite did not
    // create.
    // ------------------------------------------------------------------

    fn unique_session(case: &str) -> String {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        format!("mjtest-{case}-{nanos}")
    }

    /// Run `body` against a freshly created, uniquely named tmux session,
    /// guaranteeing the session is killed afterwards even if `body` panics
    /// (e.g. on a failed assertion). This is the only sanctioned way these
    /// tests touch tmux state on the shared server.
    async fn with_test_session<F, Fut>(case: &str, body: F)
    where
        F: FnOnce(String) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = ()> + Send + 'static,
    {
        let session = unique_session(case);
        ensure_session(&session)
            .await
            .expect("failed to create test tmux session");
        let cleanup = session.clone();
        let result = tokio::spawn(body(session)).await;
        let _ = kill_session(&cleanup).await;
        if let Err(err) = result {
            std::panic::resume_unwind(err.into_panic());
        }
    }

    /// Case: minimum latency. The 250ms poll sleep runs BEFORE the first
    /// `capture_pane`, so even a command that resolves instantly still costs
    /// at least one poll interval. Assert the floor so a future "optimize
    /// the happy path" pass sees the cost is deliberate, not accidental.
    #[test]
    fn idle_shell_detection_covers_more_than_bash() {
        // send_and_read GATES sentinel matching on this (mjolnir-xrv), so a
        // shell missing from the list makes its pane look permanently busy and
        // every call there waits out its timeout. Shared sessions are exactly
        // where a login shell is not bash, so this pins the breadth rather than
        // leaving it to be narrowed by someone tidying up.
        for shell in [
            "bash", "sh", "zsh", "dash", "ash", "busybox", "fish", "ksh", "nu",
        ] {
            assert!(
                super::is_idle_shell(shell),
                "{shell} must count as an idle shell, or send_and_read times out in its panes"
            );
        }

        // A foreground process must NOT read as idle — that is the whole gate:
        // a lookalike printed while one of these runs must not end the wait.
        for busy in ["sleep", "cargo", "vim", "ssh", "python3"] {
            assert!(!super::is_idle_shell(busy), "{busy} must read as busy");
        }
    }

    #[tokio::test]
    async fn instant_command_still_costs_the_250ms_poll_floor() {
        with_test_session("latency", |session| async move {
            let result = send_and_read(&session, "true", 5_000, "sidLatency")
                .await
                .expect("send_and_read failed");
            assert!(!result.timed_out);
            assert_eq!(result.exit_code, Some(0));
            assert!(
                result.duration_ms >= 250,
                "expected the 250ms poll floor to apply even to an instant command, got {}ms",
                result.duration_ms
            );
        })
        .await;
    }

    /// Case: timeout leaves the command running. `send_and_read` must report
    /// `timed_out: true, exit_code: None` and return — WITHOUT waiting for
    /// the still-running command. A subsequent call on the same session,
    /// keyed by a different sentinel id, must resolve on its OWN sentinel
    /// and not be confused by the first command's sentinel landing later.
    #[tokio::test]
    async fn timeout_leaves_command_running_and_next_call_ignores_stale_sentinel() {
        with_test_session("timeout", |session| async move {
            // Resolves well after our 500ms timeout.
            let slow = send_and_read(&session, "sleep 2; echo SLOW_DONE", 500, "sidTimeoutSlow")
                .await
                .expect("send_and_read failed");
            assert!(slow.timed_out, "expected the slow command to time out");
            assert_eq!(slow.exit_code, None);

            // Issued immediately after, on the same session, while the slow
            // command above is still running in the background pane. Its own
            // sentinel must be found without tripping over the stale one.
            let fast = send_and_read(&session, "echo FAST_DONE", 5_000, "sidTimeoutFast")
                .await
                .expect("send_and_read failed");
            assert!(!fast.timed_out);
            assert_eq!(fast.exit_code, Some(0));
            assert!(
                fast.output.contains("FAST_DONE"),
                "expected FAST_DONE in output, got: {:?}",
                fast.output
            );

            // Let the slow command's now-stale sentinel land before the
            // session is torn down, so it doesn't leak into another test.
            tokio::time::sleep(std::time::Duration::from_millis(2_000)).await;
        })
        .await;
    }

    /// Case: two concurrent in-process `send_and_read` calls on the SAME
    /// session must not interleave sentinels — this is exactly what the
    /// per-session mutex (SESSION_LOCKS, tmux.rs:85) guarantees. It does NOT
    /// guarantee anything against a human typing in the same shared pane
    /// over a PTY concurrently (a different, cross-process actor) — that gap
    /// is a known, out-of-scope design limitation, not something this test
    /// exercises or fixes.
    #[tokio::test]
    async fn concurrent_send_and_read_on_same_session_do_not_interleave() {
        with_test_session("concurrent", |session| async move {
            let s1 = session.clone();
            let s2 = session.clone();
            let (r1, r2) = tokio::join!(
                send_and_read(&s1, "sh -c 'echo AAA; exit 7'", 5_000, "sidConcA"),
                send_and_read(&s2, "sh -c 'echo BBB; exit 9'", 5_000, "sidConcB"),
            );
            let r1 = r1.expect("first concurrent send_and_read failed");
            let r2 = r2.expect("second concurrent send_and_read failed");

            assert!(!r1.timed_out);
            assert!(!r2.timed_out);
            assert_eq!(r1.exit_code, Some(7));
            assert_eq!(r2.exit_code, Some(9));
            assert!(
                r1.output.contains("AAA"),
                "expected AAA in first output, got: {:?}",
                r1.output
            );
            assert!(
                r2.output.contains("BBB"),
                "expected BBB in second output, got: {:?}",
                r2.output
            );
        })
        .await;
    }

    /// Case: `capture_pane` is called with a 1000-line scrollback cap. A
    /// command emitting more than that silently truncates. This does not
    /// change production behavior — it makes the truncation visible in a
    /// test rather than undocumented.
    #[tokio::test]
    async fn capture_pane_truncates_deep_scrollback_silently() {
        with_test_session("truncate", |session| async move {
            // Make sure tmux's own history-limit isn't the bottleneck —
            // we want to characterize capture_pane's own "-1000" cap.
            Command::new("tmux")
                .args(["set-option", "-t", &session, "history-limit", "5000"])
                .output()
                .await
                .expect("failed to raise history-limit");

            let result = send_and_read(&session, "seq 1 1500", 10_000, "sidTrunc")
                .await
                .expect("send_and_read failed");
            assert!(!result.timed_out);

            // capture_pane's "-S -1000" cap is measured in tmux screen rows
            // from the bottom, which includes prompt/echo chrome in addition
            // to plain `seq` output lines — so the exact count isn't 1000 on
            // the nose. What matters is that the cap actually bites: 1500
            // lines of output must not all survive.
            let captured_lines = result.output.lines().count();
            assert!(
                captured_lines < 1500,
                "expected capture_pane's 1000-line cap to truncate 1500 lines of output, got {} lines",
                captured_lines
            );
            // No truncation marker exists: the earliest lines of `seq 1 1500`
            // (starting at "1") are simply gone rather than replaced with a
            // "N lines truncated" notice. Assert that silently-dropped shape.
            assert_ne!(
                result.output.lines().next(),
                Some("1"),
                "expected the earliest output lines to have been silently dropped"
            );
        })
        .await;
    }

    /// Case: sentinel discrimination. A command whose OWN pane text (typed
    /// echo or literal stdout) contains a string shaped exactly like the
    /// RESOLVED sentinel (`__MJOLNIR_DONE_<id>_<digits>__`) — using the same
    /// sentinel id — must not be mistaken for the real sentinel that
    /// send_and_read appends and that only appears once the whole command
    /// finishes.
    ///
    /// FIXED (mjolnir-xrv): send_and_read now gates a sentinel match on the
    /// pane being back at an idle shell prompt (`capture_pane`'s
    /// `running_command == None`, from `#{pane_current_command}`), not on
    /// text shape alone. A lookalike printed by the command's own output
    /// while it is still running (e.g. mid-`sleep`) cannot satisfy that gate
    /// — `pane_current_command` reports the foreground process (e.g.
    /// "sleep") until the command truly finishes and the shell returns,
    /// which is exactly when our appended sentinel echo has also run.
    #[tokio::test]
    async fn sentinel_discrimination_ignores_lookalike_resolved_shapes_in_own_output() {
        with_test_session("sentdisc", |session| async move {
            let sentinel_id = format!(
                "sd{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            );
            let lookalike_prefix = format!("__MJOLNIR_DONE_{}_", sentinel_id);

            // Prints a RESOLVED-shaped lookalike ("...999__") immediately,
            // then sleeps well past the first 250ms poll, then truly
            // finishes with exit code 0. If discrimination worked, the
            // result must reflect the REAL completion (exit 0, duration
            // >= ~1s), not the early lookalike (exit 999, duration ~250ms).
            let command = format!("printf '%s999__\\n' '{lookalike_prefix}'; sleep 1; true");

            let result = send_and_read(&session, &command, 5_000, &sentinel_id)
                .await
                .expect("send_and_read failed");

            assert!(!result.timed_out);
            assert_eq!(
                result.exit_code,
                Some(0),
                "sentinel discrimination failed: matched the lookalike '999__' line \
                 instead of waiting for the real sentinel (duration_ms={})",
                result.duration_ms
            );
            assert!(
                result.duration_ms >= 900,
                "expected to wait for the real completion (~1s sleep), got {}ms — \
                 returned early on the lookalike sentinel",
                result.duration_ms
            );
        })
        .await;
    }
}

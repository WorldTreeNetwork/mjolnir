//! Server administration commands.
//!
//! All commands in this module are synchronous — they shell out to `ssh` or `rsync`
//! and wait for the child process. This is intentional: calling sync code from an
//! async main() blocks the tokio runtime, which is fine for a CLI with no concurrent work.

use anyhow::{bail, Context, Result};
use clap::Subcommand;
use std::path::PathBuf;

use crate::config::Profile;

#[derive(Subcommand)]
pub enum ServerCommand {
    /// Bootstrap a fresh Linux server with Mjolnir
    Setup {
        /// SSH host (user@ip). Uses profile host if not specified.
        host: Option<String>,
        #[arg(long)]
        skip_firecracker: bool,
        #[arg(long)]
        use_loopback: bool,
        #[arg(long)]
        skip_rootfs: bool,
    },
    /// Deploy code to the server
    Deploy {
        #[arg(long)]
        agent: bool,
        #[arg(long)]
        iroh: bool,
        #[arg(long)]
        rootfs: bool,
    },
    /// Show mjolnir service status
    Status,
    /// Show mjolnir service logs
    Logs {
        #[arg(long)]
        follow: bool,
        #[arg(short, default_value = "100")]
        n: u32,
    },
    /// Restart mjolnir service
    Restart,
    /// Start mjolnir service
    Start,
    /// Stop mjolnir service
    Stop,
    /// Attach to remote IEx console
    Shell,
    /// SSH into the server
    Ssh,
    /// Show VM networking status (TAPs, NAT, forwarding)
    Networking,
    /// Rebuild guest agent on the server
    BuildAgent {
        #[arg(long)]
        iroh: bool,
    },
}

/// Dispatch a server subcommand using the given profile for host resolution.
pub fn run(cmd: ServerCommand, profile: &Profile) -> Result<()> {
    let host = crate::config::resolve_host(&None, profile)?;

    match cmd {
        ServerCommand::Status => ssh(&host, "systemctl status mjolnir --no-pager"),

        ServerCommand::Logs { follow, n } => {
            if follow {
                ssh_interactive(&host, "journalctl -u mjolnir -f")
            } else {
                ssh(&host, &format!("journalctl -u mjolnir -n {} --no-pager", n))
            }
        }

        ServerCommand::Restart => ssh(&host, "systemctl restart mjolnir"),

        ServerCommand::Start => ssh(&host, "systemctl start mjolnir"),

        ServerCommand::Stop => ssh(&host, "systemctl stop mjolnir"),

        ServerCommand::Shell => cmd_remote_shell(&host),

        ServerCommand::Ssh => ssh_interactive(&host, ""),

        ServerCommand::Networking => ssh(
            &host,
            "echo '=== IP Forwarding ===' && cat /proc/sys/net/ipv4/ip_forward \
             && echo '=== NAT Rules ===' && iptables -t nat -L -n --line-numbers 2>/dev/null || true \
             && echo '=== TAP Interfaces ===' && ip link show | grep -E 'mj-|tap' || true",
        ),

        ServerCommand::BuildAgent { iroh } => {
            let cmd_str = if iroh {
                "./scripts/build-guest-agent.sh --iroh".to_string()
            } else {
                "./scripts/build-guest-agent.sh".to_string()
            };
            ssh(&host, &cmd_str)
        }

        ServerCommand::Setup {
            host: host_override,
            skip_firecracker,
            use_loopback,
            skip_rootfs,
        } => {
            let effective_host = host_override.unwrap_or(host);
            cmd_setup(
                &effective_host,
                profile,
                skip_firecracker,
                use_loopback,
                skip_rootfs,
            )
        }

        ServerCommand::Deploy {
            agent,
            iroh,
            rootfs,
        } => cmd_deploy(&host, agent, iroh, rootfs),
    }
}

/// Run an SSH command non-interactively, inheriting stdout/stderr, checking exit code.
fn ssh(host: &str, cmd: &str) -> Result<()> {
    let status = std::process::Command::new("ssh")
        .args([host, cmd])
        .status()
        .with_context(|| format!("Failed to run ssh {}", host))?;

    if !status.success() {
        bail!(
            "ssh command failed with exit code {}",
            status.code().unwrap_or(-1)
        );
    }
    Ok(())
}

/// Run an interactive SSH session, replacing this process on Unix.
///
/// On Unix, uses `exec()` to replace the current process.
/// On Windows, spawns ssh.exe and waits.
fn ssh_interactive(host: &str, cmd: &str) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let mut command = std::process::Command::new("ssh");
        command.arg("-t").arg(host);
        if !cmd.is_empty() {
            command.arg(cmd);
        }
        let err = command.exec();
        bail!("Failed to exec ssh: {}", err);
    }

    #[cfg(windows)]
    {
        let mut args = vec!["-t".to_string(), host.to_string()];
        if !cmd.is_empty() {
            args.push(cmd.to_string());
        }
        let status = std::process::Command::new("ssh.exe")
            .args(&args)
            .status()
            .with_context(|| format!("Failed to run ssh.exe {}", host))?;
        std::process::exit(status.code().unwrap_or(1));
    }
}

/// Attach to the remote IEx shell, falling back to tmux.
fn cmd_remote_shell(host: &str) -> Result<()> {
    let script = "if [ -x /opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir ]; then \
                  /opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir remote; \
                  else echo 'Release binary not found, trying tmux...' && tmux attach -t 0; \
                  fi";
    ssh_interactive(host, script)
}

/// Walk up from `start` looking for a directory containing both `mix.exs` and `native/`.
fn find_project_root() -> Result<PathBuf> {
    // First try: walk up from CWD.
    if let Ok(cwd) = std::env::current_dir() {
        if let Some(root) = walk_up_for_project(&cwd, 16) {
            return Ok(root);
        }
    }

    // Second try: walk up from the binary's location.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            if let Some(root) = walk_up_for_project(exe_dir, 6) {
                return Ok(root);
            }
        }
    }

    bail!(
        "Could not find project root (directory containing both mix.exs and native/). \
         Run this command from within the Mjolnir source tree."
    )
}

fn walk_up_for_project(start: &std::path::Path, max_levels: usize) -> Option<PathBuf> {
    let mut current = start.to_path_buf();
    for _ in 0..max_levels {
        if current.join("mix.exs").exists() && current.join("native").exists() {
            return Some(current);
        }
        if !current.pop() {
            break;
        }
    }
    None
}

/// Bootstrap a fresh server by rsyncing the project and running bootstrap-host.sh.
fn cmd_setup(
    host: &str,
    profile: &Profile,
    skip_firecracker: bool,
    use_loopback: bool,
    skip_rootfs: bool,
) -> Result<()> {
    let source = profile
        .setup_source
        .as_deref()
        .unwrap_or("local");

    if source != "local" {
        bail!("Unsupported setup_source '{}'. Only 'local' is supported.", source);
    }

    let project_root = find_project_root()?;
    let project_root_str = project_root.to_string_lossy();

    // rsync the project to /opt/mjolnir/ on the server.
    let rsync_src = format!("{}/", project_root_str);
    let rsync_dst = format!("{}:/opt/mjolnir/", host);

    eprintln!("Syncing {} -> {}...", rsync_src, rsync_dst);

    let rsync_status = std::process::Command::new("rsync")
        .args([
            "-avz",
            "--delete",
            "--filter=:- .gitignore",
            "--exclude=.git",
            &rsync_src,
            &rsync_dst,
        ])
        .status()
        .context("Failed to run rsync")?;

    if !rsync_status.success() {
        bail!(
            "rsync failed with exit code {}",
            rsync_status.code().unwrap_or(-1)
        );
    }

    // Build environment variable prefix for the bootstrap script.
    let mut env_parts = Vec::new();
    if skip_firecracker {
        env_parts.push("SKIP_FIRECRACKER=1");
    }
    if use_loopback {
        env_parts.push("USE_LOOPBACK=1");
    }
    if skip_rootfs {
        env_parts.push("SKIP_ROOTFS=1");
    }
    let env_prefix = if env_parts.is_empty() {
        String::new()
    } else {
        format!("{} ", env_parts.join(" "))
    };

    let bootstrap_cmd = format!(
        r#"export PATH="$HOME/.local/bin:$PATH" && \
command -v mise >/dev/null 2>&1 && mise trust /opt/mjolnir/.mise.toml 2>/dev/null; \
cd /opt/mjolnir && {}./scripts/bootstrap-host.sh"#,
        env_prefix
    );

    ssh_interactive(host, &bootstrap_cmd)
}

/// Deploy by running scripts/deploy.sh locally.
fn cmd_deploy(host: &str, agent: bool, iroh: bool, rootfs: bool) -> Result<()> {
    let project_root = find_project_root()?;
    let deploy_script = project_root.join("scripts/deploy.sh");

    let mut args = vec![
        deploy_script.to_string_lossy().to_string(),
        host.to_string(),
    ];
    if agent {
        args.push("--agent".to_string());
    }
    if iroh {
        args.push("--iroh".to_string());
    }
    if rootfs {
        args.push("--rootfs".to_string());
    }

    eprintln!("Running deploy: bash {}", args.join(" "));

    let status = std::process::Command::new("bash")
        .args(&args)
        .status()
        .context("Failed to run deploy script")?;

    if !status.success() {
        bail!(
            "deploy script failed with exit code {}",
            status.code().unwrap_or(-1)
        );
    }
    Ok(())
}

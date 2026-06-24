//! Mjolnir CLI — VM control plane.
//!
//! Usage:
//!   mjolnir login --api https://mjolnir.example.com   # authenticate + save API
//!   mjolnir spawn                                      # spawn a VM, print ticket
//!   mjolnir list                                       # list your VMs
//!   mjolnir connect <id|ticket>                        # shell (id→gateway, ticket→P2P)
//!   mjolnir ssh <id|ticket>                            # SSH over the Iroh tunnel
//!   mjolnir exec <id> <cmd>                            # run a command in a VM
//!   mjolnir server status                              # show server status
//!   mjolnir config                                     # show config

mod api;
mod auth;
mod config;
mod connect;
mod forge;
mod forge_tui;
mod mcp;
mod server;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "mjolnir", about = "Mjolnir — VM control plane", version)]
struct Cli {
    /// Profile to use (from ~/.config/mjolnir/profiles.toml)
    #[arg(long, global = true, env = "MJOLNIR_PROFILE")]
    profile: Option<String>,

    /// Emit raw JSON instead of formatted output (where supported)
    #[arg(long, global = true)]
    json: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    // --- VM Operations ---
    /// Spawn a new VM
    #[command(next_help_heading = "VM Operations")]
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
    /// List running VMs
    List {
        /// Also list dormant (parked) VMs
        #[arg(long)]
        dormant: bool,
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
    /// Execute a command in a VM
    Exec {
        /// VM ID or ticket
        id: String,
        /// Command to execute
        cmd: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Stop and destroy a VM (or all with --all)
    Kill {
        /// VM ID or ticket
        id: Option<String>,
        /// Stop every running VM
        #[arg(long)]
        all: bool,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Retire a stranded VM to state=failed so it stops auto-resuming
    Retire {
        /// VM ID or ticket
        id: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Revive a failed VM back to running so Reconcile resumes it
    Revive {
        /// VM ID or ticket
        id: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Permanently dispose of a failed VM (soft-delete rootfs to @trash)
    Forget {
        /// VM ID or ticket
        id: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Send a JSON payload into a VM (wakes a dormant VM)
    Message {
        /// VM ID or ticket
        id: String,
        /// JSON payload, e.g. '{"key":"val"}'
        payload: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Diagnose VM/host health; --fix to repair
    Doctor {
        /// VM ID or ticket (omit to check API + host)
        id: Option<String>,
        /// Repair degraded/dead checks (heal)
        #[arg(long)]
        fix: bool,
        /// Cap the heal level (VM only; default 2)
        #[arg(long)]
        max_level: Option<u32>,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    // --- Connections ---
    /// Open an interactive shell (VM id → gateway WebSocket, ticket → P2P)
    #[command(next_help_heading = "Connections")]
    Connect {
        /// VM ID or ticket
        target: String,
        /// Force a direct peer-to-peer (Iroh) connection even for a VM id
        #[arg(long)]
        p2p: bool,
        /// Attach to a named tmux session inside the VM
        #[arg(long)]
        session: Option<String>,
        /// Relay URL hint (P2P only)
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s) for hole-punching (P2P only; ip:port, repeatable)
        #[arg(long)]
        ip: Vec<String>,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// SSH into a VM over the Iroh tunnel
    Ssh {
        /// VM ID or ticket
        target: String,
        /// SSH user (default: root)
        #[arg(long, default_value = "root")]
        user: String,
        /// Relay URL hint
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s)
        #[arg(long)]
        ip: Vec<String>,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
        /// Extra args passed to ssh
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        ssh_args: Vec<String>,
    },
    /// TCP proxy to a VM over the Iroh tunnel (for ssh ProxyCommand)
    Proxy {
        /// VM ID or ticket
        target: String,
        /// Target port on the guest (default: 22)
        #[arg(long, default_value = "22")]
        port: u16,
        /// Relay URL hint
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s)
        #[arg(long)]
        ip: Vec<String>,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Get the web gateway URL for a VM
    Url {
        /// VM ID or ticket
        id: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
        /// Show URL for a specific port
        #[arg(long)]
        port: Option<u16>,
    },
    /// Fetch or convert connection tickets
    Ticket {
        #[command(subcommand)]
        action: TicketAction,
    },

    // --- Snapshots ---
    /// Manage snapshots (create / list / show / rm)
    #[command(next_help_heading = "Snapshots")]
    Snapshot {
        #[command(subcommand)]
        action: SnapshotAction,
    },

    // --- Auth ---
    /// Authenticate with the Mjolnir identity provider
    #[command(next_help_heading = "Auth")]
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

    // --- Config ---
    /// View or update configuration
    #[command(next_help_heading = "Config")]
    Config {
        #[command(subcommand)]
        action: Option<ConfigAction>,
    },

    // --- Integrations ---
    /// Run MCP server over stdio (for Claude Code integration)
    #[command(name = "mcp-serve", next_help_heading = "Integrations")]
    McpServe {
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
    },

    // --- Forge (host config reconciler) ---
    /// Host configuration reconciler
    #[command(next_help_heading = "Forge (host config)")]
    Forge {
        #[command(subcommand)]
        cmd: ForgeCmd,
    },

    // --- Server admin ---
    /// Server administration (SSH)
    #[command(next_help_heading = "Server")]
    Server {
        #[command(subcommand)]
        action: server::ServerCommand,
    },
}

#[derive(Subcommand)]
enum SnapshotAction {
    /// Checkpoint a running VM
    Create {
        /// VM ID or ticket
        id: String,
        /// Snapshot name
        name: String,
        /// Compact the snapshot (reclaim freed blocks)
        #[arg(long)]
        compact: bool,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// List available snapshots
    List {
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Show metadata for a snapshot
    Show {
        /// Snapshot name
        name: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Delete a snapshot
    Rm {
        /// Snapshot name
        name: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
}

#[derive(Subcommand)]
enum ConfigAction {
    /// Set a config value
    Set {
        /// Config key (e.g. "api", "host", "ssh_key")
        key: String,
        /// Value to set
        value: String,
    },
    /// List all profiles
    Profiles,
}

#[derive(Subcommand)]
enum TicketAction {
    /// Fetch a VM's connection ticket (--wait blocks for PTY readiness)
    Get {
        /// VM ID or ticket
        id: String,
        /// Block until the PTY is ready before returning
        #[arg(long)]
        wait: bool,
        /// Timeout in ms when waiting (default: 30000)
        #[arg(long)]
        timeout: Option<u64>,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Decode iroh JSON to compact ticket (z32)
    Decode {
        /// Iroh JSON EndpointAddr string
        json: String,
    },
    /// Encode compact ticket to iroh JSON
    Encode {
        /// z32 node ID ticket
        ticket: String,
        /// Relay URL
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s) (ip:port, repeatable)
        #[arg(long)]
        ip: Vec<String>,
    },
}

#[derive(Subcommand)]
enum ForgeCmd {
    /// Show the reconciliation plan for a host (observe + diff)
    Plan {
        /// Forge host name
        #[arg(long)]
        host: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Apply pending changes for a host
    Apply {
        /// Forge host name
        #[arg(long)]
        host: String,
        /// Skip confirmation prompt
        #[arg(long)]
        yes: bool,
        /// Apply all safe (non-destructive) changes
        #[arg(long)]
        all_safe: bool,
        /// Apply a specific resource (KIND/ID, e.g. tap/mj-abc123)
        #[arg(long)]
        resource: Option<String>,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Show stored reconciliation state
    State {
        /// Filter by host
        #[arg(long)]
        host: Option<String>,
        /// Filter by resource kind
        #[arg(long)]
        kind: Option<String>,
        /// Filter by status
        #[arg(long)]
        status: Option<String>,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Show or follow the reconciliation event/audit feed
    Events {
        /// Follow live events (SSE stream) instead of printing a snapshot
        #[arg(long)]
        tail: bool,
        /// Resume cursor — only events after this id
        #[arg(long)]
        since: Option<String>,
        /// Max events to show in snapshot mode (ignored with --tail)
        #[arg(long)]
        limit: Option<u32>,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Manage forge hosts
    Hosts {
        #[command(subcommand)]
        cmd: HostsCmd,
    },
    /// Launch the interactive forge TUI
    Tui {
        /// Forge host name
        #[arg(long, default_value = "self")]
        host: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
}

#[derive(Subcommand)]
enum HostsCmd {
    /// List all forge hosts
    List {
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// Register a new forge host
    Add {
        /// Host name (e.g. "self" or "root@1.2.3.4")
        host: String,
        /// Transport type: local or ssh
        #[arg(long, default_value = "local")]
        transport: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
}

// --- Main ---

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let profile = config::resolve_profile(&cli.profile);
    let json = cli.json;

    let result: anyhow::Result<()> = match cli.command {
        // --- VM Operations ---
        Command::Spawn {
            api,
            connect,
            token,
            memory,
            snapshot,
        } => api::cmd_spawn(&profile, &api, &token, connect, &memory, &snapshot).await,
        Command::List {
            dormant,
            api,
            token,
        } => api::cmd_list(&profile, &api, &token, dormant, json).await,
        Command::Info { id, api, token } => api::cmd_info(&profile, &api, &token, &id, json).await,
        Command::Exec {
            id,
            cmd,
            api,
            token,
        } => api::cmd_exec(&profile, &api, &token, &id, &cmd).await,
        Command::Kill {
            id,
            all,
            api,
            token,
        } => {
            if all {
                api::cmd_kill_all(&profile, &api, &token).await
            } else {
                match id {
                    Some(id) => api::cmd_kill(&profile, &api, &token, &id).await,
                    None => Err(anyhow::anyhow!("provide a VM id or --all")),
                }
            }
        }
        Command::Retire { id, api, token } => api::cmd_retire(&profile, &api, &token, &id).await,
        Command::Revive { id, api, token } => api::cmd_revive(&profile, &api, &token, &id).await,
        Command::Forget { id, api, token } => api::cmd_forget(&profile, &api, &token, &id).await,
        Command::Message {
            id,
            payload,
            api,
            token,
        } => api::cmd_message(&profile, &api, &token, &id, &payload, json).await,
        Command::Doctor {
            id,
            fix,
            max_level,
            api,
            token,
        } => match id {
            Some(id) => api::cmd_doctor(&profile, &api, &token, &id, fix, max_level, json).await,
            None => api::cmd_doctor_host(&profile, &api, &token, fix, json).await,
        },
        Command::Url {
            id,
            api,
            token,
            port,
        } => api::cmd_url(&profile, &api, &token, &id, port).await,

        // --- Connections ---
        Command::Connect {
            target,
            p2p,
            session,
            relay,
            ip,
            api,
            token,
        } => connect::cmd_shell(&profile, &api, &token, &target, p2p, session, relay, &ip).await,
        Command::Ssh {
            target,
            user,
            relay,
            ip,
            api,
            token,
            ssh_args,
        } => {
            connect::cmd_ssh_target(
                &profile, &api, &token, &target, &user, relay, &ip, &ssh_args,
            )
            .await
        }
        Command::Proxy {
            target,
            port,
            relay,
            ip,
            api,
            token,
        } => connect::cmd_proxy_target(&profile, &api, &token, &target, port, relay, &ip).await,

        // --- Snapshots ---
        Command::Snapshot { action } => match action {
            SnapshotAction::Create {
                id,
                name,
                compact,
                api,
                token,
            } => api::cmd_snapshot_create(&profile, &api, &token, &id, &name, compact, json).await,
            SnapshotAction::List { api, token } => {
                api::cmd_snapshots(&profile, &api, &token, json).await
            }
            SnapshotAction::Show { name, api, token } => {
                api::cmd_snapshot_show(&profile, &api, &token, &name, json).await
            }
            SnapshotAction::Rm { name, api, token } => {
                api::cmd_snapshot_rm(&profile, &api, &token, &name, json).await
            }
        },

        // --- Auth ---
        Command::Login { issuer, api } => {
            if let Some(ref url) = api {
                if let Err(e) = config::set("api", url) {
                    eprintln!("Warning: failed to save API config: {}", e);
                }
            }
            auth::login(issuer).await
        }
        Command::Logout => auth::logout(),
        Command::Status => {
            config::show();
            auth::status()
        }

        // --- Config ---
        Command::Config { action } => match action {
            Some(ConfigAction::Set { key, value }) => {
                let profile_name = cli.profile.as_deref().unwrap_or("default");
                config::set_in(profile_name, &key, &value)
            }
            Some(ConfigAction::Profiles) => {
                config::show_profiles();
                Ok(())
            }
            None => {
                config::show();
                Ok(())
            }
        },

        // --- Ticket ---
        Command::Ticket { action } => match action {
            TicketAction::Get {
                id,
                wait,
                timeout,
                api,
                token,
            } => api::cmd_ticket_get(&profile, &api, &token, &id, wait, timeout, json).await,
            TicketAction::Decode { json } => {
                match serde_json::from_str::<iroh::EndpointAddr>(&json) {
                    Ok(addr) => {
                        println!("{}", connect::format_addr_info(&addr));
                        Ok(())
                    }
                    Err(e) => {
                        eprintln!("Failed to parse iroh JSON: {}", e);
                        std::process::exit(1);
                    }
                }
            }
            TicketAction::Encode { ticket, relay, ip } => {
                match connect::resolve_addr(&ticket, relay, &ip) {
                    Ok(addr) => {
                        println!("{}", serde_json::to_string(&addr).unwrap());
                        Ok(())
                    }
                    Err(e) => Err(e),
                }
            }
        },

        // --- MCP server ---
        Command::McpServe { api } => {
            let profile_name = cli.profile.as_deref().unwrap_or("default");
            mcp::run_mcp_server(profile_name, &profile, &api).await
        }

        // --- Forge ---
        Command::Forge { cmd } => match cmd {
            ForgeCmd::Plan { host, api, token } => {
                match forge::plan(api, token, host, &profile).await {
                    Ok(all_converged) => {
                        if all_converged {
                            Ok(())
                        } else {
                            std::process::exit(1);
                        }
                    }
                    Err(e) => Err(e),
                }
            }
            ForgeCmd::Apply {
                host,
                yes,
                all_safe,
                resource,
                api,
                token,
            } => match forge::apply(api, token, host, yes, all_safe, resource, &profile).await {
                Ok(all_ok) => {
                    if all_ok {
                        Ok(())
                    } else {
                        std::process::exit(2);
                    }
                }
                Err(e) => Err(e),
            },
            ForgeCmd::State {
                host,
                kind,
                status,
                api,
                token,
            } => forge::state(api, token, host, kind, status, &profile).await,
            ForgeCmd::Events {
                tail,
                since,
                limit,
                api,
                token,
            } => {
                if tail {
                    forge::events_tail(api, token, since, &profile).await
                } else {
                    forge::events(api, token, since, limit, &profile).await
                }
            }
            ForgeCmd::Hosts { cmd } => match cmd {
                HostsCmd::List { api, token } => forge::hosts_list(api, token, &profile).await,
                HostsCmd::Add {
                    host,
                    transport,
                    api,
                    token,
                } => forge::hosts_add(api, token, host, transport, &profile).await,
            },
            ForgeCmd::Tui { host, api, token } => forge_tui::run(api, token, host, &profile).await,
        },

        // --- Server admin (sync — blocks tokio runtime, which is fine for CLI) ---
        Command::Server { action } => server::run(action, &profile),
    };

    if let Err(e) = result {
        eprintln!("Error: {:?}", e);
        std::process::exit(1);
    }
}

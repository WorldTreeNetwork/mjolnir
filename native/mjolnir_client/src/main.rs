//! Mjolnir CLI — VM control plane.
//!
//! Usage:
//!   mjolnir login --api https://mjolnir.example.com   # authenticate + save API
//!   mjolnir spawn                                      # spawn a VM, print ticket
//!   mjolnir list                                       # list your VMs
//!   mjolnir connect <id>                               # connect to a VM PTY
//!   mjolnir iroh connect <ticket>                      # connect via Iroh QUIC
//!   mjolnir exec <id> <cmd>                            # run a command in a VM
//!   mjolnir server status                              # show server status
//!   mjolnir config                                     # show config

mod api;
mod auth;
mod config;
mod connect;
mod mcp;
mod server;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "mjolnir", about = "Mjolnir — VM control plane", version)]
struct Cli {
    /// Profile to use (from ~/.config/mjolnir/profiles.toml)
    #[arg(long, global = true, env = "MJOLNIR_PROFILE")]
    profile: Option<String>,

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

    // --- Connections ---
    /// Connect to a VM terminal (WebSocket PTY)
    #[command(next_help_heading = "Connections")]
    Connect {
        /// VM ID (UUID)
        id: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// P2P connections via Iroh QUIC
    Iroh {
        #[command(subcommand)]
        action: IrohCommand,
    },

    // --- Hidden backward-compat aliases ---
    /// Connect to VM shell via Iroh (use 'iroh connect' instead)
    #[command(hide = true)]
    Shell {
        /// Ticket (z32 node ID), hex node ID, or full iroh JSON
        ticket: String,
        /// Relay URL hint
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s) (ip:port, repeatable)
        #[arg(long)]
        ip: Vec<String>,
    },
    /// Connect to VM PTY (use 'connect' instead)
    #[command(hide = true)]
    Pty {
        /// VM ID (UUID)
        id: String,
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
    },
    /// SSH via Iroh (use 'iroh ssh' instead)
    #[command(hide = true, name = "ssh")]
    SshAlias {
        /// Ticket
        ticket: String,
        /// SSH user (default: root)
        #[arg(long, default_value = "root")]
        user: String,
        /// Relay URL hint
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s)
        #[arg(long)]
        ip: Vec<String>,
        /// Extra args passed to ssh
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        ssh_args: Vec<String>,
    },
    /// TCP proxy via Iroh (use 'iroh proxy' instead)
    #[command(hide = true, name = "proxy")]
    ProxyAlias {
        /// Ticket
        ticket: String,
        /// Target port (default: 22)
        #[arg(long, default_value = "22")]
        port: u16,
        /// Relay URL hint
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s)
        #[arg(long)]
        ip: Vec<String>,
    },

    // --- Snapshots ---
    /// Create a snapshot of a running VM
    #[command(next_help_heading = "Snapshots")]
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
    /// List available snapshots
    Snapshots {
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
        /// Bearer token for API auth
        #[arg(long, env = "MJOLNIR_TOKEN")]
        token: Option<String>,
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
    /// Convert between ticket formats
    Ticket {
        #[command(subcommand)]
        action: TicketAction,
    },

    // --- Integrations ---
    /// Run MCP server over stdio (for Claude Code integration)
    #[command(name = "mcp-serve", next_help_heading = "Integrations")]
    McpServe {
        /// Mjolnir API base URL
        #[arg(long)]
        api: Option<String>,
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
enum IrohCommand {
    /// Connect to VM shell via Iroh QUIC (P2P)
    Connect {
        /// Ticket (z32 node ID), hex node ID, or full iroh JSON
        ticket: String,
        /// Relay URL hint (only needed for self-hosted relays)
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s) for faster hole-punching (ip:port, repeatable)
        #[arg(long)]
        ip: Vec<String>,
    },
    /// SSH into VM via Iroh tunnel
    Ssh {
        /// Ticket
        ticket: String,
        /// SSH user (default: root)
        #[arg(long, default_value = "root")]
        user: String,
        /// Relay URL hint
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s)
        #[arg(long)]
        ip: Vec<String>,
        /// Extra args passed to ssh
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        ssh_args: Vec<String>,
    },
    /// TCP proxy via Iroh (for ProxyCommand)
    Proxy {
        /// Ticket
        ticket: String,
        /// Target port on the guest (default: 22 for SSH)
        #[arg(long, default_value = "22")]
        port: u16,
        /// Relay URL hint
        #[arg(long)]
        relay: Option<String>,
        /// Direct IP hint(s)
        #[arg(long)]
        ip: Vec<String>,
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

// --- Main ---

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let profile = config::resolve_profile(&cli.profile);

    let result: anyhow::Result<()> = match cli.command {
        // --- VM Operations ---
        Command::Spawn {
            api,
            connect,
            token,
            memory,
            snapshot,
        } => {
            api::cmd_spawn(&profile, &api, &token, connect, &memory, &snapshot).await
        }
        Command::List { api, token } => api::cmd_list(&profile, &api, &token).await,
        Command::Info { id, api, token } => api::cmd_info(&profile, &api, &token, &id).await,
        Command::Exec { id, cmd, api, token } => {
            api::cmd_exec(&profile, &api, &token, &id, &cmd).await
        }
        Command::Kill { id, api, token } => api::cmd_kill(&profile, &api, &token, &id).await,

        // --- Connections ---
        Command::Connect { id, api, token } => {
            connect::cmd_connect(&profile, &api, &token, &id).await
        }
        Command::Iroh { action } => match action {
            IrohCommand::Connect { ticket, relay, ip } => {
                match connect::resolve_addr(&ticket, relay, &ip) {
                    Ok(addr) => connect::connect_to_vm(addr).await,
                    Err(e) => Err(e),
                }
            }
            IrohCommand::Ssh {
                ticket,
                user,
                relay,
                ip,
                ssh_args,
            } => connect::cmd_ssh(&ticket, &user, relay, &ip, &ssh_args),
            IrohCommand::Proxy {
                ticket,
                port,
                relay,
                ip,
            } => connect::cmd_proxy(&ticket, port, relay, &ip).await,
        },

        // --- Hidden backward-compat aliases ---
        Command::Shell { ticket, relay, ip } => {
            match connect::resolve_addr(&ticket, relay, &ip) {
                Ok(addr) => connect::connect_to_vm(addr).await,
                Err(e) => Err(e),
            }
        }
        Command::Pty { id, api, token } => {
            connect::cmd_connect(&profile, &api, &token, &id).await
        }
        Command::SshAlias {
            ticket,
            user,
            relay,
            ip,
            ssh_args,
        } => connect::cmd_ssh(&ticket, &user, relay, &ip, &ssh_args),
        Command::ProxyAlias {
            ticket,
            port,
            relay,
            ip,
        } => connect::cmd_proxy(&ticket, port, relay, &ip).await,

        // --- Snapshots ---
        Command::Snapshot {
            id,
            name,
            api,
            token,
            compact,
        } => api::cmd_snapshot(&profile, &api, &token, &id, &name, compact).await,
        Command::Snapshots { api, token } => api::cmd_snapshots(&profile, &api, &token).await,

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
            Some(ConfigAction::Set { key, value }) => config::set(&key, &value),
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
            TicketAction::Decode { json } => {
                match serde_json::from_str::<iroh_base::EndpointAddr>(&json) {
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
        Command::McpServe { api } => mcp::run_mcp_server(&profile, &api).await,

        // --- Server admin (sync — blocks tokio runtime, which is fine for CLI) ---
        Command::Server { action } => server::run(action, &profile),
    };

    if let Err(e) = result {
        eprintln!("Error: {:?}", e);
        std::process::exit(1);
    }
}

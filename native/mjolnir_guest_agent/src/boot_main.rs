//! Mjolnir Boot Agent
//!
//! Minimal boot agent binary compiled without the `full` feature.
//! Shares protocol, pty, and vsock modules with the full agent.
//! Provides vsock ping response (with "agent":"boot") and PTY console during initramfs boot.

mod protocol;
mod pty;
mod vsock;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    tracing::info!("Mjolnir boot agent starting");
    vsock::run_boot_listener(5000).await;
}

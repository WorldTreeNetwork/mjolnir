//! Mjolnir Boot Agent
//!
//! Minimal boot agent binary compiled without the `full` feature.
//! Shares protocol, pty, and vsock modules with the full agent.
//! Provides vsock ping response (with "agent":"boot") and PTY console during initramfs boot.

// `boot` and `full` are mutually exclusive: this binary deliberately omits the
// tmux/secrets/syslog modules that the shared vsock.rs reaches for under
// `cfg(feature = "full")`. Cargo's required-features can demand `boot` but
// cannot forbid `full`, so say it here — one sentence beats five E0433s that
// blame the crate for what is really a wrong invocation (mjolnir-ufj).
#[cfg(feature = "full")]
compile_error!(
    "mjolnir-boot-agent must be built WITHOUT the `full` feature: \
     cargo build --bin mjolnir-boot-agent --no-default-features --features boot"
);

mod protocol;
mod pty;
mod vsock;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    tracing::info!("Mjolnir boot agent starting");
    vsock::run_boot_listener(5000).await;
}

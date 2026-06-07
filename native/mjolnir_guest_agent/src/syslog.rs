//! Syslog forwarder: reads from /dev/log and sends lines to host via vsock channel 2.
//!
//! Replaces the need for a separate syslog daemon + socat. The guest agent
//! itself becomes the syslog sink, forwarding messages over the existing
//! multiplexed vsock connection using `frame_binary(SYSLOG_CHANNEL, line)`.
//!
//! Guest processes log via standard syslog(3) / logger(1) which write to
//! /dev/log. This module binds that socket and forwards each datagram as
//! a newline-terminated line on vsock channel 2.

use std::path::Path;
use tokio::net::UnixDatagram;
use tokio::sync::mpsc;
use tracing::{error, info, warn};

/// Vsock channel reserved for syslog data (matches host Syslog.Listener).
pub const SYSLOG_CHANNEL: u8 = 2;

const DEV_LOG_PATH: &str = "/dev/log";

/// Encode raw binary data into a framed wire message on a given channel.
/// Wire format: [channel:u8][length:u32 BE][payload]
fn frame_binary(channel: u8, data: &[u8]) -> Vec<u8> {
    let length = data.len() as u32;
    let mut frame = Vec::with_capacity(5 + data.len());
    frame.push(channel);
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(data);
    frame
}

/// Start the syslog forwarder.
///
/// Binds a Unix datagram socket at `/dev/log`, reads syslog messages, and
/// forwards each as a newline-terminated line on vsock channel 2 via the
/// provided `write_tx` sender.
///
/// This function runs forever (until the write channel closes or an
/// unrecoverable error occurs). Spawn it as a tokio task.
pub async fn run_syslog_forwarder(write_tx: mpsc::Sender<Vec<u8>>) {
    // Remove stale socket if it exists
    if Path::new(DEV_LOG_PATH).exists() {
        if let Err(e) = std::fs::remove_file(DEV_LOG_PATH) {
            warn!("Failed to remove stale {}: {}", DEV_LOG_PATH, e);
        }
    }

    let sock = match UnixDatagram::bind(DEV_LOG_PATH) {
        Ok(s) => s,
        Err(e) => {
            error!("Failed to bind {}: {}", DEV_LOG_PATH, e);
            return;
        }
    };

    // Make /dev/log world-writable so any process can log
    if let Err(e) = std::fs::set_permissions(
        DEV_LOG_PATH,
        std::os::unix::fs::PermissionsExt::from_mode(0o666),
    ) {
        warn!("Failed to chmod {}: {}", DEV_LOG_PATH, e);
    }

    info!("Syslog forwarder listening on {}", DEV_LOG_PATH);

    let mut buf = vec![0u8; 8192];

    loop {
        match sock.recv(&mut buf).await {
            Ok(n) if n > 0 => {
                let msg = &buf[..n];

                // Ensure message is newline-terminated for the host parser
                let frame = if msg.last() == Some(&b'\n') {
                    frame_binary(SYSLOG_CHANNEL, msg)
                } else {
                    let mut with_nl = Vec::with_capacity(n + 1);
                    with_nl.extend_from_slice(msg);
                    with_nl.push(b'\n');
                    frame_binary(SYSLOG_CHANNEL, &with_nl)
                };

                if write_tx.send(frame).await.is_err() {
                    info!("Syslog forwarder: write channel closed, exiting");
                    return;
                }
            }
            Ok(_) => {
                // Empty datagram, skip
            }
            Err(e) => {
                error!("Syslog forwarder: recv error: {}", e);
                // Brief pause to avoid tight error loop
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
    }
}

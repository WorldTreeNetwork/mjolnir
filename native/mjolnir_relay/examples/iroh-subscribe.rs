//! Iroh subscriber that reads a broadcast from a relay.
//!
//! ```text
//! iroh-subscribe read <relay-id> <token> <path> <seconds>
//! iroh-subscribe listen <relay-id> <token> <seconds>
//! ```
use std::time::Duration;

use iroh::{EndpointId, Watcher};
use iroh_live::{Node, NodeConfig, Reach, RelayConfig, RelayStatus};
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let cmd = args.next().unwrap_or_else(|| "read".into());
    let relay: EndpointId = args.next().expect("relay id").parse()?;
    let token = args.next().expect("token");
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::N0)
        .bind()
        .await?;
    let node = Node::new(endpoint, NodeConfig::default());
    let mut config = RelayConfig::iroh(relay);
    if token != "-" {
        config = config.with_token(token.parse()?);
    }
    let link = node.attach_relay(config)?;
    if !wait_connected(&link, 8).await {
        let mut status = link.status();
        println!("refused: relay link not connected status={:?}", status.get());
        std::process::exit(2);
    }
    println!("connected");
    match cmd.as_str() {
        "read" => {
            let path = args.next().expect("path");
            let seconds: u64 = args.next().unwrap_or("8".into()).parse()?;
            let subscription = node.subscribe(path.as_str(), Reach::Relays).await?;
            let broadcast = subscription.broadcast();
            let track = broadcast
                .track("bytes")
                .map_err(|err| anyhow::anyhow!("track: {err}"))?;
            let mut reader = track
                .subscribe(None)
                .await
                .map_err(|err| anyhow::anyhow!("subscribe: {err}"))?;
            let mut bytes = 0usize;
            let mut frames = 0usize;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
            while tokio::time::Instant::now() < deadline {
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                let group = tokio::time::timeout(left, reader.recv_group()).await;
                let Ok(Ok(Some(mut group))) = group else { break };
                while let Some(frame) = group
                    .read_frame()
                    .await
                    .map_err(|err| anyhow::anyhow!("frame: {err}"))?
                {
                    bytes += frame.payload.len();
                    frames += 1;
                }
            }
            println!("received path={path} frames={frames} bytes={bytes}");
        }
        "gap" => {
            let path = args.next().expect("path");
            let seconds: u64 = args.next().unwrap_or("12".into()).parse()?;
            let subscription = node.subscribe(path.as_str(), Reach::Relays).await?;
            let broadcast = subscription.broadcast();
            let track = broadcast
                .track("bytes")
                .map_err(|err| anyhow::anyhow!("track: {err}"))?;
            let mut reader = track
                .subscribe(None)
                .await
                .map_err(|err| anyhow::anyhow!("subscribe: {err}"))?;
            let mut frames = 0usize;
            let started = std::time::Instant::now();
            let mut last: Option<std::time::Instant> = None;
            let mut max_gap = Duration::ZERO;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
            while tokio::time::Instant::now() < deadline {
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                let group =
                    tokio::time::timeout(left.min(Duration::from_millis(250)), reader.recv_group())
                        .await;
                let Ok(Ok(Some(mut group))) = group else { continue };
                while let Some(frame) = group
                    .read_frame()
                    .await
                    .map_err(|err| anyhow::anyhow!("frame: {err}"))?
                {
                    let now = std::time::Instant::now();
                    if let Some(prev) = last {
                        max_gap = max_gap.max(now.saturating_duration_since(prev));
                    }
                    last = Some(now);
                    frames += 1;
                    println!(
                        "frame n={frames} t_ms={} bytes={}",
                        started.elapsed().as_millis(),
                        frame.payload.len()
                    );
                }
            }
            println!(
                "gap path={path} frames={frames} max_gap_ms={}",
                max_gap.as_millis()
            );
        }
        "listen" => {
            let seconds: u64 = args.next().unwrap_or("6".into()).parse()?;
            let mut announced = node.origin().announced();
            let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
            let mut count = 0usize;
            while tokio::time::Instant::now() < deadline {
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                match tokio::time::timeout(left, announced.next()).await {
                    Ok(Some(event)) => {
                        count += 1;
                        println!("announce: {event:?}");
                    }
                    _ => break,
                }
            }
            println!("announcements={count}");
        }
        other => anyhow::bail!("unknown command {other}"),
    }
    link.detach().await;
    node.shutdown().await;
    Ok(())
}

async fn wait_connected(link: &iroh_live::RelayLink, seconds: u64) -> bool {
    let mut status = link.status();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
    while tokio::time::Instant::now() < deadline {
        if status.get() == RelayStatus::Connected {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    status.get() == RelayStatus::Connected
}
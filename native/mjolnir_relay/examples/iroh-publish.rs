//! Iroh publisher that attaches to a relay with a token.
//!
//! ```text
//! iroh-publish publish <relay-id> <token> <path> <seconds>
//! iroh-publish placeholder <relay-id> <token> <seconds>
//! iroh-publish notoken <relay-id> [path]
//! ```
//!
//! `path` is relative to the token root. `-` is no token. `self` is this
//! client's own endpoint id, used as the session path.
use std::time::Duration;

use iroh::{EndpointId, Watcher};
use iroh_live::{Audience, Node, NodeConfig, RelayConfig, RelayStatus};
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let cmd = args.next().unwrap_or_else(|| "publish".into());
    let relay: EndpointId = args.next().expect("relay id").parse()?;
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::N0)
        .bind()
        .await?;
    let own = endpoint.id();
    println!("client-endpoint={own}");
    let node = Node::new(endpoint, NodeConfig::default());
    match cmd.as_str() {
        "publish" => {
            let token = args.next().expect("token");
            let path = args.next().expect("path");
            let seconds: u64 = args.next().unwrap_or("8".into()).parse()?;
            let mut config = RelayConfig::iroh(relay).with_consume(false);
            if token != "-" {
                config = config.with_token(token.parse()?);
            }
            let link = node.attach_relay(config)?;
            if !wait_connected(&link, 8).await {
                println!("refused: relay link not connected");
                std::process::exit(2);
            }
            println!("connected");
            let publication = node.publish(path.as_str(), Audience::Granted)?;
            let track = publication
                .broadcast()
                .create_track("bytes", timed())
                .map_err(|err| anyhow::anyhow!("{err}"))?;
            let mut sent = 0usize;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
            while tokio::time::Instant::now() < deadline {
                let mut group = track
                    .append_group(now())
                    .map_err(|err| anyhow::anyhow!("{err}"))?;
                let payload = b"mjolnir-relay-frame".to_vec();
                sent += payload.len();
                group
                    .write_frame(now(), payload)
                    .map_err(|err| anyhow::anyhow!("{err}"))?;
                group.finish().map_err(|err| anyhow::anyhow!("{err}"))?;
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            println!("published path={path} bytes={sent}");
            link.detach().await;
        }
        // Publishes the reserved top-level name. The grant's stand-in is a
        // random child of this name that the client is not given.
        "placeholder" => {
            let token = args.next().expect("token");
            let seconds: u64 = args.next().unwrap_or("4".into()).parse()?;
            let path = mjolnir_relay::NO_PUBLISH_SEGMENT;
            let mut config = RelayConfig::iroh(relay).with_consume(false);
            config = config.with_token(token.parse()?);
            let link = node.attach_relay(config)?;
            if !wait_connected(&link, 8).await {
                println!("refused: relay link not connected");
                std::process::exit(2);
            }
            println!("connected");
            let publication = node.publish(path, Audience::Granted)?;
            let track = publication
                .broadcast()
                .create_track("bytes", timed())
                .map_err(|err| anyhow::anyhow!("{err}"))?;
            let mut sent = 0usize;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
            while tokio::time::Instant::now() < deadline {
                let mut group = track
                    .append_group(now())
                    .map_err(|err| anyhow::anyhow!("{err}"))?;
                let payload = b"mjolnir-relay-frame".to_vec();
                sent += payload.len();
                group
                    .write_frame(now(), payload)
                    .map_err(|err| anyhow::anyhow!("{err}"))?;
                group.finish().map_err(|err| anyhow::anyhow!("{err}"))?;
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            println!("published path={path} bytes={sent}");
            link.detach().await;
        }
        "notoken" => {
            let path = args.next().unwrap_or_else(|| "/".into());
            let path = if path == "self" {
                own.to_string()
            } else {
                path
            };
            let mut config = RelayConfig::iroh(relay).with_consume(false);
            config.url = format!("iroh://{relay}/{path}").parse()?;
            let link = node.attach_relay(config)?;
            let connected = wait_connected(&link, 5).await;
            let mut status = link.status();
            println!(
                "notoken path={path} connected={connected} status={:?}",
                status.get()
            );
            if connected {
                std::process::exit(2);
            }
            println!("refused");
        }
        other => anyhow::bail!("unknown command {other}"),
    }
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

fn timed() -> moq_net::track::Info {
    moq_net::track::Info::default().with_timescale(moq_net::Timescale::MILLI)
}

fn now() -> moq_net::Timestamp {
    moq_net::Timestamp::from(moq_net::time::Instant::now())
}
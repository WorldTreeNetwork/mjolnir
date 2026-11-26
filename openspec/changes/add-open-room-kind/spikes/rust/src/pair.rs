//! Bounded Iroh pair for the path trial. Spike only.
//!
//! publish <relay-id> <token> <abs-path> <seconds> <ready-file> <payload>
//! read    <relay-id> <token> <abs-path> <subscribe-timeout-secs> <read-secs>
//! listen  <relay-id> <token> <seconds>
//!
//! `Node::subscribe` waits until a route exists. This binary bounds that wait
//! and prints the payload bytes it actually read.
use std::time::Duration;

use iroh::{EndpointId, Watcher};
use iroh_live::{Audience, Node, NodeConfig, Reach, RelayConfig, RelayStatus};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let cmd = args.next().expect("command");
    let relay: EndpointId = args.next().expect("relay").parse()?;
    let token = args.next().expect("token");
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::N0)
        .bind()
        .await?;
    println!("client-endpoint={}", endpoint.id());
    let node = Node::new(endpoint, NodeConfig::default());
    match cmd.as_str() {
        "publish" => {
            let path = args.next().expect("path");
            let seconds: u64 = args.next().expect("seconds").parse()?;
            let ready = args.next().expect("ready-file");
            let payload = args.next().expect("payload").into_bytes();
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
            std::fs::write(&ready, "ready")?;
            println!("announcing path={path}");
            let mut sent = 0usize;
            let mut frames = 0usize;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
            while tokio::time::Instant::now() < deadline {
                let mut group = track.append_group(now()).map_err(|e| anyhow::anyhow!("{e}"))?;
                sent += payload.len();
                frames += 1;
                group
                    .write_frame(now(), payload.clone())
                    .map_err(|e| anyhow::anyhow!("{e}"))?;
                group.finish().map_err(|e| anyhow::anyhow!("{e}"))?;
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            println!("published path={path} frames={frames} bytes={sent} payload-len={}", payload.len());
            link.detach().await;
        }
        "read" => {
            let path = args.next().expect("path");
            let sub_wait: u64 = args.next().expect("subscribe-timeout").parse()?;
            let seconds: u64 = args.next().expect("read-seconds").parse()?;
            let mut config = RelayConfig::iroh(relay);
            if token != "-" {
                config = config.with_token(token.parse()?);
            }
            let link = node.attach_relay(config)?;
            if !wait_connected(&link, 8).await {
                println!("refused: relay link not connected");
                std::process::exit(2);
            }
            println!("connected");
            let started = std::time::Instant::now();
            let subscribed = tokio::time::timeout(
                Duration::from_secs(sub_wait),
                node.subscribe(path.as_str(), Reach::Relays),
            )
            .await;
            let subscription = match subscribed {
                Err(_) => {
                    println!(
                        "subscribe-timeout call=Node::subscribe path={path} bound_s={sub_wait} elapsed_ms={}",
                        started.elapsed().as_millis()
                    );
                    std::process::exit(124);
                }
                Ok(Err(err)) => {
                    println!(
                        "subscribe-error path={path} elapsed_ms={} err={err}",
                        started.elapsed().as_millis()
                    );
                    std::process::exit(3);
                }
                Ok(Ok(subscription)) => subscription,
            };
            println!("subscribed path={path} elapsed_ms={}", started.elapsed().as_millis());
            let broadcast = subscription.broadcast();
            let track = broadcast.track("bytes").map_err(|e| anyhow::anyhow!("track: {e}"))?;
            let mut reader = track.subscribe(None).await.map_err(|e| anyhow::anyhow!("track-subscribe: {e}"))?;
            let mut bytes = 0usize;
            let mut frames = 0usize;
            let mut first = String::new();
            let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
            while tokio::time::Instant::now() < deadline {
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                let group = tokio::time::timeout(left, reader.recv_group()).await;
                let Ok(Ok(Some(mut group))) = group else { break };
                while let Some(frame) = group.read_frame().await? {
                    if first.is_empty() {
                        first = String::from_utf8_lossy(&frame.payload).chars().take(48).collect();
                    }
                    bytes += frame.payload.len();
                    frames += 1;
                }
            }
            println!("received path={path} frames={frames} bytes={bytes} first={first}");
            link.detach().await;
        }
        "listen" => {
            let seconds: u64 = args.next().expect("seconds").parse()?;
            let mut config = RelayConfig::iroh(relay);
            if token != "-" {
                config = config.with_token(token.parse()?);
            }
            let link = node.attach_relay(config)?;
            if !wait_connected(&link, 8).await {
                println!("refused: relay link not connected");
                std::process::exit(2);
            }
            println!("connected");
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
            link.detach().await;
        }
        other => anyhow::bail!("unknown {other}"),
    }
    node.shutdown().await;
    Ok(())
}

fn timed() -> moq_net::track::Info {
    moq_net::track::Info::default().with_timescale(moq_net::Timescale::MILLI)
}

fn now() -> moq_net::Timestamp {
    moq_net::Timestamp::from(moq_net::time::Instant::now())
}

async fn wait_connected(link: &iroh_live::RelayLink, seconds: u64) -> bool {
    let mut status = link.status();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
    while tokio::time::Instant::now() < deadline {
        if status.get() == RelayStatus::Connected {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    false
}

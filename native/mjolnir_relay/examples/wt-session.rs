//! Small WebTransport client for acceptance runs.
//!
//!   cargo run --example wt-session -- hold <url> <seconds>
//!   cargo run --example wt-session -- refuse <url>
//!   cargo run --example wt-session -- announce <url-with-jwt> <seconds>
use std::time::Duration;

use moq_auth::{Algorithm, Claims, Key, KeySet};

fn client() -> moq_tokio::Client {
    let mut config = moq_tokio::connect::Config::default();
    // WT_VERIFY=1 checks the server certificate against the public roots and
    // binds every interface, for a run against a relay's real name.
    if std::env::var("WT_VERIFY").as_deref() == Ok("1") {
        config.bind = Some("0.0.0.0:0".parse().unwrap());
    } else {
        config.tls.insecure = Some(true);
        config.bind = Some("127.0.0.1:0".parse().unwrap());
    }
    config.init(Default::default()).expect("client").with_reconnect(false)
}

fn mint(root: &str, publish: bool, seconds: u64) -> (String, String) {
    let key = Key::generate(Algorithm::EdDSA, None).unwrap();
    let public = key.public().unwrap();
    let set = KeySet {
        keys: vec![std::sync::Arc::new(public)],
    };
    let now = kio::clock::wall();
    let mut claims = Claims::default()
        .with_root(root)
        .with_issued(now)
        .with_expires(now + Duration::from_secs(seconds));
    if publish {
        claims = claims.with_publish(["**".parse().unwrap()]);
    }
    claims = claims.with_subscribe(["**".parse().unwrap()]);
    let token = key.sign(&claims).unwrap();
    (set.to_str().unwrap(), token)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let cmd = args.next().unwrap_or_else(|| "help".into());
    match cmd.as_str() {
        "mint" => {
            let root = args.next().expect("root");
            let seconds: u64 = args.next().unwrap_or("60".into()).parse()?;
            let publish = args.next().unwrap_or("publish".into()) != "subscribe";
            let (set, token) = mint(&root, publish, seconds);
            println!("{set}");
            eprintln!("{token}");
        }
        "hold" => {
            let url: url::Url = args.next().expect("url").parse()?;
            let seconds: u64 = args.next().unwrap_or("30".into()).parse()?;
            let session = client().connect(url).established().await?;
            println!("held");
            tokio::time::sleep(Duration::from_secs(seconds)).await;
            drop(session);
            println!("released");
        }
        "refuse" => {
            let url: url::Url = args.next().expect("url").parse()?;
            match client().connect(url).established().await {
                Ok(_) => {
                    println!("admitted");
                    std::process::exit(2);
                }
                Err(err) => println!("refused: {err}"),
            }
        }
        "publish" => {
            let url: url::Url = args.next().expect("url").parse()?;
            let path = args.next().expect("path");
            let seconds: u64 = args.next().unwrap_or("8".into()).parse()?;
            let origin = moq_tokio::origin::spawn();
            let routed = origin
                .route(path.as_str(), moq_net::origin::RouteOptions::default())
                .map_err(|err| anyhow::anyhow!("route: {err}"))?;
            let track = routed
                .broadcast()
                .create_track("bytes", timed())
                .map_err(|err| anyhow::anyhow!("track: {err}"))?;
            let writer = tokio::spawn(async move {
                let mut sent = 0usize;
                let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
                while tokio::time::Instant::now() < deadline {
                    let mut group = track.append_group(now()).expect("group");
                    let payload = b"mjolnir-relay-frame".to_vec();
                    sent += payload.len();
                    group.write_frame(now(), payload).expect("frame");
                    group.finish().expect("finish");
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
                println!("published path={path} bytes={sent}");
            });
            let session = client()
                .with_publisher(origin.consume())
                .connect(url)
                .established()
                .await?;
            println!("held");
            writer.await.ok();
            drop(session);
            println!("released");
        }
        "read" => {
            let url: url::Url = args.next().expect("url").parse()?;
            let path = args.next().expect("path");
            let seconds: u64 = args.next().unwrap_or("8".into()).parse()?;
            let origin = moq_tokio::origin::spawn();
            let table = origin.consume();
            let mut routes = table.routes();
            let session = client()
                .with_subscriber(origin)
                .connect(url)
                .established()
                .await?;
            println!("held");
            let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
            let mut saw = false;
            while tokio::time::Instant::now() < deadline {
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                match tokio::time::timeout(left, routes.next()).await {
                    Ok(Some(event)) => {
                        println!("route: {event:?}");
                        if format!("{event:?}").contains(path.as_str()) {
                            saw = true;
                            break;
                        }
                    }
                    _ => break,
                }
            }
            if !saw {
                println!("received path={path} frames=0 bytes=0 no-announcement");
                drop(session);
                return Ok(());
            }
            let requested = table.request(path.as_str(), None).await?;
            let track = requested
                .track("bytes")
                .map_err(|err| anyhow::anyhow!("track: {err}"))?;
            let mut reader = track
                .subscribe(None)
                .await
                .map_err(|err| anyhow::anyhow!("subscribe: {err}"))?;
            let mut bytes = 0usize;
            let mut frames = 0usize;
            while tokio::time::Instant::now() < deadline {
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                let group = tokio::time::timeout(left, reader.recv_group()).await;
                let Ok(Ok(Some(mut group))) = group else { break };
                while let Some(frame) = group.read_frame().await? {
                    bytes += frame.payload.len();
                    frames += 1;
                }
            }
            println!("received path={path} frames={frames} bytes={bytes}");
            drop(session);
        }
        "announce" => {
            let url: url::Url = args.next().expect("url").parse()?;
            let seconds: u64 = args.next().unwrap_or("5".into()).parse()?;
            let origin = moq_tokio::origin::spawn();
            let mut routes = origin.consume().routes();
            let session = client()
                .with_subscriber(origin)
                .connect(url)
                .established()
                .await?;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
            while tokio::time::Instant::now() < deadline {
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                match tokio::time::timeout(left, routes.next()).await {
                    Ok(Some(event)) => println!("route: {event:?}"),
                    _ => break,
                }
            }
            drop(session);
        }
        _ => {
            eprintln!("usage: wt-session mint|hold|refuse|announce|publish|read");
            std::process::exit(2);
        }
    }
    Ok(())
}

fn timed() -> moq_net::track::Info {
    moq_net::track::Info::default().with_timescale(moq_net::Timescale::MILLI)
}

fn now() -> moq_net::Timestamp {
    moq_net::Timestamp::from(moq_net::time::Instant::now())
}

//! Small WebTransport client for acceptance runs.
//!
//!   cargo run --example wt-session -- hold <url> <seconds>
//!   cargo run --example wt-session -- refuse <url>
//!   cargo run --example wt-session -- announce <url-with-jwt> <seconds>
use std::time::Duration;

use moq_auth::{Algorithm, Claims, Key, KeySet};

fn client() -> moq_tokio::Client {
    let mut config = moq_tokio::connect::Config::default();
    config.tls.insecure = Some(true);
    config.bind = Some("127.0.0.1:0".parse().unwrap());
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
            eprintln!("usage: wt-session mint|hold|refuse|announce");
            std::process::exit(2);
        }
    }
    Ok(())
}

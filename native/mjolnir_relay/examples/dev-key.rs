//! Local fixture keys and tokens. Not installed.
//!
//! ```text
//! dev-key public
//! dev-key generate <private-path>
//! dev-key sign <private-path> <seconds> <root> <publish> <subscribe>
//! dev-key owner <byte>
//! dev-key mint <root> <seconds> <publish-patterns> <subscribe-patterns>
//! dev-key private-jwk
//! dev-key oct-jwk
//! ```
//!
//! Patterns are comma-separated. `-` is an empty list. `mint` prints the
//! public verify set on stdout and the token on stderr.
//! `generate` writes a private set (mode 0600) and prints only the public
//! set. `sign` reads that private file and prints one token.
use std::time::Duration;

use moq_auth::{Algorithm, Claims, Key, KeySet};

fn set_of(key: Key) -> String {
    let set = KeySet {
        keys: vec![std::sync::Arc::new(key)],
    };
    set.to_str().expect("json")
}

fn patterns(text: &str) -> Vec<moq_auth::Pattern> {
    if text == "-" {
        return Vec::new();
    }
    text.split(',')
        .map(|pattern| pattern.parse().expect("pattern"))
        .collect()
}

fn main() {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref().unwrap_or("public") {
        "public" => {
            let key = Key::generate(Algorithm::EdDSA, None).expect("key");
            println!("{}", set_of(key.public().expect("public")));
        }
        "generate" => {
            let path = args.next().expect("private path");
            let key = Key::generate(Algorithm::EdDSA, None).expect("key");
            let private = KeySet {
                keys: vec![std::sync::Arc::new(key)],
            };
            private.to_file(&path).expect("write private set");
            println!("{}", private.public().expect("public").to_str().expect("json"));
        }
        "sign" => {
            let path = args.next().expect("private path");
            let seconds: u64 = args.next().expect("seconds").parse().expect("seconds");
            let root = args.next().expect("root");
            let publish = patterns(&args.next().expect("publish"));
            let subscribe = patterns(&args.next().expect("subscribe"));
            let set = KeySet::from_file(&path).expect("read private set");
            let now = kio::clock::wall();
            let mut claims = Claims::default()
                .with_root(root)
                .with_issued(now)
                .with_expires(now + Duration::from_secs(seconds));
            if !publish.is_empty() {
                claims = claims.with_publish(publish);
            }
            if !subscribe.is_empty() {
                claims = claims.with_subscribe(subscribe);
            }
            println!("{}", set.sign(&claims).expect("sign"));
        }
        "owner" => {
            let byte: u8 = args.next().unwrap_or("7".into()).parse().expect("byte");
            println!("t/{}", bs58::encode([byte; 32]).into_string());
        }
        "tokens" => {
            let seconds: u64 = args.next().expect("seconds").parse().expect("seconds");
            let key = Key::generate(Algorithm::EdDSA, None).expect("key");
            println!("SET {}", set_of(key.public().expect("public")));
            while let Some(name) = args.next() {
                let root = args.next().expect("root");
                let publish = patterns(&args.next().expect("publish"));
                let subscribe = patterns(&args.next().expect("subscribe"));
                let now = kio::clock::wall();
                let mut claims = Claims::default()
                    .with_root(root)
                    .with_issued(now)
                    .with_expires(now + Duration::from_secs(seconds));
                if !publish.is_empty() {
                    claims = claims.with_publish(publish);
                }
                if !subscribe.is_empty() {
                    claims = claims.with_subscribe(subscribe);
                }
                println!("TOKEN {name} {}", key.sign(&claims).expect("sign"));
            }
        }
        "mint" => {
            let root = args.next().expect("root");
            let seconds: u64 = args.next().expect("seconds").parse().expect("seconds");
            let publish = patterns(&args.next().expect("publish patterns"));
            let subscribe = patterns(&args.next().expect("subscribe patterns"));
            let key = Key::generate(Algorithm::EdDSA, None).expect("key");
            let now = kio::clock::wall();
            let mut claims = Claims::default()
                .with_root(root)
                .with_issued(now)
                .with_expires(now + Duration::from_secs(seconds));
            if !publish.is_empty() {
                claims = claims.with_publish(publish);
            }
            if !subscribe.is_empty() {
                claims = claims.with_subscribe(subscribe);
            }
            let token = key.sign(&claims).expect("sign");
            println!("{}", set_of(key.public().expect("public")));
            eprintln!("{token}");
        }
        "private-jwk" => {
            let key = Key::generate(Algorithm::EdDSA, None).expect("key");
            println!("{}", set_of(key));
        }
        "oct-jwk" => {
            let key = Key::generate(Algorithm::HS256, None).expect("key");
            println!("{}", set_of(key));
        }
        other => {
            eprintln!("unknown command {other}");
            std::process::exit(2);
        }
    }
}
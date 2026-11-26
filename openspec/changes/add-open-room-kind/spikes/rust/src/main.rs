//! Spike H1 harness for add-open-room-kind. Local, disposable, dummy keys. Not product code.
//!
//!   kind-spike relay <priv>
//!       In-process moq-relay with the Mjolnir WebTransport decider (`spawn_web_decider`) and the
//!       Mjolnir Iroh session handler (`IrohSessions` + `TokenPolicy`), as `mjolnir-relay` composes
//!       them. Writes <priv>/relay.txt (QUIC addr), iroh.txt (endpoint id), hash.txt (SHA-256 of the
//!       10-day self-signed certificate, for Chromium `serverCertificateHashes`), private.json (0600),
//!       verify.json. Runs until <priv>/stop exists.
//!   kind-spike sign <priv> <root> <publish|-> <subscribe|-> <seconds>
//!       One token, signed with <priv>/private.json, root copied byte for byte. Wall clock.
//!   kind-spike offline
//!       Verification table under a kio Manual clock installed on the runtime, so moq-auth's
//!       `Key::verify` (validate_times) and the relay's `profile` both read the controlled time.
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use moq_auth::{Algorithm, Claims, Key, KeyId, KeySet, Pattern};
use sha2::Digest;

const KID: &str = "spike-kind";

fn owner() -> String {
    bs58::encode([9u8; 32]).into_string()
}

fn patterns(text: &str) -> Vec<Pattern> {
    if text == "-" {
        return Vec::new();
    }
    text.split(',').map(|p| p.parse().expect("pattern")).collect()
}

fn claims(root: &str, publish: &str, subscribe: &str, iat: kio::clock::Wall, exp: kio::clock::Wall) -> Claims {
    Claims::default()
        .with_root(root)
        .with_publish(patterns(publish))
        .with_subscribe(patterns(subscribe))
        .with_issued(iat)
        .with_expires(exp)
}

fn cert_pair(dir: &Path) -> anyhow::Result<(PathBuf, PathBuf, String)> {
    let key = rcgen::KeyPair::generate()?; // ECDSA P-256, which serverCertificateHashes requires
    let mut params = rcgen::CertificateParams::new(vec!["localhost".into(), "127.0.0.1".into()])?;
    let now = time::OffsetDateTime::now_utc();
    params.not_before = now - time::Duration::days(1);
    params.not_after = now + time::Duration::days(10); // Chromium allows at most 14 days
    let cert = params.self_signed(&key)?;
    let hash = hex::encode(sha2::Sha256::digest(cert.der()));
    let cert_path = dir.join("relay.pem");
    let key_path = dir.join("relay-tls-key.pem");
    std::fs::write(&cert_path, cert.pem())?;
    std::fs::write(&key_path, key.serialize_pem())?;
    Ok((cert_path, key_path, hash))
}

async fn relay(dir: PathBuf) -> anyhow::Result<()> {
    std::fs::create_dir_all(&dir)?;
    let (cert, tls_key, hash) = cert_pair(&dir)?;
    let _ = moq_tokio::crypto::install_default();
    let mut config = moq_relay::Config::default();
    config.listen.bind = Some("127.0.0.1:0".parse()?);
    config.listen.tls.cert = vec![cert];
    config.listen.tls.key = vec![tls_key];
    config.web.ws = false;
    let mut relay = moq_relay::Relay::load(config).await?.with_signals(false);
    let quic = relay.quic_addr().expect("quic addr");
    let admissions = relay.admissions().expect("admissions");

    let key = Key::generate(Algorithm::EdDSA, Some(KeyId::decode(KID).unwrap()))?;
    let public = KeySet { keys: vec![Arc::new(key.public()?)] };
    std::fs::write(dir.join("verify.json"), public.to_str()?)?;
    KeySet { keys: vec![Arc::new(key)] }.to_file(dir.join("private.json"))?;

    let keys = Arc::new(Mutex::new(public));
    let draining = Arc::new(AtomicBool::new(false));
    let keys_ok = Arc::new(AtomicBool::new(true));
    mjolnir_relay::spawn_web_decider(admissions, keys.clone(), draining.clone(), keys_ok.clone(), mjolnir_relay::DEFAULT_MAX_TTL);

    // The Iroh mount, as native/mjolnir_relay/src/main.rs mount_iroh does it.
    let alpns = moq_transport_iroh::alpns().into_iter().map(<[u8]>::to_vec).collect();
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::N0)
        .secret_key(iroh::SecretKey::generate())
        .alpns(alpns)
        .bind()
        .await?;
    let iroh_id = endpoint.id();
    let policy = mjolnir_relay::TokenPolicy { keys, draining, keys_ok, max_ttl: mjolnir_relay::DEFAULT_MAX_TTL };
    let router = mjolnir_relay::IrohSessions::new(relay.cluster().clone())
        .with_policy(policy)
        .mount(iroh::protocol::Router::builder(endpoint))
        .spawn();

    let ready = relay.ready();
    let join = tokio::spawn(relay.run());
    ready.wait().await.map_err(|e| anyhow::anyhow!("{e:?}"))?;
    std::fs::write(dir.join("relay.txt"), quic.to_string())?;
    std::fs::write(dir.join("iroh.txt"), iroh_id.to_string())?;
    std::fs::write(dir.join("hash.txt"), &hash)?;
    println!("relay up quic={quic} iroh={iroh_id}");
    let stop = dir.join("stop");
    while !stop.exists() && !join.is_finished() {
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    let _ = router.shutdown().await;
    println!("relay stopping");
    Ok(())
}

fn sign(dir: &Path, root: &str, publish: &str, subscribe: &str, seconds: u64) -> anyhow::Result<String> {
    let set = KeySet::from_file(dir.join("private.json")).map_err(|e| anyhow::anyhow!("{e}"))?;
    let now = kio::clock::wall();
    Ok(set.sign(&claims(root, publish, subscribe, now, now + Duration::from_secs(seconds)))?)
}

fn verdict(r: &Result<moq_auth::Grant, mjolnir_relay::Refuse>) -> String {
    match r {
        Ok(_) => "ADMIT".into(),
        Err(e) => format!("refuse({e:?})"),
    }
}

fn verify_verdict(set: &KeySet, token: &str) -> String {
    match set.verify(token) {
        Ok(_) => "ok".into(),
        Err(e) => format!("err({e})"),
    }
}

fn offline() -> anyhow::Result<()> {
    let rt = tokio::runtime::Builder::new_current_thread().enable_time().build()?;
    let installed = kio::clock::Manual::new().install(rt.handle());
    let t0 = installed.wall();
    let key = Key::generate(Algorithm::EdDSA, Some(KeyId::decode(KID).unwrap()))?;
    let public = KeySet { keys: vec![Arc::new(key.public()?)] };
    let ttl = mjolnir_relay::DEFAULT_MAX_TTL;
    let o = owner();
    let tok = |root: &str, publish: &str, iat: kio::clock::Wall| {
        key.sign(&claims(root, publish, "**", iat, t0 + Duration::from_secs(600))).unwrap()
    };

    rt.block_on(async {
        println!("# offline verification under kio Manual clock (installed on this runtime)");
        println!("t0 (manual wall) unix={}", t0.saturating_duration_since(kio::clock::Wall::UNIX_EPOCH).as_secs());
        installed.step_wall(t0 + Duration::from_secs(10));
        println!("now = t0+10s; tokens iat=t0 exp=t0+600; room-mint shape publish alice/** subscribe **");
        println!();
        println!("## marker roots: own path, encoded spellings of the own path, and the other kind");
        let protected = format!("t/{o}/standup");
        for (marker, enc, dbl) in [("~open", "%7Eopen", "%257Eopen"), ("@open", "%40open", "%2540open"), ("+open", "%2Bopen", "%252Bopen")] {
            let root = format!("t/{o}/{marker}/standup");
            let t = tok(&root, "alice/**", t0);
            println!("root_allowed({marker}) = {}", mjolnir_relay::root_allowed(&root));
            for (label, path) in [
                ("own literal", root.clone()),
                ("own %-encoded marker", format!("t/{o}/{enc}/standup")),
                ("own double-encoded marker", format!("t/{o}/{dbl}/standup")),
                ("protected same name", protected.clone()),
                ("own + /alice", format!("{root}/alice")),
            ] {
                println!("  token {marker:6} path {label:28} -> {}", verdict(&mjolnir_relay::assess(Some(&t), &path, &public, ttl)));
            }
            let p = tok(&protected, "alice/**", t0);
            println!("  token protected path {marker} same name           -> {}", verdict(&mjolnir_relay::assess(Some(&p), &root, &public, ttl)));
            // A root spelled with the encoded marker is its own literal namespace, not the marker's.
            let encroot = format!("t/{o}/{enc}/standup");
            let e = tok(&encroot, "alice/**", t0);
            println!("  token root {enc:10} at literal {marker} path    -> {}", verdict(&mjolnir_relay::assess(Some(&e), &root, &public, ttl)));
        }
        println!();
        println!("## tenant-wide grant (root t/<owner>, subscribe **, publish **): spans both kinds");
        let wide = tok(&format!("t/{o}"), "**", t0);
        for path in [protected.clone(), format!("t/{o}/~open/standup")] {
            println!("  wide token path {path:70} -> {}", verdict(&mjolnir_relay::assess(Some(&wide), &path, &public, ttl)));
        }
        println!();
        println!("## time is controlled through moq-auth verify and relay profile");
        let open = format!("t/{o}/~open/standup");
        let t = tok(&open, "alice/**", t0);
        let future = tok(&open, "alice/**", t0 + Duration::from_secs(60));
        println!("  now=t0+10   KeySet::verify={}  assess={}", verify_verdict(&public, &t), verdict(&mjolnir_relay::assess(Some(&t), &open, &public, ttl)));
        installed.step_wall(t0 + Duration::from_secs(600));
        println!("  now=t0+600  KeySet::verify={}  assess={}", verify_verdict(&public, &t), verdict(&mjolnir_relay::assess(Some(&t), &open, &public, ttl)));
        installed.step_wall(t0 + Duration::from_secs(599));
        println!("  now=t0+599  KeySet::verify={}  assess={}", verify_verdict(&public, &t), verdict(&mjolnir_relay::assess(Some(&t), &open, &public, ttl)));
        installed.step_wall(t0 + Duration::from_secs(10));
        println!("  iat=t0+60 at now=t0+10: KeySet::verify={}  assess={}", verify_verdict(&public, &future), verdict(&mjolnir_relay::assess(Some(&future), &open, &public, ttl)));
    });
    // Control: the same token on the host clock (2026), outside the manual runtime.
    let t = key.sign(&claims(&format!("t/{o}/~open/standup"), "alice/**", "**", t0, t0 + Duration::from_secs(600)))?;
    let host = std::thread::spawn(move || {
        let public = public;
        format!("host clock: KeySet::verify={}  assess={}", verify_verdict(&public, &t),
            verdict(&mjolnir_relay::assess(Some(&t), &format!("t/{}/~open/standup", owner()), &public, ttl)))
    })
    .join()
    .unwrap();
    println!("  {host}");
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("relay") => relay(args[1].clone().into()).await,
        Some("sign") => {
            let seconds = args[5].parse()?;
            println!("{}", sign(Path::new(&args[1]), &args[2], &args[3], &args[4], seconds)?);
            Ok(())
        }
        Some("offline") => tokio::task::spawn_blocking(offline).await?,
        _ => anyhow::bail!("usage: kind-spike relay|sign|offline"),
    }
}

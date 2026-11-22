//! Host edge relay. One WebTransport listener, deny-by-default tokens.
//!
//! Does not call `iroh_live_relay::run`. Pulls stay off.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use moq_auth::{Grant, KeySet};
use moq_relay::shutdown::Trigger;
use moq_relay::{Config, Relay};
use mjolnir_relay::{
    IrohSessions, TokenPolicy, cert_usable, file_sha256, key_file_trusted, load_verify_keys,
};
use tokio::signal::unix::{SignalKind, signal};
struct Settings {
    host: String,
    bind: String,
    cert: PathBuf,
    key: PathBuf,
    keys: PathBuf,
    active: PathBuf,
    drain: Duration,
    max_ttl: Duration,
    state_dir: PathBuf,
}

fn settings() -> anyhow::Result<Settings> {
    let host = std::env::var("MJOLNIR_RELAY_HOST")?;
    // `tls/cert.pem` and `tls/key.pem` are symlinks to `current/`. moq watches
    // that directory, so renaming `current` is the reload. Watching
    // `current/cert.pem` follows the generation directory and misses the rename.
    let tls = std::env::var("MJOLNIR_RELAY_TLS_DIR")
        .unwrap_or_else(|_| "/var/lib/mjolnir-relay/tls".into());
    Ok(Settings {
        host,
        bind: std::env::var("MJOLNIR_RELAY_BIND").unwrap_or_else(|_| "0.0.0.0:443".into()),
        cert: PathBuf::from(&tls).join("cert.pem"),
        key: PathBuf::from(&tls).join("key.pem"),
        keys: PathBuf::from(
            std::env::var("MJOLNIR_RELAY_KEYS")
                .unwrap_or_else(|_| "/etc/mjolnir-relay/relay-keys.json".into()),
        ),
        active: PathBuf::from(
            std::env::var("MJOLNIR_RELAY_KEYS_ACTIVE")
                .unwrap_or_else(|_| "/run/mjolnir-relay/keys.active".into()),
        ),
        drain: Duration::from_secs(parse_u64("MJOLNIR_RELAY_DRAIN_SECONDS", 30)),
        max_ttl: Duration::from_secs(parse_u64("MJOLNIR_RELAY_TOKEN_MAX_TTL", 3600)),
        state_dir: PathBuf::from(
            std::env::var("MJOLNIR_RELAY_STATE_DIR")
                .unwrap_or_else(|_| "/var/lib/mjolnir-relay-state".into()),
        ),
    })
}

fn parse_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|text| text.parse().ok())
        .unwrap_or(default)
}

fn write_active(path: &Path, text: &str) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(path, text);
}

fn check_cert(settings: &Settings) -> anyhow::Result<()> {
    let pem = std::fs::read_to_string(&settings.cert)
        .map_err(|err| anyhow::anyhow!("{}: {err}", settings.cert.display()))?;
    if !settings.key.is_file() {
        anyhow::bail!("{}: missing key", settings.key.display());
    }
    cert_usable(&pem, &settings.host, SystemTime::now())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber_lite();
    let settings = settings()?;
    key_file_trusted(&settings.keys)?;
    let keys = load_verify_keys(&settings.keys).map_err(|err| {
        anyhow::anyhow!("{}: {err}", settings.keys.display())
    })?;
    check_cert(&settings)?;
    write_active(&settings.active, &file_sha256(&settings.keys)?);

    moq_tokio::crypto::install_default()?;
    let mut config = Config::default();
    config.listen.bind = Some(settings.bind.parse()?);
    config.listen.tls.cert = vec![settings.cert.clone()];
    config.listen.tls.key = vec![settings.key.clone()];
    config.web.ws = false;
    config.drain_timeout = Some(settings.drain.into());

    let mut relay = Relay::load(config).await?.with_signals(false);
    let trigger = relay.shutdown_trigger().clone();
    let net_admission = relay.shutdown().admission().clone();
    let admissions = relay
        .admissions()
        .ok_or_else(|| anyhow::anyhow!("relay built its own auth and left no admissions"))?;
    let keys = Arc::new(Mutex::new(keys));
    let draining = Arc::new(AtomicBool::new(false));
    let keys_ok = Arc::new(AtomicBool::new(true));
    spawn_decider(
        admissions,
        keys.clone(),
        draining.clone(),
        keys_ok.clone(),
        settings.max_ttl,
    );
    spawn_key_watch(
        settings.keys.clone(),
        settings.active.clone(),
        keys.clone(),
        keys_ok.clone(),
    );
    spawn_cert_watch(settings.cert.clone(), settings.host.clone());

    let policy = TokenPolicy {
        keys: keys.clone(),
        draining: draining.clone(),
        keys_ok: keys_ok.clone(),
        max_ttl: settings.max_ttl,
    };
    let iroh_router = mount_iroh(&relay, policy, &settings.state_dir).await?;
    // Cert, keys, and the UDP listener are ready. Type=notify waits for this
    // before ExecStartPost opens the firewall rule.
    notify_ready();

    let drain = settings.drain;
    let draining_signal = draining.clone();
    tokio::spawn(async move {
        let mut term = signal(SignalKind::terminate()).expect("sigterm");
        let mut interrupt = signal(SignalKind::interrupt()).expect("sigint");
        tokio::select! {
            _ = term.recv() => {}
            _ = interrupt.recv() => {}
        }
        drain_then_stop(draining_signal, net_admission, trigger, drain).await;
    });

    relay.run().await?;
    let _ = iroh_router.shutdown().await;
    Ok(())
}

async fn mount_iroh(
    relay: &Relay,
    policy: TokenPolicy,
    state_dir: &Path,
) -> anyhow::Result<iroh::protocol::Router> {
    std::fs::create_dir_all(state_dir)?;
    let secret_path = state_dir.join("iroh-secret");
    let secret = if secret_path.is_file() {
        let bytes = std::fs::read(&secret_path)?;
        let array: [u8; 32] = bytes
            .as_slice()
            .try_into()
            .map_err(|_| anyhow::anyhow!("iroh secret must be 32 bytes"))?;
        iroh::SecretKey::from_bytes(&array)
    } else {
        let secret = iroh::SecretKey::generate();
        std::fs::write(&secret_path, secret.to_bytes())?;
        secret
    };
    // N0 so a client can dial this endpoint id. Minimal publishes no relay
    // address, and a client that only has the id never reaches the socket.
    // The MoQ ALPNs have to be on the endpoint before bind; the router accept
    // alone does not add them to the QUIC handshake.
    let alpns = moq_transport_iroh::alpns()
        .into_iter()
        .map(<[u8]>::to_vec)
        .collect();
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::N0)
        .secret_key(secret)
        .alpns(alpns)
        .bind()
        .await?;
    println!("iroh endpoint: {}", endpoint.id());
    let router = IrohSessions::new(relay.cluster().clone())
        .with_policy(policy)
        .mount(iroh::protocol::Router::builder(endpoint))
        .spawn();
    Ok(router)
}

async fn drain_then_stop(
    draining: Arc<AtomicBool>,
    admission: moq_net::server::Admission,
    trigger: Trigger,
    drain: Duration,
) {
    draining.store(true, Ordering::SeqCst);
    admission.drain();
    tokio::time::sleep(drain).await;
    trigger.start();
}

fn spawn_decider(
    mut admissions: moq_relay::auth::Admissions,
    keys: Arc<Mutex<KeySet>>,
    draining: Arc<AtomicBool>,
    keys_ok: Arc<AtomicBool>,
    max_ttl: Duration,
) {
    tokio::spawn(async move {
        while let Some(admission) = admissions.next().await {
            if draining.load(Ordering::SeqCst) {
                admission.refuse(moq_relay::auth::Error::Unavailable("draining".into()));
                continue;
            }
            if !keys_ok.load(Ordering::SeqCst) {
                admission.refuse(moq_relay::auth::Error::Unavailable("keys unavailable".into()));
                continue;
            }
            let path = admission.request.path.clone();
            let from_setup = admission.request.token.as_ref().and_then(|token| {
                String::from_utf8(token.value.clone()).ok()
            });
            let from_query = admission.request.query.as_deref().and_then(jwt_query);
            let token = from_setup.or(from_query);
            let set = keys.lock().expect("keys").clone();
            match mjolnir_relay::web_grant(
                admission.attached(),
                token.as_deref(),
                &path,
                &set,
                max_ttl,
            ) {
                Ok(grant) => {
                    let _ = grant_or_refuse(admission, grant);
                }
                Err(err) => {
                    admission.refuse(moq_relay::auth::Error::Forbidden(err.to_string()));
                }
            }
        }
    });
}

fn grant_or_refuse(admission: moq_relay::auth::Admission, grant: Grant) -> Result<(), ()> {
    match grant.validate() {
        Ok(()) => {
            admission.grant(moq_auth::lease::Consumer::fixed(grant));
            Ok(())
        }
        Err(err) => {
            admission.refuse(err.into());
            Err(())
        }
    }
}

fn jwt_query(query: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == "jwt").then(|| value.to_string())
    })
}

fn spawn_key_watch(
    path: PathBuf,
    active: PathBuf,
    keys: Arc<Mutex<KeySet>>,
    keys_ok: Arc<AtomicBool>,
) {
    tokio::spawn(async move {
        let mut last = std::fs::metadata(&path).ok().and_then(|meta| meta.modified().ok());
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let modified = std::fs::metadata(&path).ok().and_then(|meta| meta.modified().ok());
            if modified == last {
                continue;
            }
            last = modified;
            // A bad file refuses new sessions. It does not clear a drain,
            // and a later good file does not reopen a drain.
            match key_file_trusted(&path).and_then(|_| load_verify_keys(&path)).and_then(|set| {
                let hash = file_sha256(&path)?;
                Ok((set, hash))
            }) {
                Ok((set, hash)) => {
                    *keys.lock().expect("keys") = set;
                    keys_ok.store(true, Ordering::SeqCst);
                    write_active(&active, &hash);
                }
                Err(_) => {
                    keys_ok.store(false, Ordering::SeqCst);
                    write_active(&active, "invalid");
                }
            }
        }
    });
}

fn spawn_cert_watch(cert: PathBuf, host: String) {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(30)).await;
            let Ok(pem) = std::fs::read_to_string(&cert) else {
                tracing::error!(path = %cert.display(), "certificate unreadable");
                std::process::exit(1);
            };
            if cert_usable(&pem, &host, SystemTime::now()).is_err() {
                tracing::error!("certificate is no longer usable");
                std::process::exit(1);
            }
        }
    });
}

/// Tell systemd the process is serving. A start that exits before this
/// never runs ExecStartPost, so a failed start does not open UDP 443.
#[cfg(target_os = "linux")]
fn notify_ready() {
    let Ok(addr) = std::env::var("NOTIFY_SOCKET") else {
        return;
    };
    std::env::remove_var("NOTIFY_SOCKET");
    let Ok(sock) = std::os::unix::net::UnixDatagram::unbound() else {
        return;
    };
    let sent = if let Some(name) = addr.strip_prefix('@') {
        <std::os::unix::net::SocketAddr as std::os::linux::net::SocketAddrExt>::from_abstract_name(name)
            .ok()
            .and_then(|dest| sock.connect_addr(&dest).ok())
            .and_then(|_| sock.send(b"READY=1\n").ok())
    } else {
        sock.send_to(b"READY=1\n", &addr).ok()
    };
    if sent.is_none() {
        tracing::error!("sd_notify READY=1 failed");
    }
}

#[cfg(not(target_os = "linux"))]
fn notify_ready() {}

fn tracing_subscriber_lite() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .try_init();
}

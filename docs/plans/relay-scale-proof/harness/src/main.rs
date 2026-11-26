//! Load generator for one Mjolnir MoQ relay.
//!
//! `irl run` at iroh-live `747b1bd` is one endpoint with media capture and
//! broadcast tickets. It does not open N rooms of P participants on tokens
//! shaped like `Mjolnir.Relay.Mint`. This binary does.
//!
//! ```text
//! relay-scale run --transport wt|iroh --rooms N --participants P --seconds S
//! ```
//!
//! The relay is a child process so CPU and RSS are that process alone.
//! `--loss-pct` and `--delay-ms` insert a UDP proxy in front of WebTransport.
//! `--burn-threads` spins threads inside the relay process (a CPU cap's inverse:
//! the relay contends for cores). Iroh does not traverse that UDP proxy.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use iroh::Watcher;
use moq_auth::{Algorithm, Claims, Key, KeySet};

struct Opts {
    transport: String,
    rooms: u32,
    participants: u32,
    seconds: u64,
    video_kbps: u64,
    loss_pct: u32,
    burn_threads: u32,
    delay_ms: u64,
}

struct Totals {
    published: AtomicU64,
    span: AtomicU64,
    delivered: AtomicU64,
    skipped: AtomicU64,
    late: AtomicU64,
    session_errors: AtomicU64,
    first_frame_us: AtomicU64,
    latencies: Mutex<Vec<u32>>,
}

impl Totals {
    fn new() -> Self {
        Self {
            published: AtomicU64::new(0),
            span: AtomicU64::new(0),
            delivered: AtomicU64::new(0),
            skipped: AtomicU64::new(0),
            late: AtomicU64::new(0),
            session_errors: AtomicU64::new(0),
            first_frame_us: AtomicU64::new(0),
            latencies: Mutex::new(Vec::new()),
        }
    }

    fn note_latency(&self, us: u32) {
        let mut g = self.latencies.lock().expect("lat");
        if g.len() < 200_000 {
            g.push(us);
        }
        if us > 300_000 {
            self.late.fetch_add(1, Ordering::Relaxed);
        }
    }
}

fn owner() -> String {
    bs58::encode([9u8; 32]).into_string()
}

fn room_token(key: &Key, room: &str, participant: &str) -> String {
    let now = kio::clock::wall();
    let claims = Claims::default()
        .with_root(format!("t/{}/{room}", owner()))
        .with_publish([format!("{participant}/**").parse().unwrap()])
        .with_subscribe(["**".parse().unwrap()])
        .with_issued(now)
        .with_expires(now + Duration::from_secs(600));
    key.sign(&claims).unwrap()
}

fn timed() -> moq_net::track::Info {
    moq_net::track::Info::default().with_timescale(moq_net::Timescale::MILLI)
}

fn stamp() -> moq_net::Timestamp {
    moq_net::Timestamp::from(moq_net::time::Instant::now())
}

fn wall_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn payload(seq: u32, size: usize) -> Vec<u8> {
    let mut buf = vec![0u8; size.max(12)];
    buf[..8].copy_from_slice(&wall_ms().to_be_bytes());
    buf[8..12].copy_from_slice(&seq.to_be_bytes());
    buf
}

fn parse_payload(bytes: &[u8]) -> Option<(u64, u32)> {
    if bytes.len() < 12 {
        return None;
    }
    let mut ms = [0u8; 8];
    let mut seq = [0u8; 4];
    ms.copy_from_slice(&bytes[..8]);
    seq.copy_from_slice(&bytes[8..12]);
    Some((u64::from_be_bytes(ms), u32::from_be_bytes(seq)))
}

/// 30 groups/s. Every 60th group is an 8x keyframe. Average stays near `kbps`.
fn video_sizes(kbps: u64) -> (usize, usize) {
    let avg = ((kbps * 1000) / 8 / 30).max(12) as usize;
    let delta = (avg * 60 / 67).max(12);
    (delta, delta * 8)
}

fn percentile(samples: &mut [u32], p: f64) -> u32 {
    if samples.is_empty() {
        return 0;
    }
    samples.sort_unstable();
    let idx = ((samples.len() as f64 - 1.0) * p).round() as usize;
    samples[idx.min(samples.len() - 1)]
}

fn arg(args: &[String], name: &str, default: &str) -> String {
    args.windows(2)
        .find(|w| w[0] == name)
        .map(|w| w[1].clone())
        .unwrap_or_else(|| default.to_string())
}

fn parse_opts(args: &[String]) -> Opts {
    Opts {
        transport: arg(args, "--transport", "wt"),
        rooms: arg(args, "--rooms", "1").parse().unwrap_or(1),
        participants: arg(args, "--participants", "2").parse().unwrap_or(2),
        seconds: arg(args, "--seconds", "6").parse().unwrap_or(6),
        video_kbps: arg(args, "--video-kbps", "1000").parse().unwrap_or(1000),
        loss_pct: arg(args, "--loss-pct", "0").parse().unwrap_or(0).min(100),
        burn_threads: arg(args, "--burn-threads", "0").parse().unwrap_or(0),
        delay_ms: arg(args, "--delay-ms", "0").parse().unwrap_or(0),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("serve") => serve(&args).await,
        Some("run") => drive(&args).await,
        _ => {
            eprintln!(
                "usage: relay-scale run --transport wt|iroh --rooms N --participants P --seconds S [--video-kbps 1000] [--loss-pct N] [--delay-ms N] [--burn-threads N]"
            );
            std::process::exit(2);
        }
    }
}

async fn serve(args: &[String]) -> anyhow::Result<()> {
    let keys_path = arg(args, "--keys", "");
    let burn: u32 = arg(args, "--burn-threads", "0").parse().unwrap_or(0);
    let seconds: u64 = arg(args, "--seconds", "30").parse().unwrap_or(30);
    let raw = std::fs::read_to_string(&keys_path)?;
    let set: KeySet = raw.parse().map_err(|err| anyhow::anyhow!("keys: {err}"))?;
    let dir = work_dir();
    let (cert, key) = cert_pair(&dir);
    let _ = moq_tokio::crypto::install_default();
    let mut config = moq_relay::Config::default();
    config.listen.bind = Some("127.0.0.1:0".parse().unwrap());
    config.listen.tls.cert = vec![cert];
    config.listen.tls.key = vec![key];
    config.web.ws = false;
    let mut relay = moq_relay::Relay::load(config).await?.with_signals(false);
    let quic = relay.quic_addr().unwrap();
    let admissions = relay.admissions().unwrap();
    let cluster = relay.cluster().clone();
    let ready = relay.ready();
    let join = tokio::spawn(relay.run());
    ready.wait().await?;
    let keys = Arc::new(Mutex::new(set));
    let policy = mjolnir_relay::TokenPolicy {
        keys: keys.clone(),
        draining: Arc::new(AtomicBool::new(false)),
        keys_ok: Arc::new(AtomicBool::new(true)),
        max_ttl: Duration::from_secs(3600),
    };
    mjolnir_relay::spawn_web_decider(
        admissions,
        keys,
        policy.draining.clone(),
        policy.keys_ok.clone(),
        policy.max_ttl,
    );
    let alpns = moq_transport_iroh::alpns()
        .into_iter()
        .map(<[u8]>::to_vec)
        .collect();
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::N0)
        .secret_key(iroh::SecretKey::generate())
        .alpns(alpns)
        .bind()
        .await?;
    let iroh_id = endpoint.id();
    let router = mjolnir_relay::IrohSessions::new(cluster)
        .with_policy(policy)
        .mount(iroh::protocol::Router::builder(endpoint))
        .spawn();
    println!("READY quic={quic} iroh={iroh_id}");
    let _ = std::io::stdout().flush();
    for _ in 0..burn {
        std::thread::spawn(|| {
            let end = Instant::now() + Duration::from_secs(900);
            let mut x = 0u64;
            while Instant::now() < end {
                x = x.wrapping_mul(1664525).wrapping_add(1013904223);
                std::hint::black_box(x);
            }
        });
    }
    tokio::time::sleep(Duration::from_secs(seconds.saturating_add(45))).await;
    router.shutdown().await.ok();
    join.abort();
    Ok(())
}

fn work_dir() -> PathBuf {
    let path = std::env::temp_dir().join(format!("relay-scale-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&path);
    path
}

fn cert_pair(dir: &Path) -> (PathBuf, PathBuf) {
    let key = rcgen::KeyPair::generate().unwrap();
    let params = rcgen::CertificateParams::new(vec!["localhost".into()]).unwrap();
    let cert = params.self_signed(&key).unwrap();
    let cert_path = dir.join("cert.pem");
    let key_path = dir.join("key.pem");
    std::fs::write(&cert_path, cert.pem()).unwrap();
    std::fs::write(&key_path, key.serialize_pem()).unwrap();
    (cert_path, key_path)
}

struct RelayChild {
    child: Child,
    quic: SocketAddr,
    iroh: String,
}

impl Drop for RelayChild {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

async fn drive(args: &[String]) -> anyhow::Result<()> {
    let opts = parse_opts(args);
    let work = work_dir();
    let key = Key::generate(Algorithm::EdDSA, None)?;
    let public = KeySet {
        keys: vec![std::sync::Arc::new(key.public()?)],
    };
    let keys_path = work.join("verify.json");
    std::fs::write(&keys_path, public.to_str()?)?;
    let mut child = Command::new(std::env::current_exe()?)
        .args([
            "serve",
            "--keys",
            keys_path.to_str().unwrap(),
            "--seconds",
            &opts.seconds.to_string(),
            "--burn-threads",
            &opts.burn_threads.to_string(),
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;
    let (quic, iroh) = read_ready(child.stdout.take().unwrap())?;
    let relay = RelayChild { child, quic, iroh };
    let connect_to = if opts.transport == "wt" && (opts.loss_pct > 0 || opts.delay_ms > 0) {
        spawn_proxy(relay.quic, opts.loss_pct, opts.delay_ms).await?
    } else {
        relay.quic
    };
    let udp_before = udp_counters();
    let totals = Arc::new(Totals::new());
    let stop = Arc::new(AtomicBool::new(false));
    let stop_s = stop.clone();
    let pid = relay.child.id();
    let sampler = tokio::spawn(async move {
        let mut out = Vec::new();
        while !stop_s.load(Ordering::Relaxed) {
            if let Some(row) = sample_pid(pid) {
                out.push(row);
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        out
    });
    let ran = if opts.transport == "iroh" {
        run_iroh(&opts, &relay.iroh, &key, totals.clone()).await
    } else if opts.transport == "wt" {
        run_wt(&opts, connect_to, &key, totals.clone()).await
    } else {
        Err(anyhow::anyhow!("transport must be wt or iroh"))
    };
    stop.store(true, Ordering::Relaxed);
    let samples = sampler.await.unwrap_or_default();
    ran?;
    let udp_after = udp_counters();
    let mut lats = totals.latencies.lock().expect("lat").clone();
    let published = totals.published.load(Ordering::Relaxed);
    let delivered = totals.delivered.load(Ordering::Relaxed);
    // Span is the seq range each subscriber actually observed, so groups
    // published before that subscriber attached are not counted as loss.
    let expected = totals.span.load(Ordering::Relaxed);
    let ratio = if expected == 0 { 0.0 } else { delivered as f64 / expected as f64 };
    let (cpu_max, rss_max) = samples.iter().fold((0.0f64, 0u64), |(c, r), (cc, rr)| (c.max(*cc), r.max(*rr)));
    let cpu_avg = if samples.is_empty() {
        0.0
    } else {
        samples.iter().map(|(c, _)| c).sum::<f64>() / samples.len() as f64
    };
    println!(
        "RESULT transport={} rooms={} participants={} seconds={} video_kbps={} loss_pct={} delay_ms={} burn_threads={} quic={} via={} iroh={} published={} expected={} delivered={} delivery={ratio:.4} skipped={} late={} session_errors={} p50_ms={} p95_ms={} p99_ms={} joiner_first_ms={} relay_cpu_avg={cpu_avg:.1} relay_cpu_max={cpu_max:.1} relay_rss_kb={rss_max} udp_rcvbuf_delta={} udp_sndbuf_delta={} udp_proc_drops_delta={} buffers=\"{}\"",
        opts.transport,
        opts.rooms,
        opts.participants,
        opts.seconds,
        opts.video_kbps,
        if opts.transport == "wt" { opts.loss_pct } else { 0 },
        if opts.transport == "wt" { opts.delay_ms } else { 0 },
        opts.burn_threads,
        relay.quic,
        connect_to,
        relay.iroh,
        published,
        expected,
        delivered,
        totals.skipped.load(Ordering::Relaxed),
        totals.late.load(Ordering::Relaxed),
        totals.session_errors.load(Ordering::Relaxed),
        percentile(&mut lats, 0.50) / 1000,
        percentile(&mut lats, 0.95) / 1000,
        percentile(&mut lats, 0.99) / 1000,
        totals.first_frame_us.load(Ordering::Relaxed) / 1000,
        udp_after.rcvbuf.saturating_sub(udp_before.rcvbuf),
        udp_after.sndbuf.saturating_sub(udp_before.sndbuf),
        udp_after.proc_drops.saturating_sub(udp_before.proc_drops),
        buffer_sysctls(),
    );
    Ok(())
}

fn read_ready(stdout: std::process::ChildStdout) -> anyhow::Result<(SocketAddr, String)> {
    let mut lines = std::io::BufReader::new(stdout).lines();
    let deadline = Instant::now() + Duration::from_secs(40);
    while Instant::now() < deadline {
        match lines.next() {
            Some(Ok(line)) => {
                if let Some(rest) = line.strip_prefix("READY ") {
                    let mut quic = None;
                    let mut iroh = None;
                    for part in rest.split_whitespace() {
                        if let Some(v) = part.strip_prefix("quic=") {
                            quic = Some(v.parse::<SocketAddr>()?);
                        }
                        if let Some(v) = part.strip_prefix("iroh=") {
                            iroh = Some(v.to_string());
                        }
                    }
                    if let (Some(q), Some(i)) = (quic, iroh) {
                        return Ok((q, i));
                    }
                }
                eprintln!("serve: {line}");
            }
            Some(Err(err)) => return Err(err.into()),
            None => anyhow::bail!("relay serve exited before READY"),
        }
    }
    anyhow::bail!("timed out waiting for relay READY")
}

fn sample_pid(pid: u32) -> Option<(f64, u64)> {
    let out = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "%cpu=,rss="])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let mut parts = text.split_whitespace();
    Some((parts.next()?.parse().ok()?, parts.next()?.parse().ok()?))
}

struct UdpSnap {
    rcvbuf: u64,
    sndbuf: u64,
    proc_drops: u64,
}

fn udp_counters() -> UdpSnap {
    let mut snap = UdpSnap { rcvbuf: 0, sndbuf: 0, proc_drops: 0 };
    if let Ok(text) = std::fs::read_to_string("/proc/net/snmp") {
        for line in text.lines() {
            let Some(vals) = line.strip_prefix("Udp:") else { continue };
            if vals.contains("InDatagrams") {
                continue;
            }
            let n: Vec<u64> = vals.split_whitespace().filter_map(|s| s.parse().ok()).collect();
            if n.len() >= 6 {
                snap.rcvbuf = n[4];
                snap.sndbuf = n[5];
            }
        }
    }
    if let Ok(text) = std::fs::read_to_string("/proc/net/udp") {
        for (i, line) in text.lines().enumerate() {
            if i == 0 {
                continue;
            }
            if let Some(drops) = line.split_whitespace().last() {
                snap.proc_drops += drops.parse::<u64>().unwrap_or(0);
            }
        }
    }
    snap
}

fn buffer_sysctls() -> String {
    let mut out = Vec::new();
    for key in ["net.core.rmem_max", "net.core.wmem_max", "net.inet.udp.recvspace", "kern.ipc.maxsockbuf"] {
        if let Ok(text) = Command::new("sysctl").args(["-n", key]).output() {
            if text.status.success() {
                let v = String::from_utf8_lossy(&text.stdout).trim().to_string();
                if !v.is_empty() {
                    out.push(format!("{key}={v}"));
                }
            }
        }
    }
    if out.is_empty() { "unread".into() } else { out.join(" ") }
}

async fn spawn_proxy(upstream: SocketAddr, loss_pct: u32, delay_ms: u64) -> anyhow::Result<SocketAddr> {
    let front = Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await?);
    let addr = front.local_addr()?;
    tokio::spawn(async move {
        let mut backs: HashMap<SocketAddr, Arc<tokio::net::UdpSocket>> = HashMap::new();
        let mut buf = vec![0u8; 65535];
        let mut n: u64 = 0;
        loop {
            let Ok((len, src)) = front.recv_from(&mut buf).await else { break };
            n = n.wrapping_add(1);
            if loss_pct > 0 && (n % 100) < u64::from(loss_pct) {
                continue;
            }
            if !backs.contains_key(&src) {
                let std_sock = match std::net::UdpSocket::bind("127.0.0.1:0") {
                    Ok(s) => s,
                    Err(_) => continue,
                };
                if std_sock.set_nonblocking(true).is_err() {
                    continue;
                }
                let back = match tokio::net::UdpSocket::from_std(std_sock) {
                    Ok(s) => Arc::new(s),
                    Err(_) => continue,
                };
                let back_r = back.clone();
                let front_r = front.clone();
                let delay = delay_ms;
                tokio::spawn(async move {
                    let mut b = vec![0u8; 65535];
                    loop {
                        let Ok((len, _)) = back_r.recv_from(&mut b).await else { break };
                        if delay > 0 {
                            tokio::time::sleep(Duration::from_millis(delay)).await;
                        }
                        if front_r.send_to(&b[..len], src).await.is_err() {
                            break;
                        }
                    }
                });
                backs.insert(src, back);
            }
            let Some(back) = backs.get(&src) else { continue };
            if delay_ms > 0 {
                tokio::time::sleep(Duration::from_millis(delay_ms)).await;
            }
            let _ = back.send_to(&buf[..len], upstream).await;
        }
    });
    Ok(addr)
}

fn wt_client() -> moq_tokio::Client {
    let mut config = moq_tokio::connect::Config::default();
    config.tls.insecure = Some(true);
    config.bind = Some("127.0.0.1:0".parse().unwrap());
    config.init(Default::default()).expect("client").with_reconnect(false)
}

async fn run_wt(opts: &Opts, addr: SocketAddr, key: &Key, totals: Arc<Totals>) -> anyhow::Result<()> {
    let mut joins = Vec::new();
    for room in 0..opts.rooms {
        for p in 0..opts.participants {
            let late = room == 0 && opts.participants > 1 && p + 1 == opts.participants;
            let token = room_token(key, &format!("room{room}"), &format!("p{p}"));
            let url: url::Url = format!("https://{addr}/?jwt={token}").parse()?;
            let totals = totals.clone();
            let seconds = opts.seconds;
            let video_kbps = opts.video_kbps;
            let participants = opts.participants;
            joins.push(tokio::spawn(async move {
                if late {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
                if let Err(err) = one_wt(url, p, participants, seconds, video_kbps, late, totals.clone()).await {
                    eprintln!("wt p{p} room failed: {err}");
                    totals.session_errors.fetch_add(1, Ordering::Relaxed);
                }
            }));
        }
    }
    for join in joins {
        join.await.ok();
    }
    Ok(())
}

async fn one_wt(
    url: url::Url,
    me: u32,
    participants: u32,
    seconds: u64,
    video_kbps: u64,
    joiner: bool,
    totals: Arc<Totals>,
) -> anyhow::Result<()> {
    let began = Instant::now();
    let pub_origin = moq_tokio::origin::spawn();
    let path = format!("p{me}");
    let routed = pub_origin
        .route(path.as_str(), moq_net::origin::RouteOptions::default())
        .map_err(|err| anyhow::anyhow!("route: {err}"))?;
    let audio = routed
        .broadcast()
        .create_track("audio", timed())
        .map_err(|err| anyhow::anyhow!("audio: {err}"))?;
    let video = routed
        .broadcast()
        .create_track("video", timed())
        .map_err(|err| anyhow::anyhow!("video: {err}"))?;
    let sub_origin = moq_tokio::origin::spawn();
    let table = sub_origin.consume();
    let session = wt_client()
        .with_publisher(pub_origin.consume())
        .with_subscriber(sub_origin)
        .connect(url)
        .established()
        .await?;
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let (delta, keyframe) = video_sizes(video_kbps);
    let audio_pub = {
        let totals = totals.clone();
        tokio::spawn(async move { publish_track(audio, Duration::from_millis(20), 0, 80, 80, deadline, totals).await })
    };
    let video_pub = {
        let totals = totals.clone();
        tokio::spawn(async move { publish_track(video, Duration::from_millis(33), 60, delta, keyframe, deadline, totals).await })
    };
    let mut readers = Vec::new();
    for other in 0..participants {
        if other == me {
            continue;
        }
        let other_path = format!("p{other}");
        let requested = match wait_request(&table, &other_path).await {
            Ok(req) => req,
            Err(err) => {
                eprintln!("request {other_path}: {err}");
                totals.session_errors.fetch_add(1, Ordering::Relaxed);
                continue;
            }
        };
        for name in ["audio", "video"] {
            let track = match requested.track(name) {
                Ok(t) => t,
                Err(err) => {
                    eprintln!("track {other_path}/{name}: {err}");
                    continue;
                }
            };
            let totals = totals.clone();
            let mark = joiner && name == "video";
            readers.push(tokio::spawn(async move {
                read_track(track, deadline, mark, began, totals).await;
            }));
        }
    }
    audio_pub.await.ok();
    video_pub.await.ok();
    for reader in readers {
        reader.await.ok();
    }
    drop(session);
    Ok(())
}

async fn publish_track(
    track: moq_net::track::Producer,
    every: Duration,
    key_every: u32,
    delta: usize,
    keyframe: usize,
    deadline: Instant,
    totals: Arc<Totals>,
) {
    let mut tick = tokio::time::interval(every);
    let mut seq = 0u32;
    let mut n = 0u32;
    loop {
        tick.tick().await;
        if Instant::now() >= deadline {
            break;
        }
        let size = if key_every > 0 && n % key_every == 0 { keyframe } else { delta };
        n = n.wrapping_add(1);
        let Ok(mut group) = track.append_group(stamp()) else { break };
        if group.write_frame(stamp(), payload(seq, size)).is_err() {
            break;
        }
        if group.finish().is_err() {
            break;
        }
        seq = seq.wrapping_add(1);
        totals.published.fetch_add(1, Ordering::Relaxed);
    }
}

async fn wait_request(
    table: &moq_net::origin::Consumer,
    path: &str,
) -> anyhow::Result<moq_net::broadcast::Consumer> {
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        match tokio::time::timeout(Duration::from_millis(700), table.request(path, None)).await {
            Ok(Ok(req)) => return Ok(req),
            Ok(Err(err)) => {
                let text = err.to_string();
                if Instant::now() >= deadline || !text.to_ascii_lowercase().contains("unrout") {
                    anyhow::bail!("{text}");
                }
                tokio::time::sleep(Duration::from_millis(40)).await;
            }
            Err(_) => {
                if Instant::now() >= deadline {
                    anyhow::bail!("timeout");
                }
            }
        }
    }
}

async fn read_track(
    track: moq_net::track::Consumer,
    deadline: Instant,
    joiner: bool,
    began: Instant,
    totals: Arc<Totals>,
) {
    let mut reader = match track.subscribe(None).await {
        Ok(r) => r,
        Err(err) => {
            eprintln!("subscribe: {err}");
            totals.session_errors.fetch_add(1, Ordering::Relaxed);
            return;
        }
    };
    let mut prev: Option<u32> = None;
    let mut marked = false;
    let mut got = 0u64;
    let mut holes = 0u64;
    while Instant::now() < deadline + Duration::from_millis(400) {
        let left = deadline.saturating_duration_since(Instant::now()) + Duration::from_millis(200);
        let group = tokio::time::timeout(left, reader.recv_group()).await;
        let Ok(Ok(Some(mut group))) = group else { break };
        loop {
            let frame = match group.read_frame().await {
                Ok(Some(frame)) => frame,
                Ok(None) => break,
                Err(_) => break,
            };
            let Some((sent_ms, seq)) = parse_payload(&frame.payload) else { continue };
            if let Some(prev) = prev {
                if seq > prev.saturating_add(1) {
                    let gap = u64::from(seq - prev - 1);
                    holes += gap;
                    totals.skipped.fetch_add(gap, Ordering::Relaxed);
                }
            }
            prev = Some(seq);
            got += 1;
            let now = wall_ms();
            if now >= sent_ms {
                totals.note_latency(((now - sent_ms) as u32).saturating_mul(1000));
            }
            totals.delivered.fetch_add(1, Ordering::Relaxed);
            if joiner && !marked {
                marked = true;
                totals.first_frame_us.store(began.elapsed().as_micros() as u64, Ordering::Relaxed);
            }
        }
    }
    if prev.is_some() {
        totals.span.fetch_add(got + holes, Ordering::Relaxed);
    }
}

async fn run_iroh(opts: &Opts, relay_id: &str, key: &Key, totals: Arc<Totals>) -> anyhow::Result<()> {
    let relay: iroh::EndpointId = relay_id.parse()?;
    let mut joins = Vec::new();
    for room in 0..opts.rooms {
        for p in 0..opts.participants {
            let late = room == 0 && opts.participants > 1 && p + 1 == opts.participants;
            let token = room_token(key, &format!("room{room}"), &format!("p{p}"));
            let totals = totals.clone();
            let seconds = opts.seconds;
            let video_kbps = opts.video_kbps;
            let participants = opts.participants;
            joins.push(tokio::spawn(async move {
                if late {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
                if let Err(err) = one_iroh(relay, token, room, p, participants, seconds, video_kbps, late, totals.clone()).await {
                    eprintln!("iroh p{p} failed: {err}");
                    totals.session_errors.fetch_add(1, Ordering::Relaxed);
                }
            }));
        }
    }
    for join in joins {
        join.await.ok();
    }
    Ok(())
}

async fn wait_iroh(node: &iroh_live::Node, path: &str) -> anyhow::Result<iroh_live::Subscription> {
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        match tokio::time::timeout(Duration::from_secs(2), node.subscribe(path, iroh_live::Reach::Relays)).await {
            Ok(Ok(sub)) => return Ok(sub),
            Ok(Err(err)) => {
                if Instant::now() >= deadline {
                    anyhow::bail!("{err}");
                }
                tokio::time::sleep(Duration::from_millis(40)).await;
            }
            Err(_) => {
                if Instant::now() >= deadline {
                    anyhow::bail!("timeout");
                }
            }
        }
    }
}

async fn one_iroh(
    relay: iroh::EndpointId,
    token: String,
    room: u32,
    me: u32,
    participants: u32,
    seconds: u64,
    video_kbps: u64,
    joiner: bool,
    totals: Arc<Totals>,
) -> anyhow::Result<()> {
    let began = Instant::now();
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::N0).bind().await?;
    let node = iroh_live::Node::new(endpoint, iroh_live::NodeConfig::default());
    // consume stays on: false keeps the relay's routes out of this node's table,
    // which is what a publish-only example wants and what makes subscribe fail.
    let config = iroh_live::RelayConfig::iroh(relay).with_token(token.parse()?);
    let link = node.attach_relay(config)?;
    let mut status = link.status();
    tokio::time::timeout(Duration::from_secs(10), async {
        while status.get() != iroh_live::RelayStatus::Connected {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .map_err(|_| anyhow::anyhow!("iroh link not connected"))?;
    // Iroh announces the absolute path. WebTransport sessions are already rooted
    // at the token root, so they publish `p{me}` instead.
    let own = format!("t/{}/room{room}/p{me}", owner());
    let publication = node
        .publish(own.as_str(), iroh_live::Audience::Granted)
        .map_err(|err| anyhow::anyhow!("publish: {err}"))?;
    let audio = publication
        .broadcast()
        .create_track("audio", timed())
        .map_err(|err| anyhow::anyhow!("audio: {err}"))?;
    let video = publication
        .broadcast()
        .create_track("video", timed())
        .map_err(|err| anyhow::anyhow!("video: {err}"))?;
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let (delta, keyframe) = video_sizes(video_kbps);
    let audio_pub = {
        let totals = totals.clone();
        tokio::spawn(async move { publish_track(audio, Duration::from_millis(20), 0, 80, 80, deadline, totals).await })
    };
    let video_pub = {
        let totals = totals.clone();
        tokio::spawn(async move { publish_track(video, Duration::from_millis(33), 60, delta, keyframe, deadline, totals).await })
    };
    let mut readers = Vec::new();
    for other in 0..participants {
        if other == me {
            continue;
        }
        let sub = match wait_iroh(&node, &format!("t/{}/room{room}/p{other}", owner())).await {
            Ok(sub) => sub,
            Err(err) => {
                eprintln!("iroh subscribe p{other}: {err}");
                totals.session_errors.fetch_add(1, Ordering::Relaxed);
                continue;
            }
        };
        for name in ["audio", "video"] {
            let track = match sub.broadcast().track(name) {
                Ok(t) => t,
                Err(err) => {
                    eprintln!("iroh track {name}: {err}");
                    continue;
                }
            };
            let totals = totals.clone();
            let mark = joiner && name == "video";
            readers.push(tokio::spawn(async move {
                read_track(track, deadline, mark, began, totals).await;
            }));
        }
    }
    audio_pub.await.ok();
    video_pub.await.ok();
    for reader in readers {
        reader.await.ok();
    }
    link.detach().await;
    Ok(())
}

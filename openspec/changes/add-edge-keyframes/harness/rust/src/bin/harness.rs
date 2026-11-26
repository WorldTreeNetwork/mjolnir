//! Spike harness tools (not product code).
//!
//!   harness relay <priv>                         in-process moq-relay + Mjolnir WebTransport decider;
//!                                                writes <priv>/relay.txt, verify.json, private.json (0600)
//!   harness mint <priv> <room> <participant> <seconds> [owner-byte]
//!                                                a token shaped as Mjolnir.Relay.Mint signs it
//!   harness publish <url-with-jwt> <broadcast>   fMP4 on stdin -> MoQ broadcast (hang catalog)
//!   harness export <url-with-jwt> <broadcast> <seconds> <out.mkv>
//!                                                MoQ broadcast -> Matroska file (content checked by ffmpeg)
//!   harness catalog <url-with-jwt> <broadcast>   print the hang catalog JSON
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use moq_auth::{Algorithm, Claims, Key, KeyId, KeySet};
use moq_mux::catalog::Stream as _;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn cert_pair(dir: &Path) -> (PathBuf, PathBuf) {
    let key = rcgen::KeyPair::generate().unwrap();
    let params = rcgen::CertificateParams::new(vec!["localhost".into()]).unwrap();
    let cert = params.self_signed(&key).unwrap();
    let cert_path = dir.join("relay.pem");
    let key_path = dir.join("relay-tls-key.pem");
    std::fs::write(&cert_path, cert.pem()).unwrap();
    std::fs::write(&key_path, key.serialize_pem()).unwrap();
    (cert_path, key_path)
}

fn client() -> moq_tokio::Client {
    let mut config = moq_tokio::connect::Config::default();
    config.tls.insecure = Some(true);
    config.bind = Some("127.0.0.1:0".parse().unwrap());
    config.init(Default::default()).unwrap().with_reconnect(false)
}

async fn relay(dir: PathBuf) -> anyhow::Result<()> {
    let (cert, tls_key) = cert_pair(&dir);
    let _ = moq_tokio::crypto::install_default();
    let mut config = moq_relay::Config::default();
    config.listen.bind = Some("127.0.0.1:0".parse().unwrap());
    config.listen.tls.cert = vec![cert];
    config.listen.tls.key = vec![tls_key];
    config.web.ws = false;
    let mut relay = moq_relay::Relay::load(config).await?.with_signals(false);
    let quic = relay.quic_addr().unwrap();
    let admissions = relay.admissions().unwrap();
    let ready = relay.ready();
    let join = tokio::spawn(relay.run());
    ready.wait().await.map_err(|e| anyhow::anyhow!("{e:?}"))?;
    // Dummy spike key, kid "spike-dummy". Generated per run; never leaves <priv>.
    let key = Key::generate(Algorithm::EdDSA, Some(KeyId::decode("spike-dummy").unwrap())).unwrap();
    let public = KeySet { keys: vec![Arc::new(key.public().unwrap())] };
    std::fs::write(dir.join("verify.json"), public.to_str().unwrap())?;
    let private = KeySet { keys: vec![Arc::new(key)] };
    private.to_file(dir.join("private.json"))?;
    mjolnir_relay::spawn_web_decider(
        admissions,
        Arc::new(Mutex::new(public)),
        Arc::new(AtomicBool::new(false)),
        Arc::new(AtomicBool::new(true)),
        mjolnir_relay::DEFAULT_MAX_TTL,
    );
    std::fs::write(dir.join("relay.txt"), quic.to_string())?;
    println!("relay up quic={quic}");
    let stop = dir.join("stop");
    while !stop.exists() && !join.is_finished() {
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    println!("relay stopping");
    Ok(())
}

fn mint(dir: &Path, room: &str, participant: &str, seconds: u64, owner_byte: u8) -> anyhow::Result<String> {
    let file = std::env::var("MINT_KEYFILE").map(PathBuf::from).unwrap_or_else(|_| dir.join("private.json"));
    let set = KeySet::from_file(file).map_err(|e| anyhow::anyhow!("{e}"))?;
    let owner = bs58::encode([owner_byte; 32]).into_string();
    let now = kio::clock::wall();
    let claims = Claims::default()
        .with_root(format!("t/{owner}/{room}"))
        .with_publish([format!("{participant}/**").parse().unwrap()])
        .with_subscribe(["**".parse().unwrap()])
        .with_issued(now)
        .with_expires(now + Duration::from_secs(seconds));
    Ok(set.sign(&claims).map_err(|e| anyhow::anyhow!("{e}"))?)
}

async fn publish(url: url::Url, path: String) -> anyhow::Result<()> {
    let origin = moq_tokio::origin::spawn();
    let route = origin.route(path.as_str(), moq_net::origin::RouteOptions::default())?;
    let mut broadcast = route.broadcast().clone();
    let catalog = moq_mux::catalog::Producer::new(&mut broadcast, moq_mux::catalog::Config::default())?;
    let format: moq_mux::import::ContainerFormat = std::env::var("PUBLISH_FORMAT").unwrap_or("fmp4".into()).parse()?;
    let init = moq_mux::import::ContainerInit::new(format, bytes::Bytes::new());
    let mut import: moq_mux::import::Container = moq_mux::import::Container::new(broadcast, catalog.reserve(), &init)?;
    let session = client().with_publisher(origin.consume()).connect(url).established().await?;
    println!("publish held path={path}");
    let mut stdin = tokio::io::stdin();
    let mut buf = vec![0u8; 64 * 1024];
    let mut total = 0usize;
    loop {
        tokio::select! {
            n = stdin.read(&mut buf) => {
                let n = n?;
                if n == 0 { break; }
                total += n;
                import.decode(&buf[..n])?;
            }
            res = session.closed() => { println!("publish relay session closed: {res:?}"); break; }
        }
    }
    println!("publish done path={path} bytes_in={total}");
    let _ = import.finish();
    tokio::time::sleep(Duration::from_millis(500)).await;
    drop(route);
    Ok(())
}

async fn resolve(url: url::Url, path: &str) -> anyhow::Result<(moq_tokio::Connection, moq_net::origin::Producer, moq_mux::Source)> {
    let origin = moq_tokio::origin::spawn();
    let session = client().with_subscriber(origin.clone()).connect(url).established().await?;
    let consumer = origin.consume();
    let mut follow = consumer.follow(path, None)?;
    let broadcast = tokio::time::timeout(Duration::from_secs(15), follow.available())
        .await
        .map_err(|_| anyhow::anyhow!("broadcast {path} never announced"))??
        .ok_or_else(|| anyhow::anyhow!("broadcast {path} offline"))?;
    Ok((session, origin, moq_mux::Source::new(consumer, broadcast)))
}

async fn export(url: url::Url, path: String, seconds: u64, out: PathBuf) -> anyhow::Result<()> {
    let (session, _origin, source) = resolve(url, &path).await?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
    let (mut bytes, mut chunks, mut segment) = (0usize, 0usize, 0usize);
    // A WHIP ingest publishes a new rendition when the encoder changes resolution (H.264, VP9,
    // AV1) and adds renditions one by one, while an MKV header is final once written. So each
    // layout change rolls to a new segment file: <out>.<n>.mkv.
    let why = 'outer: loop {
        let mut probe: moq_mux::catalog::Consumer<()> = source.catalog(moq_mux::catalog::CatalogFormat::Hang).await?;
        let want_audio = std::env::var("EXPORT_VIDEO_ONLY").is_err();
        let _ = tokio::time::timeout_at(deadline, async {
            while let Ok(Some(c)) = probe.next().await {
                if (!c.video.renditions.is_empty() || std::env::var("EXPORT_AUDIO_ONLY").is_ok()) && (!want_audio || !c.audio.renditions.is_empty()) {
                    break;
                }
            }
        })
        .await;
        let catalog: moq_mux::catalog::Consumer<()> = source.catalog(moq_mux::catalog::CatalogFormat::Hang).await?;
        let mut selection = moq_mux::select::Broadcast::default().audio(moq_mux::select::Audio::default());
        if std::env::var("EXPORT_AUDIO_ONLY").is_err() {
            selection = selection.video(moq_mux::select::Video::default());
        }
        let stream = catalog.select(selection);
        let delay = moq_net::track::Delay::default().with_min(None).with_max(Duration::from_secs(std::env::var("EXPORT_MAX_DELAY").ok().and_then(|v| v.parse().ok()).unwrap_or(2)));
        let mut export = moq_mux::container::mkv::Export::new(source.clone(), stream).with_delay(delay);
        segment += 1;
        let mut file = tokio::fs::File::create(out.with_extension(format!("{segment}.mkv"))).await?;
        loop {
            match tokio::time::timeout_at(deadline, export.next()).await {
                Err(_) => break 'outer "deadline".to_string(),
                Ok(Ok(Some(chunk))) => {
                    bytes += chunk.len();
                    chunks += 1;
                    file.write_all(&chunk).await?;
                }
                Ok(Ok(None)) => break 'outer "broadcast ended".to_string(),
                Ok(Err(err)) if err.to_string().contains("layout changed") => {
                    println!("export segment={segment} rolled: {err}");
                    file.flush().await?;
                    continue 'outer;
                }
                Ok(Err(err)) => break 'outer format!("error: {err}"),
            }
        }
    };
    println!("export path={path} segments={segment} chunks={chunks} bytes={bytes} end={why}");
    drop(session);
    Ok(())
}

/// A plain MoQ subscriber (no player latency logic): the newest video rendition to IVF (VP8, VP9,
/// AV1) or Annex-B (H.264), and the first audio rendition to Ogg Opus, for ffmpeg to decode.
async fn raw(url: url::Url, path: String, seconds: u64, out: PathBuf) -> anyhow::Result<()> {
    let (session, _origin, source) = resolve(url, &path).await?;
    let mut catalog: moq_mux::catalog::Consumer<()> = source.catalog(moq_mux::catalog::CatalogFormat::Hang).await?;
    // Wait (briefly) for a catalog that names both media.
    let mut snap = None;
    let _ = tokio::time::timeout(Duration::from_secs(8), async {
        while let Ok(Some(c)) = catalog.next().await {
            let full = !c.video.renditions.is_empty() && !c.audio.renditions.is_empty();
            snap = Some(c);
            if full { break; }
        }
    }).await;
    let snap = snap.ok_or_else(|| anyhow::anyhow!("no catalog"))?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
    let mut tasks = Vec::new();
    if let Some((name, config)) = snap.video.renditions.iter().last() {
        let codec = format!("{:?}", config.codec);
        let kind = if codec.starts_with("VP8") { "VP80" } else if codec.starts_with("VP9") { "VP90" } else if codec.starts_with("AV1") { "AV01" } else { "h264" };
        let (w, h) = (config.coded_width.unwrap_or(0) as u16, config.coded_height.unwrap_or(0) as u16);
        let reader = source.broadcast().track(name.as_str())?.subscribe(None).await?;
        let file = out.with_extension(if kind == "h264" { "h264" } else { "ivf" });
        let name = name.clone();
        let t0 = std::time::Instant::now();
        tasks.push(tokio::spawn(async move {
            let payloads = collect_timed(&name, reader, deadline, t0).await;
            let mut buf = Vec::new();
            if kind == "h264" {
                for p in &payloads { annexb(p, &mut buf); }
            } else {
                buf.extend_from_slice(b"DKIF"); buf.extend_from_slice(&0u16.to_le_bytes()); buf.extend_from_slice(&32u16.to_le_bytes());
                buf.extend_from_slice(kind.as_bytes()); buf.extend_from_slice(&w.to_le_bytes()); buf.extend_from_slice(&h.to_le_bytes());
                buf.extend_from_slice(&30u32.to_le_bytes()); buf.extend_from_slice(&1u32.to_le_bytes());
                buf.extend_from_slice(&(payloads.len() as u32).to_le_bytes()); buf.extend_from_slice(&0u32.to_le_bytes());
                for (i, p) in payloads.iter().enumerate() {
                    buf.extend_from_slice(&(p.len() as u32).to_le_bytes()); buf.extend_from_slice(&(i as u64).to_le_bytes()); buf.extend_from_slice(p);
                }
            }
            std::fs::write(&file, buf).ok();
            format!("video track={name} codec={codec} frames={}", payloads.len())
        }));
    }
    if let Some((name, config)) = snap.audio.renditions.iter().next() {
        let reader = source.broadcast().track(name.as_str())?.subscribe(None).await?;
        let channels = config.channel_count as u8;
        let file = out.with_extension("opus");
        let name = name.clone();
        tasks.push(tokio::spawn(async move {
            let payloads = collect(reader, deadline).await;
            std::fs::write(&file, ogg_opus(&payloads, channels)).ok();
            format!("audio track={name} packets={}", payloads.len())
        }));
    }
    let mut lines = Vec::new();
    for t in tasks { lines.push(t.await?); }
    println!("raw path={path} {}", lines.join(" "));
    drop(session);
    Ok(())
}

async fn collect_timed(
    track: &str,
    reader: moq_net::track::Subscriber,
    deadline: tokio::time::Instant,
    t0: std::time::Instant,
) -> Vec<bytes::Bytes> {
    let mut out = Vec::new();
    let mut reader = reader;
    let mut index = 0u64;
    while let Ok(Ok(Some(mut group))) = tokio::time::timeout_at(deadline, reader.recv_group()).await {
        let group_start = index;
        index += 1;
        while let Ok(Ok(Some(frame))) = tokio::time::timeout_at(deadline, group.read_frame()).await {
            println!(
                "raw-frame track={track} group_start={group_start} bytes={} media={:?} wall_ms={}",
                frame.payload.len(),
                frame.timestamp,
                t0.elapsed().as_millis()
            );
            if let Ok(f) = hang::container::Frame::decode(frame.payload.clone()) {
                out.push(f.payload);
            }
        }
    }
    out
}

async fn collect(mut reader: moq_net::track::Subscriber, deadline: tokio::time::Instant) -> Vec<bytes::Bytes> {
    let mut out = Vec::new();
    while let Ok(Ok(Some(mut group))) = tokio::time::timeout_at(deadline, reader.recv_group()).await {
        while let Ok(Ok(Some(frame))) = tokio::time::timeout_at(deadline, group.read_frame()).await {
            if let Ok(f) = hang::container::Frame::decode(frame.payload.clone()) { out.push(f.payload); }
        }
    }
    out
}

/// H.264 access units arrive either as Annex-B or 4-byte length-prefixed NAL units.
fn annexb(p: &[u8], out: &mut Vec<u8>) {
    if p.starts_with(&[0, 0, 0, 1]) || p.starts_with(&[0, 0, 1]) { out.extend_from_slice(p); return; }
    let mut i = 0;
    while i + 4 <= p.len() {
        let n = u32::from_be_bytes([p[i], p[i + 1], p[i + 2], p[i + 3]]) as usize;
        i += 4;
        if i + n > p.len() { break; }
        out.extend_from_slice(&[0, 0, 0, 1]); out.extend_from_slice(&p[i..i + n]); i += n;
    }
}

fn ogg_crc(data: &[u8]) -> u32 {
    let mut crc = 0u32;
    for &b in data {
        crc ^= (b as u32) << 24;
        for _ in 0..8 { crc = if crc & 0x8000_0000 != 0 { (crc << 1) ^ 0x04c1_1db7 } else { crc << 1 }; }
    }
    crc
}

fn ogg_page(out: &mut Vec<u8>, flags: u8, granule: u64, seq: u32, packet: &[u8]) {
    let mut lacing = vec![255u8; packet.len() / 255];
    lacing.push((packet.len() % 255) as u8);
    let start = out.len();
    out.extend_from_slice(b"OggS"); out.push(0); out.push(flags);
    out.extend_from_slice(&granule.to_le_bytes()); out.extend_from_slice(&0x5350_494bu32.to_le_bytes());
    out.extend_from_slice(&seq.to_le_bytes()); out.extend_from_slice(&0u32.to_le_bytes());
    out.push(lacing.len() as u8); out.extend_from_slice(&lacing); out.extend_from_slice(packet);
    let crc = ogg_crc(&out[start..]);
    out[start + 22..start + 26].copy_from_slice(&crc.to_le_bytes());
}

/// Opus samples per packet at 48 kHz, from the TOC byte (RFC 6716 section 3.1).
fn opus_samples(p: &[u8]) -> u64 {
    if p.is_empty() { return 960; }
    let config = p[0] >> 3;
    let frame = match config {
        0..=11 => [480, 960, 1920, 2880][(config % 4) as usize],
        12..=15 => [480, 960][(config % 2) as usize],
        _ => [120, 240, 480, 960][(config % 4) as usize],
    };
    let count = match p[0] & 3 { 0 => 1, 1 | 2 => 2, _ => p.get(1).map(|c| (c & 0x3f) as u64).unwrap_or(1) };
    frame * count
}

fn ogg_opus(packets: &[bytes::Bytes], channels: u8) -> Vec<u8> {
    let mut out = Vec::new();
    let mut head = b"OpusHead".to_vec();
    head.push(1); head.push(channels.max(1)); head.extend_from_slice(&312u16.to_le_bytes());
    head.extend_from_slice(&48000u32.to_le_bytes()); head.extend_from_slice(&0u16.to_le_bytes()); head.push(0);
    ogg_page(&mut out, 2, 0, 0, &head);
    let mut tags = b"OpusTags".to_vec();
    tags.extend_from_slice(&5u32.to_le_bytes()); tags.extend_from_slice(b"spike"); tags.extend_from_slice(&0u32.to_le_bytes());
    ogg_page(&mut out, 0, 0, 1, &tags);
    let mut granule = 0u64;
    for (i, p) in packets.iter().enumerate() {
        granule += opus_samples(p);
        ogg_page(&mut out, if i + 1 == packets.len() { 4 } else { 0 }, granule, i as u32 + 2, p);
    }
    out
}

/// The add-call-e2ee room credential, with the spike's dummy secret (32 x 0x11, kid 1).
fn credential(owner_byte: u8) -> moq_e2ee::Credential {
    let owner = bs58::encode([owner_byte; 32]).into_string();
    moq_e2ee::Credential::new(moq_e2ee::credential::Config {
        context: format!("mjolnir-call/v1/{owner}/r1").into(),
        kid: 1,
        secret: [0x11; 32],
    })
    .unwrap()
}

/// S7 publisher: real media (fMP4 on stdin) imported into a local plaintext hang broadcast, then
/// every track bridged frame by frame into a moq-e2ee protected broadcast at `<label>/<credential
/// path>`, as the add-call-e2ee page does. Writes the token-relative path to <priv>/protected-path.txt.
async fn protected_pub(dir: &Path, url: url::Url, label: String) -> anyhow::Result<()> {
    let local = moq_tokio::origin::spawn();
    let src = local.route("src", moq_net::origin::RouteOptions::default())?;
    let mut plain = src.broadcast().clone();
    let catalog = moq_mux::catalog::Producer::new(&mut plain, moq_mux::catalog::Config::default())?;
    let mut import = moq_mux::container::fmp4::Import::new(plain.clone(), catalog.timebase().reserve());
    let cred = credential(9);
    let path = format!("{label}/{}", cred.path("call")?);
    std::fs::write(dir.join("protected-path.txt"), &path)?;
    let generation = cred.produce();
    let remote = moq_tokio::origin::spawn();
    let options = moq_net::origin::RouteOptions::hidden().with_instance(generation.epoch().instance(), 0);
    let route = remote.route(path.as_str(), options)?;
    let protected = moq_e2ee::broadcast::Producer::new(route.broadcast().clone(), generation.clone());
    let session = client().with_publisher(remote.consume()).connect(url).established().await?;
    let feeder = tokio::spawn(async move {
        let mut stdin = tokio::io::stdin();
        let mut buf = vec![0u8; 64 * 1024];
        while let Ok(n) = stdin.read(&mut buf).await {
            if n == 0 || import.decode(&buf[..n]).is_err() { break; }
        }
    });
    let mut names = vec![hang::Catalog::DEFAULT_NAME.to_string()];
    for _ in 0..100 {
        let snap = catalog.snapshot();
        if !snap.video.renditions.is_empty() && !snap.audio.renditions.is_empty() {
            names.extend(snap.video.renditions.keys().cloned());
            names.extend(snap.audio.renditions.keys().cloned());
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let consumer = plain.consume();
    let mut bridges = Vec::new();
    for name in &names {
        let mut reader = consumer.track(name.as_str())?.subscribe(None).await?;
        let mut writer = protected.create_track(name, timed())?;
        bridges.push(tokio::spawn(async move {
            let mut frames = 0u64;
            while let Ok(Some(mut group)) = reader.recv_group().await {
                let Ok(mut out) = writer.append_group(now()) else { break };
                while let Ok(Some(frame)) = group.read_frame().await {
                    if out.write_frame(now(), &frame.payload).is_err() { break; }
                    frames += 1;
                }
                let _ = out.finish();
            }
            frames
        }));
    }
    route.announce()?;
    println!("protected publish path={path} tracks={names:?}");
    let _ = feeder.await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    for (name, b) in names.iter().zip(bridges) {
        b.abort();
        let _ = name;
    }
    drop(session);
    Ok(())
}

/// S7 protected reader (credential holder): discover as the design does (only `<label>/<credential
/// path>` qualifies), then force-open `path` anyway and try to decrypt its tracks.
async fn protected_read(url: url::Url, label: String, path: String, seconds: u64) -> anyhow::Result<()> {
    let cred = credential(9);
    let expected = format!("{label}/{}", cred.path("call")?);
    let origin = moq_tokio::origin::spawn();
    let mut announced = origin.consume().announced();
    let session = client().with_subscriber(origin.clone()).connect(url).established().await?;
    let mut seen = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_millis(1500);
    while let Ok(Some(event)) = tokio::time::timeout_at(deadline, announced.next()).await {
        if let moq_net::announce::Event::Present(a) = event { seen.push(a.prefix.to_string()); }
    }
    let qualifying: Vec<_> = seen.iter().filter(|p| **p == expected).collect();
    println!("protected-read discovery: announced={seen:?} qualifying_for_label={qualifying:?}");
    let remote = tokio::time::timeout(Duration::from_secs(5), origin.consume().follow(path.as_str(), None)?.available())
        .await??
        .ok_or_else(|| anyhow::anyhow!("offline"))?;
    // Any epoch: the plaintext route carries none, and a protected reader has only its own.
    let reader = moq_e2ee::broadcast::Consumer::new(remote.clone(), cred.consume(cred.produce().epoch().clone()));
    for semantic in [hang::Catalog::DEFAULT_NAME, "0.vp8", "0.avc3", "1.opus"] {
        let attempt = tokio::time::timeout(Duration::from_secs(seconds), async {
            let mut track = reader.subscribe(semantic, None)?.await?;
            let mut group = track.recv_group().await?.ok_or_else(|| anyhow::anyhow!("track ended"))?;
            let frame = group.read_frame().await?;
            Ok::<_, anyhow::Error>(frame.map(|f| f.plaintext.len()))
        })
        .await;
        println!("protected-read forced path={path} semantic={semantic} -> {attempt:?}");
    }
    drop(session);
    Ok(())
}

async fn frames(url: url::Url, path: String, track: String, seconds: u64) -> anyhow::Result<()> {
    let (session, _origin, source) = resolve(url, &path).await?;
    let mut reader = source.broadcast().track(track.as_str())?.subscribe(None).await?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
    let (mut groups, mut frames, mut bytes) = (0, 0, 0);
    while let Ok(Ok(Some(mut group))) = tokio::time::timeout_at(deadline, reader.recv_group()).await {
        groups += 1;
        while let Ok(Ok(Some(frame))) = tokio::time::timeout_at(deadline, group.read_frame()).await {
            frames += 1;
            bytes += frame.payload.len();
        }
    }
    println!("frames path={path} track={track} groups={groups} frames={frames} bytes={bytes}");
    drop(session);
    Ok(())
}

async fn print_catalog(url: url::Url, path: String) -> anyhow::Result<()> {
    let (session, _origin, source) = resolve(url, &path).await?;
    let mut catalog: moq_mux::catalog::Consumer<()> = source.catalog(moq_mux::catalog::CatalogFormat::Hang).await?;
    let snap = tokio::time::timeout(Duration::from_secs(5), catalog.next()).await;
    println!("catalog path={path} {snap:?}");
    drop(session);
    Ok(())
}

/// Open a video track only after that rendition already has a group.
/// Announcement is not enough. A rendition change is the same test.
fn probe_decision(group_exists: bool, already_open: bool) -> &'static str {
    if already_open {
        "open"
    } else if group_exists {
        "open-after-group"
    } else {
        "hold"
    }
}

async fn probe_selftest() -> anyhow::Result<()> {
    let origin = moq_tokio::origin::spawn();
    let route = origin.route("probe", moq_net::origin::RouteOptions::default())?;
    let producer = route.broadcast().clone();
    let consumer = producer.consume();
    let mut opened = std::collections::BTreeSet::<String>::new();
    let mut joins_from_probe = 0u64;

    for (name, write_first) in [("0.vp8", true), ("1.vp8", false)] {
        let track = producer.create_track(name, timed())?;
        let decision = probe_decision(false, opened.contains(name));
        println!("probe track={name} at=announcement decision={decision}");
        if decision != "hold" {
            anyhow::bail!("probe subscribed {name} before a group existed");
        }
        if !write_first {
            println!("probe track={name} at=rendition-change decision=hold");
        }
        let mut group = track.append_group(now())?;
        group.write_frame(now(), bytes::Bytes::from_static(b"keyframe"))?;
        group.finish()?;
        let decision = probe_decision(true, opened.contains(name));
        println!("probe track={name} at=group-exists decision={decision}");
        if decision != "open-after-group" {
            anyhow::bail!("probe did not open {name} after its group");
        }
        let mut reader = consumer.track(name)?.subscribe(None).await?;
        opened.insert(name.to_string());
        let t0 = std::time::Instant::now();
        let mut got = reader.recv_group().await?.ok_or_else(|| anyhow::anyhow!("no group"))?;
        let frame = got.read_frame().await?.ok_or_else(|| anyhow::anyhow!("no frame"))?;
        println!(
            "raw-frame track={name} group_start=0 bytes={} media={:?} wall_ms={}",
            frame.payload.len(),
            frame.timestamp,
            t0.elapsed().as_millis()
        );
    }
    println!("join-cause PLIs from probe: {joins_from_probe}");
    println!("patch-only gate logs: unavailable");
    println!("probe-selftest ok renditions={}", opened.len());
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "warn".into()))
        .with_writer(std::io::stderr).with_ansi(false)
        .init();
    let _ = moq_tokio::crypto::install_default();
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args[0].as_str() {
        "relay" => relay(args[1].clone().into()).await,
        "keygen" => {
            // A second, unrelated dummy key: tokens it signs must be refused.
            let key = Key::generate(Algorithm::EdDSA, Some(KeyId::decode("spike-dummy").unwrap())).unwrap();
            KeySet { keys: vec![Arc::new(key)] }.to_file(&args[1])?;
            Ok(())
        }
        "mint" => {
            let owner = args.get(5).map(|s| s.parse()).transpose()?.unwrap_or(9u8);
            println!("{}", mint(Path::new(&args[1]), &args[2], &args[3], args[4].parse()?, owner)?);
            Ok(())
        }
        "publish" => publish(args[1].parse()?, args[2].clone()).await,
        "export" => export(args[1].parse()?, args[2].clone(), args[3].parse()?, args[4].clone().into()).await,
        "raw" => raw(args[1].parse()?, args[2].clone(), args[3].parse()?, args[4].clone().into()).await,
        "protected-pub" => protected_pub(Path::new(&args[1]), args[2].parse()?, args[3].clone()).await,
        "protected-read" => protected_read(args[1].parse()?, args[2].clone(), args[3].clone(), args[4].parse()?).await,
        "frames" => frames(args[1].parse()?, args[2].clone(), args[3].clone(), args[4].parse()?).await,
        "catalog" => print_catalog(args[1].parse()?, args[2].clone()).await,
        "probe-selftest" => probe_selftest().await,
        other => anyhow::bail!("unknown command {other}"),
    }
}

fn timed() -> moq_net::track::Info {
    moq_net::track::Info::default().with_timescale(moq_net::Timescale::MILLI)
}

fn now() -> moq_net::Timestamp {
    moq_net::Timestamp::from(moq_net::time::Instant::now())
}

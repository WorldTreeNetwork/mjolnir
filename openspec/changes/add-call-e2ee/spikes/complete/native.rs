//! Native (iroh-live) side of the call bridge, review B1 layout and the shared B5 wire surface:
//! `<label>/<path("call")>/<epoch>`, protected tracks under their semantic names, plus a protected
//! `bridge.tracks` manifest in the browser bridge's JSON format. Not product code.
#![allow(dead_code)]
use super::common::*;
use iroh_live::media::*;
use moq_net::broadcast::{Listed, TracksEvent};
use std::time::Duration;

pub struct NativePublisher {
    pub path: String,
    pub local: LocalBroadcast,
    _keep: Vec<Box<dyn std::any::Any + Send>>,
}

/// Publish a real H.264 + Opus `LocalBroadcast` through `Node::publish_with` (Iroh ingress), encrypted.
pub fn publish_native(node: &iroh_live::Node, label: &str, cred: &moq_e2ee::Credential) -> NativePublisher {
    let source = VideoSource::test_pattern(video::Size::new(320, 180), video::FrameRate::new(30, 1).unwrap()).unwrap();
    let local = LocalBroadcast::new();
    let mut encoding = VideoEncoding::single(VideoRendition::new("video").with_size(video::Size::new(320, 180)));
    encoding.renditions[0].config.kind = video::encode::Kind::Software;
    local.set_video(source, encoding).unwrap();
    local.set_audio(AudioSource::tone(440.0, audio::Layout::Mono).unwrap(), audio_encoding::voice()).unwrap();
    let generation = cred.produce();
    let opaque = cred.path("call").unwrap();
    let path = format!("{label}/{opaque}/{}", generation.epoch());
    let full = format!("t/{}/r1/{path}", owner());
    let (publication, protected) = node
        .publish_with(full.as_str(), iroh_live::Audience::Granted, |b| {
            Ok::<_, moq_e2ee::Error>(moq_e2ee::broadcast::Producer::new(b.clone(), generation))
        })
        .unwrap();
    let mut manifest = protected.create_track("bridge.tracks", timed()).unwrap();
    let plain = local.consume();
    let bridge = tokio::spawn(async move {
        let mut listing = plain.tracks().unwrap();
        let mut known = serde_json::Map::new();
        while let Some(ev) = listing.next().await.unwrap() {
            if let TracksEvent::Added { name, info: Listed::Track(info) } = ev {
                println!("native publish: listed {name} timescale {:?}", info.timescale);
                let mut out = protected.create_track(&name, info.clone()).unwrap();
                known.insert(name.to_string(), manifest_entry(&info));
                let stamp = moq_net::Timestamp::from(moq_net::time::Instant::now());
                let mut g = manifest.append_group(stamp).unwrap();
                g.write_frame(stamp, &serde_json::to_vec(&known).unwrap()).unwrap();
                g.finish().unwrap();
                let src = plain.clone();
                tokio::spawn(async move {
                    let mut sub = src.track(&name).unwrap().subscribe(None).await.unwrap();
                    while let Ok(Some(mut g)) = sub.recv_group().await {
                        let Ok(mut dest) = out.create_group(g.start) else { continue };
                        tokio::spawn(async move {
                            while let Ok(Some(f)) = g.read_frame().await {
                                if dest.write_frame(f.timestamp, &f.payload).is_err() {
                                    return;
                                }
                            }
                            let _ = dest.finish();
                        });
                    }
                });
            }
        }
    });
    NativePublisher { path, local, _keep: vec![Box::new(publication), Box::new(bridge)] }
}

/// Wait for an announcement under `label` whose opaque matches `cred.path("call")`; return the
/// relative path and the epoch parsed from its last segment (never from a producer object).
pub async fn discover(
    routes: &mut moq_net::origin::Routes,
    label: &str,
    cred: &moq_e2ee::Credential,
    within: Duration,
) -> Option<(String, moq_e2ee::Epoch)> {
    let opaque = cred.path("call").unwrap().to_string();
    let needle = format!("{label}/{opaque}/");
    let deadline = std::time::Instant::now() + within;
    while let Some(left) = deadline.checked_duration_since(std::time::Instant::now()) {
        let Ok(Some(event)) = tokio::time::timeout(left, routes.next()).await else { return None };
        let text = format!("{event:?}");
        if let Some(at) = text.find(&needle) {
            let rest: String = text[at + needle.len()..].chars().take(36).collect();
            if let Ok(epoch) = rest.parse::<moq_e2ee::Epoch>() {
                return Some((format!("{needle}{rest}"), epoch));
            }
        }
    }
    None
}

pub struct Playback {
    pub decoded_frames: usize,
    pub distinct_pixels: usize,
    pub audio_samples: usize,
    pub peak: f32,
    pub manifest: Vec<String>,
}

/// Decrypt a protected broadcast (manifest-driven) into a local mirror and play it with the
/// native iroh-live player. Fails if the codec is not one the native player decodes.
pub async fn read_and_play(
    table: &moq_net::origin::Consumer,
    path: &str,
    cred: &moq_e2ee::Credential,
    epoch: moq_e2ee::Epoch,
    frames: usize,
) -> anyhow::Result<Playback> {
    let remote = table.follow(path, None).unwrap().available().await?.ok_or_else(|| anyhow::anyhow!("no broadcast"))?;
    let cg = cred.consume(epoch);
    let metadata = remote.clone();
    let sealed = moq_e2ee::broadcast::Consumer::new(remote, cg.clone());
    let mirror_origin = moq_tokio::origin::spawn();
    let mirror_route = mirror_origin.route("local", moq_net::origin::RouteOptions::hidden()).unwrap();
    let mirror = mirror_route.broadcast().clone();
    let consumer = mirror.consume();
    let names = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let seen = names.clone();
    let decrypt = tokio::spawn(async move {
        let mut manifest = sealed.subscribe("bridge.tracks", None).unwrap().await.unwrap();
        let mut made = std::collections::HashSet::new();
        while let Ok(Some(mut g)) = manifest.recv_group().await {
            let Ok(Some(f)) = g.read_frame().await else { continue };
            let map: serde_json::Map<String, serde_json::Value> = serde_json::from_slice(&f.plaintext).unwrap();
            for (name, _meta) in map {
                if !made.insert(name.clone()) {
                    continue;
                }
                seen.lock().unwrap().push(name.clone());
                let info = metadata.track(cg.name(&name).unwrap().as_str()).unwrap().info().await.unwrap();
                let dest = mirror.create_track(name.as_str(), info).unwrap();
                let mut sub = sealed.subscribe(&name, None).unwrap().await.unwrap();
                tokio::spawn(async move {
                    let mut newest: Option<u64> = None;
                    while let Ok(Some(mut g)) = sub.recv_group().await {
                        if newest.is_some_and(|n| g.start() <= n) {
                            continue;
                        }
                        newest = Some(g.start());
                        let Ok(mut d) = dest.create_group(moq_net::group::Info { start: g.start() }) else { continue };
                        tokio::spawn(async move {
                            while let Ok(Some(f)) = g.read_frame().await {
                                if d.write_frame(f.timestamp, f.plaintext).is_err() {
                                    return;
                                }
                            }
                            let _ = d.finish();
                        });
                    }
                });
            }
        }
    });
    let result = async {
        let player = RemoteBroadcast::from_consumer(consumer).play(PlayerConfig::default().with_audio(AudioMode::Decode))?;
        let mut vf = player.video_frames();
        let mut af = player.audio_frames();
        let mut sums = std::collections::HashSet::new();
        let mut decoded = 0;
        for _ in 0..frames {
            let Some(f) = vf.next().await else { break };
            decoded += 1;
            let pixels = f.surface.to_i420()?;
            sums.insert(pixels.data().iter().enumerate().fold(0u64, |a, (i, b)| a.wrapping_add((i as u64 + 1) * u64::from(*b))));
        }
        let (mut samples, mut peak) = (0, 0f32);
        for _ in 0..20 {
            let Some(f) = af.next().await else { break };
            samples += f.samples.len();
            for x in f.samples.iter() {
                peak = peak.max(x.abs());
            }
        }
        anyhow::Ok(Playback { decoded_frames: decoded, distinct_pixels: sums.len(), audio_samples: samples, peak, manifest: vec![] })
    }
    .await;
    decrypt.abort();
    result.map(|mut p| {
        p.manifest = names.lock().unwrap().clone();
        p
    })
}

#![cfg(feature = "native-media")]
//! Review B5 cross-direction fixture, driven by complete/cross-drive.mjs:
//!  - native iroh-live publisher on label `nat` (H.264 + Opus) for a browser to read;
//!  - native reader of the browser publisher on label `alice`, decoded by the native player.
//! Both sides use the B1 layout and the same `bridge.tracks` manifest format.
#[path = "../../complete/common.rs"]
mod common;
#[path = "../../complete/native.rs"]
mod native;
use common::*;
use std::time::Duration;

#[tokio::test(flavor = "multi_thread")]
#[ignore = "local browser fixture only"]
async fn cross() {
    let dir = std::env::var("E2EE_PRIVATE").unwrap();
    let r = start().await;
    let (router, id) = iroh_relay(&r).await;
    let lines = format!(
        "{}\n{}\n{}\n{}\n{}\n",
        r.quic,
        owner(),
        room_token(&r.key, "r1", "alice", 3600),
        room_token(&r.key, "r1", "bob", 3600),
        room_token(&r.key, "r1", "carol", 3600)
    );
    let (node, link) = iroh_node(id, &room_token(&r.key, "r1", "nat", 3600)).await;
    let publisher = native::publish_native(&node, "nat", &label_credential([17; 32], 1, "nat"));
    std::fs::write(format!("{dir}/native-path.txt"), &publisher.path).unwrap();
    std::fs::write(format!("{dir}/admission.txt"), lines).unwrap();
    println!("cross: native publishing at {}", publisher.path);

    let origin = moq_tokio::origin::spawn();
    let table = origin.consume();
    let mut routes = table.routes();
    let _session = client()
        .with_subscriber(origin)
        .connect(url(&r, &room_token(&r.key, "r1", "dave", 3600)))
        .established()
        .await
        .unwrap();
    let out = dir.clone();
    tokio::spawn(async move {
        let cred = label_credential([17; 32], 1, "alice");
        let result = match native::discover(&mut routes, "alice", &cred, Duration::from_secs(900)).await {
            None => serde_json::json!({"error": "no alice announcement"}),
            Some((path, epoch)) => {
                println!("cross: native reader discovered {path}");
                match tokio::time::timeout(Duration::from_secs(60), native::read_and_play(&table, &path, &cred, epoch, 20)).await {
                    Ok(Ok(p)) => serde_json::json!({"path": path, "manifest": p.manifest, "decodedFrames": p.decoded_frames,
                        "distinctPixels": p.distinct_pixels, "audioSamples": p.audio_samples, "peak": p.peak}),
                    Ok(Err(e)) => serde_json::json!({"path": path, "error": format!("{e:#}")}),
                    Err(_) => serde_json::json!({"path": path, "error": "timeout: no decoded frames in 60 s"}),
                }
            }
        };
        println!("cross: NATIVE READS BROWSER {result}");
        std::fs::write(format!("{out}/native-read-browser.json"), result.to_string()).unwrap();
    });
    while !std::path::Path::new(&format!("{dir}/stop")).exists() {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    publisher.local.close();
    link.detach().await;
    node.shutdown().await;
    router.shutdown().await.unwrap();
    r.trigger.start();
}

#![cfg(feature = "native-media")]
//! Native iroh-live publisher (real H.264 + Opus) through Iroh ingress, read over WebTransport,
//! decrypted and decoded by the native player. Review B1 layout: context .../r1/<label>, path("call").
#[path = "../../complete/common.rs"]
mod common;
#[path = "../../complete/native.rs"]
mod native;
use common::*;
use std::time::Duration;

#[tokio::test(flavor = "multi_thread")]
async fn real_native_media() {
    tokio::time::timeout(Duration::from_secs(60), run()).await.expect("native media deadline");
}

async fn run() {
    let r = start().await;
    let (router, id) = iroh_relay(&r).await;
    let (node, link) = iroh_node(id, &room_token(&r.key, "r1", "alice", 60)).await;
    let publisher = native::publish_native(&node, "alice", &label_credential([17; 32], 1, "alice"));
    let origin = moq_tokio::origin::spawn();
    let table = origin.consume();
    let mut routes = table.routes();
    let session = client()
        .with_subscriber(origin)
        .connect(url(&r, &room_token(&r.key, "r1", "bob", 60)))
        .established()
        .await
        .unwrap();
    // The reader builds the credential for the label it saw announced, then checks the opaque.
    let reader = label_credential([17; 32], 1, "alice");
    let (path, epoch) = native::discover(&mut routes, "alice", &reader, Duration::from_secs(10)).await.expect("announcement");
    assert_eq!(path, publisher.path);
    // A credential for another label does not match this opaque.
    assert_ne!(label_credential([17; 32], 1, "bob").path("call").unwrap().as_str(), path.split('/').nth(1).unwrap());
    let p = native::read_and_play(&table, &path, &reader, epoch, 20).await.unwrap();
    assert!(p.decoded_frames >= 20 && p.distinct_pixels >= 10 && p.peak > 0.01);
    println!(
        "NATIVE PLAYBACK layout=label path={path} manifest={:?} decoded_frames={} distinct_pixels={} audio_samples={} peak={}",
        p.manifest, p.decoded_frames, p.distinct_pixels, p.audio_samples, p.peak
    );
    publisher.local.close();
    drop((publisher, session));
    link.detach().await;
    node.shutdown().await;
    router.shutdown().await.unwrap();
    r.trigger.start();
}

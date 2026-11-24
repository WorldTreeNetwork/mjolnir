//! Spike e2ee-iroh-live: an iroh-live `Node` publisher takes part in an encrypted room
//! with no iroh-live fork. `Node::publish_with` hands the caller the `moq_net` broadcast it
//! announces; the caller wraps it in `moq_e2ee::broadcast::Producer`. Media that iroh-live's
//! own pipeline writes in plaintext (`LocalBroadcast::consume()` is a `moq_net` broadcast
//! consumer) is bridged in-process, group for group, into the protected broadcast. Here a
//! plain local broadcast stands in for `LocalBroadcast` (same type), and a WebTransport
//! subscriber with the credential decrypts what the Iroh publisher sent.
mod common;
use common::*;

use std::time::Duration;

const MARKER: &[u8] = b"PLAINTEXT-MARKER";

/// Copy every group of `semantic` from a plaintext local track into the protected one.
async fn bridge(
    local: moq_net::broadcast::Consumer,
    semantic: &'static str,
    mut out: moq_e2ee::track::Producer,
) {
    let mut reader = local.track(semantic).unwrap().subscribe(None).await.unwrap();
    while let Ok(Some(mut group)) = reader.recv_group().await {
        let mut sealed = out.create_group(group.start).unwrap();
        while let Ok(Some(frame)) = group.read_frame().await {
            sealed.write_frame(frame.timestamp, &frame.payload).unwrap();
        }
        sealed.finish().unwrap();
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn iroh_live_node_publishes_a_protected_broadcast_without_a_fork() {
    let running = start().await;
    let (router, relay_id) = iroh_relay(&running).await;
    let cred = credential([7u8; 32], 1);
    let opaque = cred.path("call").unwrap();

    // Stand-in for iroh-live's `LocalBroadcast`: plaintext tracks on a local, unannounced route.
    let local_origin = moq_tokio::origin::spawn();
    let local_route = local_origin
        .route("local", moq_net::origin::RouteOptions::hidden())
        .unwrap();
    let catalog = local_route.broadcast().create_track("catalog.json", timed()).unwrap();
    let video = local_route.broadcast().create_track("video", timed()).unwrap();
    let local = local_route.broadcast().consume();
    let encoder = tokio::spawn(async move {
        let (mut catalog, mut video) = (catalog, video);
        for n in 0..80u32 {
            let mut g = catalog.append_group(now()).unwrap();
            g.write_frame(now(), br#"{"video":{"track":"video"}}"#.to_vec()).unwrap();
            g.finish().unwrap();
            let mut g = video.append_group(now()).unwrap();
            let mut f = MARKER.to_vec();
            f.extend_from_slice(format!("-iroh-{n}").as_bytes());
            g.write_frame(now(), f).unwrap();
            g.finish().unwrap();
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    });

    // The Iroh publisher, with the room token minted for alice.
    let (node, link) = iroh_node(relay_id, &room_token(&running.key, "r1", "alice", 60)).await;
    let generation = cred.produce();
    let epoch = generation.epoch().clone();
    // Iroh spells the absolute path (relay-room-auth spec); WebTransport is rooted at the token root.
    let iroh_path = format!("t/{}/r1/alice/{opaque}", owner());
    let path = format!("alice/{opaque}");
    let (publication, (cat_out, vid_out)) = node
        .publish_with(iroh_path.as_str(), iroh_live::Audience::Granted, |b| {
            let protected = moq_e2ee::broadcast::Producer::new(b.clone(), generation.clone());
            let c = protected.create_track("catalog.json", timed())?;
            let v = protected.create_track("video", timed())?;
            Ok::<_, moq_e2ee::Error>((c, v))
        })
        .expect("iroh-live publish_with");
    println!("spike e2ee-iroh-live: iroh-live published {iroh_path} (absolute; WebTransport reads {path})");
    tokio::spawn(bridge(local.clone(), "catalog.json", cat_out));
    tokio::spawn(bridge(local.clone(), "video", vid_out));

    // A WebTransport subscriber holding the credential.
    let b_origin = moq_tokio::origin::spawn();
    let b_table = b_origin.consume();
    let b_session = client()
        .with_subscriber(b_origin)
        .connect(url(&running, &room_token(&running.key, "r1", "bob", 60)))
        .established()
        .await
        .expect("bob admitted");
    let remote = tokio::time::timeout(
        Duration::from_secs(10),
        b_table.follow(path.as_str(), None).unwrap().available(),
    )
    .await
    .expect("iroh publication reached the WebTransport side")
    .unwrap()
    .unwrap();
    let announced = moq_e2ee::Epoch::of(&remote);
    println!("spike e2ee-iroh-live: route instance as an epoch = {announced:?} (iroh-live routes with a minted instance)");
    let epoch_used = announced.unwrap_or_else(|| epoch.clone());
    let bob = moq_e2ee::broadcast::Consumer::new(remote, cred.consume(epoch_used));
    let mut track = bob.subscribe("video", None).unwrap().await.unwrap();
    let mut got = 0;
    for _ in 0..3 {
        let mut group = tokio::time::timeout(Duration::from_secs(5), track.recv_group())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let frame = group.read_frame().await.unwrap().unwrap();
        println!(
            "spike e2ee-iroh-live: bob (WebTransport) decrypted {:?}",
            String::from_utf8_lossy(&frame.plaintext)
        );
        assert!(frame.plaintext.starts_with(MARKER));
        got += 1;
    }
    assert_eq!(got, 3);

    encoder.abort();
    drop((publication, b_session));
    link.detach().await;
    node.shutdown().await;
    let _ = router.shutdown().await;
    running.trigger.start();
    let _ = tokio::time::timeout(Duration::from_secs(8), running.join).await;
    println!("spike e2ee-iroh-live: PROVEN (node layer + in-process bridge, no fork)");
}

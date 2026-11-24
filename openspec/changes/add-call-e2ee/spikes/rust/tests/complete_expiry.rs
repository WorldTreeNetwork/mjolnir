//! Room-token expiry mid-call, label layout. What happens at `exp`, and what a client must do.
//!  - `subscriber_expires_mid_call`: bob's token ends during an encrypted call. His session closes; a new
//!    session with a fresh token and the SAME content credential reads the same publisher epoch again.
//!  - `publisher_expires_mid_call`: alice's token ends. Readers see her broadcast go away; she reconnects
//!    the same local origin (same generation, so no nonce is reused) on a fresh token, and readers resume.
//!  - `room_expiry_both_transports`: bare close timing on WebTransport and Iroh.
#[path = "../../complete/common.rs"]
mod common;
use common::*;
use iroh::Watcher;
use std::time::{Duration, Instant};

struct Pub {
    path: String,
    origin: moq_net::origin::Producer,
    _keep: Vec<Box<dyn std::any::Any + Send>>,
}

/// Label-layout publisher writing a numbered marker frame every 40 ms. The session is separate.
fn publisher(cred: &moq_e2ee::Credential, label: &str) -> Pub {
    let generation = cred.produce();
    let path = format!("{label}/{}/{}", cred.path("call").unwrap(), generation.epoch());
    let origin = moq_tokio::origin::spawn();
    let route = origin.route(path.as_str(), moq_net::origin::RouteOptions::hidden()).unwrap();
    let protected = moq_e2ee::broadcast::Producer::new(route.broadcast().clone(), generation);
    let mut video = protected.create_track("video", timed()).unwrap();
    route.announce().unwrap();
    let writer = tokio::spawn(async move {
        for n in 0..2000u32 {
            let mut g = video.append_group(now()).unwrap();
            g.write_frame(now(), format!("FRAME-{n}").as_bytes()).unwrap();
            g.finish().unwrap();
            tokio::time::sleep(Duration::from_millis(40)).await;
        }
    });
    Pub { path, origin, _keep: vec![Box::new(route), Box::new(protected), Box::new(writer)] }
}

/// Subscribe as `who` with a token of `ttl` seconds; count decrypted frames until the session or track ends.
async fn read_until_end(
    r: &Running,
    who: &str,
    ttl: u64,
    path: &str,
    cred: &moq_e2ee::Credential,
    limit: Duration,
) -> (usize, Option<String>, u128, String) {
    let origin = moq_tokio::origin::spawn();
    let table = origin.consume();
    let started = Instant::now();
    let session = client()
        .with_subscriber(origin)
        .connect(url(r, &room_token(&r.key, "r1", who, ttl)))
        .established()
        .await
        .unwrap();
    let epoch: moq_e2ee::Epoch = path.rsplit('/').next().unwrap().parse().unwrap();
    let remote = tokio::time::timeout(Duration::from_secs(5), table.follow(path, None).unwrap().available())
        .await
        .expect("broadcast available")
        .unwrap()
        .unwrap();
    let sealed = moq_e2ee::broadcast::Consumer::new(remote, cred.consume(epoch));
    let mut track = sealed.subscribe("video", None).unwrap().await.unwrap();
    let (mut frames, mut last) = (0usize, None);
    let end = loop {
        match tokio::time::timeout(limit.saturating_sub(started.elapsed()), track.recv_group()).await {
            Err(_) => break "still reading at limit".to_string(),
            Ok(Ok(None)) => break "track ended (None)".to_string(),
            Ok(Err(e)) => break format!("track error {e:?}"),
            Ok(Ok(Some(mut g))) => {
                if let Ok(Some(f)) = g.read_frame().await {
                    frames += 1;
                    last = Some(String::from_utf8_lossy(&f.plaintext).to_string());
                }
            }
        }
    };
    let closed = tokio::time::timeout(Duration::from_millis(500), session.closed()).await;
    (frames, last, started.elapsed().as_millis(), format!("{end}; session {:?}", closed.map(|r| format!("{r:?}"))))
}

#[tokio::test(flavor = "multi_thread")]
async fn subscriber_expires_mid_call() {
    let r = start().await;
    let cred = label_credential([17; 32], 1, "alice");
    let p = publisher(&cred, "alice");
    let _alice = client()
        .with_publisher(p.origin.consume())
        .connect(url(&r, &room_token(&r.key, "r1", "alice", 60)))
        .established()
        .await
        .unwrap();
    let (frames, last, ms, end) = read_until_end(&r, "bob", 3, &p.path, &cred, Duration::from_secs(8)).await;
    println!("expiry/subscriber: token ttl=3s -> {frames} frames decrypted, last {last:?}, ended at {ms} ms: {end}");
    assert!(frames > 20 && ms < 6000, "subscriber should be cut near exp");
    // What the client must do: get a fresh token and reconnect. The content credential and the
    // publisher's epoch are unchanged, so no rekey and no new invite secret is needed.
    let (again, last2, _, end2) = read_until_end(&r, "bob", 60, &p.path, &cred, Duration::from_secs(2)).await;
    println!("expiry/subscriber: fresh token, same credential -> {again} more frames, last {last2:?} ({end2})");
    assert!(again > 10);
    r.trigger.start();
}

#[tokio::test(flavor = "multi_thread")]
async fn publisher_expires_mid_call() {
    let r = start().await;
    let cred = label_credential([17; 32], 1, "alice");
    let p = publisher(&cred, "alice");
    let t0 = Instant::now();
    let alice = client()
        .with_publisher(p.origin.consume())
        .connect(url(&r, &room_token(&r.key, "r1", "alice", 3)))
        .established()
        .await
        .unwrap();
    let path = p.path.clone();
    let c2 = cred.clone();
    let (frames, last, ms, end) = read_until_end(&r, "bob", 60, &path, &c2, Duration::from_secs(8)).await;
    let closed = tokio::time::timeout(Duration::from_millis(500), alice.closed()).await;
    println!(
        "expiry/publisher: alice ttl=3s -> reader got {frames} frames, last {last:?}, reader ended at {ms} ms ({end}); alice session after {} ms: {:?}",
        t0.elapsed().as_millis(),
        closed.map(|r| format!("{r:?}"))
    );
    assert!(frames > 20 && ms < 6500, "reader should see the publisher go at its exp");
    // Publisher reconnects the SAME local origin (same generation; its nonce counters continue) on a fresh token.
    let _alice2 = client()
        .with_publisher(p.origin.consume())
        .connect(url(&r, &room_token(&r.key, "r1", "alice", 60)))
        .established()
        .await
        .unwrap();
    let (again, last2, _, end2) = read_until_end(&r, "bob", 60, &p.path, &cred, Duration::from_secs(2)).await;
    println!("expiry/publisher: alice reconnected (fresh token, same generation and path) -> reader {again} frames, last {last2:?} ({end2})");
    assert!(again > 10);
    r.trigger.start();
}

#[tokio::test(flavor = "multi_thread")]
async fn room_expiry_both_transports() {
    let r = start().await;
    let start = Instant::now();
    let token = room_token(&r.key, "r1", "bob", 5);
    let session = client().connect(url(&r, &token)).established().await.unwrap();
    let closed = tokio::time::timeout(Duration::from_secs(8), session.closed()).await.expect("WebTransport expiry deadline");
    println!("expiry/bare: WebTransport token ttl=5s close_ms={} result={closed:?}", start.elapsed().as_millis());
    let (router, id) = iroh_relay(&r).await;
    let start = Instant::now();
    let (node, link) = iroh_node(id, &room_token(&r.key, "r1", "alice", 10)).await;
    let mut status = link.status();
    tokio::time::timeout(Duration::from_secs(13), async {
        while status.get() == iroh_live::RelayStatus::Connected {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("Iroh expiry deadline");
    println!("expiry/bare: Iroh token ttl=10s close_ms={} status={:?}", start.elapsed().as_millis(), status.get());
    link.detach().await;
    node.shutdown().await;
    router.shutdown().await.unwrap();
    r.trigger.start();
}

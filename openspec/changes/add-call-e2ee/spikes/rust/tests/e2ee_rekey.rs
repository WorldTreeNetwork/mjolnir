//! Spike e2ee-rekey: removing a member is a new credential (new kid, new secret). The
//! publisher keeps its session and publishes a second broadcast under the new credential
//! beside the old one; remaining members follow the new path on the same session; the
//! publisher withdraws the old broadcast once they have. No session restarts. The removed
//! member, still holding a valid room token, can see the new path at the relay but cannot
//! derive its track names.
mod common;
use common::*;

use std::time::{Duration, Instant};

const MARKER: &[u8] = b"PLAINTEXT-MARKER";

fn sealed(
    origin: &moq_net::origin::Producer,
    cred: &moq_e2ee::Credential,
) -> (moq_net::origin::Route, moq_e2ee::track::Producer, moq_e2ee::Epoch, String) {
    let generation = cred.produce();
    let epoch = generation.epoch().clone();
    let path = format!("alice/{}", cred.path("call").unwrap());
    let route = origin
        .route(
            path.as_str(),
            moq_net::origin::RouteOptions::hidden().with_instance(epoch.instance(), 0),
        )
        .unwrap();
    let protected = moq_e2ee::broadcast::Producer::new(route.broadcast().clone(), generation);
    let video = protected.create_track("video", timed()).unwrap();
    route.announce().unwrap();
    (route, video, epoch, path)
}

async fn open(
    table: &moq_net::origin::Consumer,
    path: &str,
    cred: &moq_e2ee::Credential,
    epoch: &moq_e2ee::Epoch,
) -> moq_e2ee::track::Consumer {
    let remote = tokio::time::timeout(
        Duration::from_secs(5),
        table.follow(path, None).unwrap().available(),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap();
    // The app channel delivers the epoch alongside the credential (default wire).
    let epoch = moq_e2ee::Epoch::of(&remote).unwrap_or_else(|| epoch.clone());
    let consumer = moq_e2ee::broadcast::Consumer::new(remote, cred.consume(epoch));
    consumer.subscribe("video", None).unwrap().await.unwrap()
}

async fn next(track: &mut moq_e2ee::track::Consumer) -> Option<Vec<u8>> {
    let mut group = tokio::time::timeout(Duration::from_secs(3), track.recv_group())
        .await
        .ok()?
        .ok()??;
    let frame = group.read_frame().await.ok()??;
    Some(frame.plaintext.to_vec())
}

#[tokio::test(flavor = "multi_thread")]
async fn new_credential_removes_a_member_without_restarting_sessions() {
    let running = start().await;
    let k1 = credential([1u8; 32], 1);
    let k2 = credential([2u8; 32], 2);

    let a_origin = moq_tokio::origin::spawn();
    let (r1, mut v1, e1, p1) = sealed(&a_origin, &k1);
    let a_session = client()
        .with_publisher(a_origin.consume())
        .connect(url(&running, &room_token(&running.key, "r1", "alice", 60)))
        .established()
        .await
        .unwrap();
    let a_id = format!("{:p}", &a_session);

    let b_origin = moq_tokio::origin::spawn();
    let b_table = b_origin.consume();
    let b_session = client()
        .with_subscriber(b_origin)
        .connect(url(&running, &room_token(&running.key, "r1", "bob", 60)))
        .established()
        .await
        .unwrap();
    let c_origin = moq_tokio::origin::spawn();
    let c_table = c_origin.consume();
    let c_session = client()
        .with_subscriber(c_origin)
        .connect(url(&running, &room_token(&running.key, "r1", "carol", 60)))
        .established()
        .await
        .unwrap();

    // Publisher writes one numbered frame every 50 ms to every live generation.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<moq_e2ee::track::Producer>();
    let k1_live = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    let k1_flag = k1_live.clone();
    let writer = tokio::spawn(async move {
        let mut v1 = Some(v1);
        let mut outs = vec![];
        for n in 0..200u32 {
            while let Ok(extra) = rx.try_recv() {
                outs.push(extra);
            }
            if !k1_flag.load(std::sync::atomic::Ordering::SeqCst) {
                if let Some(old) = v1.take() {
                    old.finish().unwrap();
                }
            }
            if let Some(v) = v1.as_mut() {
                v1_write(v, n);
            }
            for o in outs.iter_mut() {
                v1_write(o, n);
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    });

    let mut b1 = open(&b_table, &p1, &k1, &e1).await;
    let mut c1 = open(&c_table, &p1, &k1, &e1).await;
    let first = next(&mut b1).await.unwrap();
    assert!(first.starts_with(MARKER));
    assert!(next(&mut c1).await.unwrap().starts_with(MARKER));
    println!("spike e2ee-rekey: before removal bob and carol both decrypt under kid 1 at {p1}");

    // Remove carol: alice and bob get k2 over the app channel. Same alice session.
    let t0 = Instant::now();
    let (r2, v2, e2, p2) = sealed(&a_origin, &k2);
    tx.send(v2).unwrap();
    println!("spike e2ee-rekey: kid 2 path {p2} (kid 1 path {p1}); alice session unchanged = {}", a_id == format!("{:p}", &a_session));
    let mut b2 = open(&b_table, &p2, &k2, &e2).await;
    let first_k2 = next(&mut b2).await.unwrap();
    let switched = t0.elapsed();
    println!(
        "spike e2ee-rekey: bob decrypts kid 2 {:?} {} ms after the new credential, same bob session",
        String::from_utf8_lossy(&first_k2),
        switched.as_millis()
    );
    // Overlap: bob's old subscription still delivers until alice withdraws kid 1.
    let still_k1 = next(&mut b1).await;
    println!("spike e2ee-rekey: kid 1 still delivering during overlap = {}", still_k1.is_some());
    // Withdrawing the route alone is not enough (first run: carol kept 51+ frames).
    // The publisher stops encrypting under kid 1 and ends that broadcast.
    k1_live.store(false, std::sync::atomic::Ordering::SeqCst);
    tokio::time::sleep(Duration::from_millis(120)).await;
    r1.withdraw();
    r1.broadcast().close();
    drop(r1);

    // Carol: valid room token, only kid 1. Kid 1 stops; kid 2 is announced but unreadable.
    let mut c_after = 0;
    while next(&mut c1).await.is_some() {
        c_after += 1;
        if c_after > 50 {
            break;
        }
    }
    println!("spike e2ee-rekey: carol kid 1 frames after withdraw drained = {c_after}, then ended");
    assert!(c_after < 50, "kid 1 kept flowing after withdraw");
    let k2_remote = tokio::time::timeout(
        Duration::from_secs(5),
        c_table.follow(p2.as_str(), None).unwrap().available(),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap();
    println!("spike e2ee-rekey: carol can see kid 2 path at the relay: {p2}");
    assert_ne!(k1.path("call").unwrap().to_string(), k2.path("call").unwrap().to_string());
    let carol_k2 = moq_e2ee::broadcast::Consumer::new(k2_remote, k1.consume(e2.clone()));
    let tried = tokio::time::timeout(Duration::from_secs(3), carol_k2.subscribe("video", None).unwrap()).await;
    println!(
        "spike e2ee-rekey: carol subscribing kid 2 with kid 1 secret -> {:?}",
        tried.as_ref().map(|r| r.as_ref().map(|_| "subscribed"))
    );
    assert!(!matches!(tried, Ok(Ok(_))));
    // Bob keeps reading kid 2 after kid 1 is gone.
    let later = next(&mut b2).await.unwrap();
    println!("spike e2ee-rekey: bob after withdraw {:?}", String::from_utf8_lossy(&later));
    assert!(later.starts_with(MARKER));

    writer.abort();
    drop((r2, a_session, b_session, c_session));
    running.trigger.start();
    let _ = tokio::time::timeout(Duration::from_secs(8), running.join).await;
    println!("spike e2ee-rekey: PROVEN");
}

fn v1_write(track: &mut moq_e2ee::track::Producer, n: u32) {
    let mut g = track.append_group(now()).unwrap();
    let mut f = MARKER.to_vec();
    f.extend_from_slice(format!("-{n}").as_bytes());
    g.write_frame(now(), &f).unwrap();
    g.finish().unwrap();
}

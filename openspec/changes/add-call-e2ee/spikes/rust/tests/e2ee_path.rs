//! Spike e2ee-path: a credential-derived broadcast path sits under the participant
//! label, inside an unchanged room token, through a real moq-relay with the Mjolnir
//! decider. A holder of the credential decrypts; a holder of only the room token gets
//! ciphertext and cannot even name the semantic track.
mod common;
use common::*;

use std::time::Duration;

const MARKER: &[u8] = b"PLAINTEXT-MARKER";

#[tokio::test(flavor = "multi_thread")]
async fn credential_path_under_participant_label_is_admitted_and_opaque() {
    let running = start().await;
    let secret = [7u8; 32];
    let cred = credential(secret, 1);
    let opaque = cred.path("call").unwrap();
    // The credential path is one segment; the room token only lets alice publish `alice/**`.
    let path = format!("alice/{opaque}");
    println!("spike e2ee-path: opaque segment = {opaque} (len {})", opaque.as_str().len());
    println!("spike e2ee-path: publish path (token-relative) = {path}");
    println!(
        "spike e2ee-path: absolute path at relay = t/{}/r1/{path}",
        owner()
    );

    // --- alice publishes a protected broadcast with a catalog and a video track.
    let generation = cred.produce();
    let epoch = generation.epoch().clone();
    let physical_video = generation.name("video").unwrap();
    let physical_catalog = generation.name("catalog.json").unwrap();
    println!("spike e2ee-path: epoch (route instance) = {epoch}");
    println!("spike e2ee-path: physical name of \"video\" = {}", physical_video.as_str());
    println!("spike e2ee-path: physical name of \"catalog.json\" = {}", physical_catalog.as_str());

    let a_origin = moq_tokio::origin::spawn();
    let options = moq_net::origin::RouteOptions::hidden().with_instance(epoch.instance(), 0);
    let route = a_origin.route(path.as_str(), options).expect("route");
    let protected = moq_e2ee::broadcast::Producer::new(route.broadcast().clone(), generation.clone());
    let mut video = protected.create_track("video", timed()).unwrap();
    let mut catalog = protected.create_track("catalog.json", timed()).unwrap();
    route.announce().unwrap();
    let a_session = client()
        .with_publisher(a_origin.consume())
        .connect(url(&running, &room_token(&running.key, "r1", "alice", 60)))
        .established()
        .await
        .expect("alice admitted");

    let writer = tokio::spawn(async move {
        for n in 0..60u32 {
            let mut g = catalog.append_group(now()).unwrap();
            g.write_frame(now(), br#"{"display":"Alice","video":{"track":"video"}}"#).unwrap();
            g.finish().unwrap();
            let mut g = video.append_group(now()).unwrap();
            let mut frame = MARKER.to_vec();
            frame.extend_from_slice(format!("-video-{n}").as_bytes());
            g.write_frame(now(), &frame).unwrap();
            g.finish().unwrap();
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    });

    // --- bob: room token + credential.
    let b_origin = moq_tokio::origin::spawn();
    let b_table = b_origin.consume();
    let mut b_routes = b_table.routes();
    let b_session = client()
        .with_subscriber(b_origin)
        .connect(url(&running, &room_token(&running.key, "r1", "bob", 60)))
        .established()
        .await
        .expect("bob admitted");
    let announced = tokio::time::timeout(Duration::from_secs(5), b_routes.next())
        .await
        .expect("an announcement")
        .expect("route event");
    println!("spike e2ee-path: bob sees announcement {announced:?}");
    let remote = tokio::time::timeout(
        Duration::from_secs(5),
        b_table.follow(path.as_str(), None).unwrap().available(),
    )
    .await
    .expect("follow in time")
    .unwrap()
    .unwrap();
    let seen_epoch = moq_e2ee::Epoch::of(&remote);
    println!("spike e2ee-path: bob read epoch from route instance = {seen_epoch:?}");
    let seen_epoch = if lite07() {
        seen_epoch.expect("lite-07 carries the epoch as the route instance")
    } else {
        assert!(seen_epoch.is_none(), "default wire: relay-minted instance, no epoch");
        println!("spike e2ee-path: default wire carries no epoch; taking it from the app channel");
        epoch.clone()
    };
    assert_eq!(seen_epoch, epoch);
    let bob = moq_e2ee::broadcast::Consumer::new(remote.clone(), cred.consume(seen_epoch));
    let mut track = bob.subscribe("video", None).unwrap().await.unwrap();
    let mut group = tokio::time::timeout(Duration::from_secs(5), track.recv_group())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let frame = group.read_frame().await.unwrap().unwrap();
    println!(
        "spike e2ee-path: bob decrypted video frame = {:?}",
        String::from_utf8_lossy(&frame.plaintext)
    );
    assert!(frame.plaintext.starts_with(MARKER));
    let mut cat = bob.subscribe("catalog.json", None).unwrap().await.unwrap();
    let mut cg = tokio::time::timeout(Duration::from_secs(5), cat.recv_group())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let cf = cg.read_frame().await.unwrap().unwrap();
    println!(
        "spike e2ee-path: bob decrypted catalog = {}",
        String::from_utf8_lossy(&cf.plaintext)
    );

    // --- carol: room token, no credential.
    let c_origin = moq_tokio::origin::spawn();
    let c_table = c_origin.consume();
    let c_session = client()
        .with_subscriber(c_origin)
        .connect(url(&running, &room_token(&running.key, "r1", "carol", 60)))
        .established()
        .await
        .expect("carol admitted");
    let c_remote = tokio::time::timeout(
        Duration::from_secs(5),
        c_table.follow(path.as_str(), None).unwrap().available(),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap();
    // (a) The semantic name is not a track at the relay.
    let mut plain = c_remote.track("video").unwrap().subscribe(None);
    let semantic_try = tokio::time::timeout(Duration::from_secs(3), &mut plain).await;
    println!("spike e2ee-path: carol subscribes semantic \"video\" -> {:?}", semantic_try.as_ref().map(|r| r.as_ref().map(|_| "subscribed")));
    assert!(!matches!(semantic_try, Ok(Ok(_))), "semantic name served in clear");
    // (b) A wrong credential derives a name the publisher does not serve.
    let wrong = credential([8u8; 32], 1);
    let wrong_consumer =
        moq_e2ee::broadcast::Consumer::new(c_remote.clone(), wrong.consume(epoch.clone()));
    let wrong_try = tokio::time::timeout(
        Duration::from_secs(3),
        wrong_consumer.subscribe("video", None).unwrap(),
    )
    .await;
    println!("spike e2ee-path: carol with a wrong secret -> {:?}", wrong_try.as_ref().map(|r| r.as_ref().map(|_| "subscribed")));
    assert!(!matches!(wrong_try, Ok(Ok(_))), "wrong credential subscribed");
    // (c) Given the physical name (as the relay sees it), the bytes are ciphertext.
    let mut raw = c_remote
        .track(physical_video.as_str())
        .unwrap()
        .subscribe(None)
        .await
        .expect("raw physical subscribe");
    let mut rg = tokio::time::timeout(Duration::from_secs(5), raw.recv_group())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let rf = rg.read_frame().await.unwrap().unwrap();
    println!(
        "spike e2ee-path: carol raw frame on physical name: {} bytes, marker present = {}",
        rf.payload.len(),
        contains(&rf.payload, MARKER)
    );
    assert!(!contains(&rf.payload, MARKER));
    assert_eq!(rf.payload.len(), frame.plaintext.len() + 16, "ciphertext = plaintext + 16-byte tag");

    // --- alice may not publish the same opaque segment under bob's label.
    let x_origin = moq_tokio::origin::spawn();
    let x_route = x_origin
        .route(format!("bob/{opaque}").as_str(), Default::default())
        .unwrap();
    let _x = x_route.broadcast().create_track("x", timed()).unwrap();
    let x_session = client()
        .with_publisher(x_origin.consume())
        .connect(url(&running, &room_token(&running.key, "r1", "alice", 60)))
        .established()
        .await
        .expect("session admitted");
    let leaked = tokio::time::timeout(
        Duration::from_secs(2),
        c_table.follow(format!("bob/{opaque}").as_str(), None).unwrap().available(),
    )
    .await;
    println!("spike e2ee-path: alice publishing bob/<opaque> visible to carol? {}", matches!(leaked, Ok(Ok(Some(_)))));
    assert!(!matches!(leaked, Ok(Ok(Some(_)))));

    writer.abort();
    drop((a_session, b_session, c_session, x_session));
    running.trigger.start();
    let _ = tokio::time::timeout(Duration::from_secs(8), running.join).await;
    println!("spike e2ee-path: PROVEN");
}

/// Option B for the default wire: the epoch is the last path segment. A subscriber learns it
/// from the announcement under `<label>/<opaque>/`, with no app channel and no lite-07.
#[tokio::test(flavor = "multi_thread")]
async fn epoch_as_last_path_segment_on_the_default_wire() {
    let running = start().await;
    let cred = credential([7u8; 32], 1);
    let opaque = cred.path("call").unwrap();
    let generation = cred.produce();
    let path = format!("alice/{opaque}/{}", generation.epoch());
    let a_origin = moq_tokio::origin::spawn();
    let route = a_origin
        .route(path.as_str(), moq_net::origin::RouteOptions::hidden())
        .unwrap();
    let protected = moq_e2ee::broadcast::Producer::new(route.broadcast().clone(), generation);
    let mut video = protected.create_track("video", timed()).unwrap();
    route.announce().unwrap();
    let _a = client()
        .with_publisher(a_origin.consume())
        .connect(url(&running, &room_token(&running.key, "r1", "alice", 60)))
        .established()
        .await
        .unwrap();
    let writer = tokio::spawn(async move {
        for n in 0..40u32 {
            let mut g = video.append_group(now()).unwrap();
            g.write_frame(now(), format!("PLAINTEXT-MARKER-{n}").as_bytes()).unwrap();
            g.finish().unwrap();
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    });

    let b_origin = moq_tokio::origin::spawn();
    let b_table = b_origin.consume();
    let mut routes = b_table.routes();
    let _b = client()
        .with_subscriber(b_origin)
        .connect(url(&running, &room_token(&running.key, "r1", "bob", 60)))
        .established()
        .await
        .unwrap();
    // Bob knows only the credential: derive the opaque segment, find `<label>/<opaque>/<epoch>`.
    let want = cred.path("call").unwrap().to_string();
    let found = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let event = routes.next().await.expect("route event");
            let text = format!("{event:?}");
            if let Some(at) = text.find(&format!("/{want}/")) {
                let rest = &text[at + want.len() + 2..];
                let epoch_text: String = rest.chars().take(36).collect();
                let label_start = text[..at].rfind('"').unwrap() + 1;
                return (text[label_start..at].to_string(), epoch_text);
            }
        }
    })
    .await
    .expect("announcement under the opaque segment");
    println!("spike e2ee-path/epoch-in-path: announced label={} epoch={}", found.0, found.1);
    let epoch: moq_e2ee::Epoch = found.1.parse().expect("canonical UUIDv7 from the path");
    let full = format!("{}/{want}/{epoch}", found.0);
    let remote = b_table.follow(full.as_str(), None).unwrap().available().await.unwrap().unwrap();
    println!(
        "spike e2ee-path/epoch-in-path: route instance on the default wire = {:?}",
        moq_e2ee::Epoch::of(&remote)
    );
    let bob = moq_e2ee::broadcast::Consumer::new(remote, cred.consume(epoch));
    let mut track = bob.subscribe("video", None).unwrap().await.unwrap();
    let mut group = tokio::time::timeout(Duration::from_secs(5), track.recv_group())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let frame = group.read_frame().await.unwrap().unwrap();
    println!(
        "spike e2ee-path/epoch-in-path: bob decrypted {:?}",
        String::from_utf8_lossy(&frame.plaintext)
    );
    assert!(frame.plaintext.starts_with(b"PLAINTEXT-MARKER"));
    writer.abort();
    running.trigger.start();
    let _ = tokio::time::timeout(Duration::from_secs(8), running.join).await;
    println!("spike e2ee-path/epoch-in-path: PROVEN");
}

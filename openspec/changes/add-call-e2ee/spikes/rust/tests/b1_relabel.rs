// REGRESSION for review finding B1 (add-call-e2ee advise 2026-11-23). Copied verbatim from
// reviews/2026-11-23-relabel-probe.rs (the original stays under reviews/, unedited).
//
// `relay_relabel_passes_d2_checks` is an EXPECTED-VULNERABLE test: it PASSES when the attack
// SUCCEEDS, i.e. while the contract's current D2 layout (room-wide context, opaque = path(<label>))
// lets a relay re-serve alice's ciphertext as bob's. If it ever fails, the layout changed; re-read B1.
// `label_in_context_refuses_the_relabel` is the fix: context mjolnir-call/v1/<owner>/<room>/<label>,
// opaque = path("call"). It PASSES when the transplant is refused with Authentication.
//
// Run from spikes/rust:
//   CARGO_TARGET_DIR=../../../../../native/mjolnir_relay/target cargo test --offline --test b1_relabel -- --nocapture --test-threads=1
//
//! Reader probe for add-call-e2ee D2 (advise 2026-11-23). Not product code.
//!
//! Claim under test (design.md D2): binding `<opaque>` to the label means "a relay that
//! re-mounts alice's broadcast under `bob/` is caught".
//!
//! `relay_relabel_passes_d2_checks`: a session that holds NO content credential re-serves
//! alice's ciphertext, byte for byte, at `bob/<path(bob)>/<alice's epoch>`. `path(bob)` is
//! public at the relay as soon as bob publishes. A credential holder applying exactly D2's
//! subscriber rules (opaque == path(announced label), canonical epoch, greatest epoch)
//! accepts it and decrypts alice's frames as bob's.
//!
//! `label_in_context_refuses_the_relabel`: the same attack when each publisher's credential
//! context ends in its label. No new cryptography: `context` is the draft's own field.
mod common;
use common::*;

use std::time::{Duration, Instant};

const ALICE: &[u8] = b"ALICE-FRAME";
const BOB: &[u8] = b"BOB-FRAME";

struct Published {
    epoch: moq_e2ee::Epoch,
    opaque: String,
    video: String,
    _keep: Vec<Box<dyn std::any::Any>>,
}

/// One participant publishing the D2 layout `<label>/<opaque>/<epoch>` with a marked video track.
async fn publish(
    running: &Running,
    cred: &moq_e2ee::Credential,
    label: &str,
    semantic: &str,
    marker: &'static [u8],
) -> Published {
    let opaque = cred.path(semantic).unwrap().to_string();
    let generation = cred.produce();
    let epoch = generation.epoch().clone();
    let video_name = generation.name("video").unwrap().as_str().to_string();
    let path = format!("{label}/{opaque}/{epoch}");
    let origin = moq_tokio::origin::spawn();
    let route = origin
        .route(path.as_str(), moq_net::origin::RouteOptions::hidden())
        .unwrap();
    let protected = moq_e2ee::broadcast::Producer::new(route.broadcast().clone(), generation);
    let mut video = protected.create_track("video", timed()).unwrap();
    route.announce().unwrap();
    let session = client()
        .with_publisher(origin.consume())
        .connect(url(running, &room_token(&running.key, "r1", label, 60)))
        .established()
        .await
        .expect("publisher admitted");
    let writer = tokio::spawn(async move {
        for n in 0..600u32 {
            let mut g = video.append_group(now()).unwrap();
            let mut f = marker.to_vec();
            f.extend_from_slice(format!("-{n}").as_bytes());
            g.write_frame(now(), &f).unwrap();
            g.finish().unwrap();
            tokio::time::sleep(Duration::from_millis(40)).await;
        }
    });
    Published {
        epoch,
        opaque,
        video: video_name,
        _keep: vec![
            Box::new(origin),
            Box::new(route),
            Box::new(protected),
            Box::new(session),
            Box::new(writer),
        ],
    }
}

/// The relay's power, stood in for by a credential-less session: read alice's physical video
/// track and re-serve the same ciphertext, same group starts, same frame order, at `swapped`.
/// `names` are the physical names to serve it under (the relay sees every requested name).
async fn remount(
    running: &Running,
    alice_path: &str,
    alice_video: &str,
    swapped: &str,
    names: Vec<String>,
) -> impl Sized {
    let sub_origin = moq_tokio::origin::spawn();
    let table = sub_origin.consume();
    let sub_session = client()
        .with_subscriber(sub_origin)
        .connect(url(running, &room_token(&running.key, "r1", "mallory", 60)))
        .established()
        .await
        .expect("tap admitted");
    let remote = tokio::time::timeout(
        Duration::from_secs(5),
        table.follow(alice_path, None).unwrap().available(),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap();
    let mut raw = remote
        .track(alice_video)
        .unwrap()
        .subscribe(None)
        .await
        .expect("raw physical subscribe");

    let pub_origin = moq_tokio::origin::spawn();
    let route = pub_origin
        .route(swapped, moq_net::origin::RouteOptions::hidden())
        .unwrap();
    let outs: Vec<moq_net::track::Producer> = names
        .iter()
        .map(|name| route.broadcast().create_track(name.as_str(), timed()).unwrap())
        .collect();
    route.announce().unwrap();
    // A second token for label `bob`. The relay needs none: it owns the namespace.
    let pub_session = client()
        .with_publisher(pub_origin.consume())
        .connect(url(running, &room_token(&running.key, "r1", "bob", 60)))
        .established()
        .await
        .expect("re-mount admitted");
    let pump = tokio::spawn(async move {
        while let Ok(Some(mut group)) = raw.recv_group().await {
            let start = group.start;
            let mut sealed: Vec<_> = outs
                .iter()
                .filter_map(|out| out.create_group(moq_net::group::Info { start }).ok())
                .collect();
            while let Ok(Some(frame)) = group.read_frame().await {
                for g in sealed.iter_mut() {
                    let _ = g.write_frame(frame.timestamp, frame.payload.clone());
                }
            }
            for g in sealed {
                let _ = g.finish();
            }
        }
    });
    (sub_session, table, remote, pub_origin, route, pub_session, pump)
}

/// D2's subscriber rule, verbatim: under label `label`, accept only announcements whose opaque
/// equals `want`, parse the epoch from the last segment, and read the greatest.
async fn greatest_epoch(
    routes: &mut moq_net::origin::Routes,
    label: &str,
    want: &str,
    window: Duration,
) -> Vec<moq_e2ee::Epoch> {
    let needle = format!("\"{label}/{want}/");
    let mut found: Vec<moq_e2ee::Epoch> = vec![];
    let deadline = Instant::now() + window;
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        let Ok(Some(event)) = tokio::time::timeout(left, routes.next()).await else {
            break;
        };
        let text = format!("{event:?}");
        if let Some(at) = text.find(&needle) {
            let rest: String = text[at + needle.len()..].chars().take(36).collect();
            if let Ok(epoch) = rest.parse::<moq_e2ee::Epoch>() {
                if !found.contains(&epoch) {
                    found.push(epoch);
                }
            }
        }
    }
    found.sort();
    found
}

#[tokio::test(flavor = "multi_thread")]
async fn relay_relabel_passes_d2_checks() {
    let running = start().await;
    // The contract's credential: one context for the room (common::credential).
    let cred = credential([7u8; 32], 1);
    let bob = publish(&running, &cred, "bob", "bob", BOB).await;
    tokio::time::sleep(Duration::from_millis(20)).await;
    let alice = publish(&running, &cred, "alice", "alice", ALICE).await;
    assert!(alice.epoch > bob.epoch, "alice started later, so her epoch is the greater");
    assert_ne!(alice.opaque, bob.opaque, "label-bound opaque differs per label");
    println!("probe relabel: alice at alice/{}/{}", alice.opaque, alice.epoch);
    println!("probe relabel: bob   at bob/{}/{}", bob.opaque, bob.epoch);

    let alice_path = format!("alice/{}/{}", alice.opaque, alice.epoch);
    let swapped = format!("bob/{}/{}", bob.opaque, alice.epoch);
    let _relay = remount(&running, &alice_path, &alice.video, &swapped, vec![alice.video.clone()]).await;
    println!("probe relabel: a session with no content credential re-serves alice's ciphertext at {swapped}");

    // dave: room token + credential, applying D2's rules to label `bob`.
    let d_origin = moq_tokio::origin::spawn();
    let d_table = d_origin.consume();
    let mut d_routes = d_table.routes();
    let _d = client()
        .with_subscriber(d_origin)
        .connect(url(&running, &room_token(&running.key, "r1", "dave", 60)))
        .established()
        .await
        .expect("dave admitted");
    let want = cred.path("bob").unwrap().to_string();
    assert_eq!(want, bob.opaque, "D2 check: announced opaque == credential.path(\"bob\")");
    let epochs = greatest_epoch(&mut d_routes, "bob", &want, Duration::from_millis(1500)).await;
    println!("probe relabel: dave sees {} canonical epoch(s) under bob/{want}/: {epochs:?}", epochs.len());
    let chosen = epochs.last().expect("an epoch under bob's opaque").clone();
    assert_eq!(chosen, alice.epoch, "D2 'read the greatest' selects the re-mounted one");
    let full = format!("bob/{want}/{chosen}");
    let remote = tokio::time::timeout(
        Duration::from_secs(5),
        d_table.follow(full.as_str(), None).unwrap().available(),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap();
    let dave = moq_e2ee::broadcast::Consumer::new(remote, cred.consume(chosen));
    let mut track = dave.subscribe("video", None).unwrap().await.expect("subscribe under label bob");
    let mut group = tokio::time::timeout(Duration::from_secs(5), track.recv_group())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let frame = group.read_frame().await.unwrap().unwrap();
    println!(
        "probe relabel: dave, reading label `bob` with every D2 check passed, decrypted {:?}",
        String::from_utf8_lossy(&frame.plaintext)
    );
    assert!(frame.plaintext.starts_with(ALICE), "alice's media was accepted as bob's");
    assert!(!frame.plaintext.starts_with(BOB));
    println!("probe relabel: D2 CLAIM REFUTED (label-bound opaque does not bind the keys to the label)");
    running.trigger.start();
    let _ = tokio::time::timeout(Duration::from_secs(8), running.join).await;
}

fn label_credential(label: &str) -> moq_e2ee::Credential {
    moq_e2ee::Credential::new(moq_e2ee::credential::Config {
        context: format!("mjolnir-call/v1/{}/r1/{label}", owner()).into(),
        kid: 1,
        secret: [7u8; 32],
    })
    .unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn label_in_context_refuses_the_relabel() {
    let running = start().await;
    let (cred_a, cred_b) = (label_credential("alice"), label_credential("bob"));
    let bob = publish(&running, &cred_b, "bob", "call", BOB).await;
    tokio::time::sleep(Duration::from_millis(20)).await;
    let alice = publish(&running, &cred_a, "alice", "call", ALICE).await;
    assert_ne!(alice.opaque, bob.opaque, "the context makes the opaque label-bound too");

    // What dave will ask for under label bob and alice's epoch: the relay sees this name in the request.
    let asked = cred_b.consume(alice.epoch.clone()).name("video").unwrap().as_str().to_string();
    assert_ne!(asked, alice.video, "another context derives another physical name");

    let alice_path = format!("alice/{}/{}", alice.opaque, alice.epoch);
    let swapped = format!("bob/{}/{}", bob.opaque, alice.epoch);
    // The relay serves alice's ciphertext under her own physical name AND under the name dave asks for.
    let _relay = remount(
        &running,
        &alice_path,
        &alice.video,
        &swapped,
        vec![alice.video.clone(), asked.clone()],
    )
    .await;

    let d_origin = moq_tokio::origin::spawn();
    let d_table = d_origin.consume();
    let mut d_routes = d_table.routes();
    let _d = client()
        .with_subscriber(d_origin)
        .connect(url(&running, &room_token(&running.key, "r1", "dave", 60)))
        .established()
        .await
        .expect("dave admitted");
    let want = cred_b.path("call").unwrap().to_string();
    let epochs = greatest_epoch(&mut d_routes, "bob", &want, Duration::from_millis(1500)).await;
    let chosen = epochs.last().expect("an epoch under bob's opaque").clone();
    assert_eq!(chosen, alice.epoch, "the re-mount is still announced and still the greatest");
    let full = format!("bob/{want}/{chosen}");
    let remote = tokio::time::timeout(
        Duration::from_secs(5),
        d_table.follow(full.as_str(), None).unwrap().available(),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap();
    let dave = moq_e2ee::broadcast::Consumer::new(remote, cred_b.consume(chosen));
    let mut track = dave.subscribe("video", None).unwrap().await.expect("the aliased name is served");
    let outcome = tokio::time::timeout(Duration::from_secs(5), async {
        let mut group = track.recv_group().await?.ok_or(moq_e2ee::Error::Authentication)?;
        group.read_frame().await
    })
    .await;
    let shown = match &outcome {
        Ok(Ok(Some(frame))) => format!("PLAINTEXT {:?}", String::from_utf8_lossy(&frame.plaintext)),
        Ok(Ok(None)) => "group ended with no frame".to_string(),
        Ok(Err(err)) => format!("refused: {err:?}"),
        Err(_) => "timed out with no frame".to_string(),
    };
    println!("probe relabel/context: dave reading the re-mount under label `bob` -> {shown}");
    assert!(!matches!(outcome, Ok(Ok(Some(_)))), "the re-mount decrypted");
    println!("probe relabel/context: REFUSED (label in the credential context binds every key and name)");
    running.trigger.start();
    let _ = tokio::time::timeout(Duration::from_secs(8), running.join).await;
}

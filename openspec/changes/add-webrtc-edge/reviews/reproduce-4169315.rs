
#[cfg(test)]
mod independent_review {
    use super::*;
    use moq_auth::{Algorithm, Claims, Key};
    use tower::ServiceExt;

    fn fixture() -> (Arc<Edge>, Checked) {
        let key = Key::generate(Algorithm::EdDSA, None).unwrap();
        let root = format!("t/{}/~open/standup", bs58::encode([9u8; 32]).into_string());
        let now = kio::clock::wall();
        let claims = Claims::default().with_root(&root)
            .with_publish(["alice/**".parse().unwrap()]).with_subscribe(["**".parse().unwrap()])
            .with_issued(now).with_expires(now + Duration::from_secs(120));
        let token = key.sign(&claims).unwrap();
        let edge = Edge::new(KeySet { keys: vec![Arc::new(key.public().unwrap())] });
        let checked = edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap();
        (edge, checked)
    }

    async fn request(edge: &Arc<Edge>, c: &Checked, path: &str, body: &str) -> Response {
        let req = axum::http::Request::builder().method("POST").uri(path)
            .header("authorization", format!("Bearer {}", c.token))
            .header("x-mjolnir-root", &c.root).header("content-type", "application/json")
            .header("origin", "https://unlisted.invalid")
            .body(axum::body::Body::from(body.to_owned())).unwrap();
        edge.router().oneshot(req).await.unwrap()
    }

    #[tokio::test]
    async fn http_encoded_slash_reaches_dial_and_double_decode_changes_name() {
        let (edge, c) = fixture();
        let denied = request(&edge, &c, "/admit", r#"{"operation":"publish","broadcast":"alice%2fcam"}"#).await;
        assert_eq!(denied.status(), 400);
        assert_eq!(edge.dials(), 0);
        for path in ["/whip/standup/alice%2fcam", "/whip/standup/%2561lice/cam"] {
            let response = request(&edge, &c, path, "invalid SDP").await;
            assert_eq!(response.status(), 503, "BUG: canonical rejection should be 400 before dial");
        }
        assert_eq!(edge.dials(), 2, "both malformed URL spellings passed admission");
        eprintln!("REPRO encoded slash + double decode: HTTP 503, 2 dials; /admit rejects raw encoded slash");
    }

    #[tokio::test]
    async fn http_cors_cache_and_json_contract() {
        let (edge, c) = fixture();
        let response = request(&edge, &c, "/admit", r#"{"operation":"publish","broadcast":"alice/cam"}"#).await;
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers()["access-control-allow-origin"], "*");
        assert!(response.headers().get("cache-control").is_none());
        let bad = request(&edge, &c, "/admit", "{}").await;
        assert_eq!(bad.status(), 422);
        assert_ne!(bad.headers()["content-type"], "application/json");
        eprintln!("REPRO /admit: unlisted origin '*', no cache-control; missing fields 422 text");
    }

    #[tokio::test]
    async fn failed_leader_discards_successful_waiter_reservation() {
        let (edge, c) = fixture();
        edge.enable_test_dial();
        let (left, right) = tokio::join!(
            edge.attach(&c, "m=video 9 RTP/AVP 96", "m=video 0 RTP/AVP 96", SystemTime::now()),
            edge.attach(&c, "m=audio 9 RTP/AVP 111", "m=audio 9 RTP/AVP 111", SystemTime::now()),
        );
        assert_eq!(left, Err(AdmitError::CodecUnavailable));
        assert_eq!(right, Err(AdmitError::SetupFailed));
        assert_eq!(edge.refs(&c.token), 0);
        eprintln!("REPRO successful shared dial: rejected leader causes otherwise-valid follower setup_failed");
    }

    #[tokio::test]
    async fn first_acquire_expiry_is_setup_failed() {
        let (edge, c) = fixture();
        let error = edge.acquire(&c.token, 1, tokio::time::Instant::now()).await.unwrap_err();
        assert_eq!(error, AdmitError::SetupFailed);
        eprintln!("REPRO acquisition deadline with expired exp and no hold => setup_failed, not bad_token");
    }

    #[tokio::test]
    async fn tombstones_wrong_owner_and_expiry_cleanup() {
        let (edge, c) = fixture();
        edge.enable_test_dial();
        let id = edge.attach(&c, "m=audio 9 RTP/AVP 111", "m=audio 9 RTP/AVP 111", SystemTime::now()).await.unwrap();
        edge.delete(&id, Some(&c.token), SystemTime::now()).unwrap();
        assert_eq!(edge.delete(&id, Some("other"), SystemTime::now()), Err(AdmitError::NotFound));
        edge.sweep(UNIX_EPOCH + Duration::from_secs(c.exp_unix + 31));
        assert_eq!(edge.pool.lock().unwrap().tombstones.len(), 1);
        let id2 = edge.attach(&c, "m=audio 9 RTP/AVP 111", "m=audio 9 RTP/AVP 111", SystemTime::now()).await.unwrap();
        edge.sweep(UNIX_EPOCH + Duration::from_secs(c.exp_unix));
        assert_eq!(edge.delete(&id2, Some(&c.token), UNIX_EPOCH + Duration::from_secs(c.exp_unix + 1)), Err(AdmitError::NotFound));
        eprintln!("REPRO tombstones: foreign bearer 404; sweep retains old tombstone; expired active id owner gets 404");
    }

    fn offer(direction: str0m::media::Direction) -> String {
        let crypto = rind_str0m::default_provider().unwrap();
        let mut rtc = str0m::RtcConfig::new().set_crypto_provider(Arc::new(crypto))
            .set_dtls_version(str0m::config::DtlsVersion::Dtls12).build(std::time::Instant::now());
        let mut api = rtc.sdp_api();
        api.add_media(str0m::media::MediaKind::Audio, direction, None, None, None);
        api.add_media(str0m::media::MediaKind::Video, direction, None, None, None);
        api.apply().unwrap().0.to_sdp_string()
    }

    // Real TLS relay and actual moq_webrtc accept/run, no fake dial in these tests.
    async fn live() -> (Arc<Edge>, Checked, tempfile::TempDir, tokio::task::JoinHandle<anyhow::Result<()>>) {
        let _ = moq_tokio::crypto::install_default();
        let dir = tempfile::tempdir().unwrap();
        let key = rcgen::KeyPair::generate().unwrap();
        let cert = rcgen::CertificateParams::new(vec!["localhost".into()]).unwrap().self_signed(&key).unwrap();
        let cert_path = dir.path().join("cert.pem");
        let key_path = dir.path().join("key.pem");
        std::fs::write(&cert_path, cert.pem()).unwrap();
        std::fs::write(&key_path, key.serialize_pem()).unwrap();
        let mut cfg = moq_relay::Config::default();
        cfg.listen.bind = Some("127.0.0.1:0".parse().unwrap());
        cfg.listen.tls.cert = vec![cert_path.clone()];
        cfg.listen.tls.key = vec![key_path];
        cfg.web.ws = false;
        let mut relay = moq_relay::Relay::load(cfg).await.unwrap().with_signals(false);
        let addr = relay.quic_addr().unwrap();
        let admissions = relay.admissions().unwrap();
        let ready = relay.ready();
        let task = tokio::spawn(async move { relay.run().await.map_err(Into::into) });
        ready.wait().await.unwrap();
        let (edge, c) = fixture();
        crate::spawn_web_decider(admissions, Arc::new(Mutex::new(edge.snap.lock().unwrap().keys.clone())),
            Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(true)), DEFAULT_MAX_TTL);
        edge.set_moq(crate::moq_session::MoqConfig {
            relay: format!("https://localhost:{}", addr.port()).parse().unwrap(), tls_root: Some(cert_path),
            media: moq_webrtc::Server::bind("127.0.0.1:0".parse().unwrap(), Default::default()).await.unwrap(),
        });
        (edge, c, dir, task)
    }

    #[tokio::test]
    async fn real_http_answer_drop_leaves_runner() {
        let (edge, c, _dir, relay) = live().await;
        let response = request(&edge, &c, "/whip/standup/alice/cam", &offer(str0m::media::Direction::SendOnly)).await;
        assert_eq!(response.status(), 201);
        drop(response); // no answer bytes consumed/delivered to a client
        tokio::task::yield_now().await;
        assert_eq!(edge.session_count(), 1);
        assert_eq!(edge.refs(&c.token), 1);
        assert_eq!(edge.runner_count(), 1);
        eprintln!("REPRO discarded actual HTTP 201/body: runners=1 sessions=1 refs=1");
        edge.drop_token(&c.token); relay.abort(); let _ = relay.await;
    }

    #[tokio::test]
    async fn real_whep_cancellation_leaks_hold() {
        let (edge, mut c, _dir, relay) = live().await;
        c.operation = Op::Subscribe;
        let worker_edge = edge.clone(); let worker_c = c.clone();
        let task = tokio::spawn(async move { worker_edge.open_session(&worker_c, &offer(str0m::media::Direction::RecvOnly)).await });
        tokio::time::timeout(Duration::from_secs(4), async {
            while edge.refs(&c.token) == 0 { tokio::time::sleep(Duration::from_millis(1)).await; }
        }).await.unwrap();
        task.abort(); let _ = task.await;
        assert_eq!(edge.refs(&c.token), 1);
        assert_eq!(edge.link_count(), 1);
        assert_eq!(edge.session_count(), 0);
        eprintln!("REPRO cancelled real WHEP: refs=1 links=1 sessions=0");
        edge.drop_token(&c.token); relay.abort(); let _ = relay.await;
    }

    #[tokio::test]
    async fn real_missing_broadcast_is_503() {
        let (edge, mut c, _dir, relay) = live().await;
        c.operation = Op::Subscribe;
        let start = std::time::Instant::now();
        let result = edge.open_session(&c, &offer(str0m::media::Direction::RecvOnly)).await;
        assert_eq!(result, Err(AdmitError::SetupFailed));
        assert_eq!(edge.refs(&c.token), 0);
        eprintln!("REPRO real absent broadcast: setup_failed after {:?}, token still valid", start.elapsed());
        relay.abort(); let _ = relay.await;
    }

    #[tokio::test]
    async fn real_runner_completion_leaves_session_and_link() {
        let (edge, c, _dir, relay) = live().await;
        let (_id, answer) = edge.open_session(&c, &offer(str0m::media::Direction::SendOnly)).await.unwrap();
        assert!(answer_has_usable_video(&answer));
        assert!(!answer.contains("b=TIAS:"), "uncapped actual answer");
        // No ICE peer: the pinned real runner returns IceTimeout after 30 seconds.
        tokio::time::timeout(Duration::from_secs(33), async {
            while edge.runner_count() != 0 { tokio::time::sleep(Duration::from_millis(1)).await; }
        }).await.unwrap();
        assert_eq!(edge.session_count(), 1);
        assert_eq!(edge.refs(&c.token), 1);
        relay.abort(); let _ = relay.await;
        assert_eq!(edge.link_count(), 1);
        eprintln!("REPRO actual Response::run completion: runners=0 sessions=1 refs=1 links=1");
        edge.drop_token(&c.token);
    }
}


#[cfg(test)]
mod independent_review {
    use super::*;
    use moq_auth::{Algorithm, Claims, Key};
    use tower::ServiceExt;

    fn fixture() -> (Arc<Edge>, Checked) {
        static KEY_ID: AtomicU64 = AtomicU64::new(1);
        let kid = moq_auth::KeyId::decode(&format!("{:016x}", KEY_ID.fetch_add(1, Ordering::SeqCst))).unwrap();
        let key = Key::generate(Algorithm::EdDSA, Some(kid)).unwrap();
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
    async fn live_two() -> (Arc<Edge>, Checked, Checked, tempfile::TempDir, tokio::task::JoinHandle<anyhow::Result<()>>) {
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
        let (other_edge, other) = fixture();
        assert_ne!(c.token, other.token);
        edge.snap.lock().unwrap().keys.keys.extend(other_edge.snap.lock().unwrap().keys.keys.clone());
        crate::spawn_web_decider(admissions, Arc::new(Mutex::new(edge.snap.lock().unwrap().keys.clone())),
            Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(true)), DEFAULT_MAX_TTL);
        edge.set_moq(crate::moq_session::MoqConfig {
            relay: format!("https://localhost:{}", addr.port()).parse().unwrap(), tls_root: Some(cert_path),
            media: moq_webrtc::Server::bind("127.0.0.1:0".parse().unwrap(), Default::default()).await.unwrap(),
        });
        (edge, c, other, dir, task)
    }

    async fn live() -> (Arc<Edge>, Checked, tempfile::TempDir, tokio::task::JoinHandle<anyhow::Result<()>>) {
        let (edge, c, _, dir, task) = live_two().await;
        (edge, c, dir, task)
    }

    use http_body_util::BodyExt;

    #[tokio::test]
    async fn prior_http_decode_cors_cache_json_regressions() {
        let (edge, c) = fixture();
        for prefix in ["whip", "whep"] {
            for path in ["alice%2fcam", "%2561lice/cam", "alice%252fcam", "alice%5ccam", "alice/%2e/cam", "alice/%", "alice/%xx"] {
                assert_eq!(request(&edge, &c, &format!("/{prefix}/standup/{path}"), "bad SDP").await.status(), 400, "{path}");
            }
        }
        let response = request(&edge, &c, "/admit", r#"{"operation":"publish","broadcast":"alice/cam"}"#).await;
        assert_eq!(response.status(), 200);
        assert!(response.headers().get("access-control-allow-origin").is_none());
        assert_eq!(response.headers()["cache-control"], "no-store");
        let bad = request(&edge, &c, "/admit", "{}").await;
        assert_eq!(bad.status(), 400);
        assert_eq!(bad.into_body().collect().await.unwrap().to_bytes(), r#"{"error":"bad_request"}"#);
        assert_eq!(edge.dials(), 0);
        edge.enable_test_dial();
        let good = request(&edge, &c, "/whip/standup/alice/cam%2D1", "bad SDP").await;
        assert_eq!(good.status(), 201);
        assert_eq!(edge.moq_paths(), vec!["alice/cam-1"]);
        drop(good);
        assert_eq!(edge.refs(&c.token), 0);
    }

    #[tokio::test]
    async fn prior_rejected_leader_reserves_waiter() {
        let (edge, c) = fixture(); edge.enable_test_dial();
        let (left, right) = tokio::join!(
            edge.attach(&c, "m=video 9 RTP/AVP 96", "m=video 0 RTP/AVP 96", SystemTime::now()),
            edge.attach(&c, "m=audio 9 RTP/AVP 111", "m=audio 9 RTP/AVP 111", SystemTime::now()));
        assert_eq!(left, Err(AdmitError::CodecUnavailable));
        let id = right.unwrap(); assert_eq!(edge.refs(&c.token), 1);
        edge.delete(&id, Some(&c.token), SystemTime::now()).unwrap();
        assert_eq!(edge.link_count(), 0);
    }

    #[tokio::test]
    async fn prior_first_expiry_and_tombstones() {
        let (edge, c) = fixture(); edge.enable_test_dial();
        let deadline = Deadline { at: tokio::time::Instant::now(), exp_bound: true };
        assert!(matches!(edge.acquire(&c.token, UNIX_EPOCH, &deadline).await, Err(AdmitError::BadToken)));
        let id = edge.attach(&c, "", "", SystemTime::now()).await.unwrap();
        edge.delete(&id, Some(&c.token), SystemTime::now()).unwrap();
        let (_, different) = fixture(); assert_ne!(c.token, different.token);
        assert_eq!(edge.delete(&id, Some(&different.token), SystemTime::now()), Err(AdmitError::Forbidden));
        edge.sweep(c.exp + Duration::from_secs(31)); assert_eq!(edge.tombstone_count(), 0);
        let id = edge.attach(&c, "", "", SystemTime::now()).await.unwrap();
        edge.sweep(c.exp + Duration::from_secs(1));
        assert_eq!(edge.delete(&id, Some(&c.token), c.exp + Duration::from_secs(1)), Ok(()));
    }

    #[tokio::test]
    async fn prior_real_answer_drop_and_cancellation() {
        let (edge, c, _dir, relay) = live().await;
        let response = request(&edge, &c, "/whip/standup/alice/cam", &offer(str0m::media::Direction::SendOnly)).await;
        assert_eq!(response.status(), 201); drop(response);
        tokio::task::yield_now().await;
        assert_eq!((edge.session_count(), edge.refs(&c.token), edge.runner_count()), (0,0,0));
        let mut sub = c.clone(); sub.operation = Op::Subscribe; sub.broadcast = "absent/cam".into();
        let e = edge.clone(); let cc = sub.clone();
        let task = tokio::spawn(async move { e.open_session(&cc, &offer(str0m::media::Direction::RecvOnly)).await });
        tokio::time::timeout(Duration::from_secs(4), async { while edge.refs(&c.token) == 0 { tokio::task::yield_now().await; } }).await.unwrap();
        task.abort(); let _ = task.await;
        assert_eq!((edge.refs(&c.token), edge.link_count(), edge.session_count()), (0,0,0));
        relay.abort(); let _ = relay.await;
    }

    #[tokio::test]
    async fn prior_real_absent_source_is_now_409() {
        let (edge, mut c, _dir, relay) = live().await; c.operation = Op::Subscribe;
        let result = edge.open_session(&c, &offer(str0m::media::Direction::RecvOnly)).await;
        assert!(matches!(result, Err(AdmitError::NotStarted)));
        assert_eq!((edge.refs(&c.token), edge.session_count()), (0,0));
        relay.abort(); let _ = relay.await;
    }

    #[tokio::test]
    async fn prior_real_natural_runner_cleanup_and_cap() {
        let (edge, c, _dir, relay) = live().await;
        let response = request(&edge, &c, "/whip/standup/alice/cam", &offer(str0m::media::Direction::SendOnly)).await;
        assert_eq!(response.status(), 201);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let answer = std::str::from_utf8(&body).unwrap();
        assert!(answer_has_usable_video(answer)); assert!(answer.contains("b=TIAS:2250000"), "{answer}");
        assert_eq!(edge.runner_count(), 1);
        tokio::time::timeout(Duration::from_secs(34), async { while edge.session_count() != 0 { tokio::time::sleep(Duration::from_millis(10)).await; } }).await.unwrap();
        assert_eq!((edge.runner_count(), edge.refs(&c.token), edge.link_count()), (0,0,0));
        relay.abort(); let _ = relay.await;
    }

    #[tokio::test]
    async fn cancelled_leader_live_waiter_retries() {
        let (edge, c) = fixture(); edge.enable_test_dial();
        *edge.test_dial_wait.lock().unwrap() = Duration::from_millis(100);
        let e = edge.clone(); let cc = c.clone();
        let leader = tokio::spawn(async move { e.acquire(&cc.token, cc.exp, &setup_deadline(cc.exp).unwrap()).await });
        while edge.dials() == 0 { tokio::task::yield_now().await; }
        let e = edge.clone(); let cc = c.clone();
        let waiter = tokio::spawn(async move { e.acquire(&cc.token, cc.exp, &setup_deadline(cc.exp).unwrap()).await });
        tokio::time::sleep(Duration::from_millis(10)).await;
        leader.abort(); let _ = leader.await;
        let reservation = tokio::time::timeout(Duration::from_secs(1), waiter).await.unwrap().unwrap().ok().unwrap();
        assert_eq!(edge.refs(&c.token), 1); drop(reservation);
        assert_eq!((edge.refs(&c.token), edge.link_count(), edge.flight_count()), (0,0,0));
    }

    #[tokio::test]
    async fn defect_last_release_retains_real_connection_and_redial_overlaps() {
        let (edge, c, _dir, relay) = live().await;
        let r = edge.acquire(&c.token, c.exp, &setup_deadline(c.exp).unwrap()).await.ok().unwrap();
        let weak = Arc::downgrade(edge.pool.lock().unwrap().links[&c.token].shared.as_ref().unwrap());
        drop(r); tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(edge.link_count(), 0);
        assert!(weak.upgrade().is_some_and(|s| !s.dead()), "characterizes retained live link");
        let next = edge.acquire(&c.token, c.exp, &setup_deadline(c.exp).unwrap()).await.ok().unwrap();
        assert_eq!(edge.dials(), 2);
        assert!(weak.upgrade().is_some_and(|s| !s.dead()), "old connection remains live alongside new generation");
        drop(next); edge.drain();
        assert!(weak.upgrade().is_some_and(|s| !s.dead()), "drain cannot reach removed link");
        eprintln!("DEFECT final release reports links=0 but watcher retains live Shared; next acquire dials a second live connection; drain does not close old connection");
        relay.abort(); let _ = relay.await;
    }

    #[tokio::test]
    async fn defect_drain_allows_pending_dial_to_publish() {
        let (edge, c) = fixture(); edge.enable_test_dial();
        *edge.test_dial_wait.lock().unwrap() = Duration::from_millis(100);
        let e = edge.clone(); let cc = c.clone();
        let task = tokio::spawn(async move { e.open_session(&cc, "v=0").await });
        while edge.dials() == 0 { tokio::task::yield_now().await; }
        edge.drain(); assert!(!edge.admissions_open());
        let negotiated = task.await.unwrap().ok().expect("characterizes post-drain success");
        assert_eq!(edge.session_count(), 1); assert_eq!(edge.link_count(), 1);
        eprintln!("DEFECT drain during flight => successful session registered after drain");
        drop(negotiated);
    }

    async fn serve(edge: &Arc<Edge>) -> (std::net::SocketAddr, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap(); let router = edge.router();
        let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap(); });
        (addr, task)
    }

    fn wire(c: &Checked, route: &str, body: &str) -> String {
        format!("POST {route} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {}\r\nX-Mjolnir-Root: {}\r\nContent-Type: application/sdp\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", c.token, c.root, body.len())
    }

    #[tokio::test]
    async fn real_http_delivery_and_request_disconnect() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let (edge, c, _dir, relay) = live().await; let (addr, server) = serve(&edge).await;
        let mut sock = tokio::net::TcpStream::connect(addr).await.unwrap();
        sock.write_all(wire(&c, "/whip/standup/alice/cam", &offer(str0m::media::Direction::SendOnly)).as_bytes()).await.unwrap();
        let mut bytes = Vec::new(); sock.read_to_end(&mut bytes).await.unwrap();
        assert!(String::from_utf8_lossy(&bytes).starts_with("HTTP/1.1 201"));
        assert_eq!(edge.session_count(), 1); assert_eq!(edge.runner_count(), 1);
        let mut sock = tokio::net::TcpStream::connect(addr).await.unwrap();
        sock.write_all(wire(&c, "/whep/standup/absent/cam", &offer(str0m::media::Direction::RecvOnly)).as_bytes()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(2), async { while edge.refs(&c.token) < 2 { tokio::task::yield_now().await; } }).await.unwrap();
        drop(sock);
        tokio::time::sleep(Duration::from_millis(200)).await;
        eprintln!("HTTP disconnect: refs={} sessions={} runners={}", edge.refs(&c.token), edge.session_count(), edge.runner_count());
        assert_eq!(edge.refs(&c.token), 1);
        assert_eq!(edge.session_count(), 1);
        edge.drop_token(&c.token); server.abort(); relay.abort(); let _ = relay.await;
    }
    // Real Hyper HTTP/1 serializer, deterministic peer write failure. The only
    // simulated layer is AsyncWrite; the offer/answer and runner are production.
    struct FailedWire { request: std::io::Cursor<Vec<u8>> }
    impl tokio::io::AsyncRead for FailedWire {
        fn poll_read(mut self: std::pin::Pin<&mut Self>, _cx: &mut std::task::Context<'_>, buf: &mut tokio::io::ReadBuf<'_>) -> std::task::Poll<std::io::Result<()>> {
            use std::io::Read;
            let mut bytes = vec![0; buf.remaining()];
            let n = self.request.read(&mut bytes).unwrap();
            if n == 0 { return std::task::Poll::Pending; }
            buf.put_slice(&bytes[..n]); std::task::Poll::Ready(Ok(()))
        }
    }
    impl tokio::io::AsyncWrite for FailedWire {
        fn poll_write(self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>, _: &[u8]) -> std::task::Poll<std::io::Result<usize>> {
            std::task::Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into()))
        }
        fn poll_flush(self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>) -> std::task::Poll<std::io::Result<()>> { std::task::Poll::Ready(Ok(())) }
        fn poll_shutdown(self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>) -> std::task::Poll<std::io::Result<()>> { std::task::Poll::Ready(Ok(())) }
    }

    #[tokio::test]
    async fn defect_http_write_failure_after_body_eof_leaks_candidate() {
        let (edge, c, _dir, relay) = live().await;
        let incumbent = request(&edge, &c, "/whip/standup/alice/incumbent", &offer(str0m::media::Direction::SendOnly)).await;
        incumbent.into_body().collect().await.unwrap();
        assert_eq!(edge.refs(&c.token), 1);
        let io = FailedWire { request: std::io::Cursor::new(wire(&c, "/whip/standup/alice/candidate", &offer(str0m::media::Direction::SendOnly)).into_bytes()) };
        let router = edge.router();
        let service = hyper::service::service_fn(move |req: axum::http::Request<hyper::body::Incoming>| {
            router.clone().oneshot(req.map(axum::body::Body::new))
        });
        let result = hyper::server::conn::http1::Builder::new().serve_connection(hyper_util::rt::TokioIo::new(io), service).await;
        assert!(result.is_err());
        tokio::task::yield_now().await;
        eprintln!("WRITE FAILURE actual Hyper={result:?}; refs={} sessions={} runners={}", edge.refs(&c.token), edge.session_count(), edge.runner_count());
        assert_eq!(edge.refs(&c.token), 2, "characterizes leaked failed-answer candidate beside incumbent");
        assert_eq!(edge.session_count(), 2);
        edge.drop_token(&c.token); relay.abort(); let _ = relay.await;
    }
    #[tokio::test]
    async fn real_catalog_timeout_preserves_incumbent_then_controlled_expiry_isolates_tokens() {
        let (edge, c, other, _dir, relay) = live_two().await;
        assert_ne!(c.token, other.token);
        for (cc, path) in [(&c, "/whip/standup/alice/incumbent"), (&other, "/whip/standup/alice/control")] {
            let response = request(&edge, cc, path, &offer(str0m::media::Direction::SendOnly)).await;
            assert_eq!(response.status(), 201); response.into_body().collect().await.unwrap();
        }
        let mut sub = c.clone(); sub.operation = Op::Subscribe; sub.broadcast = "absent/cam".into();
        let result = edge.open_session(&sub, &offer(str0m::media::Direction::RecvOnly)).await;
        assert!(matches!(result, Err(AdmitError::NotStarted)));
        assert_eq!((edge.refs(&c.token), edge.refs(&other.token)), (1,1));
        // Inject a short authenticated deadline to isolate edge lifecycle behavior;
        // not a claim of a real short Mint-issued credential or relay expiry.
        sub.exp = SystemTime::now() + Duration::from_millis(80);
        let result = edge.open_session(&sub, &offer(str0m::media::Direction::RecvOnly)).await;
        assert!(matches!(result, Err(AdmitError::BadToken)));
        assert_eq!((edge.refs(&c.token), edge.refs(&other.token)), (0,1));
        assert_eq!((edge.session_count(), edge.runner_count()), (1,1));
        edge.drop_token(&other.token); relay.abort(); let _ = relay.await;
    }

    #[tokio::test]
    async fn real_relay_death_cleans_two_same_token_legs() {
        let (edge, c, _dir, relay) = live().await;
        for path in ["/whip/standup/alice/one", "/whip/standup/alice/two"] {
            let response = request(&edge, &c, path, &offer(str0m::media::Direction::SendOnly)).await;
            assert_eq!(response.status(), 201); response.into_body().collect().await.unwrap();
        }
        assert_eq!(edge.refs(&c.token), 2);
        relay.abort(); let _ = relay.await;
        tokio::time::timeout(Duration::from_secs(8), async { while edge.refs(&c.token) != 0 { tokio::time::sleep(Duration::from_millis(10)).await; } }).await.unwrap();
        assert_eq!((edge.session_count(), edge.runner_count(), edge.link_count()), (0,0,0));
    }
    #[tokio::test]
    async fn expiry_during_first_dial_finishes_without_mutex_deadlock() {
        let (edge, c) = fixture(); edge.enable_test_dial();
        *edge.test_dial_wait.lock().unwrap() = Duration::from_secs(1);
        let exp = SystemTime::now() + Duration::from_millis(30);
        let result = edge.acquire(&c.token, exp, &setup_deadline(exp).unwrap()).await;
        assert!(matches!(result, Err(AdmitError::BadToken)));
        assert_eq!((edge.link_count(), edge.flight_count(), edge.refs(&c.token)), (0,0,0));
    }

    #[test]
    fn defect_configured_origin_list_still_allows_unlisted_same_host() {
        let (edge, _) = fixture(); edge.set_origins(vec!["https://named-peer.test".into()]);
        assert!(origin_allowed(&edge, "http://edge.test", "edge.test"));
        assert!(origin_allowed(&edge, "https://edge.test", "edge.test"));
        eprintln!("DEFECT nonempty origin allowlist still permits unlisted http/https host origins");
    }
}


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


    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use std::pin::Pin;
    use std::task::{Context, Poll};

    fn wire(c: &Checked, name: &str, close: bool) -> Vec<u8> {
        let sdp = offer(str0m::media::Direction::SendOnly);
        format!("POST /whip/standup/alice/{name} HTTP/1.1\r\nHost: edge.test\r\nAuthorization: Bearer {}\r\nX-Mjolnir-Root: {}\r\nContent-Type: application/sdp\r\nContent-Length: {}\r\n{}\r\n{}", c.token, c.root, sdp.len(), if close {"Connection: close\r\n"} else {""}, sdp).into_bytes()
    }
    async fn until(mut condition: impl FnMut() -> bool) {
        tokio::time::timeout(Duration::from_secs(3), async {
            while !condition() { tokio::task::yield_now().await; }
        }).await.expect("bounded condition");
    }
    async fn tcp(edge: &Arc<Edge>, c: &Checked, name: &str) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let router = edge.router();
        let task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            crate::edge_http::serve_connection(stream, router).await.unwrap();
        });
        let mut stream = tokio::net::TcpStream::connect(addr).await.unwrap();
        stream.write_all(&wire(c,name,true)).await.unwrap();
        let mut out=String::new();
        tokio::time::timeout(Duration::from_secs(3), stream.read_to_string(&mut out)).await.unwrap().unwrap();
        task.await.unwrap();
        assert!(out.starts_with("HTTP/1.1 201"), "{out}");
        out
    }
    #[derive(Clone, Copy)]
    enum Mode { Ok, Broken, Partial, Zero, FlushError, Hold, SecondError }
    struct Wire {
        input: std::io::Cursor<Vec<u8>>, output: Arc<Mutex<Vec<u8>>>, mode: Mode,
        flushed: Arc<AtomicU64>, released: Arc<AtomicBool>, wake: Arc<Mutex<Option<std::task::Waker>>>,
    }
    impl tokio::io::AsyncRead for Wire {
        fn poll_read(mut self: Pin<&mut Self>, _: &mut Context<'_>, buf: &mut tokio::io::ReadBuf<'_>) -> Poll<std::io::Result<()>> {
            let pos=self.input.position() as usize;
            if pos==self.input.get_ref().len() { return Poll::Pending; }
            let n=buf.remaining().min(self.input.get_ref().len()-pos);
            buf.put_slice(&self.input.get_ref()[pos..pos+n]); self.input.set_position((pos+n) as u64);
            Poll::Ready(Ok(()))
        }
    }
    impl tokio::io::AsyncWrite for Wire {
        fn poll_write(self: Pin<&mut Self>, _: &mut Context<'_>, buf:&[u8]) -> Poll<std::io::Result<usize>> {
            let mut out=self.output.lock().unwrap();
            if matches!(self.mode,Mode::Broken) || matches!(self.mode,Mode::Partial) && !out.is_empty() {
                return Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into()));
            }
            if matches!(self.mode,Mode::Zero) { return Poll::Ready(Ok(0)); }
            let n=buf.len().min(17); out.extend_from_slice(&buf[..n]); Poll::Ready(Ok(n))
        }
        fn poll_flush(self: Pin<&mut Self>, cx:&mut Context<'_>) -> Poll<std::io::Result<()>> {
            let count=self.output.lock().unwrap().windows(11).filter(|w| *w==b"201 Created").count();
            if matches!(self.mode,Mode::FlushError) || matches!(self.mode,Mode::SecondError) && count>=2 {
                return Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into()));
            }
            if matches!(self.mode,Mode::Hold) && count > 0 && !self.released.load(Ordering::SeqCst) {
                *self.wake.lock().unwrap()=Some(cx.waker().clone()); return Poll::Pending;
            }
            self.flushed.fetch_add(1, Ordering::SeqCst); Poll::Ready(Ok(()))
        }
        fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {Poll::Ready(Ok(()))}
    }
    fn controlled(edge: &Arc<Edge>, input: Vec<u8>, mode:Mode) -> (tokio::task::JoinHandle<Result<(),hyper::Error>>, Arc<Mutex<Vec<u8>>>, Arc<AtomicU64>, Arc<AtomicBool>, Arc<Mutex<Option<std::task::Waker>>>) {
        let output=Arc::new(Mutex::new(Vec::new())); let flushed=Arc::new(AtomicU64::new(0));
        let released=Arc::new(AtomicBool::new(false)); let wake=Arc::new(Mutex::new(None));
        let io=Wire{input:std::io::Cursor::new(input),output:output.clone(),flushed:flushed.clone(),released:released.clone(),wake:wake.clone(),mode};
        (tokio::spawn(crate::edge_http::serve_connection(io,edge.router())), output,flushed,released,wake)
    }
    #[tokio::test]
    async fn real_tcp_flush_runner_finish_and_cap() {
        let (edge,c,_dir,relay)=live().await;
        let out=tcp(&edge,&c,"natural").await;
        assert!(out.contains("b=TIAS:2250000"));
        assert_eq!((edge.refs(&c.token),edge.runner_count()),(1,1));
        tokio::time::timeout(Duration::from_secs(40),async {
            while edge.session_count()!=0 {tokio::time::sleep(Duration::from_millis(20)).await;}
        }).await.expect("actual Response ICE timeout completes runner");
        assert_eq!((edge.refs(&c.token),edge.runner_count(),edge.link_count()),(0,0,0));
        relay.abort();
    }
    #[tokio::test]
    async fn real_transport_failure_matrix_preserves_incumbent() {
        let (edge,c,_dir,relay)=live().await;
        tcp(&edge,&c,"incumbent").await;
        for (i,mode) in [Mode::Broken,Mode::Partial,Mode::Zero,Mode::FlushError].into_iter().enumerate() {
            let (task,_,_,_,_)=controlled(&edge,wire(&c,&format!("failure{i}"),false),mode);
            assert!(tokio::time::timeout(Duration::from_secs(3),task).await.unwrap().unwrap().is_err());
            assert_eq!((edge.session_count(),edge.runner_count(),edge.refs(&c.token)),(1,1,1));
        }
        let (task,_,_,_,wake)=controlled(&edge,wire(&c,"drop",false),Mode::Hold);
        until(||wake.lock().unwrap().is_some()).await;
        assert_eq!((edge.session_count(),edge.runner_count()),(2,1));
        task.abort();let _=task.await;
        assert_eq!((edge.session_count(),edge.runner_count(),edge.refs(&c.token)),(1,1,1));
        edge.drain();relay.abort();
    }
    #[tokio::test]
    async fn real_pipelined_failure_commits_only_first() {
        let (edge,c,_dir,relay)=live().await;
        let mut input=wire(&c,"pipe1",false);input.extend(wire(&c,"pipe2",false));
        let (task,out,_,_,_)=controlled(&edge,input,Mode::SecondError);
        assert!(tokio::time::timeout(Duration::from_secs(3),task).await.unwrap().unwrap().is_err());
        assert_eq!(out.lock().unwrap().windows(11).filter(|w|*w==b"201 Created").count(),2);
        assert_eq!((edge.session_count(),edge.runner_count(),edge.refs(&c.token)),(1,1,1));
        edge.drain();relay.abort();
    }
    #[tokio::test]
    async fn real_pending_teardown_does_not_wake_http_defect() {
        let (edge,c,_dir,relay)=live().await;
        for reason in ["deadline","delete","relay"] {
            let (task,_,_,release,wake)=controlled(&edge,wire(&c,reason,false),Mode::Hold);
            until(||wake.lock().unwrap().is_some()).await;
            let id={let p=edge.pool.lock().unwrap();let (id,s)=p.sessions.iter().next().unwrap();assert!(matches!(s.leg,Leg::Pending{response:Some(_),..}));id.clone()};
            assert_eq!(edge.runner_count(),0);
            match reason {
                "deadline"=>tokio::time::sleep(Duration::from_millis(5200)).await,
                "delete"=>{edge.delete(&id,Some(&c.token),SystemTime::now()).unwrap();},
                _=>{relay.abort();let conn=edge.pool.lock().unwrap().links[&c.token].shared.clone().unwrap(); conn.close();},
            }
            until(||edge.session_count()==0).await;
            assert!(!edge.moq.lock().unwrap().as_ref().unwrap().media.terminate(&id));
            tokio::time::sleep(Duration::from_millis(30)).await;
            assert!(!task.is_finished(),"characterizes missing HTTP wake/termination on {reason}");
            release.store(true,Ordering::SeqCst); if let Some(w)=wake.lock().unwrap().take(){w.wake();}
            tokio::time::sleep(Duration::from_millis(30)).await;
            assert!(!task.is_finished(),"rejected ack still does not terminate HTTP");
            assert_eq!(edge.runner_count(),0);
            task.abort();let _=task.await;
            eprintln!("DEFECT real pending {reason} removed RTC ownership but left HTTP task pending, including after flush release");
        }
    }
    #[tokio::test]
    async fn real_unrun_drop_missing_context_and_relay_cleanup() {
        let (edge,c,_dir,relay)=live().await;
        let n=edge.open_session(&c,&offer(str0m::media::Direction::SendOnly)).await.unwrap();
        assert!(matches!(edge.pool.lock().unwrap().sessions[&n.id].leg,Leg::Pending{response:Some(_),..}));
        let id=n.id.clone(); drop(n);assert!(!edge.moq.lock().unwrap().as_ref().unwrap().media.terminate(&id));assert_eq!(edge.session_count(),0);assert_eq!(edge.refs(&c.token),0);
        let response=request(&edge,&c,"/whip/standup/alice/bare",&offer(str0m::media::Direction::SendOnly)).await;
        assert_eq!(response.status(),503); assert_eq!(edge.session_count(),0);
        tcp(&edge,&c,"live1").await;tcp(&edge,&c,"live2").await;
        assert_eq!((edge.refs(&c.token),edge.runner_count()),(2,2));
        relay.abort();until(||edge.session_count()==0).await;
        assert_eq!((edge.refs(&c.token),edge.runner_count(),edge.link_count()),(0,0,0));
    }
    #[tokio::test]
    async fn preexpiry_pending_deadline_wrongly_reports_token_expiry_defect() {
        let (edge,c)=fixture();edge.enable_test_dial();
        let incumbent=edge.attach(&c,"","",SystemTime::now()).await.unwrap();
        let deadline=setup_deadline(c.exp).unwrap();let reservation=edge.acquire(&c.token,c.exp,&deadline).await.unwrap();
        let result=edge.insert_pending(&reservation,"late",&c,None,UNIX_EPOCH);
        assert_eq!(result,Err(AdmitError::BadToken));
        assert!(SystemTime::now()<c.exp);
        eprintln!("DEFECT insert_pending returns BadToken for pre-expiry setup deadline; open_session then drops whole token, incumbent {incumbent}");
        drop(reservation);edge.drain();
    }

    #[tokio::test]
    async fn real_three_pipeline_success_and_h2_rejection() {
        let (edge,c,_dir,relay)=live().await;
        let mut input=wire(&c,"one",false);input.extend(wire(&c,"two",false));input.extend(wire(&c,"three",true));
        let (task,out,_,_,_)=controlled(&edge,input,Mode::Ok);
        tokio::time::timeout(Duration::from_secs(4),task).await.unwrap().unwrap().unwrap();
        assert_eq!(out.lock().unwrap().windows(11).filter(|w|*w==b"201 Created").count(),3);
        assert_eq!((edge.session_count(),edge.runner_count(),edge.refs(&c.token)),(3,3,3));
        let (task,_,_,_,_)=controlled(&edge,b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".to_vec(),Mode::Ok);
        assert!(tokio::time::timeout(Duration::from_secs(2),task).await.unwrap().unwrap().is_err());
        assert_eq!(edge.runner_count(),3);edge.drain();relay.abort();
    }
    #[tokio::test]
    async fn real_ack_expiry_only_cancels_candidate_defect() {
        let (edge,c,other,_dir,relay)=live_two().await;
        tcp(&edge,&c,"incumbent").await;tcp(&edge,&other,"control").await;
        let (task,_,_,release,wake)=controlled(&edge,wire(&c,"expired",false),Mode::Hold);
        until(||wake.lock().unwrap().is_some()).await;
        let (id,generation)={let mut p=edge.pool.lock().unwrap();let (id,s)=p.sessions.iter_mut().find(|(_,s)|matches!(s.leg,Leg::Pending{..})).unwrap();s.exp_unix=0;(id.clone(),s.generation)};
        // Isolate ack's expiry branch ahead of the independent token-expiry task.
        assert!(!edge.ack_delivery(&id,generation));
        assert_eq!((edge.refs(&c.token),edge.refs(&other.token),edge.runner_count()),(1,1,2));
        eprintln!("DEFECT ack expiry branch leaves same-token incumbent running; independent expiry task not executed in this controlled ordering");
        release.store(true,Ordering::SeqCst);if let Some(w)=wake.lock().unwrap().take(){w.wake();}
        task.abort();let _=task.await;edge.drain();relay.abort();
    }
    #[tokio::test]
    async fn real_catalog_timeout_and_whole_token_expiry_regression() {
        let (edge,c,other,_dir,relay)=live_two().await;
        tcp(&edge,&c,"incumbent").await;tcp(&edge,&other,"control").await;
        let mut sub=c.clone();sub.operation=Op::Subscribe;sub.broadcast="absent/cam".into();
        assert!(matches!(edge.open_session(&sub,&offer(str0m::media::Direction::RecvOnly)).await,Err(AdmitError::NotStarted)));
        assert_eq!((edge.refs(&c.token),edge.refs(&other.token)),(1,1));
        sub.exp=SystemTime::now()+Duration::from_millis(80);
        assert!(matches!(edge.open_session(&sub,&offer(str0m::media::Direction::RecvOnly)).await,Err(AdmitError::BadToken)));
        assert_eq!((edge.refs(&c.token),edge.refs(&other.token),edge.runner_count()),(0,1,1));
        edge.drain();relay.abort();
    }

    #[tokio::test]
    async fn real_pending_ack_gates_do_not_resurrect_or_start() {
        let (edge,c,_dir,relay)=live().await;
        let n=edge.open_session(&c,&offer(str0m::media::Direction::SendOnly)).await.unwrap();
        assert!(!edge.ack_delivery(&n.id,n.generation+1));
        assert_eq!((edge.session_count(),edge.runner_count()),(1,0));
        edge.delete(&n.id,Some(&c.token),SystemTime::now()).unwrap();
        assert!(!edge.ack_delivery(&n.id,n.generation));
        assert!(!edge.moq.lock().unwrap().as_ref().unwrap().media.terminate(&n.id));
        drop(n);
        let n=edge.open_session(&c,&offer(str0m::media::Direction::SendOnly)).await.unwrap();
        {let mut p=edge.pool.lock().unwrap();if let Leg::Pending{deadline,..}=&mut p.sessions.get_mut(&n.id).unwrap().leg{*deadline=UNIX_EPOCH;}}
        assert!(!edge.ack_delivery(&n.id,n.generation));assert_eq!(edge.runner_count(),0);
        assert!(!edge.moq.lock().unwrap().as_ref().unwrap().media.terminate(&n.id));drop(n);
        let n=edge.open_session(&c,&offer(str0m::media::Direction::SendOnly)).await.unwrap();
        edge.drain();assert!(!edge.ack_delivery(&n.id,n.generation));
        assert_eq!((edge.session_count(),edge.runner_count(),edge.refs(&c.token)),(0,0,0));
        assert!(!edge.moq.lock().unwrap().as_ref().unwrap().media.terminate(&n.id));drop(n);relay.abort();
    }
}

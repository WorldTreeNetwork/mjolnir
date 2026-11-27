
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
    enum Mode { Ok, Broken, Partial, Zero, FlushError, Hold, HoldWrite, HoldVector, SecondError }
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
        fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf:&[u8]) -> Poll<std::io::Result<usize>> {
            if matches!(self.mode,Mode::HoldWrite) { *self.wake.lock().unwrap()=Some(cx.waker().clone()); return Poll::Pending; }
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
        fn is_write_vectored(&self) -> bool { matches!(self.mode,Mode::HoldVector) }
        fn poll_write_vectored(self: Pin<&mut Self>, cx: &mut Context<'_>, _bufs:&[std::io::IoSlice<'_>]) -> Poll<std::io::Result<usize>> {
            *self.wake.lock().unwrap()=Some(cx.waker().clone());
            Poll::Pending
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
    async fn real_ack_expiry_detaches_generation() {
        let (edge,c,other,_dir,relay)=live_two().await;
        tcp(&edge,&c,"incumbent").await;tcp(&edge,&other,"control").await;
        let (task,_,_,release,wake)=controlled(&edge,wire(&c,"expired",false),Mode::Hold);
        until(||wake.lock().unwrap().is_some()).await;
        let (id,generation)={
            let mut p=edge.pool.lock().unwrap();
            // Consistent controlled token state, before the independently armed real timers.
            let hold=p.holds.get_mut(&c.token).unwrap();hold.exp=UNIX_EPOCH;hold.exp_unix=0;
            for s in p.sessions.values_mut().filter(|s|s.token==c.token) {s.exp_unix=0;}
            let (id,s)=p.sessions.iter().find(|(_,s)|matches!(s.leg,Leg::Pending{..})).unwrap();
            (id.clone(),s.generation)
        };
        // Isolate ack's expiry branch ahead of the independent token-expiry task.
        assert!(!edge.ack_delivery(&id,generation));
        assert_eq!((edge.refs(&c.token),edge.refs(&other.token),edge.runner_count()),(0,1,1));
        eprintln!("ack-first expiry detached same-token incumbent, preserved other token");
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
        {let mut p=edge.pool.lock().unwrap();if let Leg::Pending{bound,..}=&mut p.sessions.get_mut(&n.id).unwrap().leg{*bound=Deadline{at:tokio::time::Instant::now(),exp_bound:false};}}
        assert!(!edge.ack_delivery(&n.id,n.generation));assert_eq!(edge.runner_count(),0);
        assert!(!edge.moq.lock().unwrap().as_ref().unwrap().media.terminate(&n.id));drop(n);
        let n=edge.open_session(&c,&offer(str0m::media::Direction::SendOnly)).await.unwrap();
        edge.drain();assert!(!edge.ack_delivery(&n.id,n.generation));
        assert_eq!((edge.session_count(),edge.runner_count(),edge.refs(&c.token)),(0,0,0));
        assert!(!edge.moq.lock().unwrap().as_ref().unwrap().media.terminate(&n.id));drop(n);relay.abort();
    }

    #[tokio::test]
    async fn real_held_scalar_output_terminates_on_all_invalidations() {
        for mode in [Mode::Hold,Mode::HoldWrite] {
            for reason in ["deadline","delete","drain","relay"] {
                let (edge,c,other,_dir,relay)=live_two().await;
                tcp(&edge,&c,"incumbent").await;tcp(&edge,&other,"control").await;
                let (task,_,_,_,wake)=controlled(&edge,wire(&c,"candidate",false),mode);
                until(||wake.lock().unwrap().is_some()).await;
                let id={let p=edge.pool.lock().unwrap();let (id,s)=p.sessions.iter().find(|(_,s)|matches!(s.leg,Leg::Pending{..})).unwrap();assert!(matches!(s.leg,Leg::Pending{response:Some(_),..}));id.clone()};
                match reason {
                    "deadline"=>tokio::time::sleep(Duration::from_millis(5100)).await,
                    "delete"=>{edge.delete(&id,Some(&c.token),SystemTime::now()).unwrap();},
                    "drain"=>edge.drain(),
                    _=>{edge.pool.lock().unwrap().links[&c.token].shared.clone().unwrap().close();},
                }
                assert!(tokio::time::timeout(Duration::from_secs(2),task).await.expect("HTTP completes without external abort").unwrap().is_err());
                assert!(!edge.moq.lock().unwrap().as_ref().unwrap().media.terminate(&id));
                let expected=match reason {"drain"=>(0,0,0),"relay"=>(0,1,1),_=>(1,1,2)};
                assert_eq!((edge.refs(&c.token),edge.refs(&other.token),edge.runner_count()),expected);
                edge.drain();relay.abort();
            }
        }
    }
    #[tokio::test]
    async fn real_vectored_write_invalidation_defect() {
        let (edge,c,_dir,relay)=live().await;
        tcp(&edge,&c,"incumbent").await;
        let (mut task,_,_,_,wake)=controlled(&edge,wire(&c,"vector",false),Mode::HoldVector);
        until(||wake.lock().unwrap().is_some()).await;
        let id={let p=edge.pool.lock().unwrap();let (id,s)=p.sessions.iter().find(|(_,s)|matches!(s.leg,Leg::Pending{..})).unwrap();assert!(matches!(s.leg,Leg::Pending{response:Some(_),..}));id.clone()};
        edge.delete(&id,Some(&c.token),SystemTime::now()).unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(200),&mut task).await.is_err(),"characterization: held vectored write remains pending");
        // Even an unrelated socket wake cannot reach the cancellation check.
        if let Some(w)=wake.lock().unwrap().take(){w.wake();}
        assert!(tokio::time::timeout(Duration::from_millis(200),&mut task).await.is_err());
        assert_eq!((edge.session_count(),edge.runner_count(),edge.refs(&c.token)),(1,1,1));
        assert!(!edge.moq.lock().unwrap().as_ref().unwrap().media.terminate(&id));
        eprintln!("DEFECT: real Response deleted, but vectored HTTP output stays pending even after socket wake; external abort required");
        task.abort();let _=task.await;edge.drain();relay.abort();
    }

    #[tokio::test]
    async fn real_final_registration_distinguishes_deadline_and_expiry() {
        let (edge,c,other,_dir,relay)=live_two().await;
        tcp(&edge,&c,"incumbent").await;tcp(&edge,&other,"control").await;
        for catalog in [false,true] {
            let bound=setup_deadline(c.exp).unwrap();
            let mut reservation=edge.acquire(&c.token,c.exp,&bound).await.unwrap();
            let shared=edge.pool.lock().unwrap().links[&c.token].shared.clone().unwrap();
            let config=edge.moq.lock().unwrap().clone().unwrap();
            let response=crate::moq_session::whip(&config,&shared,"alice/final",&offer(str0m::media::Direction::SendOnly)).await.unwrap();
            let id=response.resource_id.clone();
            let late=Deadline{at:tokio::time::Instant::now(),exp_bound:false};
            let result=edge.insert_pending(&mut reservation,&id,&c,Some(response),late,catalog);
            assert_eq!(result,Err(if catalog {AdmitError::NotStarted}else{AdmitError::SetupFailed}));
            drop(reservation);
            assert!(!config.media.terminate(&id));
            assert_eq!((edge.refs(&c.token),edge.refs(&other.token),edge.runner_count()),(1,1,2));
        }
        let bound=setup_deadline(c.exp).unwrap();let mut reservation=edge.acquire(&c.token,c.exp,&bound).await.unwrap();
        let mut expired=c.clone();expired.exp=UNIX_EPOCH;expired.exp_unix=0;
        let result=edge.insert_pending(&mut reservation,"expired",&expired,None,bound,false);
        assert_eq!(result,Err(AdmitError::BadToken));
        // Same handling as open_session's final insertion error branch.
        reservation.disarm();edge.drop_token(&expired.token);
        assert_eq!((edge.refs(&c.token),edge.refs(&other.token),edge.runner_count()),(0,1,1));
        edge.drain();relay.abort();
    }
    #[tokio::test]
    async fn real_ack_dead_relay_and_watcher_detach_generation() {
        let (edge,c,other,_dir,relay)=live_two().await;
        tcp(&edge,&c,"incumbent").await;tcp(&edge,&other,"control").await;
        let n=edge.open_session(&c,&offer(str0m::media::Direction::SendOnly)).await.unwrap();
        let conn=edge.pool.lock().unwrap().links[&c.token].shared.clone().unwrap();
        conn.close();
        until(||conn.dead()).await; // watcher may win; expiry probe isolates the ack-first branch.
        assert!(!edge.ack_delivery(&n.id,n.generation));
        assert_eq!((edge.refs(&c.token),edge.refs(&other.token),edge.runner_count()),(0,1,1));
        drop(n);edge.drain();relay.abort();
    }
    #[tokio::test(flavor="multi_thread",worker_threads=2)]
    async fn real_last_release_closes_under_lock_before_redial() {
        let (edge,c,_dir,relay)=live().await;
        tcp(&edge,&c,"first").await;
        let (tx,rx)=tokio::sync::oneshot::channel();let tx=Mutex::new(Some(tx));
        let (release_tx,release_rx)=std::sync::mpsc::channel();let release_rx=Mutex::new(release_rx);
        let old=edge.pool.lock().unwrap().links[&c.token].shared.clone().unwrap();
        let old_probe=old.clone();let weak=Arc::downgrade(&edge);
        let id=edge.pool.lock().unwrap().sessions.keys().next().unwrap().clone();
        edge.pool.lock().unwrap().links.get_mut(&c.token).unwrap().retire_probe=Some(Arc::new(move||{
            assert!(weak.upgrade().unwrap().pool.try_lock().is_err());
            let start=std::time::Instant::now();
            while !old_probe.dead() && start.elapsed()<Duration::from_secs(1) {std::thread::sleep(Duration::from_millis(1));}
            assert!(old_probe.dead(),"actual connection stops while slot remains locked");
            tx.lock().unwrap().take().unwrap().send(()).unwrap();
            release_rx.lock().unwrap().recv_timeout(Duration::from_secs(3)).unwrap();
        }));
        let e=edge.clone();let token=c.token.clone();
        let retiring=tokio::task::spawn_blocking(move||e.delete(&id,Some(&token),SystemTime::now()).unwrap());
        rx.await.unwrap();
        let e=edge.clone();let next=c.clone();
        let acquiring=tokio::spawn(async move {e.open_session(&next,&offer(str0m::media::Direction::SendOnly)).await.unwrap()});
        // Acquire cannot pass the retirement barrier; old connection is already aborted.
        assert!(old.dead());assert!(!acquiring.is_finished());
        release_tx.send(()).unwrap();retiring.await.unwrap();
        let n=acquiring.await.unwrap();assert!(old.dead());assert_eq!(edge.link_count(),1);
        drop(n);edge.drain();relay.abort();
    }
    #[tokio::test]
    async fn real_keepalive_post_delete_prunes_tickets() {
        let (edge,c,_dir,relay)=live().await;
        let listener=tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();let addr=listener.local_addr().unwrap();let router=edge.router();
        let server=tokio::spawn(async move {let (stream,_)=listener.accept().await.unwrap();crate::edge_http::serve_connection(stream,router).await});
        let mut stream=tokio::net::TcpStream::connect(addr).await.unwrap();
        for i in 0..12 {
            stream.write_all(&wire(&c,&format!("cycle{i}"),false)).await.unwrap();
            let mut out=Vec::new();let mut buf=[0;8192];
            tokio::time::timeout(Duration::from_secs(3),async {
                loop {let n=stream.read(&mut buf).await.unwrap();assert!(n>0);out.extend_from_slice(&buf[..n]);if out.ends_with(b"0\r\n\r\n"){break;}}
            }).await.unwrap();
            assert!(out.starts_with(b"HTTP/1.1 201"));
            until(||edge.runner_count()==1).await;
            assert_eq!(crate::edge_http::OPEN_TICKETS.load(Ordering::SeqCst),0);
            let id=edge.pool.lock().unwrap().sessions.keys().next().unwrap().clone();
            let delete=format!("DELETE /session/{id} HTTP/1.1\r\nHost: edge.test\r\nAuthorization: Bearer {}\r\n\r\n",c.token);
            stream.write_all(delete.as_bytes()).await.unwrap();let mut out=Vec::new();
            tokio::time::timeout(Duration::from_secs(3),async {loop {let n=stream.read(&mut buf).await.unwrap();assert!(n>0);out.extend_from_slice(&buf[..n]);if out.ends_with(b"\r\n\r\n"){break;}}}).await.unwrap();
            assert!(out.starts_with(b"HTTP/1.1 204"));
            assert_eq!((edge.session_count(),edge.refs(&c.token),crate::edge_http::OPEN_TICKETS.load(Ordering::SeqCst)),(0,0,0));
        }
        drop(stream);tokio::time::timeout(Duration::from_secs(2),server).await.unwrap().unwrap().unwrap();relay.abort();
    }
}

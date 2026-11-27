#[cfg(test)]
mod independent_review {
 use super::*;
 use crate::keyframe::{Gate, Keyframes, Cause};
 struct Sink { track: moq_net::track::Producer, mid: str0m::media::Mid }
 impl MediaSink for Sink {
  fn on_track(&mut self, _: str0m::media::Mid, _: str0m::media::MediaKind, _: str0m::format::Codec, _: Option<(u32,u32)>) -> Result<()> { Ok(()) }
  fn on_frame(&mut self, _: str0m::media::Mid, _: codec::Frame) -> Result<()> { Ok(()) }
  fn on_discontinuity(&mut self, _: str0m::media::Mid) -> Result<()> { Ok(()) }
  fn abort(&mut self, _: moq_net::Error) {}
  fn finish(&mut self) -> Result<moq_net::broadcast::Producer> { unreachable!() }
  fn demand(&mut self, _: str0m::media::Mid) -> Option<moq_net::track::Demand> { Some(self.track.demand()) }
  fn join_samples(&mut self) -> Vec<(str0m::media::Mid,Option<u64>,Option<u64>)> { vec![(self.mid,self.track.demand().wanted(),self.track.largest().map(|p|p.group))] }
 }
 async fn fixture() -> (Session,moq_net::track::Producer,str0m::media::Mid) {
  let now=Instant::now().into_std();
  let mut offerer=rtc_config().unwrap().build(now);
  let mut api=offerer.sdp_api();
  let mid=api.add_media(str0m::media::MediaKind::Video,str0m::media::Direction::SendOnly,None,None,None);
  let (offer,_)=api.apply().unwrap();
  let mut rtc=rtc_config().unwrap().build(now);
  rtc.sdp_api().accept_offer(offer).unwrap();
  let broadcast=moq_net::broadcast::Info::new().produce();
  let track=broadcast.unique_track("v",moq_net::track::Info::default().with_refresh(Some(4))).unwrap();
  let mut s=Session::ingest(rtc,bind_udp().await.unwrap(),Box::new(Sink{track:track.clone(),mid})).unwrap().with_keyframes(Keyframes::trial());
  s.handle_media(mid).unwrap();
  s.agent=crate::ice::Agent::new(rtc_config().unwrap().build(now),bind_udp().await.unwrap()).unwrap(); // explicit missing-writer fixture after opening the negotiated line
  (s,track,mid)
 }
 fn group(track:&moq_net::track::Producer) {
  let mut g=track.create_group(moq_net::group::Info{start:1}).unwrap();
  g.write_frame(moq_net::Timestamp::unscaled(1),&b"key"[..]).unwrap();
  g.write_frame(moq_net::Timestamp::unscaled(1),vec![0u8;13]).unwrap();
  g.finish().unwrap();
 }
 async fn drive(s:&mut Session) {
  assert!(tokio::time::timeout(Duration::from_millis(10),s.run_loop()).await.is_err());
 }
 #[tokio::test]
 async fn review_queued_initial_sample_loses_join_in_real_loop() {
  let (mut s,track,mid)=fixture().await;
  tokio::task::yield_now().await;
  assert_eq!(s.demand_rx.len(),1,"initial None notification queued");
  group(&track);
  let _sub=track.subscribe(None);
  tokio::task::yield_now().await;
  assert_eq!(s.demand_rx.len(),2);
  assert_eq!(track.demand().wanted(),Some(track.largest().unwrap().group+1));
  drive(&mut s).await;
  assert_eq!(s.gates[&mid].held,0,"BUG: both notifications sampled as initial high wanted; no Join attempt");
 }
 #[tokio::test]
 async fn review_drained_baseline_control_and_parked_join_retry() {
  let (mut s,track,mid)=fixture().await;
  drive(&mut s).await; // initialize baseline before join
  let p=Keyframes::trial();
  s.gates.get_mut(&mid).unwrap().note(Cause::Period,Instant::now(),&p);
  s.fire_gates();
  assert_eq!(s.gates[&mid].held,1);
  assert!(s.gates[&mid].deadline().is_none());
  group(&track);
  let _sub=track.subscribe(None);
  drive(&mut s).await;
  assert_eq!(s.gates[&mid].held,2,"BUG: immediate Join retries parked writer without media/future deadline");
 }
 #[tokio::test(start_paused = true)]
 async fn review_open_period_parks_and_remb_style_calls_stay_quiet() {
  let (mut s,_track,mid)=fixture().await;
  let p=Keyframes::trial();
  s.gates.insert(mid,Gate::open(&p,Instant::now(),true));
  assert!(tokio::time::timeout(Duration::from_secs(10),s.run_loop()).await.is_err());
  assert_eq!(s.gates[&mid].held,1);
  for _ in 0..100 { s.fire_gates(); }
  assert_eq!(s.gates[&mid].held,1);
  assert!(s.gates[&mid].deadline().is_none());
 }
 #[tokio::test]
 async fn review_floor_and_no_pli_make_real_loop_progress() {
  let (mut s,_track,mid)=fixture().await;
  let mut p=Keyframes::trial(); p.period=Duration::from_millis(1);
  s.keyframes=Some(p);
  let mut gate=Gate::open(&p,Instant::now(),true);
  gate.note(Cause::Startup,Instant::now(),&p);
  gate.poll_send(&p,Instant::now(),true); // seed one accepted send, isolate scheduler
  s.gates.insert(mid,gate);
  drive(&mut s).await;
  assert!(s.gates[&mid].deadline().unwrap()>Instant::now());
  assert_eq!(s.gates[&mid].held,0);
  s.gates.insert(mid,Gate::open(&p,Instant::now(),false));
  drive(&mut s).await;
  assert!(s.gates[&mid].deadline().is_none());
 }

 #[tokio::test(start_paused = true)]
 async fn review_loss_due_at_floor_without_other_media() {
  let (mut s,_track,mid)=fixture().await;
  let p=Keyframes::trial();
  let t=Instant::now();
  let mut gate=Gate::open(&p,t,true);
  gate.note(Cause::Startup,t,&p);
  gate.poll_send(&p,t,true); // seed accepted send; writer is absent for next attempt
  s.gates.insert(mid,gate);
  tokio::time::advance(Duration::from_millis(300)).await;
  s.gates.get_mut(&mid).unwrap().note(Cause::Loss,Instant::now(),&p);
  assert_eq!(s.gates[&mid].deadline(),Some(t.saturating_add(p.floor)));
  assert!(tokio::time::timeout(Duration::from_millis(701),s.run_loop()).await.is_err());
  assert_eq!(s.gates[&mid].held,1);
  let mut snapshot=s.gates[&mid].clone();
  match snapshot.poll_send(&p,Instant::now(),false).unwrap() {
   crate::keyframe::Send::Held{causes} => assert_eq!(crate::keyframe::cause_names(causes),["loss"]),
   _ => panic!("missing writer"),
  }
 }
 #[tokio::test]
 async fn review_dropped_session_leaves_watcher_until_track_closes() {
  let (s,track,_mid)=fixture().await;
  tokio::task::yield_now().await;
  let weak=s.demand_tx.downgrade();
  drop(s); // public custom sink retains an externally owned producer
  tokio::task::yield_now().await;
  assert!(weak.upgrade().is_some(),"watch task still owns sender after receiver dropped");
  track.abort(moq_net::Error::Cancel).unwrap();
  tokio::task::yield_now().await;
  assert!(weak.upgrade().is_none(),"track closure releases task");
 }
}

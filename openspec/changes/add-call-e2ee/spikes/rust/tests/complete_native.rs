#![cfg(feature="native-media")]
#[path="../../complete/common.rs"] mod common;
use common::*;
use iroh_live::media::*;
use std::time::Duration;
use moq_net::broadcast::{TracksEvent,Listed};

#[tokio::test(flavor="multi_thread")]
async fn real_native_media() {
 tokio::time::timeout(Duration::from_secs(45), run()).await.expect("native media deadline");
}
async fn run(){
 let r=start().await;let(router,id)=iroh_relay(&r).await;
 let(node,link)=iroh_node(id,&room_token(&r.key,"r1","alice",60)).await;
 let source=VideoSource::test_pattern(video::Size::new(320,180),video::FrameRate::new(30,1).unwrap()).unwrap();
 let local=LocalBroadcast::new();
 let mut encoding=VideoEncoding::single(VideoRendition::new("video").with_size(video::Size::new(320,180)));
 encoding.renditions[0].config.kind=video::encode::Kind::Software;
 local.set_video(source,encoding).unwrap();
 local.set_audio(AudioSource::tone(440.0,audio::Layout::Mono).unwrap(),audio_encoding::voice()).unwrap();
 let cred=credential([17;32],1);let generation=cred.produce();let opaque=cred.path("alice").unwrap();
 let path=format!("alice/{opaque}/{}",generation.epoch());let full=format!("t/{}/r1/{path}",owner());
 let(publication,protected)=node.publish_with(full.as_str(),iroh_live::Audience::Granted,|b|Ok::<_,moq_e2ee::Error>(moq_e2ee::broadcast::Producer::new(b.clone(),generation))).unwrap();
 let mut manifest=protected.create_track("bridge.tracks",timed()).unwrap();
 let plain=local.consume();
 let bridge=tokio::spawn(async move{
  let mut listing=plain.tracks().unwrap();let mut known=serde_json::Map::new();
  while let Some(ev)=listing.next().await.unwrap(){
   if let TracksEvent::Added{name,info:Listed::Track(info)}=ev{
    assert!(name.len()<=15,"semantic length");println!("native bridge listed {name} scale {:?}",info.timescale);
    let mut out=protected.create_track(&name,info.clone()).unwrap();
    known.insert(name.to_string(),serde_json::json!(info.timescale.map(u64::from)));
    let stamp=moq_net::Timestamp::from_millis(known.len() as u64).unwrap();let mut g=manifest.create_group(known.len() as u64).unwrap();g.write_frame(stamp,&serde_json::to_vec(&known).unwrap()).unwrap();g.finish().unwrap();
    let src=plain.clone();tokio::spawn(async move{
     let mut sub=src.track(&name).unwrap().subscribe(None).await.unwrap();
     while let Ok(Some(mut g))=sub.recv_group().await{
      let mut dest=out.create_group(g.start).unwrap();
      tokio::spawn(async move {while let Ok(Some(f))=g.read_frame().await{if dest.write_frame(f.timestamp,&f.payload).is_err(){return}}let _=dest.finish();});
     }
    });
   }
  }
 });
 let origin=moq_tokio::origin::spawn();let table=origin.consume();
 let session=client().with_subscriber(origin).connect(url(&r,&room_token(&r.key,"r1","bob",60))).established().await.unwrap();
 let remote=table.follow(path.as_str(),None).unwrap().available().await.unwrap().unwrap();
 // Subscriber takes epoch from the discovered path, never the producer's generation object.
 let epoch=path.rsplit('/').next().unwrap().parse().unwrap();
 assert_eq!(path.split('/').nth(1).unwrap(),cred.path("alice").unwrap().as_str());
 let cg=cred.consume(epoch);let metadata=remote.clone();
 let sealed=moq_e2ee::broadcast::Consumer::new(remote,cg.clone());
 let mirror_origin=moq_tokio::origin::spawn();let mirror_route=mirror_origin.route("local",moq_net::origin::RouteOptions::hidden()).unwrap();
 let mirror=mirror_route.broadcast().clone();let consumer=mirror.consume();
 let decrypt=tokio::spawn(async move {
  let mut manifest=sealed.subscribe("bridge.tracks",None).unwrap().await.unwrap();let mut made=std::collections::HashSet::new();
  while let Some(mut g)=manifest.recv_group().await.unwrap(){
   let f=g.read_frame().await.unwrap().unwrap();let map:serde_json::Map<String,serde_json::Value>=serde_json::from_slice(&f.plaintext).unwrap();
   for(name,scale)in map{if !made.insert(name.clone()){continue}
    let _=scale;let info=metadata.track(cg.name(&name).unwrap().as_str()).unwrap().info().await.unwrap();
    let dest=mirror.create_track(name.as_str(),info).unwrap();let mut sub=sealed.subscribe(&name,None).unwrap().await.unwrap();
    tokio::spawn(async move{while let Ok(Some(mut g))=sub.recv_group().await{let mut d=dest.create_group(moq_net::group::Info { start: g.start() }).unwrap();tokio::spawn(async move{while let Ok(Some(f))=g.read_frame().await{if d.write_frame(f.timestamp,f.plaintext).is_err(){return}}let _=d.finish();});}});
   }
  }
 });
 let player=RemoteBroadcast::from_consumer(consumer).play(PlayerConfig::default().with_audio(AudioMode::Decode)).unwrap();
 let mut vf=player.video_frames();let mut af=player.audio_frames();
 let mut checksums=std::collections::HashSet::new();let mut timestamps=std::collections::HashSet::new();let mut audio_samples=0;let mut peak=0f32;
 for _ in 0..20{let f=vf.next().await.unwrap();assert_eq!(f.size(),video::Size::new(320,180));timestamps.insert(format!("{:?}",f.timestamp));let pixels=f.surface.to_i420().unwrap();checksums.insert(pixels.data().iter().enumerate().fold(0u64,|a,(i,b)|a.wrapping_add((i as u64+1)*u64::from(*b))));}
 for _ in 0..20{let f=af.next().await.unwrap();audio_samples+=f.samples.len();for x in f.samples.iter(){peak=peak.max(x.abs())}}
 assert!(timestamps.len()>=15);assert!(checksums.len()>=10);println!("native moving pixel checksums={}",checksums.len());assert!(peak>0.01);println!("NATIVE PLAYBACK decoded_frames={} audio_samples={audio_samples} peak={peak} stats={:?}",timestamps.len(),local.stats());
 drop(player);local.close();bridge.abort();decrypt.abort();drop((publication,session));link.detach().await;node.shutdown().await;router.shutdown().await.unwrap();r.trigger.start();
}

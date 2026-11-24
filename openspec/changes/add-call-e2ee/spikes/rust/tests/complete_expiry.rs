#[path="../../complete/common.rs"] mod common;
use common::*;
use std::time::{Duration,Instant};use iroh::Watcher;
#[tokio::test(flavor="multi_thread")]
async fn room_expiry_both_transports(){
 let r=start().await;
 let start=Instant::now();let token=room_token(&r.key,"r1","bob",5);
 let session=client().connect(url(&r,&token)).established().await.unwrap();
 let closed=tokio::time::timeout(Duration::from_secs(8),session.closed()).await.expect("WebTransport expiry deadline");
 println!("WebTransport token ttl=5s close_ms={} result={closed:?}",start.elapsed().as_millis());
 let(router,id)=iroh_relay(&r).await;let start=Instant::now();
 let(node,link)=iroh_node(id,&room_token(&r.key,"r1","alice",10)).await;let status=link.status();
 tokio::time::timeout(Duration::from_secs(13),async{while status.get()==iroh_live::RelayStatus::Connected{tokio::time::sleep(Duration::from_millis(20)).await}}).await.expect("Iroh expiry deadline");
 println!("Iroh token ttl=10s close_ms={} status={:?}",start.elapsed().as_millis(),status.get());
 link.detach().await;node.shutdown().await;router.shutdown().await.unwrap();r.trigger.start();
}

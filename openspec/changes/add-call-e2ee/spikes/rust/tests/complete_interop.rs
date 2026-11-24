#[path="../../complete/common.rs"] mod common;
use common::*;
fn hex(b:&[u8])->String{b.iter().map(|b|format!("{b:02x}")).collect()}
fn unhex(s:&str)->Vec<u8>{(0..s.len()).step_by(2).map(|i|u8::from_str_radix(&s[i..i+2],16).unwrap()).collect()}
#[tokio::test]
async fn interop(){
 let dir=std::env::var("E2EE_INTEROP").expect("private scratch output directory");
 // Review B1 layout: label in the context, opaque = path("call").
 let cred=label_credential([17;32],1,"alice");
 if std::env::var("E2EE_PHASE").as_deref()==Ok("emit"){
  let net=moq_net::broadcast::Producer::new(Default::default());let gen=cred.produce();
  let protected=moq_e2ee::broadcast::Producer::new(net.clone(),gen.clone());let mut track=protected.create_track("video",timed()).unwrap();
  let mut g=track.create_group(123).unwrap();g.write_frame(moq_net::Timestamp::from_millis(123).unwrap(),b"RUST-TO-JS real pinned public API").unwrap();g.finish().unwrap();
  let name=gen.name("video").unwrap();let mut sub=net.consume().track(name.as_str()).unwrap().subscribe(None).await.unwrap();let mut group=sub.recv_group().await.unwrap().unwrap();let f=group.read_frame().await.unwrap().unwrap();
  std::fs::write(format!("{dir}/rust.json"),serde_json::json!({"epoch":gen.epoch().to_string(),"name":name.as_str(),"path":cred.path("call").unwrap().as_str(),"semantic":"call","context":format!("mjolnir-call/v1/{}/r1/alice",owner()),"ciphertext":hex(&f.payload)}).to_string()).unwrap();println!("Rust emitted grouped frame at group=123 index=0");return
 }
 let data:serde_json::Value=serde_json::from_slice(&std::fs::read(format!("{dir}/js.json")).unwrap()).unwrap();
 let epoch:moq_e2ee::Epoch=data["epoch"].as_str().unwrap().parse().unwrap();let generation=cred.consume(epoch.clone());
 assert_eq!(generation.name("video").unwrap().as_str(),data["name"].as_str().unwrap());assert_eq!(cred.path("call").unwrap().as_str(),data["path"].as_str().unwrap());
 let ciphertext=unhex(data["ciphertext"].as_str().unwrap());
 for case in ["valid","payload","group","semantic","timestamp","wrong-key","other-label"]{
  let net=moq_net::broadcast::Producer::new(Default::default());
  let c=match case{"wrong-key"=>label_credential([18;32],1,"alice").consume(epoch.clone()),"other-label"=>label_credential([17;32],1,"bob").consume(epoch.clone()),_=>generation.clone()};
  let semantic=if case=="semantic"{"audio"}else{"video"};let name=c.name(semantic).unwrap();
  let track=net.create_track(name.as_str(),timed()).unwrap();let start=if case=="group"{125}else{124};
  let mut payload=ciphertext.clone();if case=="payload"{payload[0]^=1}
  let mut g=track.create_group(moq_net::group::Info{start}).unwrap();let ts=if case=="timestamp"{999}else{start};g.write_frame(moq_net::Timestamp::from_millis(ts).unwrap(),payload).unwrap();g.finish().unwrap();
  let sealed=moq_e2ee::broadcast::Consumer::new(net.consume(),c);let mut sub=sealed.subscribe(semantic,None).unwrap().await.unwrap();let mut group=sub.recv_group().await.unwrap().unwrap();let result=group.read_frame().await;
  if case=="valid"||case=="timestamp"{let f=result.unwrap().unwrap();assert_eq!(&f.plaintext[..],b"JS-TO-RUST real pinned key derivation");println!("interop {case}: decrypted timestamp={:?}",f.timestamp)}else{assert!(result.is_err(),"{case} accepted");println!("interop {case}: rejected {result:?}")}
 }
 println!("INTEROP both directions; timestamp modification accepted (not authenticated by profile)");
}

#[path = "../../complete/common.rs"] mod common;
#[tokio::test(flavor="multi_thread")]
#[ignore = "local browser/capture fixture only"]
async fn serve() {
    let r = common::start().await;
    let dir = std::env::var("E2EE_PRIVATE").unwrap();
    let lines = format!("{}\n{}\n{}\n{}\n{}\n", r.quic, common::owner(),
        common::room_token(&r.key,"r1","alice",3600),
        common::room_token(&r.key,"r1","bob",3600),
        common::room_token(&r.key,"r1","carol",3600));
    std::fs::write(format!("{dir}/admission.txt"), lines).unwrap();
    while !std::path::Path::new(&format!("{dir}/stop")).exists() {
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    r.trigger.start();
}

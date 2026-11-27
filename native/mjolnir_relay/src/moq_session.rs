//! One relay connection per exact token. TLS is verified. `insecure` is never set.
//! A disposable relay is trusted only by its own PEM root, with system roots off.

use std::path::PathBuf;
use std::time::Duration;

use moq_net::origin::Producer;
use url::Url;

#[derive(Clone)]
pub struct MoqConfig {
    pub relay: Url,
    pub tls_root: Option<PathBuf>,
    pub media: moq_webrtc::Server,
}

#[derive(Clone)]
pub struct Shared {
    pub publish: Producer,
    pub subscribe: Producer,
    conn: moq_tokio::Connection,
}

impl Shared {
    pub fn dead(&self) -> bool {
        !self.conn.connected()
    }

    pub async fn closed(&self) {
        let _ = self.conn.clone().closed().await;
    }
}

pub async fn dial(config: &MoqConfig, token: &str, budget: Duration) -> Result<Shared, String> {
    let _ = moq_tokio::crypto::install_default();
    let mut connect = moq_tokio::connect::Config::default();
    connect.bind = Some("127.0.0.1:0".parse().expect("bind"));
    connect.tls.insecure = Some(false);
    if let Some(root) = &config.tls_root {
        connect.tls.root = vec![root.clone()];
        connect.tls.system_roots = Some(false);
    }
    let client = connect.init(Default::default()).map_err(|err| err.to_string())?;
    let publish = moq_tokio::origin::spawn();
    let subscribe = moq_tokio::origin::spawn();
    let mut url = config.relay.clone();
    url.query_pairs_mut().append_pair("jwt", token);
    let dial = client
        .with_reconnect(false)
        .with_publisher(publish.consume())
        .with_subscriber(subscribe.clone())
        .connect(url)
        .established();
    let conn = tokio::time::timeout(budget, dial)
        .await
        .map_err(|_| "dial deadline".to_string())?
        .map_err(|err| err.to_string())?;
    Ok(Shared { publish, subscribe, conn })
}

pub async fn whip(config: &MoqConfig, shared: &Shared, broadcast: &str, offer: &str) -> Result<moq_webrtc::server::Response, String> {
    let path = moq_net::Path::new(broadcast).map_err(|err| err.to_string())?;
    let mut request = moq_webrtc::whip::Request::new(&shared.publish, path, offer);
    request.keyframes = moq_webrtc::Keyframes::trial();
    tokio::time::timeout(Duration::from_secs(5), moq_webrtc::whip::accept(&config.media, request))
        .await
        .map_err(|_| "whip deadline".to_string())?
        .map_err(|err| err.to_string())
}

pub async fn whep(config: &MoqConfig, shared: &Shared, broadcast: &str, offer: &str) -> Result<moq_webrtc::server::Response, String> {
    let path = moq_net::Path::new(broadcast).map_err(|err| err.to_string())?;
    let consumer = shared.subscribe.consume();
    let request = moq_webrtc::whep::Request::new(&consumer, path, offer);
    tokio::time::timeout(Duration::from_secs(5), moq_webrtc::whep::accept(&config.media, request))
        .await
        .map_err(|_| "whep deadline".to_string())?
        .map_err(|err| err.to_string())
}

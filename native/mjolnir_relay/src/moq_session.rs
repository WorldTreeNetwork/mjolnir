//! One relay connection per exact token. TLS is verified. `insecure` is never set.
//! A disposable relay is trusted only by its own PEM root, with system roots off.

use std::path::PathBuf;
use std::time::Duration;

use moq_net::origin::Producer;
use url::Url;

/// Adopted `.13` ingest cap: 2.5 Mbit/s, applied to the real WHIP ingest before accept.
pub const INGEST_CAP_BPS: u64 = 2_500_000;

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
    /// Keeps the relay session discovering announcements. Dropping it stops WHEP from seeing catalogs.
    _watch: std::sync::Arc<moq_net::announce::Consumer>,
}

impl Shared {
    pub fn dead(&self) -> bool {
        !self.conn.connected()
    }

    pub async fn closed(&self) {
        let _ = self.conn.clone().closed().await;
    }
}

/// Typed negotiation/transport failure. Expiry is applied by the caller, not here.
#[derive(Debug)]
pub enum SetupFault {
    /// The caller's setup deadline fired. Catalog phase maps this to `not_started` before expiry.
    Deadline { catalog: bool },
    /// The relay connection for this generation closed.
    RelayClosed,
    /// Absent broadcast, catalog timeout/closure, or no rendition.
    Catalog,
    Other(String),
}

impl std::fmt::Display for SetupFault {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Deadline { catalog } => write!(f, "deadline catalog={catalog}"),
            Self::RelayClosed => write!(f, "relay closed"),
            Self::Catalog => write!(f, "catalog"),
            Self::Other(text) => write!(f, "{text}"),
        }
    }
}

pub async fn dial(config: &MoqConfig, token: &str, budget: Duration) -> Result<Shared, SetupFault> {
    let _ = moq_tokio::crypto::install_default();
    let mut connect = moq_tokio::connect::Config::default();
    connect.bind = Some("127.0.0.1:0".parse().expect("bind"));
    connect.tls.insecure = Some(false);
    if let Some(root) = &config.tls_root {
        connect.tls.root = vec![root.clone()];
        connect.tls.system_roots = Some(false);
    }
    let client = connect.init(Default::default()).map_err(|err| SetupFault::Other(err.to_string()))?;
    let publish = moq_tokio::origin::spawn();
    let subscribe = moq_tokio::origin::spawn();
    let mut url = config.relay.clone();
    url.query_pairs_mut().append_pair("jwt", token);
    let dial = client
        .with_reconnect(false)
        .with_publisher(publish.clone())
        .with_subscriber(subscribe.clone())
        .connect(url)
        .established();
    let conn = tokio::time::timeout(budget, dial)
        .await
        .map_err(|_| SetupFault::Deadline { catalog: false })?
        .map_err(|err| SetupFault::Other(err.to_string()))?;
    let watch = std::sync::Arc::new(subscribe.consume().with_hidden(true).announced());
    Ok(Shared { publish, subscribe, conn, _watch: watch })
}

fn map_webrtc(err: moq_webrtc::Error, catalog_phase: bool) -> SetupFault {
    match err {
        moq_webrtc::Error::CatalogTimeout | moq_webrtc::Error::CatalogClosed | moq_webrtc::Error::NoRenditions => {
            SetupFault::Catalog
        }
        moq_webrtc::Error::Moq(moq_net::Error::NotFound | moq_net::Error::Unroutable) => SetupFault::Catalog,
        other => SetupFault::Other(other.to_string()),
    }
    .or_catalog_phase(catalog_phase)
}

impl SetupFault {
    fn or_catalog_phase(self, catalog_phase: bool) -> Self {
        match self {
            Self::Deadline { .. } if catalog_phase => Self::Deadline { catalog: true },
            other => other,
        }
    }
}

pub async fn whip(
    config: &MoqConfig,
    shared: &Shared,
    broadcast: &str,
    offer: &str,
) -> Result<moq_webrtc::server::Response, SetupFault> {
    let path = moq_net::Path::new(broadcast).map_err(|err| SetupFault::Other(err.to_string()))?;
    let mut request = moq_webrtc::whip::Request::new(&shared.publish, path, offer);
    request.keyframes = moq_webrtc::Keyframes::trial();
    let cap = moq_net::bandwidth::Cap::new(moq_net::bandwidth::Rate::from_bps(INGEST_CAP_BPS));
    request.ingest.rate = Some(moq_net::bandwidth::Limit::new(cap));
    moq_webrtc::whip::accept(&config.media, request)
        .await
        .map_err(|err| map_webrtc(err, false))
}

pub async fn whep(
    config: &MoqConfig,
    shared: &Shared,
    broadcast: &str,
    offer: &str,
) -> Result<moq_webrtc::server::Response, SetupFault> {
    let path = moq_net::Path::new(broadcast).map_err(|err| SetupFault::Other(err.to_string()))?;
    let consumer = shared.subscribe.consume();
    let request = moq_webrtc::whep::Request::new(&consumer, path, offer);
    moq_webrtc::whep::accept(&config.media, request)
        .await
        .map_err(|err| map_webrtc(err, true))
}

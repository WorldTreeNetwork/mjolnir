// Adapted from iroh-live-relay/src/iroh_sessions.rs at revision 747b1bd.
// Copyright the iroh-live authors. SPDX-License-Identifier: MIT OR Apache-2.0.
//
// Pull paths are omitted. Mjolnir does not pull broadcasts (design D7).
// This handler accepts an Iroh session, admits it through the relay policy,
// and serves the cluster.

use std::{sync::Arc, time::Duration};

use iroh::{
    endpoint::Connection,
    protocol::{AcceptError, ProtocolHandler, RouterBuilder},
};
use moq_ext_access::policy::{Authorization, DynPolicy, Event, PeerRequest, Policy};
use moq_ext_access::SessionRequest;
use moq_relay::cluster::Cluster;
use tokio_util::sync::CancellationToken;
use tracing::{Instrument, debug, info, info_span, warn};

/// How long a policy may take to admit one session.
const DECIDE_TIMEOUT: Duration = Duration::from_secs(10);

/// How long a closing session gets to tell its peer when the relay shuts down.
const CLOSE_GRACE: Duration = Duration::from_secs(1);

/// Accepts Iroh clients' MoQ sessions into the cluster.
pub struct IrohSessions {
    cluster: Cluster,
    policy: Arc<dyn DynPolicy<iroh::EndpointId>>,
    shutdown: CancellationToken,
}

impl Clone for IrohSessions {
    fn clone(&self) -> Self {
        Self {
            cluster: self.cluster.clone(),
            policy: Arc::clone(&self.policy),
            shutdown: self.shutdown.clone(),
        }
    }
}

impl std::fmt::Debug for IrohSessions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IrohSessions").finish_non_exhaustive()
    }
}

impl IrohSessions {
    /// Creates the handler. The caller sets the policy with [`with_policy`](Self::with_policy).
    #[must_use]
    pub fn new(cluster: Cluster) -> Self {
        Self {
            cluster,
            // Replaced before mount. A session that arrives first is refused.
            policy: Arc::new(Closed),
            shutdown: CancellationToken::new(),
        }
    }

    /// Returns this handler with `policy` deciding sessions.
    ///
    /// A rejection closes the session. An authorization's grant bounds what
    /// the client publishes into the cluster and what it reads from it, and
    /// the session closes when the authorization expires.
    #[must_use]
    pub fn with_policy(mut self, policy: impl Policy<iroh::EndpointId>) -> Self {
        self.policy = Arc::new(policy);
        self
    }

    /// Mounts this handler on `router` under every MoQ ALPN.
    #[must_use]
    pub fn mount(self, mut router: RouterBuilder) -> RouterBuilder {
        for alpn in moq_transport_iroh::alpns() {
            router = router.accept(alpn, self.clone());
        }
        router
    }

    async fn serve(&self, connection: Connection) -> Result<(), AcceptError> {
        let Admitted {
            session,
            driver,
            authorization,
        } = self.admit(connection).await?;
        self.run(session, driver, &authorization).await;
        Ok(())
    }

    async fn admit(&self, connection: Connection) -> Result<Admitted, AcceptError> {
        let peer = connection.remote_id();
        let transport =
            moq_transport_iroh::Transport::new(connection).map_err(AcceptError::from_err)?;
        let handshake = tokio::time::timeout(
            moq_transport_iroh::HANDSHAKE_TIMEOUT,
            moq_net::Server::new().handshake(moq_net::time::Instant::now(), transport),
        )
        .await
        .map_err(|_| AcceptError::from_err(moq_net::Error::Timeout))?
        .map_err(AcceptError::from_err)?;
        let session = SessionRequest::from_handshake(&handshake);
        let path = session.path().to_owned();
        let request = PeerRequest::new(peer, session, Event::Connect);
        let authorization =
            match moq_ext_access::policy::decide_within(&*self.policy, &request, DECIDE_TIMEOUT)
                .await
            {
                Ok(authorization) => authorization,
                Err(rejection) => {
                    info!(
                        reason = rejection.reason(),
                        code = %rejection.code(),
                        "the policy rejected the iroh client",
                    );
                    handshake.close(rejection.code().clone());
                    return Err(AcceptError::from_err(rejection));
                }
            };
        let grant = &authorization.grant;
        let publish = self
            .cluster
            .origin
            .scope("", &grant.publish)
            .map_err(AcceptError::from_err)?;
        let serving = self
            .cluster
            .origin
            .consume()
            .scope("", &grant.subscribe)
            .map_err(AcceptError::from_err)?;
        let (session, driver) = tokio::time::timeout(
            moq_transport_iroh::HANDSHAKE_TIMEOUT,
            handshake
                .with_publisher(serving)
                .with_subscriber(publish)
                .ok(),
        )
        .await
        .map_err(|_| AcceptError::from_err(moq_net::Error::Timeout))?
        .map_err(AcceptError::from_err)?;
        info!(%path, grant = ?authorization.grant, expires = ?authorization.expires, "iroh client admitted");
        Ok(Admitted {
            session,
            driver,
            authorization,
        })
    }

    async fn run(
        &self,
        session: moq_net::Session,
        driver: moq_net::Driver,
        authorization: &Authorization,
    ) {
        let run = moq_net::time::run(driver);
        tokio::pin!(run);
        let expiry = expiry(authorization);
        tokio::pin!(expiry);
        let close = tokio::select! {
            err = &mut run => {
                debug!(error = %err, "iroh session ended");
                return;
            }
            () = self.shutdown.cancelled() => moq_net::Error::Cancel,
            () = &mut expiry => {
                info!("the iroh client's authorization expired, closing its session");
                moq_net::Error::Expired
            }
        };
        session.abort(close);
        if tokio::time::timeout(CLOSE_GRACE, run).await.is_err() {
            warn!(grace = ?CLOSE_GRACE, "iroh session did not close in time");
        }
    }
}

struct Admitted {
    session: moq_net::Session,
    driver: moq_net::Driver,
    authorization: Authorization,
}

async fn expiry(authorization: &Authorization) {
    match authorization.expires {
        Some(expires) => {
            let left = expires
                .duration_since(std::time::SystemTime::now())
                .unwrap_or_default();
            tokio::time::sleep(left).await;
        }
        None => std::future::pending().await,
    }
}

/// Refuses every session. Replaced by [`IrohSessions::with_policy`].
#[derive(Debug)]
struct Closed;

impl Policy<iroh::EndpointId> for Closed {
    fn decide(
        &self,
        _request: &PeerRequest<iroh::EndpointId>,
    ) -> impl std::future::Future<Output = moq_ext_access::policy::Decision> + Send {
        async { Err(moq_ext_access::policy::Rejection::new("no policy")) }
    }
}

impl ProtocolHandler for IrohSessions {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        let span = info_span!("iroh_client", peer = %connection.remote_id().fmt_short());
        self.serve(connection).instrument(span).await
    }

    async fn shutdown(&self) {
        self.shutdown.cancel();
    }
}

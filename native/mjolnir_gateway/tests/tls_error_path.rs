//! Integration test: TLS round-trip for the error-response path.
//!
//! Proves that writing an HTTP error response through a `TlsStream<TcpStream>`
//! WriteHalf (i.e. via `tokio::io::split`) works end-to-end — the same code
//! path used by `run_proxy` → `write_error_and_shutdown` for TLS connections.
//!
//! Task 1c.iii acceptance: client reads bytes starting with
//! "HTTP/1.1 504 Gateway Timeout" from a TLS connection.

use rustls::pki_types::ServerName;
use rustls::sign::CertifiedKey;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::{TlsAcceptor, TlsConnector};

// ── helpers ───────────────────────────────────────────────────────────────────

/// Generate a self-signed cert/key pair (DER bytes).
fn generate_self_signed() -> (Vec<u8>, Vec<u8>) {
    use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair};

    let mut params = CertificateParams::default();
    let mut dn = DistinguishedName::new();
    dn.push(DnType::CommonName, "test-gateway");
    params.distinguished_name = dn;
    params.not_before = rcgen::date_time_ymd(2024, 1, 1);
    params.not_after = rcgen::date_time_ymd(2099, 1, 1);

    let kp = KeyPair::generate().expect("keygen");
    let cert = params.self_signed(&kp).expect("self-sign");
    (cert.der().to_vec(), kp.serialize_der())
}

/// A trivial `ResolvesServerCert` that always returns the same `CertifiedKey`.
#[derive(Debug)]
struct SingleCertResolver(Arc<CertifiedKey>);

impl rustls::server::ResolvesServerCert for SingleCertResolver {
    fn resolve(&self, _: rustls::server::ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        Some(Arc::clone(&self.0))
    }
}

/// Build a `ClientConfig` that accepts any server certificate (test-only).
fn danger_accept_any_client_config() -> rustls::ClientConfig {
    use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
    use rustls::pki_types::{CertificateDer, UnixTime};
    use rustls::{DigitallySignedStruct, Error, SignatureScheme};

    #[derive(Debug)]
    struct AcceptAnyCert;

    impl ServerCertVerifier for AcceptAnyCert {
        fn verify_server_cert(
            &self,
            _end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp: &[u8],
            _now: UnixTime,
        ) -> Result<ServerCertVerified, Error> {
            Ok(ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            vec![
                SignatureScheme::RSA_PSS_SHA256,
                SignatureScheme::RSA_PSS_SHA384,
                SignatureScheme::RSA_PSS_SHA512,
                SignatureScheme::ECDSA_NISTP256_SHA256,
                SignatureScheme::ECDSA_NISTP384_SHA384,
                SignatureScheme::ED25519,
            ]
        }
    }

    rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyCert))
        .with_no_client_auth()
}

// ── Test ──────────────────────────────────────────────────────────────────────

/// The exact bytes that `error_to_http_response(&ProxyError::ResponseTimeout)` produces.
const RESPONSE_504: &[u8] = b"HTTP/1.1 504 Gateway Timeout\r\nContent-Type: text/plain\r\nContent-Length: 22\r\nConnection: close\r\n\r\nVM did not respond in time";

/// Spin up a TLS server on an ephemeral port.  The server:
///   1. Accepts one TCP connection and performs a TLS handshake.
///   2. Splits the TLS stream with `tokio::io::split` (same as `run_proxy`).
///   3. Writes a 504 response through the `WriteHalf` and shuts it down.
///
/// The client connects via TLS (accepting any cert) and asserts the response
/// starts with "HTTP/1.1 504 Gateway Timeout".
#[tokio::test]
async fn tls_write_half_delivers_504_error_response() {
    // Install the ring crypto provider (idempotent).
    let _ = rustls::crypto::ring::default_provider().install_default();

    // Generate cert + key in DER format.
    let (cert_der, key_der) = generate_self_signed();

    // Build a CertifiedKey from DER bytes.
    let cert_chain = vec![rustls::pki_types::CertificateDer::from(cert_der)];
    let private_key = rustls::pki_types::PrivateKeyDer::Pkcs8(key_der.into());
    let signing_key =
        rustls::crypto::ring::sign::any_supported_type(&private_key).expect("signing key");
    let certified_key = Arc::new(CertifiedKey::new(cert_chain, signing_key));

    // Build ServerConfig via a single-cert resolver.
    let server_config = Arc::new(
        rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_cert_resolver(Arc::new(SingleCertResolver(Arc::clone(&certified_key)))),
    );

    let acceptor = TlsAcceptor::from(Arc::clone(&server_config));

    // Bind an ephemeral port.
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("local addr");

    // Server task: accept, handshake, split, write 504, shutdown.
    tokio::spawn(async move {
        let (tcp_stream, _peer) = listener.accept().await.expect("accept");
        let tls_stream = acceptor.accept(tcp_stream).await.expect("tls handshake");

        // Split with tokio::io::split — this is the same API used by run_proxy.
        let (_read_half, mut write_half) = tokio::io::split(tls_stream);

        let _ = write_half.write_all(RESPONSE_504).await;
        let _ = write_half.shutdown().await;
    });

    // Give the listener task a moment to reach accept().
    tokio::time::sleep(Duration::from_millis(10)).await;

    // Client: connect and read everything.
    let client_config = Arc::new(danger_accept_any_client_config());
    let connector = TlsConnector::from(client_config);

    let tcp = TcpStream::connect(addr).await.expect("tcp connect");
    let server_name = ServerName::try_from("test-gateway").expect("server name");
    let mut tls_client = connector
        .connect(server_name, tcp)
        .await
        .expect("tls connect");

    let mut received = Vec::new();
    tls_client
        .read_to_end(&mut received)
        .await
        .expect("read_to_end");

    let response_str = String::from_utf8(received).expect("utf-8 response");

    assert!(
        response_str.starts_with("HTTP/1.1 504 Gateway Timeout"),
        "expected 504 status line, got: {:?}",
        &response_str[..response_str.len().min(80)]
    );
    assert!(
        response_str.contains("VM did not respond in time"),
        "expected error body in TLS response"
    );
}

//! OAuth 2.0 Device Authorization Grant flow + token storage.

use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::Rng;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const DEFAULT_ISSUER: &str = "https://auth.identikey.me";
const CLIENT_ID: &str = "mjolnir-cli";
const SCOPES: &str = "openid";

// --- OIDC Discovery ---

#[derive(Deserialize)]
struct OidcConfig {
    authorization_endpoint: Option<String>,
    token_endpoint: String,
    device_authorization_endpoint: Option<String>,
}

async fn discover(issuer: &str) -> Result<OidcConfig> {
    let url = format!(
        "{}/.well-known/openid-configuration",
        issuer.trim_end_matches('/')
    );
    let config: OidcConfig = http_client()?
        .get(&url)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    Ok(config)
}

fn http_client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()?)
}

// --- Device Flow ---

#[derive(Deserialize)]
struct DeviceAuthResponse {
    device_code: String,
    user_code: String,
    verification_uri: String,
    verification_uri_complete: Option<String>,
    expires_in: u64,
    interval: Option<u64>,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    /// IdentiKey access tokens are opaque. The API verifies this JWT.
    id_token: Option<String>,
    refresh_token: Option<String>,
    expires_in: Option<u64>,
    #[allow(dead_code)]
    token_type: Option<String>,
}

impl TokenResponse {
    /// What `mj` sends as `Authorization: Bearer`. Keycloak's access token is
    /// already a JWT. IdentiKey's is not; the ID token is.
    fn bearer(&self) -> String {
        self.id_token
            .clone()
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| self.access_token.clone())
    }

    fn into_stored(self, issuer: String, previous_refresh: Option<String>) -> StoredToken {
        let bearer = self.bearer();
        let expires_at = earliest_expiry(
            self.expires_in.map(|e| now_secs().saturating_add(e)),
            jwt_expiry(&bearer),
        );
        StoredToken {
            access_token: bearer,
            refresh_token: self
                .refresh_token
                .filter(|t| !t.is_empty())
                .or(previous_refresh),
            expires_at,
            issuer,
        }
    }
}

#[derive(Deserialize)]
struct TokenErrorResponse {
    error: String,
    #[allow(dead_code)]
    error_description: Option<String>,
}

// --- Stored token ---

#[derive(Serialize, Deserialize)]
pub struct StoredToken {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_at: Option<u64>,
    pub issuer: String,
}

fn token_path() -> PathBuf {
    let config_dir = dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("mjolnir");
    config_dir.join("token.json")
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

impl StoredToken {
    /// Treat the token as stale 60s before `expires_at` so a reconnect after
    /// laptop sleep does not send a JWT that dies during the handshake.
    /// Keycloak access tokens for this client are 5 minutes.
    const EXPIRY_SKEW_SECS: u64 = 60;

    pub fn is_expired(&self) -> bool {
        match earliest_expiry(self.expires_at, jwt_expiry(&self.access_token)) {
            Some(exp) => now_secs().saturating_add(Self::EXPIRY_SKEW_SECS) >= exp,
            None => false,
        }
    }

    async fn save(&self) -> Result<()> {
        let path = token_path();
        let _lock = lock_token(&path).await?;
        self.save_to(&path)
    }

    /// Replace atomically: readers never observe partial JSON and the file is
    /// private from creation, including after a refresh-token rotation.
    fn save_to(&self, path: &Path) -> Result<()> {
        let temp = path.with_extension(format!("{}.tmp", rand::random::<u64>()));
        let result = (|| -> Result<()> {
            let mut opts = private_options();
            let mut file = opts.create_new(true).open(&temp)?;
            file.write_all(serde_json::to_string_pretty(self)?.as_bytes())?;
            file.sync_all()?;
            std::fs::rename(&temp, path)?;
            #[cfg(unix)]
            if let Some(parent) = path.parent() {
                File::open(parent)?.sync_all()?;
            }
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(temp);
        }
        result.context("could not save login credentials")
    }
}

fn earliest_expiry(a: Option<u64>, b: Option<u64>) -> Option<u64> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        _ => a.or(b),
    }
}

/// This unverified claim is only a refresh hint; the API verifies the JWT.
fn jwt_expiry(token: &str) -> Option<u64> {
    let payload = URL_SAFE_NO_PAD.decode(token.split('.').nth(1)?).ok()?;
    let claims: serde_json::Value = serde_json::from_slice(&payload).ok()?;
    let exp = claims.get("exp")?.as_f64()?;
    (exp.is_finite() && exp >= 0.0).then_some(exp as u64)
}

fn private_options() -> OpenOptions {
    let mut opts = OpenOptions::new();
    opts.read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    opts
}

fn lock_token_sync(path: &Path) -> Result<File> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // Lock a stable inode: token.json itself is replaced on every rotation.
    let file = private_options()
        .create(true)
        .truncate(false)
        .open(path.with_extension("lock"))?;
    file.lock()?;
    Ok(file)
}

async fn lock_token(path: &Path) -> Result<File> {
    let path = path.to_owned();
    tokio::task::spawn_blocking(move || lock_token_sync(&path)).await?
}

/// Serialize read/refresh/write across CLI processes and GUI consumers. A
/// waiting command re-reads the winning command's rotated credential.
async fn load_token_at(path: &Path, force: bool) -> Result<Option<String>> {
    let _lock = lock_token(path).await?;
    let data = match std::fs::read_to_string(path) {
        Ok(data) => data,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err.into()),
    };
    let stored: StoredToken = serde_json::from_str(&data)?;
    if !force && !stored.is_expired() {
        return Ok(Some(stored.access_token));
    }
    let refresh = stored
        .refresh_token
        .as_deref()
        .filter(|t| !t.is_empty())
        .context("Session expired without a refresh credential. Run `mj login`.")?;
    let response = refresh_token(&stored.issuer, refresh).await?;
    let refreshed = response.into_stored(stored.issuer, stored.refresh_token);
    refreshed.save_to(path)?;
    Ok(Some(refreshed.access_token))
}

async fn load_saved_token(force: bool) -> Option<String> {
    match load_token_at(&token_path(), force).await {
        Ok(token) => token,
        Err(err) => {
            eprintln!("Could not renew saved login: {err:#}");
            None
        }
    }
}

/// Load the saved session, renewing its short-lived API token when needed.
pub async fn load_token() -> Option<String> {
    load_saved_token(false).await
}

async fn refresh_token(issuer: &str, refresh: &str) -> Result<TokenResponse> {
    let config = discover(issuer).await?;
    let client = http_client()?;
    let resp = client
        .post(&config.token_endpoint)
        .form(&[
            ("grant_type", "refresh_token"),
            ("client_id", CLIENT_ID),
            ("refresh_token", refresh),
        ])
        .send()
        .await
        .context("login service unavailable; saved credentials kept, retry the command")?;
    if !resp.status().is_success() {
        let status = resp.status();
        let error = resp.json::<TokenErrorResponse>().await.ok();
        if error.as_ref().is_some_and(|e| e.error == "invalid_grant") {
            bail!("Login service no longer recognizes this session. Run `mj login`.");
        }
        bail!("Login service returned {status}; saved credentials kept, retry the command.");
    }
    Ok(resp.json::<TokenResponse>().await?)
}

/// Resolve the effective token: explicit flag > env > stored file.
pub async fn resolve_token(explicit: &Option<String>) -> Option<String> {
    if explicit.is_some() {
        return explicit.clone();
    }
    load_token().await
}

/// Force a refresh of the on-disk token, ignoring local expiry.
///
/// Used when a WebSocket handshake comes back 401 — the access token captured
/// at `mj connect` start is 5 minutes, so a laptop sleep always outlives it
/// even if `expires_at` was not re-read.
pub async fn refresh_stored_token() -> Option<String> {
    load_saved_token(true).await
}

// --- Login command ---

pub async fn login(issuer: Option<String>) -> Result<()> {
    let issuer = issuer.as_deref().unwrap_or(DEFAULT_ISSUER);

    // An explicit issuer switch must not silently reuse another issuer's session.
    if let Ok(data) = std::fs::read_to_string(token_path()) {
        if let Ok(stored) = serde_json::from_str::<StoredToken>(&data) {
            if stored.issuer == issuer && load_saved_token(false).await.is_some() {
                eprintln!("Logged in. Saved session is active.");
                return Ok(());
            }
        }
    }

    let config = discover(issuer).await?;
    let client = http_client()?;

    // Default issuer auth.identikey.me has no device-code grant. Passkey
    // is a browser loopback (RFC 8252). A deprecated Keycloak issuer still
    // advertises a device endpoint; that path is only for an explicit --issuer.
    if config.device_authorization_endpoint.is_none() {
        return loopback_login(&client, issuer, &config).await;
    }

    let device_endpoint = config
        .device_authorization_endpoint
        .clone()
        .expect("checked above");

    // Generate PKCE code verifier + challenge (S256)
    let code_verifier = generate_code_verifier();
    let code_challenge = generate_code_challenge(&code_verifier);

    // Step 1: Request device code
    let resp = client
        .post(&device_endpoint)
        .form(&[
            ("client_id", CLIENT_ID),
            ("scope", SCOPES),
            ("code_challenge", code_challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await?;

    let status = resp.status();
    let body = resp.text().await?;
    if !status.is_success() {
        bail!("Device auth failed: {}", body);
    }

    let device_resp: DeviceAuthResponse = serde_json::from_str(&body)?;

    // Step 2: Show user code
    eprintln!();
    eprintln!("Open this URL in your browser:");
    eprintln!();
    eprintln!(
        "  {}",
        device_resp
            .verification_uri_complete
            .as_deref()
            .unwrap_or(&device_resp.verification_uri)
    );
    eprintln!();
    eprintln!("  Code: {}", device_resp.user_code);
    eprintln!();

    // Try to open browser automatically
    if let Some(ref uri) = device_resp.verification_uri_complete {
        let _ = open::that(uri);
    } else {
        let _ = open::that(&device_resp.verification_uri);
    }

    eprintln!("Waiting for authorization...");

    // Step 3: Poll for token
    let interval = std::time::Duration::from_secs(device_resp.interval.unwrap_or(5));
    let deadline = now_secs() + device_resp.expires_in;

    loop {
        tokio::time::sleep(interval).await;

        if now_secs() >= deadline {
            bail!("Device code expired. Run `mjolnir login` again.");
        }

        let mut params = HashMap::new();
        params.insert("grant_type", "urn:ietf:params:oauth:grant-type:device_code");
        params.insert("client_id", CLIENT_ID);
        params.insert("device_code", &device_resp.device_code);
        params.insert("code_verifier", &code_verifier);

        let resp = client
            .post(&config.token_endpoint)
            .form(&params)
            .send()
            .await?;

        if resp.status().is_success() {
            let token_resp: TokenResponse = resp.json().await?;
            let stored = token_resp.into_stored(issuer.to_string(), None);
            stored.save().await?;
            eprintln!("Logged in. Token saved to {}", token_path().display());
            return Ok(());
        }

        // Parse error response
        let body = resp.text().await?;
        let err: TokenErrorResponse = serde_json::from_str(&body).unwrap_or(TokenErrorResponse {
            error: "unknown".into(),
            error_description: Some(body),
        });

        match err.error.as_str() {
            "authorization_pending" => continue,
            "slow_down" => {
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                continue;
            }
            "access_denied" => bail!("Authorization denied."),
            "expired_token" => bail!("Device code expired. Run `mjolnir login` again."),
            other => bail!("Auth error: {}", other),
        }
    }
}

async fn loopback_login(client: &reqwest::Client, issuer: &str, config: &OidcConfig) -> Result<()> {
    let authz = config
        .authorization_endpoint
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("issuer has no authorization_endpoint"))?;
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    let redirect = format!("http://127.0.0.1:{port}/callback");
    let verifier = generate_code_verifier();
    let challenge = generate_code_challenge(&verifier);
    let state = generate_code_verifier();
    let url = format!(
        "{authz}?response_type=code&client_id={CLIENT_ID}&scope={}&redirect_uri={}&state={}&code_challenge={}&code_challenge_method=S256",
        encode_query(SCOPES),
        encode_query(&redirect),
        encode_query(&state),
        encode_query(&challenge),
    );
    eprintln!();
    eprintln!("Open this URL and approve with your passkey:");
    eprintln!();
    eprintln!("  {url}");
    eprintln!();
    let _ = open::that(&url);
    eprintln!("Waiting for the browser to come back...");
    let expect = state.clone();
    let code = tokio::task::spawn_blocking(move || accept_loopback(listener, &expect))
        .await
        .map_err(|e| anyhow::anyhow!("login listener failed: {e}"))??;
    let resp = client
        .post(&config.token_endpoint)
        .form(&[
            ("grant_type", "authorization_code"),
            ("client_id", CLIENT_ID),
            ("code", code.as_str()),
            ("redirect_uri", redirect.as_str()),
            ("code_verifier", verifier.as_str()),
        ])
        .send()
        .await?;
    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await?;
        bail!("Token exchange failed ({status}): {body}");
    }
    let token_resp: TokenResponse = resp.json().await?;
    let stored = token_resp.into_stored(issuer.to_string(), None);
    stored.save().await?;
    eprintln!("Logged in. Token saved to {}", token_path().display());
    Ok(())
}

fn accept_loopback(listener: std::net::TcpListener, expect_state: &str) -> Result<String> {
    use std::io::{Read, Write};
    let (mut stream, _) = listener.accept()?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(10)))?;
    let mut buf = [0u8; 8192];
    let n = stream.read(&mut buf).unwrap_or(0);
    let req = String::from_utf8_lossy(&buf[..n]);
    let first = req.lines().next().unwrap_or("");
    let query = first
        .split_whitespace()
        .nth(1)
        .unwrap_or("")
        .split_once('?')
        .map(|(_, q)| q)
        .unwrap_or("");
    let mut code = None;
    let mut state = None;
    for pair in query.split('&') {
        let Some((k, v)) = pair.split_once('=') else {
            continue;
        };
        let v = percent_decode(v);
        match k {
            "code" => code = Some(v),
            "state" => state = Some(v),
            "error" => bail!("Authorization failed: {v}"),
            _ => {}
        }
    }
    if state.as_deref() != Some(expect_state) {
        bail!("Login state did not match. Run `mj login` again.");
    }
    let body = "Logged in. You can close this tab.\n";
    let resp = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(resp.as_bytes());
    code.ok_or_else(|| anyhow::anyhow!("callback had no code"))
}

fn encode_query(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(v) =
                u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or(""), 16)
            {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(if bytes[i] == b'+' { b' ' } else { bytes[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Remove stored token.
pub fn logout() -> Result<()> {
    let path = token_path();
    let _lock = lock_token_sync(&path)?;
    if path.exists() {
        std::fs::remove_file(&path)?;
        eprintln!("Logged out. Token removed.");
    } else {
        eprintln!("Not logged in.");
    }
    Ok(())
}

/// Show current auth status.
pub fn status() -> Result<()> {
    let path = token_path();
    if !path.exists() {
        println!("Not logged in.");
        return Ok(());
    }

    let data = std::fs::read_to_string(&path)?;
    let stored: StoredToken = serde_json::from_str(&data)?;

    println!("Issuer:  {}", stored.issuer);
    if stored.is_expired() && stored.refresh_token.is_some() {
        println!("Status:  saved session (API token expired; renewal on next command)");
    } else if stored.is_expired() {
        println!("Status:  expired");
    } else {
        println!("Status:  active");
    }
    println!("Token:   {}", token_path().display());
    Ok(())
}

// --- PKCE helpers ---

/// Base64url-encode without padding (RFC 7636 Appendix B).
fn base64url_encode_raw(input: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity((input.len() + 2) / 3 * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[((n >> 18) & 0x3F) as usize] as char);
        out.push(ALPHABET[((n >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(ALPHABET[((n >> 6) & 0x3F) as usize] as char);
        }
        if chunk.len() > 2 {
            out.push(ALPHABET[(n & 0x3F) as usize] as char);
        }
    }
    out
}

/// Generate a random PKCE code verifier (43-128 chars, URL-safe).
fn generate_code_verifier() -> String {
    let mut rng = rand::thread_rng();
    let bytes: Vec<u8> = (0..32).map(|_| rng.gen()).collect();
    base64url_encode_raw(&bytes)
}

/// S256: SHA-256 hash of verifier, base64url-encoded without padding.
fn generate_code_challenge(verifier: &str) -> String {
    let hash = Sha256::digest(verifier.as_bytes());
    base64url_encode_raw(&hash)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(expires_at: Option<u64>) -> StoredToken {
        StoredToken {
            access_token: "x".into(),
            refresh_token: None,
            expires_at,
            issuer: "https://example".into(),
        }
    }

    fn scratch() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("mj-login-{}", rand::random::<u64>()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("token.json")
    }

    fn jwt(exp: f64) -> String {
        format!(
            "e30.{}.signature",
            URL_SAFE_NO_PAD.encode(format!("{{\"exp\":{exp}}}"))
        )
    }

    #[test]
    fn bearer_expiry_overrides_longer_access_token_lifetime_and_legacy_cache() {
        let exp = now_secs() - 100;
        let response: TokenResponse = serde_json::from_value(serde_json::json!({
            "access_token": "opaque", "id_token": jwt(exp as f64 + 0.9),
            "expires_in": 3600, "refresh_token": "refresh"
        }))
        .unwrap();
        let mut stored = response.into_stored("https://example".into(), None);
        assert_eq!(stored.expires_at, Some(exp));
        assert!(stored.is_expired());
        stored.expires_at = Some(now_secs() + 3600);
        assert!(stored.is_expired());
        stored.expires_at = None;
        assert!(stored.is_expired());
    }

    #[test]
    fn omitted_refresh_token_preserves_saved_credential() {
        let response: TokenResponse = serde_json::from_value(serde_json::json!({
            "access_token": "jwt", "expires_in": 3600
        }))
        .unwrap();
        assert_eq!(
            response
                .into_stored("issuer".into(), Some("refresh".into()))
                .refresh_token
                .as_deref(),
            Some("refresh")
        );
    }

    /// Minimal local OP with one-use refresh tokens. No real credentials or
    /// global config overrides are involved in the regression tests.
    fn mock_issuer(status: &str, body: String) -> (String, std::thread::JoinHandle<()>) {
        use std::io::Read;
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let issuer = format!("http://{}", listener.local_addr().unwrap());
        let discovery =
            serde_json::json!({"token_endpoint": format!("{issuer}/token")}).to_string();
        let status = status.to_owned();
        let thread = std::thread::spawn(move || {
            for (status, body) in [("200 OK".to_string(), discovery), (status, body)] {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                    .unwrap();
                let mut request = Vec::new();
                let mut buf = [0; 4096];
                loop {
                    let n = stream.read(&mut buf).unwrap();
                    assert!(n > 0);
                    request.extend_from_slice(&buf[..n]);
                    let text = String::from_utf8_lossy(&request);
                    if let Some((headers, payload)) = text.split_once("\r\n\r\n") {
                        let len: usize = headers
                            .lines()
                            .find_map(|line| {
                                let (key, value) = line.split_once(':')?;
                                key.eq_ignore_ascii_case("content-length")
                                    .then(|| value.trim().parse().unwrap())
                            })
                            .unwrap_or(0);
                        if payload.len() >= len {
                            break;
                        }
                    }
                }
                let request = String::from_utf8(request).unwrap();
                if request.starts_with("POST") {
                    assert!(request.contains("grant_type=refresh_token"));
                    assert!(request.contains("client_id=mjolnir-cli"));
                    assert!(request.contains("refresh_token=original-refresh"));
                }
                write!(stream, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            }
        });
        (issuer, thread)
    }

    #[tokio::test]
    async fn concurrent_commands_refresh_once_and_persist_rotation() {
        let bearer = jwt((now_secs() + 3600) as f64);
        let (issuer, server) = mock_issuer(
            "200 OK",
            serde_json::json!({
                "access_token": "opaque", "id_token": bearer,
                "refresh_token": "rotated-refresh", "expires_in": 3600
            })
            .to_string(),
        );
        let path = scratch();
        let mut stored = token(Some(0));
        stored.issuer = issuer;
        stored.refresh_token = Some("original-refresh".into());
        stored.save_to(&path).unwrap();
        let (a, b) = tokio::join!(load_token_at(&path, false), load_token_at(&path, false));
        assert_eq!(a.unwrap(), Some(bearer.clone()));
        assert_eq!(b.unwrap(), Some(bearer));
        server.join().unwrap();
        let saved: StoredToken =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(saved.refresh_token.as_deref(), Some("rotated-refresh"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[tokio::test]
    async fn refresh_failure_keeps_saved_session_and_explains_recovery() {
        for (status, error, expected) in [
            (
                "503 Service Unavailable",
                "server_error",
                "retry the command",
            ),
            ("400 Bad Request", "invalid_grant", "Run `mj login`"),
        ] {
            let (issuer, server) =
                mock_issuer(status, serde_json::json!({"error":error}).to_string());
            let path = scratch();
            let mut stored = token(Some(0));
            stored.issuer = issuer;
            stored.refresh_token = Some("original-refresh".into());
            stored.save_to(&path).unwrap();
            let before = std::fs::read(&path).unwrap();
            let error = load_token_at(&path, false).await.unwrap_err();
            assert!(error.to_string().contains(expected), "{error}");
            assert_eq!(std::fs::read(&path).unwrap(), before);
            server.join().unwrap();
            std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
        }
    }

    #[test]
    fn unexpired_token_with_room_to_spare_is_fresh() {
        assert!(!token(Some(now_secs() + 120)).is_expired());
    }

    #[test]
    fn token_inside_skew_window_is_treated_expired() {
        assert!(token(Some(now_secs() + 30)).is_expired());
    }

    #[test]
    fn past_expiry_is_expired() {
        assert!(token(Some(now_secs().saturating_sub(1))).is_expired());
    }

    #[test]
    fn missing_expires_at_is_not_expired() {
        assert!(!token(None).is_expired());
    }
}

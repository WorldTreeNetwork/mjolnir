//! OAuth 2.0 Device Authorization Grant flow + token storage.

use rand::Rng;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

const DEFAULT_ISSUER: &str = "https://connect.identikey.io/realms/identikey";
const CLIENT_ID: &str = "mjolnir-cli";
const SCOPES: &str = "openid offline_access";

// --- OIDC Discovery ---

#[derive(Deserialize)]
struct OidcConfig {
    token_endpoint: String,
    device_authorization_endpoint: String,
}

async fn discover(issuer: &str) -> Result<OidcConfig, Box<dyn std::error::Error>> {
    let url = format!("{}/.well-known/openid-configuration", issuer.trim_end_matches('/'));
    let config: OidcConfig = reqwest::get(&url).await?.json().await?;
    Ok(config)
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
    refresh_token: Option<String>,
    expires_in: Option<u64>,
    #[allow(dead_code)]
    token_type: Option<String>,
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
    pub fn is_expired(&self) -> bool {
        match self.expires_at {
            Some(exp) => now_secs() >= exp,
            None => false,
        }
    }

    fn save(&self) -> Result<(), Box<dyn std::error::Error>> {
        let path = token_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // Restrictive permissions (user-only)
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(&path, &json)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        }
        Ok(())
    }
}

/// Load saved token, refreshing if expired.
pub async fn load_token() -> Option<String> {
    let path = token_path();
    let data = std::fs::read_to_string(&path).ok()?;
    let mut stored: StoredToken = serde_json::from_str(&data).ok()?;

    if !stored.is_expired() {
        return Some(stored.access_token.clone());
    }

    // Try refresh
    if let Some(ref refresh) = stored.refresh_token {
        if let Ok(new_token) = refresh_token(&stored.issuer, refresh).await {
            stored.access_token = new_token.access_token;
            stored.refresh_token = new_token.refresh_token.or(stored.refresh_token);
            stored.expires_at = new_token.expires_in.map(|e| now_secs() + e);
            let _ = stored.save();
            return Some(stored.access_token.clone());
        }
    }

    eprintln!("Token expired. Run `mjolnir login` to re-authenticate.");
    None
}

async fn refresh_token(
    issuer: &str,
    refresh: &str,
) -> Result<TokenResponse, Box<dyn std::error::Error>> {
    let config = discover(issuer).await?;
    let client = reqwest::Client::new();
    let resp = client
        .post(&config.token_endpoint)
        .form(&[
            ("grant_type", "refresh_token"),
            ("client_id", CLIENT_ID),
            ("refresh_token", refresh),
        ])
        .send()
        .await?
        .error_for_status()?
        .json::<TokenResponse>()
        .await?;
    Ok(resp)
}

/// Resolve the effective token: explicit flag > env > stored file.
pub async fn resolve_token(explicit: &Option<String>) -> Option<String> {
    if explicit.is_some() {
        return explicit.clone();
    }
    load_token().await
}

// --- Login command ---

pub async fn login(issuer: Option<String>) -> Result<(), Box<dyn std::error::Error>> {
    let issuer = issuer.as_deref().unwrap_or(DEFAULT_ISSUER);

    // Check if already logged in with a valid token
    if let Ok(data) = std::fs::read_to_string(token_path()) {
        if let Ok(stored) = serde_json::from_str::<StoredToken>(&data) {
            if !stored.is_expired() {
                eprintln!("Already logged in. Use `mjolnir logout` first to re-authenticate.");
                return Ok(());
            }
            // Token expired — try refresh before prompting full login
            if let Some(ref refresh) = stored.refresh_token {
                if let Ok(new_token) = refresh_token(&stored.issuer, refresh).await {
                    let refreshed = StoredToken {
                        access_token: new_token.access_token,
                        refresh_token: new_token.refresh_token.or(stored.refresh_token),
                        expires_at: new_token.expires_in.map(|e| now_secs() + e),
                        issuer: stored.issuer,
                    };
                    refreshed.save()?;
                    eprintln!("Token refreshed. Logged in.");
                    return Ok(());
                }
            }
        }
    }

    let config = discover(issuer).await?;
    let client = reqwest::Client::new();

    // Generate PKCE code verifier + challenge (S256)
    let code_verifier = generate_code_verifier();
    let code_challenge = generate_code_challenge(&code_verifier);

    // Step 1: Request device code
    let resp = client
        .post(&config.device_authorization_endpoint)
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
        return Err(format!("Device auth failed: {}", body).into());
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
            return Err("Device code expired. Run `mjolnir login` again.".into());
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
            let stored = StoredToken {
                access_token: token_resp.access_token,
                refresh_token: token_resp.refresh_token,
                expires_at: token_resp.expires_in.map(|e| now_secs() + e),
                issuer: issuer.to_string(),
            };
            stored.save()?;
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
            "access_denied" => return Err("Authorization denied.".into()),
            "expired_token" => return Err("Device code expired. Run `mjolnir login` again.".into()),
            other => return Err(format!("Auth error: {}", other).into()),
        }
    }
}

/// Remove stored token.
pub fn logout() -> Result<(), Box<dyn std::error::Error>> {
    let path = token_path();
    if path.exists() {
        std::fs::remove_file(&path)?;
        eprintln!("Logged out. Token removed.");
    } else {
        eprintln!("Not logged in.");
    }
    Ok(())
}

/// Show current auth status.
pub fn status() -> Result<(), Box<dyn std::error::Error>> {
    let path = token_path();
    if !path.exists() {
        println!("Not logged in.");
        return Ok(());
    }

    let data = std::fs::read_to_string(&path)?;
    let stored: StoredToken = serde_json::from_str(&data)?;

    println!("Issuer:  {}", stored.issuer);
    if stored.is_expired() && stored.refresh_token.is_some() {
        println!("Status:  active (will refresh automatically)");
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
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
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

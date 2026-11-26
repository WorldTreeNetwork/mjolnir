use anyhow::{anyhow, bail, Context, Result};
use reqwest::StatusCode;
use serde::Deserialize;
use std::io::{self, Write};

use crate::config::{self, Profile};

#[derive(Deserialize)]
struct MintResponse {
    token: String,
}

pub async fn mint_token(
    profile: &Profile,
    api_flag: &Option<String>,
    room: &str,
    participant: &str,
    json: bool,
) -> Result<()> {
    validate_segment(room, "Room")?;
    validate_segment(participant, "Participant")?;

    let api = config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| anyhow!("Could not initialize the room-token API client"))?;
    let request = client
        .post(format!(
            "{base}/api/relay/rooms/{room}/participants/{participant}/token"
        ))
        .json(&serde_json::json!({}));
    let request = match crate::auth::resolve_token(&None).await {
        Some(token) => request.bearer_auth(token),
        None => request,
    };

    let response = request
        .send()
        .await
        .map_err(|_| anyhow!("Could not reach the room-token API"))?;
    let status = response.status();
    if !status.is_success() {
        let hint = match status {
            StatusCode::UNAUTHORIZED => ". Run `mj login` and try again.",
            StatusCode::FORBIDDEN => ". A user session with relay:join is required.",
            StatusCode::SERVICE_UNAVAILABLE => ". The relay may be unconfigured on this host.",
            _ => "",
        };
        bail!("Room-token API returned {status}{hint}");
    }

    let body = response
        .bytes()
        .await
        .map_err(|_| anyhow!("Could not read the room-token API response"))?;
    let minted: MintResponse = serde_json::from_slice(&body)
        .map_err(|_| anyhow!("The room-token API returned an invalid response"))?;
    if minted.token.is_empty()
        || minted
            .token
            .chars()
            .any(|ch| ch.is_whitespace() || ch.is_control())
    {
        bail!("The room-token API returned an invalid response");
    }

    let mut stdout = io::stdout().lock();
    if json {
        stdout.write_all(&body)
    } else {
        writeln!(stdout, "{}", minted.token)
    }
    .context("Could not write the room-token result")
}

fn validate_segment(segment: &str, label: &str) -> Result<()> {
    if !(1..=64).contains(&segment.len())
        || !segment
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
    {
        bail!("{label} must contain 1 to 64 letters, digits, underscores, or hyphens");
    }
    Ok(())
}

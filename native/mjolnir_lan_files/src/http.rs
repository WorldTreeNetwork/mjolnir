use std::sync::Arc;
use axum::{body::Bytes, extract::{DefaultBodyLimit, Path, State}, http::{HeaderMap, StatusCode}, routing::get, Router};
use base64::{Engine, engine::general_purpose::STANDARD};
use crate::{Error, Share, BLOB_DOOR_URL};
#[derive(Clone)]
struct App { share: Arc<Share>, client: reqwest::Client }
pub fn router(share: Arc<Share>) -> Router {
    Router::new().route("/challenge", get(challenge))
        .route("/files/{hash}", get(fetch).put(put))
        .layer(DefaultBodyLimit::max(64 * 1024 * 1024))
        .with_state(App { share, client: reqwest::Client::builder().timeout(std::time::Duration::from_secs(120)).build().unwrap() })
}
fn header(h: &HeaderMap, name: &str) -> Result<Vec<u8>, StatusCode> {
    STANDARD.decode(h.get(name).and_then(|v| v.to_str().ok()).ok_or(StatusCode::UNAUTHORIZED)?).map_err(|_| StatusCode::UNAUTHORIZED)
}
fn hash(s: &str) -> Result<[u8;32], StatusCode> {
    bs58::decode(s).into_vec().ok().and_then(|b| b.try_into().ok()).ok_or(StatusCode::BAD_REQUEST)
}
fn status(e: Error) -> StatusCode {
    match e { Error::Auth | Error::Owner => StatusCode::FORBIDDEN, Error::Hash => StatusCode::BAD_REQUEST,
        Error::Door => StatusCode::BAD_GATEWAY, Error::Metadata => StatusCode::INTERNAL_SERVER_ERROR }
}
async fn challenge(State(a): State<App>) -> Vec<u8> { a.share.challenge() }
async fn put(State(a): State<App>, Path(h): Path<String>, headers: HeaderMap, body: Bytes) -> Result<StatusCode, StatusCode> {
    let digest = hash(&h)?;
    let proof = header(&headers, "x-identikey-response")?;
    a.share.put(digest, &proof, &body, || async {
        let response = a.client.put(format!("{BLOB_DOOR_URL}/storage/blob/b3/{h}")).body(body.to_vec()).send().await.map_err(|_| Error::Door)?;
        if !response.status().is_success() { return Err(Error::Door); }
        // Read the response to completion; a lost acknowledgement is failure.
        response.bytes().await.map_err(|_| Error::Door)?;
        Ok(())
    }).await.map_err(status)?;
    Ok(StatusCode::CREATED)
}
async fn fetch(State(a): State<App>, Path(h): Path<String>, headers: HeaderMap) -> Result<Vec<u8>, StatusCode> {
    a.share.authorize_get(hash(&h)?, &header(&headers, "x-identikey-response")?, &header(&headers, "x-recrypt-capability")?).map_err(status)?;
    let response = a.client.get(format!("{BLOB_DOOR_URL}/storage/blob/b3/{h}")).send().await.map_err(|_| StatusCode::BAD_GATEWAY)?;
    if !response.status().is_success() { return Err(StatusCode::BAD_GATEWAY); }
    Ok(response.bytes().await.map_err(|_| StatusCode::BAD_GATEWAY)?.to_vec())
}

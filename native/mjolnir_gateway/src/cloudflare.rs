//! Minimal Cloudflare API client for ACME DNS-01 challenge provisioning.

#![allow(dead_code)]

use std::time::Duration;

use serde::{Deserialize, Serialize};
use thiserror::Error;

const BASE_URL: &str = "https://api.cloudflare.com/client/v4";

// ── Error type ────────────────────────────────────────────────────────────────

#[derive(Debug, Error)]
pub enum CloudflareError {
    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("Cloudflare API error (status {status}): {errors:?}")]
    Api { status: u16, errors: Vec<String> },
    #[error("zone not found: {0}")]
    ZoneNotFound(String),
    #[error("no matching zone for: {0}")]
    NoMatchingZone(String),
}

// ── Cloudflare response wrapper ───────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct CfResponse<T> {
    success: bool,
    errors: Vec<CfError>,
    result: Option<T>,
}

#[derive(Debug, Deserialize)]
struct CfError {
    message: String,
}

// ── Zone and Record types ────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct ZoneId(pub String);

#[derive(Debug, Clone, Deserialize)]
pub struct RecordId(pub String);

#[derive(Debug, Deserialize)]
struct Zone {
    id: String,
    name: String,
}

#[derive(Debug, Deserialize)]
struct DnsRecord {
    id: String,
}

// ── Request bodies ────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
struct CreateTxtBody<'a> {
    r#type: &'static str,
    name: &'a str,
    content: &'a str,
    ttl: u32,
}

// ── Client ────────────────────────────────────────────────────────────────────

pub struct CloudflareClient {
    http: reqwest::Client,
    token: String,
    #[cfg(test)]
    base_url: String,
}

impl CloudflareClient {
    pub fn new(token: impl Into<String>) -> Result<Self, CloudflareError> {
        let http = reqwest::ClientBuilder::new()
            .timeout(Duration::from_secs(30))
            .build()?;
        Ok(Self {
            http,
            token: token.into(),
            #[cfg(test)]
            base_url: BASE_URL.to_owned(),
        })
    }

    #[cfg(test)]
    fn with_base_url(token: impl Into<String>, base_url: impl Into<String>) -> Self {
        let http = reqwest::ClientBuilder::new()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("reqwest client");
        Self {
            http,
            token: token.into(),
            base_url: base_url.into(),
        }
    }

    fn base(&self) -> &str {
        #[cfg(test)]
        return &self.base_url;
        #[cfg(not(test))]
        BASE_URL
    }

    /// Check a CF response for API-level errors and unwrap the result.
    fn unwrap_cf<T>(
        resp: CfResponse<T>,
        status: u16,
    ) -> Result<T, CloudflareError> {
        if !resp.success {
            let errors: Vec<String> = resp.errors.into_iter().map(|e| e.message).collect();
            return Err(CloudflareError::Api { status, errors });
        }
        resp.result.ok_or_else(|| CloudflareError::Api {
            status,
            errors: vec!["empty result".into()],
        })
    }

    /// Resolve the DNS zone containing `fqdn` by walking up labels.
    pub async fn find_zone(&self, fqdn: &str) -> Result<(ZoneId, String), CloudflareError> {
        // Strip leading label groups and try each suffix as a zone name.
        // e.g. "_acme-challenge.vm.worldtree.network"
        //   -> try "vm.worldtree.network", "worldtree.network"
        let labels: Vec<&str> = fqdn.split('.').collect();
        // Start from index 1 (skip the leftmost label).
        for start in 1..labels.len().saturating_sub(1) {
            let candidate = labels[start..].join(".");
            let url = format!("{}/zones?name={}&status=active", self.base(), candidate);
            let resp = self
                .http
                .get(&url)
                .header("Authorization", format!("Bearer {}", self.token))
                .header("Content-Type", "application/json")
                .send()
                .await?;
            let status = resp.status().as_u16();
            let body: CfResponse<Vec<Zone>> = resp.json().await?;
            if !body.success {
                let errors: Vec<String> = body.errors.into_iter().map(|e| e.message).collect();
                return Err(CloudflareError::Api { status, errors });
            }
            if let Some(zones) = body.result {
                if !zones.is_empty() {
                    let zone = &zones[0];
                    return Ok((ZoneId(zone.id.clone()), zone.name.clone()));
                }
            }
        }
        Err(CloudflareError::NoMatchingZone(fqdn.to_owned()))
    }

    /// Create a TXT record. Returns the record id so the caller can delete it later.
    pub async fn create_txt(
        &self,
        zone: &ZoneId,
        name: &str,
        content: &str,
        ttl: u32,
    ) -> Result<RecordId, CloudflareError> {
        let url = format!("{}/zones/{}/dns_records", self.base(), zone.0);
        let body = CreateTxtBody {
            r#type: "TXT",
            name,
            content,
            ttl,
        };
        let resp = self
            .http
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await?;
        let status = resp.status().as_u16();
        let cf: CfResponse<DnsRecord> = resp.json().await?;
        let record = Self::unwrap_cf(cf, status)?;
        Ok(RecordId(record.id))
    }

    /// Delete a previously-created DNS record. 404 is treated as success (idempotent).
    pub async fn delete_txt(&self, zone: &ZoneId, record: &RecordId) -> Result<(), CloudflareError> {
        let url = format!("{}/zones/{}/dns_records/{}", self.base(), zone.0, record.0);
        let resp = self
            .http
            .delete(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .header("Content-Type", "application/json")
            .send()
            .await?;
        // 404 = already gone; treat as success.
        if resp.status().as_u16() == 404 {
            return Ok(());
        }
        let status = resp.status().as_u16();
        let cf: CfResponse<serde_json::Value> = resp.json().await?;
        if !cf.success {
            let errors: Vec<String> = cf.errors.into_iter().map(|e| e.message).collect();
            return Err(CloudflareError::Api { status, errors });
        }
        Ok(())
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use mockito::Server;

    fn zone_resp(id: &str, name: &str) -> String {
        format!(
            r#"{{"success":true,"errors":[],"messages":[],"result":[{{"id":"{id}","name":"{name}"}}]}}"#
        )
    }

    fn empty_zone_resp() -> &'static str {
        r#"{"success":true,"errors":[],"messages":[],"result":[]}"#
    }

    fn record_resp(id: &str) -> String {
        format!(
            r#"{{"success":true,"errors":[],"messages":[],"result":{{"id":"{id}"}}}}"#
        )
    }

    fn error_resp(msg: &str) -> String {
        format!(
            r#"{{"success":false,"errors":[{{"message":"{msg}","code":1000}}],"messages":[],"result":null}}"#
        )
    }

    // 1. find_zone_matches_apex
    #[tokio::test]
    async fn find_zone_matches_apex() {
        let mut server = Server::new_async().await;

        // vm.worldtree.network -> not found
        let _m1 = server
            .mock("GET", "/zones?name=vm.worldtree.network&status=active")
            .with_status(200)
            .with_header("Content-Type", "application/json")
            .with_body(empty_zone_resp())
            .create_async()
            .await;

        // worldtree.network -> found
        let _m2 = server
            .mock("GET", "/zones?name=worldtree.network&status=active")
            .with_status(200)
            .with_header("Content-Type", "application/json")
            .with_body(zone_resp("zone-apex-id", "worldtree.network"))
            .create_async()
            .await;

        let cf = CloudflareClient::with_base_url("tok", server.url());
        let (zone_id, name) = cf
            .find_zone("_acme-challenge.vm.worldtree.network")
            .await
            .expect("find_zone");
        assert_eq!(zone_id.0, "zone-apex-id");
        assert_eq!(name, "worldtree.network");
    }

    // 2. find_zone_prefers_most_specific
    #[tokio::test]
    async fn find_zone_prefers_most_specific() {
        let mut server = Server::new_async().await;

        // vm.worldtree.network -> found (more specific)
        let _m1 = server
            .mock("GET", "/zones?name=vm.worldtree.network&status=active")
            .with_status(200)
            .with_header("Content-Type", "application/json")
            .with_body(zone_resp("zone-specific-id", "vm.worldtree.network"))
            .create_async()
            .await;

        let cf = CloudflareClient::with_base_url("tok", server.url());
        let (zone_id, name) = cf
            .find_zone("_acme-challenge.vm.worldtree.network")
            .await
            .expect("find_zone");
        assert_eq!(zone_id.0, "zone-specific-id");
        assert_eq!(name, "vm.worldtree.network");
    }

    // 3. find_zone_errors_when_no_match
    #[tokio::test]
    async fn find_zone_errors_when_no_match() {
        let mut server = Server::new_async().await;

        let _m1 = server
            .mock("GET", "/zones?name=vm.worldtree.network&status=active")
            .with_status(200)
            .with_header("Content-Type", "application/json")
            .with_body(empty_zone_resp())
            .create_async()
            .await;

        let _m2 = server
            .mock("GET", "/zones?name=worldtree.network&status=active")
            .with_status(200)
            .with_header("Content-Type", "application/json")
            .with_body(empty_zone_resp())
            .create_async()
            .await;

        let cf = CloudflareClient::with_base_url("tok", server.url());
        let err = cf
            .find_zone("_acme-challenge.vm.worldtree.network")
            .await
            .expect_err("expected NoMatchingZone");
        assert!(matches!(err, CloudflareError::NoMatchingZone(_)));
    }

    // 4. create_txt_parses_record_id
    #[tokio::test]
    async fn create_txt_parses_record_id() {
        let mut server = Server::new_async().await;

        let _m = server
            .mock("POST", "/zones/zone123/dns_records")
            .with_status(200)
            .with_header("Content-Type", "application/json")
            .with_body(record_resp("rec-abc"))
            .create_async()
            .await;

        let cf = CloudflareClient::with_base_url("tok", server.url());
        let record_id = cf
            .create_txt(
                &ZoneId("zone123".into()),
                "_acme-challenge.vm.worldtree.network",
                "some-dns-value",
                60,
            )
            .await
            .expect("create_txt");
        assert_eq!(record_id.0, "rec-abc");
    }

    // 5. create_txt_surfaces_api_errors
    #[tokio::test]
    async fn create_txt_surfaces_api_errors() {
        let mut server = Server::new_async().await;

        let _m = server
            .mock("POST", "/zones/zone123/dns_records")
            .with_status(400)
            .with_header("Content-Type", "application/json")
            .with_body(error_resp("Invalid record type"))
            .create_async()
            .await;

        let cf = CloudflareClient::with_base_url("tok", server.url());
        let err = cf
            .create_txt(
                &ZoneId("zone123".into()),
                "_acme-challenge.vm.worldtree.network",
                "val",
                60,
            )
            .await
            .expect_err("expected Api error");
        match err {
            CloudflareError::Api { errors, .. } => {
                assert!(errors.iter().any(|e| e.contains("Invalid record type")));
            }
            other => panic!("unexpected error: {other}"),
        }
    }

    // 6. delete_txt_404_is_ok
    #[tokio::test]
    async fn delete_txt_404_is_ok() {
        let mut server = Server::new_async().await;

        let _m = server
            .mock("DELETE", "/zones/zone123/dns_records/rec-gone")
            .with_status(404)
            .with_header("Content-Type", "application/json")
            .with_body(r#"{"success":false,"errors":[{"message":"Not found","code":1032}],"messages":[],"result":null}"#)
            .create_async()
            .await;

        let cf = CloudflareClient::with_base_url("tok", server.url());
        cf.delete_txt(&ZoneId("zone123".into()), &RecordId("rec-gone".into()))
            .await
            .expect("404 on delete should be Ok");
    }
}

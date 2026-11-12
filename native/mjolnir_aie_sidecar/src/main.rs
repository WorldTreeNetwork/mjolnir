// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 World Tree Network Foundation and the Mjolnir contributors

mod admit;
mod catalog;
mod occupancy;

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use occupancy::TryLockError;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use uuid::Uuid;

type HttpErr = (StatusCode, Json<ErrorBody>);

struct App {
    catalog: catalog::Catalog,
    admit_socket: PathBuf,
    accel_held: Option<std::fs::File>,
    jobs: Mutex<HashMap<String, LiveJob>>,
}

// A retry carries the same proof and pending_id returned by authenticated enqueue.
#[derive(Deserialize, Clone)]
struct ExecuteBody {
    design_id: String,
    #[serde(default)]
    pending_id: Option<String>,
    proof: serde_json::Value,
}

struct LiveJob {
    proof: serde_json::Value,
    attempt_id: String,
    retained_since: Instant,
    result: Option<serde_json::Value>,
}

#[derive(Serialize, Debug)]
struct ErrorBody {
    error: String,
}

fn err(status: StatusCode, error: impl Into<String>) -> HttpErr {
    (
        status,
        Json(ErrorBody {
            error: error.into(),
        }),
    )
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let bind: SocketAddr = std::env::var("AIE_BIND")
        .unwrap_or_else(|_| "10.200.0.1:7422".into())
        .parse()?;
    refuse_bad_bind(bind.ip())?;

    let require_accel = std::env::var("AIE_REQUIRE_ACCEL").unwrap_or_else(|_| "1".into()) != "0";
    let accel_path = std::env::var("AIE_DEVICE").unwrap_or_else(|_| "/dev/accel/accel0".into());
    let accel_held = match std::fs::File::open(&accel_path) {
        Ok(f) => Some(f),
        Err(e) if require_accel => {
            return Err(format!("cannot open {accel_path}: {e}").into());
        }
        Err(e) => {
            tracing::warn!("accel open skipped: {e}");
            None
        }
    };

    let admit_socket = PathBuf::from(
        std::env::var("AIE_ADMIT_SOCKET").unwrap_or_else(|_| "/run/mjolnir/aie-admit.sock".into()),
    );

    let app = Arc::new(App {
        catalog: catalog::Catalog::load(),
        admit_socket,
        accel_held,
        jobs: Mutex::new(HashMap::new()),
    });
    let _ = app.accel_held.as_ref();

    let router = Router::new()
        .route("/health", get(health))
        .route("/v1/execute", post(execute))
        .with_state(app);

    let listener = TcpListener::bind(bind).await?;
    tracing::info!(%bind, "aie sidecar listening");
    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown())
        .await?;
    Ok(())
}

fn refuse_bad_bind(ip: IpAddr) -> Result<(), String> {
    if ip.is_unspecified() {
        return Err("AIE_BIND must not be 0.0.0.0".into());
    }
    if ip.is_loopback() {
        return Err("AIE_BIND must not be loopback".into());
    }
    Ok(())
}

async fn health() -> &'static str {
    "ok\n"
}

async fn execute(
    State(app): State<Arc<App>>,
    Json(body): Json<ExecuteBody>,
) -> Result<Json<serde_json::Value>, HttpErr> {
    if !app.catalog.accepted(&body.design_id)
        || body.proof.get("design_id").and_then(|v| v.as_str()) != Some(body.design_id.as_str())
    {
        return Err(err(StatusCode::BAD_REQUEST, "unknown_design"));
    }
    // Enqueue is a separate reply: the guest persists pending_id before any
    // attempt starts. The nonce is consumed only through the scoped socket.
    let pending_id = match &body.pending_id {
        Some(id) => id.clone(),
        None => {
            let verified = beam_request("/api/aie/prepare", &body.proof)
                .await
                .map_err(|e| err(StatusCode::FORBIDDEN, e))?;
            let nonce = verified["nonce"]
                .as_str()
                .ok_or_else(|| err(StatusCode::FORBIDDEN, "nonce_required"))?;
            let id = admit::enqueue(&app.admit_socket, nonce, &verified["frame"])
                .await
                .map_err(|e| err(StatusCode::FORBIDDEN, e))?;
            app.jobs.lock().unwrap().insert(
                id.clone(),
                LiveJob {
                    proof: body.proof,
                    attempt_id: String::new(),
                    retained_since: Instant::now(),
                    result: None,
                },
            );
            return Ok(Json(
                serde_json::json!({"pending_id": id, "status":"pending"}),
            ));
        }
    };
    // References from a previous sidecar process are invalid even when the
    // BEAM still has an undispatched row. Results never authorize a new load.
    let enqueued = {
        let mut jobs = app.jobs.lock().unwrap();
        jobs.retain(|_, j| {
            (!j.attempt_id.is_empty() && j.result.is_none())
                || j.retained_since.elapsed() < Duration::from_secs(60)
        });
        let job = jobs
            .get(&pending_id)
            .ok_or_else(|| err(StatusCode::GONE, "fresh_nonce_required"))?;
        if job.proof != body.proof {
            return Err(err(StatusCode::FORBIDDEN, "proof_mismatch"));
        }
        if !job.attempt_id.is_empty() {
            return Ok(Json(job.result.clone().unwrap_or_else(|| {
                serde_json::json!({
                    "pending_id": pending_id, "attempt_id": job.attempt_id, "status": "running"
                })
            })));
        }
        job.retained_since
    };
    let guard = occupancy::try_lock(Some(&body.design_id)).map_err(|e| match e {
        TryLockError::Occupied {
            pid,
            bundle,
            started_unix,
        } => {
            tracing::info!(pid, ?bundle, started_unix, "aie occupied");
            err(StatusCode::CONFLICT, "occupied")
        }
        TryLockError::Io(e) => err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()),
    })?;
    tracing::info!(pid = guard.state().pid, bundle = ?guard.state().bundle, "aie occupancy acquired");
    let result = start_attempt(app.clone(), body, pending_id.clone(), enqueued, guard).await;
    if result.is_err() {
        // Any abandoned attempt invalidates its queued reference, including
        // failures before BEAM transitions the row to dispatched.
        app.jobs.lock().unwrap().remove(&pending_id);
    }
    result
}

async fn start_attempt(
    app: Arc<App>,
    body: ExecuteBody,
    pending_id: String,
    enqueued: Instant,
    guard: occupancy::OccupancyGuard,
) -> Result<Json<serde_json::Value>, HttpErr> {
    let attempt_id = format!("att_{}", Uuid::new_v4().as_simple());
    if let Some(job) = app.jobs.lock().unwrap().get_mut(&pending_id) {
        job.attempt_id = attempt_id.clone();
    }
    let deadline = Instant::now() + Duration::from_millis(env_u64("AIE_ADMIT_DEADLINE_MS", 5_000));
    // BEAM rechecks the original holder proof, current leaf/being, queue age,
    // and guild after try-lock. A guest-authored frame is never trusted.
    let checked = beam_check(&body, &attempt_id)
        .await
        .map_err(|e| err(StatusCode::FORBIDDEN, e))?;
    let resource = checked["resource"].as_str().unwrap_or("");
    let digest = checked["job_digest"].as_str().unwrap_or("");
    let wall_ms = checked["wall_ms"]
        .as_u64()
        .filter(|v| *v > 0)
        .ok_or_else(|| err(StatusCode::FORBIDDEN, "wall_time_required"))?;
    let input: Vec<u8> = serde_json::from_value(checked["input"].clone())
        .map_err(|_| err(StatusCode::FORBIDDEN, "input_required"))?;
    if input.len() > 1_048_576 {
        return Err(err(StatusCode::BAD_REQUEST, "input_too_large"));
    }
    let admit = tokio::time::timeout(
        deadline.saturating_duration_since(Instant::now()),
        admit::admission(
            &app.admit_socket,
            &pending_id,
            &attempt_id,
            digest,
            resource,
        ),
    )
    .await
    .map_err(|_| err(StatusCode::GONE, "fresh_nonce_required"))?
    .map_err(|e| err(StatusCode::FORBIDDEN, e))?;
    if Instant::now() >= deadline || admit["kind"].as_str() != Some("live") {
        return Err(err(StatusCode::GONE, "fresh_nonce_required"));
    }
    let argv = app
        .catalog
        .worker_argv(&body.design_id)
        .filter(|argv| !argv.is_empty())
        .ok_or_else(|| err(StatusCode::BAD_REQUEST, "unknown_design"))?;
    app.jobs.lock().unwrap().insert(
        pending_id.clone(),
        LiveJob {
            proof: body.proof,
            attempt_id: attempt_id.clone(),
            retained_since: enqueued,
            result: None,
        },
    );
    let response = serde_json::json!({
        "pending_id": pending_id, "attempt_id": attempt_id, "status": "running"
    });
    // The attempt outlives a disconnected HTTP caller. Retries only read it.
    tokio::spawn(async move {
        let result = run_worker(guard, argv, input, wall_ms).await;
        if let Some(job) = app.jobs.lock().unwrap().get_mut(&pending_id) {
            job.retained_since = Instant::now();
            job.result = Some(match result {
                Ok(status) => serde_json::json!({"pending_id": pending_id,
                    "attempt_id": attempt_id, "status": "completed", "ok": status.success(), "exit": status.to_string()}),
                Err(error) => serde_json::json!({"pending_id": pending_id,
                    "attempt_id": attempt_id, "status": "abandoned", "error": error,
                    "fresh_nonce_required": true}),
            });
        }
    });
    Ok(Json(response))
}

async fn run_worker(
    mut guard: occupancy::OccupancyGuard,
    argv: Vec<String>,
    input: Vec<u8>,
    wall_ms: u64,
) -> Result<std::process::ExitStatus, String> {
    occupancy::clear_cloexec(guard.raw_fd()).map_err(|e| e.to_string())?;
    let mut cmd = tokio::process::Command::new(&argv[0]);
    cmd.args(&argv[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    if let Some(mut stdin) = child.stdin.take() {
        tokio::spawn(async move {
            let _ = stdin.write_all(&input).await;
        });
    }
    let result = match tokio::time::timeout(Duration::from_millis(wall_ms), child.wait()).await {
        Ok(Ok(status)) => Ok(status),
        Ok(Err(e)) => {
            let _ = child.kill().await;
            Err(e.to_string())
        }
        Err(_) => {
            let _ = child.kill().await;
            Err("wall_time".into())
        }
    };
    // Wait/kill reaps the worker before releasing the occupancy guard.
    guard.release();
    result
}

async fn beam_check(body: &ExecuteBody, attempt: &str) -> Result<serde_json::Value, String> {
    beam_request(
        "/api/aie/check",
        &serde_json::json!({
            "pending_id": body.pending_id, "attempt_id": attempt, "proof": body.proof
        }),
    )
    .await
}

async fn beam_request(path: &str, body: &serde_json::Value) -> Result<serde_json::Value, String> {
    tokio::time::timeout(Duration::from_millis(env_u64("AIE_ADMIT_DEADLINE_MS", 5_000)), async {
        let addr = std::env::var("AIE_BEAM_ADDR").unwrap_or_else(|_| "10.200.0.1:4000".into());
        let payload = body.to_string();
        let mut stream = TcpStream::connect(addr).await.map_err(|e| e.to_string())?;
        // HTTP/1.0 + close keeps this bounded client free of chunked encoding.
        let req = format!("POST {path} HTTP/1.0\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", payload.len(), payload);
        stream.write_all(req.as_bytes()).await.map_err(|e| e.to_string())?;
        let mut bytes = Vec::new();
        stream.take(8 * 1024 * 1024).read_to_end(&mut bytes).await.map_err(|e| e.to_string())?;
        let reply = String::from_utf8(bytes).map_err(|e| e.to_string())?;
        let (head, payload) = reply.split_once("\r\n\r\n").ok_or("invalid_admit_reply")?;
        if head.split_whitespace().nth(1) != Some("200") { return Err("fresh_nonce_required".into()); }
        serde_json::from_str(payload).map_err(|e| e.to_string())
    }).await.map_err(|_| "admit_deadline".to_string())?
}

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

async fn shutdown() {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("shutdown");
}

#[cfg(test)]
mod guest_contract_tests {
    use super::*;
    use tokio::net::UnixListener;

    #[tokio::test]
    async fn live_retry_keeps_attempt_and_starts_only_one_worker() {
        let dir = std::env::temp_dir().join(format!("aie-guest-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        std::env::set_var("AIE_OCCUPANCY_DIR", &dir);
        let beam = TcpListener::bind("127.0.0.1:0").await.unwrap();
        std::env::set_var("AIE_BEAM_ADDR", beam.local_addr().unwrap().to_string());
        let beam_task = tokio::spawn(async move {
            let (mut stream, _) = beam.accept().await.unwrap();
            let mut buf = vec![0; 16384];
            let _ = stream.read(&mut buf).await.unwrap();
            let body =
                serde_json::json!({"resource":"owner/offer/incarnation", "job_digest":"digest",
                "wall_ms":2000, "input":[104,105,10]})
                .to_string();
            stream
                .write_all(
                    format!(
                        "HTTP/1.0 200 OK\r\nContent-Length: {}\r\n\r\n{}",
                        body.len(),
                        body
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
        });
        let socket = dir.join("admit.sock");
        let admit = UnixListener::bind(&socket).unwrap();
        let admit_task = tokio::spawn(async move {
            let (mut stream, _) = admit.accept().await.unwrap();
            let mut buf = vec![0; 16384];
            let _ = stream.read(&mut buf).await.unwrap();
            let body = r#"{"kind":"live"}"#;
            stream
                .write_all(
                    format!(
                        "HTTP/1.0 200 OK\r\nContent-Length: {}\r\n\r\n{}",
                        body.len(),
                        body
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
        });
        let marker = dir.join("loads");
        let mut catalog = catalog::Catalog::load();
        catalog.argv.insert(
            "vector-add".into(),
            vec![
                "/bin/sh".into(),
                "-c".into(),
                format!(
                    "read line; echo \"$line\" >> '{}'; sleep 0.2",
                    marker.display()
                ),
            ],
        );
        let app = Arc::new(App {
            catalog,
            admit_socket: socket,
            accel_held: None,
            jobs: Mutex::new(HashMap::new()),
        });
        let body = ExecuteBody {
            design_id: "vector-add".into(),
            pending_id: Some("pnd_same".into()),
            proof: serde_json::json!({"design_id":"vector-add", "signature":"holder-proof"}),
        };
        app.jobs.lock().unwrap().insert(
            "pnd_same".into(),
            LiveJob {
                proof: body.proof.clone(),
                attempt_id: String::new(),
                retained_since: Instant::now(),
                result: None,
            },
        );
        let first = execute(State(app.clone()), Json(body.clone()))
            .await
            .unwrap()
            .0;
        let retry = execute(State(app.clone()), Json(body.clone()))
            .await
            .unwrap()
            .0;
        assert_eq!(first["pending_id"], retry["pending_id"]);
        assert_eq!(first["attempt_id"], retry["attempt_id"]);
        let mut rebound = body.clone();
        rebound.proof["signature"] = serde_json::json!("third-identity");
        assert_eq!(
            execute(State(app.clone()), Json(rebound))
                .await
                .err()
                .unwrap()
                .0,
            StatusCode::FORBIDDEN
        );
        for _ in 0..100 {
            let response = execute(State(app.clone()), Json(body.clone()))
                .await
                .unwrap()
                .0;
            if response["status"] == "completed" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let done = execute(State(app.clone()), Json(body)).await.unwrap().0;
        assert_eq!(done["status"], "completed");
        assert_eq!(done["ok"], true);
        assert_eq!(std::fs::read_to_string(marker).unwrap(), "hi\n");
        beam_task.await.unwrap();
        admit_task.await.unwrap();
        let old = ExecuteBody {
            design_id: "vector-add".into(),
            pending_id: Some("pnd_old".into()),
            proof: serde_json::json!({"design_id":"vector-add", "signature":"holder-proof"}),
        };
        assert_eq!(
            execute(State(app.clone()), Json(old.clone()))
                .await
                .err()
                .unwrap()
                .0,
            StatusCode::GONE
        );
        app.jobs.lock().unwrap().insert(
            "pnd_old".into(),
            LiveJob {
                proof: old.proof.clone(),
                attempt_id: String::new(),
                retained_since: Instant::now(),
                result: None,
            },
        );
        // The mock BEAM is now down. A failed attempt before dispatch still
        // invalidates its reference, so a later retry cannot re-admit it.
        assert_eq!(
            execute(State(app.clone()), Json(old.clone()))
                .await
                .err()
                .unwrap()
                .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            execute(State(app.clone()), Json(old))
                .await
                .err()
                .unwrap()
                .0,
            StatusCode::GONE
        );

        std::env::remove_var("AIE_BEAM_ADDR");
        std::env::remove_var("AIE_OCCUPANCY_DIR");
        let _ = std::fs::remove_dir_all(dir);
    }
}

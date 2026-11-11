// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 World Tree Network Foundation and the Mjolnir contributors

mod admit;
mod catalog;
mod occupancy;

use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use occupancy::TryLockError;
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use uuid::Uuid;

type HttpErr = (StatusCode, Json<ErrorBody>);

struct App {
    catalog: catalog::Catalog,
    admit_socket: PathBuf,
    accel_held: Option<std::fs::File>,
}

#[derive(Deserialize)]
struct ExecuteBody {
    design_id: String,
    #[serde(default)]
    nonce: Option<String>,
    #[serde(default)]
    frame: Option<serde_json::Value>,
    #[serde(default)]
    pending_id: Option<String>,
    #[serde(default)]
    resource: Option<String>,
    #[serde(default)]
    job_digest: Option<String>,
    #[serde(default)]
    wall_ms: Option<u64>,
}

#[derive(Serialize)]
struct ErrorBody {
    error: String,
}

fn err(status: StatusCode, error: impl Into<String>) -> HttpErr {
    (status, Json(ErrorBody { error: error.into() }))
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
        std::env::var("AIE_ADMIT_SOCKET")
            .unwrap_or_else(|_| "/run/mjolnir/aie-admit.sock".into()),
    );

    let app = Arc::new(App {
        catalog: catalog::Catalog::load(),
        admit_socket,
        accel_held,
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
    if !app.catalog.accepted(&body.design_id) {
        return Err(err(StatusCode::BAD_REQUEST, "unknown_design"));
    }

    let mut guard = occupancy::try_lock(Some(&body.design_id)).map_err(|e| match e {
        TryLockError::Occupied { pid, bundle, .. } => {
            err(StatusCode::CONFLICT, format!("occupied pid={pid} bundle={bundle:?}"))
        }
        TryLockError::Io(e) => err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()),
    })?;

    let attempt_id = format!("att_{}", Uuid::new_v4().as_simple());
    let deadline = Instant::now() + Duration::from_millis(env_u64("AIE_ADMIT_DEADLINE_MS", 5_000));

    let pending_id = if let Some(id) = body.pending_id.clone() {
        id
    } else {
        let nonce = body
            .nonce
            .clone()
            .ok_or_else(|| err(StatusCode::BAD_REQUEST, "nonce_required"))?;
        let frame = body
            .frame
            .clone()
            .ok_or_else(|| err(StatusCode::BAD_REQUEST, "frame_required"))?;
        match admit::enqueue(&app.admit_socket, &nonce, &frame).await {
            Ok(id) => id,
            Err(e) => {
                guard.release();
                return Err(err(StatusCode::FORBIDDEN, e));
            }
        }
    };

    if Instant::now() > deadline {
        guard.release();
        return Err(err(StatusCode::REQUEST_TIMEOUT, "admit_deadline"));
    }

    let resource = body
        .resource
        .clone()
        .or_else(|| {
            body.frame
                .as_ref()
                .and_then(|f| f.get("resource"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
        .unwrap_or_default();
    let job_digest = body.job_digest.clone().unwrap_or_default();

    let admit = match admit::admission(
        &app.admit_socket,
        &pending_id,
        &attempt_id,
        &job_digest,
        &resource,
    )
    .await
    {
        Ok(v) => v,
        Err(e) => {
            guard.release();
            return Err(err(StatusCode::FORBIDDEN, e));
        }
    };

    let kind = admit.get("kind").and_then(|v| v.as_str()).unwrap_or("");
    if Instant::now() > deadline || kind != "live" {
        guard.release();
        return Err(err(StatusCode::FORBIDDEN, "no_live_success"));
    }

    let argv = match app.catalog.worker_argv(&body.design_id) {
        Some(argv) => argv,
        None => {
            guard.release();
            return Err(err(StatusCode::BAD_REQUEST, "unknown_design"));
        }
    };

    let fd = guard.raw_fd();
    if let Err(e) = occupancy::clear_cloexec(fd) {
        guard.release();
        return Err(err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()));
    }

    let mut cmd = std::process::Command::new(&argv[0]);
    if argv.len() > 1 {
        cmd.args(&argv[1..]);
    }
    cmd.stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            guard.release();
            return Err(err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()));
        }
    };

    let wall = Duration::from_millis(body.wall_ms.unwrap_or(env_u64("AIE_WALL_MS", 30_000)));
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                drop(child);
                tokio::time::sleep(Duration::from_millis(50)).await;
                guard.release();
                return Ok(Json(serde_json::json!({
                    "ok": true,
                    "pending_id": pending_id,
                    "attempt_id": attempt_id,
                    "status": format!("{status}")
                })));
            }
            Ok(None) if started.elapsed() >= wall => {
                let _ = child.kill();
                let _ = child.wait();
                tokio::time::sleep(Duration::from_millis(50)).await;
                guard.release();
                return Err(err(StatusCode::REQUEST_TIMEOUT, "wall_time"));
            }
            Ok(None) => tokio::time::sleep(Duration::from_millis(20)).await,
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                guard.release();
                return Err(err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()));
            }
        }
    }
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

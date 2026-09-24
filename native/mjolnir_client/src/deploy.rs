//! `mj deploy [PATH]` — package an app source tree and deploy it to Mjolnir.
//!
//! The target directory (default: cwd) is packed into a gzipped tar, honoring
//! `.gitignore` (plus a few always-excluded build/VCS dirs), and POSTed to
//! `/api/deploy`. The server streams back newline-delimited JSON: progress
//! objects `{stage, line}` (printed to stderr as they arrive) followed by a
//! final `{ok:true, url, ...}` (URL printed prominently to stdout) or
//! `{ok:false, error, stage}` (error to stderr, non-zero exit).

use anyhow::{bail, Context, Result};
use futures_util::StreamExt;
use serde::Deserialize;
use std::path::Path;

use crate::api::api_client;
use crate::config::Profile;

/// Directories always pruned from the deploy tarball, on top of `.gitignore`.
const SKIP_DIRS: &[&str] = &[".git", "node_modules", "build", ".svelte-kit"];

/// Progress frame emitted by the server during a deploy.
#[derive(Deserialize)]
struct DeployProgress {
    stage: Option<String>,
    line: Option<String>,
}

/// Terminal frame of a deploy stream. Distinguished from progress frames by the
/// presence of the `ok` field.
#[derive(Deserialize)]
struct DeployFinal {
    ok: bool,
    // ok == true
    url: Option<String>,
    app_name: Option<String>,
    release_snapshot: Option<String>,
    service_vm_id: Option<String>,
    // ok == false
    error: Option<String>,
    stage: Option<String>,
}

pub async fn cmd_deploy(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    path: Option<String>,
    name: Option<String>,
    memory: u32,
    domain: Option<String>,
    base_image: Option<String>,
) -> Result<()> {
    // Resolve + validate the source directory.
    let dir = match path {
        Some(p) => std::path::PathBuf::from(p),
        None => std::env::current_dir().context("failed to determine current directory")?,
    };
    let dir = dir
        .canonicalize()
        .with_context(|| format!("cannot access path: {}", dir.display()))?;
    if !dir.is_dir() {
        bail!("deploy target is not a directory: {}", dir.display());
    }

    // App name: --name flag, else the directory basename.
    let app_name = match name {
        Some(n) => n,
        None => dir
            .file_name()
            .and_then(|s| s.to_str())
            .map(|s| s.to_string())
            .ok_or_else(|| anyhow::anyhow!("could not derive app name from {}", dir.display()))?,
    };

    eprintln!("Packaging {} (honoring .gitignore)...", dir.display());
    let tarball = build_tarball(&dir).context("failed to build deploy tarball")?;
    eprintln!(
        "Deploying '{}' ({}, {} MB memory)...",
        app_name,
        human_bytes(tarball.len() as u64),
        memory
    );

    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let mut req = client
        .post(format!("{}/api/deploy", base))
        .header("X-App-Name", &app_name)
        .header("X-Memory-MB", memory.to_string())
        .header(reqwest::header::CONTENT_TYPE, "application/gzip")
        .body(tarball);
    if let Some(ref d) = domain {
        req = req.header("X-Domain", d);
    }
    if let Some(ref img) = base_image {
        req = req.header("X-Base-Image", img);
    }

    let resp = req.send().await.context("deploy: failed to send request")?;
    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        bail!("deploy: server returned {} — {}", status, body.trim());
    }

    // Stream the NDJSON response, one JSON object per line.
    let mut stream = resp.bytes_stream();
    let mut buf = String::new();
    let mut final_result: Option<DeployFinal> = None;

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.context("deploy: stream read error")?;
        buf.push_str(&String::from_utf8_lossy(&chunk));

        while let Some(idx) = buf.find('\n') {
            let line: String = buf.drain(..idx + 1).collect();
            handle_line(line.trim(), &mut final_result);
        }
    }
    // Any trailing bytes without a newline still form one last frame.
    let tail = buf.trim().to_string();
    if !tail.is_empty() {
        handle_line(&tail, &mut final_result);
    }

    match final_result {
        Some(f) if f.ok => {
            let url = f.url.unwrap_or_default();
            eprintln!();
            eprintln!(
                "\x1b[32m✔ Deployed {}\x1b[0m",
                f.app_name.unwrap_or(app_name)
            );
            if let Some(snap) = f.release_snapshot {
                eprintln!("  release snapshot: {}", snap);
            }
            if let Some(vm) = f.service_vm_id {
                eprintln!("  service VM:       {}", vm);
            }
            if url.is_empty() {
                eprintln!("  (deployed, but no URL was returned)");
            } else {
                eprintln!("\x1b[1;36m  {}\x1b[0m", url);
                // The URL goes to stdout so `mj deploy` can be captured in a pipe.
                println!("{}", url);
            }
            Ok(())
        }
        Some(f) => {
            let stage = f.stage.as_deref().unwrap_or("?");
            let error = f.error.as_deref().unwrap_or("unknown error");
            bail!("deploy failed at stage '{}': {}", stage, error);
        }
        None => bail!("deploy: stream ended without a final result"),
    }
}

/// Route one NDJSON line: a `{ok:...}` frame is captured as the terminal
/// result; anything else is treated as a `{stage, line}` progress frame and
/// echoed to stderr. Unparseable lines are printed raw (defensive).
fn handle_line(line: &str, final_result: &mut Option<DeployFinal>) {
    if line.is_empty() {
        return;
    }
    let value: serde_json::Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(_) => {
            eprintln!("{}", line);
            return;
        }
    };

    if value.get("ok").is_some() {
        match serde_json::from_value::<DeployFinal>(value) {
            Ok(f) => *final_result = Some(f),
            Err(e) => eprintln!("deploy: malformed final frame: {}", e),
        }
        return;
    }

    // Progress frame.
    let p: DeployProgress = serde_json::from_value(value).unwrap_or(DeployProgress {
        stage: None,
        line: Some(line.to_string()),
    });
    let text = p.line.unwrap_or_default();
    match p.stage.as_deref() {
        Some(stage) if !stage.is_empty() => eprintln!("[{}] {}", stage, text),
        _ => eprintln!("{}", text),
    }
}

/// Build a gzipped tar of `dir`, honoring `.gitignore` (via the `ignore` crate)
/// and always pruning [`SKIP_DIRS`]. Paths in the archive are relative to `dir`.
fn build_tarball(dir: &Path) -> Result<Vec<u8>> {
    use flate2::write::GzEncoder;
    use flate2::Compression;
    use ignore::overrides::OverrideBuilder;
    use ignore::WalkBuilder;

    // Prune the always-excluded dirs during the walk. All patterns are negated,
    // so the override acts as a pure ignore list (no whitelist switch).
    let mut ob = OverrideBuilder::new(dir);
    for d in SKIP_DIRS {
        ob.add(&format!("!{}/", d))
            .with_context(|| format!("bad override pattern for {}", d))?;
        ob.add(&format!("!**/{}/", d))
            .with_context(|| format!("bad nested override pattern for {}", d))?;
    }
    let overrides = ob.build().context("failed to build path overrides")?;

    let mut builder = WalkBuilder::new(dir);
    builder
        .hidden(false) // include dotfiles (e.g. .env.example); SKIP_DIRS still prunes .git
        .git_ignore(true)
        .git_global(true)
        .git_exclude(true)
        .parents(true)
        .overrides(overrides);

    let encoder = GzEncoder::new(Vec::new(), Compression::default());
    let mut tar = tar::Builder::new(encoder);
    tar.follow_symlinks(false);

    for result in builder.build() {
        let entry = result.context("failed to walk source tree")?;
        let path = entry.path();
        if path == dir {
            continue;
        }
        let rel = path.strip_prefix(dir).context("path outside source tree")?;

        let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
        if is_dir {
            // Directories are implied by their file paths; skip empty ones.
            continue;
        }
        tar.append_path_with_name(path, rel)
            .with_context(|| format!("failed to add {} to archive", rel.display()))?;
    }

    let encoder = tar.into_inner().context("failed to finalize tar")?;
    let bytes = encoder.finish().context("failed to finalize gzip")?;
    Ok(bytes)
}

/// Human-readable byte count (mirrors the style used elsewhere in the CLI).
fn human_bytes(bytes: u64) -> String {
    const UNITS: &[&str] = &["B", "KB", "MB", "GB", "TB"];
    let mut size = bytes as f64;
    let mut unit = 0;
    while size >= 1024.0 && unit < UNITS.len() - 1 {
        size /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{} {}", bytes, UNITS[unit])
    } else {
        format!("{:.1} {}", size, UNITS[unit])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Read the entry paths back out of a gzipped tar produced by
    /// [`build_tarball`], so tests can assert what was included/excluded.
    fn tarball_entries(bytes: &[u8]) -> Vec<String> {
        use flate2::read::GzDecoder;
        let mut archive = tar::Archive::new(GzDecoder::new(bytes));
        archive
            .entries()
            .unwrap()
            .map(|e| {
                e.unwrap()
                    .path()
                    .unwrap()
                    .to_string_lossy()
                    .replace('\\', "/")
            })
            .collect()
    }

    fn write_file(path: &Path, contents: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut f = std::fs::File::create(path).unwrap();
        f.write_all(contents.as_bytes()).unwrap();
    }

    /// Unique scratch dir under the system temp dir (no tempfile dep).
    fn scratch_dir(tag: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        p.push(format!("mj-deploy-test-{}-{}", tag, nanos));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn tarball_honors_gitignore_and_skip_dirs() {
        let root = scratch_dir("gitignore");

        write_file(&root.join(".gitignore"), "ignored.txt\ndist/\n");
        write_file(&root.join("index.js"), "console.log('hi')");
        write_file(&root.join("src/app.js"), "export const x = 1");
        write_file(&root.join(".env.example"), "KEY=value"); // dotfile, kept
        write_file(&root.join("ignored.txt"), "secret"); // gitignored
        write_file(&root.join("dist/bundle.js"), "built"); // gitignored dir
        write_file(&root.join("node_modules/left-pad/index.js"), "pad"); // always skipped
        write_file(&root.join(".git/config"), "[core]"); // always skipped
        write_file(&root.join("build/out.o"), "obj"); // always skipped
        write_file(&root.join(".svelte-kit/generated.js"), "gen"); // always skipped
        write_file(&root.join("web/node_modules/dep/x.js"), "nested"); // nested skip

        let bytes = build_tarball(&root).unwrap();
        let entries = tarball_entries(&bytes);

        assert!(entries.contains(&"index.js".to_string()), "{:?}", entries);
        assert!(entries.contains(&"src/app.js".to_string()), "{:?}", entries);
        assert!(
            entries.contains(&".env.example".to_string()),
            "dotfiles should be kept: {:?}",
            entries
        );

        for excluded in [
            "ignored.txt",
            "dist/bundle.js",
            "node_modules/left-pad/index.js",
            ".git/config",
            "build/out.o",
            ".svelte-kit/generated.js",
            "web/node_modules/dep/x.js",
        ] {
            assert!(
                !entries.iter().any(|e| e == excluded),
                "{} should be excluded, got {:?}",
                excluded,
                entries
            );
        }

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn progress_frame_does_not_set_final() {
        let mut final_result: Option<DeployFinal> = None;
        handle_line(r#"{"stage":"build","line":"compiling"}"#, &mut final_result);
        assert!(final_result.is_none());
    }

    #[test]
    fn ok_frame_sets_final_success() {
        let mut final_result: Option<DeployFinal> = None;
        handle_line(
            r#"{"ok":true,"url":"https://app.example.com","app_name":"app"}"#,
            &mut final_result,
        );
        let f = final_result.expect("final captured");
        assert!(f.ok);
        assert_eq!(f.url.as_deref(), Some("https://app.example.com"));
    }

    #[test]
    fn error_frame_sets_final_failure() {
        let mut final_result: Option<DeployFinal> = None;
        handle_line(
            r#"{"ok":false,"error":"boom","stage":"push"}"#,
            &mut final_result,
        );
        let f = final_result.expect("final captured");
        assert!(!f.ok);
        assert_eq!(f.error.as_deref(), Some("boom"));
        assert_eq!(f.stage.as_deref(), Some("push"));
    }
}

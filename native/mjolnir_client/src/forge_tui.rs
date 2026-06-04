//! Forge TUI — interactive ratatui front-end for the host config reconciler.
//!
//! Drives the Forge HTTP API at /api/forge/* and renders a live, navigable view
//! of reconciliation state. The data flow on launch is `/discover` → `/plan` →
//! `/state`: discover populates the store with undeclared (`unmanaged`)
//! resources, plan refreshes declared/owned statuses, and state is the primary
//! list source. State is then re-fetched every 2s and on any SSE event from
//! `/events/stream`.
//!
//! Layout:
//!   - MAIN VIEW: a `Table` of STATUS | KIND | ID with colored status cells, a
//!     header with host + counts, a one-line key legend, and a transient toast.
//!   - DIFF VIEW: a side-by-side declared-vs-observed diff for the selected row,
//!     computed with `similar::TextDiff`.
//!
//! Networking errors never crash the loop — they surface in the toast line.

use std::io::{Stdout, Write};
use std::time::Duration;

use anyhow::{Context, Result};
use crossterm::{
    event::{Event, EventStream, KeyCode, KeyEventKind, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use futures_util::StreamExt;
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
    widgets::{Block, Borders, Cell, Paragraph, Row, Table, TableState, Wrap},
    Frame, Terminal,
};
use serde::Deserialize;

use crate::config::Profile;

type Tui = Terminal<CrosstermBackend<Stdout>>;

// ---------------------------------------------------------------------------
// Response types (mirrors the /api/forge contract; some overlap with forge.rs
// but are re-declared here so the TUI module is self-contained)
// ---------------------------------------------------------------------------

#[derive(Deserialize, Clone)]
#[allow(dead_code)]
struct StateRecord {
    host: String,
    kind: String,
    resource_id: String,
    status: String,
    declared_hash: Option<String>,
    owned_hash: Option<String>,
    observed_hash: Option<String>,
    applied_at: Option<String>,
    observed_at: Option<String>,
    updated_at: Option<String>,
}

#[derive(Deserialize)]
struct StateResponse {
    records: Vec<StateRecord>,
}

#[derive(Deserialize)]
struct DiffResponse {
    #[allow(dead_code)]
    host: String,
    kind: String,
    id: String,
    status: String,
    declared: Option<String>,
    observed: Option<String>,
}

#[derive(Deserialize)]
struct ApplyResult {
    kind: String,
    id: String,
    result: String,
    reason: Option<String>,
}

#[derive(Deserialize)]
struct ApplyResponse {
    #[allow(dead_code)]
    host: String,
    results: Vec<ApplyResult>,
}

#[derive(Deserialize)]
struct DeclPathResponse {
    #[allow(dead_code)]
    host: String,
    #[allow(dead_code)]
    kind: String,
    #[allow(dead_code)]
    id: String,
    path: Option<String>,
}

/// Generic 422 error envelope: `{"error":"...","reason":"..."}`.
#[derive(Deserialize)]
struct ErrorResponse {
    #[allow(dead_code)]
    error: Option<String>,
    reason: Option<String>,
}

// ---------------------------------------------------------------------------
// Status → color mapping
// ---------------------------------------------------------------------------

fn status_color(status: &str) -> Color {
    match status {
        "converged" => Color::Green,
        "drifted" | "new" | "missing" | "prune" => Color::Yellow,
        "conflict" => Color::Red,
        "unmanaged" => Color::Blue,
        "ignored" | "tombstone" => Color::DarkGray,
        _ => Color::Reset,
    }
}

// ---------------------------------------------------------------------------
// HTTP client wrapper — one reqwest client + base URL, all forge calls.
// Every method returns a Result; callers surface failures in the toast.
// ---------------------------------------------------------------------------

struct ForgeClient {
    client: reqwest::Client,
    base: String,
    host: String,
}

impl ForgeClient {
    /// GET /state?host=H — the primary list source.
    async fn fetch_state(&self) -> Result<Vec<StateRecord>> {
        let resp: StateResponse = self
            .client
            .get(format!("{}/api/forge/state", self.base))
            .query(&[("host", &self.host)])
            .send()
            .await
            .context("failed to fetch forge state")?
            .error_for_status()
            .context("forge state request failed")?
            .json()
            .await
            .context("failed to parse forge state response")?;
        Ok(resp.records)
    }

    /// GET /discover?host=H — enumerate undeclared resources into the store.
    async fn discover(&self) -> Result<()> {
        self.client
            .get(format!("{}/api/forge/discover", self.base))
            .query(&[("host", &self.host)])
            .send()
            .await
            .context("failed to run forge discover")?
            .error_for_status()
            .context("forge discover request failed")?;
        Ok(())
    }

    /// GET /plan?host=H — refresh declared/owned statuses into the store.
    async fn plan(&self) -> Result<()> {
        self.client
            .get(format!("{}/api/forge/plan", self.base))
            .query(&[("host", &self.host)])
            .send()
            .await
            .context("failed to run forge plan")?
            .error_for_status()
            .context("forge plan request failed")?;
        Ok(())
    }

    /// GET /diff?host=H&kind=K&id=ID — canonical declared vs observed text.
    async fn diff(&self, kind: &str, id: &str) -> Result<DiffResponse> {
        let resp: DiffResponse = self
            .client
            .get(format!("{}/api/forge/diff", self.base))
            .query(&[("host", &self.host), ("kind", &kind.to_string()), ("id", &id.to_string())])
            .send()
            .await
            .context("failed to fetch forge diff")?
            .error_for_status()
            .context("forge diff request failed")?
            .json()
            .await
            .context("failed to parse forge diff response")?;
        Ok(resp)
    }

    /// POST /apply with explicit keys (`[{kind,id}]`). Returns a summary string.
    async fn apply_one(&self, kind: &str, id: &str) -> Result<String> {
        let body = serde_json::json!({
            "host": self.host,
            "keys": [{ "kind": kind, "id": id }],
        });
        self.apply(body, &format!("{}/{}", kind, id)).await
    }

    /// POST /apply with `keys: "all_safe"`.
    async fn apply_all_safe(&self) -> Result<String> {
        let body = serde_json::json!({ "host": self.host, "keys": "all_safe" });
        self.apply(body, "all_safe").await
    }

    async fn apply(&self, body: serde_json::Value, label: &str) -> Result<String> {
        let resp: ApplyResponse = self
            .client
            .post(format!("{}/api/forge/apply", self.base))
            .json(&body)
            .send()
            .await
            .context("failed to send forge apply request")?
            .error_for_status()
            .context("forge apply request failed")?
            .json()
            .await
            .context("failed to parse forge apply response")?;

        if resp.results.is_empty() {
            return Ok(format!("apply {}: nothing to do", label));
        }
        // Summarize: list each result compactly.
        let parts: Vec<String> = resp
            .results
            .iter()
            .map(|r| {
                if r.result == "ok" {
                    format!("{}/{}: ok", r.kind, r.id)
                } else {
                    let reason = r.reason.as_deref().unwrap_or("error");
                    format!("{}/{}: {}", r.kind, r.id, reason)
                }
            })
            .collect();
        Ok(format!("applied {}", parts.join(", ")))
    }

    /// POST /adopt — adopt the resource (or re-author the declaration from
    /// observed state). On 422 returns a human toast containing the reason.
    async fn adopt(&self, kind: &str, id: &str) -> Result<String> {
        let body = serde_json::json!({ "host": self.host, "kind": kind, "id": id });
        let resp = self
            .client
            .post(format!("{}/api/forge/adopt", self.base))
            .json(&body)
            .send()
            .await
            .context("failed to send forge adopt request")?;

        if resp.status().is_success() {
            Ok(format!("adopted {}/{}", kind, id))
        } else {
            let reason = parse_error_reason(resp).await;
            Ok(format!("adopt failed: {}", reason))
        }
    }

    /// POST /ignore — mark the resource ignored. On 422 surface the reason.
    async fn ignore(&self, kind: &str, id: &str) -> Result<String> {
        let body = serde_json::json!({ "host": self.host, "kind": kind, "id": id });
        let resp = self
            .client
            .post(format!("{}/api/forge/ignore", self.base))
            .json(&body)
            .send()
            .await
            .context("failed to send forge ignore request")?;

        if resp.status().is_success() {
            Ok(format!("ignored {}/{}", kind, id))
        } else {
            let reason = parse_error_reason(resp).await;
            Ok(format!("ignore failed: {}", reason))
        }
    }

    /// GET /decl-path — declaration .exs file path (null if undeclared).
    async fn decl_path(&self, kind: &str, id: &str) -> Result<Option<String>> {
        let resp: DeclPathResponse = self
            .client
            .get(format!("{}/api/forge/decl-path", self.base))
            .query(&[("host", &self.host), ("kind", &kind.to_string()), ("id", &id.to_string())])
            .send()
            .await
            .context("failed to fetch decl-path")?
            .error_for_status()
            .context("decl-path request failed")?
            .json()
            .await
            .context("failed to parse decl-path response")?;
        Ok(resp.path)
    }
}

/// Extract a human-readable reason from a non-2xx forge response body.
async fn parse_error_reason(resp: reqwest::Response) -> String {
    let status = resp.status();
    match resp.json::<ErrorResponse>().await {
        Ok(e) => e.reason.unwrap_or_else(|| status.to_string()),
        Err(_) => status.to_string(),
    }
}

// ---------------------------------------------------------------------------
// App state
// ---------------------------------------------------------------------------

/// Which screen is active.
enum View {
    List,
    Diff(DiffState),
}

/// Loaded diff content for the diff view.
struct DiffState {
    kind: String,
    id: String,
    status: String,
    declared: Option<String>,
    observed: Option<String>,
}

/// Active input/filter sub-mode within the list view.
enum InputMode {
    Normal,
    /// Typing a filter substring; holds the in-progress query.
    Filter(String),
}

struct App {
    forge: ForgeClient,
    /// All records from the last /state fetch (unfiltered).
    records: Vec<StateRecord>,
    /// Indices into `records` that pass the active filter.
    filtered: Vec<usize>,
    table_state: TableState,
    view: View,
    mode: InputMode,
    /// Applied filter substring (matches kind or id). Empty = no filter.
    filter: String,
    /// Transient toast line for results/errors.
    toast: String,
    should_quit: bool,
}

impl App {
    fn new(forge: ForgeClient) -> Self {
        Self {
            forge,
            records: Vec::new(),
            filtered: Vec::new(),
            table_state: TableState::default(),
            view: View::List,
            mode: InputMode::Normal,
            filter: String::new(),
            toast: String::new(),
            should_quit: false,
        }
    }

    /// Recompute the filtered index list and clamp the selection.
    fn recompute_filter(&mut self) {
        let f = self.filter.to_lowercase();
        self.filtered = self
            .records
            .iter()
            .enumerate()
            .filter(|(_, r)| {
                f.is_empty()
                    || r.kind.to_lowercase().contains(&f)
                    || r.resource_id.to_lowercase().contains(&f)
            })
            .map(|(i, _)| i)
            .collect();

        // Clamp selection to the new filtered length.
        let sel = match self.table_state.selected() {
            Some(s) if !self.filtered.is_empty() => s.min(self.filtered.len() - 1),
            _ if self.filtered.is_empty() => 0,
            _ => 0,
        };
        if self.filtered.is_empty() {
            self.table_state.select(None);
        } else {
            self.table_state.select(Some(sel));
        }
    }

    /// The currently selected record, if any (resolves through the filter).
    fn selected_record(&self) -> Option<&StateRecord> {
        let sel = self.table_state.selected()?;
        let idx = *self.filtered.get(sel)?;
        self.records.get(idx)
    }

    fn select_next(&mut self) {
        if self.filtered.is_empty() {
            return;
        }
        let i = match self.table_state.selected() {
            Some(i) if i + 1 < self.filtered.len() => i + 1,
            Some(i) => i,
            None => 0,
        };
        self.table_state.select(Some(i));
    }

    fn select_prev(&mut self) {
        if self.filtered.is_empty() {
            return;
        }
        let i = match self.table_state.selected() {
            Some(i) if i > 0 => i - 1,
            _ => 0,
        };
        self.table_state.select(Some(i));
    }

    fn select_first(&mut self) {
        if !self.filtered.is_empty() {
            self.table_state.select(Some(0));
        }
    }

    fn select_last(&mut self) {
        if !self.filtered.is_empty() {
            self.table_state.select(Some(self.filtered.len() - 1));
        }
    }

    /// Re-fetch /state and rebuild the filtered view (preserving selection).
    async fn refresh_state(&mut self) {
        match self.forge.fetch_state().await {
            Ok(records) => {
                self.records = records;
                self.recompute_filter();
                // Ensure a selection exists when rows are present.
                if self.table_state.selected().is_none() && !self.filtered.is_empty() {
                    self.table_state.select(Some(0));
                }
            }
            Err(e) => self.toast = format!("state refresh failed: {}", e),
        }
    }

    /// Full refresh: discover → plan → state (the launch/`r` sequence).
    async fn full_refresh(&mut self) {
        if let Err(e) = self.forge.discover().await {
            self.toast = format!("discover failed: {}", e);
        }
        if let Err(e) = self.forge.plan().await {
            self.toast = format!("plan failed: {}", e);
        }
        self.refresh_state().await;
    }
}

// ---------------------------------------------------------------------------
// Terminal lifecycle — RAII guard guarantees restore on every exit path.
// ---------------------------------------------------------------------------

struct TerminalGuard;

impl TerminalGuard {
    fn enter() -> Result<(Tui, Self)> {
        enable_raw_mode().context("failed to enable raw mode")?;
        let mut stdout = std::io::stdout();
        execute!(stdout, EnterAlternateScreen).context("failed to enter alternate screen")?;
        let backend = CrosstermBackend::new(stdout);
        let terminal = Terminal::new(backend).context("failed to build terminal")?;
        Ok((terminal, TerminalGuard))
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        // Best-effort restore — ignore errors since we may already be unwinding.
        let _ = disable_raw_mode();
        let _ = execute!(std::io::stdout(), LeaveAlternateScreen);
    }
}

/// Temporarily leave the TUI to run a blocking external process (e.g. $EDITOR),
/// then restore raw mode + alternate screen. Returns whatever `f` returns.
fn suspend_terminal<T>(terminal: &mut Tui, f: impl FnOnce() -> T) -> Result<T> {
    disable_raw_mode().ok();
    execute!(std::io::stdout(), LeaveAlternateScreen).ok();
    let out = f();
    enable_raw_mode().context("failed to re-enable raw mode")?;
    execute!(std::io::stdout(), EnterAlternateScreen).context("failed to re-enter alt screen")?;
    terminal.clear().context("failed to clear terminal")?;
    Ok(out)
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub async fn run(
    api: Option<String>,
    token: Option<String>,
    host: String,
    profile: &Profile,
) -> Result<()> {
    let client = crate::api::api_client(&token).await;
    let base = crate::config::resolve_api(&api, profile);
    let base = base.trim_end_matches('/').to_string();

    let forge = ForgeClient {
        client,
        base: base.clone(),
        host: host.clone(),
    };

    let (mut terminal, _guard) = TerminalGuard::enter()?;
    let result = event_loop(&mut terminal, forge, &base, &token, profile).await;
    // `_guard` drops here, restoring the terminal even on error.
    result
}

/// Main async event loop. Merges keyboard input, a 2s poll tick, and the SSE
/// event stream via `tokio::select!`. Redraws after every wake-up.
async fn event_loop(
    terminal: &mut Tui,
    forge: ForgeClient,
    base: &str,
    token: &Option<String>,
    profile: &Profile,
) -> Result<()> {
    let mut app = App::new(forge);

    // Initial data: discover → plan → state.
    app.full_refresh().await;
    if app.table_state.selected().is_none() && !app.filtered.is_empty() {
        app.table_state.select(Some(0));
    }
    app.toast = format!("loaded {} resources", app.records.len());

    // Input stream (async crossterm events).
    let mut events = EventStream::new();
    // 2s poll for /state.
    let mut poll = tokio::time::interval(Duration::from_secs(2));
    poll.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    // SSE channel: a background task pumps "an event arrived" notifications here.
    let (sse_tx, mut sse_rx) = tokio::sync::mpsc::channel::<()>(16);
    spawn_sse_task(base.to_string(), token.clone(), profile.clone(), sse_tx);

    // Draw once before blocking on input.
    terminal.draw(|f| draw(f, &mut app))?;

    loop {
        tokio::select! {
            // --- Keyboard / terminal events ---
            maybe_event = events.next() => {
                match maybe_event {
                    Some(Ok(Event::Key(key))) => {
                        if key.kind != KeyEventKind::Press {
                            continue;
                        }
                        handle_key(terminal, &mut app, key.code, key.modifiers).await?;
                    }
                    Some(Ok(Event::Resize(_, _))) => { /* redraw below */ }
                    Some(Ok(_)) => continue,
                    Some(Err(_)) => continue,
                    None => break, // input stream closed
                }
            }
            // --- 2s poll ---
            _ = poll.tick() => {
                // Only the list view auto-refreshes; the diff view is static.
                if matches!(app.view, View::List) {
                    app.refresh_state().await;
                }
            }
            // --- SSE event arrived → re-fetch state (debounced by draining) ---
            Some(_) = sse_rx.recv() => {
                // Drain any backlog so a burst of events triggers one refresh.
                while sse_rx.try_recv().is_ok() {}
                if matches!(app.view, View::List) {
                    app.refresh_state().await;
                }
            }
        }

        if app.should_quit {
            break;
        }
        terminal.draw(|f| draw(f, &mut app))?;
    }

    Ok(())
}

/// Background SSE subscriber. Reconnects on disconnect and sends a unit message
/// on `tx` for every decoded event so the main loop can re-fetch /state.
fn spawn_sse_task(
    base: String,
    token: Option<String>,
    profile: Profile,
    tx: tokio::sync::mpsc::Sender<()>,
) {
    tokio::spawn(async move {
        let client = crate::api::api_client(&token).await;
        let _ = profile; // base already resolved; profile kept for signature parity
        let mut cursor: Option<String> = None;

        loop {
            let mut req = client.get(format!("{}/api/forge/events/stream", base));
            if let Some(ref c) = cursor {
                req = req.query(&[("since", c)]);
            }

            let resp = match req.send().await.and_then(|r| r.error_for_status()) {
                Ok(r) => r,
                Err(_) => {
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    continue;
                }
            };

            let mut stream = resp.bytes_stream();
            let mut buf = String::new();

            while let Some(chunk) = stream.next().await {
                let chunk = match chunk {
                    Ok(c) => c,
                    Err(_) => break,
                };
                buf.push_str(&String::from_utf8_lossy(&chunk));

                // SSE frames are separated by a blank line ("\n\n").
                while let Some(idx) = buf.find("\n\n") {
                    let frame: String = buf.drain(..idx + 2).collect();
                    if frame_has_event(&frame, &mut cursor) {
                        // Notify the UI loop; if the receiver is gone, stop.
                        if tx.send(()).await.is_err() {
                            return;
                        }
                    }
                }
            }

            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });
}

/// Parse one SSE frame: update `cursor` from the `id:` line and return true if
/// the frame carried a `data:` payload (i.e. a real event vs. a heartbeat).
fn frame_has_event(frame: &str, cursor: &mut Option<String>) -> bool {
    let mut has_data = false;
    for line in frame.lines() {
        if let Some(rest) = line.strip_prefix("id:") {
            *cursor = Some(rest.trim().to_string());
        } else if line.strip_prefix("data:").is_some() {
            has_data = true;
        }
        // 'event:' and ':' comment/keepalive lines are ignored.
    }
    has_data
}

// ---------------------------------------------------------------------------
// Key handling
// ---------------------------------------------------------------------------

async fn handle_key(
    terminal: &mut Tui,
    app: &mut App,
    code: KeyCode,
    mods: KeyModifiers,
) -> Result<()> {
    // Filter input mode captures all keystrokes first.
    if let InputMode::Filter(ref mut query) = app.mode {
        match code {
            KeyCode::Char(c) => query.push(c),
            KeyCode::Backspace => {
                query.pop();
            }
            KeyCode::Enter => {
                app.filter = query.clone();
                app.mode = InputMode::Normal;
                app.recompute_filter();
                app.toast = if app.filter.is_empty() {
                    "filter cleared".to_string()
                } else {
                    format!("filter: {}", app.filter)
                };
            }
            KeyCode::Esc => {
                app.mode = InputMode::Normal;
                app.toast = "filter cancelled".to_string();
            }
            _ => {}
        }
        return Ok(());
    }

    match app.view {
        View::List => handle_list_key(app, code, mods).await,
        View::Diff(_) => handle_diff_key(terminal, app, code).await,
    }
}

async fn handle_list_key(app: &mut App, code: KeyCode, _mods: KeyModifiers) -> Result<()> {
    match code {
        KeyCode::Char('q') | KeyCode::Esc => app.should_quit = true,
        KeyCode::Char('j') | KeyCode::Down => app.select_next(),
        KeyCode::Char('k') | KeyCode::Up => app.select_prev(),
        KeyCode::Char('g') => app.select_first(),
        KeyCode::Char('G') => app.select_last(),
        KeyCode::Char('/') => {
            app.mode = InputMode::Filter(app.filter.clone());
        }
        KeyCode::Char('r') => {
            app.toast = "refreshing...".to_string();
            app.full_refresh().await;
            app.toast = format!("refreshed ({} resources)", app.records.len());
        }
        KeyCode::Char('d') => open_diff(app).await,
        KeyCode::Char('a') => {
            if let Some((kind, id)) = app.selected_record().map(|r| (r.kind.clone(), r.resource_id.clone())) {
                app.toast = match app.forge.apply_one(&kind, &id).await {
                    Ok(msg) => msg,
                    Err(e) => format!("apply failed: {}", e),
                };
                app.refresh_state().await;
            }
        }
        KeyCode::Char('A') => {
            app.toast = match app.forge.apply_all_safe().await {
                Ok(msg) => msg,
                Err(e) => format!("apply all failed: {}", e),
            };
            app.refresh_state().await;
        }
        KeyCode::Char('o') => {
            if let Some((kind, id)) = app.selected_record().map(|r| (r.kind.clone(), r.resource_id.clone())) {
                app.toast = match app.forge.adopt(&kind, &id).await {
                    Ok(msg) => msg,
                    Err(e) => format!("adopt failed: {}", e),
                };
                app.refresh_state().await;
            }
        }
        KeyCode::Char('i') => {
            if let Some((kind, id)) = app.selected_record().map(|r| (r.kind.clone(), r.resource_id.clone())) {
                app.toast = match app.forge.ignore(&kind, &id).await {
                    Ok(msg) => msg,
                    Err(e) => format!("ignore failed: {}", e),
                };
                app.refresh_state().await;
            }
        }
        _ => {}
    }
    Ok(())
}

/// Fetch /diff for the selected row and switch to the diff view.
async fn open_diff(app: &mut App) {
    let Some((kind, id)) = app
        .selected_record()
        .map(|r| (r.kind.clone(), r.resource_id.clone()))
    else {
        app.toast = "no resource selected".to_string();
        return;
    };

    match app.forge.diff(&kind, &id).await {
        Ok(d) => {
            app.view = View::Diff(DiffState {
                kind: d.kind,
                id: d.id,
                status: d.status,
                declared: d.declared,
                observed: d.observed,
            });
        }
        Err(e) => app.toast = format!("diff failed: {}", e),
    }
}

async fn handle_diff_key(terminal: &mut Tui, app: &mut App, code: KeyCode) -> Result<()> {
    // Pull kind/id/status out of the active diff state without holding a borrow.
    let (kind, id) = match &app.view {
        View::Diff(d) => (d.kind.clone(), d.id.clone()),
        _ => return Ok(()),
    };

    match code {
        KeyCode::Char('q') | KeyCode::Esc => {
            app.view = View::List;
        }
        KeyCode::Char('a') => {
            app.toast = match app.forge.apply_one(&kind, &id).await {
                Ok(msg) => msg,
                Err(e) => format!("apply failed: {}", e),
            };
            // Reload the diff so the view reflects the new state.
            reload_diff(app, &kind, &id).await;
        }
        KeyCode::Char('o') => {
            // Overwrite-decl-from-observed re-authors the declaration via /adopt.
            app.toast = match app.forge.adopt(&kind, &id).await {
                Ok(msg) => msg,
                Err(e) => format!("overwrite failed: {}", e),
            };
            reload_diff(app, &kind, &id).await;
        }
        KeyCode::Char('e') => {
            edit_declaration(terminal, app, &kind, &id).await?;
        }
        _ => {}
    }
    Ok(())
}

/// Re-fetch /diff after a mutating action so the diff view stays current.
async fn reload_diff(app: &mut App, kind: &str, id: &str) {
    match app.forge.diff(kind, id).await {
        Ok(d) => {
            app.view = View::Diff(DiffState {
                kind: d.kind,
                id: d.id,
                status: d.status,
                declared: d.declared,
                observed: d.observed,
            });
        }
        Err(e) => app.toast = format!("diff reload failed: {}", e),
    }
}

/// `e` in diff view: look up the declaration path, then open it in $EDITOR
/// (fallback `vi`). The terminal is fully suspended for the editor and restored
/// afterward. If the resource has no declaration, toast and do nothing.
async fn edit_declaration(terminal: &mut Tui, app: &mut App, kind: &str, id: &str) -> Result<()> {
    let path = match app.forge.decl_path(kind, id).await {
        Ok(Some(p)) => p,
        Ok(None) => {
            app.toast = "no declaration — adopt first".to_string();
            return Ok(());
        }
        Err(e) => {
            app.toast = format!("decl-path failed: {}", e);
            return Ok(());
        }
    };

    let editor = std::env::var("EDITOR").unwrap_or_else(|_| "vi".to_string());
    let status = suspend_terminal(terminal, || {
        std::process::Command::new(&editor).arg(&path).status()
    })?;

    match status {
        Ok(s) if s.success() => app.toast = format!("edited {}", path),
        Ok(s) => app.toast = format!("editor exited with {}", s),
        Err(e) => app.toast = format!("failed to launch editor: {}", e),
    }

    // Refresh after editing so any declaration change is reflected.
    app.full_refresh().await;
    reload_diff(app, kind, id).await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn draw(f: &mut Frame, app: &mut App) {
    match &app.view {
        View::List => draw_list(f, app),
        View::Diff(_) => draw_diff(f, app),
    }
}

fn draw_list(f: &mut Frame, app: &mut App) {
    // Vertical layout: header (1) | table (rest) | toast (1) | legend (1).
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(1),
            Constraint::Length(1),
            Constraint::Length(1),
        ])
        .split(f.area());

    draw_header(f, app, chunks[0]);
    draw_table(f, app, chunks[1]);
    draw_toast(f, app, chunks[2]);
    draw_legend(f, chunks[3]);
}

fn draw_header(f: &mut Frame, app: &App, area: Rect) {
    // Counts by category for the title line.
    let total = app.records.len();
    let drifted = app
        .records
        .iter()
        .filter(|r| matches!(r.status.as_str(), "drifted" | "new" | "missing" | "prune"))
        .count();
    let unmanaged = app
        .records
        .iter()
        .filter(|r| r.status == "unmanaged")
        .count();
    let conflict = app
        .records
        .iter()
        .filter(|r| r.status == "conflict")
        .count();

    let mut spans = vec![
        Span::styled(
            format!(" host: {} ", app.forge.host),
            Style::default().add_modifier(Modifier::BOLD),
        ),
        Span::raw(format!("| total {} ", total)),
        Span::styled(format!("| drifted {} ", drifted), Style::default().fg(Color::Yellow)),
        Span::styled(format!("| unmanaged {} ", unmanaged), Style::default().fg(Color::Blue)),
    ];
    if conflict > 0 {
        spans.push(Span::styled(
            format!("| conflict {} ", conflict),
            Style::default().fg(Color::Red),
        ));
    }
    if !app.filter.is_empty() {
        spans.push(Span::styled(
            format!("| filter \"{}\" ", app.filter),
            Style::default().fg(Color::Cyan),
        ));
    }

    let block = Block::default().borders(Borders::ALL).title(" Forge ");
    let para = Paragraph::new(Line::from(spans)).block(block);
    f.render_widget(para, area);
}

fn draw_table(f: &mut Frame, app: &mut App, area: Rect) {
    let header = Row::new(vec![
        Cell::from("STATUS"),
        Cell::from("KIND"),
        Cell::from("ID"),
    ])
    .style(Style::default().add_modifier(Modifier::BOLD))
    .height(1);

    let rows: Vec<Row> = app
        .filtered
        .iter()
        .filter_map(|&i| app.records.get(i))
        .map(|r| {
            Row::new(vec![
                Cell::from(r.status.clone())
                    .style(Style::default().fg(status_color(&r.status))),
                Cell::from(r.kind.clone()),
                Cell::from(r.resource_id.clone()),
            ])
        })
        .collect();

    let widths = [
        Constraint::Length(12),
        Constraint::Length(20),
        Constraint::Min(20),
    ];

    let table = Table::new(rows, widths)
        .header(header)
        .block(Block::default().borders(Borders::ALL))
        .row_highlight_style(
            Style::default()
                .add_modifier(Modifier::REVERSED | Modifier::BOLD),
        )
        .highlight_symbol("> ");

    f.render_stateful_widget(table, area, &mut app.table_state);
}

fn draw_toast(f: &mut Frame, app: &App, area: Rect) {
    let para = Paragraph::new(Line::from(Span::styled(
        format!(" {}", app.toast),
        Style::default().fg(Color::Cyan),
    )));
    f.render_widget(para, area);
}

fn draw_legend(f: &mut Frame, area: Rect) {
    let legend = " j/k move  /:filter  d:diff  a:apply  A:apply-all  o:adopt  i:ignore  r:refresh  q:quit";
    let para = Paragraph::new(Line::from(Span::styled(
        legend,
        Style::default().fg(Color::DarkGray),
    )));
    f.render_widget(para, area);
}

fn draw_diff(f: &mut Frame, app: &App) {
    let View::Diff(d) = &app.view else {
        return;
    };

    // Vertical: title (3) | panes (rest) | legend (1).
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(1),
            Constraint::Length(1),
        ])
        .split(f.area());

    // Title.
    let title = Line::from(vec![
        Span::styled(
            format!(" {}/{} ", d.kind, d.id),
            Style::default().add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("[{}]", d.status),
            Style::default().fg(status_color(&d.status)),
        ),
    ]);
    f.render_widget(
        Paragraph::new(title).block(Block::default().borders(Borders::ALL).title(" Diff ")),
        chunks[0],
    );

    // Side-by-side panes: declared (left) vs observed (right).
    let panes = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(chunks[1]);

    let declared = d.declared.as_deref().unwrap_or("");
    let observed = d.observed.as_deref().unwrap_or("");
    let (left_text, right_text) = build_side_by_side(declared, observed);

    f.render_widget(
        Paragraph::new(left_text)
            .block(Block::default().borders(Borders::ALL).title(" declared "))
            .wrap(Wrap { trim: false }),
        panes[0],
    );
    f.render_widget(
        Paragraph::new(right_text)
            .block(Block::default().borders(Borders::ALL).title(" observed "))
            .wrap(Wrap { trim: false }),
        panes[1],
    );

    let legend = " e:edit  a:apply  o:overwrite-decl  q/Esc:back";
    f.render_widget(
        Paragraph::new(Line::from(Span::styled(
            legend,
            Style::default().fg(Color::DarkGray),
        ))),
        chunks[2],
    );
}

/// Build the two colored text columns for the side-by-side diff. Deletions
/// (lines only in `declared`) are red on the left; insertions (lines only in
/// `observed`) are green on the right; equal lines appear on both, dim.
fn build_side_by_side(declared: &str, observed: &str) -> (Text<'static>, Text<'static>) {
    use similar::{ChangeTag, TextDiff};

    let diff = TextDiff::from_lines(declared, observed);
    let mut left: Vec<Line> = Vec::new();
    let mut right: Vec<Line> = Vec::new();

    for change in diff.iter_all_changes() {
        let value = change.value().trim_end_matches('\n').to_string();
        match change.tag() {
            ChangeTag::Equal => {
                let style = Style::default().fg(Color::Gray);
                left.push(Line::from(Span::styled(value.clone(), style)));
                right.push(Line::from(Span::styled(value, style)));
            }
            ChangeTag::Delete => {
                left.push(Line::from(Span::styled(
                    format!("- {}", value),
                    Style::default().fg(Color::Red),
                )));
                // Keep the columns vertically aligned with a blank placeholder.
                right.push(Line::from(""));
            }
            ChangeTag::Insert => {
                left.push(Line::from(""));
                right.push(Line::from(Span::styled(
                    format!("+ {}", value),
                    Style::default().fg(Color::Green),
                )));
            }
        }
    }

    (Text::from(left), Text::from(right))
}

/// Flush helper kept for parity with forge.rs `Write` usage; unused directly but
/// ensures stdout flushes on suspend paths in some terminals.
#[allow(dead_code)]
fn flush_stdout() {
    let _ = std::io::stdout().flush();
}

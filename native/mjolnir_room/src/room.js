// MIT open-room client. Admission is POST /admit on the configured origin.
// This file does not import the AGPL host. RoomJoin order is reimplemented here.
// One generation owns its camera, peer connections, timers, and sessions.
// Retiring a generation is idempotent and always releases those locally.

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const ROOM_SEG = /^[A-Za-z0-9_-]{1,64}$/;
const SESSION_PATH = /^\/session\/[A-Za-z0-9_-]{1,128}$/;
const PATH_BOUND = 4096;
const DEPTH_BOUND = 32;
const CLEANUP_MS = 2000;

export function classifyRoot(root) {
  if (typeof root !== "string" || root.includes("\\")) return "invalid";
  const parts = root.split("/");
  const ownerOk = (owner) => {
    const bytes = b58decode(owner);
    return owner === owner.trim() && bytes && bytes.length === 32;
  };
  if (parts.length === 3 && parts[0] === "t" && ownerOk(parts[1]) && ROOM_SEG.test(parts[2])) return "protected";
  if (parts.length === 4 && parts[0] === "t" && ownerOk(parts[1]) && parts[2] === "~open" && ROOM_SEG.test(parts[3])) return "open";
  return "invalid";
}

function b58decode(text) {
  if (typeof text !== "string" || text.length === 0) return null;
  let n = 0n;
  for (const ch of text) {
    const i = B58.indexOf(ch);
    if (i < 0) return null;
    n = n * 58n + BigInt(i);
  }
  const out = [];
  while (n > 0n) {
    out.push(Number(n & 255n));
    n >>= 8n;
  }
  out.reverse();
  let pad = 0;
  for (const ch of text) {
    if (ch === "1") pad += 1;
    else break;
  }
  return [...Array(pad).fill(0), ...out];
}

function forbiddenEscape(text) {
  const lower = String(text).toLowerCase();
  return lower.includes("%2f") || lower.includes("%5c") || lower.includes("%2e%2e") || lower.includes("%2e.");
}

const utf8 = new TextEncoder();
const utf8Decode = new TextDecoder("utf-8", { fatal: true });

function percentDecodeOnce(raw) {
  const bytes = utf8.encode(raw);
  const out = [];
  for (let i = 0; i < bytes.length; i += 1) {
    if (bytes[i] !== 0x25) {
      out.push(bytes[i]);
      continue;
    }
    if (i + 2 >= bytes.length) throw new Error("bad-escape");
    const hex = String.fromCharCode(bytes[i + 1], bytes[i + 2]);
    if (!/^[0-9a-fA-F]{2}$/.test(hex)) throw new Error("bad-escape");
    out.push(Number.parseInt(hex, 16));
    i += 2;
  }
  return utf8Decode.decode(new Uint8Array(out));
}

// One UTF-8 decode, matching edge canonical_broadcast. Callers keep this string.
export function canonicalBroadcast(raw, root) {
  if (typeof raw !== "string" || raw.length < 1) return null;
  const rawBytes = utf8.encode(raw);
  if (rawBytes.length > PATH_BOUND || raw.includes("\\") || forbiddenEscape(raw)) return null;
  let decoded;
  try { decoded = percentDecodeOnce(raw); } catch { return null; }
  if (!decoded || decoded.includes("\\") || decoded.includes("%") || forbiddenEscape(decoded)) return null;
  const parts = decoded.split("/");
  if (parts.some((part) => part.length === 0 || part === "." || part === "..")) return null;
  const full = root ? `${root}/${decoded}` : decoded;
  if (utf8.encode(full).length > PATH_BOUND || full.split("/").length > DEPTH_BOUND) return null;
  return decoded;
}

export function validBroadcast(raw, root) {
  return canonicalBroadcast(raw, root) !== null;
}

export function compareAdmission(expectedRoot, asked, mint, admitted) {
  if (!mint || typeof mint.token !== "string" || mint.token.length === 0) return { ok: false, error: "no_token" };
  if (!admitted || admitted.token !== mint.token || typeof admitted.root !== "string") {
    return { ok: false, error: "unauthenticated_identity" };
  }
  if (expectedRoot !== admitted.root) return { ok: false, error: "unexpected_root" };
  if (mint.root !== admitted.root) return { ok: false, error: "response_root_mismatch" };
  const klass = classifyRoot(admitted.root);
  if (klass !== "open" && klass !== "protected") return { ok: false, error: "invalid_root" };
  if (klass === "protected" && (mint.kind === undefined || mint.kind === null)) {
    // omission means protected
  } else if (mint.kind !== klass) {
    return { ok: false, error: "kind_mismatch" };
  }
  if (asked !== klass) return { ok: false, error: asked === "open" ? "open_refused" : "protected_refused" };
  return { ok: true, kind: klass, root: admitted.root };
}

const KNOWN = new Set(["room_not_open", "unexpected_root", "forbidden", "bad_token", "no_token", "not_started", "codec_unavailable", "setup_failed"]);

function gatewayError(status, body) {
  const code = body && typeof body.error === "string" ? body.error : "";
  if (KNOWN.has(code)) return code;
  if (status === 0) return "setup_failed";
  return "unauthenticated_identity";
}

function roomName(root) {
  const parts = root.split("/");
  return parts[parts.length - 1];
}

function mediaUrl(origin, kind, root, broadcast) {
  const room = encodeURIComponent(roomName(root));
  const path = broadcast.split("/").map(encodeURIComponent).join("/");
  return `${origin}/${kind}/${room}/${path}`;
}

function configuredOrigin(value) {
  let url;
  try { url = new URL(value); } catch { return null; }
  if (url.username || url.password || url.search || url.hash || url.pathname !== "/") return null;
  const loopback = url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "::1";
  if (url.protocol === "https:") return url.origin;
  if (url.protocol === "http:" && loopback) return url.origin;
  return null;
}

const trackOwners = new WeakMap();

function retainTracks(tracks) {
  return (tracks || []).map((track) => {
    trackOwners.set(track, (trackOwners.get(track) || 0) + 1);
    let released = false;
    return {
      id: track.id,
      kind: track.kind,
      get readyState() { return track.readyState; },
      raw: track,
      stop() {
        if (released) return;
        released = true;
        const left = (trackOwners.get(track) || 1) - 1;
        if (left <= 0) {
          trackOwners.delete(track);
          try { track.stop(); } catch { /* already ended */ }
        } else {
          trackOwners.set(track, left);
        }
      },
    };
  });
}

function stopTracks(tracks) {
  for (const track of tracks || []) {
    try { track.stop(); } catch { /* already ended */ }
  }
}

function snapshotMint(mint) {
  return {
    token: mint && mint.token,
    root: mint && mint.root,
    kind: mint && mint.kind,
    expectedRoot: mint && mint.expectedRoot,
    selfPath: mint && mint.selfPath,
    peerPaths: mint && Array.isArray(mint.peerPaths) ? mint.peerPaths.slice() : [],
    retryMs: mint && mint.retryMs,
  };
}

export function createRoom(deps) {
  const origin = configuredOrigin(deps && deps.origin);
  if (!origin) throw new Error("configured origin required");
  const fetchImpl = deps.fetch;
  const now = deps.now || (() => Date.now());
  const schedule = deps.schedule || ((fn, ms) => setTimeout(fn, ms));
  const clear = deps.clear || ((handle) => clearTimeout(handle));
  let seq = 0;
  let incumbent = null;
  let candidate = null;
  const deletes = [];

  function freshExp(exp) {
    return Number.isFinite(exp) && exp > Math.floor(now() / 1000);
  }

  function notify() {
    if (deps.onUpdate) deps.onUpdate();
  }

  function showLocal(gen) {
    if (!deps.onLocal) return;
    if (incumbent === gen && gen.stream) deps.onLocal(gen.stream, gen.id);
  }

  function hideLocal(gen) {
    if (deps.onLocal && gen.shown) deps.onLocal(null, gen.id);
    gen.shown = false;
  }

  function trusted(response) {
    if (!response || response.redirected) return false;
    if (!response.url) return true;
    try { return new URL(response.url, origin).origin === origin; } catch { return false; }
  }

  async function request(url, init) {
    return fetchImpl(url, {
      ...init,
      redirect: "error",
      referrerPolicy: "no-referrer",
      headers: init.headers,
    });
  }

  async function postAdmit(mint, operation, broadcast, attempt) {
    let response;
    try {
      response = await request(`${origin}/admit`, {
        method: "POST",
        cache: "no-store",
        headers: {
          authorization: `Bearer ${mint.token}`,
          "content-type": "application/json",
          "x-mjolnir-root": mint.expectedRoot,
        },
        body: JSON.stringify({ operation, broadcast }),
      });
    } catch {
      return { ok: false, error: "setup_failed" };
    }
    if (!trusted(response)) return { ok: false, error: "setup_failed" };
    const cache = response.headers.get("cache-control") || "";
    let body = {};
    try { body = await response.json(); } catch { body = {}; }
    if (!response.ok) return { ok: false, error: gatewayError(response.status, body) };
    if (!/\bno-store\b/.test(cache)) return { ok: false, error: "unauthenticated_identity" };
    if (body.operation !== operation || body.broadcast !== broadcast) return { ok: false, error: "response_mismatch" };
    const exp = Number(body.exp);
    const compared = compareAdmission(mint.expectedRoot, "open", mint, { token: mint.token, root: body.root });
    if (!compared.ok) return compared;
    if (!freshExp(exp)) return { ok: false, error: "bad_token" };
    return { ok: true, token: mint.token, root: body.root, operation, broadcast, attempt, exp };
  }

  function validate(mint) {
    if (!mint || typeof mint.token !== "string" || mint.token.length === 0) return { ok: false, error: "no_token" };
    if (!validBroadcast(mint.selfPath, mint.expectedRoot)) return { ok: false, error: "bad_request" };
    if (!Array.isArray(mint.peerPaths) || mint.peerPaths.length > 7) return { ok: false, error: "bad_request" };
    if (mint.peerPaths.some((path) => !validBroadcast(path, mint.expectedRoot))) return { ok: false, error: "bad_request" };
    if (!Number.isFinite(mint.retryMs) || mint.retryMs < 1000 || mint.retryMs > 30000) return { ok: false, error: "bad_request" };
    if (classifyRoot(mint.expectedRoot) === "invalid") return { ok: false, error: "invalid_root" };
    return { ok: true };
  }

  function generation(mint) {
    seq += 1;
    return {
      id: seq,
      mint,
      exp: 0,
      retired: false,
      committed: false,
      shown: false,
      tracks: [],
      stream: null,
      pcs: [],
      sessions: [],
      timers: [],
      cancels: [],
      peerState: {},
      admissions: new Map(),
    };
  }

  function settleOnRetire(gen) {
    let finish = () => {};
    const promise = new Promise((resolve) => {
      finish = (value) => {
        finish = () => {};
        resolve(value);
      };
    });
    gen.cancels.push(() => finish("retired"));
    return { promise, finish };
  }

  function ownTimer(gen, fn, ms) {
    const handle = schedule(() => {
      if (gen.retired) return;
      fn();
    }, ms);
    gen.timers.push(handle);
    return handle;
  }

  function ownershipError(gen) {
    if (!gen || gen.retired || (candidate !== gen && incumbent !== gen)) return "stale";
    if (!freshExp(gen.exp)) return "bad_token";
    return null;
  }

  function owns(gen) {
    return ownershipError(gen) === null;
  }

  function releaseLocal(gen) {
    if (!gen || gen.retired) return;
    gen.retired = true;
    if (incumbent === gen) incumbent = null;
    if (candidate === gen) candidate = null;
    const cancels = gen.cancels.splice(0);
    for (const cancel of cancels) {
      try { cancel(); } catch { /* already settled */ }
    }
    for (const handle of gen.timers) clear(handle);
    gen.timers = [];
    for (const pc of gen.pcs) {
      try { pc.close(); } catch { /* closed */ }
    }
    stopTracks(gen.tracks);
    hideLocal(gen);
    notify();
  }

  async function deleteOne(session) {
    if (!session || !SESSION_PATH.test(session.location)) {
      deletes.push({ ok: false, reason: "foreign_location" });
      return { ok: false, reason: "foreign_location" };
    }
    const ctrl = new AbortController();
    let timer;
    const timeout = new Promise((resolve) => {
      timer = schedule(() => {
        try { ctrl.abort(); } catch { /* already finished */ }
        resolve({ ok: false, reason: "cleanup_timeout" });
      }, CLEANUP_MS);
    });
    const attempt = (async () => {
      try {
        const response = await request(`${origin}${session.location}`, {
          method: "DELETE",
          signal: ctrl.signal,
          headers: { authorization: `Bearer ${session.token}`, "x-mjolnir-root": session.root },
        });
        if (!trusted(response)) {
          const outcome = { ok: false, reason: "redirected" };
          deletes.push(outcome);
          return outcome;
        }
        const outcome = { ok: response.ok || response.status === 404, status: response.status };
        deletes.push(outcome);
        return outcome;
      } catch {
        const outcome = { ok: false, reason: "cleanup_timeout" };
        deletes.push(outcome);
        return outcome;
      }
    })();
    const outcome = await Promise.race([attempt, timeout]);
    if (timer) clear(timer);
    return outcome;
  }

  function deleteOwned(gen) {
    const sessions = gen.sessions.splice(0);
    return Promise.all(sessions.map((session) => deleteOne(session)));
  }

  function closePc(gen, pc) {
    try { pc.close(); } catch { /* closed */ }
    gen.pcs = gen.pcs.filter((item) => item !== pc);
  }

  async function waitIce(gen, pc, budgetMs) {
    if (!owns(gen)) return false;
    if (pc.connectionState === "connected") return true;
    const gate = settleOnRetire(gen);
    ownTimer(gen, () => gate.finish(pc.connectionState === "connected" && owns(gen)), budgetMs);
    const onState = () => {
      if (pc.connectionState === "connected" && owns(gen)) gate.finish(true);
      if (pc.connectionState === "failed" || pc.connectionState === "closed") gate.finish(false);
    };
    pc.addEventListener("connectionstatechange", onState);
    const ice = await gate.promise;
    if (pc.removeEventListener) pc.removeEventListener("connectionstatechange", onState);
    return ice === true;
  }

  async function negotiate(gen, kind, broadcast, admission) {
    if (!owns(gen)) return { ok: false, error: "stale" };
    const bound = gen.admissions.get(`${admission.operation}:${broadcast}`);
    if (!bound || bound.attempt !== admission.attempt || bound.token !== admission.token || bound.root !== admission.root) {
      return { ok: false, error: "stale" };
    }
    let pc;
    try {
      pc = deps.createPeerConnection();
    } catch {
      return { ok: false, error: "setup_failed" };
    }
    gen.pcs.push(pc);
    const Stream = deps.MediaStream || globalThis.MediaStream || MediaStreamShim;
    let stream;
    try { stream = new Stream(); } catch {
      return { ok: false, error: "setup_failed", pc };
    }
    try {
      if (kind === "whip") {
        for (const track of gen.tracks) {
          const raw = track.raw || track;
          pc.addTrack(raw, stream);
          if (stream.addTrack) stream.addTrack(raw);
        }
      } else {
        pc.addTransceiver("video", { direction: "recvonly" });
        pc.addTransceiver("audio", { direction: "recvonly" });
        const attempt = gen.peerState[broadcast] && gen.peerState[broadcast].attempt;
        pc.ontrack = (event) => {
          const state = gen.peerState[broadcast];
          if (incumbent !== gen || !state || state.attempt !== attempt) return;
          if (deps.onRemoteTrack) deps.onRemoteTrack(broadcast, attempt, event, gen.id);
        };
      }
      const offer = await pc.createOffer();
      const afterOffer = ownershipError(gen);
      if (afterOffer) return { ok: false, error: afterOffer, pc };
      await pc.setLocalDescription(offer);
      if (pc.iceGatheringState && pc.iceGatheringState !== "complete") {
        const gate = settleOnRetire(gen);
        const timer = ownTimer(gen, () => gate.finish("timeout"), 1500);
        const onIce = () => {
          if (pc.iceGatheringState === "complete") {
            clear(timer);
            gate.finish("complete");
          }
        };
        pc.addEventListener("icegatheringstatechange", onIce);
        await gate.promise;
        if (pc.removeEventListener) pc.removeEventListener("icegatheringstatechange", onIce);
      }
      const beforePost = ownershipError(gen);
      if (beforePost) return { ok: false, error: beforePost, pc };
      const response = await request(mediaUrl(origin, kind, admission.root, broadcast), {
        method: "POST",
        headers: {
          authorization: `Bearer ${admission.token}`,
          "content-type": "application/sdp",
          "x-mjolnir-root": admission.root,
        },
        body: pc.localDescription.sdp,
      });
      if (!trusted(response)) return { ok: false, error: "setup_failed", pc };
      const location = response.headers.get("location") || "";
      let session = null;
      if (response.status === 201) {
        if (!SESSION_PATH.test(location)) return { ok: false, error: "setup_failed", pc };
        session = { location, token: admission.token, root: admission.root };
        gen.sessions.push(session);
      }
      const afterHeaders = ownershipError(gen);
      if (afterHeaders) return { ok: false, error: afterHeaders, pc, session };
      const bodyGate = settleOnRetire(gen);
      const bodyTimer = ownTimer(gen, () => bodyGate.finish("timeout"),
        Math.max(0, Math.min(5000, admission.exp * 1000 - now())));
      Promise.resolve().then(() => response.text()).then(
        (text) => bodyGate.finish({ text }),
        () => bodyGate.finish("failed"));
      const body = await bodyGate.promise;
      clear(bodyTimer);
      if (!body || typeof body !== "object") {
        return { ok: false, error: ownershipError(gen) || "setup_failed", pc, session };
      }
      const text = body.text;
      if (!owns(gen)) return { ok: false, error: "stale", pc, session };
      const parsed = safeJson(text);
      const fail = (error) => ({ ok: false, error, status: response.status, pc, session });
      if (response.status === 409 && parsed.error !== "codec_unavailable") return fail("not_started");
      if (response.status === 403) return fail(gatewayError(403, parsed));
      if (response.status !== 201) {
        if (parsed.error === "codec_unavailable" || KNOWN.has(parsed.error)) return fail(parsed.error);
        return fail("setup_failed");
      }
      try {
        await pc.setRemoteDescription({ type: "answer", sdp: text });
      } catch {
        return { ok: false, error: "setup_failed", pc, session };
      }
      if (!owns(gen)) return { ok: false, error: "stale", pc, session };
      const budget = Math.max(0, Math.min(10_000, admission.exp * 1000 - now()));
      const ice = await waitIce(gen, pc, budget);
      if (!ice || !owns(gen)) return { ok: false, error: gen.retired ? "stale" : "setup_failed", pc, session };
      return { ok: true, pc, session };
    } catch {
      return { ok: false, error: "setup_failed", pc };
    }
  }

  function discardAttempt(gen, result) {
    if (result && result.pc) closePc(gen, result.pc);
    if (result && result.session) {
      gen.sessions = gen.sessions.filter((item) => item !== result.session);
      void deleteOne(result.session);
    }
  }

  function armPeerRetry(gen, broadcast, admission, delay) {
    const state = gen.peerState[broadcast];
    if (!state || state.failed || gen.retired || incumbent !== gen) return;
    if (state.timer) return;
    const wait = delay || gen.retryMs;
    state.empty = true;
    state.note = "the other side must publish again";
    state.timer = ownTimer(gen, () => {
      state.timer = null;
      void playPeer(gen, broadcast, admission, Math.min(30_000, wait * 2));
    }, wait);
    notify();
  }

  function watchPeer(gen, broadcast, admission, pc, delay) {
    const state = gen.peerState[broadcast];
    state.pc = pc;
    state.detached = false;
    const onDown = () => {
      if (incumbent !== gen || state.pc !== pc || state.detached) return;
      if (pc.connectionState !== "failed" && pc.connectionState !== "disconnected") return;
      state.detached = true;
      state.empty = true;
      state.note = "the other side must publish again";
      closePc(gen, pc);
      if (state.session) {
        const session = state.session;
        state.session = null;
        gen.sessions = gen.sessions.filter((item) => item !== session);
        void deleteOne(session);
      }
      state.pc = null;
      if (state.timer) return;
      const wait = delay || gen.retryMs;
      state.timer = ownTimer(gen, () => {
        state.timer = null;
        void playPeer(gen, broadcast, admission, Math.min(30_000, wait * 2));
      }, wait);
      notify();
    };
    pc.addEventListener("connectionstatechange", onDown);
  }

  async function playPeer(gen, broadcast, admission, delay) {
    if (gen.retired || incumbent !== gen) return;
    const state = gen.peerState[broadcast] || (gen.peerState[broadcast] = { failed: false });
    if (state.failed || state.inflight) return;
    state.inflight = true;
    state.admission = admission;
    state.attempt = (state.attempt || 0) + 1;
    const result = await negotiate(gen, "whep", broadcast, admission);
    state.inflight = false;
    if (gen.retired || incumbent !== gen) {
      discardAttempt(gen, result);
      return;
    }
    if (result.ok) {
      state.empty = false;
      state.detached = false;
      state.session = result.session;
      state.pc = result.pc;
      watchPeer(gen, broadcast, admission, result.pc, delay);
      if (deps.onRemote) deps.onRemote(broadcast, state.attempt, result.pc);
      notify();
      return;
    }
    discardAttempt(gen, result);
    if (result.error === "not_started" || result.error === "setup_failed") {
      armPeerRetry(gen, broadcast, admission, delay || gen.retryMs);
      return;
    }
    state.failed = true;
    state.error = result.error;
    state.empty = true;
    notify();
  }

  function failGen(gen, error) {
    const current = candidate === gen;
    releaseLocal(gen);
    void deleteOwned(gen);
    if (current) notify();
    return { ok: false, error: error || "setup_failed" };
  }

  async function begin(mintIn, mode) {
    const mint = snapshotMint(mintIn);
    const shape = validate(mint);
    if (!shape.ok) return shape;
    if (mode === "join" && (incumbent || candidate)) return { ok: false, error: "busy" };
    if (candidate && !candidate.committed) {
      const previousCandidate = candidate;
      releaseLocal(previousCandidate);
      void deleteOwned(previousCandidate);
    }
    const attempt = seq + 1;
    const gen = generation(mint);
    candidate = gen;
    const selfPath = canonicalBroadcast(mint.selfPath, mint.expectedRoot);
    const peerPaths = mint.peerPaths.map((path) => canonicalBroadcast(path, mint.expectedRoot));
    if (!selfPath || peerPaths.some((path) => !path)) return failGen(gen, "bad_request");
    mint.selfPath = selfPath;
    mint.peerPaths = peerPaths;
    const intents = [{ operation: "publish", broadcast: mint.selfPath }, ...mint.peerPaths.map((broadcast) => ({ operation: "subscribe", broadcast }))];
    for (const intent of intents) {
      if (candidate !== gen || gen.retired) return { ok: false, error: "stale" };
      const admitted = await postAdmit(mint, intent.operation, intent.broadcast, attempt);
      if (candidate !== gen || gen.retired) return failGen(gen, "stale");
      if (!admitted.ok) return failGen(gen, admitted.error);
      gen.admissions.set(`${intent.operation}:${intent.broadcast}`, admitted);
      gen.exp = gen.exp ? Math.min(gen.exp, admitted.exp) : admitted.exp;
    }
    const beforeCamera = ownershipError(gen);
    if (beforeCamera) return failGen(gen, beforeCamera);
    if (deps.onBeforeCamera) deps.onBeforeCamera();
    let stream;
    try {
      stream = await deps.getUserMedia({ video: true, audio: true });
    } catch {
      return failGen(gen, "setup_failed");
    }
    gen.tracks = retainTracks(stream.getTracks());
    gen.stream = stream;
    const afterCamera = ownershipError(gen);
    if (afterCamera) {
      stopTracks(gen.tracks);
      return failGen(gen, afterCamera);
    }
    const publish = gen.admissions.get(`publish:${mint.selfPath}`);
    let whip;
    try {
      whip = await negotiate(gen, "whip", mint.selfPath, publish);
    } catch {
      return failGen(gen, "setup_failed");
    }
    if (!whip.ok) {
      discardAttempt(gen, whip);
      return failGen(gen, whip.error || "setup_failed");
    }
    if (!owns(gen)) return failGen(gen, "stale");
    gen.committed = true;
    const previous = incumbent;
    incumbent = gen;
    candidate = null;
    gen.shown = true;
    showLocal(gen);
    const expMs = Math.max(0, gen.exp * 1000 - now());
    ownTimer(gen, () => {
      if (incumbent === gen) drop(gen);
    }, expMs);
    if (previous) {
      releaseLocal(previous);
      void deleteOwned(previous);
    }
    notify();
    await Promise.all(mint.peerPaths.map((broadcast) => {
      const admission = gen.admissions.get(`subscribe:${broadcast}`);
      return playPeer(gen, broadcast, admission, mint.retryMs);
    }));
    if (incumbent !== gen) return { ok: false, error: "stale" };
    return { ok: true, generation: gen.id };
  }

  function drop(gen) {
    releaseLocal(gen);
    void deleteOwned(gen);
    notify();
  }

  return {
    join: (mint) => begin(mint, "join"),
    replace: (mint) => begin(mint, "replace"),
    renew: (mint) => begin(mint, "renew"),
    teardown: async () => {
      const pending = [];
      if (candidate) pending.push(candidate);
      if (incumbent && incumbent !== candidate) pending.push(incumbent);
      for (const gen of pending) releaseLocal(gen);
      const cleanup = Promise.all(pending.map((gen) => deleteOwned(gen)));
      let timeoutHandle;
      const timeout = new Promise((resolve) => {
        timeoutHandle = schedule(() => resolve({ ok: false, error: "cleanup_timeout", released: true }), CLEANUP_MS);
      });
      const settled = await Promise.race([
        cleanup.then((results) => {
          const flat = results.flat();
          const failed = flat.some((item) => item && item.ok === false);
          if (timeoutHandle) clear(timeoutHandle);
          return { ok: !failed, released: true, error: failed ? "cleanup_timeout" : undefined, cleanup: failed ? "failed" : "done" };
        }),
        timeout,
      ]);
      notify();
      return settled;
    },
    status: () => ({
      incumbent: incumbent && incumbent.id,
      candidate: candidate && candidate.id,
      tracks: incumbent ? incumbent.tracks.length : 0,
      pcs: incumbent ? incumbent.pcs.filter((pc) => !pc.closed).length : 0,
      sessions: incumbent ? incumbent.sessions.map((s) => s.location) : [],
      peers: incumbent ? incumbent.peerState : {},
      deletes: deletes.slice(),
      notice: "This room is open. The host can read the media.",
    }),
  };
}

function safeJson(text) {
  try { return JSON.parse(text); } catch { return {}; }
}

class MediaStreamShim {
  constructor() { this.tracks = []; }
  addTrack(track) { this.tracks.push(track); }
  getTracks() { return this.tracks; }
}

// MIT open-room client. Admission is POST /admit on the configured origin.
// This file does not import the AGPL host. RoomJoin order is reimplemented here.

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const ROOM_SEG = /^[A-Za-z0-9_-]{1,64}$/;
const SESSION_PATH = /^\/session\/[A-Za-z0-9_-]{1,128}$/;

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

export function validBroadcast(path) {
  if (typeof path !== "string" || path.length < 1 || path.length > 512) return false;
  if (/[\\?#]/.test(path) || path.includes("://") || path.startsWith("/") || path.startsWith(".")) return false;
  return path.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
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

function stopTracks(tracks) {
  for (const track of tracks) {
    try { track.stop(); } catch { /* already ended */ }
  }
}

export function createRoom(deps) {
  if (!deps || typeof deps.origin !== "string" || !/^https?:\/\/[^/]+$/.test(deps.origin)) {
    throw new Error("configured origin required");
  }
  const origin = deps.origin;
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

  async function postAdmit(mint, operation, broadcast, attempt) {
    let response;
    try {
      response = await fetchImpl(`${origin}/admit`, {
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
    return {
      ok: true,
      token: mint.token,
      root: body.root,
      operation,
      broadcast,
      attempt,
      exp,
    };
  }

  function validate(mint, peerPaths, retryMs) {
    if (!mint || typeof mint.token !== "string" || mint.token.length === 0) return { ok: false, error: "no_token" };
    if (!validBroadcast(mint.selfPath)) return { ok: false, error: "bad_request" };
    if (!Array.isArray(peerPaths) || peerPaths.length > 7) return { ok: false, error: "bad_request" };
    if (peerPaths.some((path) => !validBroadcast(path))) return { ok: false, error: "bad_request" };
    if (!Number.isFinite(retryMs) || retryMs < 1000 || retryMs > 30000) return { ok: false, error: "bad_request" };
    if (classifyRoot(mint.expectedRoot) === "invalid") return { ok: false, error: "invalid_root" };
    return { ok: true };
  }

  function generation(mint, peerPaths, retryMs) {
    seq += 1;
    return {
      id: seq,
      mint,
      peerPaths,
      retryMs,
      exp: 0,
      aborted: false,
      committed: false,
      tracks: [],
      pcs: [],
      sessions: [],
      timers: [],
      peerState: {},
      admissions: new Map(),
    };
  }

  function ownTimer(gen, fn, ms) {
    const handle = schedule(() => {
      if (gen.aborted) return;
      fn();
    }, ms);
    gen.timers.push(handle);
    return handle;
  }

  function release(gen, keepTracks) {
    gen.aborted = true;
    for (const handle of gen.timers) clear(handle);
    gen.timers = [];
    for (const pc of gen.pcs) {
      try { pc.close(); } catch { /* closed */ }
    }
    if (!keepTracks) stopTracks(gen.tracks);
  }

  async function deleteOwned(gen) {
    for (const session of gen.sessions) {
      if (!SESSION_PATH.test(session.location)) {
        deletes.push({ ok: false, reason: "foreign_location" });
        continue;
      }
      try {
        const response = await fetchImpl(`${origin}${session.location}`, {
          method: "DELETE",
          headers: { authorization: `Bearer ${session.token}`, "x-mjolnir-root": session.root },
        });
        deletes.push({ ok: response.ok || response.status === 404, status: response.status });
      } catch {
        deletes.push({ ok: false, reason: "setup_failed" });
      }
    }
    gen.sessions = [];
  }

  async function waitIce(pc, budgetMs) {
    if (pc.connectionState === "connected") return true;
    return new Promise((resolve) => {
      let handle;
      const finish = (ok) => {
        if (handle) clear(handle);
        resolve(ok);
      };
      handle = schedule(() => finish(pc.connectionState === "connected"), budgetMs);
      pc.addEventListener("connectionstatechange", () => {
        if (pc.connectionState === "connected") finish(true);
        if (pc.connectionState === "failed") finish(false);
      });
    });
  }

  async function negotiate(gen, kind, broadcast, admission) {
    if (gen.aborted || candidate !== gen && incumbent !== gen) return { ok: false, error: "stale" };
    if (!freshExp(admission.exp)) return { ok: false, error: "bad_token" };
    const bound = gen.admissions.get(`${admission.operation}:${broadcast}`);
    if (!bound || bound.attempt !== admission.attempt || bound.token !== admission.token || bound.root !== admission.root) {
      return { ok: false, error: "stale" };
    }
    const pc = deps.createPeerConnection();
    gen.pcs.push(pc);
    const Stream = deps.MediaStream || globalThis.MediaStream || MediaStreamShim;
    const stream = new Stream();
    if (kind === "whip") {
      for (const track of gen.tracks) {
        pc.addTrack(track, stream);
        stream.addTrack(track);
      }
    } else {
      pc.addTransceiver("video", { direction: "recvonly" });
      pc.addTransceiver("audio", { direction: "recvonly" });
      pc.ontrack = (event) => {
        if (incumbent !== gen && candidate !== gen) return;
        if (deps.ontrack) deps.ontrack(broadcast, event);
      };
    }
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    if (pc.iceGatheringState && pc.iceGatheringState !== "complete") {
      await new Promise((resolve) => {
        const timer = schedule(() => resolve(), 1500);
        pc.addEventListener("icegatheringstatechange", () => {
          if (pc.iceGatheringState === "complete") {
            clear(timer);
            resolve();
          }
        });
      });
    }
    if (gen.aborted) return { ok: false, error: "stale" };
    let response;
    try {
      response = await fetchImpl(mediaUrl(origin, kind, admission.root, broadcast), {
        method: "POST",
        headers: {
          authorization: `Bearer ${admission.token}`,
          "content-type": "application/sdp",
          "x-mjolnir-root": admission.root,
        },
        body: pc.localDescription.sdp,
      });
    } catch {
      return { ok: false, error: "setup_failed" };
    }
    const text = await response.text();
    const fail = (error, status) => {
      try { pc.close(); } catch { /* closed */ }
      gen.pcs = gen.pcs.filter((item) => item !== pc);
      return { ok: false, error, status };
    };
    const parsed = safeJson(text);
    if (response.status === 409 && parsed.error !== "codec_unavailable") return fail("not_started", 409);
    if (response.status === 403) return fail(gatewayError(403, parsed), 403);
    if (!response.ok) {
      const error = parsed.error === "codec_unavailable" ? "codec_unavailable" : gatewayError(response.status, parsed);
      return fail(error, response.status);
    }
    try {
      await pc.setRemoteDescription({ type: "answer", sdp: text });
    } catch {
      return fail("setup_failed");
    }
    const location = response.headers.get("location") || "";
    if (!SESSION_PATH.test(location)) return fail("setup_failed");
    gen.sessions.push({ location, token: admission.token, root: admission.root });
    const budget = Math.max(0, Math.min(10_000, admission.exp * 1000 - now()));
    const ice = await waitIce(pc, budget);
    if (!ice || gen.aborted || !freshExp(admission.exp)) return fail(gen.aborted ? "stale" : "setup_failed");
    return { ok: true, pc };
  }

  async function playPeer(gen, broadcast, admission, delay) {
    if (gen.aborted || incumbent !== gen) return;
    gen.peerState[broadcast] = gen.peerState[broadcast] || { failed: false };
    if (gen.peerState[broadcast].failed) return;
    const result = await negotiate(gen, "whep", broadcast, admission);
    if (gen.aborted || incumbent !== gen) return;
    if (result.ok) {
      gen.peerState[broadcast].empty = false;
      const pc = result.pc;
      pc.addEventListener("connectionstatechange", () => {
        if (incumbent !== gen) return;
        if (pc.connectionState === "failed" || pc.connectionState === "disconnected") {
          gen.peerState[broadcast].empty = true;
          gen.peerState[broadcast].note = "the other side must publish again";
          const next = Math.min(30_000, (delay || gen.retryMs) * 2);
          ownTimer(gen, () => playPeer(gen, broadcast, admission, next), gen.retryMs);
        }
      });
      return;
    }
    if (result.error === "not_started" || result.error === "setup_failed") {
      gen.peerState[broadcast].empty = true;
      const wait = delay || gen.retryMs;
      ownTimer(gen, () => playPeer(gen, broadcast, admission, Math.min(30_000, wait * 2)), wait);
      return;
    }
    gen.peerState[broadcast].failed = true;
    gen.peerState[broadcast].error = result.error;
    gen.peerState[broadcast].empty = true;
  }

  async function begin(mint, mode) {
    const peerPaths = mint.peerPaths || [];
    const retryMs = mint.retryMs;
    const shape = validate(mint, peerPaths, retryMs);
    if (!shape.ok) return shape;
    if (mode === "join" && (incumbent || candidate)) return { ok: false, error: "busy" };
    const attempt = seq + 1;
    const gen = generation(mint, peerPaths, retryMs);
    if (candidate && !candidate.committed) {
      candidate.aborted = true;
      stopTracks(candidate.tracks);
    }
    candidate = gen;
    const intents = [{ operation: "publish", broadcast: mint.selfPath }, ...peerPaths.map((broadcast) => ({ operation: "subscribe", broadcast }))];
    for (const intent of intents) {
      if (candidate !== gen) return { ok: false, error: "stale" };
      const admitted = await postAdmit(mint, intent.operation, intent.broadcast, attempt);
      if (!admitted.ok) {
        if (candidate === gen) candidate = null;
        release(gen, false);
        return admitted;
      }
      gen.admissions.set(`${intent.operation}:${intent.broadcast}`, admitted);
      gen.exp = admitted.exp;
    }
    if (candidate !== gen) {
      release(gen, false);
      return { ok: false, error: "stale" };
    }
    if (deps.onBeforeCamera) deps.onBeforeCamera();
    let stream;
    try {
      stream = await deps.getUserMedia({ video: true, audio: true });
    } catch {
      if (candidate === gen) candidate = null;
      release(gen, false);
      return { ok: false, error: "setup_failed" };
    }
    gen.tracks = stream.getTracks();
    if (candidate !== gen || gen.aborted) {
      stopTracks(gen.tracks);
      return { ok: false, error: "stale" };
    }
    const publish = gen.admissions.get(`publish:${mint.selfPath}`);
    const whip = await negotiate(gen, "whip", mint.selfPath, publish);
    if (!whip.ok) {
      if (candidate === gen) candidate = null;
      await deleteOwned(gen);
      release(gen, false);
      return { ok: false, error: whip.error || "setup_failed" };
    }
    gen.committed = true;
    const previous = incumbent;
    incumbent = gen;
    candidate = null;
    if (previous) {
      await deleteOwned(previous);
      release(previous, false);
    }
    const expMs = Math.max(0, gen.exp * 1000 - now());
    ownTimer(gen, () => {
      if (incumbent === gen) drop(gen);
    }, expMs);
    await Promise.all(peerPaths.map((broadcast) => {
      const admission = gen.admissions.get(`subscribe:${broadcast}`);
      return playPeer(gen, broadcast, admission, retryMs);
    }));
    return { ok: true, generation: gen.id };
  }

  async function drop(gen) {
    if (incumbent === gen) incumbent = null;
    if (candidate === gen) candidate = null;
    await deleteOwned(gen);
    release(gen, false);
  }

  return {
    join: (mint) => begin(mint, "join"),
    replace: (mint) => begin(mint, "replace"),
    renew: (mint) => begin(mint, "renew"),
    teardown: async () => {
      const current = candidate;
      const live = incumbent;
      if (current) await drop(current);
      if (live) await drop(live);
      return { ok: true };
    },
    status: () => ({
      incumbent: incumbent && incumbent.id,
      candidate: candidate && candidate.id,
      tracks: incumbent ? incumbent.tracks.length : 0,
      pcs: incumbent ? incumbent.pcs.length : 0,
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

import assert from "node:assert/strict";
import test from "node:test";
import { compareAdmission, createRoom, validBroadcast } from "../src/room.js";

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
function b58encode(bytes) {
  let n = 0n;
  for (const b of bytes) n = (n << 8n) + BigInt(b);
  let text = "";
  while (n > 0n) {
    text = B58[Number(n % 58n)] + text;
    n /= 58n;
  }
  return text;
}
const owner = b58encode(new Uint8Array(32).fill(9));
const openRoot = `t/${owner}/~open/r1`;
const protectedRoot = `t/${owner}/r1`;

function mint(extra = {}) {
  return {
    token: "tok-alice",
    root: openRoot,
    kind: "open",
    expectedRoot: openRoot,
    selfPath: "alice/cam",
    peerPaths: ["bob/cam"],
    retryMs: 1000,
    ...extra,
  };
}

function world(behavior = {}) {
  const calls = [];
  const timers = [];
  const gum = [];
  const pcs = [];
  let cameras = 0;
  let whips = 0;
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method, body: init.body, auth: init.headers && init.headers.authorization });
    if (behavior.network) throw new Error("down");
    if (String(url).endsWith("/admit")) {
      const body = JSON.parse(init.body);
      const spec = (behavior.admit || {})[`${body.operation}:${body.broadcast}`] || {};
      if (spec.status) return http(spec.status, spec.body || { error: spec.error }, spec.cache ?? "no-store");
      return http(200, {
        root: spec.root || openRoot,
        exp: spec.exp || 1_800_000_000,
        operation: body.operation,
        broadcast: spec.broadcast || body.broadcast,
      }, spec.cache ?? "no-store");
    }
    if (String(url).includes("/whip/")) {
      whips += 1;
      const spec = whips > 1 && behavior.secondWhip ? behavior.secondWhip : (behavior.whip || { status: 201 });
      return sdp(spec);
    }
    if (String(url).includes("/whep/")) return sdp(behavior.whep || { status: 201 });
    if (init.method === "DELETE") return http(behavior.deleteStatus || 204, {}, "no-store");
    throw new Error(url);
  };
  const room = createRoom({
    origin: "http://127.0.0.1:18447",
    fetch: fetchImpl,
    now: () => behavior.now || 1_700_000_000_000,
    schedule(fn, ms) {
      const item = { fn, ms, cleared: false };
      timers.push(item);
      return item;
    },
    clear(item) { item.cleared = true; },
    async getUserMedia() {
      cameras += 1;
      const track = { stopped: false, stop() { track.stopped = true; } };
      gum.push(track);
      if (cameras === 1 && behavior.holdFirst) await behavior.holdFirst;
      return { getTracks: () => [track] };
    },
    createPeerConnection() {
      const pc = {
        connectionState: "new",
        localDescription: null,
        closed: false,
        listeners: [],
        addEventListener(_type, fn) { pc.listeners.push(fn); },
        addTrack() {},
        addTransceiver() {},
        async createOffer() { return { type: "offer", sdp: "v=0\r\n" }; },
        async setLocalDescription(desc) { pc.localDescription = desc; },
        async setRemoteDescription() {
          if (behavior.remoteFail) throw new Error("remote");
          if (behavior.ice === "timeout") return;
          pc.connectionState = "connected";
          for (const fn of pc.listeners) fn();
        },
        close() { pc.closed = true; },
      };
      pcs.push(pc);
      return pc;
    },
  });
  return {
    room, calls, timers, gum, pcs,
    releaseCamera() {},
  };
}

function http(status, body, cache) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (name) => (name.toLowerCase() === "cache-control" ? cache : "") },
    async json() { return body; },
    async text() { return JSON.stringify(body); },
  };
}
function sdp(spec) {
  const headers = { location: "/session/abc", ...(spec.headers || {}) };
  return {
    ok: spec.status >= 200 && spec.status < 300,
    status: spec.status,
    headers: { get: (name) => headers[name.toLowerCase()] || "" },
    async text() { return spec.body || (spec.status === 201 ? "v=0\r\n" : JSON.stringify({ error: spec.error || "setup_failed" })); },
    async json() { return { error: spec.error }; },
  };
}

test("bad paths and a missing token do not fetch", async () => {
  const h = world();
  assert.equal(validBroadcast("../a"), false);
  assert.equal((await h.room.join(mint({ peerPaths: ["https://x/y"] }))).error, "bad_request");
  assert.equal((await h.room.join(mint({ token: "" }))).error, "no_token");
  assert.equal(h.calls.length, 0);
  assert.equal(h.gum.length, 0);
});

test("typed gateway refusals and kind mismatch skip the camera", async () => {
  const closed = world({ admit: { "publish:alice/cam": { status: 403, error: "room_not_open" } } });
  assert.equal((await closed.room.join(mint())).error, "room_not_open");
  assert.equal(closed.gum.length, 0);
  const wrong = world({ admit: { "publish:alice/cam": { root: protectedRoot } } });
  assert.equal((await wrong.room.join(mint())).error, "unexpected_root");
  assert.equal(wrong.pcs.length, 0);
  assert.equal(compareAdmission(openRoot, "open", { token: "t", root: openRoot }, { token: "t", root: openRoot }).error, "kind_mismatch");
  const omitted = world();
  assert.equal((await omitted.room.join(mint({ kind: undefined }))).error, "kind_mismatch");
  assert.equal(omitted.gum.length, 0);
});

test("expired-on-arrival does not construct a peer connection", async () => {
  const h = world({ admit: { "publish:alice/cam": { exp: 10 } } });
  assert.equal((await h.room.join(mint())).error, "bad_token");
  assert.equal(h.gum.length, 0);
  assert.equal(h.pcs.length, 0);
});

test("a committed join retries not_started and keeps the local track", async () => {
  const h = world({ whep: { status: 409, error: "not_started", headers: { location: "" } } });
  assert.equal((await h.room.join(mint())).ok, true);
  assert.equal(h.room.status().peers["bob/cam"].empty, true);
  assert.equal(h.gum[0].stopped, false);
  assert.equal(h.timers.some((item) => item.ms === 1000), true);
  const before = h.calls.filter((call) => call.url.includes("/whep/")).length;
  h.timers.find((item) => item.ms === 1000).fn();
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(h.calls.filter((call) => call.url.includes("/whep/")).length > before);
});

test("whip refusal stops tracks and peer connections", async () => {
  const h = world({ whip: { status: 403, error: "bad_token", headers: { location: "" } } });
  assert.equal((await h.room.join(mint())).error, "bad_token");
  assert.equal(h.gum.every((track) => track.stopped), true);
  assert.equal(h.pcs.every((pc) => pc.closed), true);
});

test("a failed replacement leaves the incumbent session", async () => {
  const h = world({ secondWhip: { status: 403, error: "forbidden", headers: { location: "" } } });
  assert.equal((await h.room.join(mint({ peerPaths: [] }))).ok, true);
  const before = h.room.status().sessions.slice();
  assert.equal((await h.room.replace(mint({ peerPaths: [] }))).error, "forbidden");
  assert.deepEqual(h.room.status().sessions, before);
  assert.equal(h.room.status().incumbent > 0, true);
});

test("a late camera from the superseded attempt is stopped", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const h = world({ holdFirst: gate });
  const first = h.room.join(mint({ peerPaths: [] }));
  await new Promise((resolve) => setImmediate(resolve));
  const replaced = h.room.replace(mint({ peerPaths: [], token: "tok-next" }));
  await new Promise((resolve) => setImmediate(resolve));
  release();
  const [firstResult, nextResult] = await Promise.all([first, replaced]);
  assert.equal(nextResult.ok, true);
  assert.equal(firstResult.ok, false);
  assert.equal(h.gum[0].stopped, true);
  assert.equal(h.room.status().tracks, 1);
});

test("the previous expiry timer does not close the new generation", async () => {
  const h = world();
  await h.room.join(mint({ peerPaths: [] }));
  const oldTimer = h.timers.at(-1);
  await h.room.replace(mint({ peerPaths: [], token: "tok-next" }));
  const live = h.pcs.filter((pc) => !pc.closed).length;
  oldTimer.fn();
  assert.equal(h.pcs.filter((pc) => !pc.closed).length, live);
});

test("teardown deletes with the admitting bearer and refuses a foreign location", async () => {
  const h = world({ whip: { status: 201, headers: { location: "https://evil.example/session/abc" } } });
  assert.equal((await h.room.join(mint({ peerPaths: [] }))).error, "setup_failed");
  const ok = world();
  await ok.room.join(mint({ peerPaths: [] }));
  await ok.room.teardown();
  const deleted = ok.calls.filter((call) => call.method === "DELETE");
  assert.equal(deleted.length, 1);
  assert.equal(deleted[0].auth, "Bearer tok-alice");
  assert.equal(deleted[0].url, "http://127.0.0.1:18447/session/abc");
  assert.equal(ok.room.status().pcs, 0);
});

test("codec failure does not schedule a retry", async () => {
  const h = world({ whep: { status: 409, error: "codec_unavailable", headers: { location: "" } } });
  // codec_unavailable is 409 in the contract table but the gateway uses 409 for that code too.
  assert.equal((await h.room.join(mint())).ok, true);
  assert.equal(h.room.status().peers["bob/cam"].failed, true);
  assert.equal(h.timers.some((item) => item.ms === 1000), false);
});

test("network failure is setup_failed with no camera", async () => {
  const h = world({ network: true });
  assert.equal((await h.room.join(mint())).error, "setup_failed");
  assert.equal(h.gum.length, 0);
});

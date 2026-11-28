import assert from "node:assert/strict";
import test from "node:test";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { canonicalBroadcast, createRoom, validBroadcast } from "../src/room.js";

const root = `t/${"1".repeat(32)}/~open/r1`;
const mint = (extra = {}) => ({
  token: "review-fake-token", root, expectedRoot: root, kind: "open",
  selfPath: "alice/cam", peerPaths: [], retryMs: 1000, ...extra,
});
const tick = () => new Promise((resolve) => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise((r) => { resolve = r; }); return { promise, resolve }; };

function harness(options = {}) {
  const h = { time: 1700000000000, calls: [], pcs: [], tracks: [], timers: [] };
  h.room = createRoom({
    origin: options.origin || "http://127.0.0.1:1",
    now: () => options.now ? options.now(h) : h.time,
    schedule(fn, ms) { const t = { fn, ms, cleared: false }; h.timers.push(t); return t; },
    clear(t) { t.cleared = true; },
    fetch: async (url, init) => {
      const call = { url, init }; h.calls.push(call);
      if (options.fetch) { const r = await options.fetch(call, h); if (r) return r; }
      if (url.endsWith("/admit")) {
        const intent = JSON.parse(init.body);
        return new Response(JSON.stringify({ root, exp: 1700000060, ...intent }), { headers: { "cache-control": "no-store" } });
      }
      if (init.method === "DELETE") return new Response(null, { status: 204 });
      return new Response("v=0\r\n", { status: 201, headers: { location: `/session/id${h.calls.length}` } });
    },
    async getUserMedia() {
      const t = { stopped: false, stop() { this.stopped = true; } };
      h.tracks.push(t);
      return { getTracks: () => [t] };
    },
    createPeerConnection() {
      const pc = {
        connectionState: "new", listeners: [], closed: false,
        addTrack() {}, addTransceiver() {},
        addEventListener(type, fn) { this.listeners.push({ type, fn }); },
        emit() { for (const { type, fn } of this.listeners) if (type === "connectionstatechange") fn(); },
        async createOffer() { if (options.offer) await options.offer(pc, h); return { type: "offer", sdp: "v=0\r\n" }; },
        async setLocalDescription(d) { this.localDescription = d; },
        async setRemoteDescription() { if (options.remote) await options.remote(pc, h); this.connectionState = "connected"; this.emit(); },
        close() { this.closed = true; this.connectionState = "closed"; this.emit(); },
      };
      h.pcs.push(pc);
      return pc;
    },
    onLocal(stream, id) { h.local = { stream, id }; },
    onRemoteTrack(path, attempt, event) { h.remote = h.remote || []; h.remote.push({ path, attempt, id: event.track.id }); },
    onUpdate() { h.updates = (h.updates || 0) + 1; },
  });
  return h;
}

test("redirected admission does not open the camera", async () => {
  let foreignRequests = 0;
  const foreign = createServer((req, res) => {
    foreignRequests += 1;
    res.setHeader("cache-control", "no-store");
    res.end(JSON.stringify({ root, exp: 1700000060, operation: "publish", broadcast: "alice/cam" }));
  });
  await new Promise((r) => foreign.listen(0, "127.0.0.1", r));
  const source = createServer((req, res) => {
    res.writeHead(307, { location: `http://127.0.0.1:${foreign.address().port}/admit` });
    res.end();
  });
  await new Promise((r) => source.listen(0, "127.0.0.1", r));
  try {
    const h = harness({
      origin: `http://127.0.0.1:${source.address().port}`,
      fetch: ({ url, init }) => url.endsWith("/admit") ? fetch(url, init) : null,
    });
    assert.equal((await h.room.join(mint())).error, "setup_failed");
    assert.equal(foreignRequests, 0);
    assert.equal(h.tracks.length, 0);
    assert.equal(h.calls[0].init.redirect, "error");
    assert.equal(h.calls[0].init.referrerPolicy, "no-referrer");
  } finally {
    await Promise.all([source, foreign].map((s) => new Promise((r) => s.close(r))));
  }
});

test("expiry between admission and the camera does not open the camera", async () => {
  const h = harness({ now(h) { const time = h.time; h.time = 1700000061000; return time; } });
  assert.equal((await h.room.join(mint())).error, "bad_token");
  assert.equal(h.tracks.length, 0);
});

test("mutating the invitation after the call does not change the committed peers", async () => {
  const input = mint({ peerPaths: ["bob/cam"] });
  const h = harness({
    fetch: ({ url, init }) => {
      if (url.endsWith("/admit") && JSON.parse(init.body).operation === "publish") input.peerPaths[0] = "eve/cam";
    },
  });
  assert.equal((await h.room.join(input)).ok, true);
  assert.equal(h.calls.some((call) => call.url.includes("/whep/") && call.url.includes("bob")), true);
  assert.equal(h.calls.some((call) => call.url.includes("eve")), false);
});

test("leave releases the camera and peer connection while DELETE is still pending", async () => {
  const gate = deferred();
  const h = harness({ fetch: ({ init }) => init.method === "DELETE" ? gate.promise : null });
  await h.room.join(mint());
  let done = false;
  const leaving = h.room.teardown().then((result) => { done = result; });
  await tick();
  assert.equal(done, false);
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.pcs[0].closed, true);
  assert.equal(h.room.status().incumbent, null);
  gate.resolve(new Response(null, { status: 204 }));
  await leaving;
  assert.equal(done.released, true);
  assert.equal(done.ok, true);
});

test("createOffer rejection returns setup_failed and retires the candidate", async () => {
  const h = harness({ offer() { throw new Error("offer failed"); } });
  assert.equal((await h.room.join(mint())).error, "setup_failed");
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.room.status().candidate, null);
  assert.equal(h.pcs[0].closed, true);
});

test("a valid Location is deleted when applying the answer fails", async () => {
  const h = harness({ remote() { throw new Error("invalid SDP"); } });
  assert.equal((await h.room.join(mint())).error, "setup_failed");
  assert.equal(h.calls.filter((call) => call.init.method === "DELETE").length, 1);
  assert.match(h.calls.find((call) => call.init.method === "DELETE").url, /\/session\/id/);
});

test("a superseded candidate closes its peer connection before the old offer finishes", async () => {
  const gate = deferred();
  const h = harness({ offer(pc, box) { if (box.pcs.length === 1) return gate.promise; } });
  const first = h.room.join(mint());
  await tick();
  const next = h.room.replace(mint({ token: "next-fake-token" }));
  await tick();
  assert.equal(h.pcs[0].closed, true);
  assert.equal(h.tracks[0].stopped, true);
  gate.resolve();
  await first;
  assert.equal((await next).ok, true);
});

test("disconnected and failed schedule one retry and close the old peer connection", async () => {
  const h = harness();
  await h.room.join(mint({ peerPaths: ["bob/cam"] }));
  const peer = h.pcs[1];
  peer.connectionState = "disconnected";
  peer.emit();
  peer.connectionState = "failed";
  peer.emit();
  const retries = h.timers.filter((t) => t.ms === 1000 && !t.cleared);
  assert.equal(retries.length, 1);
  assert.equal(peer.closed, true);
  retries[0].fn();
  await tick();
  assert.equal(h.calls.filter((call) => call.url.includes("/whep/")).length, 2);
});

test("a peer network failure closes the peer connection instead of retaining it", async () => {
  const h = harness({ fetch: ({ url }) => { if (url.includes("/whep/")) throw new Error("network"); } });
  await h.room.join(mint({ peerPaths: ["bob/cam"] }));
  const retry = h.timers.find((t) => t.ms === 1000 && !t.cleared);
  retry.fn();
  await tick();
  assert.equal(h.pcs.filter((pc) => !pc.closed).length, 1);
});

test("gateway path grammar rejects escapes and excessive depth before a request", async () => {
  for (const path of ["a/%2f/b", "a/%252f/b", "a/%", `${"a/".repeat(40)}b`]) {
    assert.equal(validBroadcast(path, root), false);
  }
  const h = harness();
  assert.equal((await h.room.join(mint({ peerPaths: ["a/%2e%2e/b"] }))).error, "bad_request");
  assert.equal(h.calls.length, 0);
});

test("WHIP 200 does not commit", async () => {
  const h = harness({
    fetch: ({ url }) => url.includes("/whip/")
      ? new Response("v=0\r\n", { status: 200, headers: { location: "/session/wrongstatus" } })
      : null,
  });
  assert.equal((await h.room.join(mint())).error, "setup_failed");
  assert.equal(h.room.status().incumbent, null);
  assert.equal(h.tracks[0].stopped, true);
});

test("expiry during createOffer does not send the media POST", async () => {
  const h = harness({ offer(pc, box) { box.time = 1700000061000; } });
  assert.equal((await h.room.join(mint())).error, "bad_token");
  assert.equal(h.calls.filter((call) => call.url.includes("/whip/")).length, 0);
  assert.equal(h.tracks[0].stopped, true);
});

test("non-loopback http origins are refused", () => {
  assert.throws(() => createRoom({ origin: "http://example.com", fetch() {} }), /origin/);
  assert.throws(() => createRoom({ origin: "https://user:pw@127.0.0.1", fetch() {} }), /origin/);
});

const boot = (await readFile(new URL("../page/boot.js", import.meta.url), "utf8")).replace(/^import .*;\n/, "");
function pageHarness() {
  class Stream {
    constructor() { this.tracks = []; }
    getTracks() { return this.tracks; }
    addTrack(t) { this.tracks.push(t); }
    removeTrack(t) { this.tracks = this.tracks.filter((item) => item !== t); }
  }
  function element() {
    return {
      textContent: "", srcObject: null, value: "", dataset: {}, hidden: true, handlers: {}, children: [],
      addEventListener(k, v) { this.handlers[k] = v; },
      click() { return this.handlers.click(); },
      append(n) { this.children.push(n); },
      play() { return Promise.reject(new Error("autoplay denied")); },
      querySelector(q) {
        if (q.startsWith("[data-path=")) return this.children.find((n) => q === `[data-path="${n.dataset.path}"]`) || null;
        return this.parts[q];
      },
      querySelectorAll() { return this.children.map((n) => n.parts.video).filter(Boolean); },
      replaceChildren() { this.children = []; },
      closest() { return this; },
      parts: {},
      set innerHTML(_v) { this.parts = { h2: element(), video: element(), p: element() }; },
    };
  }
  const nodes = Object.fromEntries(["status", "peers", "local-video", "notice", "join", "replace", "renew", "leave", "renew-token", "resume"].map((id) => [`#${id}`, element()]));
  nodes["#notice"].textContent = "This room is open. The host can read the media.";
  nodes["#resume"].hidden = true;
  let deps;
  let api;
  const live = { tracks: 1, peers: { "bob/cam": { empty: true } }, sessions: [], pcs: 0 };
  const media = deferred();
  const ctx = {
    window: { MJOLNIR_ROOM_ORIGIN: "http://127.0.0.1:1" },
    document: { querySelector: (q) => nodes[q], createElement: element },
    location: { hash: "#t=fake&self=alice/cam&peer=bob/cam", pathname: "/room.html", search: "" },
    history: { replaceState() {} },
    URLSearchParams, CSS: { escape: (x) => x }, MediaStream: Stream,
    navigator: { mediaDevices: { getUserMedia: () => media.promise } },
    fetch() {}, RTCPeerConnection() {},
    createRoom(d) {
      deps = d;
      api = {
        join: async () => ({ ok: true }),
        replace: async () => ({ ok: false, error: "setup_failed" }),
        teardown: async () => ({ ok: true }),
        status: () => live,
      };
      return api;
    },
  };
  vm.runInNewContext(boot, ctx);
  return { ctx, nodes, live, deps, media, Stream, api };
}

test("a rejected play shows recovery instead of playing", async () => {
  const p = pageHarness();
  await p.ctx.window.roomClient.join();
  p.deps.onRemoteTrack("bob/cam", 1, { track: { id: "v1", kind: "video", readyState: "live" } });
  await tick();
  const tile = p.nodes["#peers"].children[0];
  assert.match(tile.parts.p.textContent, /Playback is blocked/);
  assert.equal(p.nodes["#resume"].hidden, false);
});

test("a new subscription attempt replaces the previous tracks", () => {
  const p = pageHarness();
  p.deps.onRemoteTrack("bob/cam", 1, { track: { id: "a1", kind: "audio", readyState: "live" } });
  p.deps.onRemoteTrack("bob/cam", 1, { track: { id: "v1", kind: "video", readyState: "live" } });
  p.deps.onRemoteTrack("bob/cam", 2, { track: { id: "a2", kind: "audio", readyState: "live" } });
  p.deps.onRemoteTrack("bob/cam", 2, { track: { id: "v2", kind: "video", readyState: "live" } });
  const tracks = p.nodes["#peers"].children[0].parts.video.srcObject.getTracks();
  assert.deepEqual(tracks.map((t) => t.id), ["a2", "v2"]);
});

test("leaving clears the preview and a late camera does not restore it", async () => {
  const p = pageHarness();
  await p.nodes["#leave"].click();
  assert.equal(p.nodes["#local-video"].srcObject, null);
  const late = new p.Stream();
  p.media.resolve(late);
  await tick();
  assert.equal(p.nodes["#local-video"].srcObject, null);
  assert.match(p.nodes["#status"].textContent, /Left the room/);
});

function probeRoom(options = {}) {
  const h = { calls: [], pcs: [], tracks: [], timers: [] };
  h.room = createRoom({
    origin: "http://127.0.0.1:1",
    now: () => 1700000000000,
    schedule(fn, ms) { const t = { fn, ms, cleared: false }; h.timers.push(t); return t; },
    clear(t) { t.cleared = true; },
    fetch: async (url, init) => {
      const call = { url, init };
      h.calls.push(call);
      if (options.fetch) {
        const custom = await options.fetch(call, h);
        if (custom) return custom;
      }
      if (url.endsWith("/admit")) {
        const intent = JSON.parse(init.body);
        return new Response(JSON.stringify({ root, exp: 1700000060, ...intent }), { headers: { "cache-control": "no-store" } });
      }
      if (init.method === "DELETE") return new Response(null, { status: 204 });
      return new Response("v=0\r\n", { status: 201, headers: { location: `/session/id${h.calls.length}` } });
    },
    async getUserMedia() {
      if (options.camera) return options.camera(h);
      const track = { stopped: false, stop() { this.stopped = true; } };
      h.tracks.push(track);
      return { getTracks: () => [track] };
    },
    createPeerConnection() {
      if (options.construct) options.construct(h);
      const pc = {
        connectionState: "new", closed: false, listeners: [],
        addTrack() {}, addTransceiver() {},
        addEventListener(type, fn) { this.listeners.push({ type, fn }); },
        removeEventListener() {},
        async createOffer() { if (options.offer) await options.offer(pc, h); return { type: "offer", sdp: "v=0\r\n" }; },
        async setLocalDescription(description) { this.localDescription = description; if (options.local) await options.local(this, h); },
        async setRemoteDescription() { this.connectionState = "connected"; },
        close() { this.closed = true; this.connectionState = "closed"; },
      };
      h.pcs.push(pc);
      return pc;
    },
    onLocal(stream, id) { h.local = { stream, id }; },
  });
  return h;
}

const deletes = (h) => h.calls.filter((call) => call.init.method === "DELETE");

test("a throwing peer connection constructor releases the candidate camera", async () => {
  const h = probeRoom({ construct() { throw new Error("resources exhausted"); } });
  const result = await h.room.join(mint());
  assert.equal(result.error, "setup_failed");
  assert.equal(h.tracks[0].stopped, true);
  assert.equal(h.room.status().candidate, null);
});

test("a body read failure still deletes the allocated session", async () => {
  const h = probeRoom({
    fetch({ url }) {
      if (!url.includes("/whip/")) return null;
      const response = new Response("v=0", { status: 201, headers: { location: "/session/allocated" } });
      response.text = async () => { throw new Error("body reset"); };
      return response;
    },
  });
  assert.equal((await h.room.join(mint())).error, "setup_failed");
  assert.equal(deletes(h).length, 1);
  assert.equal(h.tracks[0].stopped, true);
});

test("leave deletes a session whose body is still pending", async () => {
  const body = deferred();
  const h = probeRoom({
    fetch({ url }) {
      if (!url.includes("/whip/")) return null;
      const response = new Response("v=0", { status: 201, headers: { location: "/session/bodypending" } });
      response.text = () => body.promise;
      return response;
    },
  });
  const join = h.room.join(mint());
  await tick();
  await h.room.teardown();
  assert.equal(deletes(h).some((call) => call.url.endsWith("/session/bodypending")), true);
  body.resolve("v=0");
  assert.equal((await join).ok, false);
});

test("retiring a generation settles ICE gathering without a browser event", async () => {
  const h = probeRoom({ local(pc) { pc.iceGatheringState = "gathering"; } });
  let settled = false;
  const join = h.room.join(mint()).then((result) => { settled = result; return result; });
  await tick();
  await h.room.teardown();
  await tick();
  assert.equal(settled.ok, false);
  assert.equal(h.pcs[0].closed, true);
  await join;
});

test("canonical broadcast matches one gateway decode", () => {
  assert.equal(canonicalBroadcast("alice/%63am", root), "alice/cam");
  assert.equal(canonicalBroadcast("alice/é", root), "alice/é");
  assert.equal(canonicalBroadcast(".hidden/cam", root), ".hidden/cam");
  assert.equal(canonicalBroadcast("alice/.hidden", root), "alice/.hidden");
  assert.equal(validBroadcast("a/%2f/b", root), false);
});

test("an escaped path is admitted as its canonical text", async () => {
  const h = probeRoom({
    fetch({ url, init }) {
      if (!url.endsWith("/admit")) return null;
      const intent = JSON.parse(init.body);
      return new Response(JSON.stringify({
        root, exp: 1700000060, ...intent, broadcast: decodeURIComponent(intent.broadcast),
      }), { headers: { "cache-control": "no-store" } });
    },
  });
  assert.equal((await h.room.join(mint({ selfPath: "alice/%63am" }))).ok, true);
  assert.equal(JSON.parse(h.calls[0].init.body).broadcast, "alice/cam");
});

test("a failed candidate does not stop a track the incumbent still owns", async () => {
  const shared = { stopped: false, stop() { this.stopped = true; } };
  const h = probeRoom({
    camera: () => ({ getTracks: () => [shared] }),
    offer(_pc, state) { if (state.pcs.length === 2) throw new Error("candidate"); },
  });
  assert.equal((await h.room.join(mint())).ok, true);
  assert.equal((await h.room.replace(mint())).ok, false);
  assert.equal(h.room.status().incumbent, 1);
  assert.equal(shared.stopped, false);
  await h.room.teardown();
  assert.equal(shared.stopped, true);
});

test("a redirected media response is not a successful join", async () => {
  const h = probeRoom({
    fetch({ url, init }) {
      if (url.endsWith("/admit")) return null;
      const response = init.method === "DELETE"
        ? new Response(null, { status: 204 })
        : new Response("v=0", { status: 201, headers: { location: "/session/redirected" } });
      Object.defineProperty(response, "redirected", { value: true });
      Object.defineProperty(response, "url", { value: "https://foreign.example/session" });
      return response;
    },
  });
  assert.equal((await h.room.join(mint())).ok, false);
  assert.equal(h.room.status().sessions.length, 0);
});

test("the next generation does not keep the previous generation's video", () => {
  const p = pageHarness();
  p.deps.onRemoteTrack("bob/cam", 1, { track: { id: "old-video", kind: "video", readyState: "live" } }, 1);
  p.deps.onRemoteTrack("bob/cam", 1, { track: { id: "new-audio", kind: "audio", readyState: "live" } }, 2);
  const tracks = p.nodes["#peers"].children[0].parts.video.srcObject.getTracks();
  assert.deepEqual(tracks.map((track) => track.id), ["new-audio"]);
});

test("a stale play completion does not hide recovery for the current attempt", async () => {
  const p = pageHarness();
  await p.ctx.window.roomClient.join();
  const tile = p.nodes["#peers"].children[0];
  const gate = deferred();
  tile.parts.video.play = () => gate.promise;
  p.deps.onRemoteTrack("bob/cam", 1, { track: { kind: "video" } });
  tile.parts.video.play = () => Promise.reject(new Error("blocked"));
  p.deps.onRemoteTrack("bob/cam", 2, { track: { kind: "video" } });
  await tick();
  gate.resolve();
  await tick();
  assert.equal(p.nodes["#resume"].hidden, false);
  assert.match(tile.parts.p.textContent, /Playback is blocked/);
});

test("an older leave does not overwrite a newer join", async () => {
  const p = pageHarness();
  const gate = deferred();
  p.api.teardown = () => gate.promise;
  const leave = p.nodes["#leave"].click();
  await p.ctx.window.roomClient.join();
  assert.equal(p.nodes["#status"].textContent, "In the room.");
  gate.resolve({ ok: true });
  await leave;
  assert.equal(p.nodes["#status"].textContent, "In the room.");
});

test("an expiry update clears the in-room status and the peer tile", async () => {
  const p = pageHarness();
  await p.ctx.window.roomClient.join();
  p.deps.onRemoteTrack("bob/cam", 1, { track: { id: "v", kind: "video", readyState: "live" } });
  p.live.incumbent = null;
  p.live.tracks = 0;
  p.live.peers = {};
  p.deps.onLocal(null, 1);
  p.deps.onUpdate();
  assert.equal(p.nodes["#status"].textContent, "This token is not valid.");
  assert.equal(p.nodes["#peers"].children.length, 0);
});

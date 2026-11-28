// Independent narrow boundary probes for 0df60bee. Harness reused; historical probes unchanged.
// Harness adapted from historical R1-R15 and current regression doubles; history unchanged.
import assert from "node:assert/strict";
import test from "node:test";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { createRoom, validBroadcast, canonicalBroadcast } from "../../../../native/mjolnir_room/src/room.js";

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
      if (options.camera) return options.camera(h);
      const t = { stopped: false, stop() { this.stopped = true; } };
      h.tracks.push(t);
      return { getTracks: () => [t] };
    },
    createPeerConnection() {
      if (options.construct) options.construct(h);
      const pc = {
        connectionState: "new", listeners: [], closed: false,
        addTrack() {}, addTransceiver() {},
        addEventListener(type, fn) { this.listeners.push({ type, fn }); },
        emit() { for (const { type, fn } of this.listeners) if (type === "connectionstatechange") fn(); },
        async createOffer() { if (options.offer) await options.offer(pc, h); return { type: "offer", sdp: "v=0\r\n" }; },
        async setLocalDescription(d) { this.localDescription = d; if (options.local) await options.local(this,h); },
        async setRemoteDescription() { if (options.remote) await options.remote(pc, h); this.connectionState = "connected"; this.emit(); },
        close() { this.closed = true; this.connectionState = "closed"; this.emit(); },
      };
      h.pcs.push(pc);
      return pc;
    },
    onLocal(stream, id) { h.local = { stream, id }; },
    onRemoteTrack(path, attempt, event, generation) { h.remote = h.remote || []; h.remote.push({ path, attempt, generation, id: event.track.id }); if (options.onRemoteTrack) options.onRemoteTrack(path, attempt, event, generation); },
    onUpdate() { h.updates = (h.updates || 0) + 1; if (options.onUpdate) options.onUpdate(); },
  });
  return h;
}

const boot = (await readFile(new URL("../../../../native/mjolnir_room/page/boot.js", import.meta.url), "utf8")).replace(/^import .*;\n/, "");
function pageHarness(factory) {
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
      querySelectorAll(q) { return q === ".tile" ? this.children : this.children.map((n) => n.parts.video).filter(Boolean); },
      replaceChildren() { this.children = []; },
      closest() { return this; },
      parts: {},
      set innerHTML(_v) { this.parts = { h2: element(), video: element(), p: element() }; },
    };
  }
  const nodes = Object.fromEntries(["status", "peers", "local-video", "notice", "join", "replace", "renew", "leave", "renew-token", "resume"].map((id) => [`#${id}`, element()]));
  nodes["#notice"].textContent = "This room is open. The host can read the media.";
  nodes["#resume"].hidden = true;
  let deps, api;
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
      if (factory) return api = factory(d);
      return api = {
        join: async () => ({ ok: true }),
        replace: async () => ({ ok: false, error: "setup_failed" }),
        teardown: async () => ({ ok: true }),
        status: () => live,
      };
    },
  };
  vm.runInNewContext(boot, ctx);
  return { ctx, nodes, live, deps, media, Stream, api };
}


for (const lateHeaders of [false, true]) {
  test(`supersession cleanup exactly once, late headers=${lateHeaders}`, async () => {
    const headers = deferred(), body = deferred(); let posts = 0, bodyReads = 0;
    const response = {status:201, headers:new Headers({location:'/session/retired'}), text(){bodyReads++; return body.promise;}};
    const h = harness({fetch:({url}) => {
      if (url.includes('/whip/') && ++posts === 1) return lateHeaders ? headers.promise : response;
    }});
    const old = h.room.join(mint()); await tick();
    assert.equal((await h.room.replace(mint({token:'successor-token'}))).ok, true);
    const currentSessions = h.room.status().sessions.slice();
    headers.resolve(response); await tick(); assert.equal((await old).ok, false);
    const retiredDeletes = () => h.calls.filter(c=>c.init.method==='DELETE' && c.url.endsWith('/session/retired'));
    assert.equal(retiredDeletes().length, 1);
    assert.equal(retiredDeletes()[0].init.headers.authorization, 'Bearer review-fake-token');
    assert.equal(bodyReads, lateHeaders ? 0 : 1);
    body.resolve('v=0'); await tick();
    assert.equal(retiredDeletes().length, 1);
    assert.deepEqual(h.room.status().sessions, currentSessions);
    assert.equal(h.tracks[1].stopped, false);
    await h.room.teardown(); await h.room.teardown();
    assert.equal(retiredDeletes().length, 1);
    for (const session of currentSessions) assert.equal(h.calls.filter(c=>c.init.method==='DELETE' && c.url.endsWith(session)).length, 1);
  });
}
for (const failure of ['answer rejection','ICE failure']) {
  test(`two-peer retry retains pending tracks then clears ${failure}`, async () => {
    let h, bobPosts=0; const pending=deferred();
    const p=pageHarness(d=>{
      h=harness({onUpdate:d.onUpdate, onRemoteTrack:d.onRemoteTrack,
        fetch:({url})=>{
          if(url.includes('/whep/') && url.endsWith('/bob/cam') && ++bobPosts===1)
            return new Response(JSON.stringify({error:'not_started'}),{status:409});
        },
        offer(pc){
          if(pc!==h.pcs[3]) return;
          pc.setRemoteDescription=async()=>{
            pc.ontrack({track:{id:'retry-video',kind:'video',readyState:'live'}});
            await pending.promise;
            if(failure==='answer rejection') throw Error('answer rejected');
          };
        }
      }); return h.room;
    });
    await h.room.join(mint({peerPaths:['bob/cam','carol/cam']}));
    h.timers.find(t=>!t.cleared && t.ms===1000).fn(); await tick();
    const tile=p.nodes['#peers'].children.find(n=>n.dataset.path==='bob/cam');
    const stream=tile.parts.video.srcObject; assert.ok(stream);
    h.pcs[2].connectionState='disconnected'; h.pcs[2].emit();
    assert.equal(tile.parts.video.srcObject,stream);
    pending.resolve(); await tick();
    if(failure==='ICE failure') { h.pcs[3].connectionState='failed';h.pcs[3].emit();await tick(); }
    assert.equal(h.room.status().peers['bob/cam'].inflight,false);
    assert.equal(h.room.status().peers['bob/cam'].empty,true);
    assert.equal(tile.parts.video.srcObject,null);
    assert.equal(tile.parts.video.dataset.blocked,'');
    assert.equal(p.nodes['#resume'].hidden,true);
    assert.equal(h.pcs[3].closed,true);
    const deleted=h.calls.filter(c=>c.init.method==='DELETE').map(c=>c.url);
    assert.equal(new Set(deleted).size,deleted.length);
    await h.room.teardown();
  });
}

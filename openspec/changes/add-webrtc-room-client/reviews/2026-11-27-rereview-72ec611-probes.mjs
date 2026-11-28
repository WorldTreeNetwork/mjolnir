// Independent re-review: PASS tests assert repairs; DEFECT tests assert remaining bad behavior.
// Harness adapted from historical R1-R15 and current regression doubles; history unchanged.
import assert from "node:assert/strict";
import test from "node:test";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { createRoom, validBroadcast } from "../../../../native/mjolnir_room/src/room.js";

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
    onRemoteTrack(path, attempt, event) { h.remote = h.remote || []; h.remote.push({ path, attempt, id: event.track.id }); },
    onUpdate() { h.updates = (h.updates || 0) + 1; },
  });
  return h;
}

const boot = (await readFile(new URL("../../../../native/mjolnir_room/page/boot.js", import.meta.url), "utf8")).replace(/^import .*;\n/, "");
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

const deleteCalls = h => h.calls.filter(c => c.init.method === 'DELETE');
test('PASS: DELETE bound releases locally and aborts an ignoring fetch', async () => {
  const h = harness({fetch: ({init}) => init.method === 'DELETE' ? new Promise(()=>{}) : null});
  await h.room.join(mint());
  const leave = h.room.teardown();
  assert.ok(h.tracks[0].stopped && h.pcs[0].closed);
  h.timers.filter(t=>t.ms===2000&&!t.cleared).forEach(t=>t.fn());
  assert.equal((await leave).error, 'cleanup_timeout');
  assert.equal(deleteCalls(h)[0].init.signal.aborted,true);
});
test('PASS: incumbent retries survive a candidate offer failure; pending retry cannot run after leave', async () => {
  const gate=deferred();
  const h=harness({offer(pc,h){if(h.pcs.length===3)return gate.promise.then(()=>{throw Error('candidate');});}});
  await h.room.join(mint({peerPaths:['bob/cam']}));
  const next=h.room.replace(mint()); await tick();
  h.pcs[1].connectionState='failed';h.pcs[1].emit();
  const timer=h.timers.find(t=>t.ms===1000&&!t.cleared);timer.fn();await tick();
  assert.equal(h.calls.filter(c=>c.url.includes('/whep/')).length,2);
  gate.resolve();assert.equal((await next).ok,false);
  assert.equal(h.room.status().incumbent,1);assert.equal(h.tracks[0].stopped,false);
  const peer=h.pcs.at(-1);peer.connectionState='failed';peer.emit();
  const pending=h.timers.filter(t=>t.ms<30000&&!t.cleared).at(-1);
  await h.room.teardown();const count=h.calls.length;pending.fn();await tick();assert.equal(h.calls.length,count);
});
test('PASS: delayed candidate camera cannot replace incumbent preview after failure or leave', async () => {
  const gate=deferred();let calls=0;const old={stopped:false,stop(){this.stopped=true;}};
  const h=harness({camera(){return ++calls===1 ? {getTracks:()=>[old]} : gate.promise;}});
  await h.room.join(mint());const first=h.local;
  const replacement=h.room.replace(mint());await tick();assert.equal(h.local,first);
  await h.room.teardown();const late={stopped:false,stop(){this.stopped=true;}};
  gate.resolve({getTracks:()=>[late]});assert.equal((await replacement).error,'stale');
  assert.equal(late.stopped,true);assert.equal(h.local.stream,null);
});
test('PASS: redirected admission response is refused independently of fetch redirect option', async () => {
  const h=harness({fetch:({url,init})=>{if(!url.endsWith('/admit'))return;const r=new Response(JSON.stringify({root,exp:1700000060,...JSON.parse(init.body)}),{headers:{'cache-control':'no-store'}});Object.defineProperty(r,'redirected',{value:true});return r;}});
  assert.equal((await h.room.join(mint())).ok,false);assert.equal(h.tracks.length,0);
});
test('DEFECT: redirected media and DELETE responses accepted by response layer',async()=>{
  const h=harness({fetch:({url,init})=>{
    if(url.endsWith('/admit'))return;
    const r=init.method==='DELETE'?new Response(null,{status:204}):new Response('v=0',{status:201,headers:{location:'/session/redirected'}});
    Object.defineProperty(r,'redirected',{value:true});Object.defineProperty(r,'url',{value:'https://foreign.example/session'});return r;
  }});
  assert.equal((await h.room.join(mint())).ok,true);
  assert.equal((await h.room.teardown()).ok,true);
  assert.ok(h.calls.every(c=>c.init.redirect==='error'));
});
test('DEFECT: response.text rejection loses validated allocated Location',async()=>{
  const h=harness({fetch:({url})=>{if(!url.includes('/whip/'))return;const r=new Response('v=0',{status:201,headers:{location:'/session/allocated'}});r.text=async()=>{throw Error('body reset');};return r;}});
  assert.equal((await h.room.join(mint())).error,'setup_failed');assert.equal(deleteCalls(h).length,0);
  assert.equal(h.tracks[0].stopped,true);
});
test('DEFECT: PC constructor exception escapes candidate cleanup',async()=>{
  const h=harness({construct(){throw Error('resources exhausted');}});
  await assert.rejects(h.room.join(mint()),/resources exhausted/);
  assert.equal(h.tracks[0].stopped,false);assert.equal(h.room.status().candidate,1);await h.room.teardown();
});
test('DEFECT: cancelled ICE gathering never settles old join',async()=>{
  const h=harness({local(pc){pc.iceGatheringState='gathering';}});let settled=false;
  void h.room.join(mint()).then(()=>settled=true);await tick();
  const gathering=h.timers.find(t=>t.ms===1500);assert.ok(gathering);
  await h.room.teardown();assert.equal(gathering.cleared,true);gathering.fn();await tick();
  assert.equal(settled,false);assert.equal(h.pcs[0].closed,true);
});
test('DEFECT: accepted percent path differs from gateway canonical echo',async()=>{
  assert.equal(validBroadcast('alice/%63am',root),true);
  const h=harness({fetch:({url,init})=>{if(!url.endsWith('/admit'))return;const intent=JSON.parse(init.body);return new Response(JSON.stringify({root,exp:1700000060,...intent,broadcast:decodeURIComponent(intent.broadcast)}),{headers:{'cache-control':'no-store'}});}});
  assert.equal((await h.room.join(mint({selfPath:'alice/%63am'}))).error,'response_mismatch');
  assert.equal(validBroadcast('alice/é',root),false); // gateway UTF-8 accepts this
  assert.equal(validBroadcast('alice/.hidden',root),true);
  assert.equal(validBroadcast('.hidden/cam',root),false); // gateway accepts this too
});
test('DEFECT: shared camera track stopped by failed candidate while incumbent owns it',async()=>{
  const shared={stopped:false,stop(){this.stopped=true;}};
  const h=harness({camera:()=>({getTracks:()=>[shared]}),offer(pc,h){if(h.pcs.length===2)throw Error('candidate');}});
  await h.room.join(mint());assert.equal((await h.room.replace(mint())).ok,false);
  assert.equal(h.room.status().incumbent,1);assert.equal(shared.stopped,true);await h.room.teardown();
});
test('PASS: current callback replaces same-kind tracks and rejected play offers recovery',async()=>{
  const p=pageHarness();await p.ctx.window.roomClient.join();
  for(const [attempt,id,kind] of [[1,'a1','audio'],[1,'v1','video'],[2,'a2','audio'],[2,'v2','video']])p.deps.onRemoteTrack('bob/cam',attempt,{track:{id,kind,readyState:'live'}});
  await tick();const tile=p.nodes['#peers'].children[0];
  assert.deepEqual(tile.parts.video.srcObject.getTracks().map(t=>t.id),['a2','v2']);
  assert.match(tile.parts.p.textContent,/Playback is blocked/);assert.equal(p.nodes['#resume'].hidden,false);
});
test('DEFECT: expiry update retains In the room and peer tile',async()=>{
  const p=pageHarness();await p.ctx.window.roomClient.join();
  p.deps.onLocal(new p.Stream(),1);
  p.deps.onRemoteTrack('bob/cam',1,{track:{id:'v',kind:'video',readyState:'live'}});await tick();
  p.live.incumbent=null;p.live.tracks=0;p.live.peers={};p.deps.onLocal(null,1);p.deps.onUpdate();
  assert.equal(p.nodes['#local-video'].srcObject,null);
  assert.equal(p.nodes['#status'].textContent,'In the room.');assert.equal(p.nodes['#peers'].children.length,1);
});
test('DEFECT: stale play completion overwrites a new attempt caption and hides recovery',async()=>{
  const p=pageHarness();await p.ctx.window.roomClient.join();const tile=p.nodes['#peers'].children[0];const gate=deferred();
  tile.parts.video.play=()=>gate.promise;
  p.deps.onRemoteTrack('bob/cam',1,{track:{kind:'video'}});
  tile.parts.video.play=()=>Promise.reject(Error('blocked'));
  p.deps.onRemoteTrack('bob/cam',2,{track:{kind:'video'}});await tick();assert.equal(p.nodes['#resume'].hidden,false);
  gate.resolve();await tick();assert.equal(p.nodes['#resume'].hidden,true);assert.equal(tile.parts.p.textContent,'Playing.');
});
test('DEFECT: late Leave completion overwrites newer successful Join status',async()=>{
  const p=pageHarness();const gate=deferred();p.api.teardown=()=>gate.promise;
  const leave=p.nodes['#leave'].click();await p.ctx.window.roomClient.join();assert.equal(p.nodes['#status'].textContent,'In the room.');
  gate.resolve({ok:true});await leave;assert.equal(p.nodes['#status'].textContent,'Left the room.');
});
test('DEFECT: first attempt of next generation retains previous generation video until new video arrives',async()=>{
  const p=pageHarness();
  p.deps.onRemoteTrack('bob/cam',1,{track:{id:'old-video',kind:'video',readyState:'live'}});
  // playPeer resets attempt to 1 in each generation; onRemoteTrack omits generation ID.
  p.deps.onRemoteTrack('bob/cam',1,{track:{id:'new-audio',kind:'audio',readyState:'live'}});
  const tracks=p.nodes['#peers'].children[0].parts.video.srcObject.getTracks();
  assert.deepEqual(tracks.map(t=>t.id),['old-video','new-audio']);await tick();
});
test('PASS: late allocated response after leave is deleted and never commits',async()=>{
  const gate=deferred();const h=harness({fetch:({url})=>url.includes('/whip/')?gate.promise:null});
  const join=h.room.join(mint());await tick();await h.room.teardown();
  gate.resolve(new Response('v=0',{status:201,headers:{location:'/session/late'}}));
  assert.equal((await join).ok,false);assert.equal(deleteCalls(h).filter(c=>c.url.endsWith('/session/late')).length,1);
  assert.equal(h.room.status().incumbent,null);
});
test('PASS: setLocalDescription rejection retires camera and PC',async()=>{
  const h=harness({local(){throw Error('local');}});assert.equal((await h.room.join(mint())).error,'setup_failed');assert.equal(h.tracks[0].stopped,true);assert.equal(h.pcs[0].closed,true);
});
test('PASS: candidate ICE timeout preserves incumbent and deletes only candidate allocation',async()=>{
  const h=harness({offer(pc,h){if(h.pcs.length===2)pc.setRemoteDescription=async()=>{};}});
  await h.room.join(mint());const next=h.room.replace(mint());await tick();
  const deadline=h.timers.find(t=>t.ms===10000&&!t.cleared);assert.ok(deadline);deadline.fn();
  assert.equal((await next).ok,false);assert.equal(h.room.status().incumbent,1);
  assert.equal(h.pcs[0].closed,false);assert.equal(h.pcs[1].closed,true);assert.equal(h.tracks[1].stopped,true);
  assert.equal(deleteCalls(h).length,1);await h.room.teardown();
});
test('DEFECT: hanging response body hides already allocated session even from leave',async()=>{
  const body=deferred();const h=harness({fetch:({url})=>{if(!url.includes('/whip/'))return;const r=new Response('v=0',{status:201,headers:{location:'/session/bodypending'}});r.text=()=>body.promise;return r;}});
  const join=h.room.join(mint());await tick();await h.room.teardown();
  assert.equal(deleteCalls(h).length,0);assert.equal(h.tracks[0].stopped,true);
  body.resolve('v=0');await join;assert.equal(deleteCalls(h).length,1);
});

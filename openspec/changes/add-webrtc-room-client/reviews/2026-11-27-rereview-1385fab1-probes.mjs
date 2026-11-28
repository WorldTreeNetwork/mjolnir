// Independent positive re-review of 1385fab1. Historical probes remain unchanged.
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

const deleteCalls = h => h.calls.filter(c => c.init.method === 'DELETE');
test('PASS: actual production callbacks carry distinct generation identity',async()=>{
 const h=harness(); await h.room.join(mint({peerPaths:['bob/cam']}));
 const old=h.pcs[1];old.ontrack({track:{id:'old'}});
 await h.room.replace(mint({peerPaths:['bob/cam']}));
 old.ontrack({track:{id:'stale'}}); h.pcs[3].ontrack({track:{id:'new'}});
 assert.deepEqual(h.remote.map(x=>[x.attempt,x.generation,x.id]),[[1,1,'old'],[1,2,'new']]);
 const p=pageHarness();
 p.deps.onRemoteTrack('bob/cam',1,{track:{id:'old',kind:'video'}},1);
 p.deps.onRemoteTrack('bob/cam',1,{track:{id:'new',kind:'audio'}},2);
 assert.deepEqual(p.nodes['#peers'].children[0].parts.video.srcObject.getTracks().map(t=>t.id),['new']); await tick();await h.room.teardown();
});
test('PASS: gather and connect cancellation settle without close events',async()=>{
 for(const gathering of [true,false]){
 const h=harness({offer(pc){pc.close=function(){this.closed=true;this.connectionState='closed';};pc.setRemoteDescription=async()=>{};},local(pc){if(gathering)pc.iceGatheringState='gathering';}});
 let result;void h.room.join(mint()).then(r=>result=r);await tick();await h.room.teardown();await tick();
 assert.equal(result.ok,false);assert.equal(h.pcs[0].closed,true);
 }
});
test('PASS: stream constructor exception releases PC and camera',async()=>{
 const old=globalThis.MediaStream; globalThis.MediaStream=class {constructor(){throw Error('stream');}};
 try{const h=harness();assert.equal((await h.room.join(mint())).error,'setup_failed');assert.equal(h.tracks[0].stopped,true);assert.equal(h.pcs[0].closed,true);}finally{globalThis.MediaStream=old;}
});
test('PASS: shared track survives commit and supersession then stops on last leave',async()=>{
 let stops=0;const shared={stop(){stops++;}};const gate=deferred();let cameras=0;
 const h=harness({camera(){return ++cameras===2?gate.promise:{getTracks:()=>[shared]};}});
 await h.room.join(mint());const pending=h.room.replace(mint());await tick();await h.room.replace(mint());
 gate.resolve({getTracks:()=>[shared]});await pending;assert.equal(stops,0);await h.room.teardown();assert.equal(stops,1);
});
test('PASS: canonical UTF8 bounds and grammar',()=>{
 for(const [raw,want] of [['alice/%63am','alice/cam'],['alice/é','alice/é'],['.hidden/cam','.hidden/cam'],['a/%C3%A9','a/é'],['a/%252f',null],['a/%ff',null]])assert.equal(canonicalBroadcast(raw,root),want);
 const budget=4096-Buffer.byteLength(root)-1;
 assert.ok(validBroadcast('é'.repeat(Math.floor(budget/2))+'a'.repeat(budget%2),root));
 assert.equal(validBroadcast('é'.repeat(Math.floor(budget/2)+1),root),false);
});
test('PASS: response provenance rejects foreign media and redirected DELETE',async()=>{
 const h=harness({fetch:({url,init})=>{if(init.method!=='DELETE')return;const r=new Response(null,{status:204});Object.defineProperty(r,'redirected',{value:true});return r;}});
 await h.room.join(mint());assert.equal((await h.room.teardown()).ok,false);
 const foreign=harness({fetch:({url})=>{if(!url.includes('/whip/'))return;const r=new Response('v=0',{status:201,headers:{location:'/session/foreign'}});Object.defineProperty(r,'url',{value:'https://foreign.example/whip'});return r;}});
 assert.equal((await foreign.room.join(mint())).ok,false);assert.equal(deleteCalls(foreign).length,0);
});
test('PASS: late headers after leave clean allocation without consuming SDP',async()=>{
 const headers=deferred(),body=deferred();const h=harness({fetch:({url})=>url.includes('/whip/')?headers.promise:null});
 let settled=false;const join=h.room.join(mint()).then(r=>{settled=true;return r;});await tick();await h.room.teardown();
 const r=new Response('v=0',{status:201,headers:{location:'/session/latebody'}});r.text=()=>body.promise;headers.resolve(r);await tick();
 assert.equal(deleteCalls(h).length,1);assert.equal(settled,true);
 body.resolve('v=0');await join;assert.equal(deleteCalls(h).length,1);
});
test('PASS: pending body settles on leave with known Location',async()=>{
 const body=deferred();const h=harness({fetch:({url})=>{if(!url.includes('/whip/'))return;const r=new Response('v=0',{status:201,headers:{location:'/session/held'}});r.text=()=>body.promise;return r;}});
 let settled=false;const join=h.room.join(mint()).then(()=>settled=true);await tick();await h.room.teardown();await tick();assert.equal(settled,true);assert.equal(deleteCalls(h).length,1);body.resolve('v=0');await join;
});
test('PASS: committed new generation without tracks retires old remote stream',async()=>{
 const p=pageHarness();p.live.incumbent=1;await p.ctx.window.roomClient.join();
 p.deps.onRemoteTrack('bob/cam',1,{track:{id:'old-video',kind:'video',readyState:'live'}},1);await tick();
 const video=p.nodes['#peers'].children[0].parts.video;const old=video.srcObject;
 p.live.incumbent=2;p.live.peers={};p.deps.onUpdate();
 p.live.peers={'bob/cam':{attempt:1,empty:true}};p.deps.onUpdate();
 assert.equal(video.srcObject,null);assert.equal(p.nodes['#resume'].hidden,true);
});
test('PASS: detached old element playing event cannot overwrite new tile caption',async()=>{
 const p=pageHarness();p.live.incumbent=1;await p.ctx.window.roomClient.join();
 p.deps.onRemoteTrack('bob/cam',1,{track:{id:'old',kind:'video'}},1);await tick();const old=p.nodes['#peers'].children[0].parts.video;
 await p.nodes['#leave'].click();p.live.incumbent=2;await p.ctx.window.roomClient.join();
 p.deps.onRemoteTrack('bob/cam',1,{track:{id:'new',kind:'video'}},2);await tick();
 old.handlers.playing();assert.match(p.nodes['#peers'].children[0].parts.p.textContent,/blocked/);assert.equal(p.nodes['#resume'].hidden,false);
});
test('PASS: same-owner earlier play cannot hide newer recovery',async()=>{
 const p=pageHarness();await p.ctx.window.roomClient.join();const video=p.nodes['#peers'].children[0].parts.video;const gate=deferred();
 video.play=()=>gate.promise;p.deps.onRemoteTrack('bob/cam',1,{track:{id:'v',kind:'video'}},1);
 video.play=()=>Promise.reject(Error('blocked'));p.deps.onRemoteTrack('bob/cam',1,{track:{id:'a',kind:'audio'}},1);await tick();assert.equal(p.nodes['#resume'].hidden,false);
 gate.resolve();await tick();assert.equal(p.nodes['#resume'].hidden,false);
});
test('PASS: detached old play completion cannot overwrite replacement tile caption',async()=>{
 const p=pageHarness();p.live.incumbent=1;await p.ctx.window.roomClient.join();const old=p.nodes['#peers'].children[0].parts.video;const gate=deferred();
 old.play=()=>gate.promise;p.deps.onRemoteTrack('bob/cam',1,{track:{id:'old',kind:'video'}},1);
 await p.nodes['#leave'].click();p.live.incumbent=2;await p.ctx.window.roomClient.join();p.deps.onRemoteTrack('bob/cam',1,{track:{id:'new',kind:'video'}},2);await tick();
 assert.match(p.nodes['#peers'].children[0].parts.p.textContent,/blocked/);gate.resolve();await tick();assert.match(p.nodes['#peers'].children[0].parts.p.textContent,/blocked/);
});
test('PASS: successful tile does not hide another blocked tile recovery',async()=>{
 const p=pageHarness();await p.ctx.window.roomClient.join();p.deps.onRemoteTrack('bob/cam',1,{track:{kind:'video'}},1);await tick();
 p.deps.onRemoteTrack('carol/cam',1,{track:{kind:'video'}},1);await tick();const carol=p.nodes['#peers'].children[1];carol.parts.video.play=()=>Promise.resolve();
 p.deps.onRemoteTrack('carol/cam',1,{track:{kind:'audio'}},1);await tick();assert.equal(p.nodes['#resume'].hidden,false);assert.equal(carol.parts.video.dataset.blocked,'');
});

// Additional narrow boundary checks, separate from the 13 adapted probes above.
test('expiry bounds a held SDP and late body cannot apply an expired answer', async()=>{
 const body=deferred();let remote=0;
 const h=harness({fetch:({url,init})=>{
  if(url.endsWith('/admit'))return new Response(JSON.stringify({root,exp:1700000002,...JSON.parse(init.body)}),{headers:{'cache-control':'no-store'}});
  if(url.includes('/whip/'))return {status:201,headers:new Headers({location:'/session/exp'}),text:()=>body.promise};
 },remote(){remote++;}});
 const joined=h.room.join(mint());await tick();const timer=h.timers.find(t=>!t.cleared&&t.ms===2000);assert.ok(timer);
 h.time+=2000;timer.fn();assert.equal((await joined).ok,false);assert.equal(h.tracks[0].stopped,true);
 body.resolve('v=0');await tick();assert.equal(remote,0);assert.equal(deleteCalls(h).length,1);
});
test('superseding a held SDP settles it and preserves newer ownership',async()=>{
 const body=deferred();let posts=0;
 const h=harness({fetch:({url})=>{if(url.includes('/whip/')&&++posts===1)return {status:201,headers:new Headers({location:'/session/superseded'}),text:()=>body.promise};}});
 const old=h.room.join(mint());await tick();assert.equal((await h.room.replace(mint())).ok,true);assert.equal((await old).ok,false);
 body.resolve('v=0');await tick();assert.equal(h.room.status().incumbent,2);assert.equal(h.tracks[1].stopped,false);await h.room.teardown();
});
test('current same-element playing/waiting cannot hide blocked recovery',async()=>{
 const p=pageHarness();p.live.incumbent=1;p.live.peers={'bob/cam':{attempt:1}};
 p.deps.onRemoteTrack('bob/cam',1,{track:{kind:'video'}},1);await tick();const tile=p.nodes['#peers'].children[0];
 p.live.incumbent=2;p.live.peers={'bob/cam':{attempt:1}};p.deps.onUpdate();
 p.deps.onRemoteTrack('bob/cam',1,{track:{kind:'video'}},2);await tick();
 tile.parts.video.handlers.playing();tile.parts.video.handlers.waiting();assert.match(tile.parts.p.textContent,/blocked/);assert.equal(p.nodes['#resume'].hidden,false);
});
test('production retry tracks survive an unrelated peer update while connecting',async()=>{
 let h;let bobPosts=0;const answer=deferred();
 const p=pageHarness(d=>{
  h=harness({onUpdate:d.onUpdate,onRemoteTrack:d.onRemoteTrack,
   fetch:({url})=>{if(url.includes('/whep/')&&url.endsWith('/bob/cam')&&++bobPosts===1)return new Response(JSON.stringify({error:'not_started'}),{status:409});},
   async remote(pc){if(pc===h.pcs[3]){pc.ontrack({track:{id:'retry-video',kind:'video',readyState:'live'}});await answer.promise;}}
  });return h.room;
 });
 await h.room.join(mint({peerPaths:['bob/cam','carol/cam']}));
 h.timers.find(t=>!t.cleared&&t.ms===1000).fn();await tick();
 const video=p.nodes['#peers'].children.find(n=>n.dataset.path==='bob/cam').parts.video;
 assert.ok(video.srcObject);assert.equal(h.room.status().peers['bob/cam'].empty,true);
 // A different real peer disconnects while Bob's valid ontrack has fired but ICE is pending.
 h.pcs[2].connectionState='disconnected';h.pcs[2].emit();
 answer.resolve();await tick();assert.equal(h.room.status().peers['bob/cam'].empty,false);
 const retained=video.srcObject;await h.room.teardown();
 assert.ok(retained,'new retry stream was discarded by paint before retry committed; no further ontrack will restore it');
});

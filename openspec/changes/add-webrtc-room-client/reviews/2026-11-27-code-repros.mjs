// Review evidence: these assertions reproduce defects at eb781150, not desired behavior.
// Run from repository root: node --test openspec/changes/add-webrtc-room-client/reviews/2026-11-27-code-repros.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createRoom, validBroadcast } from '../../../../native/mjolnir_room/src/room.js';
const root = `t/${'1'.repeat(32)}/~open/r1`;
const mint = (extra = {}) => ({token:'review-fake-token', root, expectedRoot:root, kind:'open', selfPath:'alice/cam', peerPaths:[], retryMs:1000, ...extra});
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(r => resolve=r); return {promise, resolve}; };
function harness(options = {}) {
  const h = {time:1700000000000, calls:[], pcs:[], tracks:[], timers:[]};
  h.room = createRoom({origin: options.origin || 'http://127.0.0.1:1', now:()=>options.now ? options.now(h) : h.time,
    schedule(fn, ms) {const t={fn,ms,cleared:false};h.timers.push(t);return t;}, clear(t){t.cleared=true;},
    fetch: async (url, init) => {
      const call={url,init};h.calls.push(call);
      if(options.fetch) {const r=await options.fetch(call,h);if(r) return r;}
      if(url.endsWith('/admit')) {
        const intent=JSON.parse(init.body);
        return new Response(JSON.stringify({root,exp:1700000060,...intent}),{headers:{'cache-control':'no-store'}});
      }
      if(init.method==='DELETE') return new Response(null,{status:204});
      return new Response('v=0\r\n',{status:201,headers:{location:`/session/id${h.calls.length}`}});
    },
    async getUserMedia(){const t={stopped:false,stop(){this.stopped=true;}};h.tracks.push(t);return {getTracks:()=>[t]};},
    createPeerConnection(){const pc={connectionState:'new',listeners:[],closed:false,
      addTrack(){},addTransceiver(){},addEventListener(type,fn){this.listeners.push({type,fn});},
      emit(){for(const {type,fn} of this.listeners)if(type==='connectionstatechange')fn();},
      async createOffer(){if(options.offer)await options.offer(pc,h);return {type:'offer',sdp:'v=0\r\n'};},
      async setLocalDescription(d){this.localDescription=d;},
      async setRemoteDescription(){if(options.remote)await options.remote(pc,h);this.connectionState='connected';this.emit();},
      close(){this.closed=true;this.connectionState='closed';this.emit();}};h.pcs.push(pc);return pc;}
  });return h;
}
test('R1: native fetch follows foreign /admit redirect and prompts camera', async () => {
  let foreignRequests=0;
  const foreign=createServer((req,res)=>{foreignRequests++;res.setHeader('cache-control','no-store');res.end(JSON.stringify({root,exp:1700000060,operation:'publish',broadcast:'alice/cam'}));});
  await new Promise(r=>foreign.listen(0,'127.0.0.1',r));
  const source=createServer((req,res)=>{res.writeHead(307,{location:`http://127.0.0.1:${foreign.address().port}/admit`});res.end();});
  await new Promise(r=>source.listen(0,'127.0.0.1',r));
  try {
    const h=harness({origin:`http://127.0.0.1:${source.address().port}`,fetch:({url,init})=>url.endsWith('/admit')?fetch(url,init):null});
    assert.equal((await h.room.join(mint())).ok,true);
    assert.equal(foreignRequests,1);assert.equal(h.tracks.length,1);
  } finally {await Promise.all([source,foreign].map(s=>new Promise(r=>s.close(r))));}
});
test('R2: expiry crossing after admission check still opens camera',async()=>{
  const h=harness({now(h){const time=h.time;h.time=1700000061000;return time;}});
  assert.equal((await h.room.join(mint())).ok,false);
  assert.equal(h.tracks.length,1);
});
test('R3: mutating invitation during admission throws after publisher commits',async()=>{
  const input=mint({peerPaths:['bob/cam']});
  const h=harness({fetch:({url,init})=>{if(url.endsWith('/admit')&&JSON.parse(init.body).operation==='publish')input.peerPaths[0]='eve/cam';}});
  await assert.rejects(h.room.join(input),TypeError);
  assert.equal(h.room.status().incumbent,1);
  assert.equal(h.tracks[0].stopped,false);
});
test('R4: leave waits beyond 2s for DELETE while camera and PC stay live',async()=>{
  const gate=deferred();const h=harness({fetch:({init})=>init.method==='DELETE'?gate.promise:null});
  await h.room.join(mint());let done=false;const leaving=h.room.teardown().then(()=>done=true);
  await new Promise(r=>setTimeout(r,2100));
  assert.equal(done,false);assert.equal(h.tracks[0].stopped,false);assert.equal(h.pcs[0].closed,false);
  gate.resolve(new Response(null,{status:204}));await leaving;
});
test('R5: createOffer rejection escapes and leaves camera/candidate alive',async()=>{
  const h=harness({offer(){throw Error('offer failed');}});
  await assert.rejects(h.room.join(mint()),/offer failed/);
  assert.equal(h.tracks[0].stopped,false);assert.equal(h.room.status().candidate,1);
});
test('R6: valid session Location is lost when remote-description fails',async()=>{
  const h=harness({remote(){throw Error('invalid SDP');}});
  assert.equal((await h.room.join(mint())).error,'setup_failed');
  assert.equal(h.calls.filter(c=>c.init.method==='DELETE').length,0);
});
test('R7: superseded candidate PC remains open until its pending offer finishes',async()=>{
  const gate=deferred();const h=harness({offer(pc,h){if(h.pcs.length===1)return gate.promise;}});
  const first=h.room.join(mint());await tick();
  await h.room.replace(mint({token:'next-fake-token'}));
  assert.equal(h.pcs[0].closed,false);assert.equal(h.tracks[0].stopped,true);
  gate.resolve();await first;
});
test('R8: disconnected then failed queues duplicate retries and retains failed PC',async()=>{
  const h=harness();await h.room.join(mint({peerPaths:['bob/cam']}));
  const peer=h.pcs[1];peer.connectionState='disconnected';peer.emit();peer.connectionState='failed';peer.emit();
  const retries=h.timers.filter(t=>t.ms===1000&&!t.cleared);assert.equal(retries.length,2);
  retries.forEach(t=>t.fn());await tick();
  assert.equal(h.calls.filter(c=>c.url.includes('/whep/')).length,3);
  assert.equal(peer.closed,false);assert.equal(h.room.status().pcs,4);
});
test('R9: peer network failure retains a PC on each retry',async()=>{
  const h=harness({fetch:({url})=>{if(url.includes('/whep/'))throw Error('network');}});
  await h.room.join(mint({peerPaths:['bob/cam']}));
  h.timers.find(t=>t.ms===1000).fn();await tick();
  assert.equal(h.pcs.length,3);assert.equal(h.pcs.filter(p=>!p.closed).length,3);
});
test('R10: paths forbidden by gateway are accepted locally',()=>{
  for(const path of ['a/%2f/b','a/%252f/b','a/%','a/'.repeat(40)+'b'])assert.equal(validBroadcast(path),true);
});
test('R11: WHIP 200 commits though contract requires 201',async()=>{
  const h=harness({fetch:({url})=>url.includes('/whip/')?new Response('v=0\r\n',{status:200,headers:{location:'/session/wrongstatus'}}):null});
  assert.equal((await h.room.join(mint())).ok,true);
});

import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
const boot = (await readFile(new URL('../../../../native/mjolnir_room/page/boot.js',import.meta.url),'utf8')).replace(/^import .*;\n/,'');
function pageHarness() {
  class Stream {constructor(){this.tracks=[];}getTracks(){return this.tracks;}addTrack(t){this.tracks.push(t);}}
  function element(){return {textContent:'',srcObject:null,value:'',dataset:{},handlers:{},children:[],
    addEventListener(k,v){this.handlers[k]=v;},click(){return this.handlers.click();},append(n){this.children.push(n);},
    play(){return Promise.reject(Error('autoplay denied'));},
    querySelector(q){if(q.startsWith('[data-path='))return this.children.find(n=>q===`[data-path="${n.dataset.path}"]`)||null;return this.parts[q];},
    parts:{},set innerHTML(_v){this.parts={h2:element(),video:element(),p:element()};}};}
  const nodes=Object.fromEntries(['status','peers','local-video','notice','join','replace','renew','leave','renew-token'].map(id=>[`#${id}`,element()]));
  nodes['#notice'].textContent='This room is open. The host can read the media.';
  let deps;const live={tracks:1,peers:{'bob/cam':{empty:true}}};
  const media=deferred();
  const ctx={window:{MJOLNIR_ROOM_ORIGIN:'http://127.0.0.1:1'},document:{querySelector:q=>nodes[q],createElement:element},
    location:{hash:'#t=fake',pathname:'/room.html',search:''},history:{replaceState(){}},URLSearchParams,CSS:{escape:x=>x},MediaStream:Stream,
    navigator:{mediaDevices:{getUserMedia:()=>media.promise}},fetch(){},RTCPeerConnection(){},
    createRoom(d){deps=d;return {join:async()=>({ok:true}),replace:async()=>({ok:false,error:'setup_failed'}),status:()=>live,teardown:async()=>({ok:true})};}};
  vm.runInNewContext(boot,ctx);return {ctx,nodes,live,deps,media,Stream};
}
test('R12: peer retry success does not repaint waiting; rejected play can still say playing',async()=>{
  const p=pageHarness();await p.ctx.window.roomClient.join();
  const tile=p.nodes['#peers'].children[0];assert.match(tile.parts.p.textContent,/waiting/);
  p.live.peers['bob/cam'].empty=false;
  p.deps.ontrack('bob/cam',{track:{id:'audio1'}});await tick();
  assert.match(tile.parts.p.textContent,/waiting/);
  await p.ctx.window.roomClient.join();assert.equal(tile.parts.p.textContent,'playing');
});
test('R13: successive peer streams accumulate old audio/video tracks',()=>{
  const p=pageHarness();for(const id of ['a1','v1','a2','v2'])p.deps.ontrack('bob/cam',{track:{id}});
  const video=p.nodes['#peers'].children[0].parts.video;assert.equal(video.srcObject.getTracks().length,4);
});
test('R14: camera wrapper reattaches preview after leave',async()=>{
  const p=pageHarness();const pending=p.deps.getUserMedia({video:true});
  await p.nodes['#leave'].click();assert.equal(p.nodes['#local-video'].srcObject,null);
  const late=new p.Stream();p.media.resolve(late);await pending;
  assert.equal(p.nodes['#local-video'].srcObject,late);
});

test('R15: expiry during createOffer still sends media POST',async()=>{
  const h=harness({offer(pc,h){h.time=1700000061000;}});
  assert.equal((await h.room.join(mint())).ok,false);
  assert.equal(h.calls.filter(c=>c.url.includes('/whip/')).length,1);
});

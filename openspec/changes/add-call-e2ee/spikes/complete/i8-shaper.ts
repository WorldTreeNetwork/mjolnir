// Disposable pinned-MoQ harness, not the product adapter. Run after copying into MOQ/js/e2ee/spike.
// Userspace group-delivery shaper: seeded 2% loss -> 80ms retransmit delay; uniform 0..50ms jitter.
// Virtual delivery timestamps isolate policy counts from machine scheduling; this is not a QUIC benchmark.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {Broadcast as NetBroadcast, Time} from '@moq/net';
import {Duration} from '@moq/clock';
import {Credential} from '@moq/e2ee';
import {trackKey} from '../src/key.ts';
import {GROUP} from '../src/derive.ts';
import {Pump} from '../src/pump.ts';
import {Terminal} from '../src/terminal.ts';
import * as ProtectedGroup from '../src/group.ts';
const ms=(x:number)=>Time.Timestamp.fromMillis(x);
const cred=()=>new Credential({context:new TextEncoder().encode('mjolnir-call/v1/fixture/r1/alice'),kid:1,secret:new Uint8Array(32).fill(17)});
const sub=(n:any)=>n.subscribe({delay:{max:Duration.millis(120000)}});
// Parse actual 20ms Opus packets generated privately by ffmpeg; no media is committed.
function opus(path:string){const b=readFileSync(path),packets:Uint8Array[]=[];let at=0,parts:Buffer[]=[];
 while(at<b.length){assert.equal(b.toString('ascii',at,at+4),'OggS');const count=b[at+26];let p=at+27+count;
  for(let j=0;j<count;j++){const n=b[at+27+j];parts.push(b.subarray(p,p+n));p+=n;if(n<255){packets.push(Buffer.concat(parts));parts=[]}}
  at=p;
 }return packets.slice(2,3002);
}
class Mark {
 newest=-1;opened=new Map<number,number>();mirror:Uint8Array[]=[];
 constructor(readonly span:number){}
 admit(start:number,index:number,plaintext:Uint8Array){
  if(start<this.newest-this.span||index<=(this.opened.get(start)??-1))return false;
  this.newest=Math.max(start,this.newest);this.opened.set(start,index);this.mirror.push(plaintext);
  for(const s of this.opened.keys())if(s<this.newest-this.span)this.opened.delete(s);
  return true;
 }
}
function rng(seed:number){return()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296}}
async function shaped(packets:Uint8Array[],seed:number){
 const c=cred(),g=c.produce(),net=new NetBroadcast.Producer().createTrack(await g.name('audio'),{timescale:Time.Timescale.MILLI,maxAge:null});
 const writer=await g.produce(net,'audio');
 const spans=[0,60,120];const readers=spans.map(()=>c.consume(g.epoch).consume(sub(net),'audio'));
 const queue:any[]=[];const r=rng(seed);let losses=0;
 for(let i=0;i<packets.length;i++){
  const start=i*20;const out=writer.appendGroup(ms(start));await out.writeFrame(ms(start),packets[i]);out.finish();
  const groups=await Promise.all(readers.map(t=>t.recvGroup()));assert(groups.every(Boolean));
  const loss=r()<.02;losses+=+loss;queue.push({start,arrival:start+r()*50+(loss?80:0),groups});
 }
 queue.sort((a,b)=>a.arrival-b.arrival||a.start-b.start);
 const marks=spans.map(w=>new Mark(w));const stats=spans.map(windowMs=>({windowMs,authenticated:0,delivered:0,refused:0,reofferRefused:0,maxRememberedStarts:0}));
 for(const e of queue)for(let i=0;i<spans.length;i++){
  const f=await e.groups[i].readFrame();assert(f);assert.deepEqual(f.plaintext,packets[e.start/20]);stats[i].authenticated++;
  if(marks[i].admit(e.start,0,f.plaintext))stats[i].delivered++;else stats[i].refused++;
  assert.equal(marks[i].admit(e.start,0,f.plaintext),false);stats[i].reofferRefused++;
  stats[i].maxRememberedStarts=Math.max(stats[i].maxRememberedStarts,marks[i].opened.size);
 }
 for(const t of readers)t.close();writer.finish();
 assert(stats[2].delivered>stats[0].delivered);assert(stats[2].maxRememberedStarts<=7);
 console.log(JSON.stringify({seed,frames:packets.length,losses,lossPercent:100*losses/packets.length,jitterMs:50,retransmitMs:80,stats}));
}
async function resume(semantic:string){
 const c=cred(),g=c.produce(),net=new NetBroadcast.Producer().createTrack(await g.name(semantic),{timescale:Time.Timescale.MILLI,maxAge:null});
 const writer=await g.produce(net,semantic);const out=writer.appendGroup(ms(2000));
 for(let i=0;i<5;i++)await out.writeFrame(ms(2000+i),new Uint8Array([i]));
 // Keep a single key/budget, mark and mirror across the raw cursor replacement. Internal APIs are
 // used only to reproduce a transport resuming above index zero, as upstream's own test does.
 const consuming=c.consume(g.epoch),key=trackKey(consuming.credential,consuming.epoch,semantic,GROUP),mark=new Mark(0),mirror=mark.mirror;
 const firstSub=sub(net),raw1=await firstSub.recvGroup();assert(raw1);
 const wrap=(raw:any,s:any)=>ProtectedGroup.Consumer.make(raw,{pump:new Pump(),key,terminal:new Terminal(s)});
 const first=wrap(raw1,firstSub);
 for(let i=0;i<2;i++){const f=await first.readFrame();assert(f);assert(mark.admit(2000,i,f.plaintext))}
 first.close();firstSub.close();
 const secondSub=sub(net),raw2=await secondSub.recvGroup();assert(raw2);
 // Resumed transport index; never renumber ciphertext. Duplicate replayed indices are rejected.
 for(let i=0;i<2;i++){const f=raw2.tryReadFrame();assert(f);assert.equal(mark.admit(2000,i,new Uint8Array([i])),false)}
 const second=wrap(raw2,secondSub);
 for(let i=2;i<5;i++){const f=await second.readFrame();assert(f);assert.equal(f.plaintext[0],i);assert(mark.admit(2000,i,f.plaintext))}
 assert.equal(mark.mirror,mirror);assert.equal(mark.opened.get(2000),4);assert.equal(mirror.length,5);
 second.close();secondSub.close();out.finish();writer.finish();
 console.log(JSON.stringify({resume:semantic,sameKeyBudget:true,sameMirror:true,group:2000,lastIndex:4,uniqueFrames:mirror.length,duplicateIndicesRefused:2}));
}
const packets=opus(process.argv[2]);assert.equal(packets.length,3000);
for(const seed of [17,42,2026])await shaped(packets,seed);
await resume('video');await resume('catalog.json');
console.log('I8 PASS; userspace virtual delivery queue, actual pinned AEAD/MoQ groups and real 20ms Opus packets; no physical network impairment claimed.');

// Removal by a new credential, on the label layout, under real room tokens, discovery by announcement.
// Scenario A (make-before-break): publisher announces the kid-2 broadcast beside the old one; the remaining
//   reader switches by ANNOUNCEMENT (epoch parsed from the path, nothing handed over out of band); the removed
//   reader keeps the old credential and a valid token. Then the publisher retires the old broadcast.
// Scenario B (break-before-make): a fresh publisher announces kid 2 and retires the old broadcast at once.
// Fixture key for kid 2 is the dummy 32 x 0x22 in page.ts.
import {chromium} from 'playwright';import fs from 'node:fs';import crypto from 'node:crypto';
const dir=process.argv[2]||'/tmp/mjolnir-e2ee-private4';const[addr,owner,alice,bob,carol]=fs.readFileSync(dir+'/admission.txt','utf8').trim().split('\n');const hash=new crypto.X509Certificate(fs.readFileSync(dir+'/relay.pem')).fingerprint256.replaceAll(':','').toLowerCase();
// A fresh kid-1 secret per run: runs that share a secret and label share an opaque, and a stale
// announcement from an earlier run on a long-lived relay is then indistinguishable by path.
const RUN_SECRET=crypto.randomBytes(32).toString('base64url'),RUN_SECRET2=crypto.randomBytes(32).toString('base64url');
const browser=await chromium.launch({args:['--autoplay-policy=no-user-gesture-required']});
setTimeout(async()=>{console.log(JSON.stringify({watchdog:'90 s',partial:out}));for(const p of pages){try{const r=await Promise.race([p.cd.send('Profiler.stop'),new Promise((_,r)=>setTimeout(()=>r(Error('profile timeout')),1000))]);const hits=new Map();for(const id of r.profile.samples||[])hits.set(id,(hits.get(id)||0)+1);console.log('HOT '+JSON.stringify(r.profile.nodes.map(n=>({fn:n.callFrame.functionName,line:n.callFrame.lineNumber,hits:hits.get(n.id)||0})).sort((a,b)=>b.hits-a.hits).slice(0,8)))}catch(e){console.log('PROFILE '+e.message)}}process.exit(2)},90000);
const out={browser:browser.version(),layout:'label',discovery:'relay.announced() + path parse',tokens:'room tokens alice/bob/carol, 3600 s'};
const pages=[];async function open(role,token,label,watch='alice'){console.log('OPEN '+role+' '+label);const ctx=await browser.newContext();const p=await ctx.newPage();pages.push(p);p.on('console',m=>{if(/error|PLAYBACK|published/.test(m.text()))console.log(role+':'+m.text())});p.cd=await ctx.newCDPSession(p);await p.cd.send('Profiler.enable');await p.cd.send('Profiler.start');const q=new URLSearchParams({role,relay:'https://'+addr+'/',hash,ctx:'label',label,watch});const f=new URLSearchParams({v:'1',p:'moq-e2ee-01-wip',kid:'1',k:RUN_SECRET,k2:RUN_SECRET2,t:token});await p.goto('http://localhost:8124/?'+q+'#'+f);await p.waitForFunction(()=>window.ready||window.error,null,{timeout:45000});const e=await p.evaluate(()=>window.error);if(e)throw Error(e);p.ctx=ctx;return p}
const startSampler=p=>p.evaluate(()=>{window.samples=[];let id=0,last=null;const tick=()=>{const pl=window.player;if(pl!==last){id++;last=pl}window.samples.push([performance.now(),id,pl.video.out.stats.peek()?.frameCount??0])};window.t0=performance.now();tick();window.sampler=setInterval(tick,10)});
// Longest stretch with no newly decoded frame, counting frames of every player instance the page held.
const gap=p=>p.evaluate(()=>{clearInterval(window.sampler);const s=window.samples;let base=0,prevId=s[0][1],prevF=0,lastAdv=window.t0,worst=0,firstNew=null;
 for(const [t,id,f] of s){if(id!==prevId){base+=prevF;prevId=id;prevF=0}if(f>prevF){if(t>=window.t0){worst=Math.max(worst,t-lastAdv);lastAdv=t;if(id>s[0][1]&&firstNew===null)firstNew=t-window.t0}prevF=f}}
 const per={};for(const [t,id,f] of s){per[id]=per[id]||{firstMs:Math.round(t-window.t0),maxFrames:0,firstAdvanceMs:null};if(f>0&&per[id].firstAdvanceMs===null)per[id].firstAdvanceMs=Math.round(t-window.t0);per[id].maxFrames=Math.max(per[id].maxFrames,f)}
 return {perPlayer:per,longestNoFrameMs:Math.round(worst),firstFrameFromNewPlayerMs:firstNew&&Math.round(firstNew),sampledMs:Math.round(s.at(-1)[0]-window.t0)}});
try{
 // ---- Scenario A
 const pub=await open('pub',alice,'alice'),remaining=await open('sub',bob,'bob'),removed=await open('sub',carol,'carol');
 await startSampler(remaining);const before=await removed.evaluate(()=>window.readMetrics());const started=Date.now();
 const next=await pub.evaluate(()=>window.rotate(false));const announcedMs=Date.now()-started;
 const switched=await remaining.evaluate(()=>window.switchKey());const discoveredMs=Date.now()-started;
 try{await remaining.waitForFunction(()=>{window.player.audio.out.context.peek()?.resume();const m=window.readMetrics();return m.video>=15&&m.audioBytes>1000},null,{timeout:15000})}catch(e){console.log(JSON.stringify({diag:{switched,next:String(next.path),logs:await remaining.evaluate(()=>window.logs.slice(-15)),pubBridge:await pub.evaluate(()=>window.logs.filter(l=>/encrypt bridge: track|listing error/.test(l))),metrics:await remaining.evaluate(()=>window.readMetrics())}}));throw e}
 const playingMs=Date.now()-started;const removedProbe=await removed.evaluate(p=>window.tryRead(p),String(next.path));
 await removed.waitForTimeout(1000);const unretired=await removed.evaluate(()=>window.readMetrics());
 if(unretired.video<=before.video)throw Error('positive control: removed reader should still play the unretired old broadcast');
 const retiredAt=Date.now();console.log('RETIRE_A_BEGIN');await pub.evaluate(()=>window.retire());console.log('RETIRE_A_RETURNED');setTimeout(async()=>{for(const p of pages){try{const r=await p.cd.send('Profiler.stop');const hits=new Map();for(const id of r.profile.samples||[])hits.set(id,(hits.get(id)||0)+1);console.log('RETIRE_HOT '+JSON.stringify(r.profile.nodes.map(n=>({fn:n.callFrame.functionName,line:n.callFrame.lineNumber,file:n.callFrame.url.split('/').pop()?.split('?')[0],hits:hits.get(n.id)||0})).sort((a,b)=>b.hits-a.hits).slice(0,10)))}catch(e){console.log('RETIRE_PROFILE '+e.message)}}},2000);
 let last=await removed.evaluate(()=>window.readMetrics()),lastChangeMs=0;const atRetire=last;
 for(let i=0;i<60;i++){await removed.waitForTimeout(100);const now=await removed.evaluate(()=>window.readMetrics());if(now.video!==last.video||now.audioTime!==last.audioTime)lastChangeMs=Date.now()-retiredAt;last=now}
 const a=await remaining.evaluate(()=>window.readMetrics());await remaining.waitForTimeout(800);const b=await remaining.evaluate(()=>window.readMetrics());if(b.video<=a.video)throw Error('remaining reader stopped');
 out.A={sameSession:switched.sessionSame,newPath:String(next.path),announcedMs,discoveredByAnnouncementMs:discoveredMs,playing15FramesMs:playingMs,remainingGap:await gap(remaining),
  removedWhileOldUnretired:{additionalDecodedFrames:unretired.video-before.video},removedReadsNewBroadcast:removedProbe,
  afterRetire:{removedDecodedFrames:last.video-atRetire.video,lastRemovedMediaChangeMs:lastChangeMs,observedMs:Date.now()-retiredAt},remainingAdvancedFrames:b.video-a.video};
 console.log(JSON.stringify({A:out.A}));
 for(const p of [pub,remaining,removed])await p.ctx.close();
 // ---- Scenario B
 // Own label (carol publishes) so no announcement from scenario A shares its opaque.
 const pub2=await open('pub',carol,'carol'),reader=await open('sub',bob,'bob','carol');
 await startSampler(reader);const t=Date.now();
 const limit=ms=>new Promise((_,rej)=>setTimeout(()=>rej(Error('scenario B: no switch within '+ms+' ms')),ms));
 const [next2,sw2]=await Promise.race([Promise.all([pub2.evaluate(()=>window.rotate(true)),reader.evaluate(()=>window.switchKey())]),limit(20000)]);const disc2=Date.now()-t;
 let recovered=true;try{await reader.waitForFunction(()=>{window.player.audio.out.context.peek()?.resume();const m=window.readMetrics();return m.video>=15&&m.audioBytes>1000},null,{timeout:15000})}catch{recovered=false}
 await reader.waitForTimeout(1000);
 out.B={label:'carol',switched:sw2,retiredImmediately:true,discoveredByAnnouncementMs:disc2,recovered,playing15FramesMs:Date.now()-t-1000,readerGap:await gap(reader)};
 console.log(JSON.stringify({B:out.B}));
}finally{console.log(JSON.stringify(out));console.log('CLOSE_BEGIN');await browser.close();console.log('CLOSE_RETURNED')}

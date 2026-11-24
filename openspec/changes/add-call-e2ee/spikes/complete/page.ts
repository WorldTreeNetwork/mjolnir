import { Connection, Origin, Path } from '@moq/net';
import { Broadcast, Credential, Epoch } from '@moq/e2ee';
import {inviteFields,announcedPath,contextFor,semanticFor,variantOf} from './validation.ts';
import * as Publish from '../../publish/src/index.ts';
import * as Watch from '../../watch/src/index.ts';
import { encryptBridge, decryptBridge } from './bridge.ts';
const q=new URLSearchParams(location.search);
const invite=new URLSearchParams(location.hash.slice(1));
history.replaceState(null,'',location.pathname+location.search);
const w=window as any;
w.logs=[]; w.metrics={};
const log=(s:string)=>{w.logs.push(s); console.log(s)};
const enc=new TextEncoder();
function parseInvite() {
 const {raw,token,kid}=inviteFields(invite);
 const claims=JSON.parse(atob(token.split('.')[1].replaceAll('-','+').replaceAll('_','/')));
 return {raw,token,kid,root:claims.root as string};
}
async function main(){
 Publish.assets(new URL("/assets/",location.href));Watch.assets(new URL("/assets/",location.href));
 const v=parseInvite();
 const key=await crypto.subtle.importKey('raw',v.raw,'HKDF',false,['deriveBits']);v.raw.fill(0);
 const variant=variantOf(q),label=q.get('label')??'alice',watch=q.get('watch')??'alice',codec=q.get('codec')??'vp8';
 const credFor=(l:string,kid=v.kid,secret:CryptoKey|Uint8Array=key)=>new Credential({context:enc.encode(contextFor(variant,v.root,l)),kid,secret});
 // Second credential (removal by rekey). Fixture: from the fragment `k2` if given, else the dummy 32 x 0x22.
 const k2text=invite.get('k2');const K2=k2text?Uint8Array.from(atob(k2text.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0)):new Uint8Array(32).fill(34);
 const cred=credFor(label);w.layout={variant,context:contextFor(variant,v.root,label).replace(/v1\/[^/]+\//,'v1/<owner>/'),semantic:semanticFor(variant,label)};log('layout '+JSON.stringify(w.layout));
 try {await crypto.subtle.exportKey('raw',key);throw Error('EXPORT SUCCEEDED')} catch(e:any){if(e.message==='EXPORT SUCCEEDED')throw e;log('root export rejected '+e.name)}
 const relay=new Origin.Producer();
 const url=new URL(q.get('relay')!);url.searchParams.set('jwt',v.token);
 const s=await Connection.connect({url,webtransport:{serverCertificateHashes:[{value:q.get('hash')!}]},websocket:{enabled:false},publish:q.get('role')==='pub'?relay.consume():undefined,consume:q.get('role')==='pub'?undefined:relay});
 log('connected '+s.transport+' '+s.version);w.session=s;
 const control=q.get('control')==='plaintext';
 const local=control?relay:new Origin.Producer();const LOCAL=Path.from(control?'alice/call':'local');
 if(q.get('role')==='pub'){
  const canvas=document.createElement('canvas');canvas.width=320;canvas.height=180;document.body.append(canvas);
  const ctx=canvas.getContext('2d')!;let n=0;
  setInterval(()=>{ctx.fillStyle=`hsl(${n++*7%360} 100% 50%)`;ctx.fillRect(0,0,320,180);ctx.fillStyle='black';ctx.fillRect(n%280,30,40,60)},33);
  const video=canvas.captureStream(30).getVideoTracks()[0];
  const ac=new AudioContext({sampleRate:48000});await ac.resume();const osc=ac.createOscillator();osc.frequency.value=440;
  const dst=ac.createMediaStreamDestination();osc.connect(dst);osc.start();
  const capture=new Publish.Video.Capture({source:video});
  const broadcast=new Publish.Broadcast({origin:local,enabled:true,name:LOCAL,display:capture.out.display,rotation:capture.out.rotation});
  broadcast.catalog.mutate((c:any)=>{c.spike={displayName:'E2EE-TEST-DISPLAY-ALICE-57'}});
  const ve=new Publish.Video.Encoder('video',{broadcast,capture,enabled:true,config:{codec}});
  const audioCapture=new Publish.Audio.Capture({source:dst.stream.getAudioTracks()[0]});
  const ae=new Publish.Audio.Encoder('audio',{broadcast,capture:audioCapture,enabled:true});
  w.publisher={broadcast,ve,ae,ac};
  const generation=cred.produce();const path=Path.from(label+'/'+await cred.path(semanticFor(variant,label))+'/'+generation.epoch);
  const info=control?{physical:{'catalog.json':'catalog.json',video:'video',audio:'audio'}}:await encryptBridge({local,localPath:LOCAL,relay,path,generation,log});
  w.info={path:control?LOCAL:path,physical:info.physical};
  w.rotate=async(retire=true)=>{
   const next=credFor(label,2,K2.slice());const gen=next.produce();
   const np=Path.from(label+'/'+await next.path(semanticFor(variant,label))+'/'+gen.epoch);
   const bridge=await encryptBridge({local,localPath:LOCAL,relay,path:np,generation:gen,log});
   if(retire)(info as any).retire();return {path:np,physical:bridge.physical};
  };
  w.retire=()=>{(info as any).retire()};
  // Passive-capture reference: read our own ciphertext from the local relay origin (no wire traffic).
  w.cipher={};w.recordCipher=async(limit=200)=>{const f=relay.follow(w.info.path);let b=f.active.peek();while(!b){await f.active.changed();b=f.active.peek()}
   for(const [semantic,physical] of Object.entries(info.physical)){w.cipher[semantic]=[];void(async()=>{const sub=b!.track(physical as string).subscribe({});for(;;){const g=await sub.recvGroup();if(!g)return;let index=0;void(async()=>{for(let fr=await g.readFrame();fr;fr=await g.readFrame()){if(w.cipher[semantic].length<limit)w.cipher[semantic].push({group:String(g.start),index:index++,payload:btoa(String.fromCharCode(...fr.payload))})}})().catch(()=>{})}})().catch(()=>{})}};
  log('published '+path);w.ready=true;
 }else{
  let path:any,epoch:any,rcred:any=cred;
 if(control){path=LOCAL}else{
  for await(const ev of relay.announced()){
   if(ev.kind!=='present'&&ev.kind!=='available')continue;
   const parts=String(ev.prefix).split('/');
   if(parts.length!==3||parts[0]!==watch)continue;
   let ok;try{ok=await announcedPath(String(ev.prefix),l=>credFor(l),variant)}catch(e){log('rejected announcement '+ev.prefix+' '+e);continue}
   epoch=ok.epoch;rcred=ok.credential;path=Path.from(parts.join('/'));break;
  }
  }
  if(!path)throw Error('no valid announcement');
  log('discovered '+path);
  if(!control)await decryptBridge({relay,path,credential:rcred,appEpoch:()=>epoch,local,localPath:LOCAL,log});
  const canvas=document.createElement('canvas');document.body.append(canvas);
  const player=new Watch.Player({origin:local,name:LOCAL,video:{canvas,backend:'2d'},audio:{muted:false,volume:0}});w.player=player;
  w.readMetrics=()=>({video:w.player.video.out.stats.peek()?.frameCount??0,audioBytes:w.player.audio.out.stats.peek()?.bytesReceived??0,audioTime:w.player.audio.out.timestamp.peek()?.asMicros()??0});
  w.switchKey=async()=>{
   const next=credFor(watch,2,K2.slice());
   for await(const ev of relay.announced()){
    if(ev.kind!=='present')continue;const parts=String(ev.prefix).split('/');
    if(parts.length!==3||parts[0]!==watch||parts[1]!==await next.path(semanticFor(variant,watch)))continue;
    // Several announcements can carry the same opaque (same credential and label): a closed publisher's
    // announcement may linger. Take the first one that is actually active within 1.5 s.
    {const f=relay.follow(Path.from(ev.prefix));let b=f.active.peek();const until=Date.now()+1500;while(!b&&Date.now()<until){await Promise.race([f.active.changed(),new Promise(r=>setTimeout(r,100))]);b=f.active.peek()}
     if(!b){log('switchKey: skipped inactive candidate '+ev.prefix);w.skipped=(w.skipped||0)+1;continue}}
    const epoch=Epoch.parse(parts[2]);const newLocal=Path.from('rekey-local');
    await decryptBridge({relay,path:Path.from(ev.prefix),credential:next,appEpoch:()=>epoch,local,localPath:newLocal,log});
    w.player.close();w.player=new Watch.Player({origin:local,name:newLocal,video:{canvas,backend:'2d'},audio:{muted:false,volume:0}});
    return {sessionSame:w.session===s,path:ev.prefix,skippedInactive:w.skipped||0};
   }
  };
  // Removed-member probe: what can this page's CURRENT (old) credential do with a broadcast it did not discover?
  w.tryRead=async(p:string)=>{const out:any={path:p};
   try{await announcedPath(p,l=>credFor(l),variant);out.discoveryRule='accepted'}catch(e){out.discoveryRule='rejected: '+e}
   try{const f=relay.follow(Path.from(p));let b=f.active.peek();const until=Date.now()+5000;while(!b&&Date.now()<until){await Promise.race([f.active.changed(),new Promise(r=>setTimeout(r,250))]);b=f.active.peek()}
    if(!b)throw Error('no active broadcast');out.broadcastVisible=true;
    const bc=new Broadcast.Consumer(b,rcred.consume(Epoch.parse(p.split('/')[2])));const t=await bc.subscribe('bridge.tracks',{});
    const g:any=await Promise.race([t.recvGroup(),new Promise((_,rej)=>setTimeout(()=>rej(Error('no group in 5 s')),5000))]);const fr=await g.readFrame();out.read='PLAINTEXT '+new TextDecoder().decode(fr.plaintext)}catch(e){out.read=String(e)}
   return out};
  const checks=new Set<number>();let samples=0,energy=0,peak=0;let analyser:AnalyserNode|undefined;
  for(let i=0;i<200;i++){
   await new Promise(r=>setTimeout(r,100));
   if(canvas.width&&canvas.height){const d=canvas.getContext('2d')!.getImageData(0,0,canvas.width,canvas.height).data;let sum=0;for(let j=0;j<d.length;j+=4)sum=(sum+d[j]*3+d[j+1]*5+d[j+2]*7)%1000000007;if(sum)checks.add(sum)}
   const root=player.audio.out.root.peek();const ac=player.audio.out.context.peek();
   if(ac)await ac.resume();
   if(root&&!analyser){analyser=root.context.createAnalyser();analyser.fftSize=2048;root.connect(analyser)}
   if(analyser){const a=new Float32Array(2048);analyser.getFloatTimeDomainData(a);for(const x of a){energy+=x*x;peak=Math.max(peak,Math.abs(x));samples++}}
   w.metrics={uniqueFrames:checks.size,samples,rms:Math.sqrt(energy/Math.max(1,samples)),peak,decodedVideo:player.video.out.stats.peek()?.frameCount,videoError:String(player.video.out.error.peek()??"")};
   if(checks.size>=15&&peak>0.01&&samples>10000){log('PLAYBACK '+JSON.stringify(w.metrics));w.ready=true;return}
  }
  throw Error('playback threshold missed '+JSON.stringify(w.metrics));
 }
}
async function tap(){
 const relay=new Origin.Producer();const url=new URL(q.get('relay')!);url.searchParams.set('jwt',invite.get('t')!);
 await Connection.connect({url,webtransport:{serverCertificateHashes:[{value:q.get('hash')!}]},websocket:{enabled:false},consume:relay});
 w.tapData={};w.tapErrors={};
 w.startTap=async (info:any)=>{
  const follow=relay.follow(Path.from(info.path));let remote=follow.active.peek();while(!remote){await follow.active.changed();remote=follow.active.peek()}
  for(const [semantic,physical] of Object.entries(info.physical)){
   w.tapData[semantic]=[];
   void(async()=>{const sub=remote!.track(physical as string).subscribe({});for(;;){const g=await sub.recvGroup();if(!g)return;let index=0;void(async()=>{for(let f=await g.readFrame();f;f=await g.readFrame()){
    if(w.tapData[semantic].length<200)w.tapData[semantic].push({group:String(g.start),index:index++,payload:btoa(String.fromCharCode(...f.payload))});
   }})().catch(e=>{w.tapErrors[semantic]=String(e)})}})().catch(e=>{w.tapErrors[semantic]=String(e)});
  }
  if(q.get('control')!=='plaintext'&&q.get('attack')==='1'){
   try {const sub=remote.track('video').subscribe({});await sub.recvGroup();w.semantic='unexpected success'}catch(e){w.semantic=String(e)}
  }
 };
 w.ready=true;
}
(q.get('role')==='tap'?tap():main()).catch(e=>{w.error=String(e);log('ERROR '+e.stack)});

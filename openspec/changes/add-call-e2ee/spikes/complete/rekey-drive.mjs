import {chromium} from 'playwright';import fs from 'node:fs';import crypto from 'node:crypto';
const dir=process.argv[2]||'/tmp/mjolnir-e2ee-private2';const[addr,owner,alice,bob,carol]=fs.readFileSync(dir+'/admission.txt','utf8').trim().split('\n');const hash=new crypto.X509Certificate(fs.readFileSync(dir+'/relay.pem')).fingerprint256.replaceAll(':','').toLowerCase();
const browser=await chromium.launch({args:['--autoplay-policy=no-user-gesture-required']});
try{
 async function open(role,token){const p=await(await browser.newContext()).newPage();const q=new URLSearchParams({role,relay:'https://'+addr+'/',hash});const f=new URLSearchParams({v:'1',p:'moq-e2ee-01-wip',kid:'1',k:Buffer.alloc(32,17).toString('base64url'),t:token});await p.goto('http://localhost:8124/?'+q+'#'+f);await p.waitForFunction(()=>window.ready||window.error,null,{timeout:45000});const e=await p.evaluate(()=>window.error);if(e)throw Error(e);return p}
 const pub=await open('pub',alice),remaining=await open('sub',bob),removed=await open('sub',carol);
 const before=await removed.evaluate(()=>window.readMetrics());const started=Date.now();
 const next=await pub.evaluate(()=>window.rotate(false));const switched=await remaining.evaluate(()=>window.switchKey());
 try{await remaining.waitForFunction(()=>{window.player.audio.out.context.peek()?.resume();return window.readMetrics().video>=15&&window.readMetrics().audioBytes>1000},null,{timeout:15000});}catch(e){console.log(JSON.stringify(await remaining.evaluate(()=>({metrics:window.readMetrics(),logs:window.logs.slice(-20),error:window.player.video.out.error.peek()?.message,catalog:window.player.broadcast.out.catalog.peek()}))));throw e}
 const switchMs=Date.now()-started;await removed.waitForTimeout(1000);const unretired=await removed.evaluate(()=>window.readMetrics());
 if(unretired.video<=before.video)throw Error('missed-retirement positive control did not continue old media');
 const retiredAt=Date.now();await pub.evaluate(()=>window.retire());
 let last=await removed.evaluate(()=>window.readMetrics()),lastChangeMs=0;const atRetire=last;
 for(let i=0;i<60;i++){await removed.waitForTimeout(100);const now=await removed.evaluate(()=>window.readMetrics());if(now.video!==last.video||now.audioTime!==last.audioTime)lastChangeMs=Date.now()-retiredAt;last=now}
 if(lastChangeMs>3000)throw Error('removed reader exceeded tested 3s buffer bound');
 const a=await remaining.evaluate(()=>window.readMetrics());await remaining.waitForTimeout(800);const b=await remaining.evaluate(()=>window.readMetrics());if(b.video<=a.video)throw Error('remaining reader stopped');
 console.log(JSON.stringify({browser:browser.version(),sameSession:switched.sessionSame,switchMs,unretiredAdditionalDecodedFrames:unretired.video-before.video,postRetirementDecodedFrames:last.video-atRetire.video,lastRemovedMediaChangeMs:lastChangeMs,observationMs:Date.now()-retiredAt,remainingAdvancedFrames:b.video-a.video,remainingAudioBytes:b.audioBytes}));
}finally{await browser.close()}

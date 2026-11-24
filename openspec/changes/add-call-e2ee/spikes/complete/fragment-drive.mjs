import {chromium} from 'playwright';import fs from 'node:fs';import crypto from 'node:crypto';
const dir=process.argv[2]||'/tmp/mjolnir-e2ee-private2';const[addr,owner,alice]=fs.readFileSync(dir+'/admission.txt','utf8').trim().split('\n');
const hash=new crypto.X509Certificate(fs.readFileSync(dir+'/relay.pem')).fingerprint256.replaceAll(':','').toLowerCase();
const secret=Buffer.alloc(32,17);const patterns=[secret,Buffer.from(secret.toString('hex')),Buffer.from(secret.toString('base64url'))];
function leaks(buffers){return buffers.flatMap((b,i)=>patterns.filter(p=>Buffer.from(b).includes(p)).map(()=>i))}
const browser=await chromium.launch({args:['--autoplay-policy=no-user-gesture-required']});
try{
 const p=await browser.newPage();const req=[];p.on('request',r=>{req.push(JSON.stringify({url:r.url(),headers:r.headers()}));if(r.postDataBuffer())req.push(r.postDataBuffer())});
 const q=new URLSearchParams({role:'pub',relay:'https://'+addr+'/',hash});const f=new URLSearchParams({v:'1',p:'moq-e2ee-01-wip',kid:'1',k:secret.toString('base64url'),t:alice});
 const started=Date.now();await p.goto('http://localhost:8124/?'+q+'#'+f);await p.waitForFunction(()=>window.ready||window.error);if(await p.evaluate(()=>window.error))throw Error('publisher failed');
 await p.evaluate(()=>fetch('/mint',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ttl:60})}));
 await p.waitForTimeout(60000);
 const fragment=await p.evaluate(()=>location.hash);if(fragment||leaks(req).length)throw Error('corrected flow leaked');
 if(req.some(r=>r.includes(alice)))throw Error('token in HTTP page/mint request');
 const safe={browser:browser.version(),elapsedMs:Date.now()-started,requests:req.length,fragmentRemoved:!fragment,keyLeaks:0,pageOrMintTokenLeaks:0,mintBody:'{"ttl":60}'};
 // Deliberately leak each representation in an HTTP request. The same detector must reject it.
 for(const body of [secret.toString('hex'),secret.toString('base64url'),Array.from(secret)])await p.evaluate(body=>fetch('/leak-control',{method:'POST',body:typeof body==='string'?body:new Uint8Array(body)}),body);
 const detected=leaks(req);if(detected.length<3)throw Error('positive control failed');
 console.log(JSON.stringify({...safe,deliberateLeakDetected:detected.length,positiveControlRejected:true}));
}finally{await browser.close()}

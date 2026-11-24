import {chromium} from 'playwright';import fs from 'node:fs';import crypto from 'node:crypto';import {spawn} from 'node:child_process';
const [mode='plaintext',dir='/tmp/mjolnir-e2ee-private2']=process.argv.slice(2);
const [addr,owner,alice,bob,carol]=fs.readFileSync(dir+'/admission.txt','utf8').trim().split('\n');
const hash=new crypto.X509Certificate(fs.readFileSync(dir+'/relay.pem')).fingerprint256.replaceAll(':','').toLowerCase();
const capture=spawn('tshark',['-i','lo0','-f','udp port '+addr.split(':')[1],'-w',dir+'/'+mode+'.pcapng'],{stdio:['ignore','ignore',fs.openSync(dir+'/'+mode+'-tshark.log','w')]});
await new Promise(r=>setTimeout(r,800));
const browser=await chromium.launch({args:['--autoplay-policy=no-user-gesture-required']});
try{
 async function open(role,token){const page=await(await browser.newContext()).newPage();page.on('console',m=>{if(m.text().startsWith('ERROR'))console.log(m.text())});
 const q=new URLSearchParams({role,control:mode,relay:'https://'+addr+'/',hash});const f=new URLSearchParams({v:'1',p:'moq-e2ee-01-wip',kid:'1',t:token});if(role!=='tap')f.set('k',Buffer.alloc(32,17).toString('base64url'));
 await page.goto('http://localhost:8124/?'+q+'#'+f);await page.waitForFunction(()=>window.ready||window.error,null,{timeout:45000});const error=await page.evaluate(()=>window.error);if(error)throw Error(error);return page}
 const pub=await open('pub',alice);const info=await pub.evaluate(()=>window.info);
 const taps=[await open('tap',carol),await open('tap',bob)];for(const tap of taps)await tap.evaluate(info=>window.startTap(info),info);
 const holders=[];for(const token of [bob,carol]){const p=await open('sub',token);holders.push(await p.evaluate(()=>window.metrics))}
 await new Promise(r=>setTimeout(r,3000));
 const data=[];for(const tap of taps)data.push(await tap.evaluate(()=>({tracks:window.tapData,errors:window.tapErrors,semantic:window.semantic})));
 fs.writeFileSync(dir+'/'+mode+'-tap.json',JSON.stringify({info,data}));
 console.log(JSON.stringify({mode,browser:browser.version(),holders,taps:data.map(t=>({counts:Object.fromEntries(Object.entries(t.tracks).map(([k,v])=>[k,v.length])),errors:t.errors,semantic:t.semantic}))}));
}finally{await browser.close();capture.kill('SIGINT');await new Promise(r=>capture.on('exit',r))}

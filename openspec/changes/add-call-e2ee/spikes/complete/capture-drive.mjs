// Relay-key capture driver. Modes:
//   plaintext  positive control: no encryption, publisher + two subscribers, publisher's own payloads as reference.
//   encrypted  passive: ONLY credential holders on the wire (publisher alice, holders bob and carol). No tap, no probe.
//              Reference ciphertext is read by the publisher from its own local relay origin (no wire traffic).
//   tokenonly  separate capture: publisher + one holder + one token-without-credential client (carol) that
//              is handed the physical names (what the relay learns) and also asks for the semantic name "video".
import {chromium} from 'playwright';import fs from 'node:fs';import crypto from 'node:crypto';import {spawn} from 'node:child_process';
const [mode='plaintext',dir='/tmp/mjolnir-e2ee-private3']=process.argv.slice(2);
const [addr,owner,alice,bob,carol]=fs.readFileSync(dir+'/admission.txt','utf8').trim().split('\n');
const hash=new crypto.X509Certificate(fs.readFileSync(dir+'/relay.pem')).fingerprint256.replaceAll(':','').toLowerCase();
const capture=spawn('tshark',['-i','lo0','-f','udp port '+addr.split(':')[1],'-w',dir+'/'+mode+'.pcapng'],{stdio:['ignore','ignore',fs.openSync(dir+'/'+mode+'-tshark.log','w')]});
for(let i=0;i<50&&!fs.readFileSync(dir+'/'+mode+'-tshark.log','utf8').includes('Capturing');i++)await new Promise(r=>setTimeout(r,100));
const browser=await chromium.launch({args:['--autoplay-policy=no-user-gesture-required']});
const control=mode==='plaintext'?'plaintext':'';
try{
 async function open(role,token,label,extra={}){const page=await(await browser.newContext()).newPage();page.on('console',m=>{if(m.text().startsWith('ERROR'))console.log(m.text())});
  const q=new URLSearchParams({role,control,relay:'https://'+addr+'/',hash,ctx:process.env.CTX||'label',label,...extra});const f=new URLSearchParams({v:'1',p:'moq-e2ee-01-wip',kid:'1',t:token});if(role!=='tap')f.set('k',Buffer.alloc(32,17).toString('base64url'));
  await page.goto('http://localhost:8124/?'+q+'#'+f);await page.waitForFunction(()=>window.ready||window.error,null,{timeout:45000});const error=await page.evaluate(()=>window.error);if(error)throw Error(error);return page}
 const pub=await open('pub',alice,'alice');const info=await pub.evaluate(()=>window.info);await pub.evaluate(()=>window.recordCipher(200));
 let tap;if(mode==='tokenonly'){tap=await open('tap',carol,'carol',{attack:'1'});await tap.evaluate(info=>window.startTap(info),info)}
 const holders=[];for(const [token,label] of (mode==='tokenonly'?[[bob,'bob']]:[[bob,'bob'],[carol,'carol']])){const p=await open('sub',token,label);holders.push(await p.evaluate(()=>window.metrics))}
 await new Promise(r=>setTimeout(r,3000));
 const own=await pub.evaluate(()=>window.cipher);
 const tapData=tap?await tap.evaluate(()=>({tracks:window.tapData,errors:window.tapErrors,semantic:window.semantic})):null;
 fs.writeFileSync(dir+'/'+mode+'-tap.json',JSON.stringify({info,data:[{tracks:own}],tokenOnly:tapData}));
 const count=t=>Object.fromEntries(Object.entries(t).map(([k,v])=>[k,v.length]));
 console.log(JSON.stringify({mode,browser:browser.version(),onWire:mode==='tokenonly'?['pub alice (holder)','sub bob (holder)','tap carol (token, no credential)']:['pub alice (holder)','sub bob (holder)','sub carol (holder)'],layout:await pub.evaluate(()=>window.layout),path:String(info.path),holders,referenceFrames:count(own),
  tokenOnly:tapData&&{receivedCiphertextFrames:count(tapData.tracks),errors:tapData.errors,semanticVideoSubscribe:tapData.semantic}}));
}finally{await browser.close();capture.kill('SIGINT');await new Promise(r=>capture.on('exit',r))}

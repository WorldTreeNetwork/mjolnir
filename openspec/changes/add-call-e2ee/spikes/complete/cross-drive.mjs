// Review B5: browser reads native (label nat, H.264 + Opus from iroh-live) and native reads browser
// (label alice, published by the browser as H.264 so the native player, H.264-only, can decode it).
import {chromium,firefox} from 'playwright';import fs from 'node:fs';import crypto from 'node:crypto';
const [which='chromium',dir='/tmp/mjolnir-e2ee-private4',publish='1']=process.argv.slice(2);
const [addr,owner,alice,bob]=fs.readFileSync(dir+'/admission.txt','utf8').trim().split('\n');
const hash=new crypto.X509Certificate(fs.readFileSync(dir+'/relay.pem')).fingerprint256.replaceAll(':','').toLowerCase();
const browser=await ({chromium,firefox}[which]).launch(which==='chromium'?{args:['--autoplay-policy=no-user-gesture-required']}:{firefoxUserPrefs:{'media.autoplay.default':0,'media.autoplay.blocking_policy':0}});
const out={browser:which,version:browser.version()};
try{
 async function open(role,token,label,extra={}){const page=await(await browser.newContext()).newPage();
  page.on('console',m=>{const t=m.text();if(/ERROR|discovered|layout|rejected|decrypt bridge: track/.test(t))console.log(role+': '+t)});
  const q=new URLSearchParams({role,relay:'https://'+addr+'/',hash,ctx:'label',label,...extra});const f=new URLSearchParams({v:'1',p:'moq-e2ee-01-wip',kid:'1',k:Buffer.alloc(32,17).toString('base64url'),t:token});
  await page.goto('http://localhost:8124/?'+q+'#'+f);return page}
 const pp=await browser.newPage();await pp.goto('http://localhost:8124/?role=probe');const probe=await pp.evaluate(async()=>({h264Encode:(await VideoEncoder.isConfigSupported({codec:'avc1.42001f',width:320,height:180})).supported,h264Decode:(await VideoDecoder.isConfigSupported({codec:'avc1.42001f'})).supported}));
 out.webcodecs=probe;console.log(JSON.stringify(probe));
 if(publish==='1'){const pub=await open('pub',alice,'alice',{codec:'avc1'});await pub.waitForFunction(()=>window.ready||window.error,null,{timeout:45000});out.browserPublish=await pub.evaluate(()=>({error:window.error,path:String(window.info?.path)}))}
 const sub=await open('sub',bob,'bob',{watch:'nat'});
 try{await sub.waitForFunction(()=>window.ready||window.error,null,{timeout:45000})}catch(e){}
 out.browserReadsNative=await sub.evaluate(()=>({error:window.error,metrics:window.metrics,logs:window.logs.filter(l=>/discovered|decrypt bridge: track|PLAYBACK|ERROR/.test(l)).slice(0,12)}));
 if(publish==='1'){for(let i=0;i<150&&!fs.existsSync(dir+'/native-read-browser.json');i++)await new Promise(r=>setTimeout(r,500));
  out.nativeReadsBrowser=fs.existsSync(dir+'/native-read-browser.json')?JSON.parse(fs.readFileSync(dir+'/native-read-browser.json','utf8')):{error:'no result file within 75 s'}}
}finally{console.log(JSON.stringify(out));await browser.close()}

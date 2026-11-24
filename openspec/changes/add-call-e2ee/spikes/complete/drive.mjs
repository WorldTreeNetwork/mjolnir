import {chromium,firefox} from 'playwright';
import fs from 'node:fs';import crypto from 'node:crypto';
const [which='chromium',dir='/tmp/mjolnir-e2ee-private']=process.argv.slice(2);
const [addr,owner,alice,bob,carol]=fs.readFileSync(dir+'/admission.txt','utf8').trim().split('\n');
const hash=new crypto.X509Certificate(fs.readFileSync(dir+'/relay.pem')).fingerprint256.replaceAll(':','').toLowerCase();
const browser=await ({chromium,firefox}[which]).launch(which==='chromium'?{args:['--autoplay-policy=no-user-gesture-required']}:{firefoxUserPrefs:{'media.autoplay.default':0,'media.autoplay.blocking_policy':0}});
const secret=Buffer.alloc(32,17), representations=[secret.toString('hex'),secret.toString('base64url'),secret.toString('latin1')];
const requests=[];
let ok=false;
try{
 for(const [role,token] of [['pub',alice],['sub',bob]]){
 const ctx=await browser.newContext();const page=await ctx.newPage();
 page.on('request',r=>requests.push({url:r.url(),headers:r.headers(),body:r.postData()}));
 page.on('console',m=>console.log(role+': '+m.text().replaceAll(token,'[TOKEN]')));
 page.on('console',async m=>{if(m.type()==='error')for(const a of m.args())try{console.log(role+' DETAIL '+await a.evaluate(v=>v?.stack||v?.message||String(v)))}catch{}});
 page.on('pageerror',e=>console.log(role+': ERROR '+e));
 const q=new URLSearchParams({role,relay:'https://'+addr+'/',hash,ctx:process.env.CTX||'label',label:role==='pub'?'alice':'bob',codec:process.env.CODEC||'vp8'});
 const fragment=new URLSearchParams({v:'1',p:'moq-e2ee-01-wip',kid:'1',k:secret.toString('base64url'),t:token});
 await page.goto('http://localhost:8124/?'+q+'#'+fragment);
 await page.waitForFunction(()=>window.ready||window.error,null,{timeout:45000});
 const result=await page.evaluate(()=>({error:window.error,metrics:window.metrics,fragment:location.hash}));
 console.log(JSON.stringify({browser:which,version:browser.version(),role,...result}));
 if(result.error)throw Error(result.error);
 if(result.fragment)throw Error('fragment retained');
 }
 const serialized=JSON.stringify(requests);const leaks=representations.filter(x=>serialized.includes(x));
 if(leaks.length)throw Error('network credential leak');
 console.log(JSON.stringify({requestCount:requests.length,contentKeyLeaks:leaks.length}));ok=true;
}finally{await browser.close()}
process.exit(ok?0:1);

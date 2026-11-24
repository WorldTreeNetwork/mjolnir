// Review B3c: after a join that scrubs the fragment with history.replaceState, does the browser's
// PERSISTENT history (Chromium `History`, Firefox `places.sqlite`) still hold the URL with the secret?
// Control: a static page that does NOT scrub must show its fragment in the same store, proving the
// store records fragments at all. The secret is the dummy fixture key (32 x 0x11). Prints booleans only.
import {chromium,firefox} from 'playwright';import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import crypto from 'node:crypto';import {execFileSync} from 'node:child_process';
const [which='chromium',dir='/tmp/mjolnir-e2ee-private4']=process.argv.slice(2);
const [addr,owner,alice]=fs.readFileSync(dir+'/admission.txt','utf8').trim().split('\n');
const hash=new crypto.X509Certificate(fs.readFileSync(dir+'/relay.pem')).fingerprint256.replaceAll(':','').toLowerCase();
const key=Buffer.alloc(32,17).toString('base64url');
const profile=fs.mkdtempSync(path.join(dir,'profile-'+which+'-'));
const opts=which==='chromium'
 ?{channel:'chromium',headless:true,args:['--autoplay-policy=no-user-gesture-required']}  // full Chromium (new headless), not headless-shell
 :{headless:true,firefoxUserPrefs:{'media.autoplay.default':0,'places.history.enabled':true}};
const ctx=await ({chromium,firefox}[which]).launchPersistentContext(profile,opts);
const out={browser:which,version:ctx.browser()?.version()};
try{
 const p=ctx.pages()[0]||await ctx.newPage();
 await p.goto('http://localhost:8124/control.html#control-fragment-kept');await p.waitForTimeout(500);
 const q=new URLSearchParams({role:'pub',relay:'https://'+addr+'/',hash,ctx:'label',label:'alice'});
 const f=new URLSearchParams({v:'1',p:'moq-e2ee-01-wip',kid:'1',k:key,t:alice});
 await p.goto('http://localhost:8124/?'+q+'#'+f);
 await p.waitForFunction(()=>window.ready||window.error,null,{timeout:45000});
 out.addressBarFragment=await p.evaluate(()=>location.hash);out.sessionHistoryLength=await p.evaluate(()=>history.length);
 await p.goto('http://localhost:8124/control.html?after=1');await p.waitForTimeout(3000);
}finally{await ctx.close()}
const db=which==='chromium'?path.join(profile,'Default','History'):path.join(profile,'places.sqlite');
out.store=path.basename(db);out.storeExists=fs.existsSync(db);
if(out.storeExists){
 const copy=db+'.copy';fs.copyFileSync(db,copy);for(const s of ['-wal','-journal'])if(fs.existsSync(db+s))fs.copyFileSync(db+s,copy+s);
 const sql=which==='chromium'?'select url from urls':'select url from moz_places';
 const urls=execFileSync('sqlite3',[copy,sql],{encoding:'utf8'}).split('\n').filter(Boolean);
 out.urlsRecorded=urls.length;
 out.controlFragmentInStore=urls.some(u=>u.includes('#control-fragment-kept'));
 out.joinUrlWithoutFragmentInStore=urls.some(u=>u.startsWith('http://localhost:8124/?role=pub')&&!u.includes('#'));
 out.joinUrlWithFragmentInStore=urls.some(u=>u.startsWith('http://localhost:8124/?role=pub')&&u.includes('#'));
 out.contentKeyInStore=urls.some(u=>u.includes(key));
 out.roomTokenInStore=urls.some(u=>u.includes(alice.slice(0,40)));
}
// Every file in the profile, uncompressed bytes only (Firefox's sessionstore .jsonlz4 is compressed; listed separately).
const hits=[],compressed=[];const walk=d=>{for(const n of fs.readdirSync(d)){const fp=path.join(d,n);const st=fs.lstatSync(fp);if(st.isDirectory())walk(fp);else if(st.isFile()&&st.size<64e6){if(/lz4$/.test(n))compressed.push(path.relative(profile,fp));if(fs.readFileSync(fp).includes(Buffer.from(key)))hits.push(path.relative(profile,fp))}}};
walk(profile);out.profileFilesHoldingContentKey=hits;out.compressedFilesNotScanned=compressed;
fs.rmSync(profile,{recursive:true,force:true});
console.log(JSON.stringify(out));

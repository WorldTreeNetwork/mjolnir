import { Credential, Epoch } from '@moq/e2ee';
import { keyBytes, trackKey } from '../src/key.ts';
import { nonce } from '../src/derive.ts';
const enc=new TextEncoder();
const assert=(b:unknown,m:string)=>{if(!b)throw Error(m)};
export async function runCrypto(){
 const raw=new Uint8Array(32).fill(17), context=enc.encode('mjolnir-call/v1/test/r1');
 const key=await crypto.subtle.importKey('raw',raw,'HKDF',false,['deriveBits']);
 const a=new Credential({context,kid:1,secret:key});
 const b=new Credential({context,kid:1,secret:raw});raw.fill(0);
 let rejected=false;try{await crypto.subtle.exportKey('raw',key)}catch(e){rejected=true}
 assert(rejected,'root export must reject');
 assert(await a.path('alice')===await b.path('alice'),'byte / CryptoKey paths');
 const g=a.produce(), e=g.epoch;
 assert(await g.name('video')===await b.consume(e).name('video'),'byte / CryptoKey names');
 const k=trackKey(a,e,'video',0), r=trackKey(b,e,'video',0);
 const plain=enc.encode('actual nonextractable HKDF profile test');
 const ciphertext=await k.encrypt(nonce(123n,0),plain);
 assert(new TextDecoder().decode(await r.decrypt(nonce(123n,0),ciphertext))===new TextDecoder().decode(plain),'roundtrip');
 let failures=0;
 for(const [group,index,payload] of [[124n,0,ciphertext],[123n,1,ciphertext],[123n,0,Uint8Array.from(ciphertext,(v,i)=>i===0?v^1:v)]] as const){
  try{await r.decrypt(nonce(group,index),payload);throw Error('accepted tamper')}catch(e){assert((e as any).code==='authentication','tamper must authenticate');failures++}
 }
 // A malicious same-origin caller holding the HKDF handle can derive usable bytes,
 // even though exportKey(root) is forbidden. This is the same profile derivation.
 const derived=await keyBytes(a,e,'video',0);
 const aes=await crypto.subtle.importKey('raw',derived,'AES-GCM',false,['encrypt','decrypt']);
 rejected=false;try{await crypto.subtle.exportKey('raw',aes)}catch{rejected=true}assert(rejected,'AES export rejected');
 const recovered=await crypto.subtle.decrypt({name:'AES-GCM',iv:nonce(123n,0)},aes,ciphertext);
 assert(new TextDecoder().decode(recovered)===new TextDecoder().decode(plain),'same-origin use');
 const results={profile:'moq-e2ee-01-wip',cipher:'AES-128-GCM',root:'HKDF-SHA-256 nonextractable',rootExportRejected:true,aesExportRejected:true,byteKeyInterop:true,tamperRejections:failures,derivedKeyBytes:derived.length,sameOriginDecrypt:true};
 console.log(JSON.stringify(results));return results;
}
if(typeof window==='undefined')await runCrypto();else (window as any).runCrypto=runCrypto;

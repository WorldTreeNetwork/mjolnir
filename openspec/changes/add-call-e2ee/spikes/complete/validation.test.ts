import {test,expect} from 'bun:test';import {Credential} from '@moq/e2ee';import{inviteFields,announcedPath,contextFor,semanticFor,type Variant}from './validation.ts';
const valid=()=>new URLSearchParams({v:'1',p:'moq-e2ee-01-wip',kid:'1',k:Buffer.alloc(32,17).toString('base64url'),t:'test-fixture-token'});
test('missing/wrong profile/kid/key fail closed',()=>{for(const [field,value]of[['p','other'],['kid',''],['kid','1.5'],['kid','9007199254740992'],['k',''],['k','00'],['t',''],['v','2']]){const p=valid();p.set(field,value);expect(()=>inviteFields(p)).toThrow()}expect(inviteFields(valid()).raw.length).toBe(32)});
const root='t/OWNER/r1';
const credFor=(variant:Variant,fill=17)=>(label:string)=>new Credential({context:new TextEncoder().encode(contextFor(variant,root,label)),kid:1,secret:new Uint8Array(32).fill(fill)});
for(const variant of ['label','room'] as Variant[])test(`${variant}: label binding, canonical epoch, wrong key`,async()=>{
 const c=credFor(variant)('alice');const e=c.produce().epoch;const opaque=await c.path(semanticFor(variant,'alice'));const path=`alice/${opaque}/${e}`;
 expect((await announcedPath(path,credFor(variant),variant)).epoch).toBe(e);
 for(const p of [`bob/${opaque}/${e}`,`alice/${opaque}/bad`,`alice/${opaque}/${e.toUpperCase()}`,`alice/${opaque}/${e}/extra`,`../${opaque}/${e}`])await expect(announcedPath(p,credFor(variant),variant)).rejects.toThrow();
 await expect(announcedPath(path,credFor(variant,18),variant)).rejects.toThrow();
});
test('label variant: contexts differ per label, so names differ per label for the same epoch',async()=>{
 const a=credFor('label')('alice'),b=credFor('label')('bob');const e=a.produce().epoch;
 expect(await a.consume(e).name('video')).not.toBe(await b.consume(e).name('video'));
 const ra=credFor('room')('alice'),rb=credFor('room')('bob');
 expect(await ra.consume(e).name('video')).toBe(await rb.consume(e).name('video'));
});

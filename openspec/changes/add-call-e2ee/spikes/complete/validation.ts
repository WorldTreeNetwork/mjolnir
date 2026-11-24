import {Credential,Epoch} from '@moq/e2ee';
// Two layouts are kept so the finding can say which one each run used.
//  label (default, review B1 fix): context mjolnir-call/v1/<owner>/<room>/<label>, opaque = path("call")
//  room  (contract D2 as written): context mjolnir-call/v1/<owner>/<room>,         opaque = path(<label>)
export type Variant='label'|'room';
export function variantOf(q:URLSearchParams):Variant{const v=q.get('ctx')??'label';if(v!=='label'&&v!=='room')throw Error('unknown ctx');return v}
export function roomContext(root:string){const p=root.split('/');if(p.length!==3||p[0]!=='t')throw Error('token root');return 'mjolnir-call/v1/'+p[1]+'/'+p[2]}
export function contextFor(variant:Variant,root:string,label:string){if(!/^[-_A-Za-z0-9]+$/.test(label))throw Error('label');return variant==='label'?roomContext(root)+'/'+label:roomContext(root)}
export function semanticFor(variant:Variant,label:string){return variant==='label'?'call':label}
export function inviteFields(invite:URLSearchParams){
 if(invite.get('v')!=='1'||invite.get('p')!=='moq-e2ee-01-wip')throw Error('unsupported profile');
 const encoded=invite.get('k'),token=invite.get('t'),kidText=invite.get('kid');
 if(!encoded||!token||!kidText||!/^\d+$/.test(kidText)||!/^[-_A-Za-z0-9]{43}$/.test(encoded))throw Error('missing/invalid credential');
 const raw=Uint8Array.from(atob(encoded.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
 const canonical=btoa(String.fromCharCode(...raw)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
 const kid=Number(kidText);if(!Number.isSafeInteger(kid)||raw.length!==32||canonical!==encoded)throw Error('invalid credential');
 return {raw,token,kid};
}
/** Subscriber rule: label from the first segment, the credential for that label, opaque must match, canonical epoch. */
export async function announcedPath(path:string,credentialFor:(label:string)=>Credential,variant:Variant){
 const parts=path.split('/');if(parts.length!==3||!/^[-_A-Za-z0-9]+$/.test(parts[0]))throw Error('invalid label/path');
 const credential=credentialFor(parts[0]);
 if(parts[1]!==await credential.path(semanticFor(variant,parts[0])))throw Error('label or credential mismatch');
 return {label:parts[0],epoch:Epoch.parse(parts[2]),credential};
}

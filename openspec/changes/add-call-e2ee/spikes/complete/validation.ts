import {Credential,Epoch} from '@moq/e2ee';
export function inviteFields(invite:URLSearchParams){
 if(invite.get('v')!=='1'||invite.get('p')!=='moq-e2ee-01-wip')throw Error('unsupported profile');
 const encoded=invite.get('k'),token=invite.get('t'),kidText=invite.get('kid');
 if(!encoded||!token||!kidText||!/^\d+$/.test(kidText)||!/^[-_A-Za-z0-9]{43}$/.test(encoded))throw Error('missing/invalid credential');
 const raw=Uint8Array.from(atob(encoded.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
 const canonical=btoa(String.fromCharCode(...raw)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
 const kid=Number(kidText);if(!Number.isSafeInteger(kid)||raw.length!==32||canonical!==encoded)throw Error('invalid credential');
 return {raw,token,kid};
}
export async function announcedPath(path:string,credential:Credential){
 const parts=path.split('/');if(parts.length!==3||!/^[-_A-Za-z0-9]+$/.test(parts[0]))throw Error('invalid label/path');
 if(parts[1]!==await credential.path(parts[0]))throw Error('label or credential mismatch');
 return {label:parts[0],epoch:Epoch.parse(parts[2])};
}

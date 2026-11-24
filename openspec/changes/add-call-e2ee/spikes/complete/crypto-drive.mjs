import {chromium,firefox} from 'playwright';
for(const [name,type] of Object.entries({chromium,firefox})){
 const browser=await type.launch();
 try{const p=await browser.newPage();await p.goto('http://localhost:8123/crypto.html');const result=await p.evaluate(()=>window.runCrypto());console.log(JSON.stringify({browser:name,version:browser.version(),...result}));}finally{await browser.close()}
}

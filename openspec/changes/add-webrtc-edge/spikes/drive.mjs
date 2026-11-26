// Playwright driver for the webrtc-edge spike. Copy into a dir with playwright 1.65.1 and run there.
//   node drive.mjs pub   <who> <broadcast> <vcodec|-> <holdSec> [tokenName]
//   node drive.mjs play  <chromium|firefox|webkit> <broadcast> <vcodec|-> <holdSec> <left> <right> <hz> [tokenName]
//   node drive.mjs room
//   node drive.mjs auth
//   node drive.mjs expiry <ttlTokenName>
// Env: P (private dir with fixtures and *.tok), EDGE, PAGES.
import { chromium, firefox, webkit } from 'playwright';
import fs from 'node:fs';
const P = process.env.P, EDGE = process.env.EDGE || 'http://127.0.0.1:8088', PAGES = process.env.PAGES || 'http://127.0.0.1:18124';
const tok = n => fs.readFileSync(`${P}/${n}.tok`, 'utf8').trim();
const out = o => console.log(JSON.stringify(o));
const sleep = ms => new Promise(r => setTimeout(r, ms));
const rgb = h => [1, 3, 5].map(i => parseInt(h.replace('0x', '#').slice(i, i + 2), 16));
const near = (a, b, t = 45) => a.every((x, i) => Math.abs(x - b[i]) <= t);

async function launch(kind, who) {
  if (kind === 'chromium') {
    const args = ['--autoplay-policy=no-user-gesture-required', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'];
    if (who) args.push(`--use-file-for-fake-video-capture=${P}/${who}.y4m`, `--use-file-for-fake-audio-capture=${P}/${who}.wav`);
    return chromium.launch({ args, channel: process.env.CHROME_CHANNEL || undefined });
  }
  if (kind === 'firefox') return firefox.launch({ firefoxUserPrefs: { 'media.navigator.streams.fake': true, 'media.navigator.permission.disabled': true, 'media.autoplay.default': 0, 'media.autoplay.blocking_policy': 0 } });
  return webkit.launch();
}

async function open(browser, room, token, label) {
  const ctx = await browser.newContext({ permissions: browser.browserType().name() === 'chromium' ? ['camera', 'microphone'] : [] });
  const page = await ctx.newPage();
  page.on('console', m => { if (process.env.VERBOSE) console.error(label + ': ' + m.text()); });
  page.on('pageerror', e => console.error(label + ' pageerror: ' + e));
  await page.goto(`${PAGES}/rtc.html?edge=${encodeURIComponent(EDGE)}&room=${room}#t=${token}`);
  await page.waitForFunction(() => window.ready);
  // Loss runs: withhold host candidates so the edge learns only the lossy proxy's address.
  if (process.env.STRIP) await page.evaluate(() => { window.stripCandidates = true; });
  return page;
}
const call = (page, fn, ...a) => page.evaluate(([fn, a]) => window[fn](...a).catch(e => ({ error: String(e.message || e), status: e.status })), [fn, a]);

async function contentCheck(page, name, left, right, hz) {
  const c = await page.evaluate(n => window.content(n), name);
  c.videoMatch = near(c.left, rgb(left)) && near(c.right, rgb(right));
  c.audioMatch = c.audioPeakHz !== undefined && Math.abs(c.audioPeakHz - hz) <= Math.max(15, 0.03 * hz) && c.audioRms > 0.005;
  return c;
}

const [mode, ...a] = process.argv.slice(2);
let browsers = [];
try {
  if (mode === 'pub') {
    const [who, b, vc, hold, tn] = a; const br = await launch('chromium', who); browsers.push(br);
    const page = await open(br, 'r1', tok(tn || who), who);
    const r = await call(page, 'publish', b, vc === '-' ? null : vc);
    out({ step: 'publish', who, broadcast: b, vcodec: vc, browser: 'chromium ' + br.version(), ...r });
    if (r.error) process.exit(2);
    for (let t = 0; t < +hold; t += 3) { await sleep(3000); out({ step: 'stats', t: t + 3, ...(await page.evaluate(() => window.stats(Object.keys(window.pcs)[0]))) }); }
  } else if (mode === 'simulcast') {
    const [who, b, hold] = a; const br = await launch('chromium', who); browsers.push(br);
    const page = await open(br, 'r1', tok(who), who);
    const r = await call(page, 'publishSimulcast', b);
    out({ step: 'publish-simulcast', who, broadcast: b, ...r });
    if (r.error) process.exit(2);
    await sleep(+hold * 1000);
    out({ step: 'stats', ...(await page.evaluate(n => window.stats(n), 'pub:' + b)) });
  } else if (mode === 'play') {
    const [kind, b, vc, hold, l, r_, hz, tn] = a; const br = await launch(kind); browsers.push(br);
    const page = await open(br, 'r1', tok(tn || 'erin'), kind);
    const r = await call(page, 'play', b, vc === '-' ? null : vc);
    out({ step: 'play', broadcast: b, vcodec: vc, browser: kind + ' ' + br.version(), ...r });
    if (r.error) process.exit(2);
    await sleep(2500); const first = await page.evaluate(n => window.stats(n), 'play:' + b);
    await sleep(Math.max(0, +hold * 1000 - 2500)); const last = await page.evaluate(n => window.stats(n), 'play:' + b);
    const c = await contentCheck(page, 'play:' + b, l, r_, +hz);
    out({ step: 'result', broadcast: b, vcodec: vc, first, last, content: c });
    process.exit(c.videoMatch && c.audioMatch && last.videoIn?.framesDecoded > 0 ? 0 : 1);
  } else if (mode === 'room') {
    // Two WebRTC participants (alice, bob) and one MoQ participant (carol, native) in room r1.
    const fx = { alice: ['0xC83278', '0x1EA0A0', 1000], bob: ['0xE68C14', '0x283CC8', 600], carol: ['0x28B43C', '0x7828AA', 440] };
    const pages = {};
    for (const who of ['alice', 'bob']) {
      const br = await launch('chromium', who); browsers.push(br); pages[who] = await open(br, 'r1', tok(who), who);
      out({ step: 'publish', who, ...(await call(pages[who], 'publish', who + '/cam', process.env.VCODEC || null)) });
    }
    const results = {};
    for (const who of ['alice', 'bob']) {
      const roster = await pages[who].evaluate(() => window.roster());
      out({ step: 'roster', who, ...roster });
      for (const other of roster.broadcasts.filter(x => !x.startsWith(who + '/'))) {
        out({ step: 'play', who, other, ...(await call(pages[who], 'play', other, null)) });
      }
    }
    await sleep(5000);
    for (const who of ['alice', 'bob']) for (const other of Object.keys(fx).filter(x => x !== who)) {
      const name = 'play:' + other + '/cam';
      const has = await pages[who].evaluate(n => !!window.pcs[n], name);
      if (!has) { results[`${who}<-${other}`] = { missing: true }; continue; }
      const st = await pages[who].evaluate(n => window.stats(n), name);
      const c = await contentCheck(pages[who], name, ...fx[other]);
      results[`${who}<-${other}`] = { framesDecoded: st.videoIn?.framesDecoded, codec: st.videoIn?.codec, audioEnergy: st.audioIn?.totalAudioEnergy, videoMatch: c.videoMatch, audioMatch: c.audioMatch, left: c.left, right: c.right, peakHz: c.audioPeakHz };
    }
    const pcCount = await Promise.all(['alice', 'bob'].map(w => pages[w].evaluate(() => Object.keys(window.pcs).length)));
    out({ step: 'room-result', results, peerConnectionsPerBrowser: pcCount });
    if (process.env.HOLD) await sleep(+process.env.HOLD * 1000);
    process.exit(Object.values(results).every(r => r.videoMatch && r.audioMatch) ? 0 : 1);
  } else if (mode === 'auth') {
    const br = await launch('chromium', 'alice'); browsers.push(br);
    const page = await open(br, 'r1', tok('alice'), 'alice');
    const cases = [
      ['publish as another label (alice token, bob/cam)', 'publish', 'bob/cam', tok('alice')],
      ['token for another room (r2 token on /r1/)', 'publish', 'alice/cam', tok('alice-r2')],
      ['no token', 'publish', 'alice/cam', ''],
      ['token signed by another key', 'publish', 'alice/cam', tok('forged')],
      ['expired token', 'publish', 'alice/cam', tok('expired')],
      ['WHEP outside the room (r2 token playing r1 broadcast)', 'play', 'carol/cam', tok('alice-r2')],
      ['control: alice publishes alice/cam', 'publish', 'alice/cam', tok('alice')],
    ];
    let ok = true;
    for (const [what, fn, b, t] of cases) {
      const r = await call(page, fn, b, null, t);
      const refused = !!r.error;
      const expect = !what.startsWith('control');
      if (refused !== expect) ok = false;
      out({ step: 'auth', case: what, refused, status: r.status, error: r.error?.slice(0, 160), connectMs: r.connectMs });
    }
    process.exit(ok ? 0 : 1);
  } else if (mode === 'expiry') {
    const [tn, other] = a; const br = await launch('chromium', 'alice'); browsers.push(br);
    const page = await open(br, 'r1', tok(tn), 'alice');
    const p = await call(page, 'publish', 'alice/cam', null); out({ step: 'publish', ...p });
    const w = await call(page, 'play', other || 'carol/cam', null); out({ step: 'play', ...w });
    const t0 = Date.now();
    for (let i = 0; i < 60; i++) {
      await sleep(1000);
      const e = await page.evaluate(() => window.ended);
      if (Object.keys(e).length >= 2) break;
    }
    const e = await page.evaluate(() => window.ended);
    const exp = JSON.parse(Buffer.from(tok(tn).split('.')[1], 'base64url').toString()).exp * 1000;
    const after = Object.fromEntries(Object.entries(e).map(([k, v]) => [k, { state: v.state, endedMsAfterExp: v.at - exp }]));
    out({ step: 'expiry', exp: new Date(exp).toISOString(), ended: after, waitedMs: Date.now() - t0 });
  }
} finally { for (const b of browsers) await b.close().catch(() => {}); }
process.exit(0);

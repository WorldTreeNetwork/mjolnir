import { chromium } from "playwright";
import fs from "node:fs";

const P = process.env.P;
const root = fs.readFileSync(`${P}/alice.meta`, "utf8").trim().split("\n")[0];
const alice = fs.readFileSync(`${P}/alice.tok`, "utf8").trim();
const alice2 = fs.readFileSync(`${P}/alice2.tok`, "utf8").trim();
const bob = fs.readFileSync(`${P}/bob.tok`, "utf8").trim();
const expired = fs.readFileSync(`${P}/expired.tok`, "utf8").trim();
const origin = process.env.ORIGIN;
const pageOrigin = process.env.PAGE_ORIGIN;

const args = [
  "--autoplay-policy=no-user-gesture-required",
  "--use-fake-ui-for-media-stream",
  "--use-fake-device-for-media-stream",
  `--use-file-for-fake-video-capture=${process.env.Y4M}`,
  `--use-file-for-fake-audio-capture=${process.env.WAV}`,
];

function url(token, self, peer) {
  const q = new URLSearchParams();
  if (token) q.set("t", token);
  q.set("root", root);
  q.set("kind", "open");
  q.set("self", self);
  q.set("retry", "1000");
  q.set("mintRoot", root);
  if (peer) q.append("peer", peer);
  return `${pageOrigin}/page/room.html#${q}`;
}

function arm(context) {
  return context.addInitScript(() => {
    window.__http = [];
    window.__gum = 0;
    window.__pcs = 0;
    const origFetch = window.fetch.bind(window);
    window.fetch = async (input, init) => {
      const res = await origFetch(input, init);
      const raw = typeof input === "string" ? input : input.url;
      let path = raw;
      try { path = new URL(raw, location.href).pathname; } catch { /* keep */ }
      window.__http.push({ method: (init && init.method) || "GET", path, status: res.status });
      return res;
    };
    const Orig = window.RTCPeerConnection;
    window.RTCPeerConnection = new Proxy(Orig, {
      construct(target, ctorArgs) {
        window.__pcs += 1;
        return new target(...ctorArgs);
      },
    });
    const origGum = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    navigator.mediaDevices.getUserMedia = async (constraints) => {
      window.__gum += 1;
      window.__gumNotice = document.querySelector("#notice")?.textContent || "";
      return origGum(constraints);
    };
  });
}

async function snap(page) {
  return page.evaluate(() => ({
    status: document.querySelector("#status")?.textContent || "",
    hash: location.hash,
    notice: document.querySelector("#notice")?.textContent || "",
    gum: window.__gum || 0,
    gumNotice: window.__gumNotice || "",
    pcs: window.__pcs || 0,
    http: window.__http || [],
    room: window.roomClient ? window.roomClient.status() : null,
    tiles: [...document.querySelectorAll(".tile")].map((node) => ({
      path: node.dataset.path,
      caption: node.querySelector("p")?.textContent || "",
      width: node.querySelector("video")?.videoWidth || 0,
      height: node.querySelector("video")?.videoHeight || 0,
    })),
  }));
}

async function until(page, pred, ms) {
  const start = Date.now();
  let last = null;
  while (Date.now() - start < ms) {
    last = await snap(page);
    if (pred(last)) return last;
    await page.waitForTimeout(250);
  }
  return last;
}

async function sample(page, path) {
  return page.evaluate(async (path) => {
    const video = document.querySelector(`[data-path="${CSS.escape(path)}"] video`);
    if (!video || !video.videoWidth) return { error: "no-remote-video", width: video ? video.videoWidth : 0 };
    const canvas = document.createElement("canvas");
    canvas.width = 64;
    canvas.height = 36;
    const g = canvas.getContext("2d", { willReadFrequently: true });
    g.drawImage(video, 0, 0, 64, 36);
    const d = g.getImageData(0, 0, 64, 36).data;
    const avg = (x0, x1) => {
      let r = 0, gg = 0, b = 0, n = 0;
      for (let y = 4; y < 32; y++) {
        for (let x = x0; x < x1; x++) {
          const i = (y * 64 + x) * 4;
          r += d[i]; gg += d[i + 1]; b += d[i + 2]; n++;
        }
      }
      return [r / n, gg / n, b / n].map(Math.round);
    };
    const tracks = video.srcObject ? video.srcObject.getTracks().map((t) => t.kind) : [];
    const audio = video.srcObject && video.srcObject.getAudioTracks()[0];
    let audioPeakHz = null, audioRms = null;
    if (audio) {
      const ctx = new AudioContext();
      await ctx.resume();
      const src = ctx.createMediaStreamSource(new MediaStream([audio]));
      const an = ctx.createAnalyser();
      an.fftSize = 8192;
      src.connect(an);
      await new Promise((r) => setTimeout(r, 400));
      const fr = new Float32Array(an.frequencyBinCount);
      an.getFloatFrequencyData(fr);
      let best = 0;
      for (let i = 1; i < fr.length; i++) if (fr[i] > fr[best]) best = i;
      const td = new Float32Array(an.fftSize);
      an.getFloatTimeDomainData(td);
      audioPeakHz = Math.round(best * ctx.sampleRate / an.fftSize);
      audioRms = Math.sqrt(td.reduce((s, x) => s + x * x, 0) / td.length);
      await ctx.close();
    }
    return { left: avg(4, 28), right: avg(36, 60), width: video.videoWidth, height: video.videoHeight, tracks, audioPeakHz, audioRms: audioRms && Number(audioRms.toFixed(4)) };
  }, path);
}

const browser = await chromium.launch({ executablePath: "/usr/bin/chromium", headless: true, args });
const context = await browser.newContext();
await arm(context);
const errors = [];
const alicePage = await context.newPage();
const bobPage = await context.newPage();
for (const [name, page] of [["alice", alicePage], ["bob", bobPage]]) {
  page.on("pageerror", (e) => errors.push(`${name} ${e.message}`));
}

await alicePage.goto(url(alice, "alice/cam", "bob/cam"));
const beforeJoin = await snap(alicePage);
await alicePage.click("#join");
const aliceWaiting = await until(alicePage, (s) => s.status === "in the room" && s.tiles.some((t) => t.path === "bob/cam"), 20000);

await bobPage.goto(url(bob, "bob/cam", "alice/cam"));
await bobPage.click("#join");
const bobIn = await until(bobPage, (s) => s.status === "in the room" && s.tiles.some((t) => t.caption === "playing" && t.width > 0), 20000);
const decoded = await sample(bobPage, "alice/cam");

const beforeReplace = await snap(alicePage);
await alicePage.click("#replace");
const afterReplace = await until(alicePage, (s) => {
  const sessions = (s.room && s.room.sessions) || [];
  const prev = (beforeReplace.room && beforeReplace.room.sessions) || [];
  return s.status === "in the room" && sessions.length > 0 && sessions.join() !== prev.join();
}, 20000);
const bobAfterReplace = await until(bobPage, (s) => s.tiles.some((t) => t.path === "alice/cam"), 5000);

const sessionsBeforeBadRenew = ((afterReplace.room && afterReplace.room.sessions) || []).slice();
const gumBeforeBad = afterReplace.gum;
const pcsBeforeBad = afterReplace.pcs;
await alicePage.fill("#renew-token", bob);
await alicePage.click("#renew");
const afterBadRenew = await until(alicePage, (s) => s.status === "forbidden" || (s.http.length > afterReplace.http.length && s.status !== "in the room"), 15000);

await alicePage.fill("#renew-token", alice2);
await alicePage.click("#renew");
const afterGoodRenew = await until(alicePage, (s) => {
  const sessions = (s.room && s.room.sessions) || [];
  return s.status === "in the room" && sessions.length > 0 && sessions.join() !== sessionsBeforeBadRenew.join();
}, 20000);

await alicePage.click("#leave");
const afterLeave = await until(alicePage, (s) => s.status === "left" && s.room && s.room.sessions.length === 0 && s.room.tracks === 0, 10000);

const refusal = await browser.newContext();
await arm(refusal);
async function refusalCase(name, token) {
  const page = await refusal.newPage();
  page.on("pageerror", (e) => errors.push(`${name} ${e.message}`));
  const target = token === null ? `${pageOrigin}/page/room.html` : url(token, "alice/cam", "bob/cam");
  await page.goto(target);
  if (name === "expired") await page.waitForTimeout(3500);
  await page.click("#join");
  const settled = await until(page, (s) => s.status && s.status !== "", 10000);
  await page.close();
  return { name, status: settled.status, gum: settled.gum, pcs: settled.pcs, http: settled.http, hash: settled.hash };
}
const empty = await refusalCase("empty", null);
const bad = await refusalCase("bad", "not-a-jwt");
const expiredCase = await refusalCase("expired", expired);

const out = {
  origin,
  pageOrigin,
  rootLength: root.length,
  beforeJoin: { hash: beforeJoin.hash, notice: beforeJoin.notice, gum: beforeJoin.gum, pcs: beforeJoin.pcs },
  aliceWaiting: { status: aliceWaiting.status, tiles: aliceWaiting.tiles, gum: aliceWaiting.gum, pcs: aliceWaiting.pcs, sessions: aliceWaiting.room && aliceWaiting.room.sessions, http: aliceWaiting.http },
  bobIn: { status: bobIn.status, tiles: bobIn.tiles, gum: bobIn.gum, pcs: bobIn.pcs, sessions: bobIn.room && bobIn.room.sessions, http: bobIn.http },
  decoded,
  replace: {
    beforeSessions: beforeReplace.room && beforeReplace.room.sessions,
    afterSessions: afterReplace.room && afterReplace.room.sessions,
    status: afterReplace.status,
    gum: afterReplace.gum,
    pcs: afterReplace.pcs,
    deletes: afterReplace.room && afterReplace.room.deletes,
    incumbent: afterReplace.room && afterReplace.room.incumbent,
    http: afterReplace.http,
  },
  bobAfterReplace: { status: bobAfterReplace.status, tiles: bobAfterReplace.tiles },
  badRenew: {
    status: afterBadRenew.status,
    sessions: afterBadRenew.room && afterBadRenew.room.sessions,
    sessionsUnchanged: JSON.stringify(afterBadRenew.room && afterBadRenew.room.sessions) === JSON.stringify(sessionsBeforeBadRenew),
    gum: afterBadRenew.gum,
    gumUnchanged: afterBadRenew.gum === gumBeforeBad,
    pcs: afterBadRenew.pcs,
    pcsUnchanged: afterBadRenew.pcs === pcsBeforeBad,
    http: afterBadRenew.http,
    incumbent: afterBadRenew.room && afterBadRenew.room.incumbent,
  },
  goodRenew: {
    status: afterGoodRenew.status,
    sessions: afterGoodRenew.room && afterGoodRenew.room.sessions,
    gum: afterGoodRenew.gum,
    pcs: afterGoodRenew.pcs,
    deletes: afterGoodRenew.room && afterGoodRenew.room.deletes,
    incumbent: afterGoodRenew.room && afterGoodRenew.room.incumbent,
    http: afterGoodRenew.http,
  },
  leave: {
    status: afterLeave.status,
    tracks: afterLeave.room && afterLeave.room.tracks,
    sessions: afterLeave.room && afterLeave.room.sessions,
    pcs: afterLeave.room && afterLeave.room.pcs,
    deletes: afterLeave.room && afterLeave.room.deletes,
    http: afterLeave.http,
  },
  refusals: [empty, bad, expiredCase],
  pageErrors: errors,
};
fs.writeFileSync(`${P}/evidence/summary.json`, JSON.stringify(out, null, 2));
console.log("MJ15_LIFE_OK");
await browser.close();

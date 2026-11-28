import { chromium } from "playwright";
import fs from "node:fs";

const P = process.env.P;
const root = fs.readFileSync(`${P}/alice.meta`, "utf8").trim().split("\n")[0];
const alice = fs.readFileSync(`${P}/alice.tok`, "utf8").trim();
const alice2 = fs.readFileSync(`${P}/alice2.tok`, "utf8").trim();
const bob = fs.readFileSync(`${P}/bob.tok`, "utf8").trim();
const pageOrigin = process.env.PAGE_ORIGIN;
const SOURCE = "0df60bee32e02b8908e2438259ed8e3d10b38adc";
const args = [
  "--autoplay-policy=no-user-gesture-required",
  "--use-fake-ui-for-media-stream",
  "--use-fake-device-for-media-stream",
  `--use-file-for-fake-video-capture=${process.env.Y4M}`,
  `--use-file-for-fake-audio-capture=${process.env.WAV}`,
];

function url(token, self, peer) {
  const q = new URLSearchParams();
  q.set("t", token);
  q.set("root", root);
  q.set("kind", "open");
  q.set("self", self);
  q.set("retry", "1000");
  q.set("mintRoot", root);
  if (peer) q.append("peer", peer);
  return `${pageOrigin}/page/room.html#${q}`;
}

function toneOk(tone) {
  return !!(tone && tone.rms > 0.001 && tone.peakHz >= 420 && tone.peakHz <= 460);
}

function audioBytes(inbound) {
  const rows = (inbound || []).filter((row) => row.kind === "audio");
  if (!rows.length) return null;
  return Math.max(...rows.map((row) => row.bytesReceived || 0));
}

const browser = await chromium.launch({ executablePath: "/usr/bin/chromium", headless: true, args });
const context = await browser.newContext();
await context.addInitScript(() => {
  window.__hook = "measurement-only: record peer connections, do not change play or media";
  window.__pcs = [];
  const Orig = window.RTCPeerConnection;
  window.RTCPeerConnection = new Proxy(Orig, {
    construct(target, ctorArgs) {
      const pc = new target(...ctorArgs);
      window.__pcs.push(pc);
      return pc;
    },
  });
});

async function collect(page, label) {
  return page.evaluate(async (label) => {
    const tile = document.querySelector('[data-path="alice/cam"]');
    const video = tile ? tile.querySelector("video") : null;
    const stream = video && video.srcObject;
    const tracks = stream ? stream.getTracks().map((track) => ({
      id: track.id, kind: track.kind, readyState: track.readyState, muted: track.muted, enabled: track.enabled,
    })) : [];
    const audio = stream && stream.getAudioTracks().find((track) => track.readyState === "live");
    const inbound = [];
    const outbound = [];
    for (const pc of window.__pcs || []) {
      let report;
      try { report = await pc.getStats(); } catch { continue; }
      for (const row of report.values()) {
        if (row.type === "inbound-rtp" && (row.kind === "audio" || row.kind === "video")) {
          inbound.push({
            kind: row.kind, bytesReceived: row.bytesReceived, packetsReceived: row.packetsReceived,
            packetsLost: row.packetsLost, audioLevel: row.audioLevel,
            totalSamplesReceived: row.totalSamplesReceived, framesDecoded: row.framesDecoded,
            frameWidth: row.frameWidth, frameHeight: row.frameHeight,
          });
        }
        if (row.type === "outbound-rtp" && (row.kind === "audio" || row.kind === "video")) {
          outbound.push({
            kind: row.kind, bytesSent: row.bytesSent, packetsSent: row.packetsSent, audioLevel: row.audioLevel,
          });
        }
      }
    }
    let pixels = null;
    if (video && video.videoWidth > 0) {
      const canvas = document.createElement("canvas");
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      const g = canvas.getContext("2d", { willReadFrequently: true });
      g.drawImage(video, 0, 0);
      const lx = Math.floor(canvas.width * 0.25);
      const rx = Math.floor(canvas.width * 0.75);
      const y = Math.floor(canvas.height * 0.5);
      const left = g.getImageData(lx, y, 1, 1).data;
      const right = g.getImageData(rx, y, 1, 1).data;
      pixels = {
        left: [left[0], left[1], left[2]],
        right: [right[0], right[1], right[2]],
        width: canvas.width,
        height: canvas.height,
      };
    }
    let tone = { attachedTo: null };
    if (audio) {
      const ctx = new AudioContext();
      await ctx.resume();
      const owned = new MediaStream([audio]);
      const src = ctx.createMediaStreamSource(owned);
      const an = ctx.createAnalyser();
      an.fftSize = 8192;
      src.connect(an);
      await new Promise((resolve) => setTimeout(resolve, 800));
      const fr = new Float32Array(an.frequencyBinCount);
      an.getFloatFrequencyData(fr);
      let best = 1;
      for (let i = 2; i < fr.length; i += 1) if (fr[i] > fr[best]) best = i;
      const td = new Float32Array(an.fftSize);
      an.getFloatTimeDomainData(td);
      const rms = Math.sqrt(td.reduce((sum, x) => sum + x * x, 0) / td.length);
      tone = {
        attachedTo: audio.id,
        contextState: ctx.state,
        sampleRate: ctx.sampleRate,
        peakHz: Math.round(best * ctx.sampleRate / an.fftSize),
        peakDb: Number(fr[best].toFixed(1)),
        rms: Number(rms.toFixed(4)),
      };
      await ctx.close();
    }
    return {
      label,
      hook: window.__hook,
      status: document.querySelector("#status")?.textContent || "",
      owner: tile ? tile.dataset.owner || "" : "",
      caption: tile ? (tile.querySelector("p")?.textContent || "") : "",
      srcObject: !!(video && video.srcObject),
      element: video ? {
        muted: video.muted, paused: video.paused, readyState: video.readyState,
        videoWidth: video.videoWidth, videoHeight: video.videoHeight,
      } : null,
      tracks, inbound, outbound, pixels, tone,
      room: window.roomClient ? window.roomClient.status() : null,
    };
  }, label);
}

async function until(page, pred, arg, ms) {
  const start = Date.now();
  let last = null;
  while (Date.now() - start < ms) {
    last = await page.evaluate(pred, arg);
    if (last) return last;
    await page.waitForTimeout(200);
  }
  return last;
}

function viewSnap(page) {
  return page.evaluate(() => {
    const tile = document.querySelector('[data-path="alice/cam"]');
    const video = tile && tile.querySelector("video");
    const audio = video && video.srcObject && video.srcObject.getAudioTracks()[0];
    return {
      t: Date.now(),
      status: document.querySelector("#status")?.textContent || "",
      tiles: document.querySelectorAll(".tile").length,
      owner: tile ? tile.dataset.owner || "" : "",
      caption: tile ? (tile.querySelector("p")?.textContent || "") : "",
      srcObject: !!(video && video.srcObject),
      audio: audio ? audio.id : "",
      width: video ? video.videoWidth : 0,
      local: !!document.querySelector("#local-video").srcObject,
    };
  });
}

const errors = [];
const alicePage = await context.newPage();
const bobPage = await context.newPage();
for (const [name, page] of [["alice", alicePage], ["bob", bobPage]]) {
  page.on("pageerror", (error) => errors.push(`${name} ${error.message}`));
}

await alicePage.goto(url(alice, "alice/cam", "bob/cam"));
await bobPage.goto(url(bob, "bob/cam", "alice/cam"));
await alicePage.click("#join");
await bobPage.click("#join");
const joined = await until(bobPage, () => {
  const video = document.querySelector('[data-path="alice/cam"] video');
  return !!(video && video.videoWidth > 0);
}, null, 30000);

const samples = [];
async function take(name) {
  const bobSample = await collect(bobPage, name);
  const later = await collect(bobPage, `${name}-sustained`);
  samples.push({ name, bob: bobSample, sustained: later });
}
await take("join");
const joinOwner = samples[0].bob.owner;
const joinAudio = (samples[0].bob.tracks.find((track) => track.kind === "audio") || {}).id;

const gap = [];
await alicePage.click("#replace");
const gapStart = Date.now();
let replaced = null;
while (Date.now() - gapStart < 25000) {
  const snap = await viewSnap(bobPage);
  snap.ms = Date.now() - gapStart;
  if (gap.length === 0 || JSON.stringify({ ...gap.at(-1), t: 0, ms: 0 }) !== JSON.stringify({ ...snap, t: 0, ms: 0 })) {
    gap.push(snap);
  }
  if (snap.width > 0 && snap.owner && snap.owner !== joinOwner && snap.audio && snap.audio !== joinAudio) {
    replaced = snap;
    break;
  }
  await bobPage.waitForTimeout(150);
}
await take("replace");

const replaceSessions = JSON.stringify(await alicePage.evaluate(() => window.roomClient.status().sessions));
const replaceAudio = (samples.at(-1).bob.tracks.find((track) => track.kind === "audio") || {}).id;
await alicePage.fill("#renew-token", alice2);
await alicePage.click("#renew");
const renewGap = [];
const renewStart = Date.now();
let renewed = null;
while (Date.now() - renewStart < 25000) {
  const snap = await viewSnap(bobPage);
  snap.ms = Date.now() - renewStart;
  const aliceStatus = await alicePage.evaluate(() => ({
    status: document.querySelector("#status")?.textContent || "",
    sessions: window.roomClient.status().sessions,
  }));
  snap.aliceStatus = aliceStatus.status;
  if (renewGap.length === 0 || renewGap.at(-1).owner !== snap.owner || renewGap.at(-1).audio !== snap.audio || renewGap.at(-1).caption !== snap.caption || renewGap.at(-1).aliceStatus !== snap.aliceStatus) {
    renewGap.push(snap);
  }
  if (aliceStatus.status === "In the room." && JSON.stringify(aliceStatus.sessions) !== replaceSessions
    && snap.audio && snap.audio !== replaceAudio && snap.width > 0) {
    renewed = snap;
    break;
  }
  await bobPage.waitForTimeout(150);
}
await take(renewed ? "renew" : "renew-no-new-track");

await alicePage.click("#leave");
const leaveSoon = await until(alicePage, () => {
  const tiles = document.querySelectorAll(".tile").length;
  const local = !!document.querySelector("#local-video").srcObject;
  const status = document.querySelector("#status")?.textContent || "";
  return tiles === 0 && !local && /Left|Leaving|cleanup/.test(status) ? { tiles, local, status } : null;
}, null, 8000);
await alicePage.waitForTimeout(600);
const leaveLater = await alicePage.evaluate(() => ({
  status: document.querySelector("#status")?.textContent || "",
  tiles: document.querySelectorAll(".tile").length,
  local: !!document.querySelector("#local-video").srcObject,
  captions: [...document.querySelectorAll(".tile p")].map((node) => node.textContent),
}));

await browser.close();

const browser2 = await chromium.launch({ executablePath: "/usr/bin/chromium", headless: true, args });
const context2 = await browser2.newContext();
await context2.addInitScript(() => {
  window.__hook = "measurement-only until the late-body hook is installed in the page";
  window.__pcs = [];
  const Orig = window.RTCPeerConnection;
  window.RTCPeerConnection = new Proxy(Orig, {
    construct(target, ctorArgs) {
      const pc = new target(...ctorArgs);
      window.__pcs.push(pc);
      return pc;
    },
  });
});
const aliceLate = await context2.newPage();
const bobLate = await context2.newPage();
for (const [name, page] of [["alice-late", aliceLate], ["bob-late", bobLate]]) {
  page.on("pageerror", (error) => errors.push(`${name} ${error.message}`));
}
await aliceLate.goto(url(alice, "alice/cam", "bob/cam"));
await bobLate.goto(url(bob, "bob/cam", "alice/cam"));
await aliceLate.evaluate(() => {
  window.__hook = "labeled: hold the next WHIP 201 body until __releaseBody; do not change play or media";
  const orig = window.fetch.bind(window);
  window.fetch = async (...fetchArgs) => {
    const res = await orig(...fetchArgs);
    const init = fetchArgs[1] || {};
    const method = String(init.method || "GET").toUpperCase();
    if (window.__holdNext && method === "POST" && res.status === 201) {
      window.__holdNext = false;
      window.__held = true;
      const text = await res.clone().text();
      const headers = new Headers(res.headers);
      const body = new ReadableStream({
        start(controller) {
          window.__releaseBody = () => {
            controller.enqueue(new TextEncoder().encode(text));
            controller.close();
            window.__released = true;
          };
        },
      });
      return new Response(body, { status: 201, statusText: res.statusText, headers });
    }
    return res;
  };
});
await aliceLate.click("#join");
await bobLate.click("#join");
await until(bobLate, () => {
  const video = document.querySelector('[data-path="alice/cam"] video');
  return !!(video && video.videoWidth > 0);
}, null, 30000);
const beforeHold = await viewSnap(bobLate);
await aliceLate.evaluate(() => { window.__holdNext = true; });
await aliceLate.click("#replace");
await aliceLate.waitForTimeout(1200);
const duringHold = await viewSnap(bobLate);
const aliceDuring = await aliceLate.evaluate(() => ({
  status: document.querySelector("#status")?.textContent || "",
  held: !!window.__held,
  hook: window.__hook,
  tiles: document.querySelectorAll(".tile").length,
  local: !!document.querySelector("#local-video").srcObject,
}));
await aliceLate.click("#leave");
const leaveDuringHold = await until(aliceLate, () => {
  const tiles = document.querySelectorAll(".tile").length;
  const local = !!document.querySelector("#local-video").srcObject;
  const status = document.querySelector("#status")?.textContent || "";
  return tiles === 0 && !local ? { tiles, local, status, held: !!window.__held, released: !!window.__released } : null;
}, null, 8000);
await aliceLate.evaluate(() => { if (window.__releaseBody) window.__releaseBody(); });
await aliceLate.waitForTimeout(1500);
const afterRelease = await aliceLate.evaluate(() => ({
  status: document.querySelector("#status")?.textContent || "",
  tiles: document.querySelectorAll(".tile").length,
  local: !!document.querySelector("#local-video").srcObject,
  captions: [...document.querySelectorAll(".tile p")].map((node) => node.textContent),
  released: !!window.__released,
  hook: window.__hook,
}));
const bobAfterLeave = await viewSnap(bobLate);
await browser2.close();

function pairOk(sample) {
  const first = sample.bob;
  const second = sample.sustained;
  const bytes = audioBytes(second.inbound);
  const grew = audioBytes(second.inbound) > audioBytes(first.inbound);
  return toneOk(first.tone) && toneOk(second.tone) && grew && bytes > 0
    && first.pixels && second.pixels && first.pixels.width > 0;
}

const out = {
  kind: "tone-and-color-0df60bee",
  source: SOURCE,
  olderLabeled: "reviews/2026-11-27-tone-diagnosis is the 6f98d267 page, not this source",
  productMutated: false,
  joined: !!joined,
  replaced: !!replaced,
  renewed: !!renewed,
  gap,
  renewGap,
  leaveSoon,
  leaveLater,
  lateBody: { beforeHold, duringHold, aliceDuring, leaveDuringHold, afterRelease, bobAfterLeave },
  pageErrors: errors,
  samples: samples.map((sample) => ({
    name: sample.name,
    bob: sample.bob,
    sustained: {
      tone: sample.sustained.tone,
      inbound: sample.sustained.inbound,
      pixels: sample.sustained.pixels,
      caption: sample.sustained.caption,
      owner: sample.sustained.owner,
      element: sample.sustained.element,
    },
    sustainedOk: pairOk(sample),
  })),
};
fs.writeFileSync(`${P}/evidence/summary.json`, JSON.stringify(out, null, 2));
console.log(JSON.stringify(out.samples.map((sample) => ({
  name: sample.name,
  ok: sample.sustainedOk,
  peak: sample.bob.tone.peakHz,
  peak2: sample.sustained.tone.peakHz,
  rms: sample.bob.tone.rms,
  rms2: sample.sustained.tone.rms,
  bytes: audioBytes(sample.bob.inbound),
  bytes2: audioBytes(sample.sustained.inbound),
  left: sample.sustained.pixels && sample.sustained.pixels.left,
  right: sample.sustained.pixels && sample.sustained.pixels.right,
  width: sample.sustained.pixels && sample.sustained.pixels.width,
  caption: sample.sustained.caption,
  audio: sample.bob.tone.attachedTo,
}))));
console.log(JSON.stringify({ leaveSoon, leaveLater, duringHold, leaveDuringHold, afterRelease }));

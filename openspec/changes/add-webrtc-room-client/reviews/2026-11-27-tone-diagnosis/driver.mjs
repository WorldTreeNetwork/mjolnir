import { chromium } from "playwright";
import fs from "node:fs";

const P = process.env.P;
const root = fs.readFileSync(`${P}/alice.meta`, "utf8").trim().split("\n")[0];
const alice = fs.readFileSync(`${P}/alice.tok`, "utf8").trim();
const alice2 = fs.readFileSync(`${P}/alice2.tok`, "utf8").trim();
const bob = fs.readFileSync(`${P}/bob.tok`, "utf8").trim();
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
  q.set("t", token);
  q.set("root", root);
  q.set("kind", "open");
  q.set("self", self);
  q.set("retry", "1000");
  q.set("mintRoot", root);
  if (peer) q.append("peer", peer);
  return `${pageOrigin}/page/room.html#${q}`;
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

function describeTrack(track) {
  if (!track) return null;
  return { id: track.id, kind: track.kind, readyState: track.readyState, muted: track.muted, enabled: track.enabled };
}

async function collect(page, label) {
  return page.evaluate(async (label) => {
    const tile = document.querySelector('[data-path="alice/cam"]') || document.querySelector('[data-path="bob/cam"]');
    const video = tile ? tile.querySelector("video") : document.querySelector("#local-video");
    const stream = video && video.srcObject;
    const tracks = stream ? stream.getTracks().map((track) => ({
      id: track.id, kind: track.kind, readyState: track.readyState, muted: track.muted, enabled: track.enabled,
    })) : [];
    const audio = stream && stream.getAudioTracks().find((track) => track.readyState === "live");
    let play = null;
    if (video) {
      try {
        await video.play();
        play = "resolved";
      } catch (error) {
        play = error.name || String(error);
      }
    }
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
            totalAudioEnergy: row.totalAudioEnergy, totalSamplesReceived: row.totalSamplesReceived,
            totalSamplesDecoded: row.totalSamplesDecoded, jitter: row.jitter,
            framesDecoded: row.framesDecoded, frameWidth: row.frameWidth, frameHeight: row.frameHeight,
          });
        }
        if (row.type === "outbound-rtp" && (row.kind === "audio" || row.kind === "video")) {
          outbound.push({
            kind: row.kind, bytesSent: row.bytesSent, packetsSent: row.packetsSent,
            audioLevel: row.audioLevel, totalAudioEnergy: row.totalAudioEnergy,
            framesEncoded: row.framesEncoded,
          });
        }
      }
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
        streamTrackIds: owned.getTracks().map((track) => track.id),
      };
      await ctx.close();
    }
    return {
      label,
      hook: window.__hook,
      status: document.querySelector("#status")?.textContent || "",
      owner: tile ? tile.dataset.owner || "" : "",
      caption: tile ? (tile.querySelector("p")?.textContent || "") : "",
      element: video ? {
        id: video.id, muted: video.muted, volume: video.volume, paused: video.paused,
        readyState: video.readyState, videoWidth: video.videoWidth, videoHeight: video.videoHeight,
      } : null,
      play,
      tracks,
      inbound,
      outbound,
      tone,
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
await until(bobPage, () => {
  const video = document.querySelector('[data-path="alice/cam"] video');
  return !!(video && video.videoWidth > 0);
}, null, 30000);

const samples = [];
async function take(name) {
  const bobSample = await collect(bobPage, `${name}-bob`);
  const aliceSample = await collect(alicePage, `${name}-alice-local`);
  const again = await collect(bobPage, `${name}-bob-fresh-analyser`);
  samples.push({ name, bob: bobSample, bobAgain: again, alice: aliceSample });
}
await take("join");
const joinOwner = samples[0].bob.owner;
const joinAudio = (samples[0].bob.tracks.find((track) => track.kind === "audio") || {}).id;

await alicePage.click("#replace");
await until(bobPage, ({ joinOwner, joinAudio }) => {
  const tile = document.querySelector('[data-path="alice/cam"]');
  const video = tile && tile.querySelector("video");
  const audio = video && video.srcObject && video.srcObject.getAudioTracks()[0];
  return !!(video && video.videoWidth > 0 && tile.dataset.owner !== joinOwner && audio && audio.id !== joinAudio);
}, { joinOwner, joinAudio }, 25000);
await take("replace");

const replaceSessions = JSON.stringify((await alicePage.evaluate(() => window.roomClient.status().sessions)));
await alicePage.fill("#renew-token", alice2);
await alicePage.click("#renew");
await until(alicePage, (previous) => {
  const status = document.querySelector("#status")?.textContent || "";
  return status === "In the room." && JSON.stringify(window.roomClient.status().sessions) !== previous;
}, replaceSessions, 25000);
const replaceAudio = (samples[1].bob.tracks.find((track) => track.kind === "audio") || {}).id;
await take("renew-immediate");
const renewed = await until(bobPage, (previousAudio) => {
  const video = document.querySelector('[data-path="alice/cam"] video');
  const audio = video && video.srcObject && video.srcObject.getAudioTracks()[0];
  return !!(audio && audio.id !== previousAudio && audio.readyState === "live" && video.videoWidth > 0);
}, replaceAudio, 12000);
await take(renewed ? "renew-new-track" : "renew-no-new-track");

const out = {
  kind: "tone-diagnosis",
  productMutated: false,
  hook: "measurement-only RTCPeerConnection recorder",
  pageErrors: errors,
  samples: samples.map((sample) => ({
    name: sample.name,
    bob: {
      status: sample.bob.status,
      owner: sample.bob.owner,
      caption: sample.bob.caption,
      element: sample.bob.element,
      play: sample.bob.play,
      tracks: sample.bob.tracks,
      inbound: sample.bob.inbound,
      tone: sample.bob.tone,
      toneAgain: sample.bobAgain.tone,
      inboundAgain: sample.bobAgain.inbound,
    },
    alice: {
      status: sample.alice.status,
      element: sample.alice.element,
      tracks: sample.alice.tracks,
      outbound: sample.alice.outbound,
      sessions: sample.alice.room && sample.alice.room.sessions,
      incumbent: sample.alice.room && sample.alice.room.incumbent,
    },
  })),
};
fs.writeFileSync(`${P}/evidence/summary.json`, JSON.stringify(out, null, 2));
const heard = (sample) => sample.bob.tone.rms > 0.001 || sample.bobAgain.tone.rms > 0.001;
console.log(JSON.stringify(samples.map((sample) => ({
  name: sample.name,
  heard: heard(sample),
  peak: sample.bobAgain.tone.peakHz,
  rms: sample.bobAgain.tone.rms,
  audio: (sample.bob.tracks.find((track) => track.kind === "audio") || {}).id,
}))));
await browser.close();

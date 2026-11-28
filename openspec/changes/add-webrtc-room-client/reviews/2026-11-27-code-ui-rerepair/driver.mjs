import { chromium } from "playwright";
import fs from "node:fs";

const P = process.env.P;
const root = fs.readFileSync(`${P}/alice.meta`, "utf8").trim().split("\n")[0];
const alice = fs.readFileSync(`${P}/alice.tok`, "utf8").trim();
const alice2 = fs.readFileSync(`${P}/alice2.tok`, "utf8").trim();
const bob = fs.readFileSync(`${P}/bob.tok`, "utf8").trim();
const short = fs.readFileSync(`${P}/short.tok`, "utf8").trim();
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

async function arm(context, mode) {
  await context.addInitScript((mode) => {
    window.__mode = mode;
    window.__http = [];
    window.__gum = [];
    window.__blockUnmuted = mode === "autoplay";
    const origFetch = window.fetch.bind(window);
    window.fetch = async (input, init) => {
      if (mode === "overlap" && init && init.method === "DELETE") {
        window.__http.push({ method: "DELETE", path: String(input), status: "hung", auth: "present" });
        return new Promise(() => {});
      }
      const res = await origFetch(input, init);
      const raw = typeof input === "string" ? input : input.url;
      let path = raw;
      try { path = new URL(raw, location.href).pathname; } catch { /* keep */ }
      window.__http.push({ method: (init && init.method) || "GET", path, status: res.status, redirected: res.redirected });
      if (mode === "body" && path.includes("/whip/") && res.status === 201) {
        res.text = async () => { throw new Error("body reset"); };
      }
      return res;
    };
    const Orig = window.RTCPeerConnection;
    let pcs = 0;
    window.RTCPeerConnection = function (...ctor) {
      pcs += 1;
      if (mode === "construct") throw new Error("resources exhausted");
      const pc = new Orig(...ctor);
      if (mode === "ice") {
        const setLocal = pc.setLocalDescription.bind(pc);
        pc.setLocalDescription = async (description) => {
          await setLocal(description);
          Object.defineProperty(pc, "iceGatheringState", { configurable: true, get: () => "gathering" });
        };
      }
      if (mode === "shared" && pcs === 3) {
        const offer = pc.createOffer.bind(pc);
        pc.createOffer = async () => { await offer(); throw new Error("candidate"); };
      }
      return pc;
    };
    window.RTCPeerConnection.prototype = Orig.prototype;
    const gum = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    let shared = null;
    navigator.mediaDevices.getUserMedia = async (constraints) => {
      if (mode === "shared" && shared) {
        window.__gum.push(shared.getTracks().map((track) => track.readyState));
        return shared;
      }
      const stream = await gum(constraints);
      shared = stream;
      window.__streams = window.__streams || [];
      window.__streams.push(stream);
      window.__gum.push(stream.getTracks().map((track) => track.readyState));
      return stream;
    };
    const origPlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function play() {
      if (window.__blockUnmuted && !this.muted) {
        return Promise.reject(new DOMException("autoplay blocked by harness", "NotAllowedError"));
      }
      return origPlay.call(this);
    };
  }, mode);
}

async function snap(page) {
  return page.evaluate(() => ({
    status: document.querySelector("#status")?.textContent || "",
    resumeHidden: document.querySelector("#resume")?.hidden ?? null,
    http: window.__http || [],
    gum: window.__gum || [],
    room: window.roomClient ? window.roomClient.status() : null,
    local: [...(document.querySelector("#local-video")?.srcObject?.getTracks() || [])].map((track) => ({
      id: track.id, kind: track.kind, state: track.readyState,
    })),
    streams: (window.__streams || []).map((stream) => stream.getTracks().map((track) => ({
      id: track.id, kind: track.kind, state: track.readyState,
    }))),
    tiles: [...document.querySelectorAll(".tile")].map((node) => {
      const video = node.querySelector("video");
      return {
        path: node.dataset.path,
        owner: node.dataset.owner || "",
        caption: node.querySelector("p")?.textContent || "",
        width: video?.videoWidth || 0,
        height: video?.videoHeight || 0,
      };
    }),
  }));
}

async function until(page, pred, ms) {
  const start = Date.now();
  let last = null;
  while (Date.now() - start < ms) {
    last = await snap(page);
    if (pred(last)) return last;
    await page.waitForTimeout(200);
  }
  return last;
}

function playing(snapshot, path) {
  const tile = (snapshot.tiles || []).find((item) => item.path === path);
  return !!(tile && tile.caption === "Playing." && tile.width > 0);
}

async function sample(page, path) {
  return page.evaluate(async (path) => {
    const video = document.querySelector(`[data-path="${CSS.escape(path)}"] video`);
    if (!video || !video.videoWidth) return { decoded: false, width: video ? video.videoWidth : 0 };
    const canvas = document.createElement("canvas");
    canvas.width = 64;
    canvas.height = 36;
    const g = canvas.getContext("2d", { willReadFrequently: true });
    g.drawImage(video, 0, 0, 64, 36);
    const data = g.getImageData(0, 0, 64, 36).data;
    const avg = (x0, x1) => {
      let r = 0, gg = 0, b = 0, n = 0;
      for (let y = 4; y < 32; y += 1) {
        for (let x = x0; x < x1; x += 1) {
          const i = (y * 64 + x) * 4;
          r += data[i]; gg += data[i + 1]; b += data[i + 2]; n += 1;
        }
      }
      return [r / n, gg / n, b / n].map(Math.round);
    };
    const audio = video.srcObject && video.srcObject.getAudioTracks()[0];
    let audioPeakHz = null;
    let audioRms = null;
    if (audio && audio.readyState === "live") {
      const ctx = new AudioContext();
      await ctx.resume();
      const src = ctx.createMediaStreamSource(new MediaStream([audio]));
      const an = ctx.createAnalyser();
      an.fftSize = 8192;
      src.connect(an);
      await new Promise((resolve) => setTimeout(resolve, 400));
      const fr = new Float32Array(an.frequencyBinCount);
      an.getFloatFrequencyData(fr);
      let best = 0;
      for (let i = 1; i < fr.length; i += 1) if (fr[i] > fr[best]) best = i;
      const td = new Float32Array(an.fftSize);
      an.getFloatTimeDomainData(td);
      audioPeakHz = Math.round(best * ctx.sampleRate / an.fftSize);
      audioRms = Number(Math.sqrt(td.reduce((sum, x) => sum + x * x, 0) / td.length).toFixed(4));
      if (!audioPeakHz) {
        await new Promise((resolve) => setTimeout(resolve, 400));
        an.getFloatFrequencyData(fr);
        best = 0;
        for (let i = 1; i < fr.length; i += 1) if (fr[i] > fr[best]) best = i;
        an.getFloatTimeDomainData(td);
        audioPeakHz = Math.round(best * ctx.sampleRate / an.fftSize);
        audioRms = Number(Math.sqrt(td.reduce((sum, x) => sum + x * x, 0) / td.length).toFixed(4));
      }
      await ctx.close();
    }
    return {
      decoded: true, left: avg(4, 28), right: avg(36, 60),
      width: video.videoWidth, height: video.videoHeight,
      caption: video.closest(".tile")?.querySelector("p")?.textContent || "",
      audioPeakHz, audioRms,
    };
  }, path);
}

const browser = await chromium.launch({ executablePath: "/usr/bin/chromium", headless: true, args });
const errors = [];
const media = await browser.newContext();
await arm(media, "autoplay");
const alicePage = await media.newPage();
const bobPage = await media.newPage();
for (const [name, page] of [["alice", alicePage], ["bob", bobPage]]) {
  page.on("pageerror", (error) => errors.push(`${name} ${error.message}`));
}
await alicePage.goto(url(alice, "alice/cam", "bob/cam"));
await alicePage.click("#join");
await until(alicePage, (s) => s.status === "In the room.", 25000);
await bobPage.goto(url(bob, "bob/cam", "alice/cam"));
await bobPage.click("#join");
const decodedSnap = await until(bobPage, (s) => playing(s, "alice/cam"), 30000);
const decoded = await sample(bobPage, "alice/cam");
await bobPage.evaluate(() => { window.__blockUnmuted = false; });
const beforeReplace = await snap(alicePage);
await alicePage.click("#replace");
const afterReplace = await until(alicePage, (s) => s.status === "In the room." && s.room && s.room.incumbent !== beforeReplace.room.incumbent, 25000);
const decodedAfterReplace = await until(bobPage, (s) => playing(s, "alice/cam"), 20000).then(() => sample(bobPage, "alice/cam"));
await bobPage.evaluate(() => { window.__blockUnmuted = true; });
await alicePage.click("#replace");
const blocked = await until(bobPage, (s) => s.tiles.some((tile) => tile.caption.startsWith("Playback is blocked")), 20000);
await bobPage.evaluate(() => { window.__blockUnmuted = false; });
await bobPage.click("#resume");
const resumed = await until(bobPage, (s) => playing(s, "alice/cam") && s.resumeHidden === true, 15000);
const decodedResume = await sample(bobPage, "alice/cam");
const aliceNow = await snap(alicePage);
await alicePage.fill("#renew-token", bob);
await alicePage.click("#renew");
const badRenew = await until(alicePage, (s) => s.status === "This token cannot publish that path.", 15000);
await alicePage.fill("#renew-token", alice2);
await alicePage.click("#renew");
const goodRenew = await until(alicePage, (s) => s.status === "In the room." && JSON.stringify(s.room.sessions) !== JSON.stringify(badRenew.room.sessions), 25000);
const decodedRenew = await until(bobPage, (s) => playing(s, "alice/cam"), 20000).then(() => sample(bobPage, "alice/cam"));
await alicePage.click("#leave");
const left = await until(alicePage, (s) => s.status === "Left the room." && s.room.sessions.length === 0, 15000);

async function hooked(mode, token, run) {
  const context = await browser.newContext();
  await arm(context, mode);
  const page = await context.newPage();
  page.on("pageerror", (error) => errors.push(`${mode} ${error.message}`));
  await page.goto(url(token, "alice/cam", "bob/cam"));
  const result = await run(page);
  await context.close();
  return { mode, label: "harness hook on the real page and accepted gateway", ...result };
}

const construct = await hooked("construct", alice, async (page) => {
  await page.click("#join");
  const settled = await until(page, (s) => s.status && !s.status.startsWith("Joining"), 15000);
  return {
    status: settled.status,
    sessions: settled.room && settled.room.sessions,
    streams: settled.streams,
    whip: (settled.http || []).filter((row) => String(row.path).includes("/whip/")),
  };
});

const body = await hooked("body", alice, async (page) => {
  await page.click("#join");
  const settled = await until(page, (s) => (s.http || []).some((row) => row.method === "DELETE"), 15000);
  return {
    status: settled.status,
    deletes: (settled.http || []).filter((row) => row.method === "DELETE"),
    whip: (settled.http || []).filter((row) => String(row.path).includes("/whip/")),
  };
});

const ice = await hooked("ice", alice, async (page) => {
  await page.click("#join");
  await until(page, (s) => s.gum.length > 0, 10000);
  await page.click("#leave");
  const settled = await until(page, (s) => s.status === "Left the room." || s.status.includes("cleanup"), 10000);
  return { status: settled.status, msNote: "left while ICE gathering was forced to stay gathering" };
});

const shared = await hooked("shared", alice, async (page) => {
  await page.click("#join");
  await until(page, (s) => s.status === "In the room.", 20000);
  const before = await snap(page);
  await page.click("#replace");
  const after = await until(page, (s) => s.status !== "Replacing the connection…", 15000);
  return {
    status: after.status,
    incumbent: after.room && after.room.incumbent,
    beforeStreams: before.streams,
    afterStreams: after.streams,
  };
});

const overlap = await hooked("overlap", alice, async (page) => {
  await page.click("#join");
  await until(page, (s) => s.status === "In the room.", 20000);
  await page.click("#leave");
  await page.click("#join");
  const joined = await until(page, (s) => s.status === "In the room.", 20000);
  await page.waitForTimeout(500);
  const later = await snap(page);
  return { during: joined.status, later: later.status, hungDelete: (later.http || []).some((row) => row.status === "hung") };
});

const expiryContext = await browser.newContext();
await arm(expiryContext, "expiry");
const expiryPage = await expiryContext.newPage();
await expiryPage.goto(url(short, "alice/cam", "bob/cam"));
await expiryPage.click("#join");
const expiry = await until(expiryPage, (s) => s.status === "This token is not valid." && s.tiles.length === 0, 30000);
await expiryContext.close();

const out = {
  kind: "accepted-gateway-4bd94d1d plus labeled hooks",
  decoded,
  decodedCounts: !!(decoded.decoded && decoded.width > 0 && decoded.caption === "Playing."),
  waitingAtJoin: decodedSnap.tiles,
  replace: { before: beforeReplace.room && beforeReplace.room.incumbent, after: afterReplace.room && afterReplace.room.incumbent, decoded: decodedAfterReplace },
  autoplay: { blocked: blocked.tiles, resumeHiddenAfter: resumed.resumeHidden, decoded: decodedResume },
  badRenew: { status: badRenew.status, sessions: badRenew.room && badRenew.room.sessions },
  goodRenew: { status: goodRenew.status, sessions: goodRenew.room && goodRenew.room.sessions, decoded: decodedRenew },
  leave: { status: left.status, sessions: left.room && left.room.sessions, deletes: left.room && left.room.deletes },
  hooks: { construct, body, ice, shared, overlap, expiry: { status: expiry.status, tiles: expiry.tiles, local: expiry.local } },
  aliceSessionsAtRenew: aliceNow.room && aliceNow.room.sessions,
  pageErrors: errors,
};
fs.writeFileSync(`${P}/evidence/summary.json`, JSON.stringify(out, null, 2));
const ok = out.decodedCounts && decodedResume.decoded && resumed.resumeHidden === true && left.status === "Left the room."
  && construct.streams.some((stream) => stream.every((track) => track.state === "ended"))
  && body.deletes.some((row) => row.status === 204)
  && shared.incumbent === 1
  && shared.afterStreams[0] && shared.afterStreams[0].every((track) => track.state === "live")
  && overlap.later === "In the room."
  && expiry.status === "This token is not valid.";
console.log(ok ? "MJ15_RE_OK" : "MJ15_RE_INCOMPLETE");
await browser.close();
if (!ok) process.exit(2);

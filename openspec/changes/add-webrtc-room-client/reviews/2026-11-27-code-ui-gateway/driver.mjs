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
    window.__pcs = [];
    window.__localHistory = [];
    window.__blockUnmuted = false;
    const origFetch = window.fetch.bind(window);
    window.fetch = async (input, init) => {
      const res = await origFetch(input, init);
      const raw = typeof input === "string" ? input : input.url;
      let path = raw;
      try { path = new URL(raw, location.href).pathname; } catch { /* keep */ }
      const headers = new Headers((init && init.headers) || (input instanceof Request ? input.headers : undefined));
      window.__http.push({
        method: (init && init.method) || (input instanceof Request ? input.method : "GET"),
        path,
        status: res.status,
        auth: headers.has("authorization") ? "present" : "absent",
        redirected: res.redirected,
      });
      return res;
    };
    const Orig = window.RTCPeerConnection;
    window.RTCPeerConnection = new Proxy(Orig, {
      construct(target, ctorArgs) {
        const pc = new target(...ctorArgs);
        window.__pcs.push(pc);
        return pc;
      },
    });
    const origGum = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    navigator.mediaDevices.getUserMedia = async (constraints) => {
      window.__gum += 1;
      return origGum(constraints);
    };
    const desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "srcObject");
    Object.defineProperty(HTMLMediaElement.prototype, "srcObject", {
      configurable: true,
      get() { return desc.get.call(this); },
      set(value) {
        if (this.id === "local-video") {
          const prev = desc.get.call(this);
          const describe = (stream) => !stream ? [] : stream.getTracks().map((track) => ({
            id: track.id, kind: track.kind, state: track.readyState,
          }));
          window.__localHistory.push({ prev: describe(prev), next: describe(value) });
          window.__prevLocal = prev;
        }
        desc.set.call(this, value);
      },
    });
    const origPlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function play() {
      if (window.__blockUnmuted && !this.muted) {
        return Promise.reject(new DOMException("autoplay blocked by harness", "NotAllowedError"));
      }
      return origPlay.call(this);
    };
  });
}

function tracksOf(stream) {
  return !stream ? [] : stream.getTracks().map((track) => ({
    id: track.id, kind: track.kind, state: track.readyState,
  }));
}

async function snap(page) {
  return page.evaluate(() => {
    const local = document.querySelector("#local-video");
    const describe = (stream) => !stream ? [] : stream.getTracks().map((track) => ({
      id: track.id, kind: track.kind, state: track.readyState,
    }));
    const prev = window.__prevLocal;
    return {
      status: document.querySelector("#status")?.textContent || "",
      hash: location.hash,
      notice: document.querySelector("#notice")?.textContent || "",
      gum: window.__gum || 0,
      pcsOpen: (window.__pcs || []).filter((pc) => pc.connectionState !== "closed").length,
      pcsTotal: (window.__pcs || []).length,
      http: window.__http || [],
      room: window.roomClient ? window.roomClient.status() : null,
      resumeHidden: document.querySelector("#resume")?.hidden ?? null,
      local: describe(local && local.srcObject),
      previousLocal: describe(prev),
      previewIsPrevious: !!(local && prev && local.srcObject === prev),
      localHistory: window.__localHistory || [],
      tiles: [...document.querySelectorAll(".tile")].map((node) => {
        const video = node.querySelector("video");
        return {
          path: node.dataset.path,
          attempt: node.dataset.attempt || "",
          caption: node.querySelector("p")?.textContent || "",
          width: video?.videoWidth || 0,
          height: video?.videoHeight || 0,
          tracks: describe(video && video.srcObject),
        };
      }),
    };
  });
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

function playing(snapshot, path) {
  const tile = (snapshot.tiles || []).find((item) => item.path === path);
  return !!(tile && tile.caption === "Playing." && tile.width > 0 && tile.height > 0);
}

async function sample(page, path) {
  return page.evaluate(async (path) => {
    const video = document.querySelector(`[data-path="${CSS.escape(path)}"] video`);
    if (!video || !video.videoWidth) return { error: "no-decoded-video", width: video ? video.videoWidth : 0 };
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
    const tracks = video.srcObject ? video.srcObject.getTracks().map((track) => ({
      kind: track.kind, state: track.readyState,
    })) : [];
    const audio = video.srcObject && video.srcObject.getAudioTracks()[0];
    let audioPeakHz = null, audioRms = null;
    if (audio && audio.readyState === "live") {
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
    return {
      decoded: true,
      left: avg(4, 28),
      right: avg(36, 60),
      width: video.videoWidth,
      height: video.videoHeight,
      caption: video.closest(".tile")?.querySelector("p")?.textContent || "",
      tracks,
      audioPeakHz,
      audioRms: audioRms && Number(audioRms.toFixed(4)),
    };
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
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(`${name} console ${msg.text().slice(0, 180)}`);
  });
}

await alicePage.goto(url(alice, "alice/cam", "bob/cam"));
const beforeJoin = await snap(alicePage);
await alicePage.click("#join");
const aliceJoined = await until(alicePage, (s) => s.status === "In the room.", 25000);

await bobPage.goto(url(bob, "bob/cam", "alice/cam"));
await bobPage.click("#join");
const bobDecodedSnap = await until(bobPage, (s) => playing(s, "alice/cam"), 30000);
const decoded = await sample(bobPage, "alice/cam");

const beforeReplace = await snap(alicePage);
const bobTracksBefore = bobDecodedSnap.tiles.find((t) => t.path === "alice/cam");
await alicePage.click("#replace");
const afterReplace = await until(alicePage, (s) => {
  const sessions = (s.room && s.room.sessions) || [];
  const prev = (beforeReplace.room && beforeReplace.room.sessions) || [];
  const oldEnded = (s.previousLocal || []).length > 0 && s.previousLocal.every((t) => t.state === "ended");
  const currentLive = (s.local || []).some((t) => t.state === "live");
  return s.status === "In the room."
    && s.room && s.room.incumbent !== beforeReplace.room.incumbent
    && sessions.length > 0 && sessions.join() !== prev.join()
    && oldEnded && currentLive && !s.previewIsPrevious;
}, 25000);
const bobAfterReplace = await until(bobPage, (s) => playing(s, "alice/cam") && s.tiles.some((t) => {
  const before = (bobTracksBefore && bobTracksBefore.tracks) || [];
  const now = t.path === "alice/cam" ? t.tracks : [];
  return now.length > 0 && now.every((track) => track.state === "live")
    && before.length > 0 && now.map((track) => track.id).join() !== before.map((track) => track.id).join();
}), 25000);
const decodedAfterReplace = await sample(bobPage, "alice/cam");

await bobPage.evaluate(() => { window.__blockUnmuted = true; });
const sessionsBeforeAutoplay = (afterReplace.room && afterReplace.room.sessions) || [];
await alicePage.click("#replace");
const blocked = await until(bobPage, (s) => s.resumeHidden === false && s.tiles.some((t) => t.caption.startsWith("Playback is blocked")), 25000);
await bobPage.evaluate(() => { window.__blockUnmuted = false; });
await bobPage.click("#resume");
const afterResume = await until(bobPage, (s) => playing(s, "alice/cam") && s.resumeHidden === true, 20000);
const decodedAfterResume = await sample(bobPage, "alice/cam");
const aliceAfterAutoplay = await until(alicePage, (s) => {
  const sessions = (s.room && s.room.sessions) || [];
  return s.status === "In the room." && sessions.join() !== sessionsBeforeAutoplay.join();
}, 20000);

const sessionsBeforeBad = ((aliceAfterAutoplay.room && aliceAfterAutoplay.room.sessions) || []).slice();
const gumBeforeBad = aliceAfterAutoplay.gum;
await alicePage.fill("#renew-token", bob);
await alicePage.click("#renew");
const afterBadRenew = await until(alicePage, (s) => s.status === "This token cannot publish that path.", 15000);
const renewalCleared = await alicePage.inputValue("#renew-token");

await alicePage.fill("#renew-token", alice2);
await alicePage.click("#renew");
const afterGoodRenew = await until(alicePage, (s) => {
  const sessions = (s.room && s.room.sessions) || [];
  return s.status === "In the room." && sessions.length > 0 && sessions.join() !== sessionsBeforeBad.join();
}, 25000);
const bobAfterRenew = await until(bobPage, (s) => playing(s, "alice/cam"), 25000);
const decodedAfterRenew = await sample(bobPage, "alice/cam");

await alicePage.click("#leave");
const afterLeave = await until(alicePage, (s) => s.status === "Left the room." && s.room && s.room.sessions.length === 0 && s.room.tracks === 0 && s.local.length === 0, 15000);

const refusal = await browser.newContext();
await arm(refusal);
async function refusalCase(name, token) {
  const page = await refusal.newPage();
  page.on("pageerror", (e) => errors.push(`${name} ${e.message}`));
  const target = token === null ? `${pageOrigin}/page/room.html` : url(token, "alice/cam", "bob/cam");
  await page.goto(target);
  if (name === "expired") await page.waitForTimeout(3500);
  await page.click("#join");
  const settled = await until(page, (s) => s.status && !s.status.startsWith("Joining"), 12000);
  const view = {
    name,
    status: settled.status,
    gum: settled.gum,
    pcsTotal: settled.pcsTotal,
    http: settled.http,
    hash: settled.hash,
  };
  await page.close();
  return view;
}
const empty = await refusalCase("empty", null);
const bad = await refusalCase("bad", "not-a-jwt");
const expiredCase = await refusalCase("expired", expired);

function ownership(before, after) {
  return {
    incumbentBefore: before.room && before.room.incumbent,
    incumbentAfter: after.room && after.room.incumbent,
    sessionsBefore: before.room && before.room.sessions,
    sessionsAfter: after.room && after.room.sessions,
    previousTracks: after.previousLocal,
    currentTracks: after.local,
    previousEnded: (after.previousLocal || []).length > 0 && after.previousLocal.every((t) => t.state === "ended"),
    currentLive: (after.local || []).some((t) => t.state === "live"),
    previewIsPrevious: after.previewIsPrevious,
  };
}

const out = {
  kind: "accepted-gateway-4bd94d1d",
  origin,
  pageOrigin,
  rootLength: root.length,
  beforeJoin: { hash: beforeJoin.hash, notice: beforeJoin.notice, gum: beforeJoin.gum, pcsTotal: beforeJoin.pcsTotal },
  aliceJoined: {
    status: aliceJoined.status,
    tiles: aliceJoined.tiles,
    gum: aliceJoined.gum,
    sessions: aliceJoined.room && aliceJoined.room.sessions,
    incumbent: aliceJoined.room && aliceJoined.room.incumbent,
    http: aliceJoined.http,
  },
  decoded,
  decodedCountsAsPlaying: !!(decoded.decoded && decoded.width > 0 && decoded.caption === "Playing."),
  replace: ownership(beforeReplace, afterReplace),
  bobAfterReplace: { tiles: bobAfterReplace.tiles, decoded: decodedAfterReplace },
  autoplay: {
    blockedCaption: blocked.tiles,
    resumeWasHidden: blocked.resumeHidden,
    afterResume: { tiles: afterResume.tiles, resumeHidden: afterResume.resumeHidden },
    decoded: decodedAfterResume,
  },
  badRenew: {
    status: afterBadRenew.status,
    sessions: afterBadRenew.room && afterBadRenew.room.sessions,
    sessionsUnchanged: JSON.stringify(afterBadRenew.room && afterBadRenew.room.sessions) === JSON.stringify(sessionsBeforeBad),
    gum: afterBadRenew.gum,
    gumUnchanged: afterBadRenew.gum === gumBeforeBad,
    incumbent: afterBadRenew.room && afterBadRenew.room.incumbent,
    renewalField: renewalCleared,
    http: afterBadRenew.http.filter((row) => row.path.includes("admit") || row.status === 403),
  },
  goodRenew: {
    status: afterGoodRenew.status,
    sessions: afterGoodRenew.room && afterGoodRenew.room.sessions,
    incumbent: afterGoodRenew.room && afterGoodRenew.room.incumbent,
    deletes: afterGoodRenew.room && afterGoodRenew.room.deletes,
    decoded: decodedAfterRenew,
    bobPlaying: playing(bobAfterRenew, "alice/cam"),
  },
  leave: {
    status: afterLeave.status,
    tracks: afterLeave.room && afterLeave.room.tracks,
    sessions: afterLeave.room && afterLeave.room.sessions,
    pcs: afterLeave.room && afterLeave.room.pcs,
    local: afterLeave.local,
    deletes: afterLeave.room && afterLeave.room.deletes,
  },
  refusals: [empty, bad, expiredCase],
  pageErrors: errors,
};
fs.writeFileSync(`${P}/evidence/summary.json`, JSON.stringify(out, null, 2));
const ok = out.decodedCountsAsPlaying
  && out.replace.previousEnded
  && out.replace.currentLive
  && !out.replace.previewIsPrevious
  && decodedAfterReplace.decoded
  && decodedAfterReplace.width > 0
  && decodedAfterResume.decoded
  && afterLeave.status === "Left the room.";
console.log(ok ? "MJ15_GW_OK" : "MJ15_GW_INCOMPLETE");
await browser.close();
if (!ok) process.exit(2);

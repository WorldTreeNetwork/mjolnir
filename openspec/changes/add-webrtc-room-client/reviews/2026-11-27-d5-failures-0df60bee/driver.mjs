import { chromium } from "playwright";
import fs from "node:fs";

const P = process.env.P;
const root = fs.readFileSync(`${P}/alice.meta`, "utf8").trim().split("\n")[0];
const aliceTok = fs.readFileSync(`${P}/alice.tok`, "utf8").trim();
const bobTok = fs.readFileSync(`${P}/bob.tok`, "utf8").trim();
const carolTok = fs.readFileSync(`${P}/carol.tok`, "utf8").trim();
const pageOrigin = process.env.PAGE_ORIGIN;
const SOURCE = "0df60bee32e02b8908e2438259ed8e3d10b38adc";
const args = [
  "--autoplay-policy=no-user-gesture-required",
  "--use-fake-ui-for-media-stream",
  "--use-fake-device-for-media-stream",
  `--use-file-for-fake-video-capture=${process.env.Y4M}`,
  `--use-file-for-fake-audio-capture=${process.env.WAV}`,
];

function url(token, self, peers) {
  const q = new URLSearchParams();
  q.set("t", token);
  q.set("root", root);
  q.set("kind", "open");
  q.set("self", self);
  q.set("retry", "1000");
  q.set("mintRoot", root);
  for (const peer of peers) q.append("peer", peer);
  return `${pageOrigin}/page/room.html#${q}`;
}

function redact(value) {
  return JSON.parse(JSON.stringify(value, (key, item) => {
    if (key === "token" || key === "authorization") return "[redacted]";
    if (typeof item === "string" && item.includes("eyJ")) return "[jwt]";
    return item;
  }));
}

const init = () => {
  window.__hook = "labeled D5: body reject, bad answer, or stalled publisher connectionState";
  window.__mode = "";
  window.__arm = false;
  window.__armIce = false;
  window.__events = [];
  window.__pcs = [];
  const OrigFetch = window.fetch.bind(window);
  window.fetch = async (...fetchArgs) => {
    const res = await OrigFetch(...fetchArgs);
    const init = fetchArgs[1] || {};
    const method = String(init.method || "GET").toUpperCase();
    if (!(window.__arm && method === "POST" && res.status === 201)) return res;
    window.__arm = false;
    window.__events.push({ t: Date.now(), kind: "whip-201", mode: window.__mode });
    const headers = new Headers(res.headers);
    if (window.__mode === "body") {
      const body = new ReadableStream({ start(controller) { controller.error(new Error("labeled body failure")); } });
      return new Response(body, { status: 201, statusText: res.statusText, headers });
    }
    if (window.__mode === "sdp") {
      return new Response("not-an-sdp", { status: 201, statusText: res.statusText, headers });
    }
    return res;
  };
  const Orig = window.RTCPeerConnection;
  window.RTCPeerConnection = new Proxy(Orig, {
    construct(target, ctorArgs) {
      const pc = new target(...ctorArgs);
      const rec = { born: Date.now(), publisher: false, stalled: false, closed: false };
      window.__pcs.push(rec);
      const addTrack = pc.addTrack.bind(pc);
      pc.addTrack = (...trackArgs) => {
        rec.publisher = true;
        if (window.__mode === "ice" && window.__armIce) {
          window.__armIce = false;
          rec.stalled = true;
          window.__events.push({ t: Date.now(), kind: "stall-publisher-connectionState" });
          const real = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(pc), "connectionState");
          Object.defineProperty(pc, "connectionState", {
            configurable: true,
            get() { return rec.stalled ? "connecting" : real.get.call(pc); },
          });
        }
        return addTrack(...trackArgs);
      };
      const close = pc.close.bind(pc);
      pc.close = () => {
        rec.closed = true;
        rec.closedAt = Date.now();
        return close();
      };
      return pc;
    },
  });
};

async function view(page) {
  return page.evaluate(() => {
    const tiles = [...document.querySelectorAll(".tile")].map((node) => {
      const video = node.querySelector("video");
      const stream = video && video.srcObject;
      const tracks = stream ? stream.getTracks().map((track) => ({
        id: track.id, kind: track.kind, readyState: track.readyState, muted: track.muted,
      })) : [];
      return {
        path: node.dataset.path || "",
        owner: node.dataset.owner || "",
        caption: node.querySelector("p")?.textContent || "",
        srcObject: !!stream,
        width: video ? video.videoWidth : 0,
        tracks,
      };
    });
    return {
      status: document.querySelector("#status")?.textContent || "",
      local: !!document.querySelector("#local-video").srcObject,
      tiles,
    };
  });
}

async function aliceState(page) {
  return page.evaluate(() => {
    const live = window.roomClient.status();
    const local = document.querySelector("#local-video");
    const localTracks = local.srcObject ? local.srcObject.getTracks().map((track) => ({
      id: track.id, kind: track.kind, readyState: track.readyState,
    })) : [];
    return {
      status: document.querySelector("#status")?.textContent || "",
      incumbent: live.incumbent,
      candidate: live.candidate,
      tracks: live.tracks,
      pcs: live.pcs,
      sessions: live.sessions,
      localTracks,
      pcsDetail: (window.__pcs || []).map((rec) => ({
        publisher: rec.publisher, stalled: rec.stalled, closed: rec.closed,
      })),
      events: window.__events || [],
      hook: window.__hook,
    };
  });
}

async function tone(page, path) {
  return page.evaluate(async (path) => {
    const tile = document.querySelector(`[data-path="${path}"]`);
    const video = tile && tile.querySelector("video");
    const stream = video && video.srcObject;
    const audio = stream && stream.getAudioTracks().find((track) => track.readyState === "live");
    if (!audio) return { attachedTo: null, caption: tile ? tile.querySelector("p")?.textContent || "" : "" };
    const ctx = new AudioContext();
    await ctx.resume();
    const src = ctx.createMediaStreamSource(new MediaStream([audio]));
    const an = ctx.createAnalyser();
    an.fftSize = 8192;
    src.connect(an);
    await new Promise((resolve) => setTimeout(resolve, 700));
    const fr = new Float32Array(an.frequencyBinCount);
    an.getFloatFrequencyData(fr);
    let best = 1;
    for (let i = 2; i < fr.length; i += 1) if (fr[i] > fr[best]) best = i;
    const td = new Float32Array(an.fftSize);
    an.getFloatTimeDomainData(td);
    const rms = Math.sqrt(td.reduce((sum, x) => sum + x * x, 0) / td.length);
    const result = {
      attachedTo: audio.id,
      peakHz: Math.round(best * ctx.sampleRate / an.fftSize),
      rms: Number(rms.toFixed(4)),
      contextState: ctx.state,
      caption: tile.querySelector("p")?.textContent || "",
      width: video.videoWidth,
    };
    await ctx.close();
    return result;
  }, path);
}

async function untilStatus(page, ms) {
  const start = Date.now();
  let last = "";
  while (Date.now() - start < ms) {
    last = await page.evaluate(() => document.querySelector("#status")?.textContent || "");
    if (last && last !== "Replacing the connection…" && last !== "Joining…") return { status: last, ms: Date.now() - start };
    await page.waitForTimeout(200);
  }
  return { status: last, ms: Date.now() - start, timedOut: true };
}

function falsePlaying(snapshot) {
  return (snapshot.tiles || []).filter((tile) => tile.caption === "Playing." && (!tile.srcObject || tile.width === 0 || tile.tracks.some((track) => track.readyState === "ended")));
}

const browser = await chromium.launch({ executablePath: "/usr/bin/chromium", headless: true, args });
const cases = [];
const modes = [
  ["body", 20000],
  ["sdp", 20000],
  ["ice", 25000],
];

for (const [mode, budget] of modes) {
  const context = await browser.newContext();
  await context.addInitScript(init);
  const errors = [];
  const alice = await context.newPage();
  const bob = await context.newPage();
  const carol = await context.newPage();
  for (const [name, page] of [["alice", alice], ["bob", bob], ["carol", carol]]) {
    page.on("pageerror", (error) => errors.push(`${name} ${error.message}`));
  }
  await alice.goto(url(aliceTok, "alice/cam", ["bob/cam"]));
  await bob.goto(url(bobTok, "bob/cam", ["alice/cam"]));
  await carol.goto(url(carolTok, "carol/cam", ["alice/cam"]));
  await alice.click("#join");
  await bob.click("#join");
  const readyStart = Date.now();
  let ready = false;
  while (Date.now() - readyStart < 30000) {
    ready = await bob.evaluate(() => {
      const video = document.querySelector('[data-path="alice/cam"] video');
      return !!(video && video.videoWidth > 0);
    });
    if (ready) break;
    await bob.waitForTimeout(200);
  }
  const before = await aliceState(alice);
  const bobBefore = await view(bob);
  await alice.evaluate((mode) => {
    window.__mode = mode;
    window.__arm = mode === "body" || mode === "sdp";
    window.__armIce = mode === "ice";
  }, mode);
  await Promise.all([alice.click("#replace"), carol.click("#join")]);
  const settled = await untilStatus(alice, budget);
  const traces = [];
  const watchStart = Date.now();
  while (Date.now() - watchStart < 12000) {
    const bobNow = await view(bob);
    const carolNow = await view(carol);
    traces.push({
      ms: Date.now() - watchStart,
      bob: bobNow.tiles,
      carol: carolNow.tiles,
      bobStatus: bobNow.status,
      carolStatus: carolNow.status,
    });
    await bob.waitForTimeout(500);
  }
  const after = await aliceState(alice);
  const bobTone = await tone(bob, "alice/cam");
  const carolTone = await tone(carol, "alice/cam");
  const bobEnd = await view(bob);
  const carolEnd = await view(carol);
  const falseHits = [];
  for (const row of traces) {
    falseHits.push(...falsePlaying({ tiles: row.bob }).map((tile) => ({ who: "bob", ms: row.ms, tile })));
    falseHits.push(...falsePlaying({ tiles: row.carol }).map((tile) => ({ who: "carol", ms: row.ms, tile })));
  }
  cases.push(redact({
    mode,
    ready,
    before: { incumbent: before.incumbent, candidate: before.candidate, sessions: before.sessions, pcs: before.pcs, tracks: before.tracks, localTracks: before.localTracks },
    bobBefore,
    settled,
    after,
    bobEnd,
    carolEnd,
    bobTone,
    carolTone,
    falseHits,
    traces,
    errors,
  }));
  await context.close();
}

await browser.close();
const out = {
  source: SOURCE,
  productMutated: false,
  hook: "init-script labeled body reject, bad SDP, or stalled publisher connectionState",
  cases,
};
fs.writeFileSync(`${P}/evidence/summary.json`, JSON.stringify(out, null, 2));
console.log(JSON.stringify(cases.map((row) => ({
  mode: row.mode,
  ready: row.ready,
  settled: row.settled,
  incumbent: row.before.incumbent,
  incumbentAfter: row.after.incumbent,
  candidateAfter: row.after.candidate,
  sessionsBefore: row.before.sessions,
  sessionsAfter: row.after.sessions,
  pcs: row.after.pcs,
  tracks: row.after.tracks,
  pcsDetail: row.after.pcsDetail,
  events: row.after.events,
  bob: row.bobEnd,
  carol: row.carolEnd,
  bobTone: row.bobTone,
  carolTone: row.carolTone,
  falseHits: row.falseHits.length,
  errors: row.errors,
}))));

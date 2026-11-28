import { chromium } from "playwright";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, join, extname } from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = process.env.ROOM_DIR;
const pageOrigin = "http://127.0.0.1:18132";
const gatewayOrigin = "http://127.0.0.1:18452";
const root = `t/${"1".repeat(32)}/~open/r1`;
const trace = [];
const pending = [];
let whepTries = 0;
let hangDelete = false;
let sessions = 0;

function send(res, status, body, headers = {}) {
  const text = body == null ? "" : typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, {
    "access-control-allow-origin": pageOrigin,
    "access-control-expose-headers": "location, cache-control",
    "cache-control": "no-store",
    ...headers,
  });
  res.end(text);
}

function waitAnswer(kind, path, offer) {
  return new Promise((resolve) => pending.push({ kind, path, offer, resolve }));
}

const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };
const server = createServer(async (req, res) => {
  const url = new URL(req.url, gatewayOrigin);
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": pageOrigin,
      "access-control-allow-headers": "authorization, content-type, x-mjolnir-root",
      "access-control-allow-methods": "POST, DELETE, OPTIONS",
    });
    res.end();
    return;
  }
  if (url.pathname.startsWith("/page/") || url.pathname.startsWith("/src/")) {
    const file = join(rootDir, url.pathname.slice(1));
    const body = await readFile(file);
    res.writeHead(200, { "content-type": types[extname(file)] || "text/plain" });
    res.end(body);
    return;
  }
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8");
  const item = { method: req.method, path: url.pathname, auth: req.headers.authorization ? "present" : "absent" };
  trace.push(item);
  if (url.pathname === "/admit" && req.method === "POST") {
    const intent = JSON.parse(raw);
    if (req.headers.authorization === "Bearer expired") return send(res, 403, { error: "bad_token" });
    if (req.headers.authorization === "Bearer bob") return send(res, 403, { error: "forbidden" });
    item.operation = intent.operation;
    item.broadcast = intent.broadcast;
    return send(res, 200, { root, exp: Math.floor(Date.now() / 1000) + 600, ...intent });
  }
  if (req.method === "DELETE" && url.pathname.startsWith("/session/")) {
    if (hangDelete) return;
    item.status = 204;
    return send(res, 204, "");
  }
  if (req.method === "POST" && (url.pathname.includes("/whip/") || url.pathname.includes("/whep/"))) {
    const kind = url.pathname.includes("/whip/") ? "whip" : "whep";
    if (kind === "whep") {
      whepTries += 1;
      if (whepTries === 1) {
        item.status = 409;
        return send(res, 409, { error: "not_started" });
      }
    }
    const answer = await waitAnswer(kind, url.pathname, raw);
    sessions += 1;
    const location = `/session/s${sessions}`;
    item.status = 201;
    item.location = location;
    return send(res, 201, answer, { location, "content-type": "application/sdp" });
  }
  send(res, 404, { error: "nope" });
});
await new Promise((resolve) => server.listen(18452, "127.0.0.1", resolve));
const pages = createServer(async (req, res) => {
  const url = new URL(req.url, pageOrigin);
  const file = join(rootDir, url.pathname.slice(1));
  try {
    const body = await readFile(file);
    res.writeHead(200, { "content-type": types[extname(file)] || "text/plain", "referrer-policy": "no-referrer" });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("missing");
  }
});
await new Promise((resolve) => pages.listen(18132, "127.0.0.1", resolve));

const browser = await chromium.launch({
  executablePath: "/usr/bin/chromium",
  headless: true,
  args: ["--autoplay-policy=no-user-gesture-required", "--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream"],
});

async function answerNext(aux) {
  const started = Date.now();
  while (pending.length === 0) {
    if (Date.now() - started > 8000) throw new Error("no offer");
    await new Promise((r) => setTimeout(r, 50));
  }
  const job = pending.shift();
  const answer = await aux.evaluate(async (offer) => {
    const pc = new RTCPeerConnection();
    window.__pcs = window.__pcs || [];
    window.__pcs.push(pc);
    const stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
    if (offer.includes("recvonly") || offer.includes("m=video")) {
      for (const track of stream.getTracks()) pc.addTrack(track, stream);
    }
    await pc.setRemoteDescription({ type: "offer", sdp: offer });
    const local = await pc.createAnswer();
    await pc.setLocalDescription(local);
    await new Promise((resolve) => {
      if (pc.iceGatheringState === "complete") return resolve();
      const timer = setTimeout(resolve, 800);
      pc.addEventListener("icegatheringstatechange", () => {
        if (pc.iceGatheringState === "complete") { clearTimeout(timer); resolve(); }
      });
    });
    return pc.localDescription.sdp;
  }, job.offer);
  job.resolve(answer);
}

function pageUrl(token, self, peer, stamp) {
  const q = new URLSearchParams({ t: token, root, kind: "open", self, retry: "1000", mintRoot: root });
  if (peer) q.append("peer", peer);
  return `${pageOrigin}/page/room.html?case=${stamp}#${q}`;
}

const context = await browser.newContext();
await context.addInitScript(() => {
  const orig = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  window.__gum = 0;
  navigator.mediaDevices.getUserMedia = async (c) => { window.__gum += 1; return orig(c); };
  const play = HTMLMediaElement.prototype.play;
  window.__playRejects = 0;
  HTMLMediaElement.prototype.play = function (...args) {
    if (!this.muted && !window.__allowRemote) {
      window.__playRejects += 1;
      return Promise.reject(new Error("autoplay denied"));
    }
    return play.apply(this, args);
  };
});
const aux = await context.newPage();
await aux.goto(`${pageOrigin}/page/room.html?case=aux`);
const page = await context.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));

const out = { errors };
await page.goto(pageUrl("expired", "alice/cam", "bob/cam", "expired"));
await page.click("#join");
await page.waitForTimeout(300);
out.expired = await page.evaluate(() => ({
  status: document.querySelector("#status").textContent,
  gum: window.__gum,
  hash: location.hash,
  notice: document.querySelector("#notice").textContent,
}));

whepTries = 0;
await page.goto(pageUrl("alice", "alice/cam", "bob/cam", "join"));
page.on("console", (msg) => errors.push(`console ${msg.type()}: ${msg.text()}`));
const joining = page.click("#join");
await page.waitForTimeout(1000);
out.midJoin = await page.evaluate(() => ({
  status: document.querySelector("#status").textContent,
  gum: window.__gum,
  href: location.href,
  origin: window.MJOLNIR_ROOM_ORIGIN,
}));
out.midTrace = trace.map((item) => item.path);
try {
  await answerNext(aux);
  await joining;
} catch (error) {
  out.fail = String(error);
  console.log(JSON.stringify(out, null, 2));
  await browser.close();
  server.close();
  pages.close();
  process.exit(1);
}
out.afterJoin = await page.evaluate(() => ({
  status: document.querySelector("#status").textContent,
  gum: window.__gum,
  tile: document.querySelector(".tile p")?.textContent || "",
  sessions: window.roomClient.status().sessions,
}));
const retry = answerNext(aux);
await page.waitForFunction(() => {
  const text = document.querySelector(".tile p")?.textContent || "";
  return text.includes("Waiting") || text.includes("Playback") || text.includes("Playing");
});
await retry;
await page.waitForFunction(() => document.querySelector("#status").textContent === "In the room.");
out.afterRetry = await page.evaluate(() => ({
  status: document.querySelector("#status").textContent,
  tile: document.querySelector(".tile p")?.textContent || "",
  width: document.querySelector(".tile video")?.videoWidth || 0,
  sessions: window.roomClient.status().sessions,
}));

const replacing = page.click("#replace");
await answerNext(aux);
await answerNext(aux);
await replacing;
await page.waitForFunction(() => document.querySelector("#resume").hidden === false || (document.querySelector(".tile p")?.textContent || "").includes("Playback"));
out.afterReplace = await page.evaluate(() => ({
  status: document.querySelector("#status").textContent,
  tile: document.querySelector(".tile p")?.textContent || "",
  resume: document.querySelector("#resume").hidden,
  sessions: window.roomClient.status().sessions,
  gum: window.__gum,
}));
await page.evaluate(() => { window.__allowRemote = true; });
await page.click("#resume");
await page.waitForFunction(() => (document.querySelector(".tile p")?.textContent || "") === "Playing.");
out.afterResume = await page.evaluate(() => ({
  tile: document.querySelector(".tile p").textContent,
  rejects: window.__playRejects,
}));

const beforeRenew = out.afterReplace.sessions.slice();
await page.fill("#renew-token", "bob");
await page.click("#renew");
await page.waitForTimeout(400);
out.badRenew = await page.evaluate(() => ({
  status: document.querySelector("#status").textContent,
  sessions: window.roomClient.status().sessions,
  gum: window.__gum,
  field: document.querySelector("#renew-token").value,
}));
out.badRenew.sessionsUnchanged = JSON.stringify(out.badRenew.sessions) === JSON.stringify(beforeRenew);

hangDelete = true;
const beforeLeave = Date.now();
const leaving = page.click("#leave");
await page.waitForFunction(() => document.querySelector("#local-video").srcObject == null);
out.leaveClearedMs = Date.now() - beforeLeave;
out.leaveImmediate = await page.evaluate(() => ({
  status: document.querySelector("#status").textContent,
  local: document.querySelector("#local-video").srcObject,
  tiles: document.querySelectorAll(".tile").length,
}));
await page.waitForFunction(() => document.querySelector("#status").textContent !== "Leaving…", { timeout: 5000 });
out.leaveFinal = await page.evaluate(() => document.querySelector("#status").textContent);
out.hungDeletes = trace.filter((item) => item.method === "DELETE" && item.status == null).map((item) => item.path);
out.trace = trace.map(({ method, path, status, operation, broadcast, location, auth }) => ({ method, path, status, operation, broadcast, location, auth }));
out.pageErrors = errors;
await browser.close();
server.close();
pages.close();
console.log(JSON.stringify(out, null, 2));

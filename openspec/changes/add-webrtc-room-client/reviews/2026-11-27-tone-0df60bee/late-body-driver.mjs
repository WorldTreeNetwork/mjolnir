import { chromium } from "playwright";
import fs from "node:fs";

const P = process.env.P;
const root = fs.readFileSync(`${P}/alice.meta`, "utf8").trim().split("\n")[0];
const alice = fs.readFileSync(`${P}/alice.tok`, "utf8").trim();
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
  window.__hook = "labeled init: hold the next WHIP 201 body until __releaseBody";
  window.__holdNext = false;
  window.__held = false;
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
const errors = [];
const alicePage = await context.newPage();
const bobPage = await context.newPage();
alicePage.on("pageerror", (error) => errors.push(`alice ${error.message}`));
bobPage.on("pageerror", (error) => errors.push(`bob ${error.message}`));
await alicePage.goto(url(alice, "alice/cam", "bob/cam"));
await bobPage.goto(url(bob, "bob/cam", "alice/cam"));
await alicePage.click("#join");
await bobPage.click("#join");
const start = Date.now();
let joined = false;
while (Date.now() - start < 30000) {
  joined = await bobPage.evaluate(() => {
    const video = document.querySelector('[data-path="alice/cam"] video');
    return !!(video && video.videoWidth > 0);
  });
  if (joined) break;
  await bobPage.waitForTimeout(200);
}
await alicePage.evaluate(() => { window.__holdNext = true; });
await alicePage.click("#replace");
const heldAt = Date.now();
let during = null;
while (Date.now() - heldAt < 8000) {
  during = await alicePage.evaluate(() => ({
    status: document.querySelector("#status")?.textContent || "",
    held: !!window.__held,
    hook: window.__hook,
  }));
  if (during.held) break;
  await alicePage.waitForTimeout(100);
}
const bobDuring = await bobPage.evaluate(() => {
  const tile = document.querySelector('[data-path="alice/cam"]');
  const video = tile && tile.querySelector("video");
  return {
    owner: tile ? tile.dataset.owner || "" : "",
    caption: tile ? tile.querySelector("p")?.textContent || "" : "",
    srcObject: !!(video && video.srcObject),
    width: video ? video.videoWidth : 0,
  };
});
await alicePage.click("#leave");
await alicePage.waitForTimeout(400);
const leaveWhileHeld = await alicePage.evaluate(() => ({
  status: document.querySelector("#status")?.textContent || "",
  tiles: document.querySelectorAll(".tile").length,
  local: !!document.querySelector("#local-video").srcObject,
  captions: [...document.querySelectorAll(".tile p")].map((node) => node.textContent),
  held: !!window.__held,
  released: !!window.__released,
}));
await alicePage.evaluate(() => { if (window.__releaseBody) window.__releaseBody(); });
await alicePage.waitForTimeout(1200);
const after = await alicePage.evaluate(() => ({
  status: document.querySelector("#status")?.textContent || "",
  tiles: document.querySelectorAll(".tile").length,
  local: !!document.querySelector("#local-video").srcObject,
  captions: [...document.querySelectorAll(".tile p")].map((node) => node.textContent),
  released: !!window.__released,
}));
const out = { joined, during, bobDuring, leaveWhileHeld, after, errors, hook: "init-script holds WHIP 201 body" };
fs.writeFileSync(`${P}/evidence/late-body.json`, JSON.stringify(out, null, 2));
console.log(JSON.stringify(out));
await browser.close();

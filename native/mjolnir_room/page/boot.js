import { createRoom } from "../src/room.js";

const status = document.querySelector("#status");
const peers = document.querySelector("#peers");
const localVideo = document.querySelector("#local-video");
const resume = document.querySelector("#resume");
const origin = window.MJOLNIR_ROOM_ORIGIN || "";

const COPY = {
  no_token: "A token is required before the camera can open.",
  bad_token: "This token is not valid.",
  forbidden: "This token cannot publish that path.",
  room_not_open: "This room is not open.",
  unexpected_root: "The room root does not match this invitation.",
  setup_failed: "The room could not be connected.",
  cleanup_timeout: "Left the room. The server has not confirmed cleanup.",
  stale: "That attempt is no longer current.",
  gateway_not_configured: "This page has no gateway configured.",
};

function readFragment() {
  const params = new URLSearchParams(location.hash.replace(/^#/, ""));
  const token = params.get("t") || "";
  const expectedRoot = params.get("root") || "";
  const kind = params.get("kind") || undefined;
  const selfPath = params.get("self") || "";
  const peerPaths = params.getAll("peer");
  const retryMs = Number(params.get("retry") || "1000");
  const mintRoot = params.get("mintRoot") || expectedRoot;
  history.replaceState(null, "", location.pathname + location.search);
  return { token, root: mintRoot, kind, expectedRoot, selfPath, peerPaths, retryMs };
}

const fragment = readFragment();
const invite = Object.freeze({ ...fragment, peerPaths: Object.freeze(fragment.peerPaths.slice()) });
let renewal = null;
let actionId = 0;
let shownGeneration = 0;
const playback = new Map();

function say(text) {
  status.textContent = text || "";
}

function registered(path, node, video, owner, stream) {
  return peers.querySelector(`[data-path="${CSS.escape(path)}"]`) === node
    && node.querySelector("video") === video && video.dataset.owner === owner
    && video.srcObject === stream && !!owner;
}

function retireView(node) {
  const video = node.querySelector("video");
  node.dataset.owner = "";
  video.dataset.owner = "";
  video.dataset.blocked = "";
  video.srcObject = null;
  playback.delete(video);
}

function playView(path, node, video) {
  const owner = video.dataset.owner;
  const stream = video.srcObject;
  const revision = (playback.get(video) || 0) + 1;
  playback.set(video, revision);
  const current = () => registered(path, node, video, owner, stream)
    && playback.get(video) === revision;
  video.play().then(() => {
    if (!current()) return;
    video.dataset.blocked = "";
    setCaption(path, "Playing.");
    refreshResume();
  }).catch(() => {
    if (!current()) return;
    video.dataset.blocked = "1";
    setCaption(path, "Playback is blocked. Use Play media.");
    refreshResume();
  });
}

function tile(path) {
  let node = peers.querySelector(`[data-path="${CSS.escape(path)}"]`);
  if (node) return node;
  node = document.createElement("div");
  node.className = "tile";
  node.dataset.path = path;
  node.dataset.attempt = "";
  node.innerHTML = `<h2></h2><video autoplay playsinline></video><p></p>`;
  node.querySelector("h2").textContent = path;
  const video = node.querySelector("video");
  const current = () => registered(path, node, video, video.dataset.owner, video.srcObject);
  video.addEventListener("playing", () => { if (current() && video.dataset.blocked !== "1") setCaption(path, "Playing."); });
  video.addEventListener("waiting", () => {
    if (!current() || video.dataset.blocked === "1") return;
    setCaption(path, "Waiting — the other side must publish again.");
  });
  video.addEventListener("ended", () => { if (current()) setCaption(path, "Waiting — the other side must publish again."); });
  peers.append(node);
  return node;
}

function setCaption(path, text) {
  const node = peers.querySelector(`[data-path="${CSS.escape(path)}"]`);
  if (node) node.querySelector("p").textContent = text;
}

function mintFromInvite(token) {
  return {
    token,
    root: invite.root,
    kind: invite.kind,
    expectedRoot: invite.expectedRoot,
    selfPath: invite.selfPath,
    peerPaths: invite.peerPaths.slice(),
    retryMs: invite.retryMs,
  };
}

function explain(error) {
  return COPY[error] || "The room could not be connected.";
}

const room = origin
  ? createRoom({
      origin,
      fetch,
      getUserMedia: (constraints) => navigator.mediaDevices.getUserMedia(constraints),
      createPeerConnection: () => new RTCPeerConnection(),
      onBeforeCamera() {
        if (!document.querySelector("#notice").textContent.includes("host can read")) {
          throw new Error("notice missing");
        }
      },
      onLocal(stream, generation) {
        if (!stream) {
          if (shownGeneration === generation) {
            localVideo.srcObject = null;
            shownGeneration = 0;
          }
          return;
        }
        shownGeneration = generation;
        localVideo.srcObject = stream;
      },
      onRemoteTrack(path, attempt, event, generation) {
        const node = tile(path);
        const video = node.querySelector("video");
        const owner = generation == null ? `a:${attempt}` : `${generation}:${attempt}`;
        if (node.dataset.owner !== owner) {
          node.dataset.owner = owner;
          node.dataset.attempt = String(attempt);
          video.dataset.owner = owner;
          video.srcObject = new MediaStream();
          video.dataset.blocked = "";
        }
        const stream = video.srcObject;
        for (const track of stream.getTracks()) {
          if (track.readyState === "ended" || track.kind === event.track.kind) stream.removeTrack(track);
        }
        stream.addTrack(event.track);
        playView(path, node, video);
      },
      onUpdate() { paint(); },
    })
  : null;

function refreshResume() {
  if (!resume) return;
  const blocked = [...peers.querySelectorAll("video")].some((video) => video.dataset.blocked === "1");
  resume.hidden = !blocked;
}

function paint() {
  if (!room) return;
  const live = room.status();
  if (Object.prototype.hasOwnProperty.call(live, "incumbent") && !live.incumbent && !live.candidate) {
    for (const node of peers.querySelectorAll(".tile")) retireView(node);
    peers.replaceChildren();
    if (shownGeneration) {
      localVideo.srcObject = null;
      shownGeneration = 0;
    }
    say(COPY.bad_token);
    refreshResume();
    return;
  }
  for (const node of peers.querySelectorAll(".tile")) {
    const peer = (live.peers || {})[node.dataset.path];
    const expected = peer && `${live.incumbent}:${peer.attempt}`;
    if (node.dataset.owner && (node.dataset.owner !== expected || (!peer?.inflight && (peer?.failed || peer?.empty)))) {
      retireView(node);
      node.querySelector("p").textContent = "Waiting — the other side must publish again.";
    }
  }
  refreshResume();
  for (const [path, peer] of Object.entries(live.peers || {})) {
    const node = tile(path);
    const video = node.querySelector("video");
    if (peer.failed) {
      node.querySelector("p").textContent = explain(peer.error);
      continue;
    }
    if (video && video.dataset.blocked === "1") continue;
    if (peer.empty || !video || !video.srcObject || video.srcObject.getTracks().length === 0) {
      node.querySelector("p").textContent = "Waiting — the other side must publish again.";
    }
  }

}

async function run(action) {
  if (!room) {
    say(COPY.gateway_not_configured);
    return;
  }
  const id = ++actionId;
  const field = document.querySelector("#renew-token");
  const token = action === "renew" ? (renewal || field.value) : invite.token;
  if (action === "renew") {
    field.value = "";
    renewal = null;
  }
  say(action === "replace" || action === "renew" ? "Replacing the connection…" : "Joining…");
  let result;
  try {
    result = await room[action](mintFromInvite(token));
  } catch {
    if (id === actionId) say("That action did not finish.");
    return;
  }
  if (id !== actionId) return;
  paint();
  if (id !== actionId) return;
  say(result.ok ? "In the room." : explain(result.error));
}

function clearViews() {
  localVideo.srcObject = null;
  shownGeneration = 0;
  if (resume) resume.hidden = true;
  for (const node of peers.querySelectorAll(".tile")) retireView(node);
  peers.replaceChildren();
}

document.querySelector("#join").addEventListener("click", () => run("join"));
document.querySelector("#replace").addEventListener("click", () => run("replace"));
document.querySelector("#renew").addEventListener("click", () => run("renew"));
document.querySelector("#leave").addEventListener("click", async () => {
  const id = ++actionId;
  clearViews();
  say("Leaving…");
  if (!room) return;
  let result = { ok: true };
  try { result = await room.teardown(); } catch { result = { ok: false, error: "setup_failed" }; }
  if (id !== actionId) return;
  say(result && result.ok === false ? explain(result.error) : "Left the room.");
});
if (resume) resume.addEventListener("click", () => {
  for (const video of peers.querySelectorAll("video")) {
    const node = video.closest(".tile");
    playView(node.dataset.path, node, video);
  }
});

window.roomClient = {
  join: () => run("join"),
  replace: () => run("replace"),
  renew: (token) => {
    renewal = token;
    return run("renew");
  },
  leave: () => document.querySelector("#leave").click(),
  status: () => (room ? room.status() : { error: "gateway_not_configured" }),
  setRenewal: (token) => { renewal = token; },
};

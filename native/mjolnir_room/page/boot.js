import { createRoom } from "../src/room.js";

const status = document.querySelector("#status");
const peers = document.querySelector("#peers");
const localVideo = document.querySelector("#local-video");
const origin = window.MJOLNIR_ROOM_ORIGIN || "";

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

const invite = readFragment();
let renewal = null;

function say(error) {
  status.textContent = error ? String(error) : "in the room";
}

function tile(path) {
  let node = peers.querySelector(`[data-path="${CSS.escape(path)}"]`);
  if (node) return node;
  node = document.createElement("div");
  node.className = "tile";
  node.dataset.path = path;
  node.innerHTML = `<h2></h2><video autoplay playsinline></video><p></p>`;
  node.querySelector("h2").textContent = path;
  peers.append(node);
  return node;
}

const room = origin
  ? createRoom({
      origin,
      fetch,
      getUserMedia: (c) => navigator.mediaDevices.getUserMedia(c),
      createPeerConnection: () => new RTCPeerConnection(),
      onBeforeCamera() {
        if (!document.querySelector("#notice").textContent.includes("host can read")) {
          throw new Error("notice missing");
        }
      },
      ontrack(path, event) {
        const video = tile(path).querySelector("video");
        const stream = video.srcObject instanceof MediaStream ? video.srcObject : new MediaStream();
        if (!stream.getTracks().some((track) => track.id === event.track.id)) stream.addTrack(event.track);
        video.srcObject = stream;
        video.play().catch(() => {});
      },
    })
  : null;

function mintFromInvite(token) {
  return {
    token,
    root: invite.root,
    kind: invite.kind,
    expectedRoot: invite.expectedRoot,
    selfPath: invite.selfPath,
    peerPaths: invite.peerPaths,
    retryMs: invite.retryMs,
  };
}

async function run(action) {
  if (!room) {
    say("gateway_not_configured");
    return;
  }
  const token = action === "renew" ? (renewal || document.querySelector("#renew-token").value) : invite.token;
  const result = await room[action](mintFromInvite(token));
  say(result.ok ? "" : result.error);
  const live = room.status();
  if (live.tracks && localVideo.srcObject == null) {
    /* local preview is attached by the module only through tracks the page owns via gum;
       show them from the peer connection sender when present */
  }
  paint(live);
}

function paint(live) {
  for (const [path, peer] of Object.entries(live.peers || {})) {
    const node = tile(path);
    node.querySelector("p").textContent = peer.failed
      ? peer.error
      : peer.empty
        ? "waiting — the other side must publish again"
        : "playing";
  }
}

document.querySelector("#join").addEventListener("click", () => run("join"));
document.querySelector("#replace").addEventListener("click", () => run("replace"));
document.querySelector("#renew").addEventListener("click", () => run("renew"));
document.querySelector("#leave").addEventListener("click", async () => {
  if (room) await room.teardown();
  localVideo.srcObject = null;
  say("left");
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

if (invite.token && room) {
  const preview = new MediaStream();
  const orig = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  navigator.mediaDevices.getUserMedia = async (constraints) => {
    const stream = await orig(constraints);
    localVideo.srcObject = stream;
    return stream;
  };
  void preview;
}

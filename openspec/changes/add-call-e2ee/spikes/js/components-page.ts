// Spike e2ee-js, component half: unmodified @moq/publish and @moq/watch over @moq/e2ee.
// Not product code. No patch to watch or publish: each component gets a plaintext, never-connected
// local Origin, and a bridge (bridge.ts) re-encrypts / decrypts between it and the relay origin.
//
//   role=cpub secret relay hash     camera -> Publish.Broadcast -> local origin -> encrypt bridge -> relay
//   role=csub secret relay hash epoch   relay -> decrypt bridge -> local origin -> Watch.Player -> <canvas>
import { Connection, Origin, Path } from "@moq/net";
import * as Publish from "../../publish/src/index.ts";
import * as Watch from "../../watch/src/index.ts";
import { Credential, Epoch } from "@moq/e2ee";
import { decryptBridge, encryptBridge } from "./bridge.ts";

const q = new URLSearchParams(location.search);
const out: string[] = [];
(window as any).spikeLog = out;
(window as any).spikeDone = false;
function log(line: string) {
	const s = `spike e2ee-js [${q.get("role")}]: ${line}`;
	out.push(s);
	console.log(s);
}
const enc = new TextEncoder();
const hex = (h: string) => Uint8Array.from(h.match(/../g)!.map((b) => parseInt(b, 16)));
const cred = new Credential({ context: enc.encode("spike/meeting-123"), kid: 1, secret: hex(q.get("secret")!) });
const LOCAL = Path.from("local/me.hang");

async function connect(o: { publish?: Origin.Producer; consume?: Origin.Producer }) {
	const s = await Connection.connect({
		url: new URL(q.get("relay")!),
		webtransport: { serverCertificateHashes: [{ value: q.get("hash")! }] },
		websocket: { enabled: false },
		publish: o.publish?.consume(),
		consume: o.consume,
	});
	log(`connected transport=${s.transport} version=${s.version}`);
}

async function cpub() {
	const relay = new Origin.Producer();
	await connect({ publish: relay });
	const local = new Origin.Producer(); // plaintext; no session ever serves it

	// The README's publish example, unchanged except for the origin.
	const camera = new Publish.Source.Camera({ enabled: true });
	const video = new Publish.Signals.Computed((effect) => effect.get(camera.out.source)?.video);
	const capture = new Publish.Video.Capture({ source: video, orientation: camera.out.orientation });
	const broadcast = new Publish.Broadcast({
		origin: local,
		enabled: true,
		name: LOCAL,
		display: capture.out.display,
		rotation: capture.out.rotation,
	});
	new Publish.Video.Encoder("video/hd", { broadcast, capture, enabled: true });

	const generation = cred.produce();
	const path = await cred.path("meeting.hang");
	const info = await encryptBridge({ local, localPath: LOCAL, relay, path, generation, log });
	(window as any).spikeInfo = { path, epoch: generation.epoch, ...info };
	(window as any).spikeDone = true;
}

async function csub() {
	const relay = new Origin.Producer();
	await connect({ consume: relay });
	const local = new Origin.Producer();
	const path = await cred.path("meeting.hang");
	const { remote } = await decryptBridge({
		relay,
		path,
		credential: cred,
		appEpoch: (r) => Epoch.of(r) ?? Epoch.parse(q.get("epoch")!),
		local,
		localPath: LOCAL,
		log,
	});
	log(`relay instance=${String(remote.instance)} Epoch.of=${Epoch.of(remote) ?? "undefined"}`);

	const canvas = document.createElement("canvas");
	document.body.appendChild(canvas);
	// The README's headless player, unchanged except for the origin.
	const player = new Watch.Player({
		origin: local,
		name: LOCAL,
		video: { canvas, backend: "2d" },
		audio: { muted: true },
	});
	(window as any).player = player;
	const ctx = canvas.getContext("2d")!;
	const sample = () => {
		if (canvas.width === 0 || canvas.height === 0) return undefined;
		const d = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
		let sum = 0;
		let nonzero = 0;
		for (let i = 0; i < d.length; i += 4) {
			sum = (sum + d[i] * 3 + d[i + 1] * 5 + d[i + 2] * 7) % 1_000_000_007;
			if (d[i] | d[i + 1] | d[i + 2]) nonzero++;
		}
		return { w: canvas.width, h: canvas.height, nonzero, sum };
	};
	let first: ReturnType<typeof sample>;
	for (let i = 0; i < 60; i++) {
		await new Promise((r) => setTimeout(r, 250));
		const s = sample();
		if (s && s.nonzero > 0) {
			if (!first) {
				first = s;
				log(`canvas painted ${s.w}x${s.h} nonzero_px=${s.nonzero} checksum=${s.sum}`);
			} else if (s.sum !== first.sum) {
				log(`canvas changed ${s.w}x${s.h} nonzero_px=${s.nonzero} checksum=${s.sum}`);
				log("RESULT csub rendered=true");
				(window as any).spikeDone = true;
				return;
			}
		}
	}
	log(`RESULT csub rendered=false last=${JSON.stringify(sample())}`);
	(window as any).spikeDone = true;
}

({ cpub, csub })[q.get("role") as "cpub" | "csub"]().catch((e) => {
	log(`ERROR ${e?.name}: ${e?.message}\n${e?.stack}`);
	(window as any).spikeDone = true;
});

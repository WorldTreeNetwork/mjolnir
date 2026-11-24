// Spike e2ee-js (mjolnir-rurh.9): @moq/e2ee over a real moq-relay via WebTransport, in a browser.
// Not product code. Built by run.sh (Bun frame-only bundle) inside the moq copy so the workspace packages resolve.
//
// Query params:
//   role=pub   secret=<hex32> relay=<url> hash=<hex>            publishes a protected broadcast
//   role=sub   secret=<hex32> relay=<url> hash=<hex> epoch=<e>    decrypts it (epoch = the app channel)
//   role=eve   relay=<url> hash=<hex> path=<p> video=<physical> epoch=<e> wrong=<hex32>
//              no credential: reads the raw physical track, then tries a wrong secret
//   versions=<comma list>  optional; omitted = @moq/net's default version list
import { Connection, Origin, Path, Time } from "@moq/net";
import { Duration } from "@moq/clock";
import { Broadcast, Credential, Epoch } from "@moq/e2ee";

const q = new URLSearchParams(location.search);
const out: string[] = [];
(window as any).spikeLog = out;
function log(line: string) {
	const s = `spike e2ee-js [${q.get("role")}]: ${line}`;
	out.push(s);
	console.log(s);
	document.body.textContent = out.join("\n");
}
(window as any).spikeDone = false;

const enc = new TextEncoder();
const dec = new TextDecoder();
const hex = (h: string) => Uint8Array.from(h.match(/../g)!.map((b) => parseInt(b, 16)));
const MARKER = "PLAINTEXT-MARKER";

function credential(secretHex: string) {
	return new Credential({ context: enc.encode("spike/meeting-123"), kid: 1, secret: hex(secretHex) });
}

async function connect(origin: { publish?: Origin.Producer; consume?: Origin.Producer }) {
	const versions = q.get("versions")?.split(",");
	const session = await Connection.connect({
		url: new URL(q.get("relay")!),
		versions,
		webtransport: { serverCertificateHashes: [{ value: q.get("hash")! }] },
		websocket: { enabled: false },
		publish: origin.publish?.consume(),
		consume: origin.consume,
	});
	log(`connected transport=${session.transport} version=${session.version} offered=${versions ? versions.join(",") : "(default)"}`);
	log(`userAgent=${navigator.userAgent}`);
	return session;
}

async function active(origin: Origin.Producer, path: Path.Valid) {
	const request = origin.follow(path);
	for (;;) {
		const front = request.active.peek();
		if (front) return front;
		await request.active.changed();
	}
}

async function pub() {
	const origin = new Origin.Producer();
	await connect({ publish: origin });
	const cred = credential(q.get("secret")!);
	const generation = cred.produce();
	const path = await cred.path("meeting.hang");
	const route = origin.route(path, { hidden: true, instance: { id: Epoch.instance(generation.epoch), epoch: 0n } });
	const bc = new Broadcast.Producer(route.broadcast, generation);
	const catalog = await bc.createTrack("catalog.json", { timescale: Time.Timescale.MILLI });
	const video = await bc.createTrack("video", { timescale: Time.Timescale.MILLI });
	route.announce();
	log(`path=${path}`);
	log(`epoch=${generation.epoch}`);
	log(`physical catalog.json=${catalog.name}`);
	log(`physical video=${video.name}`);
	(window as any).spikeInfo = { path, epoch: generation.epoch, catalog: catalog.name, video: video.name };

	let n = 0;
	const t0 = Time.Timestamp.now();
	const cg = catalog.appendGroup(t0);
	await cg.writeFrame(t0, enc.encode(JSON.stringify({ display: "Alice", video: { track: "video" }, marker: `${MARKER}-catalog` })));
	cg.finish();
	(window as any).spikeDone = true;
	for (;;) {
		const now = Time.Timestamp.now();
		const g = video.appendGroup(now);
		await g.writeFrame(now, enc.encode(`${MARKER}-video-${n++}`));
		g.finish();
		await new Promise((r) => setTimeout(r, 150));
	}
}

async function sub() {
	const origin = new Origin.Producer();
	await connect({ consume: origin });
	const cred = credential(q.get("secret")!);
	const path = await cred.path("meeting.hang");
	const remote = await active(origin, path);
	const routed = Epoch.of(remote);
	log(`resolved path=${path} instance=${String(remote.instance)} Epoch.of=${routed ?? "undefined"}`);
	const epoch = routed ?? Epoch.parse(q.get("epoch")!);
	log(`using epoch=${epoch} (source=${routed ? "route instance" : "app channel"})`);
	const bc = new Broadcast.Consumer(remote, cred.consume(epoch));
	const sub = { delay: { max: Duration.millis(60_000) } };
	const catalog = await bc.subscribe("catalog.json", sub);
	const cg = await catalog.recvGroup();
	const cf = await cg?.readFrame();
	log(`decrypted catalog.json = ${dec.decode(cf?.plaintext)}`);
	const video = await bc.subscribe("video", sub);
	for (let i = 0; i < 3; i++) {
		const g = await video.recvGroup();
		const f = await g?.readFrame();
		log(`decrypted video group start=${g?.start} = "${dec.decode(f?.plaintext)}"`);
	}
	log("RESULT sub decrypted=true");
	(window as any).spikeDone = true;
}

async function eve() {
	const origin = new Origin.Producer();
	await connect({ consume: origin });
	// A relay (or anyone it serves) sees the physical path and physical track names.
	const path = Path.from(q.get("path")!);
	const remote = await active(origin, path);
	const raw = remote.track(q.get("video")!).subscribe({ delay: { max: Duration.millis(60_000) } });
	let leaked = false;
	for (let i = 0; i < 3; i++) {
		const g = await raw.recvGroup();
		const f = await g?.readFrame();
		const bytes = f?.payload ?? new Uint8Array();
		const asText = dec.decode(bytes);
		if (asText.includes(MARKER)) leaked = true;
		log(`no-credential raw video frame ${i}: ${bytes.byteLength} bytes, marker present=${asText.includes(MARKER)}, head=${[...bytes.slice(0, 8)].map((b) => b.toString(16).padStart(2, "0")).join("")}`);
	}
	raw.close();

	// Wrong secret, correct epoch, on the real broadcast: the derived physical name differs.
	const wrong = credential(q.get("wrong")!);
	log(`wrong-secret path=${await wrong.path("meeting.hang")} (real path=${path})`);
	const bc = new Broadcast.Consumer(remote, wrong.consume(Epoch.parse(q.get("epoch")!)));
	try {
		const t = await bc.subscribe("video", { delay: { max: Duration.millis(60_000) } });
		const g = await Promise.race([t.recvGroup(), new Promise((_, rej) => setTimeout(() => rej(new Error("timeout 4s, no group")), 4000))]);
		const f = await (g as any)?.readFrame();
		const s = dec.decode(f?.plaintext);
		if (s.includes(MARKER)) leaked = true;
		log(`wrong-secret video read -> "${s}"`);
	} catch (e) {
		log(`wrong-secret subscribe "video" -> ${(e as Error)?.name}: ${(e as Error)?.message}`);
	}
	log(`RESULT eve plaintext_leaked=${leaked}`);
	(window as any).spikeDone = true;
}

const roles: Record<string, () => Promise<void>> = { pub, sub, eve };
roles[q.get("role")!]().catch((e) => {
	log(`ERROR ${e?.name}: ${e?.message}\n${e?.stack}`);
	(window as any).spikeDone = true;
});

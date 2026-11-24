// Spike e2ee-js: a bridge between a plaintext local origin (what @moq/publish and @moq/watch use,
// unmodified) and an @moq/e2ee protected broadcast on the relay origin. Not product code.
//
// Encrypt side: follows the local broadcast, mirrors every listed track of groups through
// Broadcast.Producer under its semantic name, and writes a protected "bridge.tracks" manifest
// (semantic name + track info) because a subscriber cannot list opaque physical names.
// Decrypt side: reads the manifest, subscribes each track through Broadcast.Consumer, and writes
// the plaintext into a local broadcast that the watch component follows.
import { Duration } from "@moq/clock";
import {
	type Broadcast as NetBroadcast,
	type Group as NetGroup,
	type Origin,
	type Path,
	Time,
	type Track as NetTrack,
} from "@moq/net";
import { Broadcast, type Credential, Epoch, type Generation, type Group, type Track } from "@moq/e2ee";

type Log = (line: string) => void;
type Meta = { timescale: number | null; maxAgeMs: number | null; priority: number };
const MANIFEST = "bridge.tracks";
const SUB = { delay: { max: Duration.millis(60_000) } };
const enc = new TextEncoder();
const dec = new TextDecoder();

async function active(origin: Origin.Producer, path: Path.Valid): Promise<NetBroadcast.Consumer> {
	const request = origin.follow(path);
	for (;;) {
		const front = request.active.peek();
		if (front) return front;
		await request.active.changed();
	}
}

const init = (m: Meta): NetTrack.InfoInit => ({
	timescale: m.timescale as Time.Timescale | null,
	maxAge: m.maxAgeMs === null ? null : Duration.millis(m.maxAgeMs),
	priority: m.priority,
});

export async function encryptBridge(o: {
	local: Origin.Producer;
	localPath: Path.Valid;
	relay: Origin.Producer;
	path: Path.Valid;
	generation: Generation.Producer;
	log: Log;
}) {
	const plain = await active(o.local, o.localPath);
	const route = o.relay.route(o.path, {
		hidden: true,
		instance: { id: Epoch.instance(o.generation.epoch), epoch: 0n },
	});
	const bc = new Broadcast.Producer(route.broadcast, o.generation);
	const manifest = await bc.createTrack(MANIFEST, { timescale: Time.Timescale.MILLI });
	route.announce();
	const tracks: Track.Producer[] = [manifest];
 const known: Record<string, Meta> = {};
	const physical: Record<string, string> = {};
	let ready: () => void;
	const seen = new Promise<void>((r) => (ready = r));
	void (async () => {
		for await (const ev of plain.tracks()) {
			if (ev.kind !== "added" || ev.datagrams) continue;
			// A name can be listed again (the local track was replaced). A JS generation refuses to create a
			// name twice, so keep the existing protected track instead of letting the listing loop die.
			if (physical[ev.name]) { o.log(`encrypt bridge: "${ev.name}" listed again; keeping ${physical[ev.name]}`); continue; }
			const meta = { timescale: ev.info.timescale, maxAgeMs: ev.info.maxAge?.asMillis() ?? null, priority: ev.info.priority };
			const track = await bc.createTrack(ev.name, init(meta));
			tracks.push(track);
 known[ev.name] = meta;
			physical[ev.name] = track.name;
			o.log(`encrypt bridge: track "${ev.name}" -> physical ${track.name} ${JSON.stringify(meta)}`);
			const now = Time.Timestamp.now();
			const g = manifest.appendGroup(now);
			await g.writeFrame(now, enc.encode(JSON.stringify(known)));
			g.finish();
			void pumpEncrypt(plain.track(ev.name).subscribe(SUB), track, ev.name, o.log);
			if (Object.keys(known).some((n) => n !== "catalog.json") && known["catalog.json"]) ready();
		}
	})().catch((e) => o.log(`encrypt bridge listing error ${e}`));
	await seen;
	// Republish the manifest every second: a reader that joined on an older snapshot (latest-group delivery
	// can skip groups) converges without depending on the next track change.
	const refresh = setInterval(() => { try { const now = Time.Timestamp.now(); const g = manifest.appendGroup(now); void g.writeFrame(now, enc.encode(JSON.stringify(known))).then(() => g.finish()); } catch {} }, 1000);
	return { physical, retire: () => { clearInterval(refresh); for (const track of tracks) track.finish(); route.broadcast.close(); route.withdraw(); } };
}

async function pumpEncrypt(sub: NetTrack.Subscriber, out: Track.Producer, name: string, log: Log) {
	let groups = 0;
 let newest = -1;
	for (;;) {
		const g = await sub.recvGroup();
		if (!g) break;
 if (g.start <= newest) continue; newest = g.start;
		let eg: Group.Producer;
		try {
			eg = out.createGroup(g.start);
		} catch (e) {
			log(`encrypt bridge: ${name} skip group ${g.start}: ${e}`);
			continue;
		}
		if (groups++ < 2) log(`encrypt bridge: ${name} group ${g.start}`);
		void (async () => {
			for (let f = await g.readFrame(); f; f = await g.readFrame()) await eg.writeFrame(f.timestamp, f.payload);
			eg.finish();
		})().catch((e) => log(`encrypt bridge: ${name} group error ${e}`));
	}
}

export async function decryptBridge(o: {
	relay: Origin.Producer;
	path: Path.Valid;
	credential: Credential;
	appEpoch: (remote: NetBroadcast.Consumer) => Epoch.Valid;
	local: Origin.Producer;
	localPath: Path.Valid;
	log: Log;
}) {
	const remote = await active(o.relay, o.path);
	const bc = new Broadcast.Consumer(remote, o.credential.consume(o.appEpoch(remote)));
	const route = o.local.route(o.localPath, { hidden: true });
	const mirror = route.broadcast;
	const manifest = await bc.subscribe(MANIFEST, SUB);
	const made = new Set<string>();
	let announced = false;
	void (async () => {
		for (let g = await manifest.recvGroup(); g; g = await manifest.recvGroup()) {
			const f = await g.readFrame();
			const known: Record<string, Meta> = JSON.parse(dec.decode(f?.plaintext));
			for (const [name, meta] of Object.entries(known)) {
				if (made.has(name)) continue;
				made.add(name);
				const local = mirror.createTrack(name, init(meta));
				o.log(`decrypt bridge: track "${name}" ${JSON.stringify(meta)}`);
				void pumpDecrypt(await bc.subscribe(name, SUB), local, name, o.log);
			}
			if (!announced && made.has("catalog.json")) {
				announced = true;
				route.announce();
			}
		}
	})().catch((e) => o.log(`decrypt bridge manifest error ${e}`));
	return { remote };
}

async function pumpDecrypt(sub: Track.Consumer, out: NetTrack.Producer, name: string, log: Log) {
	let groups = 0;
 let newest = -1;
	for (;;) {
		const g = await sub.recvGroup();
		if (!g) break;
 if (g.start <= newest) continue; newest = g.start;
		let lg: NetGroup.Producer;
		try {
			lg = out.createGroup(g.start);
		} catch (e) {
			log(`decrypt bridge: ${name} skip group ${g.start}: ${e}`);
			continue;
		}
		let frames = 0;
		void (async () => {
			for (let f = await g.readFrame(); f; f = await g.readFrame()) {
				lg.writeFrame({ payload: f.plaintext, timestamp: f.timestamp as Time.Timestamp });
				if (groups <= 2 && frames++ === 0) log(`decrypt bridge: ${name} group ${g.start} first frame ${f.plaintext.byteLength} bytes`);
			}
			lg.finish();
		})().catch((e) => log(`decrypt bridge: ${name} group error ${e}`));
		groups++;
	}
}

// Playwright driver for spike e2ee-js: pub, sub, and eve pages against a local relay.
// usage: node drive.mjs <chromium|firefox> <pageBaseUrl> <relayUrl> <certHashHex> [versions]
import { chromium, firefox } from "playwright";

const [, , which, base, relay, hash, versions] = process.argv;
const components = process.env.COMPONENTS === "1";
const browserType = { chromium, firefox }[which];
const launchOpts =
	which === "chromium"
		? { args: ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"] }
		: { firefoxUserPrefs: { "media.navigator.streams.fake": true, "media.navigator.permission.disabled": true } };
const browser = await browserType.launch(launchOpts);
console.log(`browser ${which} version=${browser.version()}`);

const secret = "11".repeat(32);
const wrong = "22".repeat(32);
const common = { relay, hash, ...(versions ? { versions } : {}) };
const url = (p) => `${base}?${new URLSearchParams({ ...common, ...p })}`;

async function open(name, params, timeoutMs = 30000) {
	const ctx = await browser.newContext();
	const page = await ctx.newPage();
	page.on("console", (m) => console.log(`[${which}:${name}] ${m.text()}`));
	page.on("pageerror", (e) => console.log(`[${which}:${name}] pageerror ${e.message}`));
	await page.goto(url(params));
	await page.waitForFunction(() => window.spikeDone === true, null, { timeout: timeoutMs });
	return page;
}

let ok = false;
try {
	const pubPage = await open("pub", { role: components ? "cpub" : "pub", secret });
	const info = await pubPage.evaluate(() => window.spikeInfo);
	if (!info) throw new Error("publisher produced no info");
	// The epoch rides to the subscriber over the "app channel" (this driver), as on a wire without instances.
	const subPage = await open("sub", { role: components ? "csub" : "sub", secret, epoch: info.epoch });
	if (components) {
		ok = (await subPage.evaluate(() => window.spikeLog)).some(s => s.includes("RESULT csub rendered=true"));
	} else {
	const eve = await open("eve", { role: "eve", path: info.path, video: info.video, epoch: info.epoch, wrong });
	const subLog = (await subPage.evaluate(() => window.spikeLog)).join("\n");
	const eveLog = (await eve.evaluate(() => window.spikeLog)).join("\n");
	ok = subLog.includes("RESULT sub decrypted=true") && eveLog.includes("RESULT eve plaintext_leaked=false");
	}
} catch (e) {
	console.log(`driver error: ${e.message}`);
}
console.log(`VERDICT ${which} ${components ? "components" : "frames"}: ${ok ? "PROVEN" : "REFUTED (this harness)"}`);
await browser.close();
process.exit(ok ? 0 : 1);

// Pinned @moq/net subscriber. Spike page script, bundled by pair-live.sh.
// Reads window.__MOQ__ = { url, hash, path, seconds }.
import * as Moq from "@moq/net";

type Config = { url: string; hash: string; path: string; seconds: number };

async function main() {
  const cfg = (window as unknown as { __MOQ__: Config }).__MOQ__;
  const parsed = new URL(cfg.url);
  const dial = parsed;
  const lines: string[] = [];
  const say = (s: string) => {
    lines.push(s);
    console.log(s);
  };
  say(`document.pathname=${location.pathname}`);
  say(`connect.url.raw=${cfg.url}`);
  say(`connect.url.pathname=${parsed.pathname}`);
  say(`connect.url.href=${parsed.href.replace(/jwt=[^&]+/, "jwt=REDACTED")}`);
  await fetch("/log", { method: "POST", body: lines.join("\n") });
  const origin = new Moq.Origin.Producer();
  const connection = await Moq.Connection.connect({
    url: dial,
    consume: origin,
    webtransport: { serverCertificateHashes: [{ algorithm: "sha-256", value: cfg.hash }] },
    timeout: Moq.Clock.Duration.millis(8_000),
  });
  say("moq-connected");
  const request = origin.request(Moq.Path.from(cfg.path));
  const broadcast = await request.broadcast();
  const track = broadcast.track("bytes").subscribe();
  let frames = 0;
  let bytes = 0;
  let first = "";
  const deadline = Date.now() + cfg.seconds * 1000;
  while (Date.now() < deadline) {
    const left = Math.max(1, deadline - Date.now());
    const group = await Promise.race([
      track.recvGroup(),
      new Promise((resolve) => setTimeout(() => resolve(null), left)),
    ]);
    if (!group) break;
    for (;;) {
      const frame = await (group as { readFrame: () => Promise<{ payload?: Uint8Array } | undefined> }).readFrame();
      if (!frame?.payload) break;
      if (!first) first = new TextDecoder().decode(frame.payload).slice(0, 48);
      bytes += frame.payload.byteLength;
      frames += 1;
    }
  }
  say(`received path=${cfg.path} frames=${frames} bytes=${bytes} first=${first}`);
  track.close();
  request.close();
  await connection.close();
  origin.close();
  const body = lines.join("\n");
  document.title = body;
  document.body.textContent = body;
  await fetch("/log", { method: "POST", body });
}

main().catch((err) => {
  const message = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
  console.error(message);
  const body = `moq-error ${message}\n${err instanceof Error ? err.stack : ""}`;
  document.title = message;
  document.body.textContent = body;
  fetch("/log", { method: "POST", body });
});

import { describe, expect, test } from "bun:test";
import { createSocket } from "node:dgram";
import { createLogger } from "./index.ts";
import { format3164, priFromPino } from "./syslog.ts";

describe("rfc3164", () => {
  test("pri maps pino error to syslog error", () => {
    expect(priFromPino(50)).toBe(8 + 3);
    expect(priFromPino(30)).toBe(8 + 6);
  });

  test("strips ansi from MSG", () => {
    const line = format3164({
      pri: 14,
      hostname: "box",
      tag: "myscape",
      msg: '{\x1b[31m"a"\x1b[0m:1}',
      at: new Date("2026-01-02T03:04:05"),
    });
    expect(line).not.toMatch(/\x1b/);
    expect(line).toMatch(/^<\d+>/);
    expect(line).toContain(" myscape: ");
    expect(line).toContain('{"a":1}');
  });
});

describe("createLogger syslog UDP", () => {
  test("emits 3164 datagram with schema JSON and no ANSI", async () => {
    const sock = createSocket("udp4");
    const got = Promise.withResolvers<string>();
    await new Promise<void>((resolve) => {
      sock.bind(0, "127.0.0.1", () => resolve());
    });
    sock.once("message", (buf) => got.resolve(buf.toString("utf8")));
    const addr = sock.address();
    const log = createLogger({
      name: "myscape",
      schema: "myscape/v1",
      stdout: false,
      syslog: { host: "127.0.0.1", port: addr.port },
    });
    log.info({ url: "/worlds/xela.glb", status: 200 }, "probe ok");
    const datagram = await got.promise;
    sock.close();
    expect(datagram).toMatch(/^<\d+>[A-Z][a-z]{2} /);
    expect(datagram).not.toMatch(/\x1b/);
    const msg = datagram.split(": ").slice(1).join(": ");
    const rec = JSON.parse(msg) as { schema: string; app: string; url: string };
    expect(rec.schema).toBe("myscape/v1");
    expect(rec.app).toBe("myscape");
    expect(rec.url).toBe("/worlds/xela.glb");
  });
});

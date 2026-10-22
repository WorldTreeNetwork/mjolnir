import { describe, expect, test } from "bun:test";
import { mkdtemp, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  PINO_ENVELOPE,
  generateSchema,
  canonicalJson,
  schemaMatches,
  assertSchemaMatches,
  GenerateError,
  type LogFromSchema,
} from "./generate.ts";

const appConst = {
  $id: "myscape/v1",
  type: "object",
  properties: {
    url: { type: "string" },
  },
} as const;

describe("PINO_ENVELOPE", () => {
  test("required and optional keys", () => {
    expect(PINO_ENVELOPE.required).toEqual(["level", "time", "schema", "app", "name"]);
    expect(PINO_ENVELOPE.properties.level.type).toBe("number");
    expect(PINO_ENVELOPE.properties.time.type).toBe("string");
    expect(PINO_ENVELOPE.properties.schema.type).toBe("string");
    expect(PINO_ENVELOPE.properties.app.type).toBe("string");
    expect(PINO_ENVELOPE.properties.name.type).toBe("string");
    expect(PINO_ENVELOPE.properties.msg.type).toBe("string");
    expect(PINO_ENVELOPE.properties.err.type).toBe("object");
  });
});

describe("generateSchema", () => {
  test("merges envelope with app fields", () => {
    const out = generateSchema(appConst);
    expect(out.$id).toBe("myscape/v1");
    expect(out.additionalProperties).toBe(false);
    expect(out.properties.url).toEqual({ type: "string" });
    expect(out.properties.level).toEqual({ type: "number" });
    expect(out.properties.time).toEqual({ type: "string" });
    expect(out.properties.schema).toEqual({ type: "string" });
    expect(out.properties.app).toEqual({ type: "string" });
    expect(out.properties.name).toEqual({ type: "string" });
    expect(out.properties.msg).toEqual({ type: "string" });
    expect(out.properties.err).toEqual({ type: "object" });
    expect(out.required).toEqual(["level", "time", "schema", "app", "name"]);
  });

  test("merges app required", () => {
    const out = generateSchema({
      $id: "myscape/v1",
      properties: { url: { type: "string" } },
      required: ["url"],
    });
    expect(out.required).toEqual(["level", "time", "schema", "app", "name", "url"]);
  });

  test("envelope key collision fails", () => {
    expect(() =>
      generateSchema({
        $id: "myscape/v1",
        properties: { level: { type: "number" } },
      }),
    ).toThrow(GenerateError);
    expect(() =>
      generateSchema({
        $id: "myscape/v1",
        properties: { name: { type: "string" } },
      }),
    ).toThrow(/envelope key name/);
  });

  test("nested properties fail", () => {
    expect(() =>
      generateSchema({
        $id: "myscape/v1",
        properties: { req: { type: "object", properties: { url: { type: "string" } } } },
      }),
    ).toThrow(/nested properties/);
  });

  test("enum, array, $ref, combinators fail", () => {
    expect(() =>
      generateSchema({
        $id: "x",
        properties: { color: { type: "string", enum: ["a"] } },
      }),
    ).toThrow(/enum/);
    expect(() =>
      generateSchema({
        $id: "x",
        properties: { tags: { type: "array" } },
      }),
    ).toThrow(/array/);
    expect(() =>
      generateSchema({
        $id: "x",
        properties: { n: { $ref: "#/defs/n" } },
      }),
    ).toThrow(/\$ref/);
    expect(() =>
      generateSchema({
        $id: "x",
        anyOf: [{ type: "object" }],
      }),
    ).toThrow(/anyOf/);
    expect(() =>
      generateSchema({
        $id: "x",
        properties: { n: { type: "number", oneOf: [] } },
      }),
    ).toThrow(/oneOf/);
    expect(() =>
      generateSchema({
        $id: "x",
        allOf: [],
      }),
    ).toThrow(/allOf/);
  });

  test("unknown type fails generate", () => {
    expect(() =>
      generateSchema({
        $id: "x",
        properties: { n: { type: "integer" } },
      }),
    ).toThrow(/unknown type integer/);
  });

  test("app required naming envelope or missing key fails", () => {
    expect(() =>
      generateSchema({
        $id: "x",
        properties: { url: { type: "string" } },
        required: ["name"],
      }),
    ).toThrow(/envelope key name/);
    expect(() =>
      generateSchema({
        $id: "x",
        properties: { url: { type: "string" } },
        required: ["missing"],
      }),
    ).toThrow(/missing from properties/);
  });

  test("additionalProperties true fails", () => {
    expect(() =>
      generateSchema({
        $id: "x",
        properties: { url: { type: "string" } },
        additionalProperties: true,
      }),
    ).toThrow(/additionalProperties/);
  });

  test("opaque object property is allowed", () => {
    const out = generateSchema({
      $id: "x",
      properties: { meta: { type: "object" } },
    });
    expect(out.properties.meta).toEqual({ type: "object" });
  });
});

describe("derived type helper", () => {
  test("LogFromSchema accepts envelope plus app fields", () => {
    const rec: LogFromSchema<typeof appConst> = {
      level: 30,
      time: "2026-09-10T00:00:00.000Z",
      schema: "myscape/v1",
      app: "myscape",
      name: "myscape",
      url: "/worlds/xela.glb",
    };
    expect(rec.url).toBe("/worlds/xela.glb");
  });
});

describe("canonical --check", () => {
  test("stable key order, 2-space indent, trailing newline", () => {
    const text = canonicalJson({ b: 1, a: { z: 2, y: 3 } });
    expect(text).toBe('{\n  "a": {\n    "y": 3,\n    "z": 2\n  },\n  "b": 1\n}\n');
  });

  test("matches canonical bytes or parsed-equal", () => {
    const generated = generateSchema(appConst);
    const canonical = canonicalJson(generated);
    expect(schemaMatches(canonical, generated)).toBe(true);
    const reordered = JSON.stringify(generated) + "\n";
    expect(reordered === canonical).toBe(false);
    expect(schemaMatches(reordered, generated)).toBe(true);
    expect(schemaMatches('{"$id":"other"}\n', generated)).toBe(false);
    expect(() => assertSchemaMatches('{"$id":"other"}\n', generated)).toThrow(/differs/);
  });
});

describe("mjolnir-log generate --check", () => {
  test("fails on drift and does not write", async () => {
    const dir = await mkdtemp(join(tmpdir(), "mjolnir-log-"));
    const from = join(dir, "types.ts");
    const out = join(dir, "schema.json");
    await writeFile(
      from,
      `export const schema = { $id: "x", properties: { url: { type: "string" } } } as const;\n`,
    );
    await writeFile(out, '{"$id":"stale"}\n');
    const bin = fileURLToPath(new URL("./bin/mjolnir-log.ts", import.meta.url));
    const proc = Bun.spawn(["bun", bin, "generate", "--from", from, "--export", "schema", "--out", out, "--check"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const exit = await proc.exited;
    expect(exit).not.toBe(0);
    expect(await readFile(out, "utf8")).toBe('{"$id":"stale"}\n');
  });

  test("writes canonical schema without --check", async () => {
    const dir = await mkdtemp(join(tmpdir(), "mjolnir-log-"));
    const from = join(dir, "types.ts");
    const out = join(dir, "schema.json");
    await writeFile(
      from,
      `export const schema = { $id: "x", properties: { url: { type: "string" } } } as const;\n`,
    );
    const bin = fileURLToPath(new URL("./bin/mjolnir-log.ts", import.meta.url));
    const proc = Bun.spawn(["bun", bin, "generate", "--from", from, "--export", "schema", "--out", out], {
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(await proc.exited).toBe(0);
    const written = await readFile(out, "utf8");
    expect(schemaMatches(written, generateSchema({ $id: "x", properties: { url: { type: "string" } } }))).toBe(true);
  });
});

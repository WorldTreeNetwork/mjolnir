import { describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { generateSchema } from "./generate.ts";
import { lspMissingMessage } from "./lsp-deps.ts";
import {
  addSchemaFile,
  diagnosticsForLine,
  diagnosticsForText,
  emptyRegistry,
  isLogDocument,
  loadRegistry,
  rangeForPath,
  type SchemaRegistry,
} from "./lsp.ts";

function registryWith(id: string, schema: { $id?: string }): SchemaRegistry {
  const r = emptyRegistry();
  addSchemaFile(r, `${id}.schema.json`, schema);
  return r;
}

const generated = generateSchema({
  $id: "myscape/v1",
  properties: { url: { type: "string" } },
});

describe("isLogDocument", () => {
  test("jsonl and ndjson always attach", () => {
    expect(isLogDocument("file:///tmp/a.jsonl", "not json")).toBe(true);
    expect(isLogDocument("file:///tmp/a.ndjson", "")).toBe(true);
  });

  test(".log only when first non-empty line starts with {", () => {
    expect(isLogDocument("file:///tmp/a.log", "\n  {\"a\":1}\n")).toBe(true);
    expect(isLogDocument("file:///tmp/a.log", "INFO hello\n")).toBe(false);
    expect(isLogDocument("file:///tmp/a.txt", "{\"a\":1}\n")).toBe(false);
  });
});

describe("rangeForPath", () => {
  test("maps a property onto offsets; unresolved path is the whole line", () => {
    const line = '{"schema":"myscape/v1","extra":true}';
    const extra = rangeForPath(line, 3, "extra");
    expect(extra.start.line).toBe(3);
    expect(line.slice(extra.start.character, extra.end.character)).toBe("true");
    const missing = rangeForPath(line, 3, "nope");
    expect(missing).toEqual({ start: { line: 3, character: 0 }, end: { line: 3, character: line.length } });
  });
});

describe("diagnosticsForText", () => {
  const registry = registryWith("myscape/v1", generated);

  test("unknown field diagnostic; document text still contains extra", () => {
    const text = '{"schema":"myscape/v1","extra":true}';
    const diags = diagnosticsForText(text, registry);
    expect(diags.some((d) => d.path === "extra" && d.message === "unknown field")).toBe(true);
    expect(text).toContain("extra");
  });

  test("unknown schema id", () => {
    const diags = diagnosticsForLine('{"schema":"myscape/v2"}', 0, registry);
    expect(diags).toHaveLength(1);
    expect(diags[0]?.message).toBe("no schema for myscape/v2");
  });

  test("untyped line with no schema key has no diagnostic", () => {
    expect(diagnosticsForLine('{"msg":"hello"}', 0, registry)).toEqual([]);
  });

  test("duplicate $id is one ambiguous schema id diagnostic", () => {
    const r = emptyRegistry();
    addSchemaFile(r, "/a/schema.json", generated);
    addSchemaFile(r, "/b/schema.json", generated);
    const diags = diagnosticsForLine('{"schema":"myscape/v1"}', 0, r);
    expect(diags).toHaveLength(1);
    expect(diags[0]?.message).toBe("ambiguous schema id");
  });

  test("skips empty lines and invalid JSON", () => {
    const text = '\nnot json\n{"schema":"myscape/v1","url":"/x"}\n';
    const diags = diagnosticsForText(text, registry);
    expect(diags.filter((d) => d.message === "unknown field")).toEqual([]);
  });
});

describe("schema registry", () => {
  test("workspace glob *schema.json plus extra paths", async () => {
    const dir = await mkdtemp(join(tmpdir(), "mjolnir-log-lsp-"));
    mkdirSync(join(dir, "nested"));
    writeFileSync(join(dir, "nested", "app.schema.json"), JSON.stringify(generated));
    const extraDir = await mkdtemp(join(tmpdir(), "mjolnir-log-extra-"));
    writeFileSync(join(extraDir, "other.schema.json"), JSON.stringify({ $id: "other/v1", type: "object", properties: {} }));
    const r = loadRegistry([dir], [join(extraDir, "other.schema.json")]);
    expect(r.byId.get("myscape/v1")?.files).toHaveLength(1);
    expect(r.byId.has("other/v1")).toBe(true);
  });
});

describe("isolation", () => {
  test("logger entry does not import LSP optionalDependencies", () => {
    const src = readFileSync(fileURLToPath(new URL("./index.ts", import.meta.url)), "utf8");
    expect(src).not.toContain("vscode-languageserver");
    expect(src).not.toContain("jsonc-parser");
    expect(src).not.toContain("./lsp");
  });

  test("missing optional deps message is clear", () => {
    const msg = lspMissingMessage(["vscode-languageserver", "jsonc-parser"]);
    expect(msg).toContain("vscode-languageserver");
    expect(msg).toContain("jsonc-parser");
    expect(msg).toContain("optionalDependencies");
  });
});

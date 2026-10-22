#!/usr/bin/env bun
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { GenerateError, assertSchemaMatches, canonicalJson, generateSchema } from "../generate.ts";

function usage(): never {
  console.error(
    "usage: mjolnir-log generate --from <module.ts> [--export name] [--out schema.json] [--check]",
  );
  process.exit(2);
}

const argv = process.argv.slice(2);
if (argv[0] !== "generate") usage();

let fromPath: string | undefined;
let exportName: string | undefined;
let outPath: string | undefined;
let check = false;
for (let i = 1; i < argv.length; i++) {
  const arg = argv[i];
  if (arg === "--from") fromPath = argv[++i];
  else if (arg === "--export") exportName = argv[++i];
  else if (arg === "--out") outPath = argv[++i];
  else if (arg === "--check") check = true;
  else usage();
}
if (!fromPath) usage();

const mod = await import(pathToFileURL(resolve(fromPath)).href);
const appConst = exportName
  ? mod[exportName]
  : (mod.default ?? mod.schema ?? mod.logSchema ?? mod.appSchema);
if (appConst === undefined) {
  console.error(
    `mjolnir-log generate: no export${exportName ? ` ${exportName}` : " (default/schema/logSchema/appSchema)"} in ${fromPath}`,
  );
  process.exit(1);
}

try {
  const generated = generateSchema(appConst);
  const text = canonicalJson(generated);
  if (check) {
    if (!outPath) {
      console.error("mjolnir-log generate --check requires --out <schema.json>");
      process.exit(2);
    }
    let committed: string;
    try {
      committed = readFileSync(resolve(outPath), "utf8");
    } catch {
      console.error(`mjolnir-log generate --check: cannot read ${outPath}`);
      process.exit(1);
    }
    assertSchemaMatches(committed, generated);
  } else if (outPath) {
    const dest = resolve(outPath);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, text);
  } else {
    process.stdout.write(text);
  }
} catch (err) {
  const message = err instanceof GenerateError || err instanceof Error ? err.message : String(err);
  console.error(`mjolnir-log generate: ${message}`);
  process.exit(1);
}

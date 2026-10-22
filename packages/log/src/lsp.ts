import { findNodeAtLocation, parseTree } from "jsonc-parser";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { isAbsolute, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { validateRecord, type JsonSchema, type ValidationIssue } from "./schema.ts";

export type LspRange = {
  start: { line: number; character: number };
  end: { line: number; character: number };
};

export type LspDiagnostic = {
  message: string;
  range: LspRange;
  path?: string;
};

export type SchemaEntry = {
  schema: JsonSchema;
  files: string[];
};

export type SchemaRegistry = {
  byId: Map<string, SchemaEntry>;
};

export function emptyRegistry(): SchemaRegistry {
  return { byId: new Map() };
}

export function addSchemaFile(registry: SchemaRegistry, file: string, schema: JsonSchema): void {
  const id = schema.$id;
  if (typeof id !== "string" || id.length === 0) return;
  const existing = registry.byId.get(id);
  if (existing) {
    if (!existing.files.includes(file)) existing.files.push(file);
    return;
  }
  registry.byId.set(id, { schema, files: [file] });
}

export function loadRegistry(folders: string[], extraPaths: string[] = []): SchemaRegistry {
  const registry = emptyRegistry();
  const files = new Set<string>();
  for (const folder of folders) {
    collectSchemaFiles(folder, files);
  }
  for (const extra of extraPaths) {
    const resolved = resolveExtra(extra, folders);
    if (!resolved) continue;
    try {
      if (statSync(resolved).isDirectory()) collectSchemaFiles(resolved, files);
      else files.add(resolved);
    } catch {
      // missing path is not a diagnostic source
    }
  }
  for (const file of files) {
    try {
      const parsed = JSON.parse(readFileSync(file, "utf8")) as JsonSchema;
      addSchemaFile(registry, file, parsed);
    } catch {
      // skip unreadable / invalid schema files
    }
  }
  return registry;
}

function resolveExtra(extra: string, folders: string[]): string | undefined {
  if (isAbsolute(extra)) return extra;
  if (folders[0]) return join(folders[0], extra);
  return extra;
}

function collectSchemaFiles(root: string, out: Set<string>): void {
  let entries: string[];
  try {
    entries = readdirSync(root);
  } catch {
    return;
  }
  for (const name of entries) {
    if (name === "node_modules" || name === ".git") continue;
    const full = join(root, name);
    let st;
    try {
      st = statSync(full);
    } catch {
      continue;
    }
    if (st.isDirectory()) collectSchemaFiles(full, out);
    else if (name.endsWith("schema.json")) out.add(full);
  }
}

export function uriToPath(uri: string): string {
  if (uri.startsWith("file://")) {
    try {
      return fileURLToPath(uri);
    } catch {
      return uri;
    }
  }
  return uri;
}

export function isLogDocument(uri: string, text: string): boolean {
  const path = uriToPath(uri).replace(/\\/g, "/");
  if (path.endsWith(".jsonl") || path.endsWith(".ndjson")) return true;
  if (path.endsWith(".log")) {
    const first = firstNonEmptyLine(text);
    return Boolean(first && first.trimStart().startsWith("{"));
  }
  return false;
}

function firstNonEmptyLine(text: string): string | undefined {
  for (const line of text.split(/\r?\n/)) {
    if (line.trim() !== "") return line;
  }
  return undefined;
}

export function rangeForPath(lineText: string, line: number, path: string): LspRange {
  const whole: LspRange = {
    start: { line, character: 0 },
    end: { line, character: lineText.length },
  };
  const tree = parseTree(lineText);
  if (!tree) return whole;
  const segments = path.split(".").filter((s) => s.length > 0);
  const node = findNodeAtLocation(tree, segments);
  if (!node) return whole;
  return {
    start: { line, character: node.offset },
    end: { line, character: node.offset + node.length },
  };
}

export function diagnosticsForText(text: string, registry: SchemaRegistry): LspDiagnostic[] {
  const out: LspDiagnostic[] = [];
  const lines = text.split(/\n/);
  for (let i = 0; i < lines.length; i++) {
    let lineText = lines[i] ?? "";
    if (lineText.endsWith("\r")) lineText = lineText.slice(0, -1);
    if (lineText.trim() === "") continue;
    out.push(...diagnosticsForLine(lineText, i, registry));
  }
  return out;
}

export function diagnosticsForLine(lineText: string, line: number, registry: SchemaRegistry): LspDiagnostic[] {
  let rec: Record<string, unknown>;
  try {
    rec = JSON.parse(lineText) as Record<string, unknown>;
  } catch {
    return [];
  }
  if (typeof rec !== "object" || rec === null || Array.isArray(rec)) return [];
  if (!("schema" in rec)) return [];

  const id = rec.schema;
  if (typeof id !== "string") {
    return [{ message: `no schema for ${String(id)}`, range: rangeForPath(lineText, line, "schema"), path: "schema" }];
  }

  const entry = registry.byId.get(id);
  if (!entry) {
    return [{ message: `no schema for ${id}`, range: rangeForPath(lineText, line, "schema"), path: "schema" }];
  }
  if (entry.files.length > 1) {
    return [{ message: "ambiguous schema id", range: rangeForPath(lineText, line, "schema"), path: "schema" }];
  }

  return validateRecord(rec, entry.schema).map((issue: ValidationIssue) => ({
    message: issue.message,
    path: issue.path,
    range: rangeForPath(lineText, line, issue.path),
  }));
}

export function workspaceRelative(file: string, folders: string[]): string {
  for (const folder of folders) {
    const rel = relative(folder, file);
    if (rel && !rel.startsWith("..") && !isAbsolute(rel)) return rel;
  }
  return file;
}

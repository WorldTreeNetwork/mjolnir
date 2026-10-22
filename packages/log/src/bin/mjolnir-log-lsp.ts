#!/usr/bin/env bun
import { lspMissingMessage } from "../lsp-deps.ts";

const missing: string[] = [];
async function tryImport(label: string, specifier: string): Promise<unknown> {
  try {
    return await import(specifier);
  } catch {
    missing.push(label);
    return null;
  }
}

const vls = (await tryImport("vscode-languageserver", "vscode-languageserver/node")) as
  | typeof import("vscode-languageserver/node")
  | null;
const textdoc = (await tryImport(
  "vscode-languageserver-textdocument",
  "vscode-languageserver-textdocument",
)) as typeof import("vscode-languageserver-textdocument") | null;
await tryImport("jsonc-parser", "jsonc-parser");

if (missing.length > 0 || !vls || !textdoc) {
  console.error(lspMissingMessage(missing.length > 0 ? missing : ["vscode-languageserver"]));
  process.exit(1);
}

const { diagnosticsForText, isLogDocument, loadRegistry, uriToPath } = await import("../lsp.ts");
const { TextDocument } = textdoc;
const {
  createConnection,
  TextDocuments,
  ProposedFeatures,
  DiagnosticSeverity,
  TextDocumentSyncKind,
} = vls;

const connection = createConnection(ProposedFeatures.all);
const documents = new TextDocuments(TextDocument);

let folders: string[] = [];
let extraPaths: string[] = [];
let registry = loadRegistry([], []);

function refreshRegistry(): void {
  registry = loadRegistry(folders, extraPaths);
}

function folderPaths(params: {
  workspaceFolders?: { uri: string }[] | null;
  rootUri?: string | null;
}): string[] {
  const out: string[] = [];
  for (const f of params.workspaceFolders ?? []) out.push(uriToPath(f.uri));
  if (params.rootUri) out.push(uriToPath(params.rootUri));
  return out;
}

connection.onInitialize((params) => {
  const init = (params.initializationOptions ?? {}) as { schemaPaths?: unknown };
  extraPaths = Array.isArray(init.schemaPaths)
    ? init.schemaPaths.filter((p): p is string => typeof p === "string")
    : [];
  folders = folderPaths(params);
  refreshRegistry();
  return {
    capabilities: {
      textDocumentSync: TextDocumentSyncKind.Incremental,
    },
  };
});

function publish(doc: { uri: string; getText(): string }): void {
  const text = doc.getText();
  if (!isLogDocument(doc.uri, text)) {
    connection.sendDiagnostics({ uri: doc.uri, diagnostics: [] });
    return;
  }
  const diagnostics = diagnosticsForText(text, registry).map((d) => ({
    range: d.range,
    message: d.message,
    source: "mjolnir-log",
    severity: DiagnosticSeverity.Warning,
  }));
  connection.sendDiagnostics({ uri: doc.uri, diagnostics });
}

documents.onDidChangeContent((change) => {
  publish(change.document);
});
documents.onDidOpen((event) => {
  publish(event.document);
});
documents.onDidClose((event) => {
  connection.sendDiagnostics({ uri: event.document.uri, diagnostics: [] });
});

connection.onDidChangeWatchedFiles(() => {
  refreshRegistry();
  for (const doc of documents.all()) publish(doc);
});

documents.listen(connection);
connection.listen();

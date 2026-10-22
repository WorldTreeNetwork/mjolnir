export const LSP_OPTIONAL_PACKAGES = [
  "vscode-languageserver",
  "vscode-languageserver-textdocument",
  "jsonc-parser",
] as const;

export function lspMissingMessage(missing: string[]): string {
  return [
    `mjolnir-log-lsp requires ${missing.join(", ")}.`,
    "They are optionalDependencies of mjolnir-log.",
    `Install with: bun add ${LSP_OPTIONAL_PACKAGES.join(" ")}`,
  ].join(" ");
}

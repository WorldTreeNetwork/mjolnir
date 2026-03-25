# Universal MCP Generator Specification

**Status**: Draft
**Date**: 2026-02-26
**Author**: Architecture Team

## 1. Problem Statement

Mjolnir needs an MCP (Model Context Protocol) server so AI agents can spawn, manage, snapshot, and execute commands inside microVMs. Hand-coding MCP tool definitions is tedious, error-prone, and drifts from the actual API. Worse, every new project with a REST API faces the same problem: translating typed API contracts into MCP tool definitions that agents can discover and invoke.

We propose a **Universal MCP Generator** -- an Elysia/Bun application that reads TypeScript files containing Zod schemas and automatically generates a fully functional MCP server. Zod is the universal anchor: it is simultaneously machine-readable (JSON Schema output, TypeScript type inference, runtime validation) and human-readable (error messages, `.describe()` annotations, constraint descriptions). This duality makes Zod the perfect bridge between typed API contracts and the natural-language descriptions that agents consume.

## 2. Architecture Overview

```
                          ┌──────────────────────────┐
                          │    AI Agent (Claude, etc) │
                          └────────────┬─────────────┘
                                       │ MCP (Streamable HTTP)
                                       ▼
┌─────────────────────────────────────────────────────────────┐
│                   Universal MCP Generator                   │
│                      (Elysia / Bun)                         │
│                                                             │
│  ┌───────────┐  ┌──────────────┐  ┌───────────────────┐    │
│  │  Ingester  │  │  Tool        │  │  MCP Server       │    │
│  │  (ts-morph)│─▶│  Registry    │─▶│  (JSON-RPC 2.0)   │    │
│  └───────────┘  │  (Zod→JSON   │  │  Streamable HTTP   │    │
│                 │   Schema)     │  └─────────┬─────────┘    │
│  ┌───────────┐  └──────────────┘            │               │
│  │  Enricher  │         ▲                    │               │
│  │  (AI pass) │─────────┘                    │               │
│  └───────────┘                               ▼               │
│  ┌───────────┐                    ┌─────────────────────┐   │
│  │  Editor    │                    │  Proxy Layer        │   │
│  │  (TUI/Web) │                    │  (Zod validate →    │   │
│  └───────────┘                    │   HTTP to backend)   │   │
│                                    └──────────┬──────────┘   │
└───────────────────────────────────────────────┼──────────────┘
                                                │ HTTP/REST
                                                ▼
                                    ┌──────────────────────┐
                                    │  Backend API          │
                                    │  (Mjolnir Elixir,    │
                                    │   any REST service)   │
                                    └──────────────────────┘
```

The generator operates in five stages: **Ingest**, **Transform**, **Enrich**, **Serve**, and **Edit**. Phases 1-2 are the MVP. Phases 3-5 extend to the full vision.

## 3. The MCP Protocol Contract

MCP uses JSON-RPC 2.0 over Streamable HTTP (spec revision 2025-03-26). The server exposes a single HTTP endpoint (e.g. `/mcp`) that accepts POST for client-to-server messages and optionally GET for server-to-client SSE streams.

A tool is defined as:

```json
{
  "name": "spawn_vm",
  "title": "Spawn MicroVM",
  "description": "Create and boot a new Cloud Hypervisor microVM with specified resources",
  "inputSchema": {
    "type": "object",
    "properties": {
      "base_image":  { "type": "string", "description": "Base rootfs image name" },
      "memory_mb":   { "type": "integer", "description": "RAM in MB (min 128)" },
      "vcpus":       { "type": "integer", "description": "Virtual CPU count (1-8)" }
    }
  },
  "annotations": {
    "title": "Spawn MicroVM",
    "readOnlyHint": false,
    "destructiveHint": false,
    "openWorldHint": true
  }
}
```

Tool invocation uses `tools/call` with a `name` and `arguments` object. Results return `content` (array of text/image/audio blocks) and an optional `isError` flag. The key insight: `inputSchema` is just JSON Schema, and Zod generates JSON Schema natively.

## 4. Zod as the Universal Anchor

### 4.1 Why Zod

Zod schemas encode three things simultaneously:

1. **Structure** -- property names, types, nesting, optionality
2. **Constraints** -- min/max, regex patterns, refinements, transforms
3. **Documentation** -- `.describe()` annotations, error messages, metadata

When we call `z.toJSONSchema(schema)`, we get the JSON Schema that MCP expects for `inputSchema`. When we read `.describe()` strings, we get the natural-language tool descriptions that agents need. When we call `schema.parse(input)`, we get runtime validation with error messages that become actionable feedback for agents (MCP's `isError: true` tool execution errors).

### 4.2 Zod v4 Native JSON Schema

Zod v4 provides `z.toJSONSchema()` natively, eliminating the need for the now-deprecated `zod-to-json-schema` package:

```typescript
import { z } from "zod";

const SpawnVMInput = z.object({
  base_image: z.string()
    .describe("Base rootfs image name (e.g. 'ubuntu-24.04', 'alpine')"),
  memory_mb: z.int().min(128).max(8192).optional()
    .describe("RAM allocation in megabytes. Defaults to 512."),
  vcpus: z.int().min(1).max(8).optional()
    .describe("Number of virtual CPUs. Defaults to 1."),
  ssh_public_key: z.string().optional()
    .describe("SSH public key to inject into the VM for key-based auth"),
  snapshot: z.string().optional()
    .describe("Name of a snapshot to restore from instead of a fresh image"),
  rootfs_size_mb: z.int().min(256).optional()
    .describe("Root filesystem size in MB. Defaults to 2048."),
  enable_iroh: z.boolean().optional()
    .describe("Enable Iroh peer-to-peer networking for this VM"),
});

const jsonSchema = z.toJSONSchema(SpawnVMInput);
// Produces a valid JSON Schema object ready for MCP inputSchema
```

### 4.3 Validation Error Messages as Agent Feedback

When an agent sends invalid arguments, Zod's parse errors map directly to MCP tool execution errors:

```typescript
try {
  const validated = SpawnVMInput.parse(args);
} catch (e) {
  if (e instanceof z.ZodError) {
    return {
      content: [{ type: "text", text: e.issues.map(i =>
        `${i.path.join(".")}: ${i.message}`
      ).join("\n") }],
      isError: true,
    };
  }
}
```

An agent receives: `memory_mb: Number must be greater than or equal to 128` -- actionable, self-correctable feedback.

## 5. Mjolnir API Surface as Zod Schemas

Mjolnir's Elixir API router exposes these endpoints. Here is the complete Zod schema contract that the MCP sidecar uses:

```typescript
// file: schemas/mjolnir.ts
import { z } from "zod";

const vmId = z.string().uuid().describe("UUID of the target VM");

export const tools = {
  spawn_vm: {
    description: "Spawn a new Cloud Hypervisor microVM. Returns the VM details including its UUID.",
    input: z.object({
      base_image: z.string().optional()
        .describe("Base rootfs image name (default: ubuntu-24.04)"),
      memory_mb: z.int().min(128).max(8192).optional()
        .describe("RAM in megabytes (default: 512)"),
      vcpus: z.int().min(1).max(8).optional()
        .describe("Virtual CPU count (default: 1)"),
      ssh_public_key: z.string().optional()
        .describe("SSH public key to inject for key-based authentication"),
      snapshot: z.string().optional()
        .describe("Restore from this named snapshot instead of a fresh base image"),
      rootfs_size_mb: z.int().min(256).optional()
        .describe("Root filesystem size in MB (default: 2048)"),
      enable_iroh: z.boolean().optional()
        .describe("Enable Iroh P2P networking in this VM"),
    }),
    method: "POST" as const,
    path: "/api/vms",
  },

  list_vms: {
    description: "List all running microVMs with their status and resource usage.",
    input: z.object({}),
    method: "GET" as const,
    path: "/api/vms",
  },

  get_vm: {
    description: "Get detailed information about a specific VM by its UUID.",
    input: z.object({ vm_id: vmId }),
    method: "GET" as const,
    path: "/api/vms/:vm_id",
  },

  exec_in_vm: {
    description: "Execute a shell command inside a running VM. Returns stdout, stderr, and exit code.",
    input: z.object({
      vm_id: vmId,
      command: z.string().min(1)
        .describe("Shell command to execute (runs via sh -c)"),
      timeout: z.int().min(1000).max(300_000).optional()
        .describe("Execution timeout in milliseconds (default: 30000)"),
    }),
    method: "POST" as const,
    path: "/api/vms/:vm_id/exec",
  },

  stop_vm: {
    description: "Stop and destroy a running VM. This is irreversible -- the VM's ephemeral state is lost. Snapshots taken before stopping are preserved.",
    input: z.object({ vm_id: vmId }),
    method: "DELETE" as const,
    path: "/api/vms/:vm_id",
  },

  create_snapshot: {
    description: "Create a named snapshot of a running VM. The snapshot captures the full rootfs state and can be used to spawn new VMs.",
    input: z.object({
      vm_id: vmId,
      name: z.string().min(1).max(128)
        .describe("Unique name for this snapshot"),
      compact: z.boolean().optional()
        .describe("Compact the snapshot to reduce disk usage (slower)"),
    }),
    method: "POST" as const,
    path: "/api/vms/:vm_id/snapshots",
  },

  list_snapshots: {
    description: "List all available snapshots that can be used to spawn VMs.",
    input: z.object({}),
    method: "GET" as const,
    path: "/api/snapshots",
  },

  delete_snapshot: {
    description: "Permanently delete a snapshot by name.",
    input: z.object({
      name: z.string().min(1).describe("Snapshot name to delete"),
    }),
    method: "DELETE" as const,
    path: "/api/snapshots/:name",
  },

  send_message: {
    description: "Send a message to a VM for inter-VM communication or coroutine wake-up.",
    input: z.object({
      vm_id: vmId,
      from_vm_id: z.string().optional()
        .describe("Source VM UUID (or 'external' if from outside)"),
      payload: z.record(z.unknown()).optional()
        .describe("Arbitrary JSON payload to deliver"),
    }),
    method: "POST" as const,
    path: "/api/vms/:vm_id/messages",
  },

  get_connection_ticket: {
    description: "Get an Iroh connection ticket for direct P2P access to a VM's PTY.",
    input: z.object({ vm_id: vmId }),
    method: "GET" as const,
    path: "/api/vms/:vm_id/ticket",
  },

  list_dormant_vms: {
    description: "List VMs that have been snapshotted and stopped but can be restored.",
    input: z.object({}),
    method: "GET" as const,
    path: "/api/dormant",
  },
};
```

This single file is the complete contract. The MCP server reads it, the Elysia proxy uses it for validation, and the Mjolnir Elixir backend satisfies it.

## 6. MVP Implementation (Phase 1)

Phase 1 is a hand-written Elysia app that serves Streamable HTTP MCP, validates inputs via Zod, and proxies to Mjolnir's REST API. No auto-generation yet -- but the tool definitions are already Zod-driven.

### 6.1 Project Structure

```
mjolnir-mcp/
├── package.json
├── tsconfig.json
├── src/
│   ├── index.ts              # Elysia app entry point
│   ├── schemas/
│   │   └── mjolnir.ts        # Zod schemas (as shown in Section 5)
│   ├── mcp/
│   │   ├── server.ts         # MCP server setup + tool registration
│   │   └── proxy.ts          # HTTP proxy to Mjolnir backend
│   └── config.ts             # Environment configuration
└── descriptions/
    └── mjolnir.descriptions.json  # Editable tool descriptions
```

### 6.2 Entry Point

```typescript
// src/index.ts
import { Elysia } from "elysia";
import { mcp } from "elysia-mcp";
import { registerMjolnirTools } from "./mcp/server";

const app = new Elysia()
  .use(
    mcp({
      serverInfo: {
        name: "mjolnir-mcp",
        version: "0.1.0",
      },
      capabilities: {
        tools: { listChanged: false },
      },
      setupServer: async (server) => {
        await registerMjolnirTools(server);
      },
    })
  )
  .listen(3001);

console.log(`Mjolnir MCP server running on http://localhost:${app.server!.port}/mcp`);
```

### 6.3 Tool Registration from Zod Schemas

```typescript
// src/mcp/server.ts
import { z } from "zod";
import { tools } from "../schemas/mjolnir";
import { proxyToMjolnir } from "./proxy";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

export async function registerMjolnirTools(server: McpServer) {
  for (const [toolName, def] of Object.entries(tools)) {
    server.registerTool(
      toolName,
      {
        description: def.description,
        inputSchema: def.input,
      },
      async (args) => {
        try {
          // Zod validation happens automatically via the SDK,
          // but we also validate explicitly for richer error messages
          const validated = def.input.parse(args);

          const result = await proxyToMjolnir(def.method, def.path, validated);

          return {
            content: [
              { type: "text", text: JSON.stringify(result, null, 2) },
            ],
          };
        } catch (e) {
          if (e instanceof z.ZodError) {
            return {
              content: [
                {
                  type: "text",
                  text: `Validation failed:\n${e.issues
                    .map((i) => `  ${i.path.join(".")}: ${i.message}`)
                    .join("\n")}`,
                },
              ],
              isError: true,
            };
          }
          return {
            content: [
              { type: "text", text: `Error: ${(e as Error).message}` },
            ],
            isError: true,
          };
        }
      }
    );
  }
}
```

### 6.4 Proxy Layer

```typescript
// src/mcp/proxy.ts
import { config } from "../config";

export async function proxyToMjolnir(
  method: string,
  pathTemplate: string,
  args: Record<string, unknown>
): Promise<unknown> {
  // Substitute path parameters like :vm_id from args
  let path = pathTemplate;
  const bodyArgs = { ...args };

  for (const [key, value] of Object.entries(args)) {
    const placeholder = `:${key}`;
    if (path.includes(placeholder)) {
      path = path.replace(placeholder, encodeURIComponent(String(value)));
      delete bodyArgs[key];
    }
  }

  const url = `${config.mjolnirBaseUrl}${path}`;

  const fetchOpts: RequestInit = {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(config.mjolnirApiToken
        ? { Authorization: `Bearer ${config.mjolnirApiToken}` }
        : {}),
    },
  };

  // GET/DELETE requests: no body. POST/PUT/PATCH: send body.
  if (method !== "GET" && method !== "DELETE") {
    fetchOpts.body = JSON.stringify(bodyArgs);
  }

  const response = await fetch(url, fetchOpts);
  const data = await response.json();

  if (!response.ok) {
    throw new Error(
      `Mjolnir API error (${response.status}): ${JSON.stringify(data)}`
    );
  }

  return data;
}
```

### 6.5 Configuration

```typescript
// src/config.ts
export const config = {
  mjolnirBaseUrl: process.env.MJOLNIR_URL ?? "http://localhost:4000",
  mjolnirApiToken: process.env.MJOLNIR_API_TOKEN,
  port: parseInt(process.env.MCP_PORT ?? "3001", 10),
};
```

### 6.6 Running It

```bash
cd mjolnir-mcp
bun install
MJOLNIR_URL=http://45.76.77.97:4000 bun run src/index.ts
```

An agent connects to `http://localhost:3001/mcp` via Streamable HTTP, discovers 10 tools, and can spawn VMs, run commands, manage snapshots -- all with Zod-validated inputs and natural-language error messages.

## 7. Phase 2: Zod Schema Ingestion and Auto-Generation

Phase 2 replaces hand-written schema files with automatic extraction from any TypeScript codebase.

### 7.1 Ingestion Pipeline

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  .ts files   │────▶│  ts-morph     │────▶│  Zod AST     │
│  (git repo)  │     │  parse        │     │  extraction   │
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                  │
                              ┌────────────────────┘
                              ▼
                     ┌──────────────────┐     ┌──────────────┐
                     │  Tool Definition  │────▶│  MCP Server   │
                     │  Registry         │     │  (runtime)    │
                     └──────────────────┘     └──────────────┘
```

### 7.2 ts-morph Extraction Strategy

Use `ts-morph` to parse TypeScript source files and find exported Zod schemas:

```typescript
// src/ingester/extract.ts
import { Project, SyntaxKind } from "ts-morph";

interface ExtractedTool {
  name: string;
  exportName: string;
  filePath: string;
  zodSource: string;          // The Zod schema source code
  descriptions: string[];     // .describe() strings found
  surroundingCode: string;    // Context for AI enrichment
}

export function extractZodSchemas(entryPaths: string[]): ExtractedTool[] {
  const project = new Project({ tsConfigFilePath: "tsconfig.json" });
  const tools: ExtractedTool[] = [];

  for (const filePath of entryPaths) {
    const sourceFile = project.addSourceFileAtPath(filePath);

    // Find all exported variable declarations whose initializer
    // starts with z.object(
    const exports = sourceFile.getExportedDeclarations();

    for (const [name, declarations] of exports) {
      for (const decl of declarations) {
        if (decl.getKind() === SyntaxKind.VariableDeclaration) {
          const initializer = decl.getChildrenOfKind(
            SyntaxKind.CallExpression
          );
          const text = decl.getText();
          if (text.includes("z.object(")) {
            tools.push({
              name: camelToSnake(name),
              exportName: name,
              filePath,
              zodSource: text,
              descriptions: extractDescribeCalls(text),
              surroundingCode: extractContext(sourceFile, decl),
            });
          }
        }
      }
    }
  }

  return tools;
}
```

### 7.3 Dynamic Import for Runtime Schemas

After extraction, we dynamically import the actual Zod schemas for runtime validation:

```typescript
// src/ingester/loader.ts
export async function loadZodSchemas(
  filePath: string
): Promise<Record<string, z.ZodType>> {
  const module = await import(filePath);
  const schemas: Record<string, z.ZodType> = {};

  for (const [key, value] of Object.entries(module)) {
    if (value instanceof z.ZodType) {
      schemas[key] = value;
    }
  }

  return schemas;
}
```

## 8. Phase 3: AI-Powered Description Enrichment

Phase 3 adds an AI pass that reads the extracted schemas plus surrounding source code and generates rich, agent-friendly descriptions.

### 8.1 Enrichment Flow

```typescript
// src/enricher/enrich.ts
interface ToolDescriptions {
  [toolName: string]: {
    description: string;         // Tool-level description
    paramDescriptions: {         // Per-parameter descriptions
      [param: string]: string;
    };
    usageNotes: string;          // Optional usage guidance for agents
    generatedAt: string;         // ISO timestamp
    model: string;               // Which AI model generated this
  };
}

export async function enrichDescriptions(
  tools: ExtractedTool[]
): Promise<ToolDescriptions> {
  const result: ToolDescriptions = {};

  for (const tool of tools) {
    const prompt = `Given this Zod schema for an API tool called "${tool.name}":

\`\`\`typescript
${tool.zodSource}
\`\`\`

And this surrounding code context:
\`\`\`typescript
${tool.surroundingCode}
\`\`\`

Generate:
1. A one-sentence description of what this tool does (for an AI agent)
2. For each parameter, a description that includes type, constraints, and purpose
3. Any usage notes (e.g., "call list_vms first to get vm_id values")

Return as JSON.`;

    const response = await callAI(prompt);
    result[tool.name] = JSON.parse(response);
  }

  return result;
}
```

### 8.2 Editable Description Files

Enriched descriptions are written to `descriptions/<project>.descriptions.json`. This file is version-controlled and manually editable:

```json
{
  "spawn_vm": {
    "description": "Create and boot a new Cloud Hypervisor microVM. The VM starts from a base image or named snapshot and is ready for commands within ~2 seconds.",
    "paramDescriptions": {
      "base_image": "Name of the root filesystem template (e.g., 'ubuntu-24.04'). Defaults to the server's configured default.",
      "memory_mb": "RAM allocation in megabytes. Must be between 128 and 8192. Default: 512.",
      "vcpus": "Number of virtual CPU cores. Must be between 1 and 8. Default: 1."
    },
    "usageNotes": "After spawning, use exec_in_vm to run commands. The returned vm_id is a UUID you will need for all subsequent operations on this VM.",
    "generatedAt": "2026-02-26T20:00:00Z",
    "model": "claude-sonnet-4-20250514"
  }
}
```

The description file is merged at startup: if a human-edited description exists, it takes precedence over AI-generated ones. Re-running the enricher only fills in missing entries.

## 9. Phase 4: The MCP Description Editor

A lightweight TUI (using `ink` or `blessed`) or web UI that:

- Lists all discovered tools with their current descriptions
- Allows inline editing of tool descriptions and parameter descriptions
- Provides a "re-enrich" button that re-runs the AI pass for a specific tool
- Shows a live preview of how the tool appears to agents (the `tools/list` response)
- Diffs changes against the last committed version

This is a quality-of-life feature and is not required for the core pipeline to function.

## 10. Phase 5: Universal Mode

In universal mode, the generator accepts any git repository URL or local path:

```bash
# Point at a local project
bunx universal-mcp-gen serve ./my-api/src/schemas/

# Point at a git repo
bunx universal-mcp-gen serve https://github.com/org/repo --glob "src/**/*.schema.ts"

# Generate without serving (output tool definitions to JSON)
bunx universal-mcp-gen generate ./schemas/ --output tools.json
```

The CLI automates: clone (if remote) -> scan for Zod exports -> extract -> convert to JSON Schema -> optionally enrich -> serve MCP endpoint.

## 11. Implementation Plan

### Phase 1 -- MVP Sidecar (1-2 days)

| Task | Detail |
|------|--------|
| Scaffold `mjolnir-mcp` Bun project | `bun init`, add `elysia`, `elysia-mcp`, `zod` |
| Write `schemas/mjolnir.ts` | Zod schemas for all 10 Mjolnir API endpoints |
| Implement `mcp/server.ts` | Register tools from schema map, wire Zod inputSchema |
| Implement `mcp/proxy.ts` | Path param substitution, auth header forwarding |
| Test with MCP Inspector | `npx @modelcontextprotocol/inspector` against running server |
| Deploy alongside Mjolnir | Systemd unit or Docker container on the same host |

**Done when**: An agent can connect to `http://host:3001/mcp`, call `tools/list`, and successfully `spawn_vm` -> `exec_in_vm` -> `stop_vm`.

### Phase 2 -- Auto-Generation (3-5 days)

| Task | Detail |
|------|--------|
| Add `ts-morph` ingester | Parse .ts files, find exported Zod schemas |
| Build tool definition compiler | Zod AST -> tool name + inputSchema + description |
| Dynamic import loader | Import Zod schemas at runtime for validation |
| File watcher | Re-ingest on file changes, emit `tools/list_changed` |
| CLI interface | `bunx universal-mcp-gen serve <path>` |

### Phase 3 -- AI Enrichment (2-3 days)

| Task | Detail |
|------|--------|
| Enrichment prompt engineering | Craft prompts that produce good tool descriptions |
| Description file format | JSON with merge semantics (human edits preserved) |
| `enrich` CLI command | One-shot enrichment of all tools |
| Integration into serve pipeline | Enrich on first run, cache descriptions |

### Phase 4 -- Editor (3-5 days)

| Task | Detail |
|------|--------|
| TUI or web UI | Browse/edit tool descriptions |
| Live preview | Show `tools/list` response as agent would see it |
| Re-enrich action | Re-run AI on selected tools |

### Phase 5 -- Universal (2-3 days)

| Task | Detail |
|------|--------|
| Git clone support | Clone remote repos to temp dir |
| Glob scanning | Find Zod schemas across arbitrary codebases |
| `generate` command | Output tool definitions without serving |
| NPM package | Publish as `universal-mcp-gen` |

## 12. Dependencies

| Package | Purpose | Version |
|---------|---------|---------|
| `elysia` | HTTP framework on Bun | ^1.2 |
| `elysia-mcp` | MCP plugin for Elysia (Streamable HTTP, session management) | ^0.1 |
| `zod` | Schema definition and runtime validation | ^3.24 / v4 |
| `@modelcontextprotocol/sdk` | MCP types and server primitives (used by elysia-mcp) | ^1.12 |
| `ts-morph` | TypeScript AST parsing (Phase 2+) | ^25.0 |

## 13. Key Design Decisions

**Why Elysia/Bun, not Express/Node?** Bun's startup time is under 50ms. Elysia's type inference means the proxy layer gets end-to-end type safety. The `elysia-mcp` plugin provides Streamable HTTP, session management, and JSON-RPC handling out of the box.

**Why a sidecar, not embedded in Elixir?** MCP is a TypeScript/JSON Schema ecosystem. Zod is TypeScript-native. Building the MCP server in TypeScript means we get the best tooling, the best type inference, and the most natural mapping from Zod to JSON Schema. Mjolnir's Elixir backend does not need to know MCP exists -- it just serves its REST API.

**Why Zod, not OpenAPI?** OpenAPI is verbose and requires a separate specification file. Zod schemas live in code, co-located with the types they describe. They are both the specification AND the runtime validator. OpenAPI describes; Zod enforces.

**Why editable descriptions?** AI-generated descriptions are a starting point. Human tuning of how tools appear to agents is critical for production quality. A tool called `exec_in_vm` might need usage guidance like "always check VM status first" that no amount of code analysis can infer. The description file is the human-in-the-loop control surface.

## 14. Security Considerations

- The MCP sidecar authenticates to Mjolnir's backend using a bearer token (`MJOLNIR_API_TOKEN`)
- The MCP endpoint itself should be protected if exposed beyond localhost (TLS, auth middleware via Elysia's `authentication` config option)
- Zod validation at the MCP layer rejects malformed inputs before they reach the backend
- Tool annotations mark destructive operations (`stop_vm`, `delete_snapshot`) so clients can prompt for confirmation

## 15. References

- [MCP Specification -- Tools](https://modelcontextprotocol.io/specification/draft/server/tools)
- [MCP Streamable HTTP Transport](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)
- [MCP TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
- [elysia-mcp Plugin](https://github.com/kerlos/elysia-mcp)
- [Zod JSON Schema Generation](https://zod.dev/json-schema)
- [zod-to-json-schema (deprecated, reference only)](https://www.npmjs.com/package/zod-to-json-schema)
- [ts-morph](https://ts-morph.com)
- [Elysia Framework](https://elysiajs.com)

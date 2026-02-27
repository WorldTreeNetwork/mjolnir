# Universal MCP Generator

**Status**: Deferred — Future standalone project
**Date**: 2026-02-26
**Original spec**: `universal-mcp-generator-spec-original.md` (same directory)

## The Idea

Every REST API needs an MCP server now. Hand-coding tool definitions is tedious, drifts from the actual API, and produces inconsistent descriptions. The Universal MCP Generator reads typed schema files (Zod, JSON Schema, or OpenAPI) and produces a fully functional MCP server — complete with validation, proxy routing, and agent-friendly descriptions.

This is a standalone open-source tool, not part of Mjolnir's core. Mjolnir's own MCP server is Elixir-native (see `docs/plans/initiatives/mjolnir-mcp-server.md`). The generator is for everyone else.

## Core Mechanics

### Input: Zod Schemas as the Anchor

Zod remains the ideal bridge between typed API contracts and MCP tool definitions:

- **Structure** → JSON Schema for `inputSchema` via `z.toJSONSchema()`
- **Constraints** → Validation rules that become actionable agent feedback
- **Documentation** → `.describe()` annotations that become tool/param descriptions
- **Runtime validation** → `schema.parse()` catches bad agent inputs with useful errors

A single Zod file like this:

```typescript
export const tools = {
  create_user: {
    description: "Create a new user account",
    input: z.object({
      email: z.string().email().describe("User's email address"),
      role: z.enum(["admin", "member"]).describe("Account role"),
    }),
    method: "POST" as const,
    path: "/api/users",
  },
};
```

...produces a complete MCP tool with input validation, JSON Schema, descriptions, and a proxy route. No code generation step — the schema IS the server definition.

### Pipeline

```
Source schemas → Ingest → Transform → (optional) Enrich → Serve
```

1. **Ingest**: Read `.ts` files, find exported Zod schemas via `ts-morph` AST parsing or dynamic import
2. **Transform**: Convert Zod → JSON Schema for MCP `inputSchema`, extract `.describe()` for tool descriptions
3. **Enrich** (optional): AI pass that reads schemas + surrounding code context and generates richer descriptions
4. **Serve**: Start a Streamable HTTP MCP server with all discovered tools wired to a configurable backend proxy

### CLI

```bash
# Serve MCP from local schemas
bunx universal-mcp-gen serve ./src/schemas/ --backend http://localhost:4000

# Serve from a git repo
bunx universal-mcp-gen serve https://github.com/org/api --glob "src/**/*.schema.ts"

# Generate tool definitions to JSON (no server)
bunx universal-mcp-gen generate ./schemas/ --output tools.json

# Enrich descriptions with AI
bunx universal-mcp-gen enrich ./schemas/ --model claude-sonnet
```

## The Bigger Vision: MCP Sets and aspects.sh

### MCP Sets

An MCP Set is a curated, portable collection of MCP tool definitions that an agent can install as a unit. Think npm packages but for agent capabilities:

```json
{
  "name": "mjolnir-vm-ops",
  "version": "1.0.0",
  "description": "Firecracker microVM lifecycle management",
  "tools": ["spawn_vm", "exec", "stop_vm", "create_snapshot", ...],
  "backend": {
    "type": "http",
    "url_env": "MJOLNIR_URL"
  },
  "schema_source": "https://github.com/mjolnir/mjolnir-mcp/schemas/mjolnir.ts"
}
```

An MCP Set bundles:
- Tool definitions with schemas and descriptions
- Backend routing configuration
- Auth requirements
- Composability rules (which sets play well together)

### aspects.sh Integration

[aspects.sh](https://aspects.sh) is "The Open Aspect Registry" — reusable AI personalities/capabilities for agents. The natural extension: aspects.sh becomes a registry that serves not just personality aspects but also **capability aspects** backed by MCP Sets.

The upgrade path for aspects.sh:

1. **Schema hosting**: aspects.sh stores MCP Set definitions alongside aspect personalities. An aspect can declare the MCP tools it needs to function. An "infrastructure engineer" aspect might bundle the `mjolnir-vm-ops` MCP Set.

2. **One-command install**: `npx @morphist/aspects add mjolnir-vm-ops` installs both the personality aspect AND the MCP Set, configuring the agent's MCP client to connect to the right backend.

3. **Discovery**: Agents browse aspects.sh to find capabilities. "I need to manage VMs" → discovers `mjolnir-vm-ops` set → installs it → can now spawn VMs. Self-service capability acquisition.

4. **Composition**: Aspects compose. A "full-stack deployer" aspect might compose `mjolnir-vm-ops` + `docker-registry` + `dns-manager` MCP Sets into a unified capability surface.

### Trading Card Aesthetic

Each MCP Set and each tool within it gets a generated visual identity — a trading card. This serves both UX and discoverability:

```
┌─────────────────────────────┐
│  ⚡ SPAWN VM                │
│  ─────────────────────────  │
│                             │
│   [Generated art:           │
│    lightning striking       │
│    a crystalline server     │
│    node, digital forge      │
│    aesthetic]               │
│                             │
│  ─────────────────────────  │
│  Firecracker microVM        │
│  Boot: ~2s | RAM: 128-8192  │
│                             │
│  SET: mjolnir-vm-ops        │
│  RARITY: ◆ Core             │
│  TYPE: Infrastructure       │
│                             │
│  "The hammer falls where    │
│   you choose to swing it."  │
└─────────────────────────────┘
```

**Generation approach**: Each tool's card art is generated from its schema metadata — name, description, parameter types, and the set it belongs to feed into an image generation prompt. The aesthetic is consistent within a set (same color palette, frame style, iconography) but each tool gets unique art.

**Card properties**:
- **Set**: Which MCP Set this tool belongs to (e.g. `mjolnir-vm-ops`)
- **Rarity**: Core (essential), Uncommon (specialized), Rare (advanced/dangerous)
- **Type**: Infrastructure, Data, Communication, Orchestration, etc.
- **Stats**: Latency, complexity, destructiveness (from schema annotations)
- **Flavor text**: From the tool's `usageNotes` or AI-enriched descriptions

**Why this matters**: Agent capability registries are boring lists today. The trading card metaphor makes tool discovery visceral, memorable, and shareable. A dev showing off their agent's "deck" of capabilities is more engaging than a JSON config file. It's also a natural fit for the aspects.sh registry UI.

### Set Examples

| Set Name | Tools | Theme |
|---|---|---|
| `mjolnir-vm-ops` | spawn, exec, stop, snapshot, restore, list | Forge / lightning / metal |
| `mjolnir-mesh` | join_mesh, get_peers, broadcast, pipe | Neural / constellation / wiring |
| `mjolnir-dormant` | list_dormant, deliver_message, wake | Sleep / crystals / awakening |
| `github-repo-ops` | create_repo, list_issues, create_pr, merge | Octopus / ink / tentacles |
| `postgres-ops` | query, migrate, backup, restore | Elephant / stone / architecture |

Each set has a visual identity. Tools within a set share the palette but have individual art. Collecting sets = building your agent's capability deck.

## Technical Considerations for Later

### Ingestion Improvements

The original spec's `text.includes("z.object(")` approach for finding Zod schemas is brittle. Better approaches:

1. **Convention-based**: Files matching `*.schema.ts` or `*.tools.ts` are scanned. Exported objects with `input` (ZodType) + `method` + `path` properties are tools. No AST heuristics needed.

2. **Dynamic import only**: Skip `ts-morph` entirely. `await import(file)` and inspect exports at runtime. If a value is a `z.ZodObject`, it's a schema. Simpler, more reliable, but requires the schemas to be valid runnable TypeScript.

3. **Decorator/marker pattern**: A `@mcpTool` decorator or `asTool()` wrapper function explicitly marks exports as MCP tools. Zero ambiguity.

### Schema Format Expansion

Beyond Zod:
- **JSON Schema files** (`.schema.json`): Direct use as `inputSchema`, descriptions from `description` fields
- **OpenAPI specs**: Extract operations → tools, request bodies → input schemas. Lots of existing tooling here.
- **GraphQL schemas**: Mutations → tools, queries → resources. Natural mapping.
- **Protobuf**: gRPC service definitions → tools. More exotic but relevant for infrastructure APIs.

### Description Quality

The AI enrichment pass works best when it has access to:
- The schema itself (structure, constraints)
- Surrounding code (what the handler does)
- API documentation (if available)
- Example requests/responses (from tests or docs)

Ranking of description quality: human-written > AI-enriched-from-rich-context > AI-enriched-from-schema-only > schema `.describe()` alone > auto-generated-from-field-names.

The editable descriptions file (`*.descriptions.json`) with merge semantics (human edits take precedence) is the right architecture regardless.

## Relationship to Mjolnir

This project is **decoupled** from Mjolnir:
- Mjolnir's MCP server is Elixir-native, lives in the Mjolnir repo, talks directly to OTP
- The Universal MCP Generator is a TypeScript/Bun tool that works with any REST API
- Mjolnir could be one of the first "MCP Sets" published through this system
- The generator could eventually generate the Zod schema contract that a native MCP server (in any language) implements against — schema as interface

## Timeline

Not now. This is a post-Phase-1 project. Mjolnir's own MCP server ships first, proving the tool surface. The generator crystallizes later when:
1. We've built 2-3 MCP servers by hand and understand the patterns
2. aspects.sh has enough traction to justify the registry integration
3. The trading card generation pipeline has a proof of concept

See the original detailed spec in `universal-mcp-generator-spec-original.md` for the phased implementation plan (Phases 2-5).

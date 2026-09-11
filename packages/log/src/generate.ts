/** Pino envelope `createLogger` stamps (`name` + `base.schema/app`; pino adds level/time/msg/err). */
export const PINO_ENVELOPE = {
  type: "object",
  properties: {
    level: { type: "number" },
    time: { type: "string" },
    schema: { type: "string" },
    app: { type: "string" },
    name: { type: "string" },
    msg: { type: "string" },
    err: { type: "object" },
  },
  required: ["level", "time", "schema", "app", "name"],
} as const;

export const ENVELOPE_KEYS = Object.keys(PINO_ENVELOPE.properties) as Array<
  keyof typeof PINO_ENVELOPE.properties
>;

export const ENVELOPE_REQUIRED = [...PINO_ENVELOPE.required];

const ENVELOPE_KEY_SET = new Set<string>(ENVELOPE_KEYS);
const ALLOWED_ROOT_KEYS = new Set(["$id", "type", "properties", "required", "additionalProperties"]);
const FORBIDDEN_KEYS = new Set(["enum", "items", "$ref", "anyOf", "oneOf", "allOf"]);
const ALLOWED_TYPES = new Set(["string", "number", "boolean", "object"]);

export class GenerateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "GenerateError";
  }
}

export type EnvelopeRecord = {
  level: number;
  time: string;
  schema: string;
  app: string;
  name: string;
  msg?: string;
  err?: Record<string, unknown>;
};

type TypeName = "string" | "number" | "boolean" | "object";

export type TsType<T extends { type?: string }> = T["type"] extends "string"
  ? string
  : T["type"] extends "number"
    ? number
    : T["type"] extends "boolean"
      ? boolean
      : T["type"] extends "object"
        ? Record<string, unknown>
        : unknown;

type PropMap = Record<string, { type?: string }>;

export type AppFields<T extends { properties?: PropMap; required?: readonly string[] }> =
  T["properties"] extends PropMap
    ? {
        [K in Extract<keyof T["properties"], RequiredKey<T>>]: TsType<T["properties"][K]>;
      } & {
        [K in Exclude<keyof T["properties"], RequiredKey<T>>]?: TsType<T["properties"][K]>;
      }
    : {};

type RequiredKey<T> = T extends { required?: readonly (infer R)[] }
  ? R extends string
    ? R
    : never
  : never;

/** Field type derived from an app const schema object (no parallel hand-written type). */
export type LogFromSchema<T extends { properties?: PropMap; required?: readonly string[] }> =
  EnvelopeRecord & AppFields<T>;

export type GeneratedSchema = {
  $id: string;
  type: "object";
  properties: Record<string, { type: TypeName }>;
  required: string[];
  additionalProperties: false;
};

/**
 * Merge the library envelope with an app const. Apps supply only their fields.
 * Fails on envelope-key collision, nested properties, and closed-world violations.
 */
export function generateSchema(appConst: unknown): GeneratedSchema {
  if (typeof appConst !== "object" || appConst === null || Array.isArray(appConst)) {
    throw new GenerateError("app schema const must be an object");
  }
  const app = appConst as Record<string, unknown>;

  for (const key of Object.keys(app)) {
    if (FORBIDDEN_KEYS.has(key)) {
      throw new GenerateError(`${key} is not in the closed-world subset`);
    }
    if (!ALLOWED_ROOT_KEYS.has(key)) {
      throw new GenerateError(`unsupported schema key ${key}`);
    }
  }

  const id = app.$id;
  if (typeof id !== "string" || id.length === 0) {
    throw new GenerateError("$id is required");
  }
  if (app.type !== undefined && app.type !== "object") {
    throw new GenerateError("schema type must be object");
  }
  if (app.additionalProperties !== undefined && app.additionalProperties !== false) {
    throw new GenerateError("additionalProperties must be false or omitted");
  }

  const appProps = app.properties;
  if (appProps !== undefined && (typeof appProps !== "object" || appProps === null || Array.isArray(appProps))) {
    throw new GenerateError("properties must be an object");
  }
  const props = (appProps ?? {}) as Record<string, unknown>;

  const appRequired = app.required;
  if (appRequired !== undefined && !Array.isArray(appRequired)) {
    throw new GenerateError("required must be an array of strings");
  }
  const requiredKeys = (appRequired ?? []) as unknown[];
  for (const key of requiredKeys) {
    if (typeof key !== "string") {
      throw new GenerateError("required entries must be strings");
    }
    if (ENVELOPE_KEY_SET.has(key)) {
      throw new GenerateError(`required key collides with envelope key ${key}`);
    }
    if (!(key in props)) {
      throw new GenerateError(`required key ${key} is missing from properties`);
    }
  }

  const mergedProps: Record<string, { type: TypeName }> = {};
  for (const [key, spec] of Object.entries(PINO_ENVELOPE.properties)) {
    mergedProps[key] = { type: spec.type };
  }
  for (const [key, spec] of Object.entries(props)) {
    if (ENVELOPE_KEY_SET.has(key)) {
      throw new GenerateError(`app key collides with envelope key ${key}`);
    }
    mergedProps[key] = checkProperty(key, spec);
  }

  return {
    $id: id,
    type: "object",
    properties: mergedProps,
    required: [...ENVELOPE_REQUIRED, ...requiredKeys.filter((k): k is string => typeof k === "string")],
    additionalProperties: false,
  };
}

function checkProperty(name: string, spec: unknown): { type: TypeName } {
  if (typeof spec !== "object" || spec === null || Array.isArray(spec)) {
    throw new GenerateError(`property ${name} must be an object`);
  }
  const s = spec as Record<string, unknown>;
  if ("properties" in s) {
    throw new GenerateError(`nested properties at ${name}`);
  }
  for (const key of Object.keys(s)) {
    if (FORBIDDEN_KEYS.has(key)) {
      throw new GenerateError(`${key} is not in the closed-world subset`);
    }
    if (key !== "type") {
      throw new GenerateError(`unsupported key ${key} on property ${name}`);
    }
  }
  const t = s.type;
  if (typeof t !== "string") {
    throw new GenerateError(`property ${name} needs a type`);
  }
  if (t === "array") {
    throw new GenerateError("type array is not in the closed-world subset");
  }
  if (!ALLOWED_TYPES.has(t)) {
    throw new GenerateError(`unknown type ${t}`);
  }
  return { type: t as TypeName };
}

/** Stable key order, 2-space indent, trailing newline. */
export function canonicalJson(value: unknown): string {
  return `${JSON.stringify(sortKeys(value), null, 2)}\n`;
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as object).sort()) {
      out[key] = sortKeys((value as Record<string, unknown>)[key]);
    }
    return out;
  }
  return value;
}

/** Canonical bytes, or parsed-equal after canonicalizing both sides. */
export function schemaMatches(committedText: string, generated: unknown): boolean {
  const want = canonicalJson(generated);
  if (committedText === want) return true;
  try {
    return canonicalJson(JSON.parse(committedText)) === want;
  } catch {
    return false;
  }
}

export function assertSchemaMatches(committedText: string, generated: unknown): void {
  if (!schemaMatches(committedText, generated)) {
    throw new GenerateError("schema.json differs from generated output");
  }
}

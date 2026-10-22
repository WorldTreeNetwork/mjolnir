export type JsonSchema = {
  $id?: string;
  type?: string;
  properties?: Record<string, JsonSchema>;
  required?: string[];
  additionalProperties?: boolean;
};

export type ValidationIssue = { path: string; message: string };

/** Unknown fields are kept on the wire; they are issues, not errors that drop the record. */
export function validateRecord(
  rec: Record<string, unknown>,
  schema: JsonSchema,
): ValidationIssue[] {
  const issues: ValidationIssue[] = [];
  const props = schema.properties ?? {};
  for (const key of schema.required ?? []) {
    if (!(key in rec)) issues.push({ path: key, message: "required" });
  }
  for (const [key, spec] of Object.entries(props)) {
    if (!(key in rec) || rec[key] === undefined) continue;
    const got = rec[key];
    const want = spec.type;
    if (!want) continue;
    if (want !== "string" && want !== "number" && want !== "boolean" && want !== "object") {
      issues.push({ path: key, message: `unknown type ${want}` });
      continue;
    }
    const ok =
      want === "string"
        ? typeof got === "string"
        : want === "number"
          ? typeof got === "number"
          : want === "boolean"
            ? typeof got === "boolean"
            : typeof got === "object" && got !== null && !Array.isArray(got);
    if (!ok) issues.push({ path: key, message: `expected ${want}` });
  }
  if (schema.additionalProperties === false) {
    for (const key of Object.keys(rec)) {
      if (!(key in props)) issues.push({ path: key, message: "unknown field" });
    }
  }
  return issues;
}

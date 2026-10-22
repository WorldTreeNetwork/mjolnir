import { describe, expect, test } from "bun:test";
import { validateRecord } from "./schema.ts";

const schema = {
  $id: "myscape/v1",
  type: "object",
  properties: {
    schema: { type: "string" },
    msg: { type: "string" },
    url: { type: "string" },
    status: { type: "number" },
  },
  required: ["schema"],
  additionalProperties: false,
};

describe("validateRecord", () => {
  test("flags missing required and type mismatch", () => {
    expect(validateRecord({ url: "/x" }, schema).map((i) => i.path)).toContain("schema");
    expect(
      validateRecord({ schema: "myscape/v1", status: "nope" }, schema).find((i) => i.path === "status")
        ?.message,
    ).toBe("expected number");
  });

  test("unknown fields are issues, record still usable", () => {
    const rec = { schema: "myscape/v1", extra: true };
    const issues = validateRecord(rec, schema);
    expect(issues).toEqual([{ path: "extra", message: "unknown field" }]);
    expect(rec.extra).toBe(true);
  });

  test("unknown JSON Schema type is an issue, not a pass", () => {
    const withArray = {
      ...schema,
      properties: { ...schema.properties, tags: { type: "array" } },
    };
    const issues = validateRecord({ schema: "myscape/v1", tags: ["a"] }, withArray);
    expect(issues.find((i) => i.path === "tags")?.message).toBe("unknown type array");

    const withInteger = {
      ...schema,
      properties: { ...schema.properties, n: { type: "integer" } },
    };
    expect(validateRecord({ schema: "myscape/v1", n: 1 }, withInteger).find((i) => i.path === "n")?.message).toBe(
      "unknown type integer",
    );
  });
});

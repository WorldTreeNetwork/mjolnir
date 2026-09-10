import { describe, expect, test } from "bun:test";
import { renderLine, wantsColor } from "./pretty.ts";

describe("pretty", () => {
  test("NO_COLOR and plain disable color", () => {
    expect(wantsColor({ plain: true, isTTY: true, noColor: undefined })).toBe(false);
    expect(wantsColor({ isTTY: true, noColor: "1" })).toBe(false);
    expect(wantsColor({ isTTY: false })).toBe(false);
    expect(wantsColor({ isTTY: true, noColor: undefined })).toBe(true);
  });

  test("plain rendering has no ANSI", () => {
    const line = renderLine(
      { level: 30, time: "t", msg: "hi", schema: "s", n: 3 },
      false,
    );
    expect(line).not.toMatch(/\x1b/);
    expect(line).toContain("INFO");
    expect(line).toContain("hi");
    expect(line).toContain("schema=");
  });

  test("color rendering uses escapes for types", () => {
    const line = renderLine({ level: 50, msg: "boom", n: 1 }, true);
    expect(line).toMatch(/\x1b\[/);
    expect(line).toContain("ERROR");
  });
});

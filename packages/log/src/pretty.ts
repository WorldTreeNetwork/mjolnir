import { Writable } from "node:stream";

const C = {
  reset: "\x1b[0m",
  dim: "\x1b[2m",
  red: "\x1b[31m",
  yellow: "\x1b[33m",
  green: "\x1b[32m",
  cyan: "\x1b[36m",
  magenta: "\x1b[35m",
  white: "\x1b[37m",
};

function paint(color: string, s: string, colorize: boolean): string {
  if (!colorize) return s;
  return `${color}${s}${C.reset}`;
}

function colorFor(value: unknown): string {
  const t = typeof value;
  if (t === "number") return C.cyan;
  if (t === "boolean") return C.magenta;
  if (value === null) return C.dim;
  if (t === "string") return C.green;
  return C.white;
}

export function wantsColor(opts: {
  plain?: boolean;
  isTTY?: boolean;
  noColor?: string | undefined;
}): boolean {
  if (opts.plain) return false;
  if (opts.noColor !== undefined && opts.noColor !== "") return false;
  return Boolean(opts.isTTY);
}

export function renderLine(rec: Record<string, unknown>, colorize: boolean): string {
  const level = rec.level;
  const lvl =
    level === 60
      ? "fatal"
      : level === 50
        ? "error"
        : level === 40
          ? "warn"
          : level === 30
            ? "info"
            : level === 20
              ? "debug"
              : "trace";
  const lvlColor =
    lvl === "error" || lvl === "fatal"
      ? C.red
      : lvl === "warn"
        ? C.yellow
        : C.cyan;
  const time = rec.time != null ? String(rec.time) : "";
  const msg = rec.msg != null ? String(rec.msg) : "";
  const skip = new Set(["level", "time", "msg", "pid", "hostname"]);
  const rest: string[] = [];
  for (const [k, v] of Object.entries(rec)) {
    if (skip.has(k)) continue;
    rest.push(
      `${paint(C.dim, k + "=", colorize)}${paint(colorFor(v), JSON.stringify(v), colorize)}`,
    );
  }
  return [
    paint(C.dim, time, colorize),
    paint(lvlColor, lvl.toUpperCase(), colorize),
    msg,
    rest.join(" "),
  ]
    .filter(Boolean)
    .join(" ");
}

export function prettyWritable(colorize: boolean): Writable {
  return new Writable({
    write(chunk, _enc, cb) {
      const line = String(chunk).trimEnd();
      if (!line) {
        cb();
        return;
      }
      try {
        const rec = JSON.parse(line) as Record<string, unknown>;
        process.stdout.write(renderLine(rec, colorize) + "\n");
      } catch {
        process.stdout.write(line + "\n");
      }
      cb();
    },
  });
}

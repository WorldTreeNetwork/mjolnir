import pino, { type Logger, type StreamEntry } from "pino";
import { prettyWritable, wantsColor } from "./pretty.ts";
import { syslogWritable, type SyslogTarget } from "./syslog.ts";

export type { SyslogTarget };

export type CreateLoggerOptions = {
  name: string;
  /** Schema identifier stamped on every record. */
  schema: string;
  stdout?: boolean;
  plain?: boolean;
  /** UDP target. Unset → stdout only. */
  syslog?: SyslogTarget;
};

export function createLogger(opts: CreateLoggerOptions): Logger {
  const stdoutOn = opts.stdout !== false;
  const colorize = wantsColor({
    plain: opts.plain,
    isTTY: Boolean(process.stdout.isTTY),
    noColor: process.env.NO_COLOR,
  });
  const streams: StreamEntry[] = [];
  if (stdoutOn) {
    streams.push({
      stream: colorize ? prettyWritable(true) : pino.destination(1),
    });
  }
  if (opts.syslog) {
    streams.push({ stream: syslogWritable(opts.syslog, opts.name) });
  }
  if (streams.length === 0) {
    streams.push({ stream: pino.destination(1) });
  }
  return pino(
    {
      name: opts.name,
      base: { schema: opts.schema, app: opts.name },
      timestamp: pino.stdTimeFunctions.isoTime,
    },
    pino.multistream(streams),
  );
}

export { format3164, priFromPino, rfc3164Stamp } from "./syslog.ts";
export { renderLine, wantsColor } from "./pretty.ts";

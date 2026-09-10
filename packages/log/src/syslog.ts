import { createSocket, type Socket } from "node:dgram";
import { hostname as osHostname } from "node:os";
import { Writable } from "node:stream";

const MONTHS = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
];

/** user facility (1) * 8 + syslog severity */
export function priFromPino(level: number): number {
  const sev =
    level >= 60 ? 2 : level >= 50 ? 3 : level >= 40 ? 4 : level >= 30 ? 6 : 7;
  return 8 + sev;
}

export function rfc3164Stamp(d = new Date()): string {
  const mon = MONTHS[d.getMonth()];
  const day = String(d.getDate()).padStart(2, " ");
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  const ss = String(d.getSeconds()).padStart(2, "0");
  return `${mon} ${day} ${hh}:${mm}:${ss}`;
}

export function format3164(opts: {
  pri: number;
  hostname: string;
  tag: string;
  msg: string;
  at?: Date;
}): string {
  const clean = opts.msg.replace(/\x1b\[[0-9;]*m/g, "").replace(/\n/g, " ");
  return `<${opts.pri}>${rfc3164Stamp(opts.at)} ${opts.hostname} ${opts.tag}: ${clean}`;
}

export type SyslogTarget = { host: string; port: number };

export function syslogWritable(
  target: SyslogTarget,
  tag: string,
  hostname = osHostname(),
): Writable {
  const sock: Socket = createSocket("udp4");
  return new Writable({
    write(chunk, _enc, cb) {
      const line = String(chunk).trimEnd();
      if (!line) {
        cb();
        return;
      }
      let level = 30;
      try {
        const rec = JSON.parse(line) as { level?: number };
        if (typeof rec.level === "number") level = rec.level;
      } catch {
        /* raw line */
      }
      const datagram = format3164({
        pri: priFromPino(level),
        hostname,
        tag,
        msg: line,
      });
      const buf = Buffer.from(datagram, "utf8");
      sock.send(buf, target.port, target.host, (err) => cb(err ?? undefined));
    },
    final(cb) {
      sock.close();
      cb();
    },
  });
}

//! Host side of one Reflect QUIC exchange.
//! Args: ip port budget pin_hex program_path correlation_hex
//! Stdout is the reply payload on transport status 0.
//! Exit 0 status 0, 5 status 2, 6 status 3, 3 pin refused, 4 timeout.

const std = @import("std");
const quic = @import("quic.zig");

extern fn socket(domain: c_int, kind: c_int, proto: c_int) c_int;
extern fn sendto(fd: c_int, buf: [*]const u8, n: usize, flags: c_int, addr: *const Sock, len: u32) isize;
extern fn recvfrom(fd: c_int, buf: [*]u8, n: usize, flags: c_int, addr: *Sock, len: *u32) isize;
extern fn bind(fd: c_int, addr: *const Sock, len: u32) c_int;
extern fn clock_gettime(clk: c_int, ts: *Time) c_int;
extern fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern fn open(path: [*:0]const u8, flags: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn getrandom(buf: [*]u8, len: usize, flags: c_uint) isize;

const Sock = extern struct { family: u16, port: u16, addr: u32, zero: [8]u8 };
const Time = extern struct { sec: i64, nsec: i64 };

var rng: u64 = 0;

fn rnd() u64 {
    rng = rng *% 0x9E3779B97F4A7C15 +% 1;
    return rng;
}

fn now() u64 {
    var t: Time = undefined;
    _ = clock_gettime(1, &t);
    return @as(u64, @intCast(t.sec)) * 1_000_000_000 + @as(u64, @intCast(t.nsec));
}

fn ip4(s: []const u8) ?u32 {
    var n: u32 = 0;
    var acc: u32 = 0;
    var parts: u32 = 0;
    for (s) |c| {
        if (c == '.') {
            if (parts == 3) return null;
            n = (n << 8) | acc;
            acc = 0;
            parts += 1;
        } else if (c >= '0' and c <= '9') acc = acc * 10 + (c - '0') else return null;
    }
    if (parts != 3) return null;
    return (n << 8) | acc;
}

fn hexByte(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn parseHex(s: []const u8, out: []u8) bool {
    if (s.len != out.len * 2) return false;
    for (out, 0..) |*b, i| {
        const hi = hexByte(s[i * 2]) orelse return false;
        const lo = hexByte(s[i * 2 + 1]) orelse return false;
        b.* = (hi << 4) | lo;
    }
    return true;
}

fn pump(c: *quic.Conn, fd: c_int, dst: *const Sock) void {
    var buf: [1500]u8 = undefined;
    const n = c.send(&buf, now());
    if (n == 0) return;
    _ = sendto(fd, buf[0..n].ptr, n, 0, dst, @sizeOf(Sock));
}

fn readFile(path: []const u8, buf: []u8) ?usize {
    var z: [4096:0]u8 = undefined;
    if (path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = open(z[0..path.len :0], 0);
    if (fd < 0) return null;
    var n: usize = 0;
    while (n < buf.len) {
        const r = read(fd, buf[n..].ptr, buf.len - n);
        if (r < 0) return null;
        if (r == 0) break;
        n += @intCast(r);
    }
    _ = close(fd);
    return n;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var seed: [8]u8 = undefined;
    if (getrandom(&seed, seed.len, 0) != @as(isize, seed.len)) return 2;
    rng = std.mem.readInt(u64, &seed, .little);

    const v = init.args.vector;
    if (v.len < 7) return 2;
    const ip = ip4(std.mem.span(v[1])) orelse return 2;
    const port = std.fmt.parseInt(u16, std.mem.span(v[2]), 10) catch return 2;
    const budget = std.fmt.parseInt(u64, std.mem.span(v[3]), 10) catch return 2;
    var pin: [32]u8 = undefined;
    if (!parseHex(std.mem.span(v[4]), &pin)) return 2;
    const path = std.mem.span(v[5]);
    var corr: [8]u8 = undefined;
    if (!parseHex(std.mem.span(v[6]), &corr)) return 2;

    var file: [1177]u8 = undefined;
    const n = readFile(path, &file) orelse return 2;
    if (n > 1176) return 2;
    var frame: [1200]u8 = undefined;
    @memcpy(frame[0..4], "RFL1");
    frame[4] = 0;
    frame[5] = 0;
    frame[6] = 0;
    frame[7] = 0;
    @memcpy(frame[8..16], &corr);
    std.mem.writeInt(u64, frame[16..24], budget, .big);
    @memcpy(frame[24..][0..n], file[0..n]);

    var c = quic.Conn.openClient(rnd, &pin);
    const fd = socket(2, 2, 17);
    if (fd < 0) return 2;
    var local = Sock{ .family = 2, .port = 0, .addr = 0, .zero = .{0} ** 8 };
    if (bind(fd, &local, @sizeOf(Sock)) != 0) return 2;
    var dst = Sock{ .family = 2, .port = @byteSwap(port), .addr = @byteSwap(ip), .zero = .{0} ** 8 };
    const start = now();
    while (now() - start < 60_000_000_000) {
        pump(&c, fd, &dst);
        if (c.accepted and !c.app_tx_on) {
            if (!c.writeApp(frame[0 .. 24 + n])) return 2;
        }
        if (c.refused) return 3;
        if (c.peer_fin) {
            const got = c.readApp();
            if (got.len < 24) return 4;
            const status = got[5];
            if (status == 2) return 5;
            if (status == 3) return 6;
            if (status != 0 or got[4] != 1) return 4;
            var off: usize = 24;
            while (off < got.len) {
                const w = write(1, got[off..].ptr, got.len - off);
                if (w <= 0) return 2;
                off += @intCast(w);
            }
            return 0;
        }
        var pkt: [1500]u8 = undefined;
        var from: Sock = undefined;
        var ln: u32 = @sizeOf(Sock);
        const r = recvfrom(fd, &pkt, pkt.len, 0x40, &from, &ln);
        if (r > 0) c.recv(pkt[0..@intCast(r)], now());
    }
    return 4;
}

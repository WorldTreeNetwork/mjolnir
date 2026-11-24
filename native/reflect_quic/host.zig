//! Host side of one Reflect QUIC exchange.
//! Args: ip port budget key_file server_name program_path correlation_hex
//! key_file is this end's entity key, exactly 32 bytes (an Ed25519 seed).
//! server_name is the one guest name it accepts, in base58.
//! Stdout is the reply payload on transport status 0.
//! Exit 0 status 0, 5 status 2, 6 status 3, 3 the guest refused (its name is
//! not server_name), 4 timeout, 7 a flight of ours was given up with no answer
//! (the guest does not allow this key, or is gone), 2 a wrong call.

const std = @import("std");
const quic = @import("quic.zig");
const entity = @import("entity.zig");

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
extern fn _exit(status: c_int) noreturn;

const Sock = extern struct { family: u16, port: u16, addr: u32, zero: [8]u8 };
const Time = extern struct { sec: i64, nsec: i64 };

/// Connection IDs and the key share come from the operating system on every
/// call, as homoiconic's quic-client does.
fn rnd() u64 {
    var b: [8]u8 = undefined;
    var n: usize = 0;
    while (n < b.len) {
        const r = getrandom(b[n..].ptr, b.len - n, 0);
        if (r <= 0) _exit(2);
        n += @intCast(r);
    }
    return std.mem.readInt(u64, &b, .little);
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
        if (r < 0) {
            _ = close(fd);
            return null;
        }
        if (r == 0) break;
        n += @intCast(r);
    }
    _ = close(fd);
    return n;
}

var me: entity.Identity = undefined;
var allow: entity.Allow = .{};

pub fn main(init: std.process.Init.Minimal) u8 {
    const v = init.args.vector;
    if (v.len != 8) return 2;
    const ip = ip4(std.mem.span(v[1])) orelse return 2;
    const port = std.fmt.parseInt(u16, std.mem.span(v[2]), 10) catch return 2;
    const budget = std.fmt.parseInt(u64, std.mem.span(v[3]), 10) catch return 2;
    // This end's key, and the one name it accepts.
    var seed: [33]u8 = undefined;
    const sn = readFile(std.mem.span(v[4]), &seed) orelse return 2;
    if (sn != 32) {
        std.crypto.secureZero(u8, &seed);
        return 2;
    }
    me = entity.identity(seed[0..32]) orelse return 2;
    std.crypto.secureZero(u8, &seed);
    const expect = entity.parse(std.mem.span(v[5])) orelse return 2;
    if (!allow.add(&expect)) return 2;
    const path = std.mem.span(v[6]);
    var corr: [8]u8 = undefined;
    if (!parseHex(std.mem.span(v[7]), &corr)) return 2;

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

    var c = quic.Conn.openClient(rnd, &me, &allow);
    const fd = socket(2, 2, 17);
    if (fd < 0) return 2;
    var local = Sock{ .family = 2, .port = 0, .addr = 0, .zero = .{0} ** 8 };
    if (bind(fd, &local, @sizeOf(Sock)) != 0) return 2;
    var dst = Sock{ .family = 2, .port = @byteSwap(port), .addr = @byteSwap(ip), .zero = .{0} ** 8 };
    const start = now();
    while (now() - start < 60_000_000_000) {
        // Once the reply is in, what there is to send is its acknowledgement:
        // this pump runs before the reply is read below, so the guest has its
        // acknowledgement before this process exits.
        pump(&c, fd, &dst);
        if (c.accepted and !c.app_tx_on) {
            if (!c.writeApp(frame[0 .. 24 + n])) return 2;
        }
        if (c.refused) return 3;
        // A flight of ours was given up and its last wait is over: the guest
        // does not allow this key, or is gone.
        if (!c.peer_fin and c.gaveUp(now())) return 7;
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
        const r = recvfrom(fd, &pkt, pkt.len, 0x40, &from, &ln); // MSG_DONTWAIT
        if (r > 0) _ = c.recv(pkt[0..@intCast(r)], now());
    }
    return 4;
}

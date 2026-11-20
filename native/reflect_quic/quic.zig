//! QUIC v1, one stream, TLS_AES_128_GCM_SHA256, X25519, P-256 certificate.
//! The caller supplies monotonic nanoseconds. This file does not read programs.

const std = @import("std");
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Aes128 = std.crypto.core.aes.Aes128;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const X25519 = std.crypto.dh.X25519;
const Scheme = std.crypto.sign.ecdsa.EcdsaP256Sha256;

const initial_salt = [_]u8{ 0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a };
const guest_key = [_]u8{ 0xc4, 0x4a, 0xda, 0xbc, 0x4e, 0xce, 0xef, 0x4c, 0x6c, 0x1a, 0x3f, 0x2a, 0xf7, 0x50, 0x67, 0x98, 0x59, 0xd8, 0x4a, 0x4c, 0xec, 0xc8, 0x69, 0x00, 0x23, 0x32, 0x9c, 0x85, 0xd9, 0x9e, 0x73, 0x8a };
const guest_cert = [_]u8{
    0x30, 0x82, 0x01, 0x79, 0x30, 0x82, 0x01, 0x1f, 0xa0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x14, 0x63, 0xb2, 0x8f, 0x7e, 0x7d, 0x3b, 0x81, 0x5d, 0x04, 0xd7, 0x0d, 0x63, 0x54, 0x6d, 0xcf, 0x13, 0x92, 0x05, 0xb6, 0x31, 0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x30, 0x12, 0x31, 0x10, 0x30, 0x0e, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x07, 0x72, 0x65, 0x66, 0x6c, 0x65, 0x63, 0x74, 0x30, 0x1e, 0x17, 0x0d, 0x32, 0x36, 0x31, 0x31, 0x32, 0x30, 0x30, 0x34, 0x34, 0x31, 0x33, 0x39, 0x5a, 0x17, 0x0d, 0x33, 0x36, 0x31, 0x31, 0x31, 0x37, 0x30, 0x34, 0x34, 0x31, 0x33, 0x39, 0x5a, 0x30, 0x12, 0x31, 0x10, 0x30, 0x0e, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x07, 0x72, 0x65, 0x66, 0x6c, 0x65, 0x63, 0x74, 0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04, 0xec, 0xde, 0x71, 0x4e, 0x2c, 0xc5, 0x30, 0x1e, 0x84, 0xeb, 0xef, 0x38, 0x5b, 0x77, 0xe4, 0xb4, 0x56, 0x85, 0x99, 0x3b, 0x19, 0x74, 0x3a, 0x0b, 0xf0, 0x57, 0xea, 0x78, 0x39, 0x7d, 0xca, 0xd2, 0x6e, 0x35, 0x86, 0xee, 0x00, 0xe1, 0xf1, 0x36, 0xa6, 0xba, 0xae, 0x1d, 0x0e, 0x84, 0x4b, 0x03, 0xed, 0x68, 0x81, 0xf6, 0xc7, 0x61, 0x23, 0xd2, 0x54, 0x3a, 0x16, 0xe5, 0x8c, 0xee, 0x59, 0x1e, 0xa3, 0x53, 0x30, 0x51, 0x30, 0x1d, 0x06, 0x03, 0x55, 0x1d, 0x0e, 0x04, 0x16, 0x04, 0x14, 0xc4, 0x73, 0x13, 0x02, 0x26, 0xc5, 0x0d, 0x5e, 0x75, 0x03, 0xe0, 0x0b, 0xcd, 0x11, 0x21, 0x6e, 0x81, 0x8a, 0xbd, 0x3e, 0x30, 0x1f, 0x06, 0x03, 0x55, 0x1d, 0x23, 0x04, 0x18, 0x30, 0x16, 0x80, 0x14, 0xc4, 0x73, 0x13, 0x02, 0x26, 0xc5, 0x0d, 0x5e, 0x75, 0x03, 0xe0, 0x0b, 0xcd, 0x11, 0x21, 0x6e, 0x81, 0x8a, 0xbd, 0x3e, 0x30, 0x0f, 0x06, 0x03, 0x55, 0x1d, 0x13, 0x01, 0x01, 0xff, 0x04, 0x05, 0x30, 0x03, 0x01, 0x01, 0xff, 0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x03, 0x48, 0x00, 0x30, 0x45, 0x02, 0x20, 0x44, 0x00, 0x91, 0x6d, 0xdb, 0x1a, 0x67, 0xae, 0xd1, 0x26, 0x81, 0x78, 0xcd, 0x34, 0x04, 0xf2, 0x87, 0x46, 0x1b, 0xda, 0x3a, 0x78, 0x21, 0xfa, 0x8f, 0xbc, 0x57, 0x16, 0xcb, 0xb9, 0xe3, 0xfc, 0x02, 0x21, 0x00, 0xeb, 0xe0, 0x03, 0x5d, 0x00, 0x20, 0xd2, 0x52, 0x83, 0x76, 0xf9, 0xb8, 0xf4, 0xf5, 0x74, 0x44, 0x4a, 0xdd, 0xea, 0x71, 0xa7, 0xb9, 0x35, 0xc0, 0xe8, 0x6c, 0x79, 0xed, 0xcd, 0xcc, 0x47, 0x41,
};

pub fn certificate() []const u8 {
    return &guest_cert;
}

const Keys = struct { key: [16]u8 = .{0} ** 16, iv: [12]u8 = .{0} ** 12, hp: [16]u8 = .{0} ** 16, on: bool = false, pn: u32 = 0 };
const Pend = struct { on: bool = false, frames: [1400]u8 = undefined, len: usize = 0, pn: u32 = 0, at: u64 = 0, tries: u8 = 0 };
const Holey = struct { buf: [8192]u8 = .{0} ** 8192, got: [8192]u8 = .{0} ** 8192, n: usize = 0 };

pub const Conn = struct {
    server: bool,
    pin: [32]u8 = .{0} ** 32,
    local_cid: [8]u8 = .{0} ** 8,
    peer_cid: [8]u8 = .{0} ** 8,
    orig_dcid: [8]u8 = .{0} ** 8,
    secret: [32]u8 = .{0} ** 32,
    share: [32]u8 = .{0} ** 32,
    initial: Keys = .{},
    handshake: Keys = .{},
    app: Keys = .{},
    open_initial: Keys = .{},
    open_handshake: Keys = .{},
    open_app: Keys = .{},
    local_hs: [32]u8 = .{0} ** 32,
    peer_hs: [32]u8 = .{0} ** 32,
    hs_secret: [32]u8 = .{0} ** 32,
    scratch: [1400]u8 = undefined,
    plain: [1400]u8 = undefined,
    init_rx: Holey = .{},
    pend: [3]Pend = .{ .{}, .{}, .{} },
    rx_pn: [3]u64 = .{0} ** 3, // bit i set => pn (base+i) seen; base in rx_base
    rx_base: [3]u32 = .{0} ** 3,
    rx_any: [3]bool = .{ false, false, false },
    client_hello: [1024]u8 = undefined,
    client_hello_len: usize = 0,
    server_flight: [4096]u8 = undefined,
    server_flight_len: usize = 0,
    hs_rx: Holey = .{},
    app_rx: Holey = .{},
    app_tx: [8192]u8 = undefined,
    app_tx_len: usize = 0,
    app_tx_on: bool = false,
    accepted: bool = false,
    refused: bool = false,
    app_keys: bool = false,
    client_fin_sent: bool = false,
    server_done: bool = false,
    peer_fin: bool = false,
    sent_fin: bool = false,
    rand: *const fn () u64,

    pub fn openClient(rand: *const fn () u64, pin: *const [32]u8) Conn {
        var c = Conn{ .server = false, .rand = rand, .pin = pin.* };
        fill(&c.local_cid, rand);
        fill(&c.peer_cid, rand);
        c.orig_dcid = c.peer_cid;
        c.secret = rand32(rand);
        c.share = X25519.recoverPublicKey(c.secret) catch .{0} ** 32;
        c.client_hello_len = buildClientHello(c.client_hello[0..], &c.share, &c.local_cid);
        installPair(&c.initial, &c.open_initial, &c.peer_cid, false);
        var wrapped: [1100]u8 = undefined;
        const wn = cryptoFrame(&wrapped, c.client_hello[0..c.client_hello_len]);
        arm(&c, 0, wrapped[0..wn], 0);
        return c;
    }

    pub fn openServer(rand: *const fn () u64) Conn {
        var c = Conn{ .server = true, .rand = rand };
        fill(&c.local_cid, rand);
        return c;
    }

    pub fn recv(c: *Conn, pkt: []const u8, now: u64) void {
        var i: usize = 0;
        while (i < pkt.len) {
            const n = c.one(pkt[i..], now) orelse break;
            if (n == 0) break;
            i += n;
        }
    }

    pub fn send(c: *Conn, out: []u8, now: u64) usize {
        var n: usize = 0;
        var s: usize = 0;
        while (s < 3) : (s += 1) {
            if (!c.due(s, now)) continue;
            const wrote = c.seal(s, out[n..], now) orelse continue;
            n += wrote;
        }
        return n;
    }

    pub fn writeApp(c: *Conn, data: []const u8) bool {
        if (!c.accepted or c.app_tx_on or data.len > c.app_tx.len) return false;
        @memcpy(c.app_tx[0..data.len], data);
        c.app_tx_len = data.len;
        c.app_tx_on = true;
        c.sent_fin = true;
        var frames: [8200]u8 = undefined;
        const n = streamFrame(frames[0..], c.app_tx[0..c.app_tx_len], true);
        arm(c, 2, frames[0..n], 0);
        return true;
    }

    pub fn readApp(c: *Conn) []const u8 {
        if (!c.peer_fin) return "";
        return c.app_rx.buf[0..c.app_rx.n];
    }

    fn due(c: *Conn, s: usize, now: u64) bool {
        const p = &c.pend[s];
        if (!p.on) return false;
        const keys = c.spaceKeys(s);
        if (!keys.on) return false;
        if (p.tries == 0) return true;
        const wait = @as(u64, 20_000_000) << @min(p.tries, 4);
        return now >= p.at +% wait;
    }

    fn spaceKeys(c: *Conn, s: usize) *Keys {
        return switch (s) {
            0 => &c.initial,
            1 => &c.handshake,
            else => &c.app,
        };
    }
    fn openKeys(c: *Conn, s: usize) *Keys {
        return switch (s) {
            0 => &c.open_initial,
            1 => &c.open_handshake,
            else => &c.open_app,
        };
    }

    fn one(c: *Conn, pkt: []const u8, now: u64) ?usize {
        if (pkt.len < 5 or pkt[0] & 0x80 == 0 and pkt[0] & 0x40 == 0) return null;
        if (pkt[0] & 0x80 != 0) return c.longPacket(pkt, now);
        return c.short(pkt, now);
    }

    fn longPacket(c: *Conn, pkt: []const u8, now: u64) ?usize {
        if (pkt.len < 7) return null;
        const ver = std.mem.readInt(u32, pkt[1..5], .big);
        if (ver != 1) return null;
        const dlen = pkt[5];
        if (dlen != 8 or pkt.len < 7 + 8) return null;
        const dcid = pkt[6..14];
        const slen = pkt[14];
        if (slen != 8 or pkt.len < 15 + 8) return null;
        const scid = pkt[15..23];
        var o: usize = 23;
        const kind = (pkt[0] & 0x30) >> 4;
        if (kind == 0) {
            const tok = getVar(pkt[o..]) orelse return null;
            o += tok.len + @as(usize, @intCast(tok.v));
            if (o > pkt.len) return null;
        }
        const ln = getVar(pkt[o..]) orelse return null;
        o += varLen(ln.v);
        if (o + ln.v > pkt.len) return null;
        const total = o + ln.v;
        const space: usize = if (kind == 0) 0 else if (kind == 2) 1 else return total;
        if (c.server and !c.initial.on and space == 0) {
            var id: [8]u8 = undefined;
            @memcpy(&id, dcid);
            c.orig_dcid = id;
            c.peer_cid = id;
            @memcpy(&c.peer_cid, scid);
            installPair(&c.initial, &c.open_initial, &c.orig_dcid, true);
        }
        if (!c.server and space == 0) {
            @memcpy(&c.peer_cid, scid);
        }
        const plain = c.open(space, pkt[0..total], o) orelse return total;
        c.mark(space, plain.pn);
        c.takeFrames(space, plain.data, now);
        return total;
    }

    fn short(c: *Conn, pkt: []const u8, now: u64) ?usize {
        if (!c.app.on or pkt.len < 1 + 8 + 4 + 16) return null;
        const total = pkt.len;
        const plain = c.open(2, pkt[0..total], 1 + 8) orelse return null;
        c.mark(2, plain.pn);
        c.takeFrames(2, plain.data, now);
        return total;
    }

    const Plain = struct { pn: u32, data: []const u8 };
    fn open(c: *Conn, space: usize, pkt: []const u8, pn_at: usize) ?Plain {
        const k = c.openKeys(space);
        if (!k.on or pn_at + 4 + 16 > pkt.len or pkt.len > c.scratch.len) return null;
        const buf = &c.scratch;
        @memcpy(buf[0..pkt.len], pkt);
        var sample: [16]u8 = undefined;
        @memcpy(&sample, buf[pn_at + 4 .. pn_at + 20]);
        const mask = hpMask(&k.hp, &sample);
        const long = buf[0] & 0x80 != 0;
        const keep: u8 = if (long) 0x0f else 0x1f;
        buf[0] ^= mask[0] & keep;
        var i: usize = 0;
        while (i < 4) : (i += 1) buf[pn_at + i] ^= mask[1 + i];
        const pn = std.mem.readInt(u32, buf[pn_at..][0..4], .big);
        const body = pn_at + 4;
        const tag_at = pkt.len - 16;
        if (tag_at < body) return null;
        var tag: [16]u8 = undefined;
        @memcpy(&tag, buf[tag_at..pkt.len]);
        var nonce: [12]u8 = k.iv;
        var s: usize = 0;
        while (s < 4) : (s += 1) nonce[8 + s] ^= buf[pn_at + s];
        Aes128Gcm.decrypt(c.plain[0 .. tag_at - body], buf[body..tag_at], tag, buf[0..body], nonce, k.key) catch return null;
        return .{ .pn = pn, .data = c.plain[0 .. tag_at - body] };
    }

    fn seal(c: *Conn, space: usize, out: []u8, now: u64) ?usize {
        const k = c.spaceKeys(space);
        const p = &c.pend[space];
        if (!k.on or !p.on) return null;
        var frames: [1500]u8 = undefined;
        var n: usize = ackFrame(frames[0..], c, space);
        @memcpy(frames[n..][0..p.len], p.frames[0..p.len]);
        n += p.len;
        const pn = k.pn;
        k.pn += 1;
        const long = space < 2;
        var hdr: [64]u8 = undefined;
        var h: usize = 0;
        const dcid = c.peer_cid;
        const scid = c.local_cid;
        if (long) {
            const kind: u8 = if (space == 0) 0 else 2;
            hdr[0] = 0xc0 | (kind << 4) | 0x03;
            std.mem.writeInt(u32, hdr[1..5], 1, .big);
            hdr[5] = 8;
            @memcpy(hdr[6..14], &dcid);
            hdr[14] = 8;
            @memcpy(hdr[15..23], &scid);
            h = 23;
            if (space == 0) {
                hdr[h] = 0;
                h += 1;
            }
            const rest = 4 + n + 16;
            h += putVar(hdr[h..], rest);
        } else {
            hdr[0] = 0x40 | 0x03;
            @memcpy(hdr[1..9], &dcid);
            h = 9;
        }
        const total = h + 4 + n + 16;
        const pad = if (space == 0 and !c.server and total < 1200) 1200 else total;
        if (pad > out.len or pad > 1400) return null;
        @memset(out[0..pad], 0);
        @memcpy(out[0..h], hdr[0..h]);
        std.mem.writeInt(u32, out[h..][0..4], pn, .big);
        var sealed: [1400]u8 = undefined;
        @memcpy(sealed[0..n], frames[0..n]);
        @memset(sealed[n .. pad - (h + 4) - 16], 0);
        // PADDING already zero. Length field must cover the padding.
        if (pad != total and long) {
            const rest = pad - h;
            _ = putVar(out[h - varLen(rest) ..], rest);
        }
        var nonce: [12]u8 = k.iv;
        var s: usize = 0;
        while (s < 4) : (s += 1) nonce[8 + s] ^= out[h + s];
        var tag: [16]u8 = undefined;
        const ctlen = pad - 16 - (h + 4);
        Aes128Gcm.encrypt(out[h + 4 ..][0..ctlen], &tag, sealed[0..ctlen], out[0 .. h + 4], nonce, k.key);
        @memcpy(out[pad - 16 .. pad], &tag);
        var sample: [16]u8 = undefined;
        @memcpy(&sample, out[h + 4 .. h + 20]);
        const mask = hpMask(&k.hp, &sample);
        const keep: u8 = if (long) 0x0f else 0x1f;
        out[0] ^= mask[0] & keep;
        s = 0;
        while (s < 4) : (s += 1) out[h + s] ^= mask[1 + s];
        p.pn = pn;
        p.at = now;
        p.tries += 1;
        return pad;
    }

    fn takeFrames(c: *Conn, space: usize, data: []const u8, _: u64) void {
        var i: usize = 0;
        while (i < data.len) {
            const t = data[i];
            if (t == 0) {
                i += 1;
                continue;
            }
            if (t == 0x02 or t == 0x03) {
                i = c.ack(data, i) orelse return;
                continue;
            }
            if (t == 0x06) {
                const off = getVar(data[i + 1 ..]) orelse return;
                const o1 = i + 1 + varLen(off.v);
                const ln = getVar(data[o1..]) orelse return;
                const o2 = o1 + varLen(ln.v);
                if (o2 + ln.v > data.len) return;
                const dest = if (space == 0) &c.init_rx else &c.hs_rx;
                holePut(dest, off.v, data[o2 .. o2 + ln.v]);
                i = o2 + ln.v;
                continue;
            }
            if (t >= 0x08 and t <= 0x0f) {
                var o = i + 1;
                const id = getVar(data[o..]) orelse return;
                o += varLen(id.v);
                var off: u64 = 0;
                if (t & 0x04 != 0) {
                    const v = getVar(data[o..]) orelse return;
                    off = v.v;
                    o += varLen(v.v);
                }
                var ln: u64 = 0;
                if (t & 0x02 != 0) {
                    const v = getVar(data[o..]) orelse return;
                    ln = v.v;
                    o += varLen(v.v);
                } else ln = data.len - o;
                if (o + ln > data.len) return;
                holePut(&c.app_rx, off, data[o .. o + ln]);
                if (t & 0x01 != 0) c.peer_fin = true;
                i = o + ln;
                continue;
            }
            return;
        }
        if (space == 0 and c.server) c.onClientHello();
        if (space == 0 and !c.server) c.onServerHello();
        if (space == 1 and !c.server) c.onServerFlight();
        if (space == 1 and c.server) c.onClientFinished();
    }

    fn onClientHello(c: *Conn) void {
        if (c.server_flight_len != 0 or c.init_rx.n < 4) return;
        if (!contiguous(&c.init_rx, c.init_rx.n)) return;
        c.client_hello_len = c.init_rx.n;
        if (c.client_hello_len > c.client_hello.len) return;
        @memcpy(c.client_hello[0..c.client_hello_len], c.init_rx.buf[0..c.client_hello_len]);
        const share = findShare(c.client_hello[0..c.client_hello_len]) orelse return;
        c.secret = rand32(c.rand);
        c.share = X25519.recoverPublicKey(c.secret) catch return;
        const shared = X25519.scalarmult(c.secret, share) catch return;
        c.server_flight_len = buildServerFlight(c.server_flight[0..], c.client_hello[0..c.client_hello_len], &c.share, &shared, &c.orig_dcid, &c.local_cid);
        if (c.server_flight_len == 0) return;
        const sh_end = msgEnd(c.server_flight[0..c.server_flight_len], 0);
        installHandshake(c, c.client_hello[0..c.client_hello_len], c.server_flight[0..sh_end], shared);
        c.init_rx = .{};
        var wrapped: [4200]u8 = undefined;
        const w0 = cryptoFrame(&wrapped, c.server_flight[0..sh_end]);
        arm(c, 0, wrapped[0..w0], 0);
        const w1 = cryptoFrame(&wrapped, c.server_flight[sh_end..c.server_flight_len]);
        arm(c, 1, wrapped[0..w1], 0);
    }

    fn onServerHello(c: *Conn) void {
        if (c.server or c.handshake.on or c.init_rx.n < 4) return;
        const sh = c.init_rx.buf[0..c.init_rx.n];
        const share = findShare(sh) orelse return;
        const shared = X25519.scalarmult(c.secret, share) catch return;
        if (sh.len > c.server_flight.len) return;
        @memcpy(c.server_flight[0..sh.len], sh);
        c.server_flight_len = sh.len;
        installHandshake(c, c.client_hello[0..c.client_hello_len], sh, shared);
    }

    fn onServerFlight(c: *Conn) void {
        if (c.server or c.server_done) return;
        if (!contiguous(&c.hs_rx, holeEnd(&c.hs_rx))) return;
        const flight = c.hs_rx.buf[0..holeEnd(&c.hs_rx)];
        if (c.server_flight_len == 0) return;
        var o: usize = 0;
        const ee = takeMsg(flight, &o, 8) orelse return;
        const certm = takeMsg(flight, &o, 11) orelse return;
        const cv = takeMsg(flight, &o, 15) orelse return;
        const fin = takeMsg(flight, &o, 20) orelse return;
        _ = ee;
        const der = certDer(certm) orelse {
            c.refused = true;
            return;
        };
        var hash: [32]u8 = undefined;
        Sha256.hash(der, &hash, .{});
        if (!std.mem.eql(u8, &hash, &c.pin)) {
            c.refused = true;
            return;
        }
        const pk = certKey(der) orelse {
            c.refused = true;
            return;
        };
        var tr: [6000]u8 = undefined;
        const n1 = c.client_hello_len + (certm.ptr - flight.ptr) + certm.len - (certm.ptr - flight.ptr);
        // transcript through Certificate is CH || flight up to end of Certificate
        const through_cert = @intFromPtr(certm.ptr) - @intFromPtr(flight.ptr) + certm.len;
        const pre = c.client_hello_len + c.server_flight_len;
        if (pre + through_cert > tr.len) return;
        @memcpy(tr[0..c.client_hello_len], c.client_hello[0..c.client_hello_len]);
        @memcpy(tr[c.client_hello_len..][0..c.server_flight_len], c.server_flight[0..c.server_flight_len]);
        @memcpy(tr[pre..][0..through_cert], flight[0..through_cert]);
        var th: [32]u8 = undefined;
        Sha256.hash(tr[0 .. pre + through_cert], &th, .{});
        if (!verifyCert(cv, pk, &th)) {
            c.refused = true;
            return;
        }
        const through_cv = @intFromPtr(cv.ptr) - @intFromPtr(flight.ptr) + cv.len;
        @memcpy(tr[pre..][0..through_cv], flight[0..through_cv]);
        Sha256.hash(tr[0 .. pre + through_cv], &th, .{});
        const expect = finished(&c.peer_hs, &th);
        if (fin.len < 36 or !std.mem.eql(u8, fin[4..36], &expect)) {
            c.refused = true;
            return;
        }
        const through_fin = @intFromPtr(fin.ptr) - @intFromPtr(flight.ptr) + fin.len;
        @memcpy(tr[pre..][0..through_fin], flight[0..through_fin]);
        Sha256.hash(tr[0 .. pre + through_fin], &th, .{});
        installApp(c, &th);
        const mine = finished(&c.local_hs, &th);
        var msg: [36]u8 = undefined;
        msg[0] = 20;
        msg[1] = 0;
        msg[2] = 0;
        msg[3] = 32;
        @memcpy(msg[4..36], &mine);
        c.hs_rx = .{};
        var wrapped: [80]u8 = undefined;
        const wn = cryptoFrame(&wrapped, &msg);
        arm(c, 1, wrapped[0..wn], 0);
        c.client_fin_sent = true;
        c.accepted = true;
        c.server_done = true;
        _ = n1;
    }

    fn onClientFinished(c: *Conn) void {
        if (!c.server or c.accepted) return;
        if (!contiguous(&c.hs_rx, holeEnd(&c.hs_rx))) return;
        const msg = c.hs_rx.buf[0..holeEnd(&c.hs_rx)];
        if (msg.len < 36 or msg[0] != 20) return;
        // Transcript: CH || server flight || client finished is hashed in two steps.
        var tr: [6000]u8 = undefined;
        if (c.client_hello_len + c.server_flight_len + 36 > tr.len) return;
        @memcpy(tr[0..c.client_hello_len], c.client_hello[0..c.client_hello_len]);
        @memcpy(tr[c.client_hello_len..][0..c.server_flight_len], c.server_flight[0..c.server_flight_len]);
        var th: [32]u8 = undefined;
        Sha256.hash(tr[0 .. c.client_hello_len + c.server_flight_len], &th, .{});
        const expect = finished(&c.peer_hs, &th);
        if (!std.mem.eql(u8, msg[4..36], &expect)) {
            c.refused = true;
            return;
        }
        installApp(c, &th);
        c.accepted = true;
        // The handshake pend is done once we have the client's finished.
        c.pend[1].on = false;
    }

    fn ack(c: *Conn, data: []const u8, at: usize) ?usize {
        var o = at + 1;
        const largest = getVar(data[o..]) orelse return null;
        o += varLen(largest.v);
        const delay = getVar(data[o..]) orelse return null;
        o += varLen(delay.v);
        const count = getVar(data[o..]) orelse return null;
        o += varLen(count.v);
        const first = getVar(data[o..]) orelse return null;
        o += varLen(first.v);
        c.acked(@truncate(largest.v));
        var n: u64 = 0;
        while (n < count.v) : (n += 1) {
            const gap = getVar(data[o..]) orelse return null;
            o += varLen(gap.v);
            const ln = getVar(data[o..]) orelse return null;
            o += varLen(ln.v);
        }
        return o;
    }

    fn acked(c: *Conn, pn: u32) void {
        var s: usize = 0;
        while (s < 3) : (s += 1) {
            if (c.pend[s].on and c.pend[s].tries > 0 and c.pend[s].pn == pn) c.pend[s].on = false;
        }
    }

    fn mark(c: *Conn, space: usize, pn: u32) void {
        if (!c.rx_any[space]) {
            c.rx_base[space] = pn;
            c.rx_any[space] = true;
        }
        if (pn < c.rx_base[space]) return;
        const d = pn - c.rx_base[space];
        if (d < 64) c.rx_pn[space] |= @as(u64, 1) << @intCast(d);
    }
};

fn arm(c: *Conn, s: usize, frames: []const u8, now: u64) void {
    const p = &c.pend[s];
    if (frames.len > p.frames.len) return;
    @memcpy(p.frames[0..frames.len], frames);
    p.len = frames.len;
    p.on = true;
    p.tries = 0;
    p.at = now;
}

fn installPair(seal: *Keys, open_k: *Keys, dcid: *const [8]u8, server: bool) void {
    const secret = Hkdf.extract(&initial_salt, dcid);
    var mine: [32]u8 = undefined;
    var peer: [32]u8 = undefined;
    expandLabel(secret, if (server) "server in" else "client in", "", &mine);
    expandLabel(secret, if (server) "client in" else "server in", "", &peer);
    traffic(seal, &mine);
    traffic(open_k, &peer);
}

fn handshakeSecret(ch: []const u8, through_sh: []const u8, shared: [32]u8) ?[32]u8 {
    var tr: [5000]u8 = undefined;
    if (ch.len + through_sh.len > tr.len) return null;
    @memcpy(tr[0..ch.len], ch);
    @memcpy(tr[ch.len..][0..through_sh.len], through_sh);
    var th: [32]u8 = undefined;
    Sha256.hash(tr[0 .. ch.len + through_sh.len], &th, .{});
    const zeros = [_]u8{0} ** 32;
    const early = Hkdf.extract(&zeros, &zeros);
    var derived: [32]u8 = undefined;
    expandLabel(early, "derived", &emptyHash(), &derived);
    return Hkdf.extract(&derived, &shared);
}

fn installHandshake(c: *Conn, ch: []const u8, through_sh: []const u8, shared: [32]u8) void {
    const hs = handshakeSecret(ch, through_sh, shared) orelse return;
    var tr: [5000]u8 = undefined;
    if (ch.len + through_sh.len > tr.len) return;
    @memcpy(tr[0..ch.len], ch);
    @memcpy(tr[ch.len..][0..through_sh.len], through_sh);
    var th: [32]u8 = undefined;
    Sha256.hash(tr[0 .. ch.len + through_sh.len], &th, .{});
    const mine_l = if (c.server) "s hs traffic" else "c hs traffic";
    const peer_l = if (c.server) "c hs traffic" else "s hs traffic";
    expandLabel(hs, mine_l, &th, &c.local_hs);
    expandLabel(hs, peer_l, &th, &c.peer_hs);
    traffic(&c.handshake, &c.local_hs);
    traffic(&c.open_handshake, &c.peer_hs);
    c.hs_secret = hs;
}

fn installApp(c: *Conn, th: *const [32]u8) void {
    var derived: [32]u8 = undefined;
    expandLabel(c.hs_secret, "derived", &emptyHash(), &derived);
    const zeros = [_]u8{0} ** 32;
    const master = Hkdf.extract(&derived, &zeros);
    var mine: [32]u8 = undefined;
    var peer: [32]u8 = undefined;
    expandLabel(master, if (c.server) "s ap traffic" else "c ap traffic", th, &mine);
    expandLabel(master, if (c.server) "c ap traffic" else "s ap traffic", th, &peer);
    traffic(&c.app, &mine);
    traffic(&c.open_app, &peer);
    c.app_keys = true;
}

fn expandLabel(prk: [32]u8, label: []const u8, ctx: []const u8, out: []u8) void {
    var info: [80]u8 = undefined;
    info[0] = @truncate(out.len >> 8);
    info[1] = @truncate(out.len);
    info[2] = @truncate(6 + label.len);
    @memcpy(info[3..9], "tls13 ");
    @memcpy(info[9..][0..label.len], label);
    var n: usize = 9 + label.len;
    info[n] = @truncate(ctx.len);
    n += 1;
    @memcpy(info[n..][0..ctx.len], ctx);
    n += ctx.len;
    Hkdf.expand(out, info[0..n], prk);
}

fn traffic(k: *Keys, secret: *const [32]u8) void {
    expandLabel(secret.*, "quic key", "", k.key[0..]);
    expandLabel(secret.*, "quic iv", "", k.iv[0..]);
    expandLabel(secret.*, "quic hp", "", k.hp[0..]);
    k.on = true;
    k.pn = 0;
}

fn hpMask(hp: *const [16]u8, sample: *const [16]u8) [16]u8 {
    const aes = Aes128.initEnc(hp.*);
    var out: [16]u8 = undefined;
    aes.encrypt(&out, sample);
    return out;
}

fn emptyHash() [32]u8 {
    var h: [32]u8 = undefined;
    Sha256.hash("", &h, .{});
    return h;
}

fn finished(secret: *const [32]u8, th: *const [32]u8) [32]u8 {
    var fk: [32]u8 = undefined;
    expandLabel(secret.*, "finished", "", &fk);
    var vd: [32]u8 = undefined;
    HmacSha256.create(&vd, th, &fk);
    return vd;
}

fn fill(d: *[8]u8, rand: *const fn () u64) void {
    const v = rand();
    var i: usize = 0;
    while (i < 8) : (i += 1) d[i] = @truncate(v >> @intCast(8 * i));
}
fn rand32(rand: *const fn () u64) [32]u8 {
    var o: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const v = rand();
        var j: usize = 0;
        while (j < 8) : (j += 1) o[i * 8 + j] = @truncate(v >> @intCast(8 * j));
    }
    return o;
}

const Var = struct { v: u64, len: usize };
fn getVar(b: []const u8) ?Var {
    if (b.len == 0) return null;
    const p = b[0] >> 6;
    const len: usize = @as(usize, 1) << @intCast(p);
    if (b.len < len) return null;
    var v: u64 = b[0] & 0x3f;
    var i: usize = 1;
    while (i < len) : (i += 1) v = (v << 8) | b[i];
    return .{ .v = v, .len = len };
}
fn varLen(v: u64) usize {
    if (v < 64) return 1;
    if (v < 16384) return 2;
    if (v < 1_073_741_824) return 4;
    return 8;
}
fn putVar(b: []u8, v: u64) usize {
    const n = varLen(v);
    var i: usize = 0;
    while (i < n) : (i += 1) b[n - 1 - i] = @truncate(v >> @intCast(8 * i));
    const tag: u8 = if (n == 1) 0 else if (n == 2) 0x40 else if (n == 4) 0x80 else 0xc0;
    b[0] |= tag;
    return n;
}

fn holePut(h: *Holey, off: u64, data: []const u8) void {
    if (off + data.len > h.buf.len) return;
    const o: usize = @intCast(off);
    @memcpy(h.buf[o..][0..data.len], data);
    var i: usize = 0;
    while (i < data.len) : (i += 1) h.got[o + i] = 1;
    while (h.n < h.buf.len and h.got[h.n] == 1) h.n += 1;
}
fn holeEnd(h: *const Holey) usize {
    return h.n;
}
fn contiguous(h: *const Holey, n: usize) bool {
    return h.n >= n;
}

fn ackFrame(out: []u8, c: *Conn, space: usize) usize {
    if (!c.rx_any[space]) return 0;
    var largest: u32 = c.rx_base[space];
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        if (c.rx_pn[space] & (@as(u64, 1) << @intCast(i)) != 0) largest = c.rx_base[space] + i;
    }
    var first: u32 = 0;
    var p = largest;
    while (p > c.rx_base[space]) {
        const d = p - c.rx_base[space];
        if (d >= 64 or c.rx_pn[space] & (@as(u64, 1) << @intCast(d)) == 0) break;
        first += 1;
        p -= 1;
    }
    out[0] = 0x02;
    var n: usize = 1;
    n += putVar(out[n..], largest);
    n += putVar(out[n..], 0);
    n += putVar(out[n..], 0);
    n += putVar(out[n..], first);
    return n;
}

fn cryptoFrame(out: []u8, data: []const u8) usize {
    out[0] = 0x06;
    var n: usize = 1;
    n += putVar(out[n..], 0);
    n += putVar(out[n..], data.len);
    @memcpy(out[n..][0..data.len], data);
    return n + data.len;
}

fn streamFrame(out: []u8, data: []const u8, fin: bool) usize {
    out[0] = 0x0e | if (fin) @as(u8, 1) else 0; // OFF+LEN+optional FIN
    var n: usize = 1;
    n += putVar(out[n..], 0); // stream id
    n += putVar(out[n..], 0); // offset
    n += putVar(out[n..], data.len);
    @memcpy(out[n..][0..data.len], data);
    return n + data.len;
}

fn msgEnd(b: []const u8, at: usize) usize {
    if (at + 4 > b.len) return 0;
    const ln = read24(b[at + 1 ..]);
    if (at + 4 + ln > b.len) return 0;
    return at + 4 + ln;
}
fn read24(b: []const u8) usize {
    return (@as(usize, b[0]) << 16) | (@as(usize, b[1]) << 8) | b[2];
}
fn takeMsg(b: []const u8, o: *usize, kind: u8) ?[]const u8 {
    if (o.* + 4 > b.len or b[o.*] != kind) return null;
    const ln = read24(b[o.* + 1 ..]);
    if (o.* + 4 + ln > b.len) return null;
    const m = b[o.* .. o.* + 4 + ln];
    o.* += 4 + ln;
    return m;
}

fn findShare(hello: []const u8) ?[32]u8 {
    // Search for the key_share group 0x001d followed by length 32.
    var i: usize = 0;
    while (i + 36 <= hello.len) : (i += 1) {
        if (hello[i] == 0x00 and hello[i + 1] == 0x1d and hello[i + 2] == 0x00 and hello[i + 3] == 0x20) {
            var s: [32]u8 = undefined;
            @memcpy(&s, hello[i + 4 .. i + 36]);
            return s;
        }
    }
    return null;
}
fn certDer(cert_msg: []const u8) ?[]const u8 {
    // handshake header + context len + list len + cert len
    if (cert_msg.len < 10) return null;
    var o: usize = 4;
    const ctx = cert_msg[o];
    o += 1 + ctx;
    if (o + 3 > cert_msg.len) return null;
    o += 3;
    if (o + 3 > cert_msg.len) return null;
    const n = read24(cert_msg[o..]);
    o += 3;
    if (o + n > cert_msg.len) return null;
    return cert_msg[o .. o + n];
}
fn certKey(der: []const u8) ?[65]u8 {
    var i: usize = 0;
    while (i + 67 < der.len) : (i += 1) {
        if (der[i] == 0x03 and der[i + 1] == 0x42 and der[i + 2] == 0x00 and der[i + 3] == 0x04) {
            var k: [65]u8 = undefined;
            @memcpy(&k, der[i + 3 .. i + 68]);
            return k;
        }
    }
    return null;
}
fn verifyCert(cv: []const u8, pk: [65]u8, th: *const [32]u8) bool {
    if (cv.len < 8) return false;
    const siglen = (@as(usize, cv[6]) << 8) | cv[7];
    if (8 + siglen > cv.len) return false;
    const sig = Scheme.Signature.fromDer(cv[8 .. 8 + siglen]) catch return false;
    const key = Scheme.PublicKey.fromSec1(&pk) catch return false;
    var msg: [140]u8 = undefined;
    @memset(msg[0..64], ' ');
    const ctx = "TLS 1.3, server CertificateVerify";
    @memcpy(msg[64..][0..ctx.len], ctx);
    msg[64 + ctx.len] = 0;
    @memcpy(msg[64 + ctx.len + 1 ..][0..32], th);
    sig.verify(msg[0 .. 64 + ctx.len + 1 + 32], key) catch return false;
    return true;
}

fn buildClientHello(out: []u8, share: *const [32]u8, scid: *const [8]u8) usize {
    var ext: [256]u8 = undefined;
    var n: usize = 0;
    n += extOne(&ext, n, 0x002b, &[_]u8{ 0x02, 0x03, 0x04 });
    n += extOne(&ext, n, 0x000a, &[_]u8{ 0x00, 0x02, 0x00, 0x1d });
    n += extOne(&ext, n, 0x000d, &[_]u8{ 0x00, 0x02, 0x04, 0x03 });
    var ks: [40]u8 = undefined;
    ks[0] = 0;
    ks[1] = 36;
    ks[2] = 0x00;
    ks[3] = 0x1d;
    ks[4] = 0;
    ks[5] = 32;
    @memcpy(ks[6..38], share);
    n += extOne(&ext, n, 0x0033, ks[0..38]);
    var tp: [64]u8 = undefined;
    const tn = params(&tp, scid, null);
    n += extOne(&ext, n, 0x0039, tp[0..tn]);
    var body: [512]u8 = undefined;
    var b: usize = 0;
    body[b] = 0x03;
    body[b + 1] = 0x03;
    b += 2;
    @memset(body[b..][0..32], 0x11);
    b += 32;
    body[b] = 0;
    b += 1;
    body[b] = 0;
    body[b + 1] = 2;
    body[b + 2] = 0x13;
    body[b + 3] = 0x01;
    b += 4;
    body[b] = 1;
    body[b + 1] = 0;
    b += 2;
    std.mem.writeInt(u16, body[b..][0..2], @intCast(n), .big);
    b += 2;
    @memcpy(body[b..][0..n], ext[0..n]);
    b += n;
    return wrap(out, 1, body[0..b]);
}

fn buildServerFlight(out: []u8, ch: []const u8, share: *const [32]u8, shared: *const [32]u8, orig: *const [8]u8, scid: *const [8]u8) usize {
    var shb: [128]u8 = undefined;
    var b: usize = 0;
    shb[0] = 0x03;
    shb[1] = 0x03;
    b = 2;
    @memset(shb[b..][0..32], 0x22);
    b += 32;
    shb[b] = 0;
    b += 1;
    shb[b] = 0x13;
    shb[b + 1] = 0x01;
    b += 2;
    shb[b] = 0;
    b += 1;
    var ext: [80]u8 = undefined;
    var n: usize = extOne(&ext, 0, 0x002b, &[_]u8{0x03, 0x04});
    var ks: [40]u8 = undefined;
    ks[0] = 0x00;
    ks[1] = 0x1d;
    ks[2] = 0;
    ks[3] = 32;
    @memcpy(ks[4..36], share);
    n += extOne(&ext, n, 0x0033, ks[0..36]);
    std.mem.writeInt(u16, shb[b..][0..2], @intCast(n), .big);
    b += 2;
    @memcpy(shb[b..][0..n], ext[0..n]);
    b += n;
    var flight: [4096]u8 = undefined;
    var f: usize = wrap(flight[0..], 2, shb[0..b]);
    // EE with transport params
    var tp: [64]u8 = undefined;
    const tn = params(&tp, scid, orig);
    var ee: [80]u8 = undefined;
    const en = extOne(&ee, 0, 0x0039, tp[0..tn]);
    var eeb: [90]u8 = undefined;
    std.mem.writeInt(u16, eeb[0..2], @intCast(en), .big);
    @memcpy(eeb[2..][0..en], ee[0..en]);
    f += wrap(flight[f..], 8, eeb[0 .. 2 + en]);
    // Certificate
    var cb: [500]u8 = undefined;
    cb[0] = 0;
    const list = 3 + guest_cert.len + 2;
    cb[1] = @truncate(list >> 16);
    cb[2] = @truncate(list >> 8);
    cb[3] = @truncate(list);
    cb[4] = @truncate(guest_cert.len >> 16);
    cb[5] = @truncate(guest_cert.len >> 8);
    cb[6] = @truncate(guest_cert.len);
    @memcpy(cb[7..][0..guest_cert.len], &guest_cert);
    cb[7 + guest_cert.len] = 0;
    cb[8 + guest_cert.len] = 0;
    f += wrap(flight[f..], 11, cb[0 .. 9 + guest_cert.len]);
    // CertificateVerify and Finished need the handshake secrets. Computed by the caller
    // after this returns only the prefix? The finished MAC needs traffic keys, which need
    // the transcript through ServerHello, then the CV signature needs transcript through Certificate.
    // Do it here with a local key schedule so the flight is complete.
    const sh_len = msgEnd(flight[0..f], 0);
    var tr: [5000]u8 = undefined;
    @memcpy(tr[0..ch.len], ch);
    @memcpy(tr[ch.len..][0..sh_len], flight[0..sh_len]);
    var th: [32]u8 = undefined;
    Sha256.hash(tr[0 .. ch.len + sh_len], &th, .{});
    const zeros = [_]u8{0} ** 32;
    const early = Hkdf.extract(&zeros, &zeros);
    const empty = emptyHash();
    var derived: [32]u8 = undefined;
    expandLabel(early, "derived", &empty, &derived);
    const hs = Hkdf.extract(&derived, shared);
    var shs: [32]u8 = undefined;
    expandLabel(hs, "s hs traffic", &th, &shs);
    // transcript through certificate
    const cert_end = f;
    @memcpy(tr[ch.len..][0..cert_end], flight[0..cert_end]);
    Sha256.hash(tr[0 .. ch.len + cert_end], &th, .{});
    var signed_msg: [160]u8 = undefined;
    @memset(signed_msg[0..64], ' ');
    const ctx = "TLS 1.3, server CertificateVerify";
    @memcpy(signed_msg[64..][0..ctx.len], ctx);
    signed_msg[64 + ctx.len] = 0;
    @memcpy(signed_msg[64 + ctx.len + 1 ..][0..32], &th);
    const sk = Scheme.SecretKey.fromBytes(guest_key) catch return 0;
    const kp = Scheme.KeyPair.fromSecretKey(sk) catch return 0;
    const sig = kp.sign(signed_msg[0 .. 64 + ctx.len + 1 + 32], null) catch return 0;
    var derb: [Scheme.Signature.der_encoded_length_max]u8 = undefined;
    const der = sig.toDer(&derb);
    var cvb: [80]u8 = undefined;
    cvb[0] = 0x04;
    cvb[1] = 0x03;
    cvb[2] = @truncate(der.len >> 8);
    cvb[3] = @truncate(der.len);
    @memcpy(cvb[4..][0..der.len], der);
    f += wrap(flight[f..], 15, cvb[0 .. 4 + der.len]);
    @memcpy(tr[ch.len..][0..f], flight[0..f]);
    Sha256.hash(tr[0 .. ch.len + f], &th, .{});
    var fk: [32]u8 = undefined;
    expandLabel(shs, "finished", "", &fk);
    var vd: [32]u8 = undefined;
    HmacSha256.create(&vd, &th, &fk);
    var fb: [32]u8 = undefined;
    @memcpy(&fb, &vd);
    f += wrap(flight[f..], 20, &fb);
    if (f > out.len) return 0;
    @memcpy(out[0..f], flight[0..f]);
    return f;
}

fn params(out: []u8, scid: *const [8]u8, orig: ?*const [8]u8) usize {
    var n: usize = 0;
    if (orig) |o| n += putTp(out, n, 0x00, o);
    n += tpVar(out, n, 0x04, 16000);
    n += tpVar(out, n, 0x05, 16000);
    n += tpVar(out, n, 0x06, 16000);
    n += tpVar(out, n, 0x08, 1);
    n += putTp(out, n, 0x0f, scid);
    return n;
}
fn putTp(out: []u8, at: usize, id: u64, v: []const u8) usize {
    var n = at;
    n += putVar(out[n..], id);
    n += putVar(out[n..], v.len);
    @memcpy(out[n..][0..v.len], v);
    return n + v.len - at;
}
fn tpVar(out: []u8, at: usize, id: u64, v: u64) usize {
    var tmp: [8]u8 = undefined;
    const n = putVar(&tmp, v);
    return putTp(out, at, id, tmp[0..n]);
}
fn extOne(ext: []u8, at: usize, id: u16, v: []const u8) usize {
    std.mem.writeInt(u16, ext[at..][0..2], id, .big);
    std.mem.writeInt(u16, ext[at + 2 ..][0..2], @intCast(v.len), .big);
    @memcpy(ext[at + 4 ..][0..v.len], v);
    return 4 + v.len;
}
fn wrap(out: []u8, kind: u8, body: []const u8) usize {
    out[0] = kind;
    out[1] = @truncate(body.len >> 16);
    out[2] = @truncate(body.len >> 8);
    out[3] = @truncate(body.len);
    @memcpy(out[4..][0..body.len], body);
    return 4 + body.len;
}

pub fn rfcInitialKey() bool {
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };
    var k: Keys = .{};
    var o: Keys = .{};
    installPair(&k, &o, &dcid, false);
    const key = [_]u8{ 0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46, 0x77, 0x30, 0xef, 0xcb, 0xe3, 0xb1, 0xa2, 0x2d };
    const iv = [_]u8{ 0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b, 0x46, 0xfb, 0x25, 0x5c };
    const hp = [_]u8{ 0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10, 0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2 };
    return std.mem.eql(u8, &k.key, &key) and std.mem.eql(u8, &k.iv, &iv) and std.mem.eql(u8, &k.hp, &hp);
}

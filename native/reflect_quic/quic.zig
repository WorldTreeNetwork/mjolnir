//! QUIC v1, one stream, TLS_AES_128_GCM_SHA256, X25519, Ed25519 raw public
//! keys on both ends (RFC 7250). Each end has an entity key and a list of the
//! names it will finish a handshake with. No key is in this file.
//! The caller supplies monotonic nanoseconds. This file does not read programs.

const std = @import("std");
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Aes128 = std.crypto.core.aes.Aes128;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const X25519 = std.crypto.dh.X25519;
const entity = @import("entity.zig");
const Ed = entity.Ed;

const initial_salt = [_]u8{ 0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a };
/// SubjectPublicKeyInfo of an Ed25519 key, up to the key (RFC 8410).
const spki = [12]u8{ 0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00 };
/// The body of the CertificateRequest: no context, signature_algorithms ed25519.
const cert_request = [11]u8{ 0x00, 0x00, 0x08, 0x00, 0x0d, 0x00, 0x04, 0x00, 0x02, 0x08, 0x07 };

/// What `Conn.tamper` is handed besides a handshake message type: the hash
/// about to be signed, and room after the flight.
pub const tamper_hash: u8 = 0xff;
pub const tamper_trailer: u8 = 0xfe;

pub const min_initial: usize = 1200;

/// A flight is sent at most this many times and then given up.
pub const max_tries: u8 = 10;
/// A resend waits 20 ms shifted left by the tries so far, at most by this.
const max_shift: u8 = 6;
/// Before a server has validated the client's address it sends at most this
/// many times the bytes it has received (RFC 9000 section 8.1).
pub const amplification: u64 = 3;

/// Whether a datagram has the shape of a client's first flight for a
/// connection other than `current`: at least 1200 bytes, a version 1 Initial,
/// 8-byte connection IDs, and a destination ID that is not `current`. Whether
/// it opens is for `recv` on a fresh server connection to say.
pub fn newInitial(dgram: []const u8, current: *const [8]u8) bool {
    if (dgram.len < min_initial) return false;
    if (dgram[0] & 0xf0 != 0xc0) return false;
    if (std.mem.readInt(u32, dgram[1..5], .big) != 1) return false;
    if (dgram[5] != 8 or dgram[14] != 8) return false;
    return !std.mem.eql(u8, dgram[6..14], current);
}

const Keys = struct { key: [16]u8 = .{0} ** 16, iv: [12]u8 = .{0} ** 12, hp: [16]u8 = .{0} ** 16, on: bool = false, pn: u32 = 0 };
/// A flight: its frames, and the packet numbers it has gone out as so far,
/// `first` to `pn`. No other packet of its space is sent while it is on.
const Pend = struct { on: bool = false, spent: bool = false, frames: [1400]u8 = undefined, len: usize = 0, first: u32 = 0, pn: u32 = 0, at: u64 = 0, tries: u8 = 0 };
const Holey = struct { buf: [8192]u8 = .{0} ** 8192, got: [8192]u8 = .{0} ** 8192, n: usize = 0 };

pub const Conn = struct {
    server: bool,
    /// This end's key, and the names it finishes a handshake with.
    id: *const entity.Identity,
    allow: *const entity.Allow,
    /// The name of the other end's key, once the handshake was accepted.
    peer_name: entity.Name = .{0} ** 32,
    /// Test seams, unset outside `quic-self`: the key this end signs with
    /// when it is not the key it presents, and a function handed each
    /// handshake message as it is built, before it enters this end's own
    /// transcript. It returns the body's new length, or null to leave the
    /// message out.
    signer: ?*const entity.Identity = null,
    tamper: ?*const fn (c: *const Conn, kind: u8, buf: []u8, len: usize) ?usize = null,
    server_trail: usize = 0,
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
    /// A packet that asks for an acknowledgement (one with a frame other than
    /// ACK and PADDING) opened in this space and no packet sent since has
    /// acknowledged it.
    ack_due: [3]bool = .{ false, false, false },
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
    opens: u64 = 0,
    dgram: usize = 0,
    /// A server has opened a Handshake packet: the client reads what is sent
    /// to its address. Until then `tx_bytes` stays within `amplification`
    /// times `rx_bytes`, the bytes of the datagrams that opened.
    validated: bool = false,
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    rand: *const fn () u64,

    pub fn openClient(rand: *const fn () u64, id: *const entity.Identity, allow: *const entity.Allow) Conn {
        var c = Conn{ .server = false, .rand = rand, .id = id, .allow = allow };
        fill(&c.local_cid, rand);
        fill(&c.peer_cid, rand);
        c.orig_dcid = c.peer_cid;
        c.secret = rand32(rand);
        c.share = X25519.recoverPublicKey(c.secret) catch .{0} ** 32;
        c.client_hello_len = buildClientHello(c.client_hello[0..], &rand32(rand), &c.share, &c.local_cid);
        installPair(&c.initial, &c.open_initial, &c.peer_cid, false);
        var wrapped: [1100]u8 = undefined;
        const wn = cryptoFrame(&wrapped, c.client_hello[0..c.client_hello_len]);
        arm(&c, 0, wrapped[0..wn], 0);
        return c;
    }

    pub fn openServer(rand: *const fn () u64, id: *const entity.Identity, allow: *const entity.Allow) Conn {
        var c = Conn{ .server = true, .rand = rand, .id = id, .allow = allow };
        fill(&c.local_cid, rand);
        return c;
    }

    /// Take one datagram. True when at least one of its packets opened: its
    /// tag checked under this connection's keys and its frames are ones its
    /// space allows. A datagram that returns false has changed nothing, and
    /// a refused connection takes nothing.
    pub fn recv(c: *Conn, pkt: []const u8, now: u64) bool {
        if (c.refused) return false;
        const before = c.opens;
        c.dgram = pkt.len;
        var i: usize = 0;
        while (i < pkt.len) {
            const n = c.one(pkt[i..], now) orelse break;
            if (n == 0) break;
            i += n;
        }
        if (c.opens == before) return false;
        c.rx_bytes += pkt.len;
        return true;
    }

    /// One datagram, or 0 when there is nothing to send. A space sends its
    /// flight when it is due, and otherwise a packet with only an ACK frame
    /// when one is owed and no flight of its own is on (`ackOnly`): an end
    /// with nothing more to say still acknowledges what it was sent, so the
    /// other end stops resending it.
    pub fn send(c: *Conn, out: []u8, now: u64) usize {
        // A refused connection says nothing more, an acknowledgement included.
        if (c.refused) return 0;
        var flight: [3]bool = undefined;
        var go: [3]bool = undefined;
        var s: usize = 0;
        while (s < 3) : (s += 1) {
            flight[s] = c.due(s, now);
            go[s] = flight[s] or c.ackOnly(s);
        }
        // A server expands a datagram that carries its Initial flight to
        // 1200 bytes (RFC 9000 section 14.1) with PADDING in the Initial
        // packet, so that packet is sized by what follows it.
        var after: usize = 0;
        if (c.server and flight[0]) {
            s = 1;
            while (s < 3) : (s += 1) {
                if (go[s]) after += c.packetSize(s, flight[s], 0);
            }
        }
        var n: usize = 0;
        s = 0;
        while (s < 3) : (s += 1) {
            if (!go[s]) continue;
            const pad_to: usize = if (s == 0 and c.server and flight[0]) min_initial -| after else 0;
            const wrote = c.seal(s, out[n..], now, flight[s], pad_to, if (s == 0) after else 0) orelse continue;
            n += wrote;
        }
        return n;
    }

    /// Whether space `s` owes an acknowledgement it can send on its own.
    /// A client that has its Finished to send is done with the Initial
    /// space (RFC 9001 section 4.9.1) and acknowledges nothing more in it.
    fn ackOnly(c: *Conn, s: usize) bool {
        if (s == 0 and !c.server and c.client_fin_sent) return false;
        return c.ack_due[s] and !c.pend[s].on and c.spaceKeys(s).on;
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

    /// Put a STREAM frame with FIN after the frames of the flight in
    /// `space`. A test seam: an end that follows the rules sends stream data
    /// in 1-RTT packets only, and `recv` drops a packet that does otherwise.
    pub fn earlyStream(c: *Conn, space: usize, data: []const u8) bool {
        const p = &c.pend[space];
        if (!p.on or p.len + data.len + 8 > p.frames.len) return false;
        p.len += streamFrame(p.frames[p.len..], data, true);
        return true;
    }

    /// Whether a flight of this end's was sent `max_tries` times, and the
    /// wait after the last send has passed with no acknowledgement.
    pub fn gaveUp(c: *const Conn, now: u64) bool {
        for (c.pend) |p| {
            if (p.spent and now >= p.at +% (@as(u64, 20_000_000) << max_shift)) return true;
        }
        return false;
    }

    /// The peer's stream once it has ended, on an accepted connection only.
    pub fn readApp(c: *Conn) []const u8 {
        if (!c.accepted or !c.peer_fin) return "";
        return c.app_rx.buf[0..c.app_rx.n];
    }

    fn due(c: *Conn, s: usize, now: u64) bool {
        const p = &c.pend[s];
        if (!p.on) return false;
        const keys = c.spaceKeys(s);
        if (!keys.on) return false;
        if (p.tries == 0) return true;
        const wait = @as(u64, 20_000_000) << @intCast(@min(p.tries, max_shift));
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
        o += ln.len;
        if (o + ln.v > pkt.len) return null;
        const total = o + ln.v;
        const space: usize = if (kind == 0) 0 else if (kind == 2) 1 else return total;
        // A server's first Initial names the keys it is opened with. They
        // stay only if it opens, and only a datagram of at least 1200 bytes
        // (RFC 9000 section 14.1) may start a connection.
        var first = false;
        if (c.server and !c.initial.on and space == 0) {
            if (c.dgram < min_initial) return total;
            @memcpy(&c.orig_dcid, dcid);
            installPair(&c.initial, &c.open_initial, &c.orig_dcid, true);
            first = true;
        }
        const opened = c.open(space, pkt[0..total], o);
        // The frames are walked before anything is changed. A packet with a
        // frame its space does not allow counts as not opened.
        if (opened == null or !c.allowed(space, opened.?.data)) {
            if (first) {
                c.initial.on = false;
                c.open_initial.on = false;
            }
            return total;
        }
        const plain = opened.?;
        c.opens += 1;
        // The peer's connection ID is taken from a packet that opened.
        if (space == 0 and (first or !c.server)) @memcpy(&c.peer_cid, scid);
        // A Handshake packet that opens on a server was sealed with keys made
        // from the ServerHello, so the client has it and reads what is sent
        // to its address: the address is validated (RFC 9000 section 8.1) and
        // the Initial space is finished, its flight and its opening keys
        // (RFC 9001 section 4.9.1).
        if (space == 1 and c.server and !c.validated) {
            c.validated = true;
            c.pend[0].on = false;
            c.ack_due[0] = false;
            c.open_initial.on = false;
        }
        c.mark(space, plain.pn);
        c.takeFrames(space, plain.data, now);
        return total;
    }

    fn short(c: *Conn, pkt: []const u8, now: u64) ?usize {
        if (!c.app.on or pkt.len < 1 + 8 + 4 + 16) return null;
        const total = pkt.len;
        const plain = c.open(2, pkt[0..total], 1 + 8) orelse return null;
        if (!c.allowed(2, plain.data)) return null;
        c.opens += 1;
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

    /// The bytes of a packet in `space` with `n` bytes of frames, padded
    /// to at least `pad_to`, and the bytes of its header (`h`) and of its
    /// Length field (`len`, 0 for a short header). The Length is written in
    /// its shortest form; a padded packet has a Length of at least 64, two
    /// bytes, so it may come out a little over `pad_to`.
    const Size = struct { total: usize, h: usize, len: usize };
    fn size(space: usize, n: usize, pad_to: usize) Size {
        if (space == 2) {
            const total = 9 + 4 + n + 16;
            return .{ .total = @max(total, pad_to), .h = 9, .len = 0 };
        }
        const h0: usize = if (space == 0) 23 + 1 else 23;
        const body = 4 + n + 16;
        const plain = h0 + varLen(body) + body;
        if (plain >= pad_to) return .{ .total = plain, .h = h0 + varLen(body), .len = varLen(body) };
        const rest = @max(pad_to - h0 - 2, 64);
        return .{ .total = h0 + 2 + rest, .h = h0 + 2, .len = 2 };
    }

    /// The bytes of the packet `seal` would make in `space` now.
    fn packetSize(c: *Conn, space: usize, flight: bool, pad_to: usize) usize {
        var frame: [32]u8 = undefined;
        var n = ackFrame(&frame, c, space);
        if (flight) n += c.pend[space].len;
        return size(space, n, pad_to).total;
    }

    /// Seal one packet in `space` into `out`: the flight when `flight`, else
    /// an ACK frame alone, which changes nothing about the flight. `after`
    /// is how many bytes the datagram will carry after this packet, for the
    /// limit on what an address not yet validated is sent.
    fn seal(c: *Conn, space: usize, out: []u8, now: u64, flight: bool, pad_to: usize, after: usize) ?usize {
        const k = c.spaceKeys(space);
        const p = &c.pend[space];
        if (!k.on or (flight and !p.on)) return null;
        var frames: [1500]u8 = undefined;
        var n: usize = ackFrame(frames[0..], c, space);
        if (n == 0 and !flight) return null;
        if (flight) {
            @memcpy(frames[n..][0..p.len], p.frames[0..p.len]);
            n += p.len;
        }
        const pn = k.pn;
        const long = space < 2;
        var hdr: [64]u8 = undefined;
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
            if (space == 0) hdr[23] = 0; // no token
        } else {
            hdr[0] = 0x40 | 0x03;
            @memcpy(hdr[1..9], &dcid);
        }
        // Every datagram a client sends with an Initial packet is 1200 bytes
        // or more; a server's Initial flight is padded so its datagram is
        // (`send`).
        const want = if (space == 0 and !c.server) @max(pad_to, min_initial) else pad_to;
        const sz = size(space, n, want);
        const pad = sz.total;
        const h = sz.h;
        if (pad > out.len or pad > 1400) return null;
        if (long) {
            hdr[h - sz.len] = 0;
            _ = putVar(hdr[h - sz.len .. h], pad - h);
        }
        // An address that has not been validated is sent no more than
        // `amplification` times what came from it, counting the rest of the
        // datagram. A packet over the limit is not sent and not counted as a
        // try; it goes when more arrives.
        if (c.server and !c.validated and c.tx_bytes + pad + after > amplification * c.rx_bytes) return null;
        k.pn += 1;
        @memset(out[0..pad], 0);
        @memcpy(out[0..h], hdr[0..h]);
        std.mem.writeInt(u32, out[h..][0..4], pn, .big);
        var sealed: [1400]u8 = undefined;
        @memcpy(sealed[0..n], frames[0..n]);
        @memset(sealed[n .. pad - (h + 4) - 16], 0); // PADDING
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
        c.tx_bytes += pad;
        // Every packet carries the space's ACK frame, so nothing is owed now.
        c.ack_due[space] = false;
        if (flight) {
            if (p.tries == 0) p.first = pn;
            p.pn = pn;
            p.at = now;
            p.tries += 1;
            // A flight nobody acknowledges is given up, not resent for ever.
            if (p.tries >= max_tries) {
                p.on = false;
                p.spent = true;
            }
        }
        // A client that sends a Handshake packet has the ServerHello, so its
        // Initial flight arrived: that space is finished (RFC 9001 4.9.1).
        if (!c.server and space == 1) {
            c.pend[0].on = false;
            c.ack_due[0] = false;
        }
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
            if (t == 0x02) {
                i = c.ack(space, data, i, true) orelse return;
                continue;
            }
            if (t == 0x06 and space < 2) {
                const off = getVar(data[i + 1 ..]) orelse return;
                const o1 = i + 1 + off.len;
                const ln = getVar(data[o1..]) orelse return;
                const o2 = o1 + ln.len;
                if (o2 + ln.v > data.len) return;
                const dest = if (space == 0) &c.init_rx else &c.hs_rx;
                holePut(dest, off.v, data[o2 .. o2 + ln.v]);
                c.ack_due[space] = true;
                i = o2 + ln.v;
                continue;
            }
            if (t >= 0x08 and t <= 0x0f and space == 2) {
                var o = i + 1;
                const id = getVar(data[o..]) orelse return;
                o += id.len;
                var off: u64 = 0;
                if (t & 0x04 != 0) {
                    const v = getVar(data[o..]) orelse return;
                    off = v.v;
                    o += v.len;
                }
                var ln: u64 = 0;
                if (t & 0x02 != 0) {
                    const v = getVar(data[o..]) orelse return;
                    ln = v.v;
                    o += v.len;
                } else ln = data.len - o;
                if (o + ln > data.len) return;
                holePut(&c.app_rx, off, data[o .. o + ln]);
                // The second gate: 1-RTT keys exist only once accepted.
                if (t & 0x01 != 0 and c.accepted) c.peer_fin = true;
                c.ack_due[space] = true;
                i = o + ln;
                continue;
            }
            return;
        }
        if (space == 0 and c.server) c.onClientHello();
        if (space == 0 and !c.server) c.onServerHello();
        if (space == 1 and !c.server) c.onServerFlight();
        if (space == 1 and c.server) c.onClientFlight();
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
        c.server_flight_len = buildServerFlight(c, c.server_flight[0..], c.client_hello[0..c.client_hello_len], &shared);
        if (c.server_flight_len == 0) return;
        const sh_end = msgEnd(c.server_flight[0..c.server_flight_len], 0);
        installHandshake(c, c.client_hello[0..c.client_hello_len], c.server_flight[0..sh_end], shared);
        c.init_rx = .{};
        var wrapped: [4200]u8 = undefined;
        const w0 = cryptoFrame(&wrapped, c.server_flight[0..sh_end]);
        arm(c, 0, wrapped[0..w0], 0);
        const w1 = cryptoFrame(&wrapped, c.server_flight[sh_end .. c.server_flight_len + c.server_trail]);
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

    fn refuse(c: *Conn) void {
        c.refused = true;
    }

    /// The server's Handshake flight: EncryptedExtensions, CertificateRequest,
    /// Certificate, CertificateVerify, Finished, and nothing after. The
    /// client waits while a message is incomplete and refuses when a
    /// complete one is not the next of these.
    fn onServerFlight(c: *Conn) void {
        if (c.server or c.server_done or c.refused) return;
        if (c.server_flight_len == 0) return;
        const flight = c.hs_rx.buf[0..holeEnd(&c.hs_rx)];
        var o: usize = 0;
        const ee = switch (nextMsg(flight, &o, 8)) {
            .wait => return,
            .bad => return c.refuse(),
            .msg => |m| m,
        };
        const cr = switch (nextMsg(flight, &o, 13)) {
            .wait => return,
            .bad => return c.refuse(),
            .msg => |m| m,
        };
        const certm = switch (nextMsg(flight, &o, 11)) {
            .wait => return,
            .bad => return c.refuse(),
            .msg => |m| m,
        };
        const through_cert = o;
        const cv = switch (nextMsg(flight, &o, 15)) {
            .wait => return,
            .bad => return c.refuse(),
            .msg => |m| m,
        };
        const through_cv = o;
        const fin = switch (nextMsg(flight, &o, 20)) {
            .wait => return,
            .bad => return c.refuse(),
            .msg => |m| m,
        };
        const through_fin = o;
        if (o != flight.len) return c.refuse(); // bytes after Finished
        if (!rawKeysChosen(ee)) return c.refuse();
        if (!std.mem.eql(u8, cr[4..], &cert_request)) return c.refuse();
        // The server's name is on this end's list, or nothing more is said.
        const key = certKey(certm) orelse return c.refuse();
        const name = entity.nameOf(&key);
        if (!c.allow.has(&name)) return c.refuse();
        var tr: [6000]u8 = undefined;
        const pre = c.client_hello_len + c.server_flight_len;
        if (pre + through_fin + 400 > tr.len) return c.refuse();
        @memcpy(tr[0..c.client_hello_len], c.client_hello[0..c.client_hello_len]);
        @memcpy(tr[c.client_hello_len..][0..c.server_flight_len], c.server_flight[0..c.server_flight_len]);
        @memcpy(tr[pre..][0..through_fin], flight[0..through_fin]);
        var th: [32]u8 = undefined;
        Sha256.hash(tr[0 .. pre + through_cert], &th, .{});
        if (!verifySig(cv, &key, "TLS 1.3, server CertificateVerify", &th)) return c.refuse();
        Sha256.hash(tr[0 .. pre + through_cv], &th, .{});
        const expect = finished(&c.peer_hs, &th);
        if (fin.len != 36 or !std.crypto.timing_safe.eql([32]u8, fin[4..36].*, expect)) return c.refuse();
        // The application secrets come from the transcript through the
        // server's Finished and nothing after it (RFC 8446 section 7.1).
        var n = pre + through_fin;
        Sha256.hash(tr[0..n], &th, .{});
        installApp(c, &th);
        // This end's key, a signature over the transcript so far, Finished.
        var out: [600]u8 = undefined;
        var f: usize = 0;
        f += c.message(out[f..], 11, &certBody(&c.id.public));
        @memcpy(tr[n..][0..f], out[0..f]);
        Sha256.hash(tr[0 .. n + f], &th, .{});
        const sig = c.sign("TLS 1.3, client CertificateVerify", &th) orelse return c.refuse();
        const cv_at = f;
        f += c.message(out[f..], 15, &cvBody(&sig));
        @memcpy(tr[n + cv_at ..][0 .. f - cv_at], out[cv_at..f]);
        n += f;
        Sha256.hash(tr[0..n], &th, .{});
        const mine = finished(&c.local_hs, &th);
        f += c.message(out[f..], 20, &mine);
        f += c.trailer(out[f..]);
        c.hs_rx = .{};
        var wrapped: [700]u8 = undefined;
        const wn = cryptoFrame(&wrapped, out[0..f]);
        arm(c, 1, wrapped[0..wn], 0);
        c.client_fin_sent = true;
        c.peer_name = name;
        c.accepted = true;
        c.server_done = true;
    }

    /// The client's Handshake flight: Certificate, CertificateVerify,
    /// Finished, and nothing after. The 1-RTT keys are made only when the
    /// client's name is on the list and its signature and Finished check.
    fn onClientFlight(c: *Conn) void {
        if (!c.server or c.accepted or c.refused) return;
        const flight = c.hs_rx.buf[0..holeEnd(&c.hs_rx)];
        var o: usize = 0;
        const certm = switch (nextMsg(flight, &o, 11)) {
            .wait => return,
            .bad => return c.refuse(),
            .msg => |m| m,
        };
        const through_cert = o;
        const cv = switch (nextMsg(flight, &o, 15)) {
            .wait => return,
            .bad => return c.refuse(),
            .msg => |m| m,
        };
        const through_cv = o;
        const fin = switch (nextMsg(flight, &o, 20)) {
            .wait => return,
            .bad => return c.refuse(),
            .msg => |m| m,
        };
        if (o != flight.len) return c.refuse(); // bytes after Finished
        const key = certKey(certm) orelse return c.refuse();
        const name = entity.nameOf(&key);
        if (!c.allow.has(&name)) return c.refuse();
        var tr: [6000]u8 = undefined;
        const pre = c.client_hello_len + c.server_flight_len;
        if (pre + through_cv > tr.len) return c.refuse();
        @memcpy(tr[0..c.client_hello_len], c.client_hello[0..c.client_hello_len]);
        @memcpy(tr[c.client_hello_len..][0..c.server_flight_len], c.server_flight[0..c.server_flight_len]);
        @memcpy(tr[pre..][0..through_cv], flight[0..through_cv]);
        var th: [32]u8 = undefined;
        Sha256.hash(tr[0 .. pre + through_cert], &th, .{});
        if (!verifySig(cv, &key, "TLS 1.3, client CertificateVerify", &th)) return c.refuse();
        Sha256.hash(tr[0 .. pre + through_cv], &th, .{});
        const expect = finished(&c.peer_hs, &th);
        if (fin.len != 36 or !std.crypto.timing_safe.eql([32]u8, fin[4..36].*, expect)) return c.refuse();
        Sha256.hash(tr[0..pre], &th, .{});
        installApp(c, &th);
        c.peer_name = name;
        c.accepted = true;
        // The handshake pend is done once we have the client's finished.
        c.pend[1].on = false;
    }

    /// One handshake message into `out`, after `tamper` has seen its body.
    fn message(c: *const Conn, out: []u8, kind: u8, body: []const u8) usize {
        var b: [600]u8 = undefined;
        @memcpy(b[0..body.len], body);
        var n = body.len;
        if (c.tamper) |t| n = t(c, kind, &b, n) orelse return 0;
        return wrap(out, kind, b[0..n]);
    }

    fn trailer(c: *const Conn, out: []u8) usize {
        const t = c.tamper orelse return 0;
        var b: [64]u8 = undefined;
        const n = t(c, tamper_trailer, &b, 0) orelse return 0;
        @memcpy(out[0..n], b[0..n]);
        return n;
    }

    /// This end's CertificateVerify signature over a transcript hash.
    fn sign(c: *const Conn, comptime ctx: []const u8, th: *const [32]u8) ?[64]u8 {
        var h = th.*;
        if (c.tamper) |t| _ = t(c, tamper_hash, &h, 32);
        var m: [64 + ctx.len + 1 + 32]u8 = undefined;
        @memset(m[0..64], ' ');
        @memcpy(m[64..][0..ctx.len], ctx);
        m[64 + ctx.len] = 0;
        @memcpy(m[64 + ctx.len + 1 ..], &h);
        const who = c.signer orelse c.id;
        const sig = who.pair.sign(&m, null) catch return null;
        return sig.toBytes();
    }

    /// Whether every frame of a packet is one this stack reads and its
    /// space allows: PADDING and ACK anywhere, CRYPTO in Initial and
    /// Handshake, STREAM in 1-RTT only (RFC 9000 section 12.4; the CRYPTO
    /// rule is stricter than the RFC). Nothing is changed.
    fn allowed(c: *Conn, space: usize, data: []const u8) bool {
        var i: usize = 0;
        while (i < data.len) {
            const t = data[i];
            if (t == 0) {
                i += 1;
            } else if (t == 0x02) {
                i = c.ack(space, data, i, false) orelse return false;
            } else if (t == 0x06) {
                if (space == 2) return false;
                const off = getVar(data[i + 1 ..]) orelse return false;
                const o1 = i + 1 + off.len;
                const ln = getVar(data[o1..]) orelse return false;
                const o2 = o1 + ln.len;
                if (ln.v > data.len or o2 + ln.v > data.len) return false;
                i = o2 + @as(usize, @intCast(ln.v));
            } else if (t >= 0x08 and t <= 0x0f) {
                if (space != 2) return false;
                var o = i + 1;
                const id = getVar(data[o..]) orelse return false;
                o += id.len;
                if (t & 0x04 != 0) {
                    const v = getVar(data[o..]) orelse return false;
                    o += v.len;
                }
                if (t & 0x02 != 0) {
                    const v = getVar(data[o..]) orelse return false;
                    o += v.len;
                    if (v.v > data.len or o + v.v > data.len) return false;
                    i = o + @as(usize, @intCast(v.v));
                } else i = data.len;
            } else return false;
        }
        return true;
    }

    /// Step over an ACK frame, applying its ranges when `apply`.
    fn ack(c: *Conn, space: usize, data: []const u8, at: usize, apply: bool) ?usize {
        var o = at + 1;
        const largest = getVar(data[o..]) orelse return null;
        o += largest.len;
        const delay = getVar(data[o..]) orelse return null;
        o += delay.len;
        const count = getVar(data[o..]) orelse return null;
        o += count.len;
        const first = getVar(data[o..]) orelse return null;
        o += first.len;
        if (first.v > largest.v) return null;
        var hi = largest.v;
        var lo = largest.v - first.v;
        if (apply) c.acked(space, lo, hi);
        var n: u64 = 0;
        while (n < count.v) : (n += 1) {
            const gap = getVar(data[o..]) orelse return null;
            o += gap.len;
            const ln = getVar(data[o..]) orelse return null;
            o += ln.len;
            if (gap.v + 2 > lo or ln.v > lo - gap.v - 2) return null;
            hi = lo - gap.v - 2;
            lo = hi - ln.v;
            if (apply) c.acked(space, lo, hi);
        }
        return o;
    }

    /// An acknowledgement is for the packet number space it arrived in and
    /// no other (RFC 9002 section 3): the same number in another space is
    /// another packet, which may be lost.
    ///
    /// The range `lo` to `hi` acknowledges the flight when it holds any
    /// packet number the flight went out as: every packet of the space from
    /// its first send to its last was a copy of it, so any copy arriving is
    /// the flight arriving.
    fn acked(c: *Conn, space: usize, lo: u64, hi: u64) void {
        const p = &c.pend[space];
        if ((!p.on and !p.spent) or p.tries == 0 or hi < p.first or lo > p.pn) return;
        p.on = false;
        p.spent = false;
        // A client whose 1-RTT packet is acknowledged holds a confirmed
        // handshake (RFC 9001 section 4.1.2): the server took its Finished,
        // which no Handshake packet will acknowledge.
        if (space == 2 and !c.server) {
            c.pend[1].on = false;
            c.pend[1].spent = false;
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
    p.spent = false;
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
const Next = union(enum) { wait, bad, msg: []const u8 };
/// The next handshake message, which must be of `kind`. `wait` while its
/// bytes are not all there; `bad` when a message of another kind is.
fn nextMsg(b: []const u8, o: *usize, kind: u8) Next {
    if (o.* + 4 > b.len) return .wait;
    if (b[o.*] != kind) return .bad;
    const ln = read24(b[o.* + 1 ..]);
    if (ln > 1024) return .bad;
    if (o.* + 4 + ln > b.len) return .wait;
    const m = b[o.* .. o.* + 4 + ln];
    o.* += 4 + ln;
    return .{ .msg = m };
}

/// The body of a Certificate message that holds one raw public key.
fn certBody(public: *const [32]u8) [53]u8 {
    var b: [53]u8 = undefined;
    b[0] = 0; // no context
    b[1] = 0;
    b[2] = 0;
    b[3] = 49; // the list: one entry
    b[4] = 0;
    b[5] = 0;
    b[6] = 44;
    @memcpy(b[7..19], &spki);
    @memcpy(b[19..51], public);
    b[51] = 0; // no entry extensions
    b[52] = 0;
    return b;
}

/// The key of a Certificate message: an empty context, and exactly one
/// entry, the SubjectPublicKeyInfo of an Ed25519 key with no extensions.
fn certKey(m: []const u8) ?[32]u8 {
    const body = m[4..];
    if (body.len < 4) return null;
    const ctx: usize = body[0];
    if (ctx != 0) return null; // rule: no context
    var o: usize = 1 + ctx;
    if (o + 3 > body.len) return null;
    const list = read24(body[o..]);
    o += 3;
    if (o + list != body.len) return null;
    if (o + 3 > body.len) return null;
    const n = read24(body[o..]);
    o += 3;
    if (n != 44 or o + 44 + 2 > body.len) return null;
    if (!std.mem.eql(u8, body[o .. o + 12], &spki)) return null; // rule: the Ed25519 prefix
    var key: [32]u8 = undefined;
    @memcpy(&key, body[o + 12 .. o + 44]);
    o += 44;
    const ext: usize = (@as(usize, body[o]) << 8) | body[o + 1];
    o += 2;
    if (ext != 0) return null; // rule: no entry extensions
    if (o + ext > body.len) return null;
    o += ext;
    if (o != body.len) return null; // rule: one entry
    return key;
}

/// Whether EncryptedExtensions chose raw public keys for both ends.
fn rawKeysChosen(m: []const u8) bool {
    const body = m[4..];
    if (body.len < 2) return false;
    const total: usize = (@as(usize, body[0]) << 8) | body[1];
    if (2 + total != body.len) return false;
    var o: usize = 2;
    var client = false;
    var server = false;
    while (o < body.len) {
        if (o + 4 > body.len) return false;
        const id = std.mem.readInt(u16, body[o..][0..2], .big);
        const ln: usize = std.mem.readInt(u16, body[o + 2 ..][0..2], .big);
        o += 4;
        if (o + ln > body.len) return false;
        if (id == 0x0013 or id == 0x0014) {
            if (ln != 1 or body[o] != 2) return false;
            if (id == 0x0013) client = true else server = true;
        }
        o += ln;
    }
    return client and server;
}

fn cvBody(sig: *const [64]u8) [68]u8 {
    var b: [68]u8 = undefined;
    b[0] = 0x08;
    b[1] = 0x07;
    b[2] = 0;
    b[3] = 64;
    @memcpy(b[4..68], sig);
    return b;
}

/// A CertificateVerify: the scheme ed25519, a 64-byte signature, and the
/// signature checks over the context and the transcript hash.
fn verifySig(cv: []const u8, key: *const [32]u8, comptime ctx: []const u8, th: *const [32]u8) bool {
    const body = cv[4..];
    if (body.len < 4 + 64) return false;
    if (body[0] != 0x08 or body[1] != 0x07) return false; // rule: the scheme
    const siglen: usize = (@as(usize, body[2]) << 8) | body[3];
    if (siglen != 64 or body.len != 4 + 64) return false; // rule: 64 bytes
    var m: [64 + ctx.len + 1 + 32]u8 = undefined;
    @memset(m[0..64], ' ');
    @memcpy(m[64..][0..ctx.len], ctx);
    m[64 + ctx.len] = 0;
    @memcpy(m[64 + ctx.len + 1 ..], th);
    const pk = Ed.PublicKey.fromBytes(key.*) catch return false;
    const sig = Ed.Signature.fromBytes(body[4..68].*);
    sig.verify(&m, pk) catch return false;
    return true;
}

fn buildClientHello(out: []u8, random: *const [32]u8, share: *const [32]u8, scid: *const [8]u8) usize {
    var ext: [256]u8 = undefined;
    var n: usize = 0;
    n += extOne(&ext, n, 0x002b, &[_]u8{ 0x02, 0x03, 0x04 });
    n += extOne(&ext, n, 0x000a, &[_]u8{ 0x00, 0x02, 0x00, 0x1d });
    n += extOne(&ext, n, 0x000d, &[_]u8{ 0x00, 0x02, 0x08, 0x07 }); // ed25519
    n += extOne(&ext, n, 0x0013, &[_]u8{ 0x01, 0x02 }); // the client's key: raw
    n += extOne(&ext, n, 0x0014, &[_]u8{ 0x01, 0x02 }); // the server's key: raw
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
    @memcpy(body[b..][0..32], random);
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

/// ServerHello through Finished. The return is the length the transcript
/// holds; `server_trail` bytes that `tamper` added follow it.
fn buildServerFlight(c: *Conn, out: []u8, ch: []const u8, shared: *const [32]u8) usize {
    var shb: [128]u8 = undefined;
    var b: usize = 0;
    shb[0] = 0x03;
    shb[1] = 0x03;
    b = 2;
    @memcpy(shb[b..][0..32], &rand32(c.rand));
    b += 32;
    shb[b] = 0;
    b += 1;
    shb[b] = 0x13;
    shb[b + 1] = 0x01;
    b += 2;
    shb[b] = 0;
    b += 1;
    var ext: [80]u8 = undefined;
    var n: usize = extOne(&ext, 0, 0x002b, &[_]u8{ 0x03, 0x04 });
    var ks: [40]u8 = undefined;
    ks[0] = 0x00;
    ks[1] = 0x1d;
    ks[2] = 0;
    ks[3] = 32;
    @memcpy(ks[4..36], &c.share);
    n += extOne(&ext, n, 0x0033, ks[0..36]);
    std.mem.writeInt(u16, shb[b..][0..2], @intCast(n), .big);
    b += 2;
    @memcpy(shb[b..][0..n], ext[0..n]);
    b += n;
    var flight: [4096]u8 = undefined;
    var f: usize = wrap(flight[0..], 2, shb[0..b]);
    const sh_len = f;
    // EncryptedExtensions: transport parameters, and raw public keys for
    // both ends (RFC 7250).
    var tp: [64]u8 = undefined;
    const tn = params(&tp, &c.local_cid, &c.orig_dcid);
    var ee: [100]u8 = undefined;
    var en = extOne(&ee, 0, 0x0039, tp[0..tn]);
    en += extOne(&ee, en, 0x0013, &[_]u8{0x02});
    en += extOne(&ee, en, 0x0014, &[_]u8{0x02});
    var eeb: [110]u8 = undefined;
    std.mem.writeInt(u16, eeb[0..2], @intCast(en), .big);
    @memcpy(eeb[2..][0..en], ee[0..en]);
    f += c.message(flight[f..], 8, eeb[0 .. 2 + en]);
    f += c.message(flight[f..], 13, &cert_request);
    f += c.message(flight[f..], 11, &certBody(&c.id.public));
    // The key schedule, to sign and to write Finished here.
    var tr: [5000]u8 = undefined;
    if (ch.len + f + 200 > tr.len) return 0;
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
    // CertificateVerify signs the transcript through Certificate.
    @memcpy(tr[ch.len..][0..f], flight[0..f]);
    Sha256.hash(tr[0 .. ch.len + f], &th, .{});
    const sig = c.sign("TLS 1.3, server CertificateVerify", &th) orelse return 0;
    f += c.message(flight[f..], 15, &cvBody(&sig));
    // Finished covers the transcript through CertificateVerify.
    @memcpy(tr[ch.len..][0..f], flight[0..f]);
    Sha256.hash(tr[0 .. ch.len + f], &th, .{});
    const vd = finished(&shs, &th);
    f += c.message(flight[f..], 20, &vd);
    c.server_trail = c.trailer(flight[f..]);
    if (f + c.server_trail > out.len) return 0;
    @memcpy(out[0 .. f + c.server_trail], flight[0 .. f + c.server_trail]);
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

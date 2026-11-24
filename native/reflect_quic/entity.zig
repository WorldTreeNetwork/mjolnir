//! An entity's key and its name. The key is Ed25519. The name is identikey's
//! fingerprint of the public key: Blake3 of the dCBOR of
//! {"alg": "ed25519", "key": <32 bytes>}. Its text form is base58, no prefix
//! and no checksum (identikey-protocol, auth-challenge v1 section 5 and
//! encoding-conventions). No key is in this file.

const std = @import("std");
pub const Ed = std.crypto.sign.Ed25519;
const Blake3 = std.crypto.hash.Blake3;

pub const Name = [32]u8;

/// dCBOR of the map up to the key's bytes: a2, "alg", "ed25519", "key", a
/// byte string of 32.
const prefix = [19]u8{ 0xa2, 0x63, 'a', 'l', 'g', 0x67, 'e', 'd', '2', '5', '5', '1', '9', 0x63, 'k', 'e', 'y', 0x58, 0x20 };

pub fn nameOf(public: *const [32]u8) Name {
    var in: [prefix.len + 32]u8 = undefined;
    @memcpy(in[0..prefix.len], &prefix);
    @memcpy(in[prefix.len..], public);
    var out: Name = undefined;
    Blake3.hash(&in, &out, .{});
    return out;
}

pub const Identity = struct {
    pair: Ed.KeyPair,
    public: [32]u8,
    name: Name,
};

/// The identity of a 32-byte seed. Null for the seeds Ed25519 refuses.
pub fn identity(seed: *const [32]u8) ?Identity {
    const pair = Ed.KeyPair.generateDeterministic(seed.*) catch return null;
    const public = pair.public_key.toBytes();
    return .{ .pair = pair, .public = public, .name = nameOf(&public) };
}

/// The names an end will finish a handshake with.
pub const Allow = struct {
    names: [max]Name = undefined,
    n: usize = 0,

    pub const max = 8;

    pub fn has(a: *const Allow, name: *const Name) bool {
        var i: usize = 0;
        while (i < a.n) : (i += 1) {
            if (std.mem.eql(u8, &a.names[i], name)) return true;
        }
        return false;
    }

    /// False when the list is full or holds the name already.
    pub fn add(a: *Allow, name: *const Name) bool {
        if (a.n == max or a.has(name)) return false;
        a.names[a.n] = name.*;
        a.n += 1;
        return true;
    }

    /// `name[,name...]` in the text form: one to eight names, none twice.
    pub fn parseList(s: []const u8) ?Allow {
        var a = Allow{};
        var i: usize = 0;
        while (true) {
            const start = i;
            while (i < s.len and s[i] != ',') i += 1;
            const name = parse(s[start..i]) orelse return null;
            if (!a.add(&name)) return null;
            if (i == s.len) return a;
            i += 1;
        }
    }
};

const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
pub const text_max = 44;

pub const Text = struct {
    buf: [text_max]u8 = undefined,
    len: usize = 0,
    pub fn slice(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }
};

/// Base58 of the 32 bytes. A leading zero byte is written as `1`.
pub fn text(name: *const Name) Text {
    var num = name.*;
    var digits: [text_max]u8 = undefined;
    var nd: usize = 0;
    var zeros: usize = 0;
    while (zeros < num.len and num[zeros] == 0) zeros += 1;
    var first = zeros;
    while (first < num.len) {
        // Divide the number by 58; the remainder is the next digit.
        var rem: u32 = 0;
        var i = first;
        while (i < num.len) : (i += 1) {
            const v = rem * 256 + num[i];
            num[i] = @intCast(v / 58);
            rem = v % 58;
        }
        digits[nd] = alphabet[rem];
        nd += 1;
        while (first < num.len and num[first] == 0) first += 1;
    }
    var out = Text{};
    while (out.len < zeros) : (out.len += 1) out.buf[out.len] = '1';
    while (nd > 0) {
        nd -= 1;
        out.buf[out.len] = digits[nd];
        out.len += 1;
    }
    return out;
}

/// The name a text stands for: only text that decodes to exactly 32 bytes
/// and that `text` would have written for them.
pub fn parse(s: []const u8) ?Name {
    if (s.len == 0 or s.len > text_max) return null;
    var num: [40]u8 = .{0} ** 40;
    for (s) |ch| {
        var carry: u32 = @intCast(std.mem.indexOfScalar(u8, alphabet, ch) orelse return null);
        var i: usize = num.len;
        while (i > 0) {
            i -= 1;
            const v = @as(u32, num[i]) * 58 + carry;
            num[i] = @truncate(v);
            carry = v >> 8;
        }
        if (carry != 0) return null;
    }
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (num[i] != 0) return null;
    }
    var name: Name = undefined;
    @memcpy(&name, num[8..40]);
    const back = text(&name);
    if (!std.mem.eql(u8, back.slice(), s)) return null;
    return name;
}

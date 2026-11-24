//! `entity name <key-file>`: the name of the entity whose key is the 32-byte
//! file, in its text form. Exit 2 for a wrong call or any other file.
//! A key is made with any tool: `head -c 32 /dev/urandom > key`.

const std = @import("std");
const entity = @import("entity.zig");

extern fn open(path: [*:0]const u8, flags: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, n: usize) isize;

pub fn main(init: std.process.Init.Minimal) u8 {
    const v = init.args.vector;
    if (v.len != 3 or !std.mem.eql(u8, std.mem.span(v[1]), "name")) return 2;
    const fd = open(v[2], 0);
    if (fd < 0) return 2;
    var seed: [33]u8 = undefined;
    var n: usize = 0;
    while (n < seed.len) {
        const r = read(fd, seed[n..].ptr, seed.len - n);
        if (r < 0) return 2;
        if (r == 0) break;
        n += @intCast(r);
    }
    if (n != 32) return 2;
    const id = entity.identity(seed[0..32]) orelse return 2;
    var line: [entity.text_max + 1]u8 = undefined;
    const t = entity.text(&id.name);
    @memcpy(line[0..t.len], t.slice());
    line[t.len] = '\n';
    if (write(1, &line, t.len + 1) != @as(isize, @intCast(t.len + 1))) return 2;
    return 0;
}

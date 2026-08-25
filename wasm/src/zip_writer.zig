const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    data: []const u8,
};

/// Packs `entries` into an uncompressed (STORE method) ZIP archive, matching
/// the exact byte layout `zip.zig`'s own reader validates (local file
/// header + data per entry, then a central directory, then the EOCD
/// record). No deflate: callers here bundle already-compressed formats
/// (PNG/JPEG/M4A), so storing raw bytes is both simplest and avoids wasting
/// CPU recompressing incompressible data.
pub fn writeStoredZip(alloc: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var total: usize = 22; // EOCD
    for (entries) |e| total += 30 + e.name.len + e.data.len + 46 + e.name.len;

    const out = try alloc.alloc(u8, total);
    var w: usize = 0;

    const Record = struct { name: []const u8, crc: u32, size: u32, offset: u32 };
    const records = try alloc.alloc(Record, entries.len);
    defer alloc.free(records);

    for (entries, 0..) |e, i| {
        const offset: u32 = @intCast(w);
        const crc = std.hash.Crc32.hash(e.data);
        const size: u32 = @intCast(e.data.len);

        std.mem.writeInt(u32, out[w..][0..4], 0x04034b50, .little);
        w += 4;
        std.mem.writeInt(u16, out[w..][0..2], 20, .little); // version needed
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // flags
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // method: stored
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // mod time
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // mod date
        w += 2;
        std.mem.writeInt(u32, out[w..][0..4], crc, .little);
        w += 4;
        std.mem.writeInt(u32, out[w..][0..4], size, .little); // compressed size
        w += 4;
        std.mem.writeInt(u32, out[w..][0..4], size, .little); // uncompressed size
        w += 4;
        std.mem.writeInt(u16, out[w..][0..2], @intCast(e.name.len), .little);
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // extra len
        w += 2;
        @memcpy(out[w .. w + e.name.len], e.name);
        w += e.name.len;
        @memcpy(out[w .. w + e.data.len], e.data);
        w += e.data.len;

        records[i] = .{ .name = e.name, .crc = crc, .size = size, .offset = offset };
    }

    const cd_offset: u32 = @intCast(w);
    for (records) |r| {
        std.mem.writeInt(u32, out[w..][0..4], 0x02014b50, .little);
        w += 4;
        std.mem.writeInt(u16, out[w..][0..2], 20, .little); // version made by
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 20, .little); // version needed
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // flags
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // method
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // mod time
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // mod date
        w += 2;
        std.mem.writeInt(u32, out[w..][0..4], r.crc, .little);
        w += 4;
        std.mem.writeInt(u32, out[w..][0..4], r.size, .little);
        w += 4;
        std.mem.writeInt(u32, out[w..][0..4], r.size, .little);
        w += 4;
        std.mem.writeInt(u16, out[w..][0..2], @intCast(r.name.len), .little);
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // extra len
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // comment len
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // disk number
        w += 2;
        std.mem.writeInt(u16, out[w..][0..2], 0, .little); // internal attrs
        w += 2;
        std.mem.writeInt(u32, out[w..][0..4], 0, .little); // external attrs
        w += 4;
        std.mem.writeInt(u32, out[w..][0..4], r.offset, .little);
        w += 4;
        @memcpy(out[w .. w + r.name.len], r.name);
        w += r.name.len;
    }
    const cd_size: u32 = @intCast(w - cd_offset);

    std.mem.writeInt(u32, out[w..][0..4], 0x06054b50, .little);
    w += 4;
    std.mem.writeInt(u16, out[w..][0..2], 0, .little); // disk num
    w += 2;
    std.mem.writeInt(u16, out[w..][0..2], 0, .little); // cd disk
    w += 2;
    std.mem.writeInt(u16, out[w..][0..2], @intCast(entries.len), .little); // entries this disk
    w += 2;
    std.mem.writeInt(u16, out[w..][0..2], @intCast(entries.len), .little); // total entries
    w += 2;
    std.mem.writeInt(u32, out[w..][0..4], cd_size, .little);
    w += 4;
    std.mem.writeInt(u32, out[w..][0..4], cd_offset, .little);
    w += 4;
    std.mem.writeInt(u16, out[w..][0..2], 0, .little); // comment len
    w += 2;

    return out[0..w];
}

test "writeStoredZip round-trips through zip.zig's own reader" {
    const zip = @import("zip.zig");
    const alloc = std.testing.allocator;

    const entries = [_]Entry{
        .{ .name = "a.txt", .data = "hello" },
        .{ .name = "dir/b.bin", .data = &[_]u8{ 0, 1, 2, 3, 255 } },
    };
    const zip_bytes = try writeStoredZip(alloc, &entries);
    defer alloc.free(zip_bytes);

    var entries_buf: [8]zip.Entry = undefined;
    const archive = try zip.open(alloc, zip_bytes, &entries_buf);
    defer for (archive.entries()) |e| alloc.free(e.name);

    try std.testing.expectEqual(@as(usize, 2), archive.count);

    const a = archive.find("a.txt") orelse return error.NotFound;
    const a_data = try archive.extract(alloc, a);
    defer alloc.free(a_data);
    try std.testing.expectEqualStrings("hello", a_data);

    const b = archive.find("dir/b.bin") orelse return error.NotFound;
    const b_data = try archive.extract(alloc, b);
    defer alloc.free(b_data);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 255 }, b_data);
}

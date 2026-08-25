const std = @import("std");
const record = @import("sqlite/record.zig");
const pager = @import("sqlite/pager.zig");
const btree = @import("sqlite/btree.zig");

// --- Color ---
pub inline fn argbFromSigned(v: i64) u32 {
    return @truncate(@as(u64, @bitCast(v)));
}

// --- SQLite column helpers (tiny, pure, reused across model/window) ---
/// Only serial types 1-7 (ints/real, <=8 bytes) decode to `.int`/`.real`; any
/// other type (NULL, TEXT, BLOB) is irrelevant to these numeric readers and,
/// crucially, can report an arbitrarily large `range.len` that must never
/// reach the fixed 8-byte stack buffer below.
fn readNumericColumn(db: pager.Db, row: btree.Row, hdr: record.RecordHeader, i: usize) record.Value {
    if (i >= hdr.column_count) return .null;
    const range = hdr.columnRange(i);
    if (range.len > 8) return .null;
    var buf: [8]u8 = undefined;
    row.readColumn(db, hdr, i, buf[0..range.len]);
    return record.decodeValue(hdr.serialType(i), buf[0..range.len]);
}

pub inline fn readColumnF32(db: pager.Db, row: btree.Row, hdr: record.RecordHeader, i: usize) f32 {
    return switch (readNumericColumn(db, row, hdr, i)) {
        .real => |r| @floatCast(r),
        .int => |n| @floatFromInt(n),
        else => 0,
    };
}

pub inline fn readColumnBool(db: pager.Db, row: btree.Row, hdr: record.RecordHeader, i: usize) bool {
    return switch (readNumericColumn(db, row, hdr, i)) {
        .int => |n| n != 0,
        else => false,
    };
}

pub inline fn readColumnI64(db: pager.Db, row: btree.Row, hdr: record.RecordHeader, i: usize) i64 {
    const v = readNumericColumn(db, row, hdr, i);
    return if (v == .int) v.int else 0;
}

// --- File/path helpers ---
pub inline fn extOf(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return "bin";
}

pub fn sanitizeInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    for (src[0..n], 0..) |c, i| {
        dst[i] = if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '_';
    }
    return n;
}

// --- Geometry helpers (Bounds-agnostic, operate on raw f32) ---
pub inline fn clampCell(f: f32, n: u32) u32 {
    if (n == 0 or f <= 0) return 0;
    const fi: u32 = @intFromFloat(@floor(f));
    return @min(fi, n - 1);
}

pub inline fn gridCellIndex(world: f32, min: f32, cell_size: f32, n: u32) u32 {
    const f = (world - min) / cell_size;
    if (f <= 0) return 0;
    const fi: u32 = @intFromFloat(@floor(f));
    return @min(fi, n - 1);
}

pub inline fn intersects(a: anytype, b: anytype) bool {
    const Vec4 = @Vector(4, f32);
    const va: Vec4 = .{ a.left, a.top, b.left, b.top };
    const vb: Vec4 = .{ b.right, b.bottom, a.right, a.bottom };
    return @reduce(.And, va <= vb);
}

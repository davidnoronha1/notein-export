const std = @import("std");
const varint = @import("varint.zig");

pub const Value = union(enum) {
    null,
    int: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

/// Byte length of a value with the given SQLite serial type.
pub fn serialTypeLen(serial_type: i64) usize {
    return switch (serial_type) {
        0, 8, 9, 10, 11 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6, 7 => 8,
        else => |n| @intCast(@divTrunc(n - if (@mod(n, 2) == 0) @as(i64, 12) else @as(i64, 13), 2)),
    };
}

fn bigIntFromBytes(bytes: []const u8) i64 {
    var v: i64 = if (bytes[0] & 0x80 != 0) -1 else 0; // sign-extend
    for (bytes) |b| v = (v << 8) | b;
    return v;
}

/// Decodes a value given its serial type and exactly `serialTypeLen(serial_type)` raw bytes.
pub fn decodeValue(serial_type: i64, bytes: []const u8) Value {
    return switch (serial_type) {
        0 => .null,
        1, 2, 3, 4, 5, 6 => .{ .int = bigIntFromBytes(bytes) },
        7 => blk: {
            const bits = std.mem.readInt(u64, bytes[0..8], .big);
            break :blk .{ .real = @bitCast(bits) };
        },
        8 => .{ .int = 0 },
        9 => .{ .int = 1 },
        else => |n| if (@mod(n, 2) == 0) .{ .blob = bytes } else .{ .text = bytes },
    };
}

pub const MAX_COLUMNS = 24;

pub const RecordHeader = struct {
    /// Total header length in bytes (including the leading varint that encodes it).
    header_len: usize,
    serial_types: [MAX_COLUMNS]i64,
    column_count: usize,

    /// Byte offset (relative to the start of the payload) and length of column `i`'s value.
    /// A row physically written before a later `ALTER TABLE ADD COLUMN` can have
    /// fewer stored columns than the table's current schema -- SQLite treats a
    /// trailing column past what a row stored as an implicit NULL/default, so
    /// `i >= column_count` is not a bug in the data; we report it as a
    /// zero-length (absent) value rather than reading uninitialized
    /// `serial_types` slots.
    pub fn columnRange(self: RecordHeader, i: usize) struct { offset: usize, len: usize } {
        var offset: usize = self.header_len;
        var idx: usize = 0;
        const limit = @min(i, self.column_count);
        while (idx < limit) : (idx += 1) offset += serialTypeLen(self.serial_types[idx]);
        if (i >= self.column_count) return .{ .offset = offset, .len = 0 };
        return .{ .offset = offset, .len = serialTypeLen(self.serial_types[i]) };
    }

    /// Serial type for column `i`, or NULL's serial type (0) if this row was
    /// written before column `i` existed (see `columnRange`) -- safe to pass
    /// straight to `decodeValue` alongside the zero-length bytes `columnRange`
    /// reports for the same case.
    pub fn serialType(self: RecordHeader, i: usize) i64 {
        return if (i >= self.column_count) 0 else self.serial_types[i];
    }
};

pub const Error = error{TooManyColumns};

/// Parses a record's header from the payload's leading bytes (always resident locally
/// on the b-tree page in practice for the tables this reader targets).
pub fn parseHeader(payload_head: []const u8) Error!RecordHeader {
    const hl = varint.decode(payload_head);
    const header_len: usize = @intCast(hl.value);

    var serial_types: [MAX_COLUMNS]i64 = undefined;
    var count: usize = 0;
    var pos: usize = hl.len;
    while (pos < header_len) {
        if (count >= MAX_COLUMNS) return Error.TooManyColumns;
        const st = varint.decode(payload_head[pos..]);
        serial_types[count] = st.value;
        count += 1;
        pos += st.len;
    }

    return .{ .header_len = header_len, .serial_types = serial_types, .column_count = count };
}

test "parseHeader and columnRange" {
    // Record: header_len_varint, 2 serial types (both 1-byte ints => type 1), then 2 body bytes.
    // header bytes: [header_len=3][type1=1][type2=1] -> header_len counts itself: 1+1+1=3
    const payload = [_]u8{ 3, 1, 1, 42, 7 };
    const hdr = try parseHeader(&payload);
    try std.testing.expectEqual(@as(usize, 3), hdr.header_len);
    try std.testing.expectEqual(@as(usize, 2), hdr.column_count);

    const r0 = hdr.columnRange(0);
    try std.testing.expectEqual(@as(usize, 3), r0.offset);
    try std.testing.expectEqual(@as(usize, 1), r0.len);
    const v0 = decodeValue(hdr.serial_types[0], payload[r0.offset .. r0.offset + r0.len]);
    try std.testing.expectEqual(@as(i64, 42), v0.int);

    const r1 = hdr.columnRange(1);
    try std.testing.expectEqual(@as(usize, 4), r1.offset);
    const v1 = decodeValue(hdr.serial_types[1], payload[r1.offset .. r1.offset + r1.len]);
    try std.testing.expectEqual(@as(i64, 7), v1.int);
}

test "decodeValue real" {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(@as(f64, 3.5)), .big);
    const v = decodeValue(7, &bytes);
    try std.testing.expectEqual(@as(f64, 3.5), v.real);
}

test "decodeValue negative int (two's complement sign extend)" {
    const v = decodeValue(1, &[_]u8{0xff});
    try std.testing.expectEqual(@as(i64, -1), v.int);
}

test "decodeValue text serial type" {
    const bytes = "hi";
    // type 13 => text len (13-13)/2 = 0... use type 17 => (17-13)/2 = 2
    const v = decodeValue(17, bytes);
    try std.testing.expectEqualStrings("hi", v.text);
}

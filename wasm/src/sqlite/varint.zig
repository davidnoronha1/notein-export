const std = @import("std");

/// Decodes a SQLite variable-length integer starting at `buf[0..]`.
/// Returns the decoded value and the number of bytes consumed (1-9).
pub fn decode(buf: []const u8) struct { value: i64, len: usize } {
    var result: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const byte = buf[i];
        result = (result << 7) | (byte & 0x7f);
        if (byte & 0x80 == 0) {
            return .{ .value = @bitCast(result), .len = i + 1 };
        }
    }
    // 9th byte contributes all 8 bits.
    result = (result << 8) | buf[8];
    return .{ .value = @bitCast(result), .len = 9 };
}

test "varint single byte" {
    const r = decode(&[_]u8{0x05});
    try std.testing.expectEqual(@as(i64, 5), r.value);
    try std.testing.expectEqual(@as(usize, 1), r.len);
}

test "varint two bytes" {
    // 0x81 0x00 -> (1 << 7) | 0 = 128
    const r = decode(&[_]u8{ 0x81, 0x00 });
    try std.testing.expectEqual(@as(i64, 128), r.value);
    try std.testing.expectEqual(@as(usize, 2), r.len);
}

test "varint max byte value" {
    // 0xff 0x7f -> (0x7f << 7) | 0x7f = 16383
    const r = decode(&[_]u8{ 0xff, 0x7f });
    try std.testing.expectEqual(@as(i64, 16383), r.value);
    try std.testing.expectEqual(@as(usize, 2), r.len);
}

test "varint nine bytes" {
    var buf: [9]u8 = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const r = decode(&buf);
    try std.testing.expectEqual(@as(usize, 9), r.len);
    try std.testing.expectEqual(@as(i64, -1), r.value);
}

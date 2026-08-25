const std = @import("std");

pub const Error = error{
    NotASqliteFile,
    UnsupportedPageSize,
    Truncated,
};

pub const Db = struct {
    bytes: []const u8,
    page_size: u32,
    usable_size: u32,

    pub fn init(bytes: []const u8) Error!Db {
        if (bytes.len < 100) return Error.Truncated;
        if (!std.mem.eql(u8, bytes[0..16], "SQLite format 3\x00")) return Error.NotASqliteFile;

        const raw_page_size = std.mem.readInt(u16, bytes[16..18], .big);
        // Page size 1 means 65536 (stored as u16 can't hold it).
        const page_size: u32 = if (raw_page_size == 1) 65536 else raw_page_size;
        if (page_size < 512 or (page_size & (page_size - 1)) != 0) return Error.UnsupportedPageSize;

        const reserved: u32 = bytes[20];
        const usable_size = page_size - reserved;

        return .{ .bytes = bytes, .page_size = page_size, .usable_size = usable_size };
    }

    /// Returns the raw bytes of 1-indexed page `page_num`.
    pub fn page(self: Db, page_num: u32) []const u8 {
        const start: usize = (@as(usize, page_num) - 1) * self.page_size;
        const end = start + self.page_size;
        return self.bytes[start..end];
    }

    /// Header is only present as a prefix on page 1; every page's *content*
    /// (btree page header + cells) starts after that prefix on page 1 only.
    pub fn pageContentOffset(page_num: u32) usize {
        return if (page_num == 1) 100 else 0;
    }
};

/// Maximum bytes of an overflowing payload stored inline on the b-tree page itself,
/// per the SQLite file format spec (table leaf cells).
pub fn localPayloadLen(usable_size: u32, payload_len: u64) u32 {
    const u: i64 = @intCast(usable_size);
    const max_local: i64 = u - 35;
    if (payload_len <= @as(u64, @intCast(max_local))) return @intCast(payload_len);

    const min_local: i64 = @divTrunc((u - 12) * 32, 255) - 23;
    const k: i64 = min_local + @as(i64, @intCast((payload_len - @as(u64, @intCast(min_local))) % @as(u64, @intCast(u - 4))));
    if (k <= max_local) return @intCast(k);
    return @intCast(min_local);
}

/// Reads `out.len` bytes starting at logical `offset` within a payload that begins
/// with `local` bytes on the b-tree page, continuing (if needed) into the overflow
/// page chain starting at `first_overflow_page` (0 = no overflow). Does not allocate;
/// walks the chain from the start (required, singly-linked) but only copies the
/// requested window, so callers can cheaply read a few trailing columns without
/// materializing multi-kilobyte payloads.
pub fn readPayloadRange(
    db: Db,
    local: []const u8,
    first_overflow_page: u32,
    offset: usize,
    out: []u8,
) void {
    var filled: usize = 0;

    if (offset < local.len) {
        const src_start = offset;
        const n = @min(out.len, local.len - src_start);
        @memcpy(out[0..n], local[src_start .. src_start + n]);
        filled = n;
        if (filled == out.len) return;
    }

    if (first_overflow_page == 0) return;

    const overflow_usable = db.usable_size - 4;
    var consumed: usize = local.len;
    var page_num = first_overflow_page;

    while (page_num != 0 and filled < out.len) {
        const page_bytes = db.page(page_num);
        const next = std.mem.readInt(u32, page_bytes[0..4], .big);
        const content = page_bytes[4..db.usable_size];

        const page_start = consumed;
        const page_end = consumed + content.len;
        const want_start = offset + filled;

        if (want_start < page_end and want_start + (out.len - filled) > page_start) {
            const local_off = if (want_start > page_start) want_start - page_start else 0;
            const n = @min(out.len - filled, content.len - local_off);
            @memcpy(out[filled .. filled + n], content[local_off .. local_off + n]);
            filled += n;
        }

        consumed = page_end;
        page_num = next;
        _ = overflow_usable;
    }
}

/// Assembles the full payload into a freshly allocated buffer.
pub fn readPayloadAll(
    alloc: std.mem.Allocator,
    db: Db,
    local: []const u8,
    first_overflow_page: u32,
    total_len: usize,
) ![]u8 {
    const out = try alloc.alloc(u8, total_len);
    readPayloadRange(db, local, first_overflow_page, 0, out);
    return out;
}

test "localPayloadLen fits inline for small payloads" {
    try std.testing.expectEqual(@as(u32, 50), localPayloadLen(4096, 50));
}

test "localPayloadLen caps large payloads" {
    const n = localPayloadLen(4096, 60000);
    try std.testing.expect(n < 60000);
    try std.testing.expect(n > 0);
}

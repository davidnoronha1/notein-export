const std = @import("std");
const pager = @import("pager.zig");
const varint = @import("varint.zig");
const record = @import("record.zig");

pub const PageType = enum(u8) {
    interior_index = 0x02,
    interior_table = 0x05,
    leaf_index = 0x0a,
    leaf_table = 0x0d,
    _,
};

/// A single table b-tree row: rowid plus enough info to fetch its record payload
/// (either directly, if fully local, or via the pager's overflow-aware readers).
pub const Row = struct {
    rowid: i64,
    /// Payload bytes resident on the leaf page itself (may be the full payload,
    /// or just its local prefix if it overflows).
    local: []const u8,
    total_len: usize,
    first_overflow_page: u32,

    pub fn header(self: Row) record.Error!record.RecordHeader {
        return record.parseHeader(self.local);
    }

    /// Reads column `i`'s raw bytes into `out` (which must be exactly the column's
    /// byte length, from `RecordHeader.columnRange`). Cheap: does not materialize
    /// unrelated columns (e.g. a large preceding TEXT column) even if this column
    /// happens to live in the overflow chain.
    pub fn readColumn(self: Row, db: pager.Db, hdr: record.RecordHeader, i: usize, out: []u8) void {
        const range = hdr.columnRange(i);
        pager.readPayloadRange(db, self.local, self.first_overflow_page, range.offset, out);
    }

    pub fn readColumnAlloc(self: Row, alloc: std.mem.Allocator, db: pager.Db, hdr: record.RecordHeader, i: usize) ![]u8 {
        const range = hdr.columnRange(i);
        const out = try alloc.alloc(u8, range.len);
        self.readColumn(db, hdr, i, out);
        return out;
    }

    /// Reads the entire record payload (all columns) into a fresh allocation.
    pub fn readAll(self: Row, alloc: std.mem.Allocator, db: pager.Db) ![]u8 {
        return pager.readPayloadAll(alloc, db, self.local, self.first_overflow_page, self.total_len);
    }
};

pub const Error = error{ InvalidPage, TooManyColumns } || pager.Error;

/// Calls `visit(ctx, row)` for every row in the table b-tree rooted at `root_page`,
/// in leaf traversal (rowid ascending) order. Walks via real recursion: b-tree
/// *depth* is tiny (a handful of levels even at millions of rows) even when a
/// page's *fanout* (cell count) is large, so this can't stack-overflow the way
/// an artificially depth-limited explicit stack sized for fanout could.
pub fn scanTable(
    db: pager.Db,
    root_page: u32,
    comptime Ctx: type,
    ctx: Ctx,
    comptime visit: fn (Ctx, Row) anyerror!void,
) !void {
    try walkPage(db, root_page, Ctx, ctx, visit);
}

fn walkPage(
    db: pager.Db,
    page_num: u32,
    comptime Ctx: type,
    ctx: Ctx,
    comptime visit: fn (Ctx, Row) anyerror!void,
) !void {
    const content_off = pager.Db.pageContentOffset(page_num);
    const page_bytes = db.page(page_num);
    const hdr = page_bytes[content_off..];

    const page_type: PageType = @enumFromInt(hdr[0]);
    const cell_count = std.mem.readInt(u16, hdr[3..5], .big);

    const header_size: usize = switch (page_type) {
        .interior_table, .interior_index => 12,
        .leaf_table, .leaf_index => 8,
        else => return Error.InvalidPage,
    };
    const cell_ptr_array = hdr[header_size..];

    switch (page_type) {
        .interior_table => {
            // Interior pages: cells give left-child-pointer + key, visited in
            // ascending order, followed by the header's rightmost pointer.
            var i: usize = 0;
            while (i < cell_count) : (i += 1) {
                const cell_off = std.mem.readInt(u16, cell_ptr_array[i * 2 ..][0..2], .big);
                const cell = page_bytes[cell_off..];
                const child = std.mem.readInt(u32, cell[0..4], .big);
                try walkPage(db, child, Ctx, ctx, visit);
            }
            const rightmost = std.mem.readInt(u32, hdr[8..12], .big);
            try walkPage(db, rightmost, Ctx, ctx, visit);
        },
        .leaf_table => {
            var i: usize = 0;
            while (i < cell_count) : (i += 1) {
                const cell_off = std.mem.readInt(u16, cell_ptr_array[i * 2 ..][0..2], .big);
                const cell = page_bytes[cell_off..];

                const payload_len_v = varint.decode(cell);
                var pos: usize = payload_len_v.len;
                const rowid_v = varint.decode(cell[pos..]);
                pos += rowid_v.len;

                const payload_len: u64 = @intCast(payload_len_v.value);
                const local_len = pager.localPayloadLen(db.usable_size, payload_len);
                const local = cell[pos .. pos + local_len];

                var overflow_page: u32 = 0;
                if (local_len < payload_len) {
                    const after_local = cell[pos + local_len ..];
                    overflow_page = std.mem.readInt(u32, after_local[0..4], .big);
                }

                try visit(ctx, .{
                    .rowid = rowid_v.value,
                    .local = local,
                    .total_len = @intCast(payload_len),
                    .first_overflow_page = overflow_page,
                });
            }
        },
        else => return Error.InvalidPage,
    }
}

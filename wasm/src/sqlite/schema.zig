const std = @import("std");
const pager = @import("pager.zig");
const btree = @import("btree.zig");
const record = @import("record.zig");

const FindCtx = struct {
    db: pager.Db,
    name: []const u8,
    found: ?u32 = null,
};

fn visitRow(ctx: *FindCtx, row: btree.Row) !void {
    if (ctx.found != null) return;
    const hdr = try row.header();
    // sqlite_master columns: type, name, tbl_name, rootpage, sql
    if (hdr.column_count < 5) return;

    const name_range = hdr.columnRange(1);
    var name_buf: [128]u8 = undefined;
    if (name_range.len > name_buf.len) return;
    row.readColumn(ctx.db, hdr, 1, name_buf[0..name_range.len]);

    if (!std.mem.eql(u8, name_buf[0..name_range.len], ctx.name)) return;

    const rp_range = hdr.columnRange(3);
    var rp_buf: [8]u8 = undefined;
    row.readColumn(ctx.db, hdr, 3, rp_buf[0..rp_range.len]);
    const v = record.decodeValue(hdr.serial_types[3], rp_buf[0..rp_range.len]);
    ctx.found = @intCast(v.int);
}

/// Scans sqlite_master (always rooted at page 1) for a table named `name`,
/// returning its root page number if found.
pub fn findTableRoot(db: pager.Db, name: []const u8) !?u32 {
    var ctx = FindCtx{ .db = db, .name = name };
    try btree.scanTable(db, 1, *FindCtx, &ctx, visitRow);
    return ctx.found;
}

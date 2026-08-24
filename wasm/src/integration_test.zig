const std = @import("std");
const zip = @import("zip.zig");
const pager = @import("sqlite/pager.zig");
const btree = @import("sqlite/btree.zig");
const schema = @import("sqlite/schema.zig");
const wal = @import("wal.zig");

const CountCtx = struct { n: usize = 0 };
fn countRow(ctx: *CountCtx, row: btree.Row) !void {
    _ = row;
    ctx.n += 1;
}

fn openDiary(alloc: std.mem.Allocator) !struct { file_bytes: []u8, archive: zip.Archive, db_bytes: []u8, db: pager.Db } {
    const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../fixtures/diary.in", alloc, .limited(300 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("skip: fixtures/diary.in not found -- integration test requires a local .in sample (ignored by git), skipping\n", .{});
            return error.SkipZigTest;
        }
        return err;
    };

    const entries_buf = try alloc.alloc(zip.Entry, 64);
    const archive = try zip.open(alloc, file_bytes, entries_buf);

    const db_entry = archive.findSuffix("_db") orelse return error.DbEntryNotFound;
    const raw_db_bytes = try archive.extract(alloc, db_entry);
    const raw_db = try pager.Db.init(raw_db_bytes);

    var db_bytes = raw_db_bytes;
    if (archive.findSuffix("_db-wal")) |wal_entry| {
        const wal_bytes = try archive.extract(alloc, wal_entry);
        db_bytes = try wal.apply(alloc, raw_db_bytes, raw_db.page_size, wal_bytes);
    }
    const db = try pager.Db.init(db_bytes);

    return .{ .file_bytes = file_bytes, .archive = archive, .db_bytes = db_bytes, .db = db };
}

test "diary.in: row counts match known sample values" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const opened = try openDiary(a);

    const expectations = [_]struct { table: []const u8, count: usize }{
        .{ .table = "PageEntity", .count = 134 },
        .{ .table = "StrokeEntity", .count = 56758 },
        .{ .table = "ImageEntity", .count = 29 },
        .{ .table = "ShapeEntity", .count = 344 },
        .{ .table = "TextBoxEntity", .count = 12 },
        .{ .table = "NoteContentEntity", .count = 2 },
    };

    for (expectations) |exp| {
        const root_page = (try schema.findTableRoot(opened.db, exp.table)) orelse return error.TableNotFound;
        var ctx = CountCtx{};
        try btree.scanTable(opened.db, root_page, *CountCtx, &ctx, countRow);
        std.testing.expectEqual(exp.count, ctx.n) catch |err| {
            std.debug.print("table {s}: expected {d}, got {d}\n", .{ exp.table, exp.count, ctx.n });
            return err;
        };
    }
}

test "diary.in: image entries resolve to zip assets by uuid" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const opened = try openDiary(a);
    const root_page = (try schema.findTableRoot(opened.db, "ImageEntity")) orelse return error.TableNotFound;

    const Ctx = struct {
        db: pager.Db,
        archive: zip.Archive,
        alloc: std.mem.Allocator,
        checked: usize = 0,
        resolved: usize = 0,
    };
    var ctx = Ctx{ .db = opened.db, .archive = opened.archive, .alloc = a };

    const visit = struct {
        fn f(c: *Ctx, row: btree.Row) !void {
            const hdr = try row.header();
            // ImageEntity columns: id, uri, layer, layer_id, bounds, rotation, page_id, ...
            // `id` does NOT reliably match the zip asset's uuid (confirmed by this
            // test originally failing 13/29 against `id`) -- the zip entry name is
            // derived from `uri`'s basename instead, which the app itself uses to
            // name the file on export.
            const uri = try row.readColumnAlloc(c.alloc, c.db, hdr, 1);
            const basename = if (std.mem.lastIndexOfScalar(u8, uri, '/')) |i| uri[i + 1 ..] else uri;
            var name_buf: [96]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "note_image_{s}", .{basename});
            c.checked += 1;
            if (c.archive.find(name) != null) {
                c.resolved += 1;
            } else {
                std.debug.print("unresolved: '{s}'\n", .{name});
            }
        }
    }.f;

    try btree.scanTable(opened.db, root_page, *Ctx, &ctx, visit);

    try std.testing.expectEqual(@as(usize, 29), ctx.checked);
    try std.testing.expectEqual(ctx.checked, ctx.resolved);
}

test "diary.in: WAL replay is required and sufficient for exact upstream counts" {
    // Confirms the WAL merge in openDiary() is actually taking effect: without
    // it StrokeEntity reads 56752/max-rowid-66716 (verified against the
    // pristine, un-checkpointed zip entry via Python's zipfile + a fresh
    // `sqlite3 PRAGMA integrity_check` during development); with it, the
    // counts below match `sqlite3` reading the fully WAL-merged database.
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const opened = try openDiary(a);

    const root_page = (try schema.findTableRoot(opened.db, "StrokeEntity")) orelse return error.TableNotFound;
    const Ctx = struct { max_rowid: i64 = 0, n: usize = 0 };
    const visit = struct {
        fn f(ctx: *Ctx, row: btree.Row) !void {
            ctx.n += 1;
            if (row.rowid > ctx.max_rowid) ctx.max_rowid = row.rowid;
        }
    }.f;
    var ctx = Ctx{};
    try btree.scanTable(opened.db, root_page, *Ctx, &ctx, visit);

    try std.testing.expectEqual(@as(usize, 56758), ctx.n);
    try std.testing.expectEqual(@as(i64, 66722), ctx.max_rowid);
}

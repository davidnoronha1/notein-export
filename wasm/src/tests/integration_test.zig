const std = @import("std");
const model = @import("../model.zig");
const pager = @import("../sqlite/pager.zig");
const btree = @import("../sqlite/btree.zig");
const schema = @import("../sqlite/schema.zig");
const wal = @import("../sqlite/wal.zig");

const CountCtx = struct { n: usize = 0 };
fn countRow(ctx: *CountCtx, row: btree.Row) !void {
    _ = row;
    ctx.n += 1;
}

fn openDiary(alloc: std.mem.Allocator, scratch: std.mem.Allocator) !struct { file_bytes: []u8, archive: model.ZipArchive, db_bytes: []u8, db: pager.Db } {
    const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../fixtures/diary.in", alloc, .limited(300 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return error.Skip;
        return err;
    };

    const entries_buf = try alloc.alloc(model.ZipEntry, 512);
    const archive = try model.openZip(alloc, file_bytes, entries_buf);

    const db_entry = archive.findSuffix("_db") orelse return error.DbNotFound;
    var db_bytes: []u8 = undefined;
    if (archive.findSuffix("_db-wal")) |wal_entry| {
        const wal_bytes = try archive.extract(scratch, wal_entry);
        defer scratch.free(wal_bytes);
        const raw_db_bytes = try archive.extract(scratch, db_entry);
        const raw_db = try pager.Db.init(raw_db_bytes);
        db_bytes = try wal.apply(scratch, raw_db_bytes, raw_db.page_size, wal_bytes);
    } else {
        db_bytes = try archive.extract(scratch, db_entry);
    }
    const db = try pager.Db.init(db_bytes);

    return .{ .file_bytes = file_bytes, .archive = archive, .db_bytes = db_bytes, .db = db };
}

test "open diary export, apply wal, and query schema" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const res = openDiary(arena.allocator(), alloc) catch |err| {
        if (err == error.Skip) return;
        return err;
    };
    defer alloc.free(res.db_bytes);

    const note_root = (try schema.findTableRoot(res.db, "NoteContentEntity")) orelse return error.TableNotFound;
    var count = CountCtx{};
    try btree.scanTable(res.db, note_root, *CountCtx, &count, countRow);
    try std.testing.expect(count.n >= 1);
}

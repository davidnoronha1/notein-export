const std = @import("std");
const model = @import("../model.zig");

test "model.open: diary.in loads with expected shape" {
    const alloc = std.testing.allocator;

    const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../fixtures/diary.in", alloc, .limited(300 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const note = try model.open(arena.allocator(), alloc, file_bytes);
    defer alloc.free(@constCast(note.db.bytes));
    defer alloc.free(file_bytes);

    try std.testing.expect(note.pages.len > 0);
    for (note.pages) |p| {
        try std.testing.expect(p.id.len > 0);
        try std.testing.expect(!p.unbounded);
        try std.testing.expect(p.width > 0);
        try std.testing.expect(p.height > 0);
    }
}

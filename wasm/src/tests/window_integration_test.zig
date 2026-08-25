const std = @import("std");
const model = @import("../model.zig");
const window = @import("../window.zig");

test "window: decodes only active pages and evicts on scroll" {
    const alloc = std.testing.allocator;

    const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../fixtures/diary.in", alloc, .limited(300 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var note = try model.open(arena.allocator(), alloc, file_bytes);
    defer alloc.free(@constCast(note.db.bytes));
    defer alloc.free(file_bytes);

    var win = window.Window.init(arena.allocator(), &note);

    try win.setActive(&.{0});
    try std.testing.expect(win.get(0) != null);
    try std.testing.expect(win.get(1) == null);

    try win.setActive(&.{1});
    try std.testing.expect(win.get(0) == null);
    try std.testing.expect(win.get(1) != null);
}

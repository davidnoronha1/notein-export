const std = @import("std");
const model = @import("model.zig");
const window = @import("window.zig");

test "window: decodes only active pages and evicts on scroll" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../fixtures/diary.in", a, .limited(300 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("skip: fixtures/diary.in not found -- skipping\n", .{});
            return error.SkipZigTest;
        }
        return err;
    };
    const note = try model.open(a, std.testing.allocator, file_bytes);
    defer std.testing.allocator.free(@constCast(note.db.bytes));

    // Use a real (non-arena) allocator for the window itself so eviction
    // actually frees memory, matching how main.zig will use it in wasm.
    var w = window.Window.init(alloc, &note);
    defer w.deinit();

    try std.testing.expectEqual(@as(usize, 0), w.activePageCount());
    try std.testing.expect(w.get(0) == null);

    // Find a page known to have a decent number of strokes for a real check.
    var richest_page: u32 = 0;
    var richest_count: usize = 0;
    var counts = try alloc.alloc(usize, note.pages.len);
    defer alloc.free(counts);
    @memset(counts, 0);
    for (note.strokes) |s| counts[s.page_index] += 1;
    for (counts, 0..) |c, i| {
        if (c > richest_count) {
            richest_count = c;
            richest_page = @intCast(i);
        }
    }
    try std.testing.expect(richest_count > 0);

    try w.setActive(&[_]u32{richest_page});
    try std.testing.expectEqual(@as(usize, 1), w.activePageCount());

    const content = w.get(richest_page) orelse return error.NotDecoded;
    try std.testing.expectEqual(richest_count, content.strokes.len);
    // At least some strokes should have actual point data.
    var any_points: bool = false;
    for (content.strokes) |s| {
        if (s.points.len > 0) any_points = true;
    }
    try std.testing.expect(any_points);

    // Scroll away: page should be evicted, a different page decoded.
    const other_page: u32 = if (richest_page == 0) 1 else 0;
    try w.setActive(&[_]u32{other_page});
    try std.testing.expectEqual(@as(usize, 1), w.activePageCount());
    try std.testing.expect(w.get(richest_page) == null);
    try std.testing.expect(w.get(other_page) != null);
}

test "window: every page in the note decodes without error via the full Window cycle" {
    // Regression test for a dangling-pointer bug in main.zig's open(): it built
    // a Window pointing at a local State's `note` field, then copied that
    // State into global storage, leaving Window.note pointing at the (now
    // dead) stack frame. Only manifested in the wasm build since native tests
    // never went through that copy -- walking every real page through the
    // same decode/evict path here is what would have caught it natively.
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../fixtures/diary.in", a, .limited(300 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("skip: fixtures/diary.in not found -- skipping\n", .{});
            return error.SkipZigTest;
        }
        return err;
    };
    const note = try model.open(a, std.testing.allocator, file_bytes);
    defer std.testing.allocator.free(@constCast(note.db.bytes));

    var w = window.Window.init(alloc, &note);
    defer w.deinit();

    var decoded_stroke_total: usize = 0;
    for (0..note.pages.len) |i| {
        try w.setActive(&[_]u32{@intCast(i)});
        const content = w.get(@intCast(i)) orelse return error.NotDecoded;
        decoded_stroke_total += content.strokes.len;
    }
    try std.testing.expectEqual(note.strokes.len, decoded_stroke_total);
}

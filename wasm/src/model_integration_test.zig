const std = @import("std");
const model = @import("model.zig");

test "model.open: diary.in loads with expected shape" {
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

    // The note's own page_list references 129 pages; PageEntity's raw table
    // count (134, see integration_test.zig) includes 5 extra orphaned/historical
    // rows not in this note's page_list.
    try std.testing.expectEqual(@as(usize, 129), note.pages.len);
    try std.testing.expectEqual(@as(usize, 56758), note.strokes.len);
    try std.testing.expectEqual(@as(usize, 344), note.shapes.len);
    try std.testing.expectEqual(@as(usize, 12), note.text_boxes.len);
    try std.testing.expectEqual(@as(usize, 29), note.images.len);
    try std.testing.expectEqual(@as(usize, 0), note.links.len);
    try std.testing.expectEqual(@as(usize, 1), note.audio.len);

    // All pages should be A4-sized, bounded (per the sample's findings).
    for (note.pages) |p| {
        try std.testing.expect(!p.unbounded);
        try std.testing.expect(p.width > 1200 and p.width < 1300);
        try std.testing.expect(p.height > 1700 and p.height < 1800);
    }

    // Every stroke/shape/text-box/image should have resolved to a real page index.
    for (note.strokes) |s| try std.testing.expect(s.page_index < note.pages.len);
    for (note.shapes) |s| try std.testing.expect(s.page_index < note.pages.len);
    for (note.text_boxes) |t| try std.testing.expect(t.page_index < note.pages.len);
    for (note.images) |img| try std.testing.expect(img.page_index < note.pages.len);
    for (note.links) |l| try std.testing.expect(l.page_index < note.pages.len);
    if (note.audio.len > 0) {
        try std.testing.expect(note.audio[0].duration_ms > 0);
        try std.testing.expect(note.audio[0].zip_entry_name.len > 0);
    }

    // Spot check: bounds should be non-degenerate for at least most strokes.
    var nonzero_bounds: usize = 0;
    for (note.strokes) |s| {
        if (s.bounds.right > s.bounds.left or s.bounds.bottom > s.bounds.top) nonzero_bounds += 1;
    }
    try std.testing.expect(nonzero_bounds > note.strokes.len / 2);
}

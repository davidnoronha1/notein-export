// Fixture-backed Nebo decode test. Needs a real `.nebo` export at
// ../fixtures/memy.nebo (git-ignored, never committed -- see .gitignore);
// skips gracefully when absent, like the other integration tests.
//
// Asserts the validation invariants documented in NEBO_FORMAT.md §21 for the
// supplied sample, so a parser that loses sync (mis-sized payload, wrong
// header, semantic stream read as ink) is caught immediately.

const std = @import("std");
const model = @import("../model.zig");
const nebo = @import("../nebo.zig");
const window = @import("../window.zig");
const raster = @import("../raster.zig");

test "decode memy.nebo ink.bink raw strokes" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../fixtures/memy.nebo", a, .limited(64 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return; // skip
        return err;
    };

    const entries_buf = try a.alloc(model.ZipEntry, 512);
    const archive = try model.openZip(a, file_bytes, entries_buf);
    try std.testing.expect(nebo.isNebo(archive));

    const ink = archive.findSuffix("/ink.bink") orelse return error.NoInk;
    const bytes = try archive.extract(a, ink);
    const strokes = (try nebo.decodeBink(a, bytes)).strokes;

    // §21 invariants for the supplied file.
    try std.testing.expectEqual(@as(usize, 767), strokes.len);

    var samples: usize = 0;
    var last_ts: i64 = std.math.minInt(i64);
    var min_x: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    for (strokes) |s| {
        samples += s.points.len;
        try std.testing.expect(s.creation_time >= last_ts); // strictly increasing (ms resolution)
        last_ts = s.creation_time;
        min_x = @min(min_x, s.bounds.left);
        max_x = @max(max_x, s.bounds.right);
    }
    try std.testing.expectEqual(@as(usize, 58430), samples);
    // Reconstructed page X bounds (§4): 38.72 .. 883.04.
    try std.testing.expectApproxEqAbs(@as(f32, 38.724796), min_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 883.043274), max_x, 0.01);
}

test "open memy.nebo as a Note" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../fixtures/memy.nebo", a, .limited(64 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return; // skip
        return err;
    };

    const note = try model.open(a, alloc, file_bytes);
    try std.testing.expectEqual(@as(usize, 1), note.pages.len);
    try std.testing.expect(note.pages[0].unbounded);
    try std.testing.expect(note.pages[0].content_bounds != null);
    try std.testing.expect(note.nebo_pages != null);
    try std.testing.expectEqual(@as(usize, 767), note.nebo_pages.?[0].len);
    // Nebo notes carry no SQLite-backed assets.
    try std.testing.expectEqual(@as(usize, 0), note.strokes.len);
    try std.testing.expectEqual(@as(usize, 0), note.images.len);

    // Per-stroke pen colors resolved from the semantic stream: the sample uses
    // 4 pens (#000000 + 3 accents), stored as authored (dark-mode lightening
    // happens later in raster.outputColor, not here).
    var has_black = false;
    var has_blue = false;
    var has_maroon = false;
    var has_orange = false;
    for (note.nebo_pages.?[0]) |s| switch (s.color) {
        0xFF000000 => has_black = true,
        0xFF1364B7 => has_blue = true,
        0xFF87202B => has_maroon = true,
        0xFFA22E00 => has_orange = true,
        else => {},
    };
    try std.testing.expect(has_black and has_blue and has_maroon and has_orange);
}

test "open multi-page e.nebo (BINK header, varying raw-stream offset)" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../fixtures/e.nebo", a, .limited(64 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return; // skip
        return err;
    };

    const note = try model.open(a, alloc, file_bytes);
    // e.nebo is a 5-page controlled color corpus; each page has exactly one
    // stroke. The raw region starts at a per-file offset (177..205 here), so
    // this only decodes if the marker is found dynamically, not at a fixed 193.
    try std.testing.expectEqual(@as(usize, 5), note.pages.len);
    try std.testing.expect(note.nebo_pages != null);
    var distinct = std.AutoHashMap(u32, void).init(a);
    for (note.nebo_pages.?, note.pages) |page, page_info| {
        try std.testing.expectEqual(@as(usize, 1), page.len);
        try std.testing.expect(page[0].points.len > 100); // ~176..186 points/stroke
        try std.testing.expect(page_info.unbounded);
        try distinct.put(page[0].color, {});
    }
    // Five different pens across the five pages (one is black, four chromatic).
    try std.testing.expect(distinct.count() >= 4);
}

test "memy.nebo ink rasterizes to visible pixels" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const file_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../fixtures/memy.nebo", a, .limited(64 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return; // skip
        return err;
    };

    var note = try model.open(a, alloc, file_bytes);
    // Window gets its own real allocator (not the note arena), mirroring
    // main.zig where the note is arena-owned but the window uses the gpa.
    var win = window.Window.init(alloc, &note);
    defer win.deinit();
    try win.setActive(&.{0});
    const content = win.get(0) orelse return error.NoContent;
    try std.testing.expect(content.strokes.len == 767);

    // Rasterize the whole content bounds into a small buffer and confirm the
    // decoder produced ink that actually lands on pixels (not all transparent).
    const cb = note.pages[0].content_bounds.?;
    const w = cb.right - cb.left;
    const h = cb.bottom - cb.top;
    const px: u32 = 512;
    const py: u32 = @intFromFloat(@as(f32, @floatFromInt(px)) * h / w);
    // 16-byte aligned so raster's SIMD clear/fill stores don't fault on native
    // (the wasm target tolerates unaligned vector stores; a native test doesn't).
    const pixels = try a.alignedAlloc(u8, .@"16", @as(usize, px) * @as(usize, py) * 4);
    const canvas = raster.Canvas{
        .pixels = pixels,
        .width = px,
        .height = py,
        .origin_x = cb.left,
        .origin_y = cb.top,
        .scale = @as(f32, @floatFromInt(px)) / w,
    };
    canvas.clear(0x00000000);
    raster.renderPageContent(canvas, content, 0);

    var non_transparent: usize = 0;
    var saw_blue = false;
    var saw_reddish = false;
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        const r = pixels[i];
        const g = pixels[i + 1];
        const b = pixels[i + 2];
        if (pixels[i + 3] == 0) continue;
        non_transparent += 1;
        // Blue pen (#1364B7): dominant blue channel.
        if (b > 120 and b > r + 40 and b > g + 30) saw_blue = true;
        // Maroon/orange pens (#87202B / #A22E00): dominant red channel.
        if (r > 100 and r > g + 50 and r > b + 40) saw_reddish = true;
    }
    // A page full of handwriting should cover a meaningful fraction of pixels...
    try std.testing.expect(non_transparent > 1000);
    // ...and the resolved pen colors must actually reach the rasterized output,
    // not just the model (proves the whole color path end-to-end).
    try std.testing.expect(saw_blue);
    try std.testing.expect(saw_reddish);
}

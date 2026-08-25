const std = @import("std");

pub const Error = std.json.ParseError(std.json.Scanner);

/// Typed/structured parse: `T` is any struct/slice/array that `std.json`
/// knows how to deserialize. Unknown JSON fields are ignored so callers
/// only declare the fields they care about; missing fields that have a
/// default value in `T` are filled in automatically (see structs below).
///
/// `parseFromSliceLeaky` is used instead of `parseFromSlice` (see
/// `std/json/static.zig:86`):
/// - Leaky allocates directly into `alloc` with no per-call tracking.
/// - All call sites already use an ArenaAllocator (scratch arenas in
///   window.zig, the persistent note arena in model.zig), so the whole
///   parse result is freed in one go when that arena resets.
/// - The non-leaky `parseFromSlice` would create its own internal arena,
///   return `Parsed(T){ .arena, .value }` requiring separate `.deinit()`,
///   duplicating arena bookkeeping for no benefit.
pub fn parseTyped(comptime T: type, alloc: std.mem.Allocator, src: []const u8) Error!T {
    return std.json.parseFromSliceLeaky(T, alloc, src, .{ .ignore_unknown_fields = true });
}

// ---------------------------------------------------------------------------
// Typed JSON shapes used by the Notein format (all have defaults where the
// format makes the field optional, so callers get sane fallbacks when the
// key is absent).
// ---------------------------------------------------------------------------

/// Single stylus sample inside a stroke's `points` array.
pub const PointJson = struct {
    x: f32,
    y: f32,
    p: f32 = 0.5,
    // `action` (0 start / 2 move / 1 end) is present in exports but not
    // needed for rasterization; default lets older/newer exports omit it.
    action: i64 = 0,
};

/// `StrokeEntity.record_json` — only the fields the viewer actually uses;
/// everything else (bounds, layerId, extras, …) is ignored via
/// `ignore_unknown_fields`.
pub const StrokeJson = struct {
    color: i64 = 0xFF000000,
    width: f32 = 1,
    creationTime: i64 = 0,
    points: []PointJson = &.{},
};

/// Element of `ShapeEntity.points` (JSON array of {x,y}).
pub const ShapePointJson = struct {
    x: f32,
    y: f32,
};

/// `PageEntity.paper_spec` — `{ preciseWidth, preciseHeight }`.
pub const PaperSpecJson = struct {
    preciseWidth: f32 = 0,
    preciseHeight: f32 = 0,
};

pub const BaseThemeJson = struct {
    color: i64 = 0xFFFFFFFF,
};

/// `PageEntity.paper_theme` — only `baseTheme.color` is needed; the rest of
/// the polymorphic union (pattern/image themes, …) is ignored. Missing
/// `baseTheme` means "no flat color" → caller falls back to white.
pub const PaperThemeJson = struct {
    baseTheme: ?BaseThemeJson = null,
};

test "typed: StrokeJson defaults fill missing fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // only points supplied — color/width/creationTime should use defaults
    const s = try parseTyped(StrokeJson, arena.allocator(),
        \\{"points":[{"x":1,"y":2},{"x":3,"y":4,"p":0.9}]}
    );
    try std.testing.expectEqual(@as(i64, 0xFF000000), s.color);
    try std.testing.expectEqual(@as(f32, 1), s.width);
    try std.testing.expectEqual(@as(i64, 0), s.creationTime);
    try std.testing.expectEqual(@as(usize, 2), s.points.len);
    try std.testing.expectEqual(@as(f32, 0.5), s.points[0].p); // default pressure
    try std.testing.expectEqual(@as(f32, 0.9), s.points[1].p);
}

test "typed: StrokeJson ignores unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try parseTyped(StrokeJson, arena.allocator(),
        \\{"color":-16777216,"width":4.2,"creationTime":123,"bounds":{"left":0,"top":0,"right":100,"bottom":50},"layerId":"abc","points":[]}
    );
    try std.testing.expectEqual(@as(i64, -16777216), s.color);
    try std.testing.expectEqual(@as(f32, 4.2), s.width);
    try std.testing.expectEqual(@as(i64, 123), s.creationTime);
}

test "typed: StrokeJson nested array numbers and action default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try parseTyped(StrokeJson, arena.allocator(),
        \\{"color":-1,"width":5.5,"points":[{"x":1,"y":-2.5,"p":0.1,"action":0}]}
    );
    try std.testing.expectEqual(@as(i64, -1), s.color);
    try std.testing.expectEqual(@as(f32, 5.5), s.width);
    try std.testing.expectEqual(@as(usize, 1), s.points.len);
    try std.testing.expectEqual(@as(f32, 1), s.points[0].x);
    try std.testing.expectEqual(@as(f32, -2.5), s.points[0].y);
    try std.testing.expectEqual(@as(f32, 0.1), s.points[0].p);
}

test "typed: PaperSpecJson defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const empty = try parseTyped(PaperSpecJson, arena.allocator(), "{}");
    try std.testing.expectEqual(@as(f32, 0), empty.preciseWidth);
    try std.testing.expectEqual(@as(f32, 0), empty.preciseHeight);
    const full = try parseTyped(PaperSpecJson, arena.allocator(), "{\"preciseWidth\":1920,\"preciseHeight\":1080}");
    try std.testing.expectEqual(@as(f32, 1920), full.preciseWidth);
    try std.testing.expectEqual(@as(f32, 1080), full.preciseHeight);
}

test "typed: PaperThemeJson nested default and missing baseTheme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const no_base = try parseTyped(PaperThemeJson, arena.allocator(), "{}");
    try std.testing.expect(no_base.baseTheme == null);
    const with_color = try parseTyped(PaperThemeJson, arena.allocator(), "{\"baseTheme\":{\"color\":-1}}");
    try std.testing.expectEqual(@as(i64, -1), with_color.baseTheme.?.color);
}

test "typed: shape points array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pts = try parseTyped([]ShapePointJson, arena.allocator(), "[{\"x\":-0.2,\"y\":771.3},{\"x\":509.8,\"y\":771.3}]");
    try std.testing.expectEqual(@as(usize, 2), pts.len);
    try std.testing.expectEqual(@as(f32, -0.2), pts[0].x);
}

test "typed: empty array and bounds style via struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pts = try parseTyped([]ShapePointJson, arena.allocator(), "[]");
    try std.testing.expectEqual(@as(usize, 0), pts.len);
    const BoundsJson = struct { left: f32 = 0, top: f32 = 0, right: f32 = 0, bottom: f32 = 0 };
    const b = try parseTyped(BoundsJson, arena.allocator(), "{\"bottom\":345.9175,\"left\":54.151577,\"right\":1181.6858,\"top\":233.9638}");
    try std.testing.expectEqual(@as(f32, 345.9175), b.bottom);
}

test "typed: decode unicode and control escapes via struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const T = struct { t: []const u8 };
    const v = try parseTyped(T, arena.allocator(), "{\"t\":\"a\\u4e2d\\nb\\t\\\"c\\\"\"}");
    try std.testing.expectEqualStrings("a中\nb\t\"c\"", v.t);
}

test "typed: page_list array of strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ids = try parseTyped([][]const u8, arena.allocator(), "[\"abc\",\"def\"]");
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("abc", ids[0]);
    try std.testing.expectEqualStrings("def", ids[1]);
}

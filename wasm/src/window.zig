const std = @import("std");
const model = @import("model.zig");
const json = @import("json.zig");
const record = @import("sqlite/record.zig");

pub const Point = struct { x: f32, y: f32, p: f32 };

pub const DecodedStroke = struct {
    bounds: model.Bounds,
    color: u32, // ARGB
    width: f32,
    points: []const Point,
    creation_time: i64,
};

pub const DecodedShape = struct {
    bounds: model.Bounds,
    color: u32,
    width: f32,
    shape_type: i64,
    points: []const [2]f32,
    creation_time: i64,
};

pub const DecodedTextBox = struct {
    bounds: model.Bounds,
    text: []const u8,
    text_size: f32,
    color: u32,
    creation_time: i64,
};

/// Tags one entry of `PageContent.order`, so ink can be rasterized in true
/// chronological (== stacking) order instead of always drawing every stroke
/// before every shape regardless of which was actually drawn on top.
pub const DrawKind = enum(u8) { stroke, shape };
pub const DrawRef = struct { kind: DrawKind, index: u32 };

pub const PageContent = struct {
    strokes: []const DecodedStroke,
    shapes: []const DecodedShape,
    text_boxes: []const DecodedTextBox,
    /// strokes+shapes interleaved by creation_time ascending (draw in this
    /// order -- earlier entries render first / end up underneath).
    order: []const DrawRef,
};

fn argbFromSigned(v: i64) u32 {
    return @truncate(@as(u64, @bitCast(v)));
}

fn decodeStroke(alloc: std.mem.Allocator, note: *const model.Note, entry: model.StrokeEntry) !DecodedStroke {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit(); // JSON parse tree is scratch; only the extracted fields below outlive it.
    const scratch = arena.allocator();

    const hdr = try entry.row.header();
    const raw = try entry.row.readColumnAlloc(scratch, note.db, hdr, 4); // record_json
    const v = json.parse(scratch, raw) catch return .{ .bounds = entry.bounds, .color = 0xFF000000, .width = 1, .points = &.{}, .creation_time = 0 };

    const color = argbFromSigned(if (v.get("color")) |c| c.asI64() else 0xFF000000);
    const width = if (v.get("width")) |w| w.asF32() else 1;
    const creation_time = if (v.get("creationTime")) |c| c.asI64() else 0;
    const pts_val = v.get("points") orelse return .{ .bounds = entry.bounds, .color = color, .width = width, .points = &.{}, .creation_time = creation_time };

    var raw_points = try scratch.alloc(Point, pts_val.array.len);
    for (pts_val.array, 0..) |pv, i| {
        raw_points[i] = .{ .x = pv.get("x").?.asF32(), .y = pv.get("y").?.asF32(), .p = if (pv.get("p")) |p| p.asF32() else 0.5 };
    }
    const points = try smoothPoints(alloc, raw_points);

    return .{ .bounds = entry.bounds, .color = color, .width = width, .points = points, .creation_time = creation_time };
}

/// Catmull-Rom-interpolates a raw stylus sample path into a denser point set
/// so `tessellateStroke`'s ribbon polygon follows a smooth curve instead of
/// straight segments between sparse raw samples (visible as faceted/angular
/// bumps on curves like "m"/"e" once zoomed in). Subdivision count per
/// segment adapts to its length, capped to bound point-count blowup on
/// already-dense or very long strokes.
fn smoothPoints(alloc: std.mem.Allocator, raw: []const Point) ![]Point {
    if (raw.len < 3) return alloc.dupe(Point, raw);

    const MAX_SUBDIV = 8;
    const UNITS_PER_STEP = 3.0;
    const MAX_TOTAL_POINTS = 4000;

    var out = std.array_list.Managed(Point).init(alloc);
    errdefer out.deinit();
    try out.append(raw[0]);

    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 1) {
        const p0 = raw[if (i == 0) 0 else i - 1];
        const p1 = raw[i];
        const p2 = raw[i + 1];
        const p3 = raw[if (i + 2 < raw.len) i + 2 else raw.len - 1];

        const seg_len = @sqrt((p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y));
        const remaining_budget = if (MAX_TOTAL_POINTS > out.items.len) MAX_TOTAL_POINTS - out.items.len else 0;
        const steps: usize = @min(@min(MAX_SUBDIV, remaining_budget), @max(1, @as(usize, @intFromFloat(seg_len / UNITS_PER_STEP))));

        var s: usize = 1;
        while (s <= steps) : (s += 1) {
            const t = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            try out.append(catmullRom(p0, p1, p2, p3, t));
        }
        if (out.items.len >= MAX_TOTAL_POINTS) break;
    }
    return out.toOwnedSlice();
}

fn catmullRom(p0: Point, p1: Point, p2: Point, p3: Point, t: f32) Point {
    const t2 = t * t;
    const t3 = t2 * t;
    return .{
        .x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
        .y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3),
        .p = 0.5 * ((2 * p1.p) + (-p0.p + p2.p) * t + (2 * p0.p - 5 * p1.p + 4 * p2.p - p3.p) * t2 + (-p0.p + 3 * p1.p - 3 * p2.p + p3.p) * t3),
    };
}

fn decodeShape(alloc: std.mem.Allocator, note: *const model.Note, entry: model.ShapeEntry) !DecodedShape {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    const hdr = try entry.row.header();
    // ShapeEntity: id, page_id, color, width, points, type, blend_mode, layer_id, ...
    const color_bytes = try entry.row.readColumnAlloc(scratch, note.db, hdr, 2);
    const color_v = record.decodeValue(hdr.serialType(2), color_bytes);
    const color = argbFromSigned(if (color_v == .int) color_v.int else 0xFF000000);
    const width = readF32Col(note.db, entry.row, hdr, 3);
    const points_json = try entry.row.readColumnAlloc(scratch, note.db, hdr, 4);
    const shape_type = readI64Col(note.db, entry.row, hdr, 5);
    const creation_time = readI64Col(note.db, entry.row, hdr, 11);

    var points: [][2]f32 = &.{};
    if (json.parse(scratch, points_json)) |v| {
        points = try alloc.alloc([2]f32, v.array.len);
        for (v.array, 0..) |pv, i| points[i] = .{ pv.get("x").?.asF32(), pv.get("y").?.asF32() };
    } else |_| {}

    return .{ .bounds = entry.bounds, .color = color, .width = width, .shape_type = shape_type, .points = points, .creation_time = creation_time };
}

fn decodeTextBox(alloc: std.mem.Allocator, note: *const model.Note, entry: model.TextBoxEntry) !DecodedTextBox {
    const hdr = try entry.row.header();
    // TextBoxEntity: id, page_id, text, text_size, box_width, box_height, line_height,
    // background_color, bounds, layer, layer_id, default_text_color, ...
    const text = try entry.row.readColumnAlloc(alloc, note.db, hdr, 2);
    const text_size = readF32Col(note.db, entry.row, hdr, 3);
    const color = argbFromSigned(readI64Col(note.db, entry.row, hdr, 11));
    const creation_time = readI64Col(note.db, entry.row, hdr, 12);

    return .{ .bounds = entry.bounds, .text = text, .text_size = text_size, .color = color, .creation_time = creation_time };
}

fn readF32Col(db: anytype, row: anytype, hdr: record.RecordHeader, i: usize) f32 {
    var buf: [8]u8 = undefined;
    const range = hdr.columnRange(i);
    row.readColumn(db, hdr, i, buf[0..range.len]);
    const v = record.decodeValue(hdr.serialType(i), buf[0..range.len]);
    return switch (v) {
        .real => |r| @floatCast(r),
        .int => |n| @floatFromInt(n),
        else => 0,
    };
}

fn readI64Col(db: anytype, row: anytype, hdr: record.RecordHeader, i: usize) i64 {
    var buf: [8]u8 = undefined;
    const range = hdr.columnRange(i);
    row.readColumn(db, hdr, i, buf[0..range.len]);
    const v = record.decodeValue(hdr.serialType(i), buf[0..range.len]);
    return if (v == .int) v.int else 0;
}

/// Keeps decoded (JSON-parsed, ready-to-rasterize) content for only the pages
/// currently "active" (in or near the viewport). Entering a page decodes its
/// strokes/shapes/text; leaving one frees that memory. A page re-entering the
/// window later is simply re-decoded from the b-tree index -- no persistent
/// per-page state is kept once evicted.
pub const Window = struct {
    alloc: std.mem.Allocator,
    note: *const model.Note,
    cache: std.AutoHashMap(u32, PageContent),

    pub fn init(alloc: std.mem.Allocator, note: *const model.Note) Window {
        return .{ .alloc = alloc, .note = note, .cache = std.AutoHashMap(u32, PageContent).init(alloc) };
    }

    pub fn deinit(self: *Window) void {
        var it = self.cache.valueIterator();
        while (it.next()) |content| self.freeContent(content.*);
        self.cache.deinit();
    }

    fn freeContent(self: *Window, content: PageContent) void {
        for (content.strokes) |s| self.alloc.free(s.points);
        self.alloc.free(content.strokes);
        for (content.shapes) |s| self.alloc.free(s.points);
        self.alloc.free(content.shapes);
        for (content.text_boxes) |t| self.alloc.free(t.text);
        self.alloc.free(content.text_boxes);
        self.alloc.free(content.order);
    }

    /// Sets which pages should be decoded right now. Pages not in `page_indices`
    /// that are currently cached get evicted; pages in `page_indices` not yet
    /// cached get decoded.
    pub fn setActive(self: *Window, page_indices: []const u32) !void {
        var wanted = std.AutoHashMap(u32, void).init(self.alloc);
        defer wanted.deinit();
        for (page_indices) |p| try wanted.put(p, {});

        var to_remove = std.array_list.Managed(u32).init(self.alloc);
        defer to_remove.deinit();
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (!wanted.contains(entry.key_ptr.*)) try to_remove.append(entry.key_ptr.*);
        }
        for (to_remove.items) |p| {
            if (self.cache.fetchRemove(p)) |kv| self.freeContent(kv.value);
        }

        for (page_indices) |p| {
            if (self.cache.contains(p)) continue;
            try self.cache.put(p, try self.decodePage(p));
        }
    }

    fn decodePage(self: *Window, page_index: u32) !PageContent {
        var strokes = std.array_list.Managed(DecodedStroke).init(self.alloc);
        for (self.note.strokes) |e| {
            if (e.page_index == page_index) try strokes.append(try decodeStroke(self.alloc, self.note, e));
        }
        var shapes = std.array_list.Managed(DecodedShape).init(self.alloc);
        for (self.note.shapes) |e| {
            if (e.page_index == page_index) try shapes.append(try decodeShape(self.alloc, self.note, e));
        }
        var texts = std.array_list.Managed(DecodedTextBox).init(self.alloc);
        for (self.note.text_boxes) |e| {
            if (e.page_index == page_index) try texts.append(try decodeTextBox(self.alloc, self.note, e));
        }

        var order = try self.alloc.alloc(DrawRef, strokes.items.len + shapes.items.len);
        for (0..strokes.items.len) |i| order[i] = .{ .kind = .stroke, .index = @intCast(i) };
        for (0..shapes.items.len) |i| order[strokes.items.len + i] = .{ .kind = .shape, .index = @intCast(i) };
        const strokes_slice = try strokes.toOwnedSlice();
        const shapes_slice = try shapes.toOwnedSlice();
        const OrderCtx = struct { strokes: []const DecodedStroke, shapes: []const DecodedShape };
        const ctx = OrderCtx{ .strokes = strokes_slice, .shapes = shapes_slice };
        std.mem.sort(DrawRef, order, ctx, struct {
            fn lessThan(c: OrderCtx, a: DrawRef, b: DrawRef) bool {
                const ta = if (a.kind == .stroke) c.strokes[a.index].creation_time else c.shapes[a.index].creation_time;
                const tb = if (b.kind == .stroke) c.strokes[b.index].creation_time else c.shapes[b.index].creation_time;
                return ta < tb;
            }
        }.lessThan);

        return .{
            .strokes = strokes_slice,
            .shapes = shapes_slice,
            .text_boxes = try texts.toOwnedSlice(),
            .order = order,
        };
    }

    pub fn get(self: *Window, page_index: u32) ?PageContent {
        return self.cache.get(page_index);
    }

    pub fn activePageCount(self: *Window) usize {
        return self.cache.count();
    }
};

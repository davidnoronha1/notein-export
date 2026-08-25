const std = @import("std");
const model = @import("model.zig");
const json = @import("json.zig");
const record = @import("sqlite/record.zig");
const tessellate = @import("tessellate.zig");
const util = @import("util.zig");

pub const Point = model.Point;

pub const DecodedStroke = struct {
    bounds: model.Bounds,
    color: u32, // ARGB
    width: f32,
    points: []const Point,
    creation_time: i64,
    /// The stroke's fill polygon, tessellated once here at decode time (see
    /// decodeStroke) instead of on every frame it's visible in -- `raster.zig`
    /// only falls back to re-tessellating on the fly when a render call's
    /// min-width floor needs a wider ribbon than this (thumbnail generation;
    /// never the interactive path). Empty for degenerate (<2 point) strokes.
    tess_poly: [][2]f32 = &.{},
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

/// Uniform spatial grid over `PageContent.order`'s bounds (one page's worth
/// of strokes+shapes), letting a viewport cull query touch only nearby items
/// instead of scanning every item on the page -- see `queryGrid` in main.zig.
/// A CSR (compressed sparse row) layout: `cell_items[cell_start[c]..cell_start[c+1]]`
/// is the list of `order`-indices whose bounds overlap cell `c` (an item
/// spanning multiple cells appears once per cell it touches). Zero `cols`
/// means "empty/no grid" (an empty page) -- callers should skip querying.
pub const Grid = struct {
    cols: u32 = 0,
    rows: u32 = 0,
    min_x: f32 = 0,
    min_y: f32 = 0,
    cell_w: f32 = 1,
    cell_h: f32 = 1,
    cell_start: []const u32 = &.{},
    cell_items: []const u32 = &.{},
};

pub const PageContent = struct {
    strokes: []const DecodedStroke,
    shapes: []const DecodedShape,
    text_boxes: []const DecodedTextBox,
    /// strokes+shapes interleaved by creation_time ascending (draw in this
    /// order -- earlier entries render first / end up underneath).
    order: []const DrawRef,
    grid: Grid = .{},
    /// Per-`order`-index scratch stamp, sized `order.len`, for dedup during a
    /// grid query (an item spanning multiple visited cells must only be
    /// collected once) -- compared against a monotonic generation counter
    /// instead of being cleared on every query. See main.zig's `queryGrid`.
    seen: []u32 = &.{},
};

const argbFromSigned = util.argbFromSigned;
const readF32Col = util.readColumnF32;
const readI64Col = util.readColumnI64;
const clampCell = util.clampCell;
const gridCellIndex = util.gridCellIndex;

fn decodeStroke(alloc: std.mem.Allocator, note: *const model.Note, entry: model.StrokeEntry) !DecodedStroke {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit(); // JSON parse tree is scratch; only the extracted fields below outlive it.
    const scratch = arena.allocator();

    const hdr = try entry.row.header();
    const raw = try entry.row.readColumnAlloc(scratch, note.db, hdr, 4); // record_json
    const parsed = json.parseTyped(json.StrokeJson, scratch, raw) catch return .{
        .bounds = entry.bounds,
        .color = 0xFF000000,
        .width = 1,
        .points = &.{},
        .creation_time = 0,
    };

    const color = argbFromSigned(parsed.color);
    const width = parsed.width;
    const creation_time = parsed.creationTime;

    var raw_points = try scratch.alloc(Point, parsed.points.len);
    for (parsed.points, 0..) |pj, i| {
        raw_points[i] = .{ .x = pj.x, .y = pj.y, .p = pj.p };
    }
    const points = try smoothPoints(alloc, raw_points);
    const tess_poly = try tessellatePoints(alloc, points, width);

    return .{ .bounds = entry.bounds, .color = color, .width = width, .points = points, .creation_time = creation_time, .tess_poly = tess_poly };
}

fn tessellatePoints(alloc: std.mem.Allocator, points: []const Point, width: f32) ![][2]f32 {
    if (points.len < 2) return &.{};
    const buf = try alloc.alloc([2]f32, points.len * 2);
    return tessellate.tessellateStroke(points, width, buf);
}

/// Catmull-Rom-interpolates a raw stylus sample path into a denser point set
/// so `tessellateStroke`'s ribbon polygon follows a smooth curve instead of
/// straight segments between sparse raw samples (visible as faceted/angular
/// bumps on curves like "m"/"e" once zoomed in). Subdivision count per
/// segment adapts to its length, capped to bound point-count blowup on
/// already-dense or very long strokes.
fn smoothPoints(alloc: std.mem.Allocator, raw: []const Point) ![]Point {
    if (raw.len < 3) return alloc.dupe(Point, raw);

    const MAX_SUBDIV = 24;
    const UNITS_PER_STEP = 1.0;
    const MAX_TOTAL_POINTS = 12000;

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

        // AVX2 (8-wide) batch: process 8 t-values at once with Vec8, tail scalar.
        // MAX_SUBDIV is 24, so a typical segment does 3 batches of 8. WASM SIMD is
        // 128-bit (4-wide) — Zig lowers Vec8 to 2× Vec4, still 2× fewer loop
        // iterations than scalar. Native x86_64 with AVX2 does 8-wide in one go.
        const Vec8 = @Vector(8, f32);
        var s: usize = 1;
        // Batch 8
        while (s + 7 <= steps) : (s += 8) {
            var t_vec: Vec8 = undefined;
            inline for (0..8) |k| {
                const sk = s + k;
                t_vec[k] = @as(f32, @floatFromInt(sk)) / @as(f32, @floatFromInt(steps));
            }
            const batch = catmullRomBatch8(p0, p1, p2, p3, t_vec);
            for (batch) |pt| try out.append(pt);
            if (out.items.len >= MAX_TOTAL_POINTS) break;
        }
        // Tail scalar (covers the 9th point case: 8+1)
        while (s <= steps) : (s += 1) {
            const t = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            try out.append(catmullRom(p0, p1, p2, p3, t));
        }
        if (out.items.len >= MAX_TOTAL_POINTS) break;
    }
    return out.toOwnedSlice();
}

fn catmullRom(p0: Point, p1: Point, p2: Point, p3: Point, t: f32) Point {
    // SIMD: compute x,y,p lanes together as Vec3
    const Vec3 = @Vector(3, f32);
    const p0v: Vec3 = .{ p0.x, p0.y, p0.p };
    const p1v: Vec3 = .{ p1.x, p1.y, p1.p };
    const p2v: Vec3 = .{ p2.x, p2.y, p2.p };
    const p3v: Vec3 = .{ p3.x, p3.y, p3.p };
    const t2 = t * t;
    const t3 = t2 * t;
    const tv: Vec3 = @splat(t);
    const t2v: Vec3 = @splat(t2);
    const t3v: Vec3 = @splat(t3);
    const res: Vec3 = @as(Vec3, @splat(0.5)) * (
        @as(Vec3, @splat(2)) * p1v +
        (-p0v + p2v) * tv +
        (@as(Vec3, @splat(2)) * p0v - @as(Vec3, @splat(5)) * p1v + @as(Vec3, @splat(4)) * p2v - p3v) * t2v +
        (-p0v + @as(Vec3, @splat(3)) * p1v - @as(Vec3, @splat(3)) * p2v + p3v) * t3v
    );
    return .{ .x = res[0], .y = res[1], .p = res[2] };
}

// AVX2-width (8-lane) batch version — computes 8 Catmull-Rom points in parallel.
// Each lane k holds t[k]; x/y/p are computed as Vec8. This is the hot path for
// smoothPoints: 24 subdivisions → 3× Vec8 batches (covers 9 points as 8+1).
fn catmullRomBatch8(p0: Point, p1: Point, p2: Point, p3: Point, t: @Vector(8, f32)) [8]Point {
    const Vec8 = @Vector(8, f32);
    const t2: Vec8 = t * t;
    const t3: Vec8 = t2 * t;

    const p0x: Vec8 = @splat(p0.x); const p0y: Vec8 = @splat(p0.y); const p0p: Vec8 = @splat(p0.p);
    const p1x: Vec8 = @splat(p1.x); const p1y: Vec8 = @splat(p1.y); const p1p: Vec8 = @splat(p1.p);
    const p2x: Vec8 = @splat(p2.x); const p2y: Vec8 = @splat(p2.y); const p2p: Vec8 = @splat(p2.p);
    const p3x: Vec8 = @splat(p3.x); const p3y: Vec8 = @splat(p3.y); const p3p: Vec8 = @splat(p3.p);

    const two: Vec8 = @splat(2); const three: Vec8 = @splat(3); const four: Vec8 = @splat(4); const five: Vec8 = @splat(5);
    const half: Vec8 = @splat(0.5);

    const x = half * (two * p1x + (-p0x + p2x) * t + (two * p0x - five * p1x + four * p2x - p3x) * t2 + (-p0x + three * p1x - three * p2x + p3x) * t3);
    const y = half * (two * p1y + (-p0y + p2y) * t + (two * p0y - five * p1y + four * p2y - p3y) * t2 + (-p0y + three * p1y - three * p2y + p3y) * t3);
    const p = half * (two * p1p + (-p0p + p2p) * t + (two * p0p - five * p1p + four * p2p - p3p) * t2 + (-p0p + three * p1p - three * p2p + p3p) * t3);

    var out: [8]Point = undefined;
    inline for (0..8) |k| out[k] = .{ .x = x[k], .y = y[k], .p = p[k] };
    return out;
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
    if (json.parseTyped([]json.ShapePointJson, scratch, points_json)) |typed_pts| {
        points = try alloc.alloc([2]f32, typed_pts.len);
        for (typed_pts, 0..) |pj, i| points[i] = .{ pj.x, pj.y };
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

fn boundsOfRef(ref: DrawRef, strokes: []const DecodedStroke, shapes: []const DecodedShape) model.Bounds {
    return switch (ref.kind) {
        .stroke => strokes[ref.index].bounds,
        .shape => shapes[ref.index].bounds,
    };
}

const CellRange = struct { cx0: u32, cx1: u32, cy0: u32, cy1: u32 };

fn cellRangeFor(b: model.Bounds, min_x: f32, min_y: f32, cell_w: f32, cell_h: f32, cols: u32, rows: u32) CellRange {
    return .{
        .cx0 = clampCell((b.left - min_x) / cell_w, cols),
        .cx1 = clampCell((b.right - min_x) / cell_w, cols),
        .cy0 = clampCell((b.top - min_y) / cell_h, rows),
        .cy1 = clampCell((b.bottom - min_y) / cell_h, rows),
    };
}

/// Builds a uniform spatial grid over `order`'s items (see `Grid`'s doc
/// comment), sized to average roughly one item per cell so a viewport query
/// touches close to `O(visible)` cells+items instead of scanning every item
/// on the page. Two passes over `order` (count, then fill) -- cheap relative
/// to the JSON-decode + smoothing + tessellation `order`'s items already went
/// through to get here, and this only runs once per page decode, not per frame.
fn buildGrid(alloc: std.mem.Allocator, order: []const DrawRef, strokes: []const DecodedStroke, shapes: []const DecodedShape) !Grid {
    if (order.len == 0) return .{};

    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for (order) |ref| {
        const b = boundsOfRef(ref, strokes, shapes);
        min_x = @min(min_x, b.left);
        max_x = @max(max_x, b.right);
        min_y = @min(min_y, b.top);
        max_y = @max(max_y, b.bottom);
    }
    if (!std.math.isFinite(min_x) or !std.math.isFinite(min_y) or !std.math.isFinite(max_x) or !std.math.isFinite(max_y)) return .{};

    const w = @max(1.0, max_x - min_x);
    const h = @max(1.0, max_y - min_y);
    const target = std.math.clamp(@sqrt(@as(f32, @floatFromInt(order.len))), 1.0, 128.0);
    const cols: u32 = @intFromFloat(target);
    const rows: u32 = cols;
    const cell_w = w / @as(f32, @floatFromInt(cols));
    const cell_h = h / @as(f32, @floatFromInt(rows));
    const n_cells: usize = @as(usize, cols) * @as(usize, rows);

    const counts = try alloc.alloc(u32, n_cells);
    defer alloc.free(counts);
    @memset(counts, 0);
    for (order) |ref| {
        const r = cellRangeFor(boundsOfRef(ref, strokes, shapes), min_x, min_y, cell_w, cell_h, cols, rows);
        var cy = r.cy0;
        while (cy <= r.cy1) : (cy += 1) {
            var cx = r.cx0;
            while (cx <= r.cx1) : (cx += 1) counts[cy * cols + cx] += 1;
        }
    }

    const cell_start = try alloc.alloc(u32, n_cells + 1);
    var acc: u32 = 0;
    for (0..n_cells) |i| {
        cell_start[i] = acc;
        acc += counts[i];
    }
    cell_start[n_cells] = acc;

    const cursor = try alloc.alloc(u32, n_cells);
    defer alloc.free(cursor);
    @memcpy(cursor, cell_start[0..n_cells]);

    const cell_items = try alloc.alloc(u32, acc);
    for (order, 0..) |ref, idx| {
        const r = cellRangeFor(boundsOfRef(ref, strokes, shapes), min_x, min_y, cell_w, cell_h, cols, rows);
        var cy = r.cy0;
        while (cy <= r.cy1) : (cy += 1) {
            var cx = r.cx0;
            while (cx <= r.cx1) : (cx += 1) {
                const cell = cy * cols + cx;
                cell_items[cursor[cell]] = @intCast(idx);
                cursor[cell] += 1;
            }
        }
    }

    return .{ .cols = cols, .rows = rows, .min_x = min_x, .min_y = min_y, .cell_w = cell_w, .cell_h = cell_h, .cell_start = cell_start, .cell_items = cell_items };
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
        for (content.strokes) |s| {
            self.alloc.free(s.points);
            self.alloc.free(s.tess_poly);
        }
        self.alloc.free(content.strokes);
        for (content.shapes) |s| self.alloc.free(s.points);
        self.alloc.free(content.shapes);
        for (content.text_boxes) |t| self.alloc.free(t.text);
        self.alloc.free(content.text_boxes);
        self.alloc.free(content.order);
        self.alloc.free(content.grid.cell_start);
        self.alloc.free(content.grid.cell_items);
        self.alloc.free(content.seen);
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

        const grid = try buildGrid(self.alloc, order, strokes_slice, shapes_slice);
        const seen = try self.alloc.alloc(u32, order.len);
        @memset(seen, 0);

        return .{
            .strokes = strokes_slice,
            .shapes = shapes_slice,
            .text_boxes = try texts.toOwnedSlice(),
            .order = order,
            .grid = grid,
            .seen = seen,
        };
    }

    pub fn get(self: *Window, page_index: u32) ?PageContent {
        return self.cache.get(page_index);
    }

    pub fn activePageCount(self: *Window) usize {
        return self.cache.count();
    }
};

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
    is_calligraphic: bool = false,
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

fn smoothPressure(alloc: std.mem.Allocator, raw: []const Point) ![]Point {
    if (raw.len == 0) return &.{};
    const PRESSURE_SMOOTH_RADIUS = 2;
    const work = try alloc.alloc(Point, raw.len);
    for (raw, 0..) |pt, wi| {
        const lo = if (wi >= PRESSURE_SMOOTH_RADIUS) wi - PRESSURE_SMOOTH_RADIUS else 0;
        const hi = @min(raw.len, wi + PRESSURE_SMOOTH_RADIUS + 1);
        var sum: f32 = 0;
        var k = lo;
        while (k < hi) : (k += 1) sum += raw[k].p;
        work[wi] = .{ .x = pt.x, .y = pt.y, .p = sum / @as(f32, @floatFromInt(hi - lo)) };
    }
    return work;
}

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
        .is_calligraphic = false,
    };

    const color = argbFromSigned(parsed.color);
    const width = parsed.width;
    const creation_time = parsed.creationTime;

    var raw_points = try scratch.alloc(Point, parsed.points.len);
    for (parsed.points, 0..) |pj, i| {
        raw_points[i] = .{ .x = pj.x, .y = pj.y, .p = pj.p };
    }
    const points = try smoothPressure(alloc, raw_points);

    return .{
        .bounds = entry.bounds,
        .color = color,
        .width = width,
        .points = points,
        .creation_time = creation_time,
        .is_calligraphic = false,
    };
}

/// Turns a Nebo raw-decoded stroke (already absolute points + pressure, see
/// nebo.zig) into a `DecodedStroke` with smoothed pressure.
fn decodeNeboStroke(alloc: std.mem.Allocator, ns: model.NeboStroke) !DecodedStroke {
    const points = try smoothPressure(alloc, ns.points);
    return .{
        .bounds = ns.bounds,
        .color = ns.color,
        .width = ns.width,
        .points = points,
        .creation_time = ns.creation_time,
        .is_calligraphic = true,
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
        if (self.note.nebo_pages) |pages| {
            // Nebo path: ink is already decoded to points in model.open; just
            // run the same smoothing + tessellation the .in path uses so the
            // ribbons match. Nebo notes have no shapes/text boxes.
            if (page_index < pages.len) {
                for (pages[page_index]) |ns| try strokes.append(try decodeNeboStroke(self.alloc, ns));
            }
        } else {
            for (self.note.strokes) |e| {
                if (e.page_index == page_index) try strokes.append(try decodeStroke(self.alloc, self.note, e));
            }
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

        const grid = if (order.len >= 32) try buildGrid(self.alloc, order, strokes_slice, shapes_slice) else Grid{};
        const seen = if (grid.cols > 0) try self.alloc.alloc(u32, order.len) else @as([]u32, &.{});
        if (grid.cols > 0) @memset(seen, 0);

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

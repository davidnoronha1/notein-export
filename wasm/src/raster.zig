const std = @import("std");
const window = @import("window.zig");
const tessellate = @import("tessellate.zig");

/// RGBA8 pixel buffer the caller owns; we only ever write into it (never read
/// back), so JS can hand us a reusable buffer across frames.
pub const Canvas = struct {
    pixels: []u8, // width*height*4 bytes, row-major RGBA
    width: u32,
    height: u32,

    /// Viewport transform: (world_x - origin_x) * scale = pixel_x, etc.
    origin_x: f32,
    origin_y: f32,
    scale: f32,

    pub fn clear(self: Canvas, argb: u32) void {
        const r: u8 = @truncate(argb >> 16);
        const g: u8 = @truncate(argb >> 8);
        const b: u8 = @truncate(argb);
        const a: u8 = @truncate(argb >> 24);

        // SIMD: fill 4 bytes (one pixel) per vector store; 16-byte vectors
        // do 4 pixels at once. `pixels` is always a multiple of 4, so no tail.
        if (self.pixels.len == 0) return;
        const Vec4 = @Vector(4, u8);
        const Vec16 = @Vector(16, u8);
        const pat4: Vec4 = .{ r, g, b, a };
        const pat16: Vec16 = .{ r, g, b, a, r, g, b, a, r, g, b, a, r, g, b, a };

        const n = self.pixels.len;
        // Prefer 16-byte vectors when naturally aligned; fallback to 4-byte.
        // Use align(1) to allow unaligned buffers (wasm linear memory may be).
        if (@intFromPtr(self.pixels.ptr) % @alignOf(Vec16) == 0) {
            const n16 = n / 16 * 16;
            const vec_ptr = @as([*]align(1) Vec16, @ptrCast(self.pixels.ptr));
            const vec_count = n16 / 16;
            for (0..vec_count) |vi| vec_ptr[vi] = pat16;
            // Handle remaining 0-12 bytes (always multiple of 4) with Vec4
            const remaining = n - n16;
            if (remaining > 0) {
                const vec4_ptr = @as([*]align(1) Vec4, @ptrCast(self.pixels.ptr + n16));
                for (0..remaining / 4) |vi| vec4_ptr[vi] = pat4;
            }
        } else {
            const vec_ptr = @as([*]align(1) Vec4, @ptrCast(self.pixels.ptr));
            for (0..n / 4) |vi| vec_ptr[vi] = pat4;
        }
    }

    fn toPixel(self: Canvas, x: f32, y: f32) [2]f32 {
        return .{ (x - self.origin_x) * self.scale, (y - self.origin_y) * self.scale };
    }

    /// Alpha-blends a single pixel (straight, non-premultiplied source alpha).
    fn blend(self: Canvas, px: i32, py: i32, argb: u32) void {
        if (px < 0 or py < 0 or px >= self.width or py >= self.height) return;
        const idx = (@as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px))) * 4;
        if (idx + 4 > self.pixels.len) @panic("blend out of bounds");
        const sa: u32 = (argb >> 24) & 0xff;
        if (sa == 0) return;
        const sr: u32 = (argb >> 16) & 0xff;
        const sg: u32 = (argb >> 8) & 0xff;
        const sb: u32 = argb & 0xff;
        if (sa == 255) {
            self.pixels[idx] = @truncate(sr);
            self.pixels[idx + 1] = @truncate(sg);
            self.pixels[idx + 2] = @truncate(sb);
            self.pixels[idx + 3] = 255;
            return;
        }
        const dr = self.pixels[idx];
        const dg = self.pixels[idx + 1];
        const db = self.pixels[idx + 2];
        const da = self.pixels[idx + 3];
        self.pixels[idx] = @truncate((sr * sa + @as(u32, dr) * (255 - sa)) / 255);
        self.pixels[idx + 1] = @truncate((sg * sa + @as(u32, dg) * (255 - sa)) / 255);
        self.pixels[idx + 2] = @truncate((sb * sa + @as(u32, db) * (255 - sa)) / 255);
        self.pixels[idx + 3] = @truncate(@min(255, sa + (@as(u32, da) * (255 - sa)) / 255));
    }

    /// Scanline-fills a polygon using the nonzero winding rule, anti-aliased:
    /// horizontal edges get analytic fractional coverage per pixel, vertical
    /// edges are smoothed by supersampling several sub-scanlines per pixel
    /// row and averaging. `poly` is a flat list of world-space (x, y) pairs.
    ///
    /// Nonzero winding (not even-odd) matters here: `tessellateStroke`'s
    /// variable-width ribbon self-overlaps at sharp corners/direction
    /// reversals (no explicit miter/bevel join), and even-odd would XOR that
    /// overlap back out into an unfilled hole -- exactly the "letters not
    /// filled in properly" symptom.
    fn fillPolygon(self: Canvas, poly: []const [2]f32, argb: u32) void {
        if (poly.len < 3) return;

        const Vec2 = @Vector(2, f32);
        var mins: Vec2 = .{ poly[0][0], poly[0][1] };
        var maxs: Vec2 = mins;
        for (poly[1..]) |p| {
            const v: Vec2 = .{ p[0], p[1] };
            mins = @min(mins, v);
            maxs = @max(maxs, v);
        }
        const min_x = mins[0];
        const max_x = maxs[0];
        const min_y = mins[1];
        const max_y = maxs[1];
        const pmin_y = self.toPixel(0, min_y)[1];
        const pmax_y = self.toPixel(0, max_y)[1];
        const y0: i32 = @max(0, @as(i32, @intFromFloat(@floor(pmin_y))));
        const y1: i32 = @min(@as(i32, @intCast(self.height)), @as(i32, @intFromFloat(@ceil(pmax_y))) + 1);
        if (y1 <= y0) return;

        const pmin_x = self.toPixel(min_x, 0)[0];
        const pmax_x = self.toPixel(max_x, 0)[0];
        const cx0: i32 = @max(0, @as(i32, @intFromFloat(@floor(pmin_x))));
        const cx1: i32 = @min(@as(i32, @intCast(self.width)), @as(i32, @intFromFloat(@ceil(pmax_x))) + 1);
        if (cx1 <= cx0) return;
        const span_w: usize = @intCast(cx1 - cx0);

        if (span_w > scratch_coverage.len) {
            fillPolygonAliased(self, poly, argb, y0, y1);
            return;
        }

        const coverage = scratch_coverage[0..span_w];
        const src_a = (argb >> 24) & 0xff;
        var xs_buf: [256]Crossing = undefined;

        var py = y0;
        while (py < y1) : (py += 1) {
            @memset(coverage, 0);

            var sub: usize = 0;
            while (sub < SUBSAMPLES) : (sub += 1) {
                const sub_offset = (@as(f32, @floatFromInt(sub)) + 0.5) / @as(f32, @floatFromInt(SUBSAMPLES));
                const world_y = self.origin_y + (@as(f32, @floatFromInt(py)) + sub_offset) / self.scale;
                const xs = collectCrossings(poly, world_y, &xs_buf);

                var winding: i32 = 0;
                var span_start: f32 = 0;
                var in_span = false;
                for (xs) |c| {
                    if (!in_span) span_start = c.x;
                    winding += c.dir;
                    const was_in = in_span;
                    in_span = winding != 0;
                    if (was_in and !in_span) {
                        const px0 = self.toPixel(span_start, 0)[0] - @as(f32, @floatFromInt(cx0));
                        const px1 = self.toPixel(c.x, 0)[0] - @as(f32, @floatFromInt(cx0));
                        addSpanCoverage(coverage, px0, px1, 1.0 / @as(f32, @floatFromInt(SUBSAMPLES)));
                    }
                }
            }

            var px_i: usize = 0;
            while (px_i < span_w) : (px_i += 1) {
                const cov = @min(1.0, coverage[px_i]);
                if (cov <= 0.001) continue;
                const a: u32 = @intFromFloat(@as(f32, @floatFromInt(src_a)) * cov + 0.5);
                if (a == 0) continue;
                self.blend(cx0 + @as(i32, @intCast(px_i)), py, (a << 24) | (argb & 0x00FFFFFF));
            }
        }
    }

    /// Un-anti-aliased fallback for polygons whose bounding box is wider than
    /// the fixed-size coverage scratch buffer (e.g. an unusually large filled
    /// region) -- still renders correctly (nonzero winding rule, same as the
    /// main path), just without edge smoothing.
    fn fillPolygonAliased(self: Canvas, poly: []const [2]f32, argb: u32, y0: i32, y1: i32) void {
        var xs_buf: [256]Crossing = undefined;
        var py = y0;
        while (py < y1) : (py += 1) {
            const world_y = self.origin_y + (@as(f32, @floatFromInt(py)) + 0.5) / self.scale;
            const xs = collectCrossings(poly, world_y, &xs_buf);

            var winding: i32 = 0;
            var span_start: f32 = 0;
            var in_span = false;
            for (xs) |c| {
                if (!in_span) span_start = c.x;
                winding += c.dir;
                const was_in = in_span;
                in_span = winding != 0;
                if (was_in and !in_span) {
                    const px0 = self.toPixel(span_start, 0)[0];
                    const px1 = self.toPixel(c.x, 0)[0];
                    var px = @max(0, @as(i32, @intFromFloat(@floor(px0))));
                    const px_end = @min(@as(i32, @intCast(self.width)), @as(i32, @intFromFloat(@ceil(px1))));
                    while (px < px_end) : (px += 1) self.blend(px, py, argb);
                }
            }
        }
    }
};

const SUBSAMPLES: usize = 4;
var scratch_coverage: [8192]f32 = undefined;

const Crossing = struct { x: f32, dir: i32 };

fn crossingLessThan(_: void, a: Crossing, b: Crossing) bool {
    return a.x < b.x;
}

/// Finds every polygon edge crossing the horizontal line `world_y`, sorted
/// left-to-right, tagged with winding direction (+1 edge going downward in
/// y as it crosses, -1 going upward) for nonzero-rule span accumulation.
fn collectCrossings(poly: []const [2]f32, world_y: f32, out: []Crossing) []Crossing {
    var count: usize = 0;
    var i: usize = 0;
    while (i < poly.len) : (i += 1) {
        const a = poly[i];
        const b = poly[(i + 1) % poly.len];
        if (a[1] <= world_y and b[1] > world_y) {
            const t = (world_y - a[1]) / (b[1] - a[1]);
            if (count < out.len) {
                out[count] = .{ .x = a[0] + t * (b[0] - a[0]), .dir = 1 };
                count += 1;
            }
        } else if (b[1] <= world_y and a[1] > world_y) {
            const t = (world_y - a[1]) / (b[1] - a[1]);
            if (count < out.len) {
                out[count] = .{ .x = a[0] + t * (b[0] - a[0]), .dir = -1 };
                count += 1;
            }
        }
    }
    const xs = out[0..count];
    std.mem.sort(Crossing, xs, {}, crossingLessThan);
    return xs;
}

/// Accumulates fractional horizontal coverage of `[x0, x1)` (in pixel-space,
/// relative to `coverage`'s start) into `coverage`, weighted by `weight`
/// (used to average multiple vertical sub-scanlines into one pixel row).
fn addSpanCoverage(coverage: []f32, x0: f32, x1: f32, weight: f32) void {
    const cx0 = @max(0.0, x0);
    const cx1 = @min(@as(f32, @floatFromInt(coverage.len)), x1);
    if (cx1 <= cx0) return;

    const ix0: i32 = @intFromFloat(@floor(cx0));
    const ix1: i32 = @intFromFloat(@floor(cx1));
    if (ix0 == ix1) {
        if (ix0 >= 0 and ix0 < coverage.len) coverage[@intCast(ix0)] += (cx1 - cx0) * weight;
        return;
    }
    if (ix0 >= 0 and ix0 < coverage.len) {
        coverage[@intCast(ix0)] += (@as(f32, @floatFromInt(ix0 + 1)) - cx0) * weight;
    }
    // SIMD: 8-wide vector add for the interior span (most pixels are interior)
    var ix = ix0 + 1;
    if (ix < ix1) {
        const w8: @Vector(8, f32) = @splat(weight);
        // Vectorized chunk: 8 f32 (32 bytes) per iteration. Use align(1) to allow
        // any coverage offset (wasm linear memory may be unaligned for Vec8).
        while (ix + 8 <= ix1) : (ix += 8) {
            const base: usize = @intCast(ix);
            const ptr = @as(*align(1) @Vector(8, f32), @ptrCast(&coverage[base]));
            ptr.* += w8;
        }
        while (ix < ix1) : (ix += 1) {
            coverage[@intCast(ix)] += weight;
        }
    }
    if (ix1 >= 0 and ix1 < coverage.len) {
        coverage[@intCast(ix1)] += (cx1 - @as(f32, @floatFromInt(ix1))) * weight;
    }
}

var scratch_poly: [8192][2]f32 = undefined;

/// Dark-mode ink inversion, toggled from JS via main.zig's `set_invert_colors`.
/// Applied at color-consumption time (not decode time) so the per-page decoded
/// caches in window.zig stay valid across toggles.
pub var invert_colors: bool = false;

/// Maps a content ARGB through the current invert setting. Used for every
/// content color crossing into pixels (drawStroke/drawShape) or back out to
/// JS (vector polys, textbox draws), so live view and all export paths stay
/// in sync automatically.
///
/// Dark-mode transform, matching how the Nebo app itself renders in dark mode:
/// flip HSL lightness while keeping hue and saturation. White paper -> black,
/// black ink -> white, and a colored pen keeps its hue but lightens (e.g. the
/// deep maroon #87202B becomes a soft pink, blue #1364B7 a lighter blue) so it
/// stays vivid on the dark backdrop instead of sinking into it. Not a bitwise
/// RGB flip (that would change hue, turning a pen into a different color). This
/// is an involution (l -> 1-l twice restores l), so toggling dark mode twice
/// gives back the exact original colors. Mirrored in web/src/canvas/color.ts's
/// invertArgb -- keep the two identical.
pub fn outputColor(argb: u32) u32 {
    if (!invert_colors) return argb;
    const r = @as(f32, @floatFromInt((argb >> 16) & 0xFF)) / 255;
    const g = @as(f32, @floatFromInt((argb >> 8) & 0xFF)) / 255;
    const b = @as(f32, @floatFromInt(argb & 0xFF)) / 255;

    var c = rgbToHsl(r, g, b);
    c.l = 1 - c.l;

    const rgb = hslToRgb(c);
    const ri: u32 = @intFromFloat(std.math.clamp(rgb[0], 0, 1) * 255 + 0.5);
    const gi: u32 = @intFromFloat(std.math.clamp(rgb[1], 0, 1) * 255 + 0.5);
    const bi: u32 = @intFromFloat(std.math.clamp(rgb[2], 0, 1) * 255 + 0.5);
    return (argb & 0xFF000000) | (ri << 16) | (gi << 8) | bi;
}

const Hsl = struct { h: f32, s: f32, l: f32 };

fn rgbToHsl(r: f32, g: f32, b: f32) Hsl {
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    const l = (max + min) / 2;
    if (max == min) return .{ .h = 0, .s = 0, .l = l };
    const d = max - min;
    const s = if (l > 0.5) d / (2 - max - min) else d / (max + min);
    const h: f32 = if (max == r)
        (g - b) / d + if (g < b) @as(f32, 6) else 0
    else if (max == g)
        (b - r) / d + 2
    else
        (r - g) / d + 4;
    return .{ .h = h / 6, .s = s, .l = l };
}

fn hueToRgb(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

fn hslToRgb(c: Hsl) [3]f32 {
    if (c.s == 0) return .{ c.l, c.l, c.l };
    const q = if (c.l < 0.5) c.l * (1 + c.s) else c.l + c.s - c.l * c.s;
    const p = 2 * c.l - q;
    return .{
        hueToRgb(p, q, c.h + 1.0 / 3.0),
        hueToRgb(p, q, c.h),
        hueToRgb(p, q, c.h - 1.0 / 3.0),
    };
}

/// Rasterizes decoded strokes and shapes for one page's content into `canvas`,
/// in `content.order` (chronological/stacking) order rather than always
/// drawing every stroke before every shape -- otherwise a shape drawn before
/// some ink would incorrectly always render on top of it, and vice versa.
/// This is the hot path: called once per visible page per frame.
pub fn renderPageContent(canvas: Canvas, content: window.PageContent, min_width_world: f32) void {
    for (content.order) |ref| {
        switch (ref.kind) {
            .stroke => drawStroke(canvas, content.strokes[ref.index], min_width_world),
            .shape => drawShape(canvas, content.shapes[ref.index], min_width_world),
        }
    }
}

const builtin = @import("builtin");
var g_debug_alloc: if (builtin.target.cpu.arch != .wasm32) std.heap.DebugAllocator(.{}) else void = if (builtin.target.cpu.arch != .wasm32) .init else {};
fn getGpa() std.mem.Allocator {
    return if (builtin.target.cpu.arch == .wasm32) std.heap.wasm_allocator else g_debug_alloc.allocator();
}
var g_poly_buf: ?std.array_list.Managed([2]f32) = null;
var g_right_buf: ?std.array_list.Managed([2]f32) = null;

fn drawStroke(canvas: Canvas, s: window.DecodedStroke, min_width_world: f32) void {
    if (s.points.len == 0) return;
    const width = @max(s.width, min_width_world);

    if (g_poly_buf == null) g_poly_buf = std.array_list.Managed([2]f32).init(getGpa());
    if (g_right_buf == null) g_right_buf = std.array_list.Managed([2]f32).init(getGpa());

    tessellate.smoothAndTessellateAdaptive(s.points, width, canvas.scale, s.is_calligraphic, &g_poly_buf.?, &g_right_buf.?) catch return;
    const poly = g_poly_buf.?.items;

    if (poly.len >= 3) canvas.fillPolygon(poly, outputColor(s.color));
}

fn drawShape(canvas: Canvas, s: window.DecodedShape, min_width_world: f32) void {
    // Notein's shape tool (rectangle/line/etc.) is stroke-only, like a
    // ruler-guided pen stroke -- there's no fill color/flag anywhere in
    // ShapeEntity's columns or its points JSON, so every shape (closed
    // polygon or open line) is drawn as an outline of `width`, never filled.
    const width = @max(s.width, min_width_world);
    const color = outputColor(s.color);
    if (s.points.len >= 3) {
        var i: usize = 0;
        while (i < s.points.len) : (i += 1) {
            drawLine(canvas, s.points[i], s.points[(i + 1) % s.points.len], width, color);
        }
    } else if (s.points.len == 2) {
        drawLine(canvas, s.points[0], s.points[1], width, color);
    }
}

fn drawLine(canvas: Canvas, a: [2]f32, b: [2]f32, width: f32, argb: u32) void {
    const quad = tessellate.quadForLine(a, b, width);
    canvas.fillPolygon(&quad, argb);
}

test "renderPageContent fills a simple stroke into the canvas buffer" {
    const pixels = try std.testing.allocator.alignedAlloc(u8, .@"16", 16 * 16 * 4);
    defer std.testing.allocator.free(pixels);
    const canvas = Canvas{ .pixels = pixels, .width = 16, .height = 16, .origin_x = 0, .origin_y = 0, .scale = 1 };
    canvas.clear(0x00000000);

    var pts = [_]window.Point{
        .{ .x = 2, .y = 8, .p = 1.0 },
        .{ .x = 14, .y = 8, .p = 1.0 },
    };
    const content = window.PageContent{
        .strokes = &[_]window.DecodedStroke{.{ .bounds = undefined, .color = 0xFFFF0000, .width = 4, .points = &pts, .creation_time = 0 }},
        .shapes = &.{},
        .text_boxes = &.{},
        .order = &[_]window.DrawRef{.{ .kind = .stroke, .index = 0 }},
    };
    renderPageContent(canvas, content, 0);

    // Center of the stroke should now be opaque red.
    const idx = (8 * 16 + 8) * 4;
    try std.testing.expectEqual(@as(u8, 255), pixels[idx]); // R
    try std.testing.expectEqual(@as(u8, 255), pixels[idx + 3]); // A
}

test "outputColor dark-mode remap: flip lightness, keep hue" {
    invert_colors = true;
    defer invert_colors = false;

    // Black ink -> white, white paper -> black (JS mirrors this for backgrounds).
    try std.testing.expectEqual(@as(u32, 0xFF000000) | 0xFFFFFF, outputColor(0xFF000000));
    try std.testing.expectEqual(@as(u32, 0xFF000000), outputColor(0xFFFFFFFF));
    // Alpha always preserved.
    try std.testing.expectEqual(@as(u32, 0x80000000), outputColor(0x80FFFFFF) & 0xFF000000);

    // A deep chromatic pen lightens (more visible on the dark backdrop) but
    // keeps its hue family -- the blue channel stays dominant, not shifted to
    // its complement.
    const from_blue = outputColor(0xFF1364B7); // deep blue
    const br: u32 = (from_blue >> 16) & 0xFF;
    const bg: u32 = (from_blue >> 8) & 0xFF;
    const bb: u32 = from_blue & 0xFF;
    try std.testing.expect(bb >= br and bb >= bg); // still bluest channel
    try std.testing.expect(br + bg + bb > 0x13 + 0x64 + 0xB7); // and lighter overall

    // Involution: applying twice restores the original (checked on a neutral,
    // where HSL round-trips exactly).
    try std.testing.expectEqual(@as(u32, 0xFF333333), outputColor(outputColor(0xFF333333)));
}

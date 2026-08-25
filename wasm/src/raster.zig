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
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) {
            self.pixels[i] = r;
            self.pixels[i + 1] = g;
            self.pixels[i + 2] = b;
            self.pixels[i + 3] = a;
        }
    }

    fn toPixel(self: Canvas, x: f32, y: f32) [2]f32 {
        return .{ (x - self.origin_x) * self.scale, (y - self.origin_y) * self.scale };
    }

    /// Alpha-blends a single pixel (straight, non-premultiplied source alpha).
    fn blend(self: Canvas, px: i32, py: i32, argb: u32) void {
        if (px < 0 or py < 0 or px >= self.width or py >= self.height) return;
        const idx = (@as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px))) * 4;
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

        var min_x: f32 = poly[0][0];
        var max_x: f32 = poly[0][0];
        var min_y: f32 = poly[0][1];
        var max_y: f32 = poly[0][1];
        for (poly) |p| {
            min_x = @min(min_x, p[0]);
            max_x = @max(max_x, p[0]);
            min_y = @min(min_y, p[1]);
            max_y = @max(max_y, p[1]);
        }
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
    var ix = ix0 + 1;
    while (ix < ix1) : (ix += 1) {
        if (ix >= 0 and ix < coverage.len) coverage[@intCast(ix)] += weight;
    }
    if (ix1 >= 0 and ix1 < coverage.len) {
        coverage[@intCast(ix1)] += (cx1 - @as(f32, @floatFromInt(ix1))) * weight;
    }
}

var scratch_poly: [8192][2]f32 = undefined;

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

fn drawStroke(canvas: Canvas, s: window.DecodedStroke, min_width_world: f32) void {
    if (s.points.len < 2) return;
    // Common case: `s.tess_poly` was already tessellated once at decode time
    // (see window.zig's decodeStroke) at the stroke's real width, and the
    // per-frame min-width floor doesn't need to raise it -- reuse it instead
    // of re-tessellating this stroke on every single frame it's visible in.
    // The floor only actually raises the width when zoomed out enough that
    // `s.width` would round to sub-pixel (main interactive rendering always
    // passes min_width_world=0; only thumbnail generation floors it), so
    // this fast path covers the hot (pan/zoom) case.
    if (min_width_world <= s.width and s.tess_poly.len >= 3) {
        canvas.fillPolygon(s.tess_poly, s.color);
        return;
    }
    const width = @max(s.width, min_width_world);
    const poly = if (s.points.len * 2 <= scratch_poly.len)
        tessellate.tessellateStroke(s.points, width, &scratch_poly)
    else
        &[_][2]f32{};
    if (poly.len >= 3) canvas.fillPolygon(poly, s.color);
}

fn drawShape(canvas: Canvas, s: window.DecodedShape, min_width_world: f32) void {
    // Notein's shape tool (rectangle/line/etc.) is stroke-only, like a
    // ruler-guided pen stroke -- there's no fill color/flag anywhere in
    // ShapeEntity's columns or its points JSON, so every shape (closed
    // polygon or open line) is drawn as an outline of `width`, never filled.
    const width = @max(s.width, min_width_world);
    if (s.points.len >= 3) {
        var i: usize = 0;
        while (i < s.points.len) : (i += 1) {
            drawLine(canvas, s.points[i], s.points[(i + 1) % s.points.len], width, s.color);
        }
    } else if (s.points.len == 2) {
        drawLine(canvas, s.points[0], s.points[1], width, s.color);
    }
}

fn drawLine(canvas: Canvas, a: [2]f32, b: [2]f32, width: f32, argb: u32) void {
    const quad = tessellate.quadForLine(a, b, width);
    canvas.fillPolygon(&quad, argb);
}

test "renderPageContent fills a simple stroke into the canvas buffer" {
    var pixels: [16 * 16 * 4]u8 = @splat(0);
    const canvas = Canvas{ .pixels = &pixels, .width = 16, .height = 16, .origin_x = 0, .origin_y = 0, .scale = 1 };
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

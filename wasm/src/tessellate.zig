const std = @import("std");
const model = @import("model.zig");

/// Builds a variable-width outline polygon from a pressure-tagged stroke
/// point path (perfect-freehand-style: pressure -> local radius, left/right
/// offset points along the path normal), writing into `out` (caller-sized;
/// returns the used prefix). Degenerate strokes (<2 points) fall back to
/// nothing (a dot isn't worth a special case at this stage).
pub fn tessellateStroke(points: []const model.Point, base_width: f32, out: [][2]f32) [][2]f32 {
    if (points.len < 2 or out.len < points.len * 2) return out[0..0];

    var n: usize = 0;
    var i: usize = 0;
    while (i < points.len) : (i += 1) {
        const p = points[i];
        const prev = points[if (i == 0) 0 else i - 1];
        const next = points[if (i + 1 < points.len) i + 1 else i];
        var dx = next.x - prev.x;
        var dy = next.y - prev.y;
        const len = @sqrt(dx * dx + dy * dy);
        if (len > 0.0001) {
            dx /= len;
            dy /= len;
        } else {
            dx = 0;
            dy = 0;
        }
        // Normal (perpendicular) direction.
        const nx = -dy;
        const ny = dx;
        const radius = @max(0.4, base_width * @max(0.15, p.p)) * 0.5;

        out[n] = .{ p.x + nx * radius, p.y + ny * radius };
        n += 1;
        out[points.len * 2 - 1 - i] = .{ p.x - nx * radius, p.y - ny * radius };
    }
    return out[0 .. points.len * 2];
}

var scratch_poly: [8192][2]f32 = undefined;

/// Same as `tessellateStroke`, but writes into this module's reusable scratch
/// buffer -- for callers (e.g. vector/SVG export) that just need "the
/// tessellated polygon for this one stroke" without owning their own buffer.
/// Empty if the stroke has more points than the scratch buffer can hold.
pub fn tessellateStrokeScratch(points: []const model.Point, base_width: f32) [][2]f32 {
    if (points.len * 2 > scratch_poly.len) return &[_][2]f32{};
    return tessellateStroke(points, base_width, &scratch_poly);
}

/// Builds the width-`width` quad outline of a single line segment `a` -> `b`
/// (used for shape-tool edges, which are drawn as ruler-guided strokes, not
/// filled polygons). Degenerate (zero-length) segments collapse to a
/// zero-area quad, which `raster.Canvas.fillPolygon` already no-ops on.
pub fn quadForLine(a: [2]f32, b: [2]f32, width: f32) [4][2]f32 {
    var dx = b[0] - a[0];
    var dy = b[1] - a[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.0001) return .{ a, a, a, a };
    dx /= len;
    dy /= len;
    const nx = -dy * @max(0.4, width) * 0.5;
    const ny = dx * @max(0.4, width) * 0.5;
    return .{
        .{ a[0] + nx, a[1] + ny },
        .{ b[0] + nx, b[1] + ny },
        .{ b[0] - nx, b[1] - ny },
        .{ a[0] - nx, a[1] - ny },
    };
}

test "tessellateStroke produces a closed outline with 2x point count" {
    const pts = [_]model.Point{
        .{ .x = 0, .y = 0, .p = 0.5 },
        .{ .x = 10, .y = 0, .p = 0.5 },
        .{ .x = 10, .y = 10, .p = 0.5 },
    };
    var buf: [16][2]f32 = undefined;
    const poly = tessellateStroke(&pts, 4, &buf);
    try std.testing.expectEqual(@as(usize, 6), poly.len);
}

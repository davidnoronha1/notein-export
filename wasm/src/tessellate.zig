const std = @import("std");
const model = @import("model.zig");

pub const Point = model.Point;

/// Evaluates Catmull-Rom spline at parameter t in [0, 1] with exact analytical derivative.
pub fn catmullRomWithDeriv(p0: Point, p1: Point, p2: Point, p3: Point, t: f32) struct { pos: Point, deriv: [2]f32 } {
    const t2 = t * t;
    const t3 = t2 * t;

    const x = 0.5 * (2.0 * p1.x + (-p0.x + p2.x) * t + (2.0 * p0.x - 5.0 * p1.x + 4.0 * p2.x - p3.x) * t2 + (-p0.x + 3.0 * p1.x - 3.0 * p2.x + p3.x) * t3);
    const y = 0.5 * (2.0 * p1.y + (-p0.y + p2.y) * t + (2.0 * p0.y - 5.0 * p1.y + 4.0 * p2.y - p3.y) * t2 + (-p0.y + 3.0 * p1.y - 3.0 * p2.y + p3.y) * t3);
    const p = std.math.clamp(0.5 * (2.0 * p1.p + (-p0.p + p2.p) * t + (2.0 * p0.p - 5.0 * p1.p + 4.0 * p2.p - p3.p) * t2 + (-p0.p + 3.0 * p1.p - 3.0 * p2.p + p3.p) * t3), 0.0, 1.0);

    const dx = 0.5 * ((-p0.x + p2.x) + (4.0 * p0.x - 10.0 * p1.x + 8.0 * p2.x - 2.0 * p3.x) * t + 3.0 * (-p0.x + 3.0 * p1.x - 3.0 * p2.x + p3.x) * t2);
    const dy = 0.5 * ((-p0.y + p2.y) + (4.0 * p0.y - 10.0 * p1.y + 8.0 * p2.y - 2.0 * p3.y) * t + 3.0 * (-p0.y + 3.0 * p1.y - 3.0 * p2.y + p3.y) * t2);

    return .{ .pos = .{ .x = x, .y = y, .p = p }, .deriv = .{ dx, dy } };
}

// --- Calligraphic (broad-nib) parameters ----------
const NIB_COS: f32 = 0.70710677; // cos(-45°): nib edge angle
const NIB_SIN: f32 = -0.70710677; // sin(-45°)
const NIB_MIN_RATIO: f32 = 0.6;
const CAP_SEGMENTS: usize = 4;

/// Directly generates an analytical, smooth-outline polygon from raw control points
/// with zoom-adaptive subdivision and rounded end caps. Uses exact polynomial
/// derivatives for normals, eliminating all finite-difference discretization noise.
pub fn smoothAndTessellateAdaptive(
    raw: []const Point,
    base_width: f32,
    scale: f32,
    is_calligraphic: bool,
    out: *std.array_list.Managed([2]f32),
    right_scratch: *std.array_list.Managed([2]f32),
) !void {
    out.clearRetainingCapacity();
    right_scratch.clearRetainingCapacity();

    if (raw.len == 0) return;
    if (raw.len == 1) {
        const p = raw[0];
        const radius = @max(0.4, base_width * @max(0.15, p.p)) * 0.5;
        const NUM_CIRCLE_PTS = 12;
        try out.ensureTotalCapacity(NUM_CIRCLE_PTS);
        for (0..NUM_CIRCLE_PTS) |k| {
            const angle = @as(f32, @floatFromInt(k)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(NUM_CIRCLE_PTS)));
            try out.append(.{ p.x + radius * @cos(angle), p.y + radius * @sin(angle) });
        }
        return;
    }

    const PIXELS_PER_STEP: f32 = 1.25;
    const MAX_SUBDIV: usize = 256;
    const effective_scale = @max(0.001, scale);

    const init_dx = raw[1].x - raw[0].x;
    const init_dy = raw[1].y - raw[0].y;
    const init_len = @sqrt(init_dx * init_dx + init_dy * init_dy);
    var current_t: [2]f32 = if (init_len > 0.0001) .{ init_dx / init_len, init_dy / init_len } else .{ 1.0, 0.0 };

    var first_p: [2]f32 = .{ raw[0].x, raw[0].y };
    var first_t: [2]f32 = current_t;
    var first_normal: [2]f32 = .{ -first_t[1], first_t[0] };
    var first_r: f32 = 0.0;

    var last_p: [2]f32 = .{ raw[raw.len - 1].x, raw[raw.len - 1].y };
    var last_t: [2]f32 = current_t;
    var last_normal: [2]f32 = first_normal;
    var last_r: f32 = 0.0;

    var is_first = true;

    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 1) {
        const p1 = raw[i];
        const p2 = raw[i + 1];
        const p0: Point = if (i == 0) .{
            .x = 2 * p1.x - p2.x,
            .y = 2 * p1.y - p2.y,
            .p = 2 * p1.p - p2.p,
        } else raw[i - 1];
        const p3: Point = if (i + 2 < raw.len) raw[i + 2] else .{
            .x = 2 * p2.x - p1.x,
            .y = 2 * p2.y - p1.y,
            .p = 2 * p2.p - p1.p,
        };

        const seg_dx = p2.x - p1.x;
        const seg_dy = p2.y - p1.y;
        const seg_len_world = @sqrt(seg_dx * seg_dx + seg_dy * seg_dy);
        const seg_len_px = seg_len_world * effective_scale;
        const wanted_steps = @as(usize, @intFromFloat(@ceil(seg_len_px / PIXELS_PER_STEP)));
        const steps: usize = @min(MAX_SUBDIV, @max(1, wanted_steps));

        const start_s: usize = if (is_first) 0 else 1;
        is_first = false;

        var s: usize = start_s;
        while (s <= steps) : (s += 1) {
            const t = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            const eval = catmullRomWithDeriv(p0, p1, p2, p3, t);
            const pos = eval.pos;
            const dlen = @sqrt(eval.deriv[0] * eval.deriv[0] + eval.deriv[1] * eval.deriv[1]);
            if (dlen > 0.0001) {
                current_t = .{ eval.deriv[0] / dlen, eval.deriv[1] / dlen };
            }
            const normal: [2]f32 = .{ -current_t[1], current_t[0] };

            const radius = if (is_calligraphic) blk: {
                const nib = @abs(current_t[1] * NIB_COS - current_t[0] * NIB_SIN);
                const nib_factor = NIB_MIN_RATIO + (1.0 - NIB_MIN_RATIO) * nib;
                break :blk @max(0.4, base_width * @max(0.15, pos.p) * nib_factor) * 0.5;
            } else @max(0.4, base_width * @max(0.15, pos.p)) * 0.5;

            if (out.items.len == 0) {
                first_p = .{ pos.x, pos.y };
                first_t = current_t;
                first_normal = normal;
                first_r = radius;
            }

            last_p = .{ pos.x, pos.y };
            last_t = current_t;
            last_normal = normal;
            last_r = radius;

            const left: [2]f32 = .{ pos.x + normal[0] * radius, pos.y + normal[1] * radius };
            const right: [2]f32 = .{ pos.x - normal[0] * radius, pos.y - normal[1] * radius };

            try out.append(left);
            try right_scratch.append(right);
        }
    }

    if (out.items.len == 0) return;

    // Build start cap:
    var start_cap: [CAP_SEGMENTS][2]f32 = undefined;
    inline for (0..CAP_SEGMENTS) |k| {
        const alpha = -std.math.pi * 0.5 + @as(f32, @floatFromInt(k)) * (std.math.pi / @as(f32, @floatFromInt(CAP_SEGMENTS)));
        const sin_a = @sin(alpha);
        const cos_a = @cos(alpha);
        const v_x = -first_t[0] * cos_a * first_r + first_normal[0] * sin_a * first_r;
        const v_y = -first_t[1] * cos_a * first_r + first_normal[1] * sin_a * first_r;
        start_cap[k] = .{ first_p[0] + v_x, first_p[1] + v_y };
    }

    // Build end cap:
    inline for (1..CAP_SEGMENTS) |k| {
        const beta = std.math.pi * 0.5 - @as(f32, @floatFromInt(k)) * (std.math.pi / @as(f32, @floatFromInt(CAP_SEGMENTS)));
        const sin_b = @sin(beta);
        const cos_b = @cos(beta);
        const w_x = last_t[0] * cos_b * last_r + last_normal[0] * sin_b * last_r;
        const w_y = last_t[1] * cos_b * last_r + last_normal[1] * sin_b * last_r;
        try out.append(.{ last_p[0] + w_x, last_p[1] + w_y });
    }

    // Append right items in reverse (skip index 0 to avoid duplicating right_0)
    var ri = right_scratch.items.len;
    while (ri > 1) {
        ri -= 1;
        try out.append(right_scratch.items[ri]);
    }

    // Prepend start_cap (0..CAP_SEGMENTS)
    try out.insertSlice(0, &start_cap);
}

pub fn tessellateStroke(points: []const model.Point, base_width: f32, out: [][2]f32) [][2]f32 {
    if (points.len == 0) return out[0..0];
    if (points.len == 1) {
        const p = points[0];
        const radius = @max(0.4, base_width * @max(0.15, p.p)) * 0.5;
        const NUM_CIRCLE_PTS = 12;
        if (out.len < NUM_CIRCLE_PTS) return out[0..0];
        for (0..NUM_CIRCLE_PTS) |k| {
            const angle = @as(f32, @floatFromInt(k)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(NUM_CIRCLE_PTS)));
            out[k] = .{ p.x + radius * @cos(angle), p.y + radius * @sin(angle) };
        }
        return out[0..NUM_CIRCLE_PTS];
    }

    const total_needed = points.len * 2 + CAP_SEGMENTS * 2;
    if (out.len < total_needed) return out[0..0];

    const Vec2 = @Vector(2, f32);
    var n: usize = 0;

    // First point direction and normal:
    const first_diff: Vec2 = .{ points[1].x - points[0].x, points[1].y - points[0].y };
    const first_len = @sqrt(@reduce(.Add, first_diff * first_diff));
    const first_t: Vec2 = if (first_len > 0.0001) first_diff / @as(Vec2, @splat(first_len)) else .{ 1.0, 0.0 };
    const first_normal: Vec2 = .{ -first_t[1], first_t[0] };
    const r0 = @max(0.4, base_width * @max(0.15, points[0].p)) * 0.5;
    const p0_vec: Vec2 = .{ points[0].x, points[0].y };

    // 1. Start round cap: arc from right_0 around -T_0 to left_0
    inline for (0..CAP_SEGMENTS) |k| {
        const alpha = -std.math.pi * 0.5 + @as(f32, @floatFromInt(k)) * (std.math.pi / @as(f32, @floatFromInt(CAP_SEGMENTS)));
        const sin_a = @sin(alpha);
        const cos_a = @cos(alpha);
        const v = -first_t * @as(Vec2, @splat(cos_a * r0)) + first_normal * @as(Vec2, @splat(sin_a * r0));
        const pt = p0_vec + v;
        out[n] = .{ pt[0], pt[1] };
        n += 1;
    }

    // 2. Left side: i from 0 to points.len - 1
    var last_t = first_t;
    var last_normal = first_normal;
    var last_r = r0;
    for (points, 0..) |p, i| {
        const prev = points[if (i == 0) 0 else i - 1];
        const next = points[if (i + 1 < points.len) i + 1 else i];
        const diff: Vec2 = .{ next.x - prev.x, next.y - prev.y };
        const len = @sqrt(@reduce(.Add, diff * diff));
        if (len > 0.0001) {
            last_t = diff / @as(Vec2, @splat(len));
            last_normal = .{ -last_t[1], last_t[0] };
        }
        last_r = @max(0.4, base_width * @max(0.15, p.p)) * 0.5;
        const p_vec: Vec2 = .{ p.x, p.y };
        const left = p_vec + last_normal * @as(Vec2, @splat(last_r));
        out[n] = .{ left[0], left[1] };
        n += 1;
    }

    // 3. End round cap: arc from left_{N-1} around +T_{N-1} to right_{N-1}
    const p_end_vec: Vec2 = .{ points[points.len - 1].x, points[points.len - 1].y };
    inline for (1..CAP_SEGMENTS) |k| {
        const beta = std.math.pi * 0.5 - @as(f32, @floatFromInt(k)) * (std.math.pi / @as(f32, @floatFromInt(CAP_SEGMENTS)));
        const sin_b = @sin(beta);
        const cos_b = @cos(beta);
        const w = last_t * @as(Vec2, @splat(cos_b * last_r)) + last_normal * @as(Vec2, @splat(sin_b * last_r));
        const pt = p_end_vec + w;
        out[n] = .{ pt[0], pt[1] };
        n += 1;
    }

    // 4. Right side: i from points.len - 1 down to 0
    var ri = points.len;
    while (ri > 0) {
        ri -= 1;
        const p = points[ri];
        const prev = points[if (ri == 0) 0 else ri - 1];
        const next = points[if (ri + 1 < points.len) ri + 1 else ri];
        const diff: Vec2 = .{ next.x - prev.x, next.y - prev.y };
        const len = @sqrt(@reduce(.Add, diff * diff));
        var normal = last_normal;
        if (len > 0.0001) {
            const t = diff / @as(Vec2, @splat(len));
            normal = .{ -t[1], t[0] };
        }
        const r = @max(0.4, base_width * @max(0.15, p.p)) * 0.5;
        const p_vec: Vec2 = .{ p.x, p.y };
        const right = p_vec - normal * @as(Vec2, @splat(r));
        out[n] = .{ right[0], right[1] };
        n += 1;
    }

    return out[0..n];
}

// --- Calligraphic (broad-nib) variant, used only by the Nebo path ----------
// Nebo ink is a FountainPen: its width varies with pressure and stroke
// direction relative to a fixed nib edge, giving thick downstrokes and thin
// cross-strokes, with rounded nib caps at stroke ends for smooth joins.

/// Like `tessellateStroke`, but the local radius is modulated by a broad-nib
/// direction factor with rounded caps.
pub fn tessellateStrokeCalligraphic(points: []const model.Point, base_width: f32, out: [][2]f32) [][2]f32 {
    if (points.len == 0) return out[0..0];
    if (points.len == 1) {
        const p = points[0];
        const radius = @max(0.4, base_width * @max(0.15, p.p)) * 0.5;
        const NUM_CIRCLE_PTS = 12;
        if (out.len < NUM_CIRCLE_PTS) return out[0..0];
        for (0..NUM_CIRCLE_PTS) |k| {
            const angle = @as(f32, @floatFromInt(k)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(NUM_CIRCLE_PTS)));
            out[k] = .{ p.x + radius * @cos(angle), p.y + radius * @sin(angle) };
        }
        return out[0..NUM_CIRCLE_PTS];
    }

    const total_needed = points.len * 2 + CAP_SEGMENTS * 2;
    if (out.len < total_needed) return out[0..0];

    const Vec2 = @Vector(2, f32);
    var n: usize = 0;

    // First point direction, nib factor, and normal:
    const first_diff: Vec2 = .{ points[1].x - points[0].x, points[1].y - points[0].y };
    const first_len = @sqrt(@reduce(.Add, first_diff * first_diff));
    const first_t: Vec2 = if (first_len > 0.0001) first_diff / @as(Vec2, @splat(first_len)) else .{ 1.0, 0.0 };
    const first_normal: Vec2 = .{ -first_t[1], first_t[0] };
    const first_nib = @abs(first_t[1] * NIB_COS - first_t[0] * NIB_SIN);
    const first_nib_factor = NIB_MIN_RATIO + (1.0 - NIB_MIN_RATIO) * first_nib;
    const r0 = @max(0.4, base_width * @max(0.15, points[0].p) * first_nib_factor) * 0.5;
    const p0_vec: Vec2 = .{ points[0].x, points[0].y };

    // 1. Start round cap: arc from right_0 around -T_0 to left_0
    inline for (0..CAP_SEGMENTS) |k| {
        const alpha = -std.math.pi * 0.5 + @as(f32, @floatFromInt(k)) * (std.math.pi / @as(f32, @floatFromInt(CAP_SEGMENTS)));
        const sin_a = @sin(alpha);
        const cos_a = @cos(alpha);
        const v = -first_t * @as(Vec2, @splat(cos_a * r0)) + first_normal * @as(Vec2, @splat(sin_a * r0));
        const pt = p0_vec + v;
        out[n] = .{ pt[0], pt[1] };
        n += 1;
    }

    // 2. Left side: i from 0 to points.len - 1
    var last_t = first_t;
    var last_normal = first_normal;
    var last_r = r0;
    for (points, 0..) |p, i| {
        const prev = points[if (i == 0) 0 else i - 1];
        const next = points[if (i + 1 < points.len) i + 1 else i];
        const diff: Vec2 = .{ next.x - prev.x, next.y - prev.y };
        const len = @sqrt(@reduce(.Add, diff * diff));
        if (len > 0.0001) {
            last_t = diff / @as(Vec2, @splat(len));
            last_normal = .{ -last_t[1], last_t[0] };
        }
        const nib = @abs(last_t[1] * NIB_COS - last_t[0] * NIB_SIN);
        const nib_factor = NIB_MIN_RATIO + (1.0 - NIB_MIN_RATIO) * nib;
        last_r = @max(0.4, base_width * @max(0.15, p.p) * nib_factor) * 0.5;
        const p_vec: Vec2 = .{ p.x, p.y };
        const left = p_vec + last_normal * @as(Vec2, @splat(last_r));
        out[n] = .{ left[0], left[1] };
        n += 1;
    }

    // 3. End round cap: arc from left_{N-1} around +T_{N-1} to right_{N-1}
    const p_end_vec: Vec2 = .{ points[points.len - 1].x, points[points.len - 1].y };
    inline for (1..CAP_SEGMENTS) |k| {
        const beta = std.math.pi * 0.5 - @as(f32, @floatFromInt(k)) * (std.math.pi / @as(f32, @floatFromInt(CAP_SEGMENTS)));
        const sin_b = @sin(beta);
        const cos_b = @cos(beta);
        const w = last_t * @as(Vec2, @splat(cos_b * last_r)) + last_normal * @as(Vec2, @splat(sin_b * last_r));
        const pt = p_end_vec + w;
        out[n] = .{ pt[0], pt[1] };
        n += 1;
    }

    // 4. Right side: i from points.len - 1 down to 0
    var ri = points.len;
    while (ri > 0) {
        ri -= 1;
        const p = points[ri];
        const prev = points[if (ri == 0) 0 else ri - 1];
        const next = points[if (ri + 1 < points.len) ri + 1 else ri];
        const diff: Vec2 = .{ next.x - prev.x, next.y - prev.y };
        const len = @sqrt(@reduce(.Add, diff * diff));
        var normal = last_normal;
        var t = last_t;
        if (len > 0.0001) {
            t = diff / @as(Vec2, @splat(len));
            normal = .{ -t[1], t[0] };
        }
        const nib = @abs(t[1] * NIB_COS - t[0] * NIB_SIN);
        const nib_factor = NIB_MIN_RATIO + (1.0 - NIB_MIN_RATIO) * nib;
        const r = @max(0.4, base_width * @max(0.15, p.p) * nib_factor) * 0.5;
        const p_vec: Vec2 = .{ p.x, p.y };
        const right = p_vec - normal * @as(Vec2, @splat(r));
        out[n] = .{ right[0], right[1] };
        n += 1;
    }

    return out[0..n];
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
    const Vec2 = @Vector(2, f32);
    const av: Vec2 = .{ a[0], a[1] };
    const bv: Vec2 = .{ b[0], b[1] };
    var diff: Vec2 = bv - av;
    const len = @sqrt(@reduce(.Add, diff * diff));
    if (len < 0.0001) return .{ a, a, a, a };
    diff /= @as(Vec2, @splat(len));
    const radius = @max(0.4, width) * 0.5;
    const offset: Vec2 = .{ -diff[1] * radius, diff[0] * radius };
    const a_left: Vec2 = av + offset;
    const b_left: Vec2 = bv + offset;
    const b_right: Vec2 = bv - offset;
    const a_right: Vec2 = av - offset;
    return .{
        .{ a_left[0], a_left[1] },
        .{ b_left[0], b_left[1] },
        .{ b_right[0], b_right[1] },
        .{ a_right[0], a_right[1] },
    };
}

test "tessellateStroke produces a closed outline with round caps" {
    const pts = [_]model.Point{
        .{ .x = 0, .y = 0, .p = 0.5 },
        .{ .x = 10, .y = 0, .p = 0.5 },
        .{ .x = 10, .y = 10, .p = 0.5 },
    };
    var buf: [32][2]f32 = undefined;
    const poly = tessellateStroke(&pts, 4, &buf);
    try std.testing.expect(poly.len >= 6);
}

test "smoothAndTessellateAdaptive generates smooth closed outline" {
    const pts = [_]model.Point{
        .{ .x = 0, .y = 0, .p = 0.5 },
        .{ .x = 100, .y = 0, .p = 0.5 },
        .{ .x = 100, .y = 100, .p = 0.5 },
    };
    var poly = std.array_list.Managed([2]f32).init(std.testing.allocator);
    defer poly.deinit();
    var right = std.array_list.Managed([2]f32).init(std.testing.allocator);
    defer right.deinit();

    try smoothAndTessellateAdaptive(&pts, 4.0, 1.0, true, &poly, &right);
    try std.testing.expect(poly.items.len >= 20);
}


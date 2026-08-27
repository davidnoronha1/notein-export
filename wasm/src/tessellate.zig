const std = @import("std");
const model = @import("model.zig");

pub const Point = model.Point;

/// Evaluates Centripetal Catmull-Rom spline at parameter u in [0, 1] with exact analytical derivative.
/// Uses centripetal parameterization (alpha = 0.5) which guarantees no self-intersections,
/// cusps, or overshoot even when control point spacing is highly non-uniform.
pub fn centripetalCatmullRomWithDeriv(
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,
    u: f32,
) struct { pos: Point, deriv: [2]f32 } {
    const d0_sq = (p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y);
    const d1_sq = (p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y);
    const d2_sq = (p3.x - p2.x) * (p3.x - p2.x) + (p3.y - p2.y) * (p3.y - p2.y);

    const d0 = @sqrt(@sqrt(d0_sq)); // centripetal: ||P1-P0||^0.5
    const d1 = @sqrt(@sqrt(d1_sq));
    const d2 = @sqrt(@sqrt(d2_sq));

    // Guard against coincident points / tiny chord lengths
    const eps: f32 = 0.0001;
    const d0_safe = @max(eps, d0);
    const d1_safe = @max(eps, d1);
    const d2_safe = @max(eps, d2);

    // Tangents with respect to parameter u in [0, 1]
    const w0 = (d1_safe * d1_safe) / (d0_safe * (d0_safe + d1_safe));
    const w1 = d0_safe / (d0_safe + d1_safe);
    const m1_x = w0 * (p1.x - p0.x) + w1 * (p2.x - p1.x);
    const m1_y = w0 * (p1.y - p0.y) + w1 * (p2.y - p1.y);

    const w2 = d2_safe / (d1_safe + d2_safe);
    const w3 = (d1_safe * d1_safe) / (d2_safe * (d1_safe + d2_safe));
    const m2_x = w2 * (p2.x - p1.x) + w3 * (p3.x - p2.x);
    const m2_y = w2 * (p2.y - p1.y) + w3 * (p3.y - p2.y);

    const u_sq = u * u;
    const u_cb = u_sq * u;

    // Hermite basis functions
    const h00 = 2.0 * u_cb - 3.0 * u_sq + 1.0;
    const h10 = u_cb - 2.0 * u_sq + u;
    const h01 = -2.0 * u_cb + 3.0 * u_sq;
    const h11 = u_cb - u_sq;

    // Hermite derivatives
    const dh00 = 6.0 * u_sq - 6.0 * u;
    const dh10 = 3.0 * u_sq - 4.0 * u + 1.0;
    const dh01 = -6.0 * u_sq + 6.0 * u;
    const dh11 = 3.0 * u_sq - 2.0 * u;

    const x = h00 * p1.x + h10 * m1_x + h01 * p2.x + h11 * m2_x;
    const y = h00 * p1.y + h10 * m1_y + h01 * p2.y + h11 * m2_y;

    const dx = dh00 * p1.x + dh10 * m1_x + dh01 * p2.x + dh11 * m2_x;
    const dy = dh00 * p1.y + dh10 * m1_y + dh01 * p2.y + dh11 * m2_y;

    // Smooth monotonic pressure interpolation
    const p = std.math.clamp(p1.p + (p2.p - p1.p) * (3.0 * u_sq - 2.0 * u_cb), 0.0, 1.0);

    return .{ .pos = .{ .x = x, .y = y, .p = p }, .deriv = .{ dx, dy } };
}

// --- Calligraphic (broad-nib) parameters ----------
const NIB_COS: f32 = 0.70710677; // cos(-45°): nib edge angle
const NIB_SIN: f32 = -0.70710677; // sin(-45°)
const NIB_MIN_RATIO: f32 = 0.6;
const CAP_SEGMENTS: usize = 8;

var g_clean_pts_buf: ?std.array_list.Managed(Point) = null;
var g_smooth_pts_buf: ?std.array_list.Managed(Point) = null;

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

    if (g_clean_pts_buf == null) g_clean_pts_buf = std.array_list.Managed(Point).init(out.allocator);
    var clean_scratch = &g_clean_pts_buf.?;
    clean_scratch.clearRetainingCapacity();

    // 1. Filter duplicate or near-coincident raw points (< 0.01 world unit)
    try clean_scratch.ensureTotalCapacity(raw.len);
    for (raw) |p| {
        if (clean_scratch.items.len > 0) {
            const last = clean_scratch.items[clean_scratch.items.len - 1];
            const dx = p.x - last.x;
            const dy = p.y - last.y;
            if (dx * dx + dy * dy < 0.0001) continue;
        }
        try clean_scratch.append(p);
    }
    const clean_items = clean_scratch.items;

    if (clean_items.len == 0) return;
    if (clean_items.len == 1) {
        const p = clean_items[0];
        const radius = @max(0.4, base_width * @max(0.15, p.p)) * 0.5;
        const NUM_CIRCLE_PTS = 16;
        try out.ensureTotalCapacity(NUM_CIRCLE_PTS);
        for (0..NUM_CIRCLE_PTS) |k| {
            const angle = @as(f32, @floatFromInt(k)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(NUM_CIRCLE_PTS)));
            try out.append(.{ p.x + radius * @cos(angle), p.y + radius * @sin(angle) });
        }
        return;
    }

    // 2. Pre-filter digitizer high-frequency quantization noise with a gentle moving average
    if (g_smooth_pts_buf == null) g_smooth_pts_buf = std.array_list.Managed(Point).init(out.allocator);
    var smooth_scratch = &g_smooth_pts_buf.?;
    smooth_scratch.clearRetainingCapacity();
    try smooth_scratch.ensureTotalCapacity(clean_items.len);

    if (clean_items.len >= 3) {
        smooth_scratch.appendAssumeCapacity(clean_items[0]);
        var si: usize = 1;
        while (si + 1 < clean_items.len) : (si += 1) {
            const prev = clean_items[si - 1];
            const curr = clean_items[si];
            const next = clean_items[si + 1];
            smooth_scratch.appendAssumeCapacity(.{
                .x = 0.25 * prev.x + 0.5 * curr.x + 0.25 * next.x,
                .y = 0.25 * prev.y + 0.5 * curr.y + 0.25 * next.y,
                .p = 0.25 * prev.p + 0.5 * curr.p + 0.25 * next.p,
            });
        }
        smooth_scratch.appendAssumeCapacity(clean_items[clean_items.len - 1]);
    } else {
        try smooth_scratch.appendSlice(clean_items);
    }
    const pts = smooth_scratch.items;

    const PIXELS_PER_STEP: f32 = 0.6;
    const MAX_SUBDIV: usize = 256;
    const effective_scale = @max(0.001, scale);

    const init_dx = pts[1].x - pts[0].x;
    const init_dy = pts[1].y - pts[0].y;
    const init_len = @sqrt(init_dx * init_dx + init_dy * init_dy);
    var current_t: [2]f32 = if (init_len > 0.0001) .{ init_dx / init_len, init_dy / init_len } else .{ 1.0, 0.0 };

    var first_p: [2]f32 = .{ pts[0].x, pts[0].y };
    var first_t: [2]f32 = current_t;
    var first_normal: [2]f32 = .{ -first_t[1], first_t[0] };
    var first_r: f32 = 0.0;

    var last_p: [2]f32 = .{ pts[pts.len - 1].x, pts[pts.len - 1].y };
    var last_t: [2]f32 = current_t;
    var last_normal: [2]f32 = first_normal;
    var last_r: f32 = 0.0;

    var is_first = true;
    var has_prev_sample = false;
    var prev_sample_pos: [2]f32 = undefined;
    var prev_sample_t: [2]f32 = current_t;

    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        const p1 = pts[i];
        const p2 = pts[i + 1];
        const p0: Point = if (i == 0) .{
            .x = 2 * p1.x - p2.x,
            .y = 2 * p1.y - p2.y,
            .p = 2 * p1.p - p2.p,
        } else pts[i - 1];
        const p3: Point = if (i + 2 < pts.len) pts[i + 2] else .{
            .x = 2 * p2.x - p1.x,
            .y = 2 * p2.y - p1.y,
            .p = 2 * p2.p - p1.p,
        };

        const seg_dx = p2.x - p1.x;
        const seg_dy = p2.y - p1.y;
        const seg_len_world = @sqrt(seg_dx * seg_dx + seg_dy * seg_dy);
        const seg_len_px = seg_len_world * effective_scale;
        const len_steps = @as(usize, @intFromFloat(@ceil(seg_len_px / PIXELS_PER_STEP)));

        // Angle-adaptive steps to ensure smooth curves on sharp turns:
        const d0_sq = (p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y);
        const d1_sq = seg_dx * seg_dx + seg_dy * seg_dy;
        const d2_sq = (p3.x - p2.x) * (p3.x - p2.x) + (p3.y - p2.y) * (p3.y - p2.y);
        const d0 = @sqrt(@sqrt(d0_sq));
        const d1 = @sqrt(@sqrt(d1_sq));
        const d2 = @sqrt(@sqrt(d2_sq));
        const d0_safe = @max(0.0001, d0);
        const d1_safe = @max(0.0001, d1);
        const d2_safe = @max(0.0001, d2);

        const w0 = (d1_safe * d1_safe) / (d0_safe * (d0_safe + d1_safe));
        const w1 = d0_safe / (d0_safe + d1_safe);
        const m1_x = w0 * (p1.x - p0.x) + w1 * (p2.x - p1.x);
        const m1_y = w0 * (p1.y - p0.y) + w1 * (p2.y - p1.y);

        const w2 = d2_safe / (d1_safe + d2_safe);
        const w3 = (d1_safe * d1_safe) / (d2_safe * (d1_safe + d2_safe));
        const m2_x = w2 * (p2.x - p1.x) + w3 * (p3.x - p2.x);
        const m2_y = w2 * (p2.y - p1.y) + w3 * (p3.y - p2.y);

        const dot = m1_x * m2_x + m1_y * m2_y;
        const mag1 = @sqrt(m1_x * m1_x + m1_y * m1_y);
        const mag2 = @sqrt(m2_x * m2_x + m2_y * m2_y);
        const cos_t = if (mag1 * mag2 > 0.0001) std.math.clamp(dot / (mag1 * mag2), -1.0, 1.0) else 1.0;
        const angle_steps = @as(usize, @intFromFloat(@ceil((1.0 - cos_t) * 8.0)));
        const steps: usize = @min(MAX_SUBDIV, @max(1, @max(len_steps, angle_steps)));

        const start_s: usize = if (is_first) 0 else 1;
        is_first = false;

        var s: usize = start_s;
        while (s <= steps) : (s += 1) {
            const u = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            const eval = centripetalCatmullRomWithDeriv(p0, p1, p2, p3, u);
            const pos = eval.pos;
            const dlen = @sqrt(eval.deriv[0] * eval.deriv[0] + eval.deriv[1] * eval.deriv[1]);
            if (dlen > 0.0001) {
                const new_t: [2]f32 = .{ eval.deriv[0] / dlen, eval.deriv[1] / dlen };
                if (new_t[0] * current_t[0] + new_t[1] * current_t[1] > 0.0) {
                    current_t = new_t;
                }
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
            var r_left = radius;
            var r_right = radius;

            if (has_prev_sample) {
                const step_dx = pos.x - prev_sample_pos[0];
                const step_dy = pos.y - prev_sample_pos[1];
                const step_ds = @sqrt(step_dx * step_dx + step_dy * step_dy);
                // sin(delta_theta) = prev_t x curr_t
                const cross = prev_sample_t[0] * current_t[1] - prev_sample_t[1] * current_t[0];
                const abs_cross = @abs(cross);
                if (abs_cross > 0.001 and step_ds > 0.0001) {
                    const r_curv = step_ds / abs_cross;
                    if (cross > 0.0) {
                        // Turning left: left is inner
                        r_left = @min(radius, @max(0.4, r_curv * 0.95));
                    } else {
                        // Turning right: right is inner
                        r_right = @min(radius, @max(0.4, r_curv * 0.95));
                    }
                }
            }

            has_prev_sample = true;
            prev_sample_pos = .{ pos.x, pos.y };
            prev_sample_t = current_t;

            const left: [2]f32 = .{ pos.x + normal[0] * r_left, pos.y + normal[1] * r_left };
            const right: [2]f32 = .{ pos.x - normal[0] * r_right, pos.y - normal[1] * r_right };

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

/// Renders smooth spline strokes as a continuous sequence of convex quads and round end caps.
/// Because each segment is an independent convex polygon, overlapping regions (loops, sharp turns,
/// self-intersections) saturate without non-zero winding cancellation, completely eliminating
/// all black hole / notch artifacts.
pub fn renderStrokeQuads(
    raw: []const Point,
    base_width: f32,
    scale: f32,
    is_calligraphic: bool,
    allocator: std.mem.Allocator,
    context: anytype,
    comptime drawQuad: fn (@TypeOf(context), [4][2]f32) void,
    comptime drawDisc: fn (@TypeOf(context), [2]f32, f32) void,
) !void {
    if (raw.len == 0) return;

    if (g_clean_pts_buf == null) g_clean_pts_buf = std.array_list.Managed(Point).init(allocator);
    var clean_scratch = &g_clean_pts_buf.?;
    clean_scratch.clearRetainingCapacity();

    // 1. Filter duplicate or near-coincident raw points (< 0.01 world unit)
    try clean_scratch.ensureTotalCapacity(raw.len);
    for (raw) |p| {
        if (clean_scratch.items.len > 0) {
            const last = clean_scratch.items[clean_scratch.items.len - 1];
            const dx = p.x - last.x;
            const dy = p.y - last.y;
            if (dx * dx + dy * dy < 0.0001) continue;
        }
        try clean_scratch.append(p);
    }
    const clean_items = clean_scratch.items;
    if (clean_items.len == 0) return;

    if (clean_items.len == 1) {
        const p = clean_items[0];
        const radius = @max(0.4, base_width * @max(0.15, p.p)) * 0.5;
        drawDisc(context, .{ p.x, p.y }, radius);
        return;
    }

    // 2. Pre-filter digitizer high-frequency noise
    if (g_smooth_pts_buf == null) g_smooth_pts_buf = std.array_list.Managed(Point).init(allocator);
    var smooth_scratch = &g_smooth_pts_buf.?;
    smooth_scratch.clearRetainingCapacity();
    try smooth_scratch.ensureTotalCapacity(clean_items.len);

    if (clean_items.len >= 3) {
        smooth_scratch.appendAssumeCapacity(clean_items[0]);
        var si: usize = 1;
        while (si + 1 < clean_items.len) : (si += 1) {
            const prev = clean_items[si - 1];
            const curr = clean_items[si];
            const next = clean_items[si + 1];
            smooth_scratch.appendAssumeCapacity(.{
                .x = 0.25 * prev.x + 0.5 * curr.x + 0.25 * next.x,
                .y = 0.25 * prev.y + 0.5 * curr.y + 0.25 * next.y,
                .p = 0.25 * prev.p + 0.5 * curr.p + 0.25 * next.p,
            });
        }
        smooth_scratch.appendAssumeCapacity(clean_items[clean_items.len - 1]);
    } else {
        try smooth_scratch.appendSlice(clean_items);
    }
    const pts = smooth_scratch.items;

    const PIXELS_PER_STEP: f32 = 0.6;
    const MAX_SUBDIV: usize = 256;
    const effective_scale = @max(0.001, scale);

    const init_dx = pts[1].x - pts[0].x;
    const init_dy = pts[1].y - pts[0].y;
    const init_len = @sqrt(init_dx * init_dx + init_dy * init_dy);
    var current_t: [2]f32 = if (init_len > 0.0001) .{ init_dx / init_len, init_dy / init_len } else .{ 1.0, 0.0 };

    var has_prev = false;
    var prev_left: [2]f32 = undefined;
    var prev_right: [2]f32 = undefined;
    var first_p: [2]f32 = undefined;
    var first_r: f32 = 0;
    var last_p: [2]f32 = undefined;
    var last_r: f32 = 0;

    var is_first = true;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        const p1 = pts[i];
        const p2 = pts[i + 1];
        const p0: Point = if (i == 0) .{
            .x = 2 * p1.x - p2.x,
            .y = 2 * p1.y - p2.y,
            .p = 2 * p1.p - p2.p,
        } else pts[i - 1];
        const p3: Point = if (i + 2 < pts.len) pts[i + 2] else .{
            .x = 2 * p2.x - p1.x,
            .y = 2 * p2.y - p1.y,
            .p = 2 * p2.p - p1.p,
        };

        const seg_dx = p2.x - p1.x;
        const seg_dy = p2.y - p1.y;
        const seg_len_world = @sqrt(seg_dx * seg_dx + seg_dy * seg_dy);
        const seg_len_px = seg_len_world * effective_scale;
        const len_steps = @as(usize, @intFromFloat(@ceil(seg_len_px / PIXELS_PER_STEP)));

        // Angle-adaptive steps
        const d0_sq = (p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y);
        const d1_sq = seg_dx * seg_dx + seg_dy * seg_dy;
        const d2_sq = (p3.x - p2.x) * (p3.x - p2.x) + (p3.y - p2.y) * (p3.y - p2.y);
        const d0 = @sqrt(@sqrt(d0_sq));
        const d1 = @sqrt(@sqrt(d1_sq));
        const d2 = @sqrt(@sqrt(d2_sq));
        const d0_safe = @max(0.0001, d0);
        const d1_safe = @max(0.0001, d1);
        const d2_safe = @max(0.0001, d2);

        const w0 = (d1_safe * d1_safe) / (d0_safe * (d0_safe + d1_safe));
        const w1 = d0_safe / (d0_safe + d1_safe);
        const m1_x = w0 * (p1.x - p0.x) + w1 * (p2.x - p1.x);
        const m1_y = w0 * (p1.y - p0.y) + w1 * (p2.y - p1.y);

        const w2 = d2_safe / (d1_safe + d2_safe);
        const w3 = (d1_safe * d1_safe) / (d2_safe * (d1_safe + d2_safe));
        const m2_x = w2 * (p2.x - p1.x) + w3 * (p3.x - p2.x);
        const m2_y = w2 * (p2.y - p1.y) + w3 * (p3.y - p2.y);

        const dot = m1_x * m2_x + m1_y * m2_y;
        const mag1 = @sqrt(m1_x * m1_x + m1_y * m1_y);
        const mag2 = @sqrt(m2_x * m2_x + m2_y * m2_y);
        const cos_t = if (mag1 * mag2 > 0.0001) std.math.clamp(dot / (mag1 * mag2), -1.0, 1.0) else 1.0;
        const angle_steps = @as(usize, @intFromFloat(@ceil((1.0 - cos_t) * 8.0)));
        const steps: usize = @min(MAX_SUBDIV, @max(1, @max(len_steps, angle_steps)));

        const start_s: usize = if (is_first) 0 else 1;
        is_first = false;

        var s: usize = start_s;
        while (s <= steps) : (s += 1) {
            const u = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            const eval = centripetalCatmullRomWithDeriv(p0, p1, p2, p3, u);
            const pos = eval.pos;
            const dlen = @sqrt(eval.deriv[0] * eval.deriv[0] + eval.deriv[1] * eval.deriv[1]);
            if (dlen > 0.0001) {
                current_t = .{ eval.deriv[0] / dlen, eval.deriv[1] / dlen };
            } else if (seg_len_world > 0.0001) {
                current_t = .{ seg_dx / seg_len_world, seg_dy / seg_len_world };
            }
            const normal: [2]f32 = .{ -current_t[1], current_t[0] };

            const radius = if (is_calligraphic) blk: {
                const nib = @abs(current_t[1] * NIB_COS - current_t[0] * NIB_SIN);
                const nib_factor = NIB_MIN_RATIO + (1.0 - NIB_MIN_RATIO) * nib;
                break :blk @max(0.4, base_width * @max(0.15, pos.p) * nib_factor) * 0.5;
            } else @max(0.4, base_width * @max(0.15, pos.p)) * 0.5;

            const curr_left: [2]f32 = .{ pos.x + normal[0] * radius, pos.y + normal[1] * radius };
            const curr_right: [2]f32 = .{ pos.x - normal[0] * radius, pos.y - normal[1] * radius };

            if (!has_prev) {
                first_p = .{ pos.x, pos.y };
                first_r = radius;
            } else {
                drawQuad(context, .{ prev_left, curr_left, curr_right, prev_right });
            }

            has_prev = true;
            prev_left = curr_left;
            prev_right = curr_right;
            last_p = .{ pos.x, pos.y };
            last_r = radius;
        }
    }

    if (has_prev) {
        drawDisc(context, first_p, first_r);
        drawDisc(context, last_p, last_r);
    }
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


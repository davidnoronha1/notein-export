const std = @import("std");
const model = @import("model.zig");
const window = @import("window.zig");
const raster = @import("raster.zig");
const zip = @import("zip.zig");
const big_alloc = @import("big_alloc.zig");

var g_panic_buf: [512]u8 = undefined;
var g_panic_len: u32 = 0;

fn panicFn(msg: []const u8, _: ?usize) noreturn {
    const n = @min(msg.len, g_panic_buf.len);
    @memcpy(g_panic_buf[0..n], msg[0..n]);
    g_panic_len = n;
    @trap();
}
pub const panic = std.debug.FullPanic(panicFn);

export fn get_panic_msg_ptr() u32 {
    return @intFromPtr(&g_panic_buf);
}
export fn get_panic_msg_len() u32 {
    return g_panic_len;
}

const gpa = std.heap.wasm_allocator;

const State = struct {
    arena: std.heap.ArenaAllocator,
    note: model.Note,
    win: window.Window,
};
var g_state: ?State = null;

// Reusable output buffers, freed/reallocated as needed across calls.
var g_canvas_buf: []u8 = &.{};
var g_page_info_buf: []PageInfo = &.{};
var g_image_draw_buf: []ImageDraw = &.{};
var g_textbox_draw_buf: []TextBoxDraw = &.{};
var g_bytes_buf: []u8 = &.{};
var g_vector_poly_buf: []VectorPoly = &.{};
var g_vector_vertex_buf: []f32 = &.{}; // flat x0,y0,x1,y1,... pairs, indexed by VectorPoly.vertex_offset
var g_asset_image_buf: []AssetImageDraw = &.{};
var g_link_draw_buf: []LinkDraw = &.{};
var g_audio_draw_buf: []AudioDraw = &.{};

const PageInfo = extern struct { width: f32, height: f32, unbounded: u32, color: u32 };
// creation_time is epoch milliseconds (fits exactly in f64's 53-bit mantissa,
// unlike f32 which can't represent it precisely) -- used by JS to interleave
// image/text compositing with ink rendering in true chronological/stacking order.
const ImageDraw = extern struct { left: f32, top: f32, right: f32, bottom: f32, name_ptr: u32, name_len: u32, creation_time: f64 };
const TextBoxDraw = extern struct { left: f32, top: f32, right: f32, bottom: f32, size: f32, color: u32, text_ptr: u32, text_len: u32, creation_time: f64 };
// f64 first so the natural C layout doesn't need to insert padding before it
// (matters since JS reads this by fixed byte stride -- see POLY_STRIDE in loader.ts).
const VectorPoly = extern struct { creation_time: f64, color: u32, vertex_offset: u32, vertex_count: u32 };
// stride 40: f64 creation_time, 4x f32 bounds, u32 page_index, u32 name_ptr, u32 name_len
const AssetImageDraw = extern struct { creation_time: f64, left: f32, top: f32, right: f32, bottom: f32, page_index: u32, name_ptr: u32, name_len: u32 };
// stride 40: f64 creation_time, 4x f32 bounds, u32 page_index, i32 link_type, u32 dest_ptr, u32 dest_len
const LinkDraw = extern struct { creation_time: f64, left: f32, top: f32, right: f32, bottom: f32, page_index: u32, link_type: i32, dest_ptr: u32, dest_len: u32 };
// stride 32: f64 creation_time, f64 duration_ms, u32 name_ptr, u32 name_len, u32 entry_ptr, u32 entry_len
const AudioDraw = extern struct { creation_time: f64, duration_ms: f64, name_ptr: u32, name_len: u32, entry_ptr: u32, entry_len: u32 };

/// Allocates `len` bytes in wasm linear memory for the caller (JS) to write
/// into before calling `set_active_window` or `get_bytes` (small, transient
/// buffers -- uses the general-purpose allocator).
export fn alloc(len: u32) u32 {
    const mem = gpa.alloc(u8, len) catch return 0;
    return @intFromPtr(mem.ptr);
}

/// Same as `alloc`, but for the one big long-lived buffer per note load: the
/// uploaded `.in` file's raw bytes, written here before calling `open`. Uses
/// `big_alloc` (see its doc comment) instead of the general-purpose
/// allocator, which would round this (often 10s-100s of MB) allocation up
/// to the next power-of-two size class.
export fn alloc_big(len: u32) u32 {
    const mem = big_alloc.allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(mem.ptr);
}

/// Parses a `.in` file (already written into wasm memory at `ptr`, `len`
/// bytes, via `alloc_big`) into the active note. Returns 0 on success,
/// negative on failure. Replaces any previously loaded note.
export fn open(ptr: u32, len: u32) i32 {
    if (g_state) |*s| {
        s.win.deinit();
        // note.db.bytes and the uploaded file bytes (note.archive.bytes)
        // are deliberately big_alloc-owned, not arena-owned (see
        // model.open's and big_alloc's doc comments) -- the arena's bulk
        // deinit below won't touch them, so they must be freed explicitly.
        big_alloc.allocator.free(@constCast(s.note.db.bytes));
        big_alloc.allocator.free(@constCast(s.note.archive.bytes));
        s.arena.deinit();
        g_state = null;
    }

    const bytes: [*]const u8 = @ptrFromInt(ptr);
    var arena = std.heap.ArenaAllocator.init(gpa);
    const note = model.open(arena.allocator(), big_alloc.allocator, bytes[0..len]) catch {
        arena.deinit();
        return -1;
    };

    // Place the note into its final (global) storage *before* taking a
    // pointer to it for the Window -- Window.note must not point at this
    // function's stack frame, which is gone once `open` returns.
    g_state = State{ .arena = arena, .note = note, .win = undefined };
    g_state.?.win = window.Window.init(gpa, &g_state.?.note);
    return 0;
}

export fn get_page_count() u32 {
    const s = &(g_state orelse return 0);
    return @intCast(s.note.pages.len);
}

/// Returns a pointer to `get_page_count()` `PageInfo` records (width, height,
/// unbounded, color), in page order.
export fn get_page_info_ptr() u32 {
    const s = &(g_state orelse return 0);
    gpa.free(g_page_info_buf);
    g_page_info_buf = gpa.alloc(PageInfo, s.note.pages.len) catch return 0;
    for (s.note.pages, 0..) |p, i| {
        g_page_info_buf[i] = .{ .width = p.width, .height = p.height, .unbounded = if (p.unbounded) 1 else 0, .color = p.background_color };
    }
    return @intFromPtr(g_page_info_buf.ptr);
}

/// Sets which pages should be decoded right now (`count` u32 page indices
/// written into wasm memory at `ptr`, via `alloc`). Call whenever the visible
/// page range changes (scroll/pan/zoom).
export fn set_active_window(ptr: u32, count: u32) void {
    const s = &(g_state orelse return);
    const indices: [*]const u32 = @ptrFromInt(ptr);
    s.win.setActive(indices[0..count]) catch {};
}

/// Rasterizes the given page's strokes+shapes intersecting the world-space
/// viewport rect (x, y, w, h) AND whose creation_time falls in
/// [time_min, time_max), into an RGBA buffer sized pixel_w*pixel_h*4,
/// returning a pointer to it. The buffer is reused/regrown across calls.
///
/// The time range lets JS interleave multiple ink passes with image/text
/// compositing (each drawn via a separate canvas drawImage call) to get true
/// chronological stacking order across content types, instead of always
/// drawing all ink before all images/text. Pass (-inf, +inf) for the common
/// case of "just render all this page's ink" -- same cost as a single
/// unfiltered call.
export fn render_viewport(
    page_index: u32,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    pixel_w: u32,
    pixel_h: u32,
    time_min: f64,
    time_max: f64,
    min_stroke_px: f32,
) u32 {
    const s = &(g_state orelse return 0);

    const needed = @as(usize, pixel_w) * @as(usize, pixel_h) * 4;
    if (g_canvas_buf.len != needed) {
        gpa.free(g_canvas_buf);
        g_canvas_buf = gpa.alloc(u8, needed) catch return 0;
    }

    const scale: f32 = if (w > 0) @as(f32, @floatFromInt(pixel_w)) / w else 1;
    const canvas = raster.Canvas{
        .pixels = g_canvas_buf,
        .width = pixel_w,
        .height = pixel_h,
        .origin_x = x,
        .origin_y = y,
        .scale = scale,
    };
    canvas.clear(0x00000000);

    if (s.win.get(page_index)) |content| {
        const cull = model.Bounds{ .left = x, .top = y, .right = x + w, .bottom = y + h };
        // Filter the chronological draw order down to visible, in-range
        // entries, but keep indices pointing at the original (unfiltered)
        // strokes/shapes arrays -- that's what content.order's indices are
        // relative to.
        var filtered_order = std.array_list.Managed(window.DrawRef).initCapacity(gpa, content.order.len) catch return @intFromPtr(g_canvas_buf.ptr);
        defer filtered_order.deinit();
        for (content.order) |ref| {
            const bounds, const time = switch (ref.kind) {
                .stroke => .{ content.strokes[ref.index].bounds, content.strokes[ref.index].creation_time },
                .shape => .{ content.shapes[ref.index].bounds, content.shapes[ref.index].creation_time },
            };
            const t: f64 = @floatFromInt(time);
            if (intersects(bounds, cull) and t >= time_min and t < time_max) filtered_order.append(ref) catch {};
        }

        const min_width_world: f32 = if (min_stroke_px > 0) min_stroke_px / scale else 0;
        raster.renderPageContent(canvas, .{
            .strokes = content.strokes,
            .shapes = content.shapes,
            .text_boxes = &.{}, // text is drawn natively by JS via get_visible_textbox_*
            .order = filtered_order.items,
        }, min_width_world);
    }

    return @intFromPtr(g_canvas_buf.ptr);
}

/// Returns the strokes+shapes intersecting the world-space viewport rect AND
/// creation_time range as vector polygon outlines (SVG/vector export), not
/// rasterized pixels -- each stroke becomes one filled polygon (the same
/// variable-width ribbon `render_viewport` rasterizes), each shape edge
/// becomes one filled quad. Resolution-independent, so unlike
/// `render_viewport` there's no pixel size to request.
export fn get_vector_content_count(page_index: u32, x: f32, y: f32, w: f32, h: f32, time_min: f64, time_max: f64) u32 {
    const s = &(g_state orelse return 0);
    const cull = model.Bounds{ .left = x, .top = y, .right = x + w, .bottom = y + h };

    var polys = std.array_list.Managed(VectorPoly).init(gpa);
    var verts = std.array_list.Managed(f32).init(gpa);

    if (s.win.get(page_index)) |content| {
        for (content.order) |ref| {
            switch (ref.kind) {
                .stroke => {
                    const st = content.strokes[ref.index];
                    const t: f64 = @floatFromInt(st.creation_time);
                    if (!intersects(st.bounds, cull) or t < time_min or t >= time_max) continue;
                    const poly = raster.tessellateStrokeScratch(st.points, st.width);
                    if (poly.len < 3) continue;
                    appendPoly(&polys, &verts, st.color, t, poly) catch break;
                },
                .shape => {
                    const sh = content.shapes[ref.index];
                    const t: f64 = @floatFromInt(sh.creation_time);
                    if (!intersects(sh.bounds, cull) or t < time_min or t >= time_max) continue;
                    if (sh.points.len >= 3) {
                        var i: usize = 0;
                        while (i < sh.points.len) : (i += 1) {
                            const quad = raster.quadForLine(sh.points[i], sh.points[(i + 1) % sh.points.len], sh.width);
                            appendPoly(&polys, &verts, sh.color, t, &quad) catch break;
                        }
                    } else if (sh.points.len == 2) {
                        const quad = raster.quadForLine(sh.points[0], sh.points[1], sh.width);
                        appendPoly(&polys, &verts, sh.color, t, &quad) catch {};
                    }
                },
            }
        }
    }

    gpa.free(g_vector_poly_buf);
    g_vector_poly_buf = polys.toOwnedSlice() catch &.{};
    gpa.free(g_vector_vertex_buf);
    g_vector_vertex_buf = verts.toOwnedSlice() catch &.{};
    return @intCast(g_vector_poly_buf.len);
}

fn appendPoly(polys: *std.array_list.Managed(VectorPoly), verts: *std.array_list.Managed(f32), color: u32, creation_time: f64, poly: []const [2]f32) !void {
    const offset: u32 = @intCast(verts.items.len / 2);
    for (poly) |v| {
        try verts.append(v[0]);
        try verts.append(v[1]);
    }
    try polys.append(.{ .creation_time = creation_time, .color = color, .vertex_offset = offset, .vertex_count = @intCast(poly.len) });
}

export fn get_vector_content_poly_ptr() u32 {
    return @intFromPtr(g_vector_poly_buf.ptr);
}

export fn get_vector_content_vertex_ptr() u32 {
    return @intFromPtr(g_vector_vertex_buf.ptr);
}

fn intersects(a: model.Bounds, b: model.Bounds) bool {
    return a.left <= b.right and a.right >= b.left and a.top <= b.bottom and a.bottom >= b.top;
}

export fn get_visible_image_count(page_index: u32, x: f32, y: f32, w: f32, h: f32) u32 {
    const s = &(g_state orelse return 0);
    const cull = model.Bounds{ .left = x, .top = y, .right = x + w, .bottom = y + h };

    var list = std.array_list.Managed(ImageDraw).init(gpa);
    for (s.note.images) |img| {
        if (img.page_index != page_index or !intersects(img.bounds, cull)) continue;
        list.append(.{
            .left = img.bounds.left,
            .top = img.bounds.top,
            .right = img.bounds.right,
            .bottom = img.bounds.bottom,
            .name_ptr = @intFromPtr(img.zip_entry_name.ptr),
            .name_len = @intCast(img.zip_entry_name.len),
            .creation_time = @floatFromInt(img.creation_time),
        }) catch break;
    }
    gpa.free(g_image_draw_buf);
    g_image_draw_buf = list.toOwnedSlice() catch &.{};
    return @intCast(g_image_draw_buf.len);
}

export fn get_visible_image_ptr() u32 {
    return @intFromPtr(g_image_draw_buf.ptr);
}

export fn get_visible_textbox_count(page_index: u32, x: f32, y: f32, w: f32, h: f32) u32 {
    const s = &(g_state orelse return 0);
    const cull = model.Bounds{ .left = x, .top = y, .right = x + w, .bottom = y + h };

    var list = std.array_list.Managed(TextBoxDraw).init(gpa);
    if (s.win.get(page_index)) |content| {
        for (content.text_boxes) |t| {
            if (!intersects(t.bounds, cull)) continue;
            list.append(.{
                .left = t.bounds.left,
                .top = t.bounds.top,
                .right = t.bounds.right,
                .bottom = t.bounds.bottom,
                .size = t.text_size,
                .color = t.color,
                .text_ptr = @intFromPtr(t.text.ptr),
                .text_len = @intCast(t.text.len),
                .creation_time = @floatFromInt(t.creation_time),
            }) catch break;
        }
    }
    gpa.free(g_textbox_draw_buf);
    g_textbox_draw_buf = list.toOwnedSlice() catch &.{};
    return @intCast(g_textbox_draw_buf.len);
}

export fn get_visible_textbox_ptr() u32 {
    return @intFromPtr(g_textbox_draw_buf.ptr);
}

/// Extracts a zip entry's raw bytes (e.g. a `note_image_*.png` asset) by name,
/// the name having been written into wasm memory at `name_ptr`/`name_len` via
/// `alloc`. Returns a pointer; call `get_bytes_len()` for its length.
export fn get_bytes(name_ptr: u32, name_len: u32) u32 {
    const s = &(g_state orelse return 0);
    const name_p: [*]const u8 = @ptrFromInt(name_ptr);
    const name = name_p[0..name_len];

    const entry = s.note.archive.find(name) orelse return 0;
    gpa.free(g_bytes_buf);
    g_bytes_buf = s.note.archive.extract(gpa, entry) catch return 0;
    return @intFromPtr(g_bytes_buf.ptr);
}

export fn get_bytes_len() u32 {
    return @intCast(g_bytes_buf.len);
}

/// Returns ALL images in the note (not viewport-culled, unlike
/// get_visible_image_*) -- for the Media panel's Images tab.
export fn get_all_images_count() u32 {
    const s = &(g_state orelse return 0);
    gpa.free(g_asset_image_buf);
    g_asset_image_buf = gpa.alloc(AssetImageDraw, s.note.images.len) catch return 0;
    for (s.note.images, 0..) |img, i| {
        g_asset_image_buf[i] = .{
            .creation_time = @floatFromInt(img.creation_time),
            .left = img.bounds.left,
            .top = img.bounds.top,
            .right = img.bounds.right,
            .bottom = img.bounds.bottom,
            .page_index = img.page_index,
            .name_ptr = @intFromPtr(img.zip_entry_name.ptr),
            .name_len = @intCast(img.zip_entry_name.len),
        };
    }
    return @intCast(g_asset_image_buf.len);
}

export fn get_all_images_ptr() u32 {
    return @intFromPtr(g_asset_image_buf.ptr);
}

/// Returns ALL hyperlinks in the note -- for the Links panel.
export fn get_all_links_count() u32 {
    const s = &(g_state orelse return 0);
    gpa.free(g_link_draw_buf);
    g_link_draw_buf = gpa.alloc(LinkDraw, s.note.links.len) catch return 0;
    for (s.note.links, 0..) |link, i| {
        g_link_draw_buf[i] = .{
            .creation_time = @floatFromInt(link.creation_time),
            .left = link.bounds.left,
            .top = link.bounds.top,
            .right = link.bounds.right,
            .bottom = link.bounds.bottom,
            .page_index = link.page_index,
            .link_type = @truncate(link.link_type),
            .dest_ptr = @intFromPtr(link.destination.ptr),
            .dest_len = @intCast(link.destination.len),
        };
    }
    return @intCast(g_link_draw_buf.len);
}

export fn get_all_links_ptr() u32 {
    return @intFromPtr(g_link_draw_buf.ptr);
}

/// Returns ALL audio recordings in the note -- for the Media panel's Audio tab.
export fn get_all_audio_count() u32 {
    const s = &(g_state orelse return 0);
    gpa.free(g_audio_draw_buf);
    g_audio_draw_buf = gpa.alloc(AudioDraw, s.note.audio.len) catch return 0;
    for (s.note.audio, 0..) |a, i| {
        g_audio_draw_buf[i] = .{
            .creation_time = @floatFromInt(a.creation_time),
            .duration_ms = @floatFromInt(a.duration_ms),
            .name_ptr = @intFromPtr(a.name.ptr),
            .name_len = @intCast(a.name.len),
            .entry_ptr = @intFromPtr(a.zip_entry_name.ptr),
            .entry_len = @intCast(a.zip_entry_name.len),
        };
    }
    return @intCast(g_audio_draw_buf.len);
}

export fn get_all_audio_ptr() u32 {
    return @intFromPtr(g_audio_draw_buf.ptr);
}

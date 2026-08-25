const std = @import("std");
const model = @import("model.zig");
const window = @import("window.zig");
const raster = @import("raster.zig");
const tessellate = @import("tessellate.zig");
const zipper = @import("zipper.zig");
const big_alloc = @import("big_alloc.zig");
const util = @import("util.zig");
const gridCellIndex = util.gridCellIndex;
const intersects = util.intersects;
const extOf = util.extOf;
const sanitizeInto = util.sanitizeInto;

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
var g_media_zip_buf: []u8 = &.{};
// Reused across every render_viewport/get_vector_content_count call instead
// of allocating a fresh list each time -- panning/zooming calls this every
// frame, and repeatedly alloc+free-ing a list sized to the page's full item
// count is pure per-frame overhead on top of the actual cull/raster work.
var g_filtered_order: std.array_list.Managed(window.DrawRef) = std.array_list.Managed(window.DrawRef).init(gpa);
// Scratch for the grid path's order-index collection (see collectVisibleOrder) --
// reused across calls for the same reason as g_filtered_order.
var g_grid_hits: std.array_list.Managed(u32) = std.array_list.Managed(u32).init(gpa);
// Monotonic counter for dedup during a grid query (see `collectVisibleOrder`):
// an item spanning multiple visited grid cells must only be collected once.
// Bumped once per query; compared against each item's `seen` stamp instead of
// memset-ing that (page-sized) array back to 0 before every query.
var g_cull_gen: u32 = 0;

// stride 36: 4x f32 (width, height), 2x u32 (unbounded, color), 4x f32 content
// bounds (left, top, right, bottom, page-local coords -- see
// model.Page.content_bounds), u32 has_content flag (content bounds fields are
// meaningless when 0, since a page with no ink has no real bounds to report).
const PageInfo = extern struct {
    width: f32,
    height: f32,
    unbounded: u32,
    color: u32,
    content_left: f32,
    content_top: f32,
    content_right: f32,
    content_bottom: f32,
    has_content: u32,
};
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

/// Allocates `len` bytes in wasm memory and returns a pointer to it, or 0 on
/// failure. Uses `big_alloc` for large requests (>64 KiB) to avoid wasm
/// page-size class waste; all callers (JS and Zig) should use this.
export fn alloc(len: u32) u32 {
    const allocator = if (len > 64 * 1024) big_alloc.allocator else gpa;
    const mem = allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(mem.ptr);
}

/// Parses a `.in` file (already written into wasm memory at `ptr`, `len`
/// bytes, via `alloc`) into the active note. Returns 0 on success,
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
        const cb = p.content_bounds orelse model.Bounds{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        g_page_info_buf[i] = .{
            .width = p.width,
            .height = p.height,
            .unbounded = if (p.unbounded) 1 else 0,
            .color = p.background_color,
            .content_left = cb.left,
            .content_top = cb.top,
            .content_right = cb.right,
            .content_bottom = cb.bottom,
            .has_content = if (p.content_bounds != null) 1 else 0,
        };
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
        collectVisibleOrder(content, cull, time_min, time_max, &g_filtered_order);

        const min_width_world: f32 = if (min_stroke_px > 0) min_stroke_px / scale else 0;
        raster.renderPageContent(canvas, .{
            .strokes = content.strokes,
            .shapes = content.shapes,
            .text_boxes = &.{}, // text is drawn natively by JS via get_visible_textbox_*
            .order = g_filtered_order.items,
        }, min_width_world);
    }

    return @intFromPtr(g_canvas_buf.ptr);
}

/// Fills `out` with the entries of `content.order` whose bounds intersect
/// `cull` and whose creation_time falls in `[time_min, time_max)` -- the
/// per-frame cull step shared by `render_viewport` and
/// `get_vector_content_count`. Uses `content.grid` (built once at decode
/// time, see window.zig) to visit only nearby items when available, instead
/// of scanning every item on the page; falls back to a full linear scan for
/// an empty/ungridded page (nothing to gain from a grid there anyway).
fn collectVisibleOrder(content: window.PageContent, cull: model.Bounds, time_min: f64, time_max: f64, out: *std.array_list.Managed(window.DrawRef)) void {
    out.clearRetainingCapacity();

    if (content.grid.cols == 0 or content.seen.len != content.order.len) {
        for (content.order) |ref| {
            const bounds, const time = switch (ref.kind) {
                .stroke => .{ content.strokes[ref.index].bounds, content.strokes[ref.index].creation_time },
                .shape => .{ content.shapes[ref.index].bounds, content.shapes[ref.index].creation_time },
            };
            const t: f64 = @floatFromInt(time);
            if (intersects(bounds, cull) and t >= time_min and t < time_max) out.append(ref) catch {};
        }
        return;
    }

    g_cull_gen += 1;
    const gen = g_cull_gen;
    const grid = content.grid;
    const cx0 = gridCellIndex(cull.left, grid.min_x, grid.cell_w, grid.cols);
    const cx1 = gridCellIndex(cull.right, grid.min_x, grid.cell_w, grid.cols);
    const cy0 = gridCellIndex(cull.top, grid.min_y, grid.cell_h, grid.rows);
    const cy1 = gridCellIndex(cull.bottom, grid.min_y, grid.cell_h, grid.rows);

    // Cells are visited in raster (row-major) order, not creation_time order,
    // so collect the hit order-indices first and sort them before appending
    // -- `order`'s index IS its creation_time rank (it was built pre-sorted,
    // see window.zig's decodePage), so sorting these indices ascending
    // restores exactly the chronological/stacking order `renderPageContent`
    // (and the caller's overlay-interleaving) depends on. Skipping this
    // would silently draw overlapping ink in the wrong stacking order
    // whenever a query happens to touch more than one grid cell.
    g_grid_hits.clearRetainingCapacity();
    var cy = cy0;
    while (cy <= cy1) : (cy += 1) {
        var cx = cx0;
        while (cx <= cx1) : (cx += 1) {
            const cell = cy * grid.cols + cx;
            for (grid.cell_items[grid.cell_start[cell]..grid.cell_start[cell + 1]]) |order_idx| {
                if (content.seen[order_idx] == gen) continue;
                content.seen[order_idx] = gen;
                g_grid_hits.append(order_idx) catch {};
            }
        }
    }
    std.mem.sort(u32, g_grid_hits.items, {}, std.sort.asc(u32));

    for (g_grid_hits.items) |order_idx| {
        const ref = content.order[order_idx];
        const bounds, const time = switch (ref.kind) {
            .stroke => .{ content.strokes[ref.index].bounds, content.strokes[ref.index].creation_time },
            .shape => .{ content.shapes[ref.index].bounds, content.shapes[ref.index].creation_time },
        };
        const t: f64 = @floatFromInt(time);
        if (intersects(bounds, cull) and t >= time_min and t < time_max) out.append(ref) catch {};
    }
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
        collectVisibleOrder(content, cull, time_min, time_max, &g_filtered_order);
        for (g_filtered_order.items) |ref| {
            switch (ref.kind) {
                .stroke => {
                    const st = content.strokes[ref.index];
                    const t: f64 = @floatFromInt(st.creation_time);
                    // Reuse the polygon already tessellated at decode time
                    // (see window.zig's decodeStroke) instead of redoing it.
                    const poly = if (st.tess_poly.len >= 3) st.tess_poly else tessellate.tessellateStrokeScratch(st.points, st.width);
                    if (poly.len < 3) continue;
                    appendPoly(&polys, &verts, st.color, t, poly) catch break;
                },
                .shape => {
                    const sh = content.shapes[ref.index];
                    const t: f64 = @floatFromInt(sh.creation_time);
                    if (sh.points.len >= 3) {
                        var i: usize = 0;
                        while (i < sh.points.len) : (i += 1) {
                            const quad = tessellate.quadForLine(sh.points[i], sh.points[(i + 1) % sh.points.len], sh.width);
                            appendPoly(&polys, &verts, sh.color, t, &quad) catch break;
                        }
                    } else if (sh.points.len == 2) {
                        const quad = tessellate.quadForLine(sh.points[0], sh.points[1], sh.width);
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

/// Builds a zip bundling every image and audio recording in the note
/// (images/ and audio/ folders, stored uncompressed -- see zipper.zig)
/// and stashes it for get_media_zip_ptr(). Returns the zip's byte length,
/// or 0 on failure/no note loaded.
export fn build_media_zip() u32 {
    const s = &(g_state orelse return 0);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var entries = std.array_list.Managed(zipper.StoredEntry).init(a);

    for (s.note.images, 0..) |img, i| {
        const src_entry = s.note.archive.find(img.zip_entry_name) orelse continue;
        const data = s.note.archive.extract(a, src_entry) catch continue;
        const name = std.fmt.allocPrint(a, "images/image-{d:0>3}.{s}", .{ i + 1, extOf(img.zip_entry_name) }) catch continue;
        entries.append(.{ .name = name, .data = data }) catch continue;
    }

    for (s.note.audio, 0..) |aud, i| {
        const src_entry = s.note.archive.find(aud.zip_entry_name) orelse continue;
        const data = s.note.archive.extract(a, src_entry) catch continue;
        var safe_buf: [128]u8 = undefined;
        const safe_len = sanitizeInto(&safe_buf, aud.name);
        const name = std.fmt.allocPrint(a, "audio/audio-{d:0>3}-{s}.{s}", .{ i + 1, safe_buf[0..safe_len], extOf(aud.zip_entry_name) }) catch continue;
        entries.append(.{ .name = name, .data = data }) catch continue;
    }

    const zip_bytes = zipper.writeStoredZip(gpa, entries.items) catch return 0;
    gpa.free(g_media_zip_buf);
    g_media_zip_buf = zip_bytes;
    return @intCast(g_media_zip_buf.len);
}

export fn get_media_zip_ptr() u32 {
    return @intFromPtr(g_media_zip_buf.ptr);
}

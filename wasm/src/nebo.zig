//! Nebo (`.nebo`) ink decoder.
//!
//! A `.nebo` file is a ZIP whose handwritten ink lives in `pages/<id>/ink.bink`
//! (a proprietary MyScript "BINK" stream), not in a SQLite db like the Notein
//! `.in` path. This module decodes the *raw stroke region* of `ink.bink` -- the
//! part that is fully reverse-engineered (see `NEBO_FORMAT.md`) -- into
//! `model.NeboStroke`s and packages them as a `model.Note` so the whole
//! window/raster/export pipeline downstream is shared with `.in`.
//!
//! Layers per NEBO_FORMAT.md §22 kept deliberately separate: ZIP container
//! (zip_reader) -> BINK raw parser (`decodeBink`) -> stroke model
//! (`model.NeboStroke`) -> style resolver (`applyStyleColors`).
//!
//! Pen colors come from the semantic stream: `LAYOUT_STROKES` enumerates the
//! 767 strokes' semantic indices (the k-th smallest maps to raw stroke k), and
//! each color `.STYLE` object carries stroke-index ranges plus a CSS color --
//! `applyStyleColors` resolves that chain to a per-stroke ARGB. The rest of the
//! semantic graph (recognition text, diagram JSON, tilt/orientation) is not yet
//! decoded; when it is, only this file changes.

const std = @import("std");
const model = @import("model.zig");
const pager = @import("sqlite/pager.zig");
const zip_reader = @import("zip_reader.zig");

const Point = model.Point;
const Bounds = model.Bounds;

/// Every raw stroke record begins with this 4-byte marker (NEBO_FORMAT.md §3).
const STROKE_MARKER = [4]u8{ 0x00, 0x00, 0x00, 0x80 };
/// Fixed header size before the variable dx/dy/pressure payload.
const STROKE_HEADER_LEN = 30;
/// Delta coordinates are stored as 1/512 binary fixed-point (§4).
const COORD_SCALE: f32 = 1.0 / 512.0;
/// Default ink color (opaque black) -- used when a stroke isn't covered by any
/// color `.STYLE`, or when the semantic style stream can't be parsed.
const DEFAULT_COLOR: u32 = 0xFF000000;
/// Base pen width in page-model units for Nebo's FountainPen look. The stored
/// `-myscript-pen-width:1.96` renders far too thin versus the app (whose brush
/// applies its own scaling), so we use a bolder base; the calligraphic
/// tessellation (see tessellate.tessellateStrokeCalligraphic) then modulates it
/// per-point by pressure and travel direction.
const PEN_WIDTH: f32 = 5.0;

/// Cheap sniff: a Nebo file has an `index.bdom` at the root and/or a
/// `pages/<id>/ink.bink` ink stream, neither of which a `.in` file has.
pub fn isNebo(archive: model.ZipArchive) bool {
    if (archive.find("index.bdom") != null) return true;
    return archive.findSuffix("/ink.bink") != null or archive.find("ink.bink") != null;
}

/// Builds a `model.Note` from a Nebo archive: one page per `ink.bink`, its ink
/// decoded up front. Pages are infinite-canvas (unbounded) -- the frontend
/// sizes their box from `content_bounds` (the real ink extent), so nothing is
/// clipped away.
pub fn open(alloc: std.mem.Allocator, archive: model.ZipArchive) !model.Note {
    var pages = std.array_list.Managed(model.Page).init(alloc);
    var nebo_pages = std.array_list.Managed([]const model.NeboStroke).init(alloc);

    for (archive.entries) |entry| {
        if (!isInkEntry(entry.name)) continue;
        const bytes = try archive.extract(alloc, entry);
        const decoded = try decodeBink(alloc, bytes);
        const strokes = decoded.strokes;
        // Resolve per-stroke pen colors from the semantic stream that follows
        // the raw region. Best-effort: on any parse trouble strokes keep the
        // default color rather than risking mis-coloring.
        applyStyleColors(alloc, strokes, bytes[decoded.sem_start..]) catch {};

        var content_bounds: ?Bounds = null;
        for (strokes) |s| content_bounds = unionBounds(content_bounds, s.bounds);

        try pages.append(.{
            .id = pageIdOf(entry.name),
            .unbounded = true,
            // No usable paper size -> frontend lays the box out from
            // content_bounds (see web/src/canvas/layout.ts).
            .width = 0,
            .height = 0,
            .background_color = 0xFFFFFFFF,
            .content_bounds = content_bounds,
        });
        try nebo_pages.append(strokes);
    }

    if (pages.items.len == 0) return model.Error.NoteNotFound;

    return .{
        .alloc = alloc,
        .archive = archive,
        // No SQLite db in a Nebo note; a zero db is never read (the Nebo path
        // never touches the b-tree). main.zig frees note.db.bytes on close,
        // and big_alloc.free no-ops on an empty slice.
        .db = .{ .bytes = &.{}, .page_size = 0, .usable_size = 0 },
        .pages = try pages.toOwnedSlice(),
        .strokes = try alloc.alloc(model.StrokeEntry, 0),
        .shapes = try alloc.alloc(model.ShapeEntry, 0),
        .text_boxes = try alloc.alloc(model.TextBoxEntry, 0),
        .images = try alloc.alloc(model.ImageAsset, 0),
        .links = try alloc.alloc(model.LinkAsset, 0),
        .audio = try alloc.alloc(model.AudioAsset, 0),
        .nebo_pages = try nebo_pages.toOwnedSlice(),
    };
}

fn isInkEntry(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "/ink.bink") or std.mem.eql(u8, name, "ink.bink");
}

/// Extracts the page id from an ink entry path (`pages/<id>/ink.bink` -> `<id>`),
/// falling back to the whole name if it doesn't match that shape.
fn pageIdOf(name: []const u8) []const u8 {
    const suffix = "/ink.bink";
    if (!std.mem.endsWith(u8, name, suffix)) return name;
    const without = name[0 .. name.len - suffix.len];
    if (std.mem.lastIndexOfScalar(u8, without, '/')) |i| return without[i + 1 ..];
    return without;
}

fn unionBounds(cur: ?Bounds, b: Bounds) Bounds {
    const c = cur orelse return b;
    return .{
        .left = @min(c.left, b.left),
        .top = @min(c.top, b.top),
        .right = @max(c.right, b.right),
        .bottom = @max(c.bottom, b.bottom),
    };
}

const readU16 = readLe(u16);
const readI16 = readLe(i16);
const readU64 = readLe(u64);

fn readLe(comptime T: type) fn ([]const u8, usize) T {
    return struct {
        fn f(buf: []const u8, off: usize) T {
            return std.mem.readInt(T, buf[off..][0..@sizeOf(T)], .little);
        }
    }.f;
}

fn readF32(buf: []const u8, off: usize) f32 {
    return @bitCast(std.mem.readInt(u32, buf[off..][0..4], .little));
}

pub const Decoded = struct {
    strokes: []model.NeboStroke,
    /// Byte offset in `data` where the raw stroke region ends and the semantic
    /// stream begins (the color/style resolver reads from here on).
    sem_start: usize,
};

/// Decodes the raw stroke region of one `ink.bink` into fully-reconstructed
/// strokes (absolute points + normalized pressure + bounds). Stops at the first
/// position that isn't a stroke marker -- that's where the semantic stream
/// begins (§10) -- so it never mis-reads object data as ink.
///
/// The raw region's start offset is NOT fixed: the `BINK` header/preamble
/// length varies between files (193 in memy.nebo, 177..205 across e.nebo's
/// pages), so we locate the first stroke marker rather than hardcoding 193.
pub fn decodeBink(alloc: std.mem.Allocator, data: []const u8) !Decoded {
    var out = std.array_list.Managed(model.NeboStroke).init(alloc);
    errdefer out.deinit();

    var pos: usize = std.mem.indexOf(u8, data, &STROKE_MARKER) orelse
        return .{ .strokes = try out.toOwnedSlice(), .sem_start = data.len };
    while (pos + STROKE_HEADER_LEN <= data.len and std.mem.eql(u8, data[pos..][0..4], &STROKE_MARKER)) {
        const ts_us = readU64(data, pos + 4);
        const x0 = readF32(data, pos + 12);
        const y0 = readF32(data, pos + 16);
        // +0x14 tilt, +0x16 orientation, +0x18 reserved: stroke-level fields
        // we currently don't render with; skipped.
        const n = readU16(data, pos + 26);

        const dx_off = pos + STROKE_HEADER_LEN;
        const dy_off = dx_off + 2 * @as(usize, n);
        const p_off = dy_off + 2 * @as(usize, n);
        const end = p_off + @as(usize, n);
        if (end > data.len) break; // truncated / lost sync

        const points = try alloc.alloc(Point, n);
        var cx: f32 = x0;
        var cy: f32 = y0;
        var min_x: f32 = x0;
        var min_y: f32 = y0;
        var max_x: f32 = x0;
        var max_y: f32 = y0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            cx += @as(f32, @floatFromInt(readI16(data, dx_off + 2 * i))) * COORD_SCALE;
            cy += @as(f32, @floatFromInt(readI16(data, dy_off + 2 * i))) * COORD_SCALE;
            const pressure = @as(f32, @floatFromInt(data[p_off + i])) / 255.0;
            points[i] = .{ .x = cx, .y = cy, .p = pressure };
            min_x = @min(min_x, cx);
            min_y = @min(min_y, cy);
            max_x = @max(max_x, cx);
            max_y = @max(max_y, cy);
        }

        try out.append(.{
            .bounds = .{ .left = min_x, .top = min_y, .right = max_x, .bottom = max_y },
            .color = DEFAULT_COLOR,
            .width = PEN_WIDTH,
            .points = points,
            .creation_time = @intCast(ts_us / 1000), // microseconds -> epoch ms
        });

        // Skip any pure-0xFF inter-stroke filler before the next marker (§9).
        pos = end;
        while (pos < data.len and data[pos] == 0xFF) pos += 1;
    }

    return .{ .strokes = try out.toOwnedSlice(), .sem_start = pos };
}

// ---- Style/color resolver ---------------------------------------------------

/// A `\0`-length-prefixed reader over the semantic stream, with every read
/// bounds-checked -- a truncated/misaligned stream yields `error.EndOfStream`
/// and the caller falls back to default ink rather than reading past the end.
const SemError = error{EndOfStream};

fn semU32(sem: []const u8, off: usize) SemError!u32 {
    if (off + 4 > sem.len) return error.EndOfStream;
    return std.mem.readInt(u32, sem[off..][0..4], .little);
}

/// A named semantic object's name is immediately preceded by a `u32` name
/// length (part of its 20-byte header, §14). Requiring it to equal the name's
/// length rejects incidental byte matches (e.g. a name appearing inside a CSS
/// string or diagram JSON blob).
fn isRealName(sem: []const u8, name_off: usize, name: []const u8) bool {
    if (name_off < 4) return false;
    const len = semU32(sem, name_off - 4) catch return false;
    return len == name.len;
}

/// Resolves per-stroke pen colors and writes them into `strokes[*].color`.
/// `sem` is the semantic stream (everything after the raw stroke region).
fn applyStyleColors(alloc: std.mem.Allocator, strokes: []model.NeboStroke, sem: []const u8) !void {
    // 1) LAYOUT_STROKES enumerates every stroke's semantic index. Sorted+deduped
    //    ascending, the k-th index is raw stroke k. Build index -> stroke-rank.
    var indices = std.array_list.Managed(u32).init(alloc);
    defer indices.deinit();
    try collectSectionIndices(sem, "LAYOUT_STROKES", &indices);
    if (indices.items.len == 0) return; // no layout info -> keep default color

    std.mem.sort(u32, indices.items, {}, std.sort.asc(u32));
    var rank_of = std.AutoHashMap(u32, u32).init(alloc);
    defer rank_of.deinit();
    var rank: u32 = 0;
    var prev: ?u32 = null;
    for (indices.items) |s| {
        if (prev != null and prev.? == s) continue; // dedup
        prev = s;
        try rank_of.put(s, rank);
        rank += 1;
    }
    // Only proceed if the enumeration matches the strokes we actually decoded;
    // otherwise the index space isn't what we think and coloring would be wrong.
    if (rank != strokes.len) return;

    // 2) Each color `.STYLE` object: its stroke-index ranges get its CSS color.
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, sem, pos, ".STYLE")) |j| {
        pos = j + ".STYLE".len;
        if (!isRealName(sem, j, ".STYLE")) continue;
        const parsed = parseStyle(sem, j + ".STYLE".len) catch continue;
        const color = parsed.color orelse continue;
        for (parsed.ranges) |r| {
            var s = r.from;
            while (s <= r.to) : (s += 1) {
                if (rank_of.get(s)) |k| strokes[k].color = color;
            }
        }
    }
}

const Range = struct { from: u32, to: u32 };

/// Adds every stroke index covered by all sections named `name` (e.g.
/// `LAYOUT_STROKES`) to `out`. Each section is `[u32 count][count x 16-byte
/// range record]`; a range record's `from`/`to` are at `+4`/`+12` (§12).
fn collectSectionIndices(sem: []const u8, comptime name: []const u8, out: *std.array_list.Managed(u32)) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, sem, pos, name)) |j| {
        pos = j + name.len;
        if (!isRealName(sem, j, name)) continue;
        const count = semU32(sem, j + name.len) catch continue;
        if (count > 4096) continue; // implausible -> not a real section header
        const ranges_off = j + name.len + 4;
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const base = ranges_off + k * 16;
            const from = semU32(sem, base + 4) catch break;
            const to = semU32(sem, base + 12) catch break;
            if (to < from or to - from > 100_000) break; // lost sync
            var s = from;
            while (s <= to) : (s += 1) try out.append(s);
        }
    }
}

const ParsedStyle = struct { ranges: []const Range, color: ?u32 };
var g_style_ranges: [4096]Range = undefined;

/// Parses a `.STYLE` object body starting at `off` (just past the name):
/// `[u32 count][count x 16B ranges][u32 css_len][css bytes]`. Returns its
/// ranges (into a reused static buffer) and the CSS `color:#RRGGBBAA` as ARGB
/// if present. Non-color styles (font-size, line-height) return `color = null`.
fn parseStyle(sem: []const u8, off: usize) !ParsedStyle {
    const count = try semU32(sem, off);
    if (count > g_style_ranges.len) return error.EndOfStream;
    const ranges_off = off + 4;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const base = ranges_off + k * 16;
        g_style_ranges[k] = .{ .from = try semU32(sem, base + 4), .to = try semU32(sem, base + 12) };
    }
    const css_len_off = ranges_off + count * 16;
    const css_len = try semU32(sem, css_len_off);
    const css_off = css_len_off + 4;
    if (css_off + css_len > sem.len) return error.EndOfStream;
    const css = sem[css_off .. css_off + css_len];
    return .{ .ranges = g_style_ranges[0..count], .color = parseCssColor(css) };
}

/// Extracts `color:#RRGGBBAA` from a CSS style string as packed ARGB
/// (`0xAARRGGBB`), or null if absent/malformed.
fn parseCssColor(css: []const u8) ?u32 {
    const needle = "color:#";
    const i = std.mem.indexOf(u8, css, needle) orelse return null;
    const hex_off = i + needle.len;
    if (hex_off + 8 > css.len) return null;
    var v: u32 = 0;
    for (css[hex_off .. hex_off + 8]) |c| {
        const d = hexVal(c) orelse return null;
        v = (v << 4) | d;
    }
    // v is 0xRRGGBBAA; repack to 0xAARRGGBB.
    const a = v & 0xFF;
    const rgb = v >> 8;
    return (a << 24) | rgb;
}

fn hexVal(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

test "decodeBink parses a single synthetic stroke" {
    const alloc = std.testing.allocator;
    // Put the marker at a nonzero offset (a stand-in for the BINK preamble) to
    // exercise the marker search rather than assuming a fixed start.
    const RAW_STREAM_START = 193;
    var buf: [RAW_STREAM_START + STROKE_HEADER_LEN + 5 * 2]u8 = undefined;
    @memset(&buf, 0);
    // one stroke, 2 points
    @memcpy(buf[RAW_STREAM_START..][0..4], &STROKE_MARKER);
    std.mem.writeInt(u64, buf[RAW_STREAM_START + 4 ..][0..8], 2_000_000, .little);
    std.mem.writeInt(u32, buf[RAW_STREAM_START + 12 ..][0..4], @bitCast(@as(f32, 10.0)), .little);
    std.mem.writeInt(u32, buf[RAW_STREAM_START + 16 ..][0..4], @bitCast(@as(f32, 20.0)), .little);
    std.mem.writeInt(u16, buf[RAW_STREAM_START + 26 ..][0..2], 2, .little);
    const dx_off = RAW_STREAM_START + STROKE_HEADER_LEN;
    std.mem.writeInt(i16, buf[dx_off..][0..2], 0, .little); // dx[0]=0
    std.mem.writeInt(i16, buf[dx_off + 2 ..][0..2], 512, .little); // dx[1]=+1.0
    std.mem.writeInt(i16, buf[dx_off + 4 ..][0..2], 0, .little); // dy[0]
    std.mem.writeInt(i16, buf[dx_off + 6 ..][0..2], 0, .little); // dy[1]
    buf[dx_off + 8] = 128; // pressure[0]
    buf[dx_off + 9] = 255; // pressure[1]

    const decoded = try decodeBink(alloc, &buf);
    const strokes = decoded.strokes;
    defer {
        for (strokes) |s| alloc.free(@constCast(s.points));
        alloc.free(strokes);
    }
    try std.testing.expectEqual(@as(usize, 1), strokes.len);
    try std.testing.expectEqual(@as(usize, 2), strokes[0].points.len);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), strokes[0].points[0].x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 11.0), strokes[0].points[1].x, 1e-4);
    try std.testing.expectEqual(@as(i64, 2000), strokes[0].creation_time);
}

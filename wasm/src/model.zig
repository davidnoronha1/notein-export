const std = @import("std");
const zip = @import("zip.zig");
const wal = @import("wal.zig");
const pager = @import("sqlite/pager.zig");
const btree = @import("sqlite/btree.zig");
const schema = @import("sqlite/schema.zig");
const record = @import("sqlite/record.zig");
const json = @import("json.zig");

pub const Bounds = struct { left: f32, top: f32, right: f32, bottom: f32 };

/// A single pressure-tagged stylus sample. Lives here (rather than in
/// window.zig, where decoded strokes are built) so both `window.zig` (which
/// decodes points) and `tessellate.zig` (which turns them into fill
/// polygons) can depend on it without depending on each other.
pub const Point = struct { x: f32, y: f32, p: f32 };

pub const Page = struct {
    id: []const u8,
    unbounded: bool,
    width: f32,
    height: f32,
    background_color: u32,
    /// Union of every stroke/shape/text-box/image/link bounds placed on this
    /// page, in the same page-local coordinate space those items report their
    /// own bounds in. `null` if the page has no content. Unlike `width`/
    /// `height` (which come from the app's declared `paper_spec`, often a
    /// nominal placeholder like 1920x1920 for an infinite-canvas page, or
    /// entirely absent), this reflects where ink actually is -- an unbounded
    /// page's real coordinate space isn't `[0,width]x[0,height]`, it can
    /// extend arbitrarily far in any direction including negative.
    content_bounds: ?Bounds = null,
};

/// Cheap per-item index entry: bounds + page association + a reference back to
/// the b-tree row, so the expensive `record_json` payload (points array) can be
/// decoded later, lazily, only for pages in the active window (see window.zig).
pub fn IndexEntry(comptime Extra: type) type {
    return struct {
        page_index: u32,
        bounds: Bounds,
        row: btree.Row,
        extra: Extra,
    };
}

pub const Empty = struct {};
pub const StrokeEntry = IndexEntry(Empty);
pub const ShapeEntry = IndexEntry(Empty);
pub const TextBoxEntry = IndexEntry(Empty);

pub const ImageAsset = struct {
    page_index: u32,
    bounds: Bounds,
    /// Zip entry name (e.g. "note_image_<uuid>.png"), resolved at load time so
    /// rendering never needs to touch SQLite again for images.
    zip_entry_name: []const u8,
    creation_time: i64,
};

pub const LinkAsset = struct {
    page_index: u32,
    bounds: Bounds,
    destination: []const u8,
    link_type: i64,
    creation_time: i64,
};

pub const AudioAsset = struct {
    /// Display name (AudioFileEntity.audio_name), e.g. "Recording 1".
    name: []const u8,
    /// Zip entry name, resolved at load time like ImageAsset.zip_entry_name.
    zip_entry_name: []const u8,
    duration_ms: i64,
    creation_time: i64,
};

pub const Note = struct {
    alloc: std.mem.Allocator,
    archive: zip.Archive,
    db: pager.Db,

    pages: []Page,
    strokes: []StrokeEntry,
    shapes: []ShapeEntry,
    text_boxes: []TextBoxEntry,
    images: []ImageAsset,
    links: []LinkAsset,
    audio: []AudioAsset,

    pub fn pageIndexOf(self: Note, id: []const u8) ?u32 {
        for (self.pages, 0..) |p, i| {
            if (std.mem.eql(u8, p.id, id)) return @intCast(i);
        }
        return null;
    }
};

pub const Error = error{
    DbEntryNotFound,
    NoteNotFound,
    TableNotFound,
    TooManyEntries,
} || zip.Error || pager.Error || btree.Error || record.Error || json.Error || std.mem.Allocator.Error;

const MAX_ZIP_ENTRIES = 512;

fn dupJsonString(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    return alloc.dupe(u8, s);
}

fn readColumn(alloc: std.mem.Allocator, db: pager.Db, row: btree.Row, hdr: record.RecordHeader, i: usize) ![]const u8 {
    return row.readColumnAlloc(alloc, db, hdr, i);
}

fn readColumnF32(db: pager.Db, row: btree.Row, hdr: record.RecordHeader, i: usize) f32 {
    if (i >= hdr.column_count) return 0;
    const range = hdr.columnRange(i);
    var buf: [8]u8 = undefined;
    row.readColumn(db, hdr, i, buf[0..range.len]);
    const v = record.decodeValue(hdr.serialType(i), buf[0..range.len]);
    return switch (v) {
        .real => |r| @floatCast(r),
        .int => |n| @floatFromInt(n),
        else => 0,
    };
}

fn readColumnBool(db: pager.Db, row: btree.Row, hdr: record.RecordHeader, i: usize) bool {
    if (i >= hdr.column_count) return false;
    const range = hdr.columnRange(i);
    var buf: [8]u8 = undefined;
    row.readColumn(db, hdr, i, buf[0..range.len]);
    const v = record.decodeValue(hdr.serialType(i), buf[0..range.len]);
    return switch (v) {
        .int => |n| n != 0,
        else => false,
    };
}

fn readColumnI64(db: pager.Db, row: btree.Row, hdr: record.RecordHeader, i: usize) i64 {
    if (i >= hdr.column_count) return 0;
    const range = hdr.columnRange(i);
    var buf: [8]u8 = undefined;
    row.readColumn(db, hdr, i, buf[0..range.len]);
    const v = record.decodeValue(hdr.serialType(i), buf[0..range.len]);
    return if (v == .int) v.int else 0;
}

/// Android packs colors as signed 32-bit ARGB ints; reinterpret the low 32
/// bits as unsigned (matches the pattern used for stroke/shape/text colors).
fn argbFromSigned(v: i64) u32 {
    return @truncate(@as(u64, @bitCast(v)));
}

fn readBounds(db: pager.Db, row: btree.Row, hdr: record.RecordHeader, left_col: usize) Bounds {
    return .{
        .left = readColumnF32(db, row, hdr, left_col),
        .top = readColumnF32(db, row, hdr, left_col + 1),
        .right = readColumnF32(db, row, hdr, left_col + 2),
        .bottom = readColumnF32(db, row, hdr, left_col + 3),
    };
}

/// Loads a `.in` file's active note into a fully-indexed (but not fully
/// content-decoded, see `IndexEntry`) in-memory representation.
///
/// `file_bytes` must outlive the returned `Note` (nothing here copies the raw
/// zip/db bytes; row payloads are read from them lazily on demand).
///
/// `alloc` is the note's persistent allocator (typically an arena) -- results
/// that must live for the Note's lifetime (the merged `db_bytes`, decoded
/// indices, etc.) are allocated from it. `scratch_base` must be a *real*
/// allocator (supports actual `free`/`resize`, e.g. the wasm/gpa allocator or
/// `std.testing.allocator`), used directly (NOT wrapped in an arena) for the
/// WAL-merge's transient pre-merge buffers: those are decompressed via a
/// growable-buffer writer that repeatedly `resize`s as it produces output,
/// and an arena can only extend in place for the most-recent allocation in
/// its current chunk -- every resize that doesn't fit permanently stranded
/// the old chunk until the whole arena tears down, turning e.g. a ~180MB
/// decompression into 600MB+ of unreachable chunk debris. Using the real
/// allocator directly lets it actually reclaim/reuse that space.
///
/// `db_bytes` (the merged/final database buffer `Note.db` wraps) is
/// deliberately also owned by `scratch_base`, not `alloc`: on the wasm
/// build, `scratch_base`'s allocator rounds large allocations up to the
/// next power-of-two size class, so `wal.apply` can often extend/merge
/// `db_bytes` in place within its already-reserved slot instead of needing
/// a whole second same-size-class allocation just to hold a copy that
/// mostly duplicates it (see `wal.apply`'s docs). That optimization only
/// works if the buffer being merged and the final buffer share the exact
/// same allocator instance, which the persistent note arena can't guarantee
/// (arenas manage their own chunks, opaque to the child allocator). The
/// caller (main.zig) is responsible for freeing `note.db.bytes` via the
/// same base allocator when the note is closed/replaced, since the note
/// arena's bulk-deinit won't touch it.
pub fn open(alloc: std.mem.Allocator, scratch_base: std.mem.Allocator, file_bytes: []const u8) !Note {
    const entries_buf = try alloc.alloc(zip.Entry, MAX_ZIP_ENTRIES);
    const archive = try zip.open(alloc, file_bytes, entries_buf);

    const db_entry = archive.findSuffix("_db") orelse return Error.DbEntryNotFound;

    var db_bytes: []u8 = undefined;
    if (archive.findSuffix("_db-wal")) |wal_entry| {
        // Extract wal_bytes BEFORE raw_db_bytes: big_alloc's in-place-growth
        // optimization only works for the single most-recently-grown
        // allocation, so raw_db_bytes must be the *last* thing allocated
        // before wal.apply potentially needs to resize it (grow OR shrink)
        // -- otherwise that resize silently falls back to a full alloc+copy
        // of the whole buffer.
        const wal_bytes = try archive.extract(scratch_base, wal_entry);
        const raw_db_bytes = try archive.extract(scratch_base, db_entry);
        const raw_db = try pager.Db.init(raw_db_bytes);
        db_bytes = try wal.apply(scratch_base, raw_db_bytes, raw_db.page_size, wal_bytes);
        // wal_bytes is genuinely temporary; raw_db_bytes is consumed by
        // wal.apply (its return value replaces it, possibly the same
        // pointer) so must NOT be freed separately here.
        scratch_base.free(wal_bytes);
    } else {
        // No WAL to merge: extract straight into scratch_base (see doc
        // comment above for why db_bytes lives there, not `alloc`).
        db_bytes = try archive.extract(scratch_base, db_entry);
    }
    const db = try pager.Db.init(db_bytes);

    // The note's uuid is embedded in the db entry's filename
    // ("note_database_note_<uuid>_db"); NoteContentEntity may contain more
    // than one row (seen in real exports), so match on that uuid rather than
    // assuming a single row.
    const note_uuid = extractNoteUuid(db_entry.name) orelse return Error.NoteNotFound;

    const note_root = (try schema.findTableRoot(db, "NoteContentEntity")) orelse return Error.TableNotFound;
    const NoteCtx = struct {
        alloc: std.mem.Allocator,
        db: pager.Db,
        uuid: []const u8,
        page_list_json: ?[]const u8 = null,
        unbounded: bool = false,
    };
    var note_ctx = NoteCtx{ .alloc = alloc, .db = db, .uuid = note_uuid };
    const visitNote = struct {
        fn f(ctx: *NoteCtx, row: btree.Row) !void {
            if (ctx.page_list_json != null) return; // already found
            const hdr = try row.header();
            // NoteContentEntity: id, page_list, page_layer_list, outline_list,
            // default_page_id, pdf_info_id, saved_page_index,
            // activated_page_layer_id, zoom, unbounded_page_offset_x,
            // unbounded_page_offset_y, unbounded_note, ...
            const id = try readColumn(ctx.alloc, ctx.db, row, hdr, 0);
            if (!std.mem.eql(u8, id, ctx.uuid)) return;
            ctx.page_list_json = try readColumn(ctx.alloc, ctx.db, row, hdr, 1);
            ctx.unbounded = readColumnBool(ctx.db, row, hdr, 11);
        }
    }.f;
    try btree.scanTable(db, note_root, *NoteCtx, &note_ctx, visitNote);
    const page_list_json = note_ctx.page_list_json orelse return Error.NoteNotFound;

    const page_ids_val = try json.parse(alloc, page_list_json);
    const page_ids = page_ids_val.array;

    // PageEntity rows keyed by id (TEXT primary key, not the implicit rowid),
    // so collect them all and match by string against page_list's order.
    const page_root = (try schema.findTableRoot(db, "PageEntity")) orelse return Error.TableNotFound;
    var page_map = std.StringHashMap(Page).init(alloc);
    const PageScanCtx = struct { alloc: std.mem.Allocator, db: pager.Db, map: *std.StringHashMap(Page), note_unbounded: bool };
    var page_scan_ctx = PageScanCtx{ .alloc = alloc, .db = db, .map = &page_map, .note_unbounded = note_ctx.unbounded };
    const visitPage = struct {
        fn f(ctx: *PageScanCtx, row: btree.Row) !void {
            const hdr = try row.header();
            // PageEntity: id, note_id, paper_spec, page_orientation, paper_theme,
            // padding_color, paper_padding, creation_time, last_modification_time,
            // tn_path, unbounded, ...
            const id = try readColumn(ctx.alloc, ctx.db, row, hdr, 0);
            const paper_spec_json = try readColumn(ctx.alloc, ctx.db, row, hdr, 2);
            var width: f32 = 0;
            var height: f32 = 0;
            if (paper_spec_json.len > 0) {
                if (json.parse(ctx.alloc, paper_spec_json)) |spec| {
                    width = if (spec.get("preciseWidth")) |w| w.asF32() else 0;
                    height = if (spec.get("preciseHeight")) |h| h.asF32() else 0;
                } else |_| {}
            }
            const unbounded = readColumnBool(ctx.db, row, hdr, 10);
            // The page's actual paper color lives in paper_theme's nested
            // baseTheme.color (an Android ARGB int), NOT the padding_color
            // column -- that one colors the margin/padding area around the
            // page, not the page itself. paper_theme is a polymorphic union
            // (ColorPaperTheme, PatternPaperTheme, ImagePaperTheme, ...);
            // only ColorPaperTheme carries a flat baseTheme.color, so fall
            // back to opaque white when it's absent (e.g. image/pattern themes).
            const paper_theme_json = try readColumn(ctx.alloc, ctx.db, row, hdr, 4);
            var background_color: u32 = 0xFFFFFFFF;
            if (paper_theme_json.len > 0) {
                if (json.parse(ctx.alloc, paper_theme_json)) |theme| {
                    if (theme.get("baseTheme")) |base| {
                        if (base.get("color")) |c| background_color = argbFromSigned(c.asI64());
                    }
                } else |_| {}
            }
            try ctx.map.put(id, .{ .id = id, .unbounded = unbounded, .width = width, .height = height, .background_color = background_color });
        }
    }.f;
    try btree.scanTable(db, page_root, *PageScanCtx, &page_scan_ctx, visitPage);

    var pages = try alloc.alloc(Page, page_ids.len);
    for (page_ids, 0..) |pid_val, i| {
        const pid = pid_val.asStr();
        pages[i] = page_map.get(pid) orelse .{ .id = pid, .unbounded = note_ctx.unbounded, .width = 0, .height = 0, .background_color = 0xFFFFFFFF };
    }

    const strokes = try scanIndexedTable(Empty, alloc, db, "StrokeEntity", pages, 1, 5);
    const shapes = try scanIndexedTable(Empty, alloc, db, "ShapeEntity", pages, 1, 12);
    const text_boxes = try scanIndexedTable(Empty, alloc, db, "TextBoxEntity", pages, 1, 14);
    const images = try scanImages(alloc, db, archive, pages);
    const links = try scanLinks(alloc, db, pages);
    const audio = try scanAudio(alloc, db, archive);

    for (strokes) |e| expandContentBounds(pages, e.page_index, e.bounds);
    for (shapes) |e| expandContentBounds(pages, e.page_index, e.bounds);
    for (text_boxes) |e| expandContentBounds(pages, e.page_index, e.bounds);
    for (images) |e| expandContentBounds(pages, e.page_index, e.bounds);
    for (links) |e| expandContentBounds(pages, e.page_index, e.bounds);

    return .{
        .alloc = alloc,
        .archive = archive,
        .db = db,
        .pages = pages,
        .strokes = strokes,
        .shapes = shapes,
        .text_boxes = text_boxes,
        .images = images,
        .links = links,
        .audio = audio,
    };
}

fn expandContentBounds(pages: []Page, page_index: u32, b: Bounds) void {
    if (page_index >= pages.len) return;
    const p = &pages[page_index];
    if (p.content_bounds) |*cb| {
        cb.left = @min(cb.left, b.left);
        cb.top = @min(cb.top, b.top);
        cb.right = @max(cb.right, b.right);
        cb.bottom = @max(cb.bottom, b.bottom);
    } else {
        p.content_bounds = b;
    }
}

fn extractNoteUuid(db_entry_name: []const u8) ?[]const u8 {
    const prefix = "note_database_note_";
    const suffix = "_db";
    if (!std.mem.startsWith(u8, db_entry_name, prefix)) return null;
    if (!std.mem.endsWith(u8, db_entry_name, suffix)) return null;
    return db_entry_name[prefix.len .. db_entry_name.len - suffix.len];
}

/// Scans a table generically into an `IndexEntry` list: only the cheap
/// `page_id` (column `page_id_col`) and `left/top/right/bottom` columns
/// (starting at `bounds_col`) are read -- `record_json`/`points`/`text` etc.
/// stay undecoded until a page enters the active window.
fn scanIndexedTable(
    comptime Extra: type,
    alloc: std.mem.Allocator,
    db: pager.Db,
    table_name: []const u8,
    pages: []const Page,
    page_id_col: usize,
    bounds_col: usize,
) ![]IndexEntry(Extra) {
    const root = (try schema.findTableRoot(db, table_name)) orelse return Error.TableNotFound;

    const Ctx = struct {
        alloc: std.mem.Allocator,
        db: pager.Db,
        pages: []const Page,
        page_id_col: usize,
        bounds_col: usize,
        out: std.array_list.Managed(IndexEntry(Extra)),
    };
    var ctx = Ctx{
        .alloc = alloc,
        .db = db,
        .pages = pages,
        .page_id_col = page_id_col,
        .bounds_col = bounds_col,
        .out = std.array_list.Managed(IndexEntry(Extra)).init(alloc),
    };

    const visit = struct {
        fn f(c: *Ctx, row: btree.Row) !void {
            const hdr = try row.header();
            const page_id = try readColumn(c.alloc, c.db, row, hdr, c.page_id_col);
            var page_index: u32 = std.math.maxInt(u32);
            for (c.pages, 0..) |p, i| {
                if (std.mem.eql(u8, p.id, page_id)) {
                    page_index = @intCast(i);
                    break;
                }
            }
            if (page_index == std.math.maxInt(u32)) return; // orphaned row, page not in this note's page_list
            const bounds = readBounds(c.db, row, hdr, c.bounds_col);
            try c.out.append(.{ .page_index = page_index, .bounds = bounds, .row = row, .extra = .{} });
        }
    }.f;
    try btree.scanTable(db, root, *Ctx, &ctx, visit);
    return ctx.out.toOwnedSlice();
}

fn scanImages(alloc: std.mem.Allocator, db: pager.Db, archive: zip.Archive, pages: []const Page) ![]ImageAsset {
    const root = (try schema.findTableRoot(db, "ImageEntity")) orelse return Error.TableNotFound;

    const Ctx = struct {
        alloc: std.mem.Allocator,
        db: pager.Db,
        archive: zip.Archive,
        pages: []const Page,
        out: std.array_list.Managed(ImageAsset),
    };
    var ctx = Ctx{ .alloc = alloc, .db = db, .archive = archive, .pages = pages, .out = std.array_list.Managed(ImageAsset).init(alloc) };

    const visit = struct {
        fn f(c: *Ctx, row: btree.Row) !void {
            const hdr = try row.header();
            // ImageEntity: id, uri, layer, layer_id, bounds, rotation, page_id,
            // creation_time, last_modification_time, left, top, right, bottom, fixed
            const uri = try readColumn(c.alloc, c.db, row, hdr, 1);
            const page_id = try readColumn(c.alloc, c.db, row, hdr, 6);

            var page_index: u32 = std.math.maxInt(u32);
            for (c.pages, 0..) |p, i| {
                if (std.mem.eql(u8, p.id, page_id)) {
                    page_index = @intCast(i);
                    break;
                }
            }
            if (page_index == std.math.maxInt(u32)) return;

            // `id` does not reliably match the zip asset's uuid; the zip entry
            // name is derived from `uri`'s basename instead (see plan findings).
            const basename = if (std.mem.lastIndexOfScalar(u8, uri, '/')) |i| uri[i + 1 ..] else uri;
            const entry_name = try std.fmt.allocPrint(c.alloc, "note_image_{s}", .{basename});
            if (c.archive.find(entry_name) == null) return; // asset missing from export, skip gracefully

            const bounds = readBounds(c.db, row, hdr, 9);
            const creation_time = readColumnI64(c.db, row, hdr, 7);
            try c.out.append(.{ .page_index = page_index, .bounds = bounds, .zip_entry_name = entry_name, .creation_time = creation_time });
        }
    }.f;
    try btree.scanTable(db, root, *Ctx, &ctx, visit);
    return ctx.out.toOwnedSlice();
}

fn scanLinks(alloc: std.mem.Allocator, db: pager.Db, pages: []const Page) ![]LinkAsset {
    const root = (try schema.findTableRoot(db, "HyperLinkEntity")) orelse return Error.TableNotFound;

    const Ctx = struct {
        alloc: std.mem.Allocator,
        db: pager.Db,
        pages: []const Page,
        out: std.array_list.Managed(LinkAsset),
    };
    var ctx = Ctx{ .alloc = alloc, .db = db, .pages = pages, .out = std.array_list.Managed(LinkAsset).init(alloc) };

    const visit = struct {
        fn f(c: *Ctx, row: btree.Row) !void {
            const hdr = try row.header();
            // HyperLinkEntity: id, bounds(json, unused), page_id, type, destination,
            // extras(json, unused), creation_time, last_modification_time, left, top, right, bottom
            const page_id = try readColumn(c.alloc, c.db, row, hdr, 2);
            var page_index: u32 = std.math.maxInt(u32);
            for (c.pages, 0..) |p, i| {
                if (std.mem.eql(u8, p.id, page_id)) {
                    page_index = @intCast(i);
                    break;
                }
            }
            if (page_index == std.math.maxInt(u32)) return; // orphaned row

            const link_type = readColumnI64(c.db, row, hdr, 3);
            const destination = try readColumn(c.alloc, c.db, row, hdr, 4);
            const creation_time = readColumnI64(c.db, row, hdr, 6);
            const bounds = readBounds(c.db, row, hdr, 8);
            try c.out.append(.{ .page_index = page_index, .bounds = bounds, .destination = destination, .link_type = link_type, .creation_time = creation_time });
        }
    }.f;
    try btree.scanTable(db, root, *Ctx, &ctx, visit);
    return ctx.out.toOwnedSlice();
}

fn scanAudio(alloc: std.mem.Allocator, db: pager.Db, archive: zip.Archive) ![]AudioAsset {
    const root = (try schema.findTableRoot(db, "AudioFileEntity")) orelse return Error.TableNotFound;

    const Ctx = struct {
        alloc: std.mem.Allocator,
        db: pager.Db,
        archive: zip.Archive,
        out: std.array_list.Managed(AudioAsset),
    };
    var ctx = Ctx{ .alloc = alloc, .db = db, .archive = archive, .out = std.array_list.Managed(AudioAsset).init(alloc) };

    const visit = struct {
        fn f(c: *Ctx, row: btree.Row) !void {
            const hdr = try row.header();
            // AudioFileEntity: id, file_path, audio_name, duration, play_speed, creation_time, last_modification_time
            const file_path = try readColumn(c.alloc, c.db, row, hdr, 1);
            const audio_name = try readColumn(c.alloc, c.db, row, hdr, 2);
            const duration_ms = readColumnI64(c.db, row, hdr, 3);
            const creation_time = readColumnI64(c.db, row, hdr, 5);

            // Zip entry name is derived from file_path's basename, same
            // pattern as ImageEntity.uri.
            const basename = if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |i| file_path[i + 1 ..] else file_path;
            const entry_name = try std.fmt.allocPrint(c.alloc, "note_audio_{s}", .{basename});
            if (c.archive.find(entry_name) == null) return; // asset missing from export, skip gracefully

            try c.out.append(.{ .name = audio_name, .zip_entry_name = entry_name, .duration_ms = duration_ms, .creation_time = creation_time });
        }
    }.f;
    try btree.scanTable(db, root, *Ctx, &ctx, visit);
    return ctx.out.toOwnedSlice();
}

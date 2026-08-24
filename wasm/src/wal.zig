const std = @import("std");

pub const Error = error{
    NotAWalFile,
    Truncated,
};

const WAL_MAGIC_BE: u32 = 0x377f0683;
const WAL_MAGIC_LE: u32 = 0x377f0682;

const Header = struct {
    page_size: u32,
    salt1: u32,
    salt2: u32,
    big_endian_checksums: bool,
};

fn parseHeader(wal: []const u8) Error!Header {
    if (wal.len < 32) return Error.Truncated;
    const magic = std.mem.readInt(u32, wal[0..4], .big);
    const big_endian_checksums = switch (magic) {
        WAL_MAGIC_BE => true,
        WAL_MAGIC_LE => false,
        else => return Error.NotAWalFile,
    };
    const page_size = std.mem.readInt(u32, wal[8..12], .big);
    const salt1 = std.mem.readInt(u32, wal[16..20], .big);
    const salt2 = std.mem.readInt(u32, wal[20..24], .big);
    return .{ .page_size = page_size, .salt1 = salt1, .salt2 = salt2, .big_endian_checksums = big_endian_checksums };
}

/// Replays a WAL file's committed frames onto `db_bytes`, mutating/resizing
/// it in place via `alloc` (the SAME allocator `db_bytes` was allocated
/// from -- required, since resizing/reallocating only works within one
/// allocator's own bookkeeping) and returning the buffer to use afterward
/// (usually the same pointer; only moves if growth couldn't be satisfied
/// in place). The caller must not use the original `db_bytes` value after
/// calling this -- treat it as consumed, like `realloc`.
///
/// Mutating in place (rather than always allocating a fresh copy) matters
/// on wasm: the wasm allocator rounds large allocations up to the next
/// power-of-two size class, so a fresh copy needs a whole *second*
/// same-size-class slot alongside `db_bytes` even though nothing but a
/// handful of WAL-modified pages actually differ -- for a large (order of
/// 100MB+) database this can double peak memory for no reason.
///
/// If `wal_bytes` is empty or not a valid/matching WAL, `db_bytes` is
/// returned unchanged. Only frames belonging to a *completed* transaction
/// are applied: WAL frames carry a "database size after commit" field that
/// is zero for all frames except the last one in each committed
/// transaction, so a first pass finds the last such frame and a second pass
/// applies only up to (and including) it. Any trailing frames from a
/// transaction that never committed (e.g. the app was killed mid-write) are
/// correctly ignored.
pub fn apply(alloc: std.mem.Allocator, db_bytes: []u8, page_size: u32, wal_bytes: []const u8) ![]u8 {
    if (wal_bytes.len < 32) return db_bytes;

    const hdr = parseHeader(wal_bytes) catch return db_bytes;
    if (hdr.page_size != page_size) return db_bytes;

    const frame_size = 24 + page_size;
    const frames_bytes = wal_bytes[32..];
    const max_frames = frames_bytes.len / frame_size;

    // Pass 1: find the last committed frame (nonzero "db size after commit")
    // whose salts match the WAL header, and the resulting db size in pages.
    var valid_frame_count: usize = 0;
    var final_db_pages: u32 = 0;
    var i: usize = 0;
    while (i < max_frames) : (i += 1) {
        const frame = frames_bytes[i * frame_size ..][0..frame_size];
        const fh = frame[0..24];
        const salt1 = std.mem.readInt(u32, fh[8..12], .big);
        const salt2 = std.mem.readInt(u32, fh[12..16], .big);
        if (salt1 != hdr.salt1 or salt2 != hdr.salt2) break; // stale/aborted generation
        const commit_size = std.mem.readInt(u32, fh[4..8], .big);
        if (commit_size != 0) {
            valid_frame_count = i + 1;
            final_db_pages = commit_size;
        }
    }
    if (valid_frame_count == 0) return db_bytes;

    const final_len = @as(usize, final_db_pages) * page_size;
    const orig_len = db_bytes.len;
    var out = db_bytes;
    if (final_len > orig_len) {
        out = try alloc.realloc(db_bytes, final_len);
        @memset(out[orig_len..], 0);
    }

    // Pass 2: apply frames in order; later frames for the same page naturally
    // overwrite earlier ones since we replay in file order.
    i = 0;
    while (i < valid_frame_count) : (i += 1) {
        const frame = frames_bytes[i * frame_size ..][0..frame_size];
        const page_num = std.mem.readInt(u32, frame[0..4], .big);
        const page_data = frame[24..frame_size];
        const off = (@as(usize, page_num) - 1) * page_size;
        @memcpy(out[off .. off + page_size], page_data);
    }

    return if (final_len < out.len) try alloc.realloc(out, final_len) else out;
}

test "apply: empty wal returns db unchanged" {
    const db = try std.testing.allocator.dupe(u8, "hello world");
    const out = try apply(std.testing.allocator, db, 4096, &[_]u8{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}

test "apply: single committed frame overwrites a page and can grow the db" {
    const page_size: u32 = 16;
    const db = try std.testing.allocator.alloc(u8, 16); // 1 page, all zero
    @memset(db, 0);

    var wal_buf: [32 + 24 + 16]u8 = undefined;
    // Header
    std.mem.writeInt(u32, wal_buf[0..4], WAL_MAGIC_BE, .big);
    std.mem.writeInt(u32, wal_buf[4..8], 3007000, .big);
    std.mem.writeInt(u32, wal_buf[8..12], page_size, .big);
    std.mem.writeInt(u32, wal_buf[12..16], 0, .big); // checkpoint seq
    std.mem.writeInt(u32, wal_buf[16..20], 111, .big); // salt1
    std.mem.writeInt(u32, wal_buf[20..24], 222, .big); // salt2
    std.mem.writeInt(u32, wal_buf[24..28], 0, .big);
    std.mem.writeInt(u32, wal_buf[28..32], 0, .big);

    // Frame: page 2 (grows db from 1 to 2 pages), commit frame (db size = 2).
    const frame = wal_buf[32..];
    std.mem.writeInt(u32, frame[0..4], 2, .big); // page number
    std.mem.writeInt(u32, frame[4..8], 2, .big); // db size after commit
    std.mem.writeInt(u32, frame[8..12], 111, .big); // salt1
    std.mem.writeInt(u32, frame[12..16], 222, .big); // salt2
    std.mem.writeInt(u32, frame[16..20], 0, .big);
    std.mem.writeInt(u32, frame[20..24], 0, .big);
    @memset(frame[24..40], 0xAB);

    const out = try apply(std.testing.allocator, db, page_size, &wal_buf);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expect(std.mem.allEqual(u8, out[0..16], 0)); // page 1 untouched
    try std.testing.expect(std.mem.allEqual(u8, out[16..32], 0xAB)); // page 2 from WAL
}

test "apply: uncommitted trailing frame is ignored" {
    const page_size: u32 = 16;
    const db = try std.testing.allocator.alloc(u8, 16);
    @memset(db, 0);

    var wal_buf: [32 + 2 * (24 + 16)]u8 = undefined;
    std.mem.writeInt(u32, wal_buf[0..4], WAL_MAGIC_BE, .big);
    std.mem.writeInt(u32, wal_buf[4..8], 3007000, .big);
    std.mem.writeInt(u32, wal_buf[8..12], page_size, .big);
    std.mem.writeInt(u32, wal_buf[12..16], 0, .big);
    std.mem.writeInt(u32, wal_buf[16..20], 111, .big);
    std.mem.writeInt(u32, wal_buf[20..24], 222, .big);
    std.mem.writeInt(u32, wal_buf[24..28], 0, .big);
    std.mem.writeInt(u32, wal_buf[28..32], 0, .big);

    // Frame 0: committed, writes page 1 to 0xCC.
    {
        const frame = wal_buf[32..][0..40];
        std.mem.writeInt(u32, frame[0..4], 1, .big);
        std.mem.writeInt(u32, frame[4..8], 1, .big); // commit
        std.mem.writeInt(u32, frame[8..12], 111, .big);
        std.mem.writeInt(u32, frame[12..16], 222, .big);
        std.mem.writeInt(u32, frame[16..20], 0, .big);
        std.mem.writeInt(u32, frame[20..24], 0, .big);
        @memset(frame[24..40], 0xCC);
    }
    // Frame 1: uncommitted (commit size 0), writes page 1 to 0xEE -- must be ignored.
    {
        const frame = wal_buf[72..][0..40];
        std.mem.writeInt(u32, frame[0..4], 1, .big);
        std.mem.writeInt(u32, frame[4..8], 0, .big); // not a commit
        std.mem.writeInt(u32, frame[8..12], 111, .big);
        std.mem.writeInt(u32, frame[12..16], 222, .big);
        std.mem.writeInt(u32, frame[16..20], 0, .big);
        std.mem.writeInt(u32, frame[20..24], 0, .big);
        @memset(frame[24..40], 0xEE);
    }

    const out = try apply(std.testing.allocator, db, page_size, &wal_buf);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.allEqual(u8, out, 0xCC));
}

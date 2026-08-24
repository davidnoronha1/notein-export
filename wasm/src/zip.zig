const std = @import("std");
const flate = std.compress.flate;

pub const Error = error{
    NotAZip,
    EocdNotFound,
    BadCentralDirectory,
    BadLocalHeader,
    UnsupportedCompression,
    Truncated,
};

pub const Entry = struct {
    name: []const u8,
    local_header_offset: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    compression_method: u16, // 0 = stored, 8 = deflate
};

pub const Archive = struct {
    bytes: []const u8,
    entries_buf: []Entry,
    count: usize,

    pub fn entries(self: Archive) []const Entry {
        return self.entries_buf[0..self.count];
    }

    pub fn find(self: Archive, name: []const u8) ?Entry {
        for (self.entries()) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// Finds an entry whose name ends with `suffix` (e.g. matching
    /// `note_database_note_<uuid>_db` without knowing the uuid up front).
    pub fn findSuffix(self: Archive, suffix: []const u8) ?Entry {
        for (self.entries()) |e| {
            if (std.mem.endsWith(u8, e.name, suffix)) return e;
        }
        return null;
    }

    /// Returns the decompressed bytes of `entry`, allocated from `alloc`.
    pub fn extract(self: Archive, alloc: std.mem.Allocator, entry: Entry) ![]u8 {
        const lh = self.bytes[entry.local_header_offset..];
        if (lh.len < 30 or std.mem.readInt(u32, lh[0..4], .little) != 0x04034b50) {
            return Error.BadLocalHeader;
        }
        const name_len = std.mem.readInt(u16, lh[26..28], .little);
        const extra_len = std.mem.readInt(u16, lh[28..30], .little);
        const data_start = 30 + @as(usize, name_len) + @as(usize, extra_len);
        const compressed = lh[data_start .. data_start + entry.compressed_size];

        switch (entry.compression_method) {
            0 => {
                const out = try alloc.alloc(u8, entry.uncompressed_size);
                @memcpy(out, compressed[0..entry.uncompressed_size]);
                return out;
            },
            8 => {
                var in_reader = std.Io.Reader.fixed(compressed);
                var window_buf: [flate.max_window_len]u8 = undefined;
                var decomp = flate.Decompress.init(&in_reader, .raw, &window_buf);
                // The zip central directory already tells us the exact
                // decompressed size, so allocate it once upfront and read
                // straight into it -- rather than a generic growable-buffer
                // read (`allocRemaining`), which grows its output via
                // repeated resize/remap calls as it goes. That pattern is
                // fine for a real allocator but can leave a lot of stranded,
                // never-reclaimed intermediate buffers depending on the
                // allocator's resize support, multiplying peak memory well
                // beyond the final size for a large (tens-to-hundreds-of-MB)
                // entry like a note's database.
                const out = try alloc.alloc(u8, entry.uncompressed_size);
                errdefer alloc.free(out);
                decomp.reader.readSliceAll(out) catch |err| switch (err) {
                    error.EndOfStream => return Error.Truncated,
                    else => |e| return e,
                };
                return out;
            },
            else => return Error.UnsupportedCompression,
        }
    }
};

/// Parses the ZIP central directory (End Of Central Directory record, walked
/// backwards from the end of the file, then the central directory entries it
/// points to). Entry name storage and the Entry array both borrow from
/// `alloc` and `bytes`; `bytes` must outlive the returned Archive.
pub fn open(alloc: std.mem.Allocator, bytes: []const u8, entries_buf: []Entry) Error!Archive {
    if (bytes.len < 22) return Error.Truncated;

    // Find EOCD signature (0x06054b50) scanning backward; comment field is
    // usually empty so it's typically right at the end, but scan a bounded
    // window to be safe (comment max length is 65535).
    const search_start = if (bytes.len > 22 + 65535) bytes.len - 22 - 65535 else 0;
    var eocd_off: ?usize = null;
    var i: usize = bytes.len - 22;
    while (true) {
        if (std.mem.readInt(u32, bytes[i..][0..4], .little) == 0x06054b50) {
            eocd_off = i;
            break;
        }
        if (i == search_start) break;
        i -= 1;
    }
    const eocd = bytes[eocd_off orelse return Error.EocdNotFound ..];

    const total_entries = std.mem.readInt(u16, eocd[10..12], .little);
    const cd_offset = std.mem.readInt(u32, eocd[16..20], .little);

    if (total_entries > entries_buf.len) return Error.BadCentralDirectory;

    var pos: usize = cd_offset;
    var n: usize = 0;
    while (n < total_entries) : (n += 1) {
        const rec = bytes[pos..];
        if (rec.len < 46 or std.mem.readInt(u32, rec[0..4], .little) != 0x02014b50) {
            return Error.BadCentralDirectory;
        }
        const method = std.mem.readInt(u16, rec[10..12], .little);
        const comp_size = std.mem.readInt(u32, rec[20..24], .little);
        const uncomp_size = std.mem.readInt(u32, rec[24..28], .little);
        const name_len = std.mem.readInt(u16, rec[28..30], .little);
        const extra_len = std.mem.readInt(u16, rec[30..32], .little);
        const comment_len = std.mem.readInt(u16, rec[32..34], .little);
        const local_offset = std.mem.readInt(u32, rec[42..46], .little);

        const name = rec[46 .. 46 + name_len];
        const owned_name = alloc.dupe(u8, name) catch return Error.BadCentralDirectory;

        entries_buf[n] = .{
            .name = owned_name,
            .local_header_offset = local_offset,
            .compressed_size = comp_size,
            .uncompressed_size = uncomp_size,
            .compression_method = method,
        };

        pos += 46 + name_len + extra_len + comment_len;
    }

    return .{ .bytes = bytes, .entries_buf = entries_buf, .count = total_entries };
}

test "open + extract a minimal stored-entry zip" {
    // Hand-built single-entry ZIP, compression method 0 (stored), file "a.txt" = "hi".
    const name = "a.txt";
    const content = "hi";

    var buf: [256]u8 = undefined;
    var w: usize = 0;

    const local_header_offset: u32 = 0;
    // Local file header
    std.mem.writeInt(u32, buf[w..][0..4], 0x04034b50, .little);
    w += 4;
    std.mem.writeInt(u16, buf[w..][0..2], 20, .little); // version
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // flags
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // method: stored
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // mod time
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // mod date
    w += 2;
    std.mem.writeInt(u32, buf[w..][0..4], 0, .little); // crc32 (unused by reader)
    w += 4;
    std.mem.writeInt(u32, buf[w..][0..4], content.len, .little); // compressed size
    w += 4;
    std.mem.writeInt(u32, buf[w..][0..4], content.len, .little); // uncompressed size
    w += 4;
    std.mem.writeInt(u16, buf[w..][0..2], name.len, .little);
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // extra len
    w += 2;
    @memcpy(buf[w .. w + name.len], name);
    w += name.len;
    @memcpy(buf[w .. w + content.len], content);
    w += content.len;

    const cd_offset: u32 = @intCast(w);
    // Central directory header
    std.mem.writeInt(u32, buf[w..][0..4], 0x02014b50, .little);
    w += 4;
    std.mem.writeInt(u16, buf[w..][0..2], 20, .little); // version made by
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 20, .little); // version needed
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // flags
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // method
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // mod time
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // mod date
    w += 2;
    std.mem.writeInt(u32, buf[w..][0..4], 0, .little); // crc32
    w += 4;
    std.mem.writeInt(u32, buf[w..][0..4], content.len, .little);
    w += 4;
    std.mem.writeInt(u32, buf[w..][0..4], content.len, .little);
    w += 4;
    std.mem.writeInt(u16, buf[w..][0..2], name.len, .little);
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // extra len
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // comment len
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // disk number
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // internal attrs
    w += 2;
    std.mem.writeInt(u32, buf[w..][0..4], 0, .little); // external attrs
    w += 4;
    std.mem.writeInt(u32, buf[w..][0..4], local_header_offset, .little);
    w += 4;
    @memcpy(buf[w .. w + name.len], name);
    w += name.len;

    const cd_size: u32 = @intCast(w - cd_offset);
    // EOCD
    std.mem.writeInt(u32, buf[w..][0..4], 0x06054b50, .little);
    w += 4;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // disk num
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // cd disk
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 1, .little); // entries this disk
    w += 2;
    std.mem.writeInt(u16, buf[w..][0..2], 1, .little); // total entries
    w += 2;
    std.mem.writeInt(u32, buf[w..][0..4], cd_size, .little);
    w += 4;
    std.mem.writeInt(u32, buf[w..][0..4], cd_offset, .little);
    w += 4;
    std.mem.writeInt(u16, buf[w..][0..2], 0, .little); // comment len
    w += 2;

    var entries_buf: [4]Entry = undefined;
    const archive = try open(std.testing.allocator, buf[0..w], &entries_buf);
    defer for (archive.entries()) |e| std.testing.allocator.free(e.name);

    try std.testing.expectEqual(@as(usize, 1), archive.count);
    const entry = archive.find("a.txt") orelse return error.NotFound;
    const data = try archive.extract(std.testing.allocator, entry);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("hi", data);
}

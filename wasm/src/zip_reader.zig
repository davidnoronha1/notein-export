const std = @import("std");
const zip = std.zip;
const flate = std.compress.flate;

pub const ZipError = error{
    NotAZip,
    EocdNotFound,
    BadCentralDirectory,
    BadLocalHeader,
    UnsupportedCompression,
    Truncated,
};

pub const ZipEntry = struct {
    name: []const u8,
    local_header_offset: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    compression_method: u16,
};

pub const ZipArchive = struct {
    bytes: []const u8,
    entries: []const ZipEntry,

    pub fn find(self: ZipArchive, name: []const u8) ?ZipEntry {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    pub fn findSuffix(self: ZipArchive, suffix: []const u8) ?ZipEntry {
        for (self.entries) |e| {
            if (std.mem.endsWith(u8, e.name, suffix)) return e;
        }
        return null;
    }

    pub fn extract(self: ZipArchive, alloc: std.mem.Allocator, entry: ZipEntry) ![]u8 {
        const lh_bytes = self.bytes[entry.local_header_offset..];
        if (lh_bytes.len < @sizeOf(zip.LocalFileHeader)) return ZipError.BadLocalHeader;
        const lh: *align(1) const zip.LocalFileHeader = @ptrCast(lh_bytes.ptr);
        if (!std.mem.eql(u8, &lh.signature, &zip.local_file_header_sig)) {
            return ZipError.BadLocalHeader;
        }

        const name_len = lh.filename_len;
        const extra_len = lh.extra_len;
        const data_start = @sizeOf(zip.LocalFileHeader) + @as(usize, name_len) + @as(usize, extra_len);
        if (data_start + entry.compressed_size > lh_bytes.len) return ZipError.Truncated;
        const compressed = lh_bytes[data_start .. data_start + entry.compressed_size];

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
                const out = try alloc.alloc(u8, entry.uncompressed_size);
                errdefer alloc.free(out);
                decomp.reader.readSliceAll(out) catch |err| switch (err) {
                    error.EndOfStream => return ZipError.Truncated,
                    else => |e| return e,
                };
                return out;
            },
            else => return ZipError.UnsupportedCompression,
        }
    }
};

pub fn openZip(alloc: std.mem.Allocator, bytes: []const u8, entries_buf: []ZipEntry) ZipError!ZipArchive {
    if (bytes.len < @sizeOf(zip.EndRecord)) return ZipError.Truncated;

    const search_start = if (bytes.len > @sizeOf(zip.EndRecord) + 65535) bytes.len - @sizeOf(zip.EndRecord) - 65535 else 0;
    var eocd_off: ?usize = null;
    var i: usize = bytes.len - @sizeOf(zip.EndRecord);
    while (true) {
        if (std.mem.eql(u8, bytes[i..][0..4], &zip.end_record_sig)) {
            eocd_off = i;
            break;
        }
        if (i == search_start) break;
        i -= 1;
    }
    const eocd_bytes = bytes[eocd_off orelse return ZipError.EocdNotFound ..];
    if (eocd_bytes.len < @sizeOf(zip.EndRecord)) return ZipError.EocdNotFound;

    const eocd: *align(1) const zip.EndRecord = @ptrCast(eocd_bytes.ptr);
    const total_entries = eocd.record_count_total;
    const cd_offset = eocd.central_directory_offset;

    if (total_entries > entries_buf.len) return ZipError.BadCentralDirectory;

    var pos: usize = cd_offset;
    var n: usize = 0;
    while (n < total_entries) : (n += 1) {
        if (pos + @sizeOf(zip.CentralDirectoryFileHeader) > bytes.len) return ZipError.BadCentralDirectory;
        const cd_hdr: *align(1) const zip.CentralDirectoryFileHeader = @ptrCast(bytes[pos..].ptr);
        if (!std.mem.eql(u8, &cd_hdr.signature, &zip.central_file_header_sig)) {
            return ZipError.BadCentralDirectory;
        }
        const method = @intFromEnum(cd_hdr.compression_method);
        const comp_size = cd_hdr.compressed_size;
        const uncomp_size = cd_hdr.uncompressed_size;
        const name_len = cd_hdr.filename_len;
        const extra_len = cd_hdr.extra_len;
        const comment_len = cd_hdr.comment_len;
        const local_offset = cd_hdr.local_file_header_offset;

        const name_start = pos + @sizeOf(zip.CentralDirectoryFileHeader);
        if (name_start + name_len > bytes.len) return ZipError.BadCentralDirectory;
        const name = bytes[name_start .. name_start + name_len];
        const owned_name = alloc.dupe(u8, name) catch return ZipError.BadCentralDirectory;

        entries_buf[n] = .{
            .name = owned_name,
            .local_header_offset = local_offset,
            .compressed_size = comp_size,
            .uncompressed_size = uncomp_size,
            .compression_method = method,
        };

        pos += @sizeOf(zip.CentralDirectoryFileHeader) + name_len + extra_len + comment_len;
    }

    return .{ .bytes = bytes, .entries = entries_buf[0..total_entries] };
}

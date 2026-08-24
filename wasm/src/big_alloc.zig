const std = @import("std");

/// A minimal allocator for the note viewer's few large (tens-to-hundreds of
/// MB), long-lived, one-shot buffers -- the uploaded file's raw bytes and
/// the decompressed database. Grows wasm linear memory directly via
/// `@wasmMemoryGrow` for the *exact* number of pages needed, unlike
/// `std.heap.wasm_allocator` (`BrkAllocator`), which rounds every large
/// allocation up to the next power-of-two "bigpage" count -- for a ~183MB
/// database that means a 256MB slot.
///
/// Supports true in-place growth for the single most-recently-grown
/// allocation (tracked in `last_growth`): since wasm memory only ever grows
/// and each `@wasmMemoryGrow` call extends from the current end, if nothing
/// else has been allocated after it yet, "growing" it is just extending
/// memory further -- no copy needed. This matters concretely for
/// `wal.apply`: a WAL that adds pages beyond the base database's original
/// size needs to grow `db_bytes`, and without this, that resize would
/// silently fall back to alloc+copy+free of the *entire* (100s of MB)
/// buffer, right back to the double-buffer peak this allocator exists to
/// avoid. Callers that want this to work must avoid allocating anything
/// else via this allocator between the growable allocation and the point
/// where they might need to grow it (see model.open's extraction order).
///
/// Freed regions go on a small linear free list (first-fit) so replacing
/// the loaded note reuses the previous file's space instead of growing wasm
/// memory further -- wasm memory can never shrink once grown, so without
/// this, loading a second note in the same session would leak the first
/// one's ~100s of MB permanently.
///
/// Not a general-purpose allocator: only reasonable for a handful of large,
/// infrequently-allocated buffers. Small/frequent allocations (stroke
/// indices, per-page decode churn, etc.) should keep using
/// `std.heap.wasm_allocator`, whose size-class free lists suit that pattern
/// much better.
const max_free_slots = 8;

var free_slots: [max_free_slots]struct { ptr: [*]u8, len: usize } = undefined;
var free_count: usize = 0;

/// The most recent allocation that came from fresh `@wasmMemoryGrow` growth
/// (not reused from the free list), and how many pages it actually
/// reserved -- the only allocation eligible for in-place resize.
var last_growth: ?struct { ptr: [*]u8, requested_len: usize, pages: usize } = null;

fn pagesFor(len: usize) usize {
    return (len + std.wasm.page_size - 1) / std.wasm.page_size;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;
    _ = alignment; // page allocations are always far more aligned than anything we hand out

    // First-fit: reuse a previously freed region if one is big enough.
    // Freelist-reused blocks are never followed by guaranteed-unclaimed
    // memory, so they don't become `last_growth`.
    var i: usize = 0;
    while (i < free_count) : (i += 1) {
        if (free_slots[i].len >= len) {
            const ptr = free_slots[i].ptr;
            free_count -= 1;
            free_slots[i] = free_slots[free_count];
            return ptr;
        }
    }

    const page_count = pagesFor(len);
    const prev_page: isize = @wasmMemoryGrow(0, page_count);
    if (prev_page == -1) return null;
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(prev_page)) * std.wasm.page_size);
    last_growth = .{ .ptr = ptr, .requested_len = len, .pages = page_count };
    return ptr;
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;

    const lg = last_growth orelse return false;
    if (lg.ptr != buf.ptr or lg.requested_len != buf.len) return false; // not the extendable tail allocation

    const new_pages = pagesFor(new_len);
    if (new_pages > lg.pages) {
        const extra = new_pages - lg.pages;
        if (@wasmMemoryGrow(0, extra) == -1) return false;
        last_growth = .{ .ptr = lg.ptr, .requested_len = new_len, .pages = new_pages };
    } else {
        // Shrinking (or still within already-reserved pages): no wasm-level
        // change needed, just record the new logical length.
        last_growth = .{ .ptr = lg.ptr, .requested_len = new_len, .pages = lg.pages };
    }
    return true;
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, buf, alignment, new_len, ret_addr)) buf.ptr else null;
}

fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;
    if (buf.len == 0) return;
    if (last_growth) |lg| {
        if (lg.ptr == buf.ptr and lg.requested_len == buf.len) last_growth = null;
    }
    if (free_count < max_free_slots) {
        free_slots[free_count] = .{ .ptr = buf.ptr, .len = buf.len };
        free_count += 1;
    }
    // If the free list is full, this region is simply leaked (matches wasm
    // memory's own "never shrinks" reality anyway) -- max_free_slots is
    // generously sized for the handful of big buffers this allocator ever
    // sees at once, so this shouldn't happen in practice.
}

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
};

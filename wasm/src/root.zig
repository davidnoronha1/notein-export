comptime {
    _ = @import("sqlite/varint.zig");
    _ = @import("sqlite/pager.zig");
    _ = @import("sqlite/record.zig");
    _ = @import("sqlite/btree.zig");
    _ = @import("sqlite/schema.zig");
    _ = @import("zip.zig");
    _ = @import("wal.zig");
    _ = @import("json.zig");
    _ = @import("model.zig");
    _ = @import("model_integration_test.zig");
    
    
    _ = @import("window.zig");
    _ = @import("window_integration_test.zig");
    _ = @import("raster.zig");
    _ = @import("integration_test.zig");
}

comptime {
    _ = @import("sqlite/varint.zig");
    _ = @import("sqlite/pager.zig");
    _ = @import("sqlite/record.zig");
    _ = @import("sqlite/btree.zig");
    _ = @import("sqlite/schema.zig");
    _ = @import("zip_reader.zig");
    _ = @import("zipper.zig");
    _ = @import("sqlite/wal.zig");
    _ = @import("util.zig");
    _ = @import("json.zig");
    _ = @import("model.zig");
    _ = @import("nebo.zig");
    _ = @import("tests/nebo_integration_test.zig");
    _ = @import("tests/model_integration_test.zig");
    _ = @import("window.zig");
    _ = @import("tests/window_integration_test.zig");
    _ = @import("raster.zig");
    _ = @import("tests/integration_test.zig");
}

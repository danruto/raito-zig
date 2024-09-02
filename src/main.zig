const std = @import("std");
const logz = @import("logz");
const zqlite = @import("zqlite");

const tui = @import("tui.zig");

const migrations = @import("migrations/migrations.zig");

pub fn main() !void {
    @setEvalBranchQuota(200000);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    try logz.setup(allocator, .{
        .level = .Debug,
        .output = .{ .file = "run.log" },
    });
    defer logz.deinit();

    var data_pool = zqlite.Pool.init(allocator, .{
        .size = 20,
        .path = "raito.db",
        .flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
    }) catch |err| {
        logz.fatal().ctx("app.data_pool").err(err).string("path", "raito.db").log();
        return err;
    };
    defer data_pool.deinit();
    {
        const conn = data_pool.acquire();
        defer data_pool.release(conn);
        try migrations.migrateData(conn, 0);
    }

    try tui.Tui.run(&data_pool);
}

test "test all" {
    @import("std").testing.refAllDecls(@This());
}

const m = @import("../migrations.zig");

pub const Conn = m.Conn;

pub const migrations = [_]m.Migration{
    .{ .id = 1, .run = &(@import("001_init.zig").run) },
};

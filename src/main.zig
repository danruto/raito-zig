const std = @import("std");
const rem = @import("rem");

const css_parser = @import("css_parser.zig");
const tui = @import("tui.zig");
const fwm = @import("fwn.zig");

pub fn main() !void {
    @setEvalBranchQuota(200000);

    try tui.Tui.run();
}

test "test all" {
    @import("std").testing.refAllDecls(@This());
}

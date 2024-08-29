const std = @import("std");
const rem = @import("rem");

const css_parser = @import("css_parser.zig");
const tui = @import("tui.zig");
const fwm = @import("fwn.zig");

pub fn main() !void {
    @setEvalBranchQuota(200000);

    // Do a quick download of the search page to make sure it works
    // _ = fwm.Freewebnovel.init(std.heap.page_allocator);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    const freewebnovel = fwm.Freewebnovel.init(allocator);
    const resp = try freewebnovel.search("martial");
    _ = resp;

    // try tui.Tui.run();
}

test "test all" {
    @import("std").testing.refAllDecls(@This());
}

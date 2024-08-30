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
    const novels = try freewebnovel.search("martial");

    for (novels) |novel| {
        std.debug.print("\tNovel: t: {s}, u: {s}, c: {any}\n", .{ novel.title, novel.url, novel.chapters });
    }

    // try tui.Tui.run();
}

test "test all" {
    @import("std").testing.refAllDecls(@This());
}

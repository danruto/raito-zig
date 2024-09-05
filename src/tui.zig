const std = @import("std");
const tuile = @import("tuile");
const zqlite = @import("zqlite");
const logz = @import("logz");

const Freewebnovel = @import("fwn.zig").Freewebnovel;
const Chapter = @import("chapter.zig");
const Novel = @import("novel.zig");
const PageContext = @import("tui/page.zig").PageContext;
const TuiHomePage = @import("tui/home.zig");
const TuiSearchPage = @import("tui/search.zig");
const TuiReaderPage = @import("tui/reader.zig");

const Allocator = std.mem.Allocator;
const Theme = tuile.Theme;
const color = tuile.color;

pub const Tui = struct {
    pub fn ayu() Theme {
        return Theme{
            .text_primary = color("#39BAE6"),
            .text_secondary = color("#FFB454"),
            .background_primary = color("#0D1017"),
            .background_secondary = color("#131721"),
            .interactive = color("#0D1017"),
            .focused = color("#1A1F29"),
            .borders = color("#131721"),
            .solid = color("#39BAE6"),
        };
    }

    pub fn globalKeyHandler(ptr: ?*anyopaque, event: tuile.events.Event) !tuile.events.EventResult {
        var tui: *tuile.Tuile = @ptrCast(@alignCast(ptr));
        switch (event) {
            .key => |key| if (key == .Escape) {
                tui.stop();
                return .consumed;
            },
            else => {},
        }
        return .ignored;
    }

    pub fn run(pool: *zqlite.Pool) !void {
        var tui = try tuile.Tuile.init(.{});
        defer tui.deinit();

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        defer _ = gpa.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_allocator = arena.allocator();
        defer arena.deinit();

        var page: PageContext = .{
            .home = null,
            .search = null,
            .reader = null,
        };

        var home = try TuiHomePage.create(.{
            .enabled = true,
            .tui = &tui,
            .gpa = allocator,
            .arena = arena_allocator,
            .page = &page,
            .pool = pool,
        });
        defer home.destroy();
        page.home = &home;

        var search = TuiSearchPage{
            .ctx = .{
                .enabled = false,
                .tui = &tui,
                .gpa = allocator,
                .arena = arena_allocator,
                .page = &page,
            },
        };
        defer search.destroy();
        page.search = &search;

        var reader = try TuiReaderPage.create(.{
            .enabled = false,
            .tui = &tui,
            .gpa = allocator,
            .arena = arena_allocator,
            .pool = pool,
        });
        defer reader.destroy();
        page.reader = &reader;

        try tui.add(
            tuile.themed(
                .{
                    .id = "themed",
                    .theme = ayu(),
                },
                tuile.block(
                    .{
                        .layout = .{ .flex = 1 },
                        .padding = .{ .top = 1, .bottom = 1, .left = 1, .right = 1 },
                    },
                    // tuile.label(.{ .text = "tesert234" }),
                    tuile.vertical(
                        .{
                            .id = "page-container",
                            .layout = .{ .flex = 1 },
                        },
                        .{
                            try home.render(),
                        },
                    ),
                ),
            ),
        );

        // Per page events
        try home.addEventHandler();
        try search.addEventHandler();
        try reader.addEventHandler();

        // Global application events
        try tui.addEventHandler(.{
            .handler = globalKeyHandler,
            .payload = &tui,
        });

        try tui.run();
    }
};

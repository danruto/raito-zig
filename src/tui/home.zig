const std = @import("std");
const tuile = @import("tuile");
const zqlite = @import("zqlite");
const logz = @import("logz");

const Freewebnovel = @import("../fwn.zig");
const Chapter = @import("../chapter.zig");
const Novel = @import("../novel.zig");

const Allocator = std.mem.Allocator;
const PageContext = @import("page.zig").PageContext;

pub const TuiHomePage = @This();

const Context = struct {
    enabled: bool,
    tui: *tuile.Tuile,
    gpa: Allocator,
    arena: Allocator,
    page: *PageContext,

    // Filtered slice of novels
    novels: ?[]Novel = null,
};

ctx: Context,
text: ?[]const u8 = null,
novels: ?std.ArrayList(Novel) = null,

pub fn create(ctx_: Context, pool: *zqlite.Pool) !TuiHomePage {
    // Read data from db and render it
    const novels = try Novel.get_all(pool, ctx_.arena);

    return .{
        .ctx = .{
            .enabled = ctx_.enabled,
            .tui = ctx_.tui,
            .gpa = ctx_.gpa,
            .arena = ctx_.arena,
            .page = ctx_.page,
            .novels = novels,
        },
    };
}

pub fn destroy(self: *TuiHomePage) void {
    if (self.ctx.novels) |novels| {
        for (novels) |novel| {
            novel.deinit(self.ctx.arena);
        }
        self.ctx.arena.free(novels);
    }
}

fn onInputChanged(opt_self: ?*TuiHomePage, value: []const u8) void {
    const self = opt_self.?;
    self.text = value;
    // Autosearch? If it's filtering on local state its fine
}

fn onSearch(opt_self: ?*TuiHomePage) void {
    const self = opt_self.?;
    _ = self;
}

fn onKeyHandler(ptr: ?*anyopaque, event: tuile.events.Event) !tuile.events.EventResult {
    var ctx: *Context = @ptrCast(@alignCast(ptr));

    if (!ctx.enabled) return .ignored;

    switch (event) {
        .char => |char| switch (char) {
            's' => {
                // Go to search page only when nothing is focused
                const input = ctx.tui.findByIdTyped(tuile.Input, "home-input") orelse unreachable;

                if (input.focus_handler.focused) {
                    return .ignored;
                }

                ctx.enabled = false;

                const search_page = ctx.page.search orelse unreachable;
                search_page.ctx.enabled = true;
                const home_page_widget = ctx.tui.findByIdTyped(tuile.StackLayout, "home-page") orelse unreachable;
                const page_container = ctx.tui.findByIdTyped(tuile.StackLayout, "page-container") orelse unreachable;
                _ = try page_container.removeChild(home_page_widget.widget());
                try page_container.addChild(try search_page.render());

                return .consumed;
            },
            'j' => {
                const list = ctx.tui.findByIdTyped(tuile.List, "home-list") orelse unreachable;
                if (list.focus_handler.focused) {
                    if (list.selected_index + 1 < list.items.items.len) {
                        list.selected_index += 1;
                    }

                    return .consumed;
                }
            },
            'k' => {
                const list = ctx.tui.findByIdTyped(tuile.List, "home-list") orelse unreachable;
                if (list.focus_handler.focused) {
                    if (list.selected_index > 0) {
                        list.selected_index -= 1;
                    }

                    return .consumed;
                }
            },

            else => {},
        },
        .key => |key| switch (key) {
            .Enter => {
                const btn = ctx.tui.findByIdTyped(tuile.Button, "home-search-button") orelse unreachable;
                if (btn.focus_handler.focused) {
                    if (btn.on_press) |on_press| {
                        on_press.call();
                    }
                }

                const list = ctx.tui.findByIdTyped(tuile.List, "home-list") orelse unreachable;
                if (list.focus_handler.focused) {
                    const focused_item = list.items.items[list.selected_index];
                    if (focused_item.value) |value| {
                        logz.debug().ctx("tui.home.onKeyHandler.enter").string("msg", "home-list focused item has value").fmt("value", "{any}", .{value}).log();

                        // Go down an index as `if (focused_item.value)` evaluates a 0 int as false
                        const idx = @intFromPtr(value);
                        const novels = ctx.novels orelse unreachable;
                        const novel = novels[idx - 1];
                        logz.debug().ctx("tui.home.onKeyHandler.enter").string("msg", "extracted novel").fmt("novel", "{any}", .{novel}).log();

                        // Toggle page from search to novel
                        ctx.enabled = false;

                        const reader_page = ctx.page.reader orelse unreachable;
                        reader_page.ctx.enabled = true;
                        try reader_page.ctx.fetch_chapter(novel.id, novel.chapter);

                        logz.debug().ctx("tui.home.onKeyHandler.enter").string("msg", "enabled reader page").log();

                        const home_page_widget = ctx.tui.findByIdTyped(tuile.StackLayout, "home-page") orelse unreachable;
                        const page_container = ctx.tui.findByIdTyped(tuile.StackLayout, "page-container") orelse unreachable;
                        _ = try page_container.removeChild(home_page_widget.widget());
                        try page_container.addChild(try reader_page.render());
                    }
                } else {
                    logz.debug().ctx("tui.home.onKeyHandler.enter").string("msg", "home-list was not focused").log();
                }
                return .consumed;
            },
            else => {},
        },

        // Space is the alternative implemented by the lib
        else => {},
    }

    return .ignored;
}

pub fn addEventHandler(self: *TuiHomePage) !void {
    try self.ctx.tui.addEventHandler(.{
        .handler = onKeyHandler,
        .payload = &self.ctx,
    });
}

pub fn render(self: *TuiHomePage) !*tuile.StackLayout {
    var novels_list = std.ArrayList(tuile.List.Item).init(self.ctx.arena);
    defer novels_list.deinit();

    if (self.ctx.novels) |novels| {
        if (novels.len > 0) {
            for (novels, 0..) |novel, idx| {
                try novels_list.append(.{
                    .label = try tuile.label(.{ .text = try self.ctx.arena.dupe(u8, novel.title) }),
                    .value = @ptrFromInt(idx + 1),
                });
            }
        }
    }

    if (novels_list.items.len == 0) {
        for (0..35) |idx| {
            try novels_list.append(.{
                .label = try tuile.label(.{ .text = "item..." }),
                .value = @ptrFromInt(idx),
            });
        }
    }

    return try tuile.vertical(.{ .id = "home-page", .layout = .{ .flex = 1 } }, .{
        tuile.list(
            .{
                .id = "home-list",
                .layout = .{ .flex = 16 },
            },
            novels_list.items[0..],
        ),
        tuile.spacer(.{ .layout = .{ .flex = 1 } }),
        tuile.horizontal(
            .{},
            .{
                tuile.input(.{
                    .id = "home-input",
                    .layout = .{ .flex = 1 },
                    .on_value_changed = .{
                        .cb = @ptrCast(&onInputChanged),
                        .payload = self,
                    },
                }),
                tuile.button(.{
                    .id = "home-search-button",
                    .text = "Search",
                    .on_press = .{
                        .cb = @ptrCast(&onSearch),
                        .payload = self,
                    },
                }),
            },
        ),
    });
}

// TODO: doesn't work
pub fn focusList(self: *TuiHomePage) void {
    const container = self.ctx.tui.findByIdTyped(tuile.StackLayout, "home-page") orelse unreachable;
    _ = container.handleEvent(.{ .focus_in = .front }) catch unreachable;
}

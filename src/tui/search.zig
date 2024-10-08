const std = @import("std");
const tuile = @import("tuile");
const zqlite = @import("zqlite");
const logz = @import("logz");

const Freewebnovel = @import("../fwn.zig");
const Chapter = @import("../chapter.zig");
const Novel = @import("../novel.zig");

const Allocator = std.mem.Allocator;
const PageContext = @import("page.zig").PageContext;

pub const TuiSearchPage = @This();

const Context = struct {
    enabled: bool,
    tui: *tuile.Tuile,
    gpa: Allocator,
    arena: Allocator,
    page: *PageContext,

    novels: ?[]Novel = null,
    text: ?[]const u8 = null,
};

ctx: Context,

pub fn destroy(self: *TuiSearchPage) void {
    if (self.ctx.novels) |data| {
        for (data) |novel| {
            novel.destroy(self.ctx.gpa);
        }
        self.ctx.gpa.free(data);
    }
}

fn onInputChanged(opt_self: ?*TuiSearchPage, value: []const u8) void {
    const self = opt_self.?;
    self.ctx.text = value;
}

fn onSearch(ctx: *Context) void {
    if (ctx.text) |text| {
        if (text.len > 0) {
            var list = ctx.tui.findByIdTyped(tuile.List, "search-list") orelse unreachable;

            const provider = Freewebnovel.init(ctx.gpa);
            ctx.novels = provider.search(text) catch unreachable;
            errdefer {
                if (ctx.novels) |novels| {
                    for (novels) |novel| {
                        novel.destroy(ctx.gpa);
                    }
                    ctx.gpa.free(novels);
                }
            }
            // self.ctx.novels = provider.sample() catch unreachable;

            // Need to reset the list since we don't have access to the internal.allocator
            // to append more items to the list
            list.destroy();

            var items = std.ArrayListUnmanaged(tuile.List.Item){};
            defer items.deinit(ctx.arena);

            logz.debug().ctx("tui.search.onSearch").string("msg", "Appending novels").log();
            for (ctx.novels.?, 0..) |novel, idx| {
                items.append(ctx.arena, .{
                    .label = tuile.label(.{ .text = ctx.arena.dupe(u8, novel.title) catch unreachable }) catch unreachable,
                    // Go up an index as `if (focused_item.value)` evaluates a 0 int as false
                    .value = @ptrFromInt(idx + 1),
                }) catch unreachable;
            }
            logz.debug().ctx("tui.search.onSearch").string("msg", "Appended novels").log();

            if (items.items.len == 0) {
                items.append(ctx.arena, .{ .label = tuile.label(.{ .text = "Failed to search" }) catch unreachable, .value = null }) catch unreachable;
            }

            logz.debug().ctx("tui.search.onSearch").string("msg", "Recreating list").log();
            list = tuile.list(
                .{
                    .id = "search-list",
                    .layout = .{ .flex = 16 },
                },
                items.items[0..],
            ) catch unreachable;
            logz.debug().ctx("tui.search.onSearch").string("msg", "Recreated list").log();

            // Toggle focus to list only when there were results
            if (ctx.novels) |novels| {
                if (novels.len > 0) {
                    const input = ctx.tui.findByIdTyped(tuile.Input, "search-input") orelse unreachable;

                    if (input.focus_handler.focused) {
                        input.focus_handler.focused = false;
                        _ = input.handleEvent(.focus_out) catch unreachable;
                    }
                    list.focus_handler.focused = true;
                    _ = list.handleEvent(.{ .focus_in = .front }) catch unreachable;
                }
            }
        }
    }
}

fn onKeyHandler(ptr: ?*anyopaque, event: tuile.events.Event) !tuile.events.EventResult {
    var ctx: *Context = @ptrCast(@alignCast(ptr));

    if (!ctx.enabled) return .ignored;

    switch (event) {
        .char => |char| switch (char) {
            'j' => {
                const list = ctx.tui.findByIdTyped(tuile.List, "search-list") orelse unreachable;
                if (list.focus_handler.focused) {
                    if (list.selected_index + 1 < list.items.items.len) {
                        list.selected_index += 1;
                    }

                    return .consumed;
                }
            },
            'k' => {
                const list = ctx.tui.findByIdTyped(tuile.List, "search-list") orelse unreachable;
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
            .Escape => {
                const input = ctx.tui.findByIdTyped(tuile.Input, "search-input") orelse unreachable;

                if (input.focus_handler.focused) {
                    return .ignored;
                }

                ctx.enabled = false;

                const home_page = ctx.page.home orelse unreachable;
                home_page.ctx.enabled = true;
                const serach_page_widget = ctx.tui.findByIdTyped(tuile.StackLayout, "search-page") orelse unreachable;
                const page_container = ctx.tui.findByIdTyped(tuile.StackLayout, "page-container") orelse unreachable;
                _ = try page_container.removeChild(serach_page_widget.widget());
                try page_container.addChild(try home_page.render());

                return .consumed;
            },
            .Enter => {
                // Handle list first as the btn and input will change the focus to it on success
                const list = ctx.tui.findByIdTyped(tuile.List, "search-list") orelse unreachable;
                if (list.focus_handler.focused) {
                    const focused_item = list.items.items[list.selected_index];
                    if (focused_item.value) |value| {
                        logz.debug().ctx("TuiSearchPage.onKeyHandler.enter").string("msg", "search-list focused item has value").fmt("value", "{any}", .{value}).log();

                        // Go down an index as `if (focused_item.value)` evaluates a 0 int as false
                        const idx = @intFromPtr(value) - 1;
                        const novels = ctx.novels orelse unreachable;
                        const novel = novels[idx];
                        logz.debug().ctx("TuiSearchPage.onKeyHandler.enter").string("msg", "extracted novel").fmt("novel", "{any}", .{novel}).log();

                        // Toggle page from search to novel
                        ctx.enabled = false;

                        const reader_page = ctx.page.reader orelse unreachable;
                        reader_page.ctx.enabled = true;
                        try reader_page.ctx.fetch_chapter(novel.id, novel.chapter);

                        logz.debug().ctx("TuiSearchPage.onKeyHandler.enter").string("msg", "enabled reader page").log();

                        const search_page_widget = ctx.tui.findByIdTyped(tuile.StackLayout, "search-page") orelse {
                            logz.err().ctx("TuiSearchPage.onKeyHandler.enter").string("msg", "search-page widget unreachable").log();
                            unreachable;
                        };
                        const page_container = ctx.tui.findByIdTyped(tuile.StackLayout, "page-container") orelse {
                            logz.err().ctx("TuiSearchPage.onKeyHandler.enter").string("msg", "page-container widget unreachable").log();
                            unreachable;
                        };
                        _ = try page_container.removeChild(search_page_widget.widget());
                        try page_container.addChild(try reader_page.render());
                    }
                } else {
                    logz.debug().ctx("TuiSearchPage.onKeyHandler.enter").string("msg", "search-list was not focused").log();
                }

                if (ctx.tui.findByIdTyped(tuile.Input, "search-input")) |input| {
                    if (input.focus_handler.focused) {
                        onSearch(ctx);
                    }
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

pub fn addEventHandler(self: *TuiSearchPage) !void {
    try self.ctx.tui.addEventHandler(.{
        .handler = onKeyHandler,
        .payload = &self.ctx,
    });
}

pub fn render(self: *TuiSearchPage) !*tuile.StackLayout {
    return try tuile.vertical(
        .{
            .id = "search-page",
            .layout = .{ .flex = 1 },
        },
        .{
            tuile.horizontal(
                .{},
                .{
                    tuile.input(.{
                        .id = "search-input",
                        .layout = .{ .flex = 1 },
                        .placeholder = "Search for a novel. [Enter] to search.",
                        .on_value_changed = .{
                            .cb = @ptrCast(&onInputChanged),
                            .payload = self,
                        },
                    }),
                },
            ),
            tuile.spacer(.{ .layout = .{ .flex = 1 } }),
            tuile.list(
                .{
                    .id = "search-list",
                    .layout = .{ .flex = 16 },
                },
                &.{
                    .{
                        .label = try tuile.label(.{ .text = "Waiting for search..." }),
                        .value = null,
                    },
                },
            ),
        },
    );
}

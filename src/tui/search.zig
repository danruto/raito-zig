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
};

ctx: Context,
text: ?[]const u8 = null,

pub fn destroy(self: *TuiSearchPage) void {
    if (self.ctx.novels) |data| {
        for (data) |novel| {
            novel.deinit(self.ctx.gpa);
        }
        self.ctx.gpa.free(data);
    }
}

fn onInputChanged(opt_self: ?*TuiSearchPage, value: []const u8) void {
    const self = opt_self.?;
    self.text = value;
}

fn onSearch(opt_self: ?*TuiSearchPage) void {
    const self = opt_self.?;
    if (self.text) |text| {
        if (text.len > 0) {
            var list = self.ctx.tui.findByIdTyped(tuile.List, "search-list") orelse unreachable;

            const provider = Freewebnovel.init(self.ctx.gpa);
            self.ctx.novels = provider.search(text) catch unreachable;
            errdefer {
                for (self.ctx.novels) |novel| {
                    novel.deinit(self.ctx.gpa);
                }
                self.ctx.gpa.free(self.ctx.novels);
            }

            // Need to reset the list since we don't have access to the internal.allocator
            // to append more items to the list
            list.destroy();

            var items = std.ArrayListUnmanaged(tuile.List.Item){};
            defer items.deinit(self.ctx.arena);

            logz.debug().ctx("tui.search.onSearch").string("msg", "Appending novels").log();
            for (self.ctx.novels.?, 0..) |novel, idx| {
                items.append(self.ctx.arena, .{
                    .label = tuile.label(.{ .text = self.ctx.arena.dupe(u8, novel.title) catch unreachable }) catch unreachable,
                    // Go up an index as `if (focused_item.value)` evaluates a 0 int as false
                    .value = @ptrFromInt(idx + 1),
                }) catch unreachable;
            }
            logz.debug().ctx("tui.search.onSearch").string("msg", "Appended novels").log();

            if (items.items.len == 0) {
                items.append(self.ctx.arena, .{ .label = tuile.label(.{ .text = "Failed to search" }) catch unreachable, .value = null }) catch unreachable;
            }

            logz.debug().ctx("tui.search.onSearch").string("msg", "Recreating list").log();
            list = tuile.list(.{
                .id = "search-list",
                .layout = .{ .flex = 16 },
            }, items.items[0..]) catch unreachable;
            logz.debug().ctx("tui.search.onSearch").string("msg", "Recreated list").log();
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
                const btn = ctx.tui.findByIdTyped(tuile.Button, "search-search-button") orelse unreachable;
                if (btn.focus_handler.focused) {
                    if (btn.on_press) |on_press| {
                        on_press.call();
                    }
                }

                const input = ctx.tui.findByIdTyped(tuile.Input, "search-input") orelse unreachable;
                if (input.focus_handler.focused) {
                    if (btn.on_press) |on_press| {
                        on_press.call();
                    }
                }

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

                        const search_page_widget = ctx.tui.findByIdTyped(tuile.StackLayout, "search-page") orelse unreachable;
                        const page_container = ctx.tui.findByIdTyped(tuile.StackLayout, "page-container") orelse unreachable;
                        _ = try page_container.removeChild(search_page_widget.widget());
                        try page_container.addChild(try reader_page.render());
                    }
                } else {
                    logz.debug().ctx("TuiSearchPage.onKeyHandler.enter").string("msg", "search-list was not focused").log();
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
    return try tuile.vertical(.{ .id = "search-page", .layout = .{ .flex = 1 } }, .{
        tuile.horizontal(
            .{},
            .{
                tuile.input(.{
                    .id = "search-input",
                    .layout = .{ .flex = 1 },
                    .on_value_changed = .{
                        .cb = @ptrCast(&onInputChanged),
                        .payload = self,
                    },
                }),
                tuile.button(.{
                    .id = "search-search-button",
                    .text = "Search",
                    .on_press = .{
                        .cb = @ptrCast(&onSearch),
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
    });
}

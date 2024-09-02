const std = @import("std");
const tuile = @import("tuile");
const zqlite = @import("zqlite");
const logz = @import("logz");

const Freewebnovel = @import("../fwn.zig").Freewebnovel;
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

pub fn onInputChanged(opt_self: ?*TuiSearchPage, value: []const u8) void {
    const self = opt_self.?;
    self.text = value;
}

pub fn onSelect(opt_self: ?*TuiSearchPage) void {
    const self = opt_self.?;
    _ = self;
}

pub fn onSearch(opt_self: ?*TuiSearchPage) void {
    const self = opt_self.?;
    if (self.text) |text| {
        if (text.len > 0) {
            logz.debug().ctx("tui.search.onSearch").string("msg", "Finding list").string("text", text).log();
            var list = self.ctx.tui.findByIdTyped(tuile.List, "search-list") orelse unreachable;
            logz.debug().ctx("tui.search.onSearch").string("msg", "Found list").string("text", text).log();

            const provider = Freewebnovel.init(self.ctx.gpa);
            logz.debug().ctx("tui.search.onSearch").string("msg", "Searching for").string("text", text).log();
            self.ctx.novels = provider.search(text) catch unreachable;
            logz.debug().ctx("tui.search.onSearch").string("msg", "Searched for").string("text", text).log();
            errdefer {
                for (self.ctx.novels) |novel| {
                    novel.deinit(self.ctx.gpa);
                }
                self.ctx.gpa.free(self.ctx.novels);
            }

            // Need to reset the list since we don't have access to the internal.allocator
            // to append more items to the list
            logz.debug().ctx("tui.search.onSearch").string("msg", "Destroying list").log();
            list.destroy();
            logz.debug().ctx("tui.search.onSearch").string("msg", "Destroyed list").log();

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
                .on_press = .{
                    .cb = @ptrCast(&onSelect),
                    .payload = self,
                },
            }, items.items[0..]) catch unreachable;
            logz.debug().ctx("tui.search.onSearch").string("msg", "Recreated list").log();
        }
    }
}

pub fn onKeyHandler(ptr: ?*anyopaque, event: tuile.events.Event) !tuile.events.EventResult {
    var ctx: *Context = @ptrCast(@alignCast(ptr));

    if (!ctx.enabled) return .ignored;

    switch (event) {
        .char => |char| switch (char) {
            'j' => {
                const list = ctx.tui.findByIdTyped(tuile.List, "search-list") orelse unreachable;
                if (list.selected_index + 1 < list.items.items.len) {
                    list.selected_index += 1;
                }

                return .consumed;
            },
            'k' => {
                const list = ctx.tui.findByIdTyped(tuile.List, "search-list") orelse unreachable;
                if (list.selected_index > 0) {
                    list.selected_index -= 1;
                }

                return .consumed;
            },

            else => {},
        },
        .key => |key| switch (key) {
            .Enter => {
                const btn = ctx.tui.findByIdTyped(tuile.Button, "search-search-button") orelse unreachable;
                if (btn.focus_handler.focused) {
                    if (btn.on_press) |on_press| {
                        on_press.call();
                    }
                }

                const list = ctx.tui.findByIdTyped(tuile.List, "search-list") orelse unreachable;
                if (list.focus_handler.focused) {
                    const focused_item = list.items.items[list.selected_index];
                    if (focused_item.value) |value| {
                        logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "search-list focused item has value").fmt("value", "{any}", .{value}).log();
                        // TODO:
                        // Go to chapter 1 of this novel
                        // check if we have a version locally, if we do go to current chapter instead
                        // Go down an index as `if (focused_item.value)` evaluates a 0 int as false
                        const idx = @intFromPtr(value) - 1;
                        const novels = ctx.novels orelse unreachable;
                        const novel = novels[idx];

                        // Toggle page from search to novel
                        ctx.enabled = false;

                        const reader_page = ctx.page.reader orelse unreachable;

                        reader_page.fetch_chapter(novel.id, novel.chapter) catch unreachable;

                        logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "enabled reader page").log();

                        const search_page_widget = ctx.tui.findByIdTyped(tuile.StackLayout, "search-page") orelse unreachable;
                        const page_container = ctx.tui.findByIdTyped(tuile.StackLayout, "page-container") orelse unreachable;
                        _ = page_container.removeChild(search_page_widget.widget()) catch unreachable;

                        page_container.addChild(reader_page.render() catch unreachable) catch unreachable;
                    }
                } else {
                    logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "search-list was not focused").log();
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
                .on_press = .{
                    .cb = @ptrCast(&onSelect),
                    .payload = self,
                },
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

pub fn destroy(self: *TuiSearchPage) void {
    if (self.ctx.novels) |data| {
        for (data) |novel| {
            novel.deinit(self.ctx.gpa);
        }
        self.ctx.gpa.free(data);
    }
}

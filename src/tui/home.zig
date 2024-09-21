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
    pool: *zqlite.Pool,

    // Filtered slice of novels
    novels: ?[]Novel = null,
};

ctx: Context,
text: ?[]const u8 = null,
novels: ?std.ArrayList(Novel) = null,

pub fn create(ctx_: Context) !TuiHomePage {
    // Read data from db and render it
    const novels = try Novel.get_all(ctx_.pool, ctx_.arena);

    return .{
        .ctx = .{
            .enabled = ctx_.enabled,
            .tui = ctx_.tui,
            .gpa = ctx_.gpa,
            .arena = ctx_.arena,
            .page = ctx_.page,
            .pool = ctx_.pool,
            .novels = novels,
        },
    };
}

pub fn destroy(self: *TuiHomePage) void {
    if (self.ctx.novels) |novels| {
        for (novels) |novel| {
            novel.destroy(self.ctx.arena);
        }
        self.ctx.arena.free(novels);
    }
}

fn onInputChanged(opt_self: ?*TuiHomePage, value: []const u8) void {
    const self = opt_self.?;
    self.text = value;
    // Autosearch? If it's filtering on local state its fine
}

// TODO:
fn onSearch(opt_self: ?*TuiHomePage) void {
    const self = opt_self.?;
    _ = self;
}

fn onKeyHandler(ptr: ?*anyopaque, event: tuile.events.Event) !tuile.events.EventResult {
    var ctx: *Context = @ptrCast(@alignCast(ptr));

    if (!ctx.enabled) return .ignored;

    // Clear out home page home-prefetch-progress always on a new button Press
    // since the UI can only update once the handler has been completed
    if (ctx.tui.findByIdTyped(tuile.Label, "home-prefetch-progress")) |label| {
        try label.setText("");
    }

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
            'p' => {
                const list = ctx.tui.findByIdTyped(tuile.List, "home-list") orelse unreachable;
                if (list.focus_handler.focused) {
                    const list_item_value = list.items.items[list.selected_index].value;
                    const idx = @intFromPtr(list_item_value);
                    const novels = ctx.novels orelse unreachable;
                    const novel = novels[idx - 1];

                    const provider = Freewebnovel.init(ctx.arena);

                    var number = novel.chapter + 1;

                    while (true) {
                        logz.debug().ctx("tui.home.onKeyHandler.p").string("msg", "prefetching chapter for novel").int("chapter", number).string("novel", novel.id).log();
                        const chapter = provider.fetch(novel, number) catch break;
                        chapter.upsert(ctx.pool, ctx.gpa) catch break;
                        number += 1;
                        logz.debug().ctx("tui.home.onKeyHandler.p").string("msg", "prefetched and saved chapter for novel").int("chapter", number).string("novel", novel.id).log();
                    }

                    logz.debug().ctx("tui.home.onKeyHandler.p").string("msg", "updating novel in db").int("chapter", number).string("novel", novel.id).log();
                    var n = try novel.clone(ctx.gpa);
                    defer n.destroy(ctx.gpa);
                    n.chapters = number;
                    try n.upsert(ctx.pool);
                    logz.debug().ctx("tui.home.onKeyHandler.p").string("msg", "updated novel in db").int("chapter", number).string("novel", novel.id).log();

                    if (ctx.tui.findByIdTyped(tuile.Label, "home-prefetch-progress")) |label| {
                        try label.setText(try std.fmt.allocPrint(ctx.arena, "Downloaded {s}", .{novel.title}));
                    }

                    return .consumed;
                }

                return .ignored;
            },
            'd' => {
                // delete novel and all related chapters from db
                const list = ctx.tui.findByIdTyped(tuile.List, "home-list") orelse unreachable;
                if (list.focus_handler.focused) {
                    const list_item_value = list.items.items[list.selected_index].value;
                    const idx = @intFromPtr(list_item_value);
                    const novels = ctx.novels orelse unreachable;
                    const novel = novels[idx - 1];

                    logz.debug().ctx("tui.home.onKeyHandler.d").string("msg", "deleting chapters for novel").string("novel", novel.id).log();
                    try Chapter.delete(novel.id, ctx.pool);
                    logz.debug().ctx("tui.home.onKeyHandler.d").string("msg", "deleting novel").string("novel", novel.id).log();
                    try novel.delete(ctx.pool);

                    logz.debug().ctx("tui.home.onKeyHandler.d").string("msg", "freeing novels").string("novel", novel.id).log();
                    // Refresh list
                    for (novels) |n| {
                        n.destroy(ctx.arena);
                    }
                    ctx.arena.free(novels);
                    logz.debug().ctx("tui.home.onKeyHandler.d").string("msg", "setting up new db novels").log();
                    ctx.novels = try Novel.get_all(ctx.pool, ctx.arena);

                    logz.debug().ctx("tui.home.onKeyHandler.d").string("msg", "resetting home list").log();
                    const home_page_widget = ctx.tui.findByIdTyped(tuile.StackLayout, "home-page") orelse unreachable;
                    const page_container = ctx.tui.findByIdTyped(tuile.StackLayout, "page-container") orelse unreachable;
                    _ = try page_container.removeChild(home_page_widget.widget());
                    const home_page = ctx.page.home orelse unreachable;
                    try page_container.addChild(try home_page.render());
                    logz.debug().ctx("tui.home.onKeyHandler.d").string("msg", "reset home list").log();
                }
            },

            else => {},
        },
        .key => |key| switch (key) {
            .Enter => {
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
                    .label = try tuile.label(.{ .text = try std.fmt.allocPrint(self.ctx.arena, "{s} - {d} / {s}", .{ novel.title, novel.chapter, if (novel.chapters > 1) try std.fmt.allocPrint(self.ctx.arena, "{d} downloaded", .{novel.chapters}) else "?" }) }),
                    .value = @ptrFromInt(idx + 1),
                });
            }
        }
    }

    if (novels_list.items.len == 0) {
        // Insert a default placeholder type message
        try novels_list.append(.{
            .label = try tuile.label(.{ .text = "Press `s` to go to the search page and find something to read!" }),
            .value = null,
        });
    }

    return try tuile.vertical(
        .{
            .id = "home-page",
            .layout = .{ .flex = 1 },
        },
        .{
            tuile.list(
                .{
                    .id = "home-list",
                    .layout = .{ .flex = 1 },
                },
                novels_list.items[0..],
            ),
            tuile.spacer(.{ .layout = .{ .flex = 1 } }),
            // tuile.horizontal(
            //     .{},
            //     .{
            //         tuile.input(.{
            //             .id = "home-input",
            //             .layout = .{ .flex = 1 },
            //             .on_value_changed = .{
            //                 .cb = @ptrCast(&onInputChanged),
            //                 .payload = self,
            //             },
            //         }),
            //     },
            // ),
            tuile.label(.{ .id = "home-prefetch-progress", .layout = .{ .max_height = 14 }, .text = "" }),
        },
    );
}

// TODO: doesn't work
pub fn focusList(self: *TuiHomePage) void {
    const container = self.ctx.tui.findByIdTyped(tuile.StackLayout, "home-page") orelse unreachable;
    _ = container.handleEvent(.{ .focus_in = .front }) catch unreachable;
}

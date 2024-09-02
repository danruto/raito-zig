const std = @import("std");
const tuile = @import("tuile");
const zqlite = @import("zqlite");
const logz = @import("logz");

const Freewebnovel = @import("fwn.zig").Freewebnovel;
const Chapter = @import("chapter.zig");
const Novel = @import("novel.zig");

const Allocator = std.mem.Allocator;
const Theme = tuile.Theme;
const color = tuile.color;

fn generateMultilineSpan(allocator: Allocator, lines: [][]const u8) !tuile.Span {
    var span = tuile.Span.init(allocator);

    for (lines) |line| {
        try span.append(.{ .style = .{ .fg = color("#FFFFFF") }, .text = try std.mem.concat(allocator, u8, &.{ line, "\n" }) });
        // Add another newline to give some spacing to the text for readability
        try span.append(.{ .style = .{ .fg = color("#FFFFFF") }, .text = "\n" });
    }

    return span;
}

fn generateMultilineSpanUnmanaged(allocator: Allocator, lines: [][]const u8) !tuile.SpanUnmanaged {
    var span = tuile.SpanUnmanaged{};

    for (lines) |line| {
        try span.append(allocator, .{ .style = .{ .fg = color("#FFFFFF") }, .text = try std.mem.concat(allocator, u8, &.{ line, "\n" }) });
        // Add another newline to give some spacing to the text for readability
        try span.append(allocator, .{ .style = .{ .fg = color("#FFFFFF") }, .text = "\n" });
    }

    return span;
}

const PageContext = struct {
    home: ?*TuiHomePage,
    search: ?*TuiSearchPage,
    reader: ?*TuiReaderPage,
};

const TuiHomePage = struct {
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

    fn onInputChanged(opt_self: ?*TuiHomePage, value: []const u8) void {
        const self = opt_self.?;
        self.text = value;
        // Autosearch? If it's filtering on local state its fine
    }

    fn onSearch(opt_self: ?*TuiHomePage) void {
        const self = opt_self.?;
        _ = self;
    }

    fn onSelect(opt_self: ?*TuiHomePage) void {
        const self = opt_self.?;
        _ = self;
    }

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

    pub fn render(self: *TuiHomePage) !*tuile.StackLayout {
        var novels_list = std.ArrayList(tuile.List.Item).init(self.ctx.arena);
        defer novels_list.deinit();

        if (self.ctx.novels) |novels| {
            if (novels.len > 0) {
                for (novels, 0..) |novel, idx| {
                    try novels_list.append(.{
                        .label = try tuile.label(.{ .text = try self.ctx.arena.dupe(u8, novel.title) }),
                        .value = @ptrFromInt(idx),
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
                        .id = "home-search-button",
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
                    .id = "home-list",
                    .layout = .{ .flex = 16 },
                    .on_press = .{
                        .cb = @ptrCast(&onSelect),
                        .payload = self,
                    },
                },
                novels_list.items[0..],
            ),
        });
    }

    fn onKeyHandler(ptr: ?*anyopaque, event: tuile.events.Event) !tuile.events.EventResult {
        var ctx: *Context = @ptrCast(@alignCast(ptr));

        if (!ctx.enabled) return .ignored;

        switch (event) {
            .char => |char| switch (char) {
                's' => {
                    // Go to search page
                    return .consumed;
                },
                'j' => {
                    const list = ctx.tui.findByIdTyped(tuile.List, "home-list") orelse unreachable;
                    if (list.selected_index + 1 < list.items.items.len) {
                        list.selected_index += 1;
                    }

                    return .consumed;
                },
                'k' => {
                    const list = ctx.tui.findByIdTyped(tuile.List, "home-list") orelse unreachable;
                    if (list.selected_index > 0) {
                        list.selected_index -= 1;
                    }

                    return .consumed;
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
                            logz.debug().ctx("tui.home.onKeyHandler.enter").string("msg", "search-list focused item has value").fmt("value", "{any}", .{value}).log();
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

                            logz.debug().ctx("tui.home.onKeyHandler.enter").string("msg", "enabled reader page").log();

                            const home_page_widget = ctx.tui.findByIdTyped(tuile.StackLayout, "home-page") orelse unreachable;
                            const page_container = ctx.tui.findByIdTyped(tuile.StackLayout, "page-container") orelse unreachable;
                            _ = page_container.removeChild(home_page_widget.widget()) catch unreachable;

                            page_container.addChild(reader_page.render() catch unreachable) catch unreachable;
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
};

const TuiSearchPage = struct {
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
};

const TuiReaderPage = struct {
    const Context = struct {
        tui: *tuile.Tuile,
        gpa: Allocator,
        arena: Allocator,
        provider: Freewebnovel,

        enabled: bool,
        chapter: ?Chapter = null,
        span: ?tuile.Span = null,
        offset: isize = 0,

        fn scroll(self: *Context, size: isize) !void {
            // If a span exists, then we have everything init already to setup
            const view = self.tui.findByIdTyped(tuile.Label, "view") orelse unreachable;
            const chapter = self.chapter orelse unreachable;
            const new_offset: isize = self.offset + size;
            if (new_offset >= 0 and new_offset < chapter.lines.items.len) {
                self.span.?.deinit();
                const span = try generateMultilineSpan(self.arena, chapter.lines.items[@intCast(new_offset)..]);
                self.span = span;
                self.offset = new_offset;
                try view.setSpan(self.span.?.view());
            }
        }

        pub fn scrollDown(self: *Context) !tuile.events.EventResult {
            try self.scroll(1);

            return .consumed;
        }

        pub fn scrollUp(self: *Context) !tuile.events.EventResult {
            try self.scroll(-1);

            return .consumed;
        }

        fn changeChapter(self: *Context, number: usize) !void {
            // TODO: max check?
            if (number < 0) return;

            const view = self.tui.findByIdTyped(tuile.Label, "view") orelse unreachable;
            self.chapter.?.deinit(self.gpa);
            self.chapter = try self.provider.sample_chapter(number);
            self.offset = 0;
            self.span.?.deinit();
            const span = try generateMultilineSpan(self.arena, self.chapter.?.lines.items[0..]);
            self.span = span;
            try view.setSpan(self.span.?.view());
        }

        pub fn prevChapter(self: *Context) !tuile.events.EventResult {
            try self.changeChapter(self.chapter.?.number - 1);

            return .consumed;
        }

        pub fn nextChapter(self: *Context) !tuile.events.EventResult {
            try self.changeChapter(self.chapter.?.number + 1);

            return .consumed;
        }
    };

    ctx: Context,
    pool: *zqlite.Pool,

    pub fn onKeyHandler(ptr: ?*anyopaque, event: tuile.events.Event) !tuile.events.EventResult {
        var ctx: *Context = @ptrCast(@alignCast(ptr));

        if (!ctx.enabled) return .ignored;

        return switch (event) {
            .char => |char| switch (char) {
                'j' => try ctx.scrollDown(),
                'k' => try ctx.scrollUp(),
                'h' => try ctx.prevChapter(),
                'l' => try ctx.nextChapter(),
                'q' => {
                    ctx.tui.stop();
                    return .consumed;
                },

                else => .ignored,
            },
            .key => |key| switch (key) {
                .Down => try ctx.scrollDown(),
                .Up => try ctx.scrollUp(),
                .Left => try ctx.prevChapter(),
                .Right => try ctx.nextChapter(),

                else => .ignored,
            },

            else => .ignored,
        };
    }

    pub fn addEventHandler(self: *TuiReaderPage) !void {
        try self.ctx.tui.addEventHandler(.{
            .handler = onKeyHandler,
            .payload = &self.ctx,
        });
    }

    pub fn create(cfg: struct {
        tui: *tuile.Tuile,
        gpa: Allocator,
        arena: Allocator,
        enabled: bool,
        pool: *zqlite.Pool,
    }) !TuiReaderPage {
        const provider = Freewebnovel.init(cfg.gpa);
        // var span = tuile.Span.init(cfg.arena);

        var chapter = try provider.sample_chapter(30);
        defer chapter.deinit(cfg.gpa);

        const ctx = .{
            .tui = cfg.tui,
            .arena = cfg.arena,
            .gpa = cfg.gpa,
            .enabled = cfg.enabled,
            .provider = provider,
        };

        return .{
            .ctx = ctx,
            .pool = cfg.pool,
        };
    }

    pub fn destroy(self: *TuiReaderPage) void {
        if (self.ctx.chapter) |chapter| chapter.deinit(self.ctx.gpa);
        if (self.ctx.span) |_| self.ctx.span.?.deinit();
    }

    pub fn render(self: *TuiReaderPage) !*tuile.StackLayout {
        return tuile.vertical(.{
            .layout = .{ .flex = 1 },
        }, .{
            tuile.block(
                .{
                    .id = "block",
                    .border = tuile.Border.all(),
                    .border_type = .rounded,
                    .layout = .{ .flex = 1 },
                },
                tuile.label(.{ .id = "view", .span = if (self.ctx.span) |span| span.view() else null }),
                // tuile.label(.{ .id = "view", .text = "sample" }),
            ),
            tuile.label(.{ .id = "view", .text = "[h] Prev | [l] Next | [j] Down | [k] Up | [q] Quit" }),
        });
    }

    pub fn fetch_chapter(self: *TuiReaderPage, novel_id: []const u8, number: usize) !void {
        if (self.ctx.chapter) |chapter| chapter.deinit(self.ctx.gpa);

        if (try Chapter.get(self.pool, self.ctx.gpa, novel_id, number)) |chapter| {
            // We found a cached chapter so just save it into our state
            self.ctx.chapter = chapter;
        } else {
            // We don't have the chapter locally, so try to fetch it
            // for now to speed it up return sample
            self.ctx.chapter = try self.ctx.provider.sample_chapter(number);
        }

        if (self.ctx.span) |_| self.ctx.span.?.deinit();
        const span = try generateMultilineSpan(self.ctx.arena, self.ctx.chapter.?.lines.items[0..]);
        self.ctx.span = span;
        self.ctx.enabled = true;
    }
};

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
                // TODO: deinit pages
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

        // const chapter = try freewebnovel.fetch("/martial-god-asura-novel", 1);
        // defer chapter.deinit(allocator);

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
        }, pool);
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
                .{ .id = "themed", .theme = ayu() },
                tuile.vertical(.{ .id = "page-container", .layout = .{ .flex = 1 } }, .{
                    try home.render(),
                }),
            ),
        );

        // Global application events
        try tui.addEventHandler(.{
            .handler = globalKeyHandler,
            .payload = &tui,
        });

        // Per page events
        try home.addEventHandler();
        try search.addEventHandler();
        try reader.addEventHandler();

        try tui.run();
    }
};

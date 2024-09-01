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

// TODO:
// - Create context per page as it needs it
// i.e. Home has a struct to impl cb's for radio
// Search has a struct ...
// Reader has a struct
// Then they all have their own event handlers

const TuiHomePage = struct {
    tui: *tuile.Tuile,
    arena: *const Allocator,
    gpa: *const Allocator,
    provider: *const Freewebnovel,

    text: ?[]const u8 = null,

    fn onInputChanged(opt_self: ?*TuiHomePage, value: []const u8) void {
        const self = opt_self.?;
        self.text = value;
        // Autosearch? If it's filtering on local state its fine
    }
};

const TuiSearchPage = struct {
    const Context = struct {
        enabled: bool,
        tui: *tuile.Tuile,
        gpa: Allocator,
        arena: Allocator,

        reader: *TuiReaderPage,
    };

    ctx: Context,
    text: ?[]const u8 = null,

    pub fn onInputChanged(opt_self: ?*TuiSearchPage, value: []const u8) void {
        const self = opt_self.?;
        self.text = value;
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
                const novels = provider.search(text) catch unreachable;
                logz.debug().ctx("tui.search.onSearch").string("msg", "Searched for").string("text", text).log();
                // errdefer {
                //     for (novels) |novel| {
                //         novel.deinit(self.ctx.gpa);
                //     }
                //     self.ctx.gpa.free(novels);
                // }

                // Need to reset the list since we don't have access to the internal.allocator
                // to append more items to the list
                logz.debug().ctx("tui.search.onSearch").string("msg", "Destroying list").log();
                list.destroy();
                logz.debug().ctx("tui.search.onSearch").string("msg", "Destroyed list").log();

                var items = std.ArrayListUnmanaged(tuile.List.Item){};
                defer items.deinit(self.ctx.arena);

                logz.debug().ctx("tui.search.onSearch").string("msg", "Appending novels").log();
                for (novels) |novel| {
                    items.append(self.ctx.arena, .{
                        .label = tuile.label(.{ .text = self.ctx.arena.dupe(u8, novel.title) catch unreachable }) catch unreachable,
                        .value = @ptrCast(@alignCast(@constCast(&novel))),
                        // .value = @ptrCast(@constCast(&novel)),
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

    pub fn onSelect(opt_self: ?*TuiSearchPage) void {
        const self = opt_self.?;
        if (self.text) |text| {
            // Query fwn and save the data to context or append to a list
            _ = text;
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
                    logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "Getting search button").log();
                    const btn = ctx.tui.findByIdTyped(tuile.Button, "search-button") orelse unreachable;
                    logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "Got search button").log();
                    if (btn.focus_handler.focused) {
                        if (btn.on_press) |on_press| {
                            logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "Found focused button and an on_press").log();
                            on_press.call();
                            logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "Called focused button and on_press").log();
                        }
                    }

                    logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "Getting search list").log();
                    const list = ctx.tui.findByIdTyped(tuile.List, "search-list") orelse unreachable;
                    logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "Got search list").log();
                    if (list.focus_handler.focused) {
                        logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "search-list was focused").log();
                        const focused_item = list.items.items[list.selected_index];
                        logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "search-list focused item found").log();
                        if (focused_item.value) |value| {
                            logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "search-list focused item has value").fmt("value", "{any}", .{value}).log();
                            // TODO:
                            // Go to chapter 1 of this novel
                            // check if we have a version locally, if we do go to current chapter instead
                            // const v: *[]const u8 = @ptrCast(@alignCast(value));
                            // const v: []const u8 = @as([*]u8, @ptrCast(value))[0..20];
                            const novel: *Novel = @ptrCast(@alignCast(value));

                            logz.debug().ctx("tui.search.onKeyHandler.enter").string("novel_url", novel.url).log();
                            logz.debug().ctx("tui.search.onKeyHandler.enter").fmt("novel", "{any}", .{novel}).log();

                            // Toggle page from search to novel
                            ctx.enabled = false;

                            logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "disabled search page").log();
                            ctx.reader.ctx.chapter = try ctx.reader.ctx.provider.sample_chapter(10);
                            logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "downloaded new chapter and set to reader ctx").log();
                            ctx.reader.ctx.span.deinit();
                            logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "deinit reader span").log();
                            const span = try generateMultilineSpan(ctx.arena, ctx.reader.ctx.chapter.lines.items[0..]);
                            logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "created new span for reader").log();
                            ctx.reader.ctx.span = span;
                            logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "saved span to reader ctx").log();
                            // TODO: setSpan but if it wasn't enabled it wouldn't exist yet
                            ctx.reader.ctx.enabled = true;
                            logz.debug().ctx("tui.search.onKeyHandler.enter").string("msg", "enabled reader page").log();
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
        if (!self.ctx.enabled) return tuile.stack_layout(.{}, &.{});

        return try tuile.vertical(.{ .layout = .{ .flex = 1 } }, .{
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
                        .id = "search-button",
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
};

const TuiReaderPage = struct {
    const Context = struct {
        tui: *tuile.Tuile,
        gpa: Allocator,
        arena: Allocator,
        provider: Freewebnovel,

        enabled: bool,
        chapter: Chapter,
        span: tuile.Span,
        offset: isize = 0,

        fn scroll(self: *Context, size: isize) !void {
            // If a span exists, then we have everything init already to setup
            const view = self.tui.findByIdTyped(tuile.Label, "view") orelse unreachable;
            const chapter = self.chapter;
            const new_offset: isize = self.offset + size;
            if (new_offset >= 0 and new_offset < chapter.lines.items.len) {
                self.span.deinit();
                const span = try generateMultilineSpan(self.arena, chapter.lines.items[@intCast(new_offset)..]);
                self.span = span;
                self.offset = new_offset;
                try view.setSpan(self.span.view());
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
            self.chapter.deinit(self.gpa);
            self.chapter = try self.provider.sample_chapter(number);
            self.offset = 0;
            self.span.deinit();
            const span = try generateMultilineSpan(self.arena, self.chapter.lines.items[0..]);
            self.span = span;
            try view.setSpan(self.span.view());
        }

        pub fn prevChapter(self: *Context) !tuile.events.EventResult {
            try self.changeChapter(self.chapter.number - 1);

            return .consumed;
        }

        pub fn nextChapter(self: *Context) !tuile.events.EventResult {
            try self.changeChapter(self.chapter.number + 1);

            return .consumed;
        }
    };

    ctx: Context,

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

    pub fn new(cfg: struct {
        tui: *tuile.Tuile,
        gpa: Allocator,
        arena: Allocator,
    }) !TuiReaderPage {
        const provider = Freewebnovel.init(cfg.gpa);
        // var span = tuile.Span.init(cfg.arena);

        var chapter = try provider.sample_chapter(30);
        defer chapter.deinit(cfg.gpa);

        const ctx = .{
            .tui = cfg.tui,
            .arena = cfg.arena,
            .gpa = cfg.gpa,
            .enabled = true,
            .provider = provider,
            .chapter = try provider.sample_chapter(30),
            .span = try generateMultilineSpan(cfg.arena, chapter.lines.items[0..]),
        };

        return .{
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *TuiReaderPage) void {
        self.ctx.chapter.deinit(self.ctx.gpa);
        self.ctx.span.deinit();
    }

    pub fn render(self: *TuiReaderPage) !*tuile.StackLayout {
        if (!self.ctx.enabled) return tuile.stack_layout(.{}, &.{});

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
                tuile.label(.{ .id = "view", .span = self.ctx.span.view() }),
                // tuile.label(.{ .id = "view", .text = "sample" }),
            ),
            tuile.label(.{ .id = "view", .text = "[h] Prev | [l] Next | [j] Down | [k] Up | [q] Quit" }),
        });
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
        _ = pool;
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

        var reader = try TuiReaderPage.new(.{
            .tui = &tui,
            .gpa = allocator,
            .arena = arena_allocator,
        });
        defer reader.deinit();

        var search = TuiSearchPage{
            .ctx = .{
                .enabled = true,
                .tui = &tui,
                .gpa = allocator,
                .arena = arena_allocator,
                .reader = &reader,
            },
        };

        reader.ctx.enabled = false;
        search.ctx.enabled = true;

        try tui.add(
            tuile.themed(
                .{ .id = "themed", .theme = ayu() },
                tuile.vertical(.{ .layout = .{ .flex = 1 } }, .{
                    try reader.render(),
                    try search.render(),
                }),
            ),
        );

        // Global application events
        try tui.addEventHandler(.{
            .handler = globalKeyHandler,
            .payload = &tui,
        });

        // Per page events
        try reader.addEventHandler();
        try search.addEventHandler();

        try tui.run();
    }
};

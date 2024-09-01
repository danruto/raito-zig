const std = @import("std");
const tuile = @import("tuile");
const zqlite = @import("zqlite");

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

const TuiPage = enum {
    home,
    search,
    reader,
};

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
    tui: *tuile.Tuile,
    arena: *const Allocator,
    gpa: *const Allocator,
    provider: *const Freewebnovel,

    text: ?[]const u8 = null,

    fn onInputChanged(opt_self: ?*TuiSearchPage, value: []const u8) void {
        const self = opt_self.?;
        self.text = value;
    }

    fn onSearch(opt_self: ?*TuiSearchPage) void {
        const self = opt_self.?;
        if (self.text) |text| {
            // Query fwn and save the data to context or append to a list
            _ = text;
        }
    }
};

const TuiReaderPage = struct {
    const Context = struct {
        tui: *tuile.Tuile,
        gpa: Allocator,
        arena: Allocator,
        provider: Freewebnovel,

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

        return switch (event) {
            .char => |char| switch (char) {
                'j' => try ctx.scrollDown(),
                'k' => try ctx.scrollUp(),
                'h' => try ctx.prevChapter(),
                'l' => try ctx.nextChapter(),

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
            tuile.label(.{ .id = "view", .text = "[h] Prev | [l] Next" }),
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
            .interactive = color("#D2A6FF"),
            .focused = color("#95E6CB"),
            .borders = color("#131721"),
            .solid = color("#39BAE6"),
        };
    }

    pub fn stopOnQ(ptr: ?*anyopaque, event: tuile.events.Event) !tuile.events.EventResult {
        var tui: *tuile.Tuile = @ptrCast(@alignCast(ptr));
        switch (event) {
            .char => |char| if (char == 'q') {
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
            .arena = arena_allocator,
            .gpa = allocator,
        });
        defer reader.deinit();

        try tui.add(
            tuile.themed(
                .{ .id = "themed", .theme = ayu() },
                try reader.render(),
            ),
        );

        // Global application events
        try tui.addEventHandler(.{
            .handler = stopOnQ,
            .payload = &tui,
        });

        // Per page events
        try reader.addEventHandler();

        try tui.run();
    }
};

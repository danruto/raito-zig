const std = @import("std");
const tuile = @import("tuile");
const zqlite = @import("zqlite");
const logz = @import("logz");

const Freewebnovel = @import("../fwn.zig");
const Chapter = @import("../chapter.zig");
const Novel = @import("../novel.zig");

const Allocator = std.mem.Allocator;
const PageContext = @import("page.zig").PageContext;
const color = tuile.color;

pub const TuiReaderPage = @This();

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

const Context = struct {
    tui: *tuile.Tuile,
    gpa: Allocator,
    arena: Allocator,
    pool: *zqlite.Pool,

    enabled: bool,
    chapter: ?Chapter = null,
    span: ?tuile.Span = null,
    offset: isize = 0,

    fn reset_span(self: *Context) !void {
        const view = self.tui.findByIdTyped(tuile.Label, "reader-view") orelse unreachable;
        const chapter = self.chapter orelse unreachable;
        self.span.?.deinit();
        const span = try generateMultilineSpan(self.arena, chapter.lines.items[@intCast(self.offset)..]);
        self.span = span;
        try view.setSpan(self.span.?.view());
    }

    fn reset_span_safe(self: *Context) !void {
        const chapter = self.chapter orelse unreachable;
        var had_span = false;
        if (self.span) |_| {
            logz.debug().ctx("TuiReaderPage.Context.reset_span_safe").string("msg", "span existed, deiniting").log();
            self.span.?.deinit();
            had_span = true;
        }
        const span = try generateMultilineSpan(self.arena, chapter.lines.items[@intCast(self.offset)..]);
        self.span = span;

        if (self.tui.findByIdTyped(tuile.Label, "reader-view")) |view| {
            logz.debug().ctx("TuiReaderPage.Context.reset_span_safe").string("msg", "reader-view exists").log();
            if (had_span) {
                logz.debug().ctx("TuiReaderPage.Context.reset_span_safe").string("msg", "span existed, setting new one").log();
                try view.setSpan(self.span.?.view());
            }
        }
    }

    fn reset_title_safe(self: *Context) !void {
        const chapter = self.chapter orelse unreachable;
        if (self.tui.findByIdTyped(tuile.Label, "reader-title")) |label| {
            try label.setText(chapter.title);
        }
    }

    fn scroll(self: *Context, size: isize) !void {
        // If a span exists, then we have everything init already to setup
        const chapter = self.chapter orelse unreachable;
        const new_offset: isize = self.offset + size;
        if (new_offset >= 0 and new_offset < chapter.lines.items.len) {
            self.offset = new_offset;
            try self.reset_span();
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

        logz.debug().ctx("TuiReaderPage.Context.change_chapter").string("msg", "changing chapter to").int("number", number).log();
        try self.fetch_chapter(self.chapter.?.novel_id, number);
    }

    pub fn prevChapter(self: *Context) !tuile.events.EventResult {
        try self.changeChapter(self.chapter.?.number - 1);

        return .consumed;
    }

    pub fn nextChapter(self: *Context) !tuile.events.EventResult {
        try self.changeChapter(self.chapter.?.number + 1);

        return .consumed;
    }

    pub fn fetch_chapter(self: *Context, novel_id: []const u8, number: usize) !void {
        self.offset = 0;

        if (try Chapter.get(self.pool, self.gpa, novel_id, number)) |chapter| {
            if (self.chapter) |c| c.deinit(self.gpa);
            // We found a cached chapter so just save it into our state
            self.chapter = chapter;

            logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "found a cached chapter").string("novel", novel_id).int("number", number).log();
        } else {
            const provider = Freewebnovel.init(self.gpa);
            if (try Novel.get(self.pool, self.gpa, novel_id)) |novel| {
                if (self.chapter) |c| c.deinit(self.gpa);
                self.chapter = try provider.fetch(novel.slug, number);
                logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "found a cached novel to fetch new chapter").string("novel", novel_id).int("number", number).log();
            } else {
                const novel = try provider.get_novel(novel_id);
                if (self.chapter) |c| c.deinit(self.gpa);
                self.chapter = try provider.fetch(novel.slug, number);
                logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "fetched new novel and chapter").string("novel", novel_id).int("number", number).log();
            }
        }

        try self.reset_span_safe();
        try self.reset_title_safe();
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

pub fn create(ctx_: Context) !TuiReaderPage {
    return .{ .ctx = ctx_ };
}

pub fn destroy(self: *TuiReaderPage) void {
    if (self.ctx.chapter) |chapter| chapter.deinit(self.ctx.gpa);
    if (self.ctx.span) |_| self.ctx.span.?.deinit();
}

pub fn render(self: *TuiReaderPage) !*tuile.StackLayout {
    return tuile.vertical(.{
        .layout = .{ .flex = 1 },
    }, .{
        tuile.block(.{
            .id = "block",
            .border = tuile.Border.all(),
            .border_type = .rounded,
            .layout = .{ .flex = 1 },
        }, tuile.vertical(.{ .id = "reader-container", .layout = .{ .alignment = .{ .h = .center, .v = .top } } }, .{
            tuile.label(.{ .id = "reader-title", .text = if (self.ctx.chapter) |chapter| chapter.title else null }),
            tuile.label(.{ .id = "reader-view", .span = if (self.ctx.span) |span| span.view() else null, .text = if (self.ctx.span) |_| null else "Chapter Unavailable", .layout = .{ .min_width = self.ctx.tui.window_size.x } }),
        })),
        tuile.label(.{ .id = "reader-status-bar", .text = "[h] Prev | [l] Next | [j] Down | [k] Up | [q] Quit" }),
    });
}

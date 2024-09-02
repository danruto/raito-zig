const std = @import("std");
const tuile = @import("tuile");
const zqlite = @import("zqlite");
const logz = @import("logz");

const Freewebnovel = @import("../fwn.zig").Freewebnovel;
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
    provider: Freewebnovel,

    enabled: bool,
    chapter: ?Chapter = null,
    span: ?tuile.Span = null,
    offset: isize = 0,

    fn scroll(self: *Context, size: isize) !void {
        // If a span exists, then we have everything init already to setup
        const view = self.tui.findByIdTyped(tuile.Label, "reader-view") orelse unreachable;
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

        const view = self.tui.findByIdTyped(tuile.Label, "reader-view") orelse unreachable;
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
        tuile.block(.{
            .id = "block",
            .border = tuile.Border.all(),
            .border_type = .rounded,
            .layout = .{ .flex = 1 },
        }, tuile.vertical(.{ .id = "reader-container", .layout = .{ .alignment = .{ .h = .center, .v = .top } } }, .{
            tuile.label(.{ .id = "reader-title", .text = if (self.ctx.chapter) |chapter| chapter.title else null }),
            tuile.label(.{ .id = "reader-view", .span = if (self.ctx.span) |span| span.view() else null, .layout = .{ .min_width = self.ctx.tui.window_size.x } }),
        })),
        tuile.label(.{ .id = "reader-status-bar", .text = "[h] Prev | [l] Next | [j] Down | [k] Up | [q] Quit" }),
    });
}

pub fn fetch_chapter(self: *TuiReaderPage, novel_id: []const u8, number: usize) !void {
    if (self.ctx.chapter) |chapter| chapter.deinit(self.ctx.gpa);

    if (try Chapter.get(self.pool, self.ctx.gpa, novel_id, number)) |chapter| {
        // We found a cached chapter so just save it into our state
        self.ctx.chapter = chapter;
    } else {
        // TODO: implement it to use real fetch
        // We don't have the chapter locally, so try to fetch it
        // for now to speed it up return sample
        self.ctx.chapter = try self.ctx.provider.sample_chapter(number);
    }

    if (self.ctx.span) |_| self.ctx.span.?.deinit();
    const span = try generateMultilineSpan(self.ctx.arena, self.ctx.chapter.?.lines.items[0..]);
    self.ctx.span = span;
    self.ctx.enabled = true;
}

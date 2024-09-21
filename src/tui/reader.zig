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

const status_bar_text = "[h] Prev | [l] Next | [j] Down | [k] Up | [q] Quit";

pub const TuiReaderPage = @This();

// TODO: move this to the theme instead
const text_color = color("#bfbdb6");

const line_padding = 20;

fn onChangeChapterInputChanged(opt_self: ?*Context, value: []const u8) void {
    const self = opt_self.?;
    self.text = value;
}

const Context = struct {
    tui: *tuile.Tuile,
    gpa: Allocator,
    arena: Allocator,
    pool: *zqlite.Pool,

    enabled: bool,
    novel_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    chapter: ?usize = null,

    lines: std.ArrayListUnmanaged([]const u8),
    span: ?tuile.Span = null,
    offset: isize = 0,

    text: ?[]const u8 = null,

    fn generateMultilineSpan(self: *Context) !tuile.Span {
        var span = tuile.Span.init(self.arena);

        for (self.lines.items[@intCast(self.offset)..]) |line| {
            try span.append(.{ .style = .{ .fg = text_color }, .text = line });
            try span.appendPlain("\n");
        }

        return span;
    }

    fn process_chapter(self: *Context, chapter: Chapter) !void {
        for (self.lines.items) |line| self.gpa.free(line);
        self.lines.clearRetainingCapacity();
        self.chapter = chapter.number;

        const line_max = self.tui.window_size.x - line_padding;
        for (chapter.lines.items) |line| {
            if (line.len > line_max) {
                // Calculate the amount of chunks required
                const chunks_as_f32 = @as(f32, @floatFromInt(line.len / line_max));
                const chunks_normalised: usize = @intFromFloat(@ceil(chunks_as_f32));
                const chunks_required = chunks_normalised + 1;
                logz.debug()
                    .ctx("tui.reader.context.process_chapter")
                    .string("msg", "calculating chunks for line")
                    .string("line", line)
                    .int("line.len", line.len)
                    .int("line_max", line_max)
                    .float("chunks_as_f32", chunks_as_f32)
                    .int("chunks_normalised", chunks_normalised)
                    .int("chunks_required", chunks_required)
                    .log();

                var start: usize = 0;
                var end: usize = line_max;

                for (0..chunks_required) |ii| {
                    var chunk_end = end;

                    // Find the first " " rune from end to keep word breaks from happening
                    while (chunk_end > 0) : (chunk_end -= 1) {
                        if (line[chunk_end] == ' ') {
                            end = @min(chunk_end, line.len - 1);
                            break;
                        }
                    }

                    logz.debug()
                        .ctx("tui.reader.generateMutlilineSpan")
                        .string("msg", "building chunk with")
                        .int("current_chunk", ii)
                        .int("start", start)
                        .int("end", end)
                        .int("chunk_end", chunk_end)
                        .string("chunk_text", line[start..end])
                        .log();

                    // Save chunk
                    try self.lines.append(self.gpa, try self.gpa.dupe(u8, line[start..end]));

                    // Update our positions
                    start = end;
                    end = @min(end + line_max, line.len - 1);
                }
            } else {
                logz.debug()
                    .ctx("tui.reader.context.process_chapter")
                    .string("msg", "line is within line_max")
                    .string("line", line)
                    .log();

                try self.lines.append(self.gpa, try self.gpa.dupe(u8, line));
            }

            // Append new lines after each block
            try self.lines.append(self.gpa, "");
        }
    }

    fn reset_span(self: *Context) !void {
        const view = self.tui.findByIdTyped(tuile.Label, "reader-view") orelse unreachable;
        self.span.?.deinit();
        const span = try self.generateMultilineSpan();
        self.span = span;
        try view.setSpan(self.span.?.view());
    }

    fn reset_span_safe(self: *Context) !void {
        if (self.span) |_| {
            logz.debug().ctx("TuiReaderPage.Context.reset_span_safe").string("msg", "span existed, deiniting").log();
            self.span.?.deinit();
        }

        logz.debug().ctx("TuiReaderPage.Context.reset_span_safe").string("msg", "resetting span").log();
        const span = try self.generateMultilineSpan();
        self.span = span;
        logz.debug().ctx("TuiReaderPage.Context.reset_span_safe").string("msg", "reset span").log();

        if (self.tui.findByIdTyped(tuile.Label, "reader-view")) |view| {
            logz.debug().ctx("TuiReaderPage.Context.reset_span_safe").string("msg", "reader-view exists, so setting span").log();
            try view.setSpan(self.span.?.view());
        } else {
            logz.debug().ctx("TuiReaderPage.Context.reset_span_safe").string("msg", "reader-view does not exist yet").log();
        }
    }

    fn reset_title_safe(self: *Context) !void {
        if (self.tui.findByIdTyped(tuile.Label, "reader-title")) |label| {
            const title = self.title orelse unreachable;
            try label.setText(title);
        }
    }

    fn scroll(self: *Context, size: isize) !void {
        const new_offset: isize = self.offset + size;
        // Give it 4 lines of buffer at the end
        if (new_offset >= 0 and new_offset < self.lines.items.len - 4) {
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
        try self.fetch_chapter(self.novel_id.?, number);
    }

    pub fn prevChapter(self: *Context) !tuile.events.EventResult {
        try self.changeChapter(self.chapter.? - 1);

        return .consumed;
    }

    pub fn nextChapter(self: *Context) !tuile.events.EventResult {
        try self.changeChapter(self.chapter.? + 1);

        return .consumed;
    }

    pub fn fetch_chapter(self: *Context, novel_id: []const u8, number: usize) !void {
        logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "fetching chapter").string("novel", novel_id).int("number", number).log();

        self.offset = 0;

        // Only save novel_id if it is different
        if (self.novel_id) |nid| {
            if (std.mem.eql(u8, nid, novel_id)) {
                // TODO: When it is the same novel but different pointers will need free

                // When its equal do nothing
            } else {
                self.gpa.free(nid);
                self.novel_id = try self.gpa.dupe(u8, novel_id);
            }
        } else {
            self.novel_id = try self.gpa.dupe(u8, novel_id);
        }

        if (try Chapter.get(self.pool, self.gpa, novel_id, number)) |chapter| {
            defer chapter.destroy(self.gpa);
            if (self.title) |title| self.gpa.free(title);
            self.title = try self.gpa.dupe(u8, chapter.title);

            try self.process_chapter(chapter);

            // We found a cached chapter so just save it into our state
            if (try Novel.get(self.pool, self.gpa, chapter.novel_id)) |novel| {
                // Update novel current chapter
                var n = try novel.clone(self.gpa);
                n.chapter = number;
                try n.upsert(self.pool);

                n.destroy(self.gpa);
                novel.destroy(self.gpa);
            }

            logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "found a cached chapter").string("novel", chapter.novel_id).int("number", number).log();
        } else {
            const provider = Freewebnovel.init(self.gpa);
            var novel: ?Novel = null;

            if (try Novel.get(self.pool, self.gpa, novel_id)) |novel_| {
                logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "found a cached novel to fetch new chapter").string("novel", novel_.id).int("number", number).log();
                novel = novel_;
            } else {
                novel = try provider.get_novel(novel_id);
                logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "fetching new novel for chapter").string("novel", novel.?.id).int("number", number).log();
            }

            if (novel) |novel_| {
                const chapter = try provider.fetch(novel_, number);
                defer chapter.destroy(self.gpa);
                if (self.title) |title| self.gpa.free(title);
                self.title = try self.gpa.dupe(u8, chapter.title);
                try chapter.upsert(self.pool, self.gpa);

                try self.process_chapter(chapter);

                // Update novel current chapter
                var n = try novel_.clone(self.gpa);
                n.chapter = number;
                try n.upsert(self.pool);
                n.destroy(self.gpa);
                novel_.destroy(self.gpa);
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
            'c' => {
                // Render an input for changing chapter
                // If it already exists, then delete it
                if (ctx.tui.findByIdTyped(tuile.StackLayout, "reader-page")) |view| {
                    if (ctx.tui.findByIdTyped(tuile.Input, "reader-change-chapter")) |input| {
                        _ = try view.removeChild(input.widget());
                        ctx.text = null;
                    } else {
                        // TODO: horz, label + input?
                        try view.addChild(tuile.input(.{
                            .id = "reader-change-chapter",
                            .placeholder = "chapter number",
                            .on_value_changed = .{
                                .cb = @ptrCast(&onChangeChapterInputChanged),
                                .payload = ctx,
                            },
                        }));
                    }

                    return .consumed;
                }

                return .ignored;
            },
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
            .Enter => {
                // TODO: Handle change chapter
                if (ctx.tui.findByIdTyped(tuile.Input, "reader-change-chapter")) |input| {
                    if (ctx.tui.findByIdTyped(tuile.StackLayout, "reader-page")) |view| {
                        if (ctx.text) |text| {

                            // try to convert the text to usize
                            const number = std.fmt.parseUnsigned(usize, text, 10) catch ctx.chapter.?;
                            try ctx.fetch_chapter(ctx.novel_id.?, number);
                            _ = try view.removeChild(input.widget());
                            ctx.text = null;

                            return .consumed;
                        }
                    }
                }
                return .ignored;
            },
            .Escape => {
                if (ctx.tui.findByIdTyped(tuile.Input, "reader-change-chapter")) |input| {
                    if (ctx.tui.findByIdTyped(tuile.StackLayout, "reader-page")) |view| {
                        _ = try view.removeChild(input.widget());
                        ctx.text = null;

                        return .consumed;
                    }
                }

                return .ignored;
            },

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
    if (self.ctx.title) |title| self.ctx.gpa.free(title);
    if (self.ctx.novel_id) |novel_id| self.ctx.gpa.free(novel_id);
    if (self.ctx.span) |_| self.ctx.span.?.deinit();
    for (self.ctx.lines.items) |line| self.ctx.gpa.free(line);
    self.ctx.lines.deinit(self.ctx.gpa);
}

pub fn render(self: *TuiReaderPage) !*tuile.StackLayout {
    return tuile.vertical(.{
        .id = "reader-page",
        .layout = .{ .flex = 1 },
    }, .{
        tuile.block(.{
            .id = "block",
            .border = tuile.Border.all(),
            .border_type = .rounded,
            .layout = .{ .flex = 1 },
        }, tuile.vertical(.{ .id = "reader-container", .layout = .{ .alignment = .{ .h = .center, .v = .top } } }, .{
            tuile.label(.{ .id = "reader-title", .text = if (self.ctx.title) |title| title else null }),
            tuile.label(.{
                .id = "reader-view",
                .span = if (self.ctx.span) |span| span.view() else null,
                .text = if (self.ctx.span) |_| null else "Chapter Unavailable",
                .layout = .{
                    .min_width = self.ctx.tui.window_size.x - line_padding,
                    .max_width = self.ctx.tui.window_size.x - line_padding,
                },
            }),
        })),
        tuile.label(.{ .id = "reader-status-bar", .text = status_bar_text }),
    });
}

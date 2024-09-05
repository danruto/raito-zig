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

fn generateMultilineSpan(allocator: Allocator, lines: [][]const u8, max_line_length: usize) !tuile.Span {
    var span = tuile.Span.init(allocator);

    for (lines) |line| {
        // TODO: If the line is too long push multiple spans?
        // Split line into multple parts if it is too long
        const adjusted_max = max_line_length - 20;
        if (line.len > adjusted_max) {
            // Calculate the amount of chunks required
            const chunks_as_f32 = @as(f32, @floatFromInt(line.len / adjusted_max));
            const chunks_normalised: usize = @intFromFloat(@ceil(chunks_as_f32));
            const chunks_required = chunks_normalised + 1;
            logz.debug()
                .ctx("tui.reader.generateMutlilineSpan")
                .string("msg", "calculating chunks for line")
                .string("line", line)
                .int("line.len", line.len)
                .int("adjusted max", adjusted_max)
                .int("max_line_length", max_line_length)
                .float("chunks_as_f32", chunks_as_f32)
                .int("chunks_normalised", chunks_normalised)
                .int("chunks_required", chunks_required)
                .log();

            // + 1 for the rest of the text
            // TODO: Peek iters for word breaks
            var start: usize = 0;
            var end: usize = adjusted_max;
            for (0..chunks_required) |ii| {
                var chunk_end = end;
                // var end = @min((ii + 1) * adjusted_max, line.len);

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

                try span.append(.{ .style = .{ .fg = text_color }, .text = line[start..end] });
                try span.appendPlain("\n");

                // Update our new pointer positions for start
                start = end;
                end = @min(end + adjusted_max, line.len - 1);
            }
        } else {
            logz.debug()
                .ctx("tui.reader.generateMutlilineSpan")
                .string("msg", "line is within adjusted_max")
                .string("line", line)
                .log();
            try span.append(.{ .style = .{ .fg = text_color }, .text = line });
            try span.appendPlain("\n");
        }

        // Add another newline to give some spacing to the text for readability
        try span.appendPlain("\n\n");
    }

    return span;
}

fn generateMultilineSpanUnmanaged(allocator: Allocator, lines: [][]const u8) !tuile.SpanUnmanaged {
    var span = tuile.SpanUnmanaged{};

    for (lines) |line| {
        try span.append(allocator, .{ .style = .{ .fg = text_color }, .text = try std.mem.concat(allocator, u8, &.{ line, "\n" }) });
        // Add another newline to give some spacing to the text for readability
        try span.appendPlain(allocator, "\n");
    }

    return span;
}

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
    chapter: ?Chapter = null,
    span: ?tuile.Span = null,
    offset: isize = 0,

    text: ?[]const u8 = null,

    fn reset_span(self: *Context) !void {
        const view = self.tui.findByIdTyped(tuile.Label, "reader-view") orelse unreachable;
        const chapter = self.chapter orelse unreachable;
        self.span.?.deinit();
        const span = try generateMultilineSpan(self.arena, chapter.lines.items[@intCast(self.offset)..], self.tui.window_size.x);
        self.span = span;
        try view.setSpan(self.span.?.view());
    }

    fn reset_span_safe(self: *Context) !void {
        const chapter = self.chapter orelse unreachable;
        if (self.span) |_| {
            logz.debug().ctx("TuiReaderPage.Context.reset_span_safe").string("msg", "span existed, deiniting").log();
            self.span.?.deinit();
        }

        logz.debug().ctx("TuiReaderPage.Context.reset_span_safe").string("msg", "resetting span").log();
        const span = try generateMultilineSpan(self.arena, chapter.lines.items[@intCast(self.offset)..], self.tui.window_size.x);
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
        logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "fetching chapter").string("novel", novel_id).int("number", number).log();

        self.offset = 0;

        if (try Chapter.get(self.pool, self.gpa, novel_id, number)) |chapter| {
            if (self.chapter) |c| c.deinit(self.gpa);
            // We found a cached chapter so just save it into our state
            self.chapter = chapter;

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
            if (try Novel.get(self.pool, self.gpa, novel_id)) |novel| {
                if (self.chapter) |c| c.deinit(self.gpa);

                logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "found a cached novel to fetch new chapter").string("novel", novel.id).int("number", number).log();
                self.chapter = try provider.fetch(novel, number);

                // Update novel current chapter
                var n = try novel.clone(self.gpa);
                n.chapter = number;
                try n.upsert(self.pool);

                n.destroy(self.gpa);
                novel.destroy(self.gpa);
            } else {
                const novel = try provider.get_novel(novel_id);
                if (self.chapter) |c| c.deinit(self.gpa);

                logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "fetched new novel and chapter").string("novel", novel.id).int("number", number).log();
                self.chapter = try provider.fetch(novel, number);

                var n = try novel.clone(self.gpa);
                n.chapter = number;
                try n.upsert(self.pool);

                n.destroy(self.gpa);

                logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "upserted novel to db").string("novel", novel.id).int("number", number).log();

                novel.destroy(self.gpa);
            }

            if (self.chapter) |chapter| {
                logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "about to insert chapter to db").int("number", number).log();
                try chapter.upsert(self.pool, self.gpa);
                logz.debug().ctx("TuiReaderPage.fetch_chapter").string("msg", "inserted chapter to db").int("number", number).log();
            } else {
                logz.warn().ctx("TuiReaderPage.fetch_chapter").string("msg", "self.chapter somehow invalid").int("number", number).log();
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
                            const number = std.fmt.parseUnsigned(usize, text, 10) catch ctx.chapter.?.number;
                            try ctx.fetch_chapter(ctx.chapter.?.novel_id, number);
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
    if (self.ctx.chapter) |chapter| chapter.deinit(self.ctx.gpa);
    if (self.ctx.span) |_| self.ctx.span.?.deinit();
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
            tuile.label(.{ .id = "reader-title", .text = if (self.ctx.chapter) |chapter| chapter.title else null }),
            tuile.label(.{
                .id = "reader-view",
                .span = if (self.ctx.span) |span| span.view() else null,
                .text = if (self.ctx.span) |_| null else "Chapter Unavailable",
                .layout = .{
                    .min_width = self.ctx.tui.window_size.x - 20,
                    .max_width = self.ctx.tui.window_size.x - 20,
                },
            }),
        })),
        tuile.label(.{ .id = "reader-status-bar", .text = status_bar_text }),
    });
}

const std = @import("std");
const tuile = @import("tuile");

const fwn = @import("fwn.zig");

const Allocator = std.mem.Allocator;
const Theme = tuile.Theme;
const color = tuile.color;

fn generateMultilineSpan(allocator: Allocator, lines: *const std.ArrayList([]const u8)) !tuile.Span {
    var span = tuile.Span.init(allocator);

    for (lines.items) |line| {
        try span.append(.{ .style = .{ .fg = color("#FFFFFF") }, .text = try std.mem.concat(allocator, u8, &.{ line, "\n\n" }) });
    }

    return span;
}

fn generateMultilineSpan2(allocator: Allocator, lines: [][]const u8) !tuile.Span {
    var span = tuile.Span.init(allocator);

    for (lines) |line| {
        try span.append(.{ .style = .{ .fg = color("#FFFFFF") }, .text = try std.mem.concat(allocator, u8, &.{ line, "\n" }) });
        // Add another newline to give some spacing to the text for readability
        try span.append(.{ .style = .{ .fg = color("#FFFFFF") }, .text = "\n" });
    }

    return span;
}

const TuiEventContext = struct {
    tui: *tuile.Tuile,
    lines: *const std.ArrayList([]const u8),
    offset: usize,
    allocator: *const Allocator,
    span: *tuile.Span,

    pub fn scrollDown(self: *TuiEventContext) tuile.events.EventResult {
        if (self.tui.findByIdTyped(tuile.Label, "view")) |view| {
            if (self.offset + 1 < self.lines.items.len) {
                self.*.span.*.deinit();
                var span = try generateMultilineSpan2(self.allocator.*, self.lines.items[self.offset + 1 ..]);
                self.*.span.* = span;
                self.*.offset += 1;
                try view.setSpan(span.view());
            }
        }
        return .consumed;
    }

    pub fn scrollUp(self: *TuiEventContext) tuile.events.EventResult {
        if (self.tui.findByIdTyped(tuile.Label, "view")) |view| {
            if (self.offset > 0) {
                self.*.span.*.deinit();
                var span = try generateMultilineSpan2(self.allocator.*, self.lines.items[self.offset - 1 ..]);
                self.*.span.* = span;
                self.*.offset -= 1;
                try view.setSpan(span.view());
            }
        }
        return .consumed;
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
                tui.stop();
                return .consumed;
            },
            else => {},
        }
        return .ignored;
    }

    pub fn scrollDown(ptr: ?*anyopaque, event: tuile.events.Event) !tuile.events.EventResult {
        var ctx: *TuiEventContext = @ptrCast(@alignCast(ptr));
        switch (event) {
            .char => |char| {
                switch (char) {
                    'j' => {
                        return ctx.scrollDown();
                    },
                    'k' => {
                        return ctx.scrollUp();
                    },

                    else => {},
                }
            },
            .key => |key| {
                switch (key) {
                    .Down => {
                        return ctx.scrollDown();
                    },
                    .Up => {
                        return ctx.scrollUp();
                    },
                    else => {},
                }
            },
            else => {},
        }
        return .ignored;
    }

    pub fn run() !void {
        var tui = try tuile.Tuile.init(.{});
        defer tui.deinit();

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        defer _ = gpa.deinit();

        // const freewebnovel = fwn.Freewebnovel.init(allocator);
        // const chapter = try freewebnovel.fetch("/martial-god-asura-novel", 1);
        // defer chapter.deinit(allocator);

        var chapter: fwn.Chapter = .{
            .title = "",
            .number = 0,
            .lines = std.ArrayList([]const u8).init(allocator),
        };

        try chapter.lines.append("Line 1");
        try chapter.lines.append("Line 2");
        try chapter.lines.append("Line 3");
        try chapter.lines.append("Line 4");
        try chapter.lines.append("Line 5");

        // Create an arena allocator for the spans
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_allocator = arena.allocator();
        defer arena.deinit();

        // var span = try generateMultilineSpan(arena_allocator, &chapter.lines);
        var span = try generateMultilineSpan2(arena_allocator, chapter.lines.items[0..]);

        try tui.add(
            tuile.themed(
                .{ .id = "themed", .theme = ayu() },
                tuile.block(
                    .{
                        .id = "block",
                        .border = tuile.Border.all(),
                        .border_type = .rounded,
                        .layout = .{ .flex = 1 },
                    },
                    tuile.label(.{ .id = "view", .span = span.view() }),
                ),
            ),
        );

        var ctx: TuiEventContext = .{
            .tui = &tui,
            .lines = &chapter.lines,
            .offset = 0,
            .allocator = &arena_allocator,
            .span = &span,
        };

        try tui.addEventHandler(.{
            .handler = stopOnQ,
            .payload = &tui,
        });
        try tui.addEventHandler(.{
            .handler = scrollDown,
            .payload = &ctx,
        });

        try tui.run();
    }
};

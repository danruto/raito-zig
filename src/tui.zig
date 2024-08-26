const tuile = @import("tuile");

const Theme = tuile.Theme;
const color = tuile.color;

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
    pub fn run() !void {
        var tui = try tuile.Tuile.init(.{});
        defer tui.deinit();

        try tui.add(
            tuile.themed(
                .{ .id = "themed", .theme = ayu() },
                tuile.block(
                    .{
                        .border = tuile.Border.all(),
                        .border_type = .rounded,
                        .layout = .{ .flex = 1 },
                    },
                    tuile.label(.{ .text = "Hello World!" }),
                ),
            ),
        );

        try tui.run();
    }
};

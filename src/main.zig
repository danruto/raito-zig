const std = @import("std");
const rem = @import("rem");

const css_parser = @import("css_parser.zig");
const tui = @import("tui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    @setEvalBranchQuota(100000);

    const input = @embedFile("chap.html");
    const decoded_input = &rem.util.utf8DecodeStringComptime(input);

    // Create the DOM in which the parsed Document will be created.
    var dom = rem.Dom{ .allocator = allocator };
    defer dom.deinit();

    // Create the HTML parser.
    var parser = try rem.Parser.init(&dom, decoded_input, allocator, .report, false);
    defer parser.deinit();

    // This causes the parser to read the input and produce a Document.
    try parser.run();

    // `errors` returns the list of parse errors that were encountered while parsing.
    // Since we know that our input was well-formed HTML, we expect there to be 0 parse errors.
    const errors = parser.errors();
    std.debug.assert(errors.len == 0);

    // We can now print the resulting Document to the console.
    const document = parser.getDocument();

    if (document.element) |document_element| {
        // Create an arena around the allocator to free once we have completed parsing
        // var arena = std.heap.ArenaAllocator.init(allocator);
        // const arena_allocator = arena.allocator();
        // defer arena.deinit();

        const css_parser_instance = try css_parser.CSSParser.init(allocator, document_element);
        _ = css_parser_instance;

        const css_selector = try css_parser.CSSSelector.init(allocator,
            \\span.chapter
        );
        try css_selector.print();
    }

    try tui.Tui.run();
}

test "test all" {
    @import("std").testing.refAllDecls(@This());
}

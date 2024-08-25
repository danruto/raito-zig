const std = @import("std");
const rem = @import("rem");

const css_parser = @import("css_parser.zig");

fn old() !void {

    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // don't forget to flush!

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // This is the text that will be read by the parser.
    // Since the parser accepts Unicode codepoints, the text must be decoded before it can be used.
    // const input = "<!doctype html><html><h1 style=bold>Your text goes here!</h1>";
    const input = @embedFile("chap.html");
    @setEvalBranchQuota(100000);
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
    try rem.util.printDocument(stdout_file, document, &dom, allocator);

    // css selector subset
    // scan until we find first parent if possible
    // keep adding nodes until we find children unless > is specified
    // if no children found so nothing matches, discard tree up until
    // the first match

    const ConstElementOrCharacterData = union(enum) {
        element: *const rem.Dom.Element,
        cdata: *const rem.Dom.CharacterData,
    };
    var node_stack = std.ArrayListUnmanaged(struct { node: ConstElementOrCharacterData, depth: usize }){};
    defer node_stack.deinit(allocator);

    if (document.element) |document_element| {
        try node_stack.append(allocator, .{ .node = .{ .element = document_element }, .depth = 1 });
    }

    while (node_stack.items.len > 0) {
        const item = node_stack.pop();

        switch (item.node) {
            .element => |e| {
                switch (e.element_type) {
                    .html_h1 => {
                        const num_attributes = e.numAttributes();
                        if (num_attributes > 0) {
                            const attribute_slice = e.attributes.slice();
                            var i: u32 = 0;
                            while (i < num_attributes) : (i += 1) {
                                const key = attribute_slice.items(.key)[i];
                                const value = attribute_slice.items(.value)[i];

                                if (key.prefix == .none) {
                                    std.debug.print("prefix: none -> {s}: {s}\n", .{ key.local_name, value });

                                    // Keep when it has attr class=tit
                                    if (std.mem.eql(u8, key.local_name, "class") and std.mem.eql(u8, value, "tit")) {
                                        // Save the child a tag

                                        // If it has children, keep it until we find what we are scanning for
                                        var num_children = e.children.items.len;
                                        while (num_children > 0) : (num_children -= 1) {
                                            switch (e.children.items[num_children - 1]) {
                                                .element => |ce| {
                                                    if (ce.element_type == .html_a) {
                                                        // const node = ConstElementOrCharacterData{ .element = ce };
                                                        // try node_stack.append(allocator, .{ .node = node, .depth = item.depth + 1 });

                                                        const child_num_attributes = ce.numAttributes();
                                                        if (child_num_attributes > 0) {
                                                            const child_attribute_slice = ce.attributes.slice();
                                                            var child_i: u32 = 0;
                                                            while (child_i < child_num_attributes) : (child_i += 1) {
                                                                const child_key = child_attribute_slice.items(.key)[child_i];
                                                                const child_value = child_attribute_slice.items(.value)[child_i];

                                                                if (key.prefix == .none) {
                                                                    std.debug.print("\tprefix: none -> {s}: {s}\n", .{ child_key.local_name, child_value });
                                                                }
                                                            }
                                                        }
                                                    }
                                                },
                                                else => {},
                                            }
                                        }
                                    }
                                } else {
                                    std.debug.print("prefix: some -> {s}: {s}\n", .{ @tagName(key.prefix), value });
                                }
                            }
                        }
                    },
                    // .html_a => {
                    //     const num_attributes = e.numAttributes();
                    //     if (num_attributes > 0) {
                    //         const attribute_slice = e.attributes.slice();
                    //         var i: u32 = 0;
                    //         while (i < num_attributes) : (i += 1) {
                    //             const key = attribute_slice.items(.key)[i];
                    //             const value = attribute_slice.items(.value)[i];

                    //             if (key.prefix == .none) {
                    //                 std.debug.print("prefix: none -> {s}: {s}\n", .{ key.local_name, value });
                    //             } else {
                    //                 std.debug.print("prefix: some -> {s}: {s}\n", .{ @tagName(key.prefix), value });
                    //             }
                    //         }
                    //     }
                    // },
                    else => {
                        // If it has children, keep it until we find what we are scanning for
                        var num_children = e.children.items.len;
                        while (num_children > 0) : (num_children -= 1) {
                            switch (e.children.items[num_children - 1]) {
                                .element => |ce| {
                                    const node = ConstElementOrCharacterData{ .element = ce };

                                    try node_stack.append(allocator, .{ .node = node, .depth = item.depth + 1 });
                                },
                                else => {},
                            }
                        }
                    },
                }
            },
            else => {},
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const input = @embedFile("chap.html");
    @setEvalBranchQuota(100000);
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
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_allocator = arena.allocator();
        defer arena.deinit();

        const css_parser_instance = try css_parser.init(arena_allocator, document_element);
        _ = css_parser_instance;

        const css_selector = try css_parser.CSSSelector.init(arena_allocator,
            \\span.chapter
        );
        try css_selector.print();
    }

    try old();
}

test "test all" {
    @import("std").testing.refAllDecls(@This());
}

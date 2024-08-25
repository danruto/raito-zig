const std = @import("std");
const rem = @import("rem");

const Allocator = std.mem.Allocator;

const CSSParser = @This();

const ConstElementOrCharacterData = union(enum) {
    element: *const rem.Dom.Element,
    cdata: *const rem.Dom.CharacterData,
};

const NodeData =
    struct { node: ConstElementOrCharacterData, depth: usize };

allocator: Allocator,

node_stack: std.ArrayListUnmanaged(NodeData),

// Caller owns the memory and is responsible for freeing
pub fn init(allocator: Allocator, document_element: *const rem.Dom.Element) !CSSParser {
    var node_stack = std.ArrayListUnmanaged(NodeData){};
    try node_stack.append(allocator, .{ .node = .{ .element = document_element }, .depth = 1 });

    return .{
        .allocator = allocator,
        .node_stack = node_stack,
    };
}

pub const CSSSelectorNode = struct {
    element_type: ?rem.Dom.ElementType,
    id: ?[]const u8,
    attribute_name: ?[]const u8,
    attribute_value: ?[]const u8,
    class_name: ?[]const u8,
    next_is_direct_child: bool,

    fn slice_to_element_type(slice: []const u8) ?rem.Dom.ElementType {
        return if (std.mem.eql(u8, slice, "h1")) {
            return .html_h1;
        } else if (std.mem.eql(u8, slice, "h3")) {
            return .html_h3;
        } else if (std.mem.eql(u8, slice, "em")) {
            return .html_em;
        } else if (std.mem.eql(u8, slice, "span")) {
            return .html_span;
        } else if (std.mem.eql(u8, slice, "div")) {
            return .html_div;
        } else if (std.mem.eql(u8, slice, "p")) {
            return .html_p;
        } else if (std.mem.eql(u8, slice, "a")) {
            return .html_a;
        } else {
            return null;
        };
    }

    pub fn parse(allocator: Allocator, s: []const u8, next_is_direct_child: bool) !CSSSelectorNode {
        _ = allocator;

        // Some local state holders for the node we are processing
        var is_id = false;
        var is_attribute = false;
        var is_attribute_value = false;
        var is_class_name = false;

        var was_space = false;
        var was_quote = false;

        var start: usize = 0;
        var count: usize = 0;

        var node: CSSSelectorNode = .{
            .element_type = null,
            .id = null,
            .attribute_name = null,
            .attribute_value = null,
            .class_name = null,
            .next_is_direct_child = next_is_direct_child,
        };

        for (s, 0..) |rune, ii| {
            switch (rune) {
                // This is the end of the node if we aren't within an attribute
                ' ' => {
                    // Space doesn't always mean end, so count it as part of the value
                    // until we hit something else
                    count += 1;
                },

                // Class name
                '.' => {
                    if (node.element_type == null and count > 0) {
                        node.element_type = slice_to_element_type(s[start .. start + count]);
                    }

                    is_class_name = true;
                    start = ii + 1;
                    count = 0;
                },

                // This is the beginning of an id field
                '#' => {
                    if (node.element_type == null and count > 0) {
                        node.element_type = slice_to_element_type(s[start .. start + count]);
                    }

                    is_id = true;
                    was_space = false;
                    was_quote = false;
                    start = ii + 1;
                    count = 0;
                },

                // This is the start of an attribute selector
                '[' => {
                    if (node.element_type == null and count > 0) {
                        node.element_type = slice_to_element_type(s[start .. start + count]);
                    }

                    is_attribute = true;
                    was_space = false;
                    was_quote = false;
                    start = ii + 1;
                    count = 0;
                },

                // This is the end of an attribute selector
                ']' => {
                    is_attribute = false;
                    is_attribute_value = false;
                    was_space = false;
                    was_quote = false;
                },

                // This signifies the end of the attribute selector name
                '=' => {
                    node.attribute_name = s[start .. start + count];

                    is_attribute_value = true;
                    was_space = false;
                    was_quote = false;
                    start = ii + 1;
                    count = 0;
                },

                // Start or end attribute name or value
                '"' => {
                    if (was_quote) {
                        // This is a matching quote, so we are closing the other one
                        was_quote = false;

                        // Quotes are only valid for attribute values so now we can save it
                        if (is_attribute_value) {
                            node.attribute_value = s[start .. start + count];
                            is_attribute_value = false;
                        }
                    } else {
                        start += 1;
                        count = 0;
                        was_quote = true;
                    }
                },

                // This is parse of the name of whatever type we are currently parsing
                else => {
                    count += 1;
                    was_space = false;
                },
            }
        }

        // One last thing to save to the node metadata
        if (count > 0) {
            // Find out what it is
            if (is_id) {
                node.id = s[start .. start + count];
            } else if (is_class_name) {
                node.class_name = s[start .. start + count];
            } else if (node.element_type == null) {
                node.element_type = slice_to_element_type(s[start .. start + count]);
            }

            // It won't be anything else as they have their own runes that auto close them
        }

        return node;
    }
};

pub const CSSSelector = struct {
    nodes: std.ArrayListUnmanaged(CSSSelectorNode),

    // Our subset says that a new node happens when we have `>`

    // Caller owns the memory and is responsible for freeing
    pub fn init(allocator: Allocator, selector: []const u8) !CSSSelector {
        var nodes = std.ArrayListUnmanaged(CSSSelectorNode){};

        var node_selectors = std.mem.split(u8, selector, ">");

        while (node_selectors.next()) |s| {
            const node = try CSSSelectorNode.parse(allocator, s, true);
            try nodes.append(allocator, node);
        }

        return .{
            .nodes = nodes,
        };
    }

    pub fn print(self: *const CSSSelector) !void {
        for (self.nodes.items) |node| {
            std.debug.print("\nPrinting node.\n", .{});

            if (node.element_type) |et| {
                std.debug.print("\tElement: {any}\n", .{et});
            }
            if (node.id) |id| {
                std.debug.print("\tID: '{s}'\n", .{id});
            }
            if (node.class_name) |cn| {
                std.debug.print("\tClassName: '{s}'\n", .{cn});
            }
            if (node.attribute_name) |an| {
                std.debug.print("\tAttribute name: '{s}'\n", .{an});
            }
            if (node.attribute_value) |av| {
                std.debug.print("\tAttribute value: '{s}'\n", .{av});
            }

            std.debug.print("Printed node.\n", .{});
        }
    }
};

// pub fn parse(self: *const CSSParser, selector: []const u8) !?*const rem.Dom.Element {
//     // Process css selector string into a very basic ast for the subset we care about
//     return null;
// }

test "fwn selectors" {
    const test_cases = [_][]const u8{
        "h3[class=\"tit\"]>a",

        "div[class=\"txt \"]",
        "div[class=\"txt \"]>#article>p",
        "h1.tit",
        "em[class=\"num\"]",
        "div[class=\"li-row\"]",
        "span[class=\"s1\"]",
        "span[class=\"chapter\"]",
    };

    // const input = @embedFile("chap.html");
    // @setEvalBranchQuota(100000);
    // const decoded_input = &rem.util.utf8DecodeStringComptime(input);

    // // Create the DOM in which the parsed Document will be created.
    // var dom = rem.Dom{ .allocator = std.testing.allocator };
    // defer dom.deinit();

    // // Create the HTML parser.
    // var parser = try rem.Parser.init(&dom, decoded_input, std.testing.allocator, .report, false);
    // defer parser.deinit();

    // // This causes the parser to read the input and produce a Document.
    // try parser.run();

    // // `errors` returns the list of parse errors that were encountered while parsing.
    // // Since we know that our input was well-formed HTML, we expect there to be 0 parse errors.
    // const errors = parser.errors();
    // std.debug.assert(errors.len == 0);

    // // We can now print the resulting Document to the console.
    // const document = parser.getDocument();

    for (test_cases) |tc| {
        var selector = try CSSSelector.init(std.testing.allocator, tc);
        defer selector.nodes.deinit(std.testing.allocator);
        try selector.print();
    }
}

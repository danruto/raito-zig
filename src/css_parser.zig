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

    pub fn parse(s: []const u8, next_is_direct_child: bool) !CSSSelectorNode {

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
                    if (is_attribute or is_attribute_value) {
                        count += 1;
                    } else {
                        if (node.element_type == null and count > 0) {
                            node.element_type = slice_to_element_type(s[start .. start + count]);
                        }

                        is_class_name = true;
                        start = ii + 1;
                        count = 0;
                    }
                },

                // This is the beginning of an id field
                '#' => {
                    if (is_attribute or is_attribute_value) {
                        count += 1;
                    } else {
                        if (node.element_type == null and count > 0) {
                            node.element_type = slice_to_element_type(s[start .. start + count]);
                        }

                        is_id = true;
                        was_space = false;
                        was_quote = false;
                        start = ii + 1;
                        count = 0;
                    }
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
                    was_quote = false;
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
            const node = try CSSSelectorNode.parse(s, true);
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

const CSSDomNode = struct {
    element: ?*const rem.Dom.Element,
    text: ?[]const u8,
};

// Caller owns the memory and is responsible for freeing
pub fn parse(self: *const CSSParser, allocator: Allocator, selector: []const u8) !?CSSDomNode {
    var css_selector = try CSSSelector.init(allocator, selector);
    defer css_selector.nodes.deinit(allocator);
    try css_selector.print();

    var css_selector_node_index: usize = 0;

    // Now loop over the dom and try to find the matching elements
    // We will do a DFS for this
    // Create a local copy of the stack by reference
    var node_stack = try self.node_stack.clone(allocator);
    defer node_stack.deinit(allocator);

    var final_node: ?*const rem.Dom.Element = null;

    std.debug.print("\nEntering cssparser.parse with {d} nodes\n", .{node_stack.items.len});

    while (node_stack.items.len > 0) {
        if (css_selector_node_index >= css_selector.nodes.items.len) {
            break;
        }

        const css_selector_node = css_selector.nodes.items[css_selector_node_index];

        const item = node_stack.pop();

        switch (item.node) {
            .element => |element| {
                var append_children = false;

                const process_for_selector_node =
                    // Searching for a matching element_type at index
                    css_selector_node.element_type == element.element_type or
                    // Searching for a matching element that is a child
                    (css_selector_node.element_type == null and css_selector_node_index > 0);

                // When it is the first element we are scanning for and it doesn't match anything we want
                // to look for, then just save the children directly
                if (!process_for_selector_node and final_node == null) {
                    append_children = true;
                }

                // We want to process a null node when it is a child of something
                // and it didn't have an element specifier. Top level queries with no
                // html element is not supported by our parser.
                if (process_for_selector_node) {
                    var match = true;

                    std.debug.print("Processing for selector et:{any}, cn:{?s}, id:{?s} using et:{any} \n", .{ css_selector_node.element_type, css_selector_node.class_name, css_selector_node.id, element.element_type });

                    if (css_selector_node.id) |id| {
                        if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "id" })) |e_id| {
                            match = std.mem.eql(u8, id, e_id);
                        } else {
                            match = false;
                        }

                        if (css_selector_node.id != null) {
                            for (0..element.numAttributes()) |idx| {
                                std.debug.print("\tk: {s}, v: {s}\n", .{
                                    element.attributes.get(idx).key.local_name,
                                    element.attributes.get(idx).value,
                                });
                            }
                        }

                        std.debug.print("\tMatch for id?: {}\n", .{match});
                    }

                    if (css_selector_node.class_name) |cn| {
                        if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "class" })) |e_cn| {
                            match = match and std.mem.eql(u8, cn, e_cn);
                        } else {
                            match = false;
                        }

                        std.debug.print("\tMatch for class name?: {}\n", .{match});
                    }

                    if (css_selector_node.attribute_name) |an| {
                        if (css_selector_node.attribute_value) |av| {
                            if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = an })) |e_av| {
                                match = match and std.mem.eql(u8, av, e_av);
                            } else {
                                match = false;
                            }
                        } else {
                            match = false;
                        }

                        std.debug.print("\tMatch for attributes?: {}\n", .{match});
                    }

                    if (match) {
                        std.debug.print("\tMatch found, saving element\n", .{});
                        // It matched everything we were looking for, save it
                        final_node = element;

                        // Bump the index if there are children to keep processing
                        css_selector_node_index += 1;
                    } else {
                        std.debug.print("\tNo match found, continuing...\n", .{});
                    }

                    // Add children to node_stack
                    append_children = true;
                }

                if (css_selector_node_index < css_selector.nodes.items.len and append_children) {
                    var num_children = element.children.items.len;
                    std.debug.print("\tAbout to append up to {d} children at selector index {d}\n", .{ num_children, css_selector_node_index });
                    while (num_children > 0) : (num_children -= 1) {
                        switch (element.children.items[num_children - 1]) {
                            .element => |c| {
                                const node = ConstElementOrCharacterData{ .element = c };
                                try node_stack.append(allocator, .{ .node = node, .depth = item.depth + 1 });
                            },
                            else => {},
                        }
                    }
                }

                if (css_selector_node_index == css_selector.nodes.items.len) {
                    std.debug.print("\tAppending cdata for final node\n", .{});
                    var num_children = element.children.items.len;
                    while (num_children > 0) : (num_children -= 1) {
                        switch (element.children.items[num_children - 1]) {
                            .cdata => |c| {
                                const node = ConstElementOrCharacterData{ .cdata = c };
                                try node_stack.append(allocator, .{ .node = node, .depth = item.depth + 1 });
                            },
                            else => {},
                        }
                    }
                }
            },
            // Effectively unreachable, we don't prcoess anything to do with cdata
            else => {},
        }
    }

    // If we have valid enough data to return, that is, we have a `final_node`
    // then generate the return pointers
    var ret: ?CSSDomNode = null;

    if (final_node != null) {
        ret = .{
            .element = final_node,
            .text = null,
        };
    }

    // If this is the final item in the stack and it is a cdata, save it
    if (ret != null and node_stack.items.len > 0) {
        while (node_stack.items.len > 0) {
            const cdata_item = node_stack.pop();

            switch (cdata_item.node) {
                .cdata => |cd| {
                    switch (cd.interface) {
                        .text => {
                            // There should only be 1 text node as a child
                            if (ret.?.text == null) {
                                ret.?.text = std.zig.fmtEscapes(cd.data.items).data;
                            } else {
                                std.debug.print("\tSomehow we have more .text types", .{});
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    return ret;
}

// test "fwn selectors" {
//     const test_cases = [_][]const u8{
//         "h1.tit",
//         "h3[class=\"tit\"]>a",
//         "em[class=\"num\"]",
//         "div[class=\"txt \"]",
//         "div[class=\"txt \"]>#article>p",
//         "div[class=\"li-row\"]",
//         "span[class=\"s1\"]",
//         "span[class=\"chapter\"]",
//     };

//     for (test_cases) |tc| {
//         var selector = try CSSSelector.init(std.testing.allocator, tc);
//         defer selector.nodes.deinit(std.testing.allocator);
//         try selector.print();
//     }
// }

test "css parser find the matching element" {
    const input = @embedFile("chap.html");
    @setEvalBranchQuota(100000);
    const decoded_input = &rem.util.utf8DecodeStringComptime(input);

    // Create the DOM in which the parsed Document will be created.
    var dom = rem.Dom{ .allocator = std.testing.allocator };
    defer dom.deinit();

    // Create the HTML parser.
    var parser = try rem.Parser.init(&dom, decoded_input, std.testing.allocator, .report, false);
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
        var css_parser = try CSSParser.init(std.testing.allocator, document_element);
        defer css_parser.node_stack.deinit(std.testing.allocator);

        // Create arena around css selector
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const arena_allocator = arena.allocator();
        defer arena.deinit();
        const node = try css_parser.parse(arena_allocator, "div#article>p");
        if (node) |n| {
            if (n.element) |e| {
                // std.debug.print("Element: {any}\n", .{e});
                const num = e.numAttributes();
                for (0..num) |idx| {
                    const a = e.attributes.get(idx);
                    std.debug.print("\tAttribute: ({s})=({s})\n", .{ a.key.local_name, a.value });
                }
                // TODO: cdata contains the element text
                // but for now we will just avoid anything that needs it
                // until it becomes a problem
                // std.debug.print("Value: {any}", .{e});
            }

            if (n.text) |t| {
                std.debug.print("\tText: {s}", .{t});
            }
        }
    }
}

const std = @import("std");
const rem = @import("rem");

const Allocator = std.mem.Allocator;

const ConstElementOrCharacterData = union(enum) {
    element: *const rem.Dom.Element,
    cdata: *const rem.Dom.CharacterData,
};

const NodeData =
    struct { node: ConstElementOrCharacterData, depth: usize };

const CSSDomNode = struct {
    element: ?*const rem.Dom.Element,
    text: ?[]const u8,
};

pub const CSSParser = struct {
    allocator: Allocator,
    node_stack: std.ArrayListUnmanaged(NodeData),

    // Caller owns the memory and is responsible for freeing
    pub fn init(allocator: Allocator, document_element: *const rem.Dom.Element) !CSSParser {
        // We hold a reference to the dom elements as we may run multiple selectors on the same document
        var node_stack = std.ArrayListUnmanaged(NodeData){};
        try node_stack.append(allocator, .{ .node = .{ .element = document_element }, .depth = 1 });

        return .{
            .allocator = allocator,
            .node_stack = node_stack,
        };
    }

    // TODO: Coming up empty on return, look into this
    fn traverse(allocator: Allocator, node_stack: *std.ArrayListUnmanaged(NodeData), selector: CSSSelectorNode) ![]NodeData {
        // var arena = std.heap.ArenaAllocator.init(self.allocator);
        // const arena_allocator = arena.allocator();
        // defer arena.deinit();

        var final_nodes = std.ArrayListUnmanaged(NodeData){};

        while (node_stack.items.len > 0) {
            const item = node_stack.pop();

            switch (item.node) {
                // We don't need to do anything for cdata as it is auxillary content for our final item
                .cdata => {},

                .element => |element| {
                    var match = selector.element_type == element.element_type;

                    if (selector.id) |id| {
                        if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "id" })) |e_id| {
                            match = match and std.mem.eql(u8, id, e_id);
                        } else {
                            match = false;
                        }
                    }

                    if (selector.class_name) |cn| {
                        if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "class" })) |e_cn| {
                            match = match and std.mem.eql(u8, cn, e_cn);
                        } else {
                            match = false;
                        }
                    }

                    if (selector.attribute_name) |name| {
                        if (selector.attribute_value) |value| {
                            if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = name })) |e_av| {
                                match = match and std.mem.eql(u8, value, e_av);
                            } else {
                                match = false;
                            }
                        } else {
                            // Must have a matching name=value pair
                            match = false;
                        }
                    }

                    if (match) {
                        std.debug.print("\tFound a match, allocating to final_nodes\n", .{});
                        try final_nodes.append(allocator, .{ .node = .{ .element = element }, .depth = item.depth });
                    } else {
                        // Add the children and continue the scan
                        var num_children = element.children.items.len;
                        while (num_children > 0) : (num_children -= 1) {
                            switch (element.children.items[num_children - 1]) {
                                // We do not process cdata unless it is the final node
                                .cdata => {},

                                .element => |c| {
                                    const node = ConstElementOrCharacterData{ .element = c };
                                    try node_stack.append(allocator, .{ .node = node, .depth = item.depth + 1 });
                                },
                            }
                        }
                    }
                },
            }
        }

        return try final_nodes.toOwnedSlice(allocator);
        // return &.{};
    }

    pub fn parse2(self: *const CSSParser, selector: []const u8) ![]CSSDomNode {
        // Add all nodes until we find a match, if the selector is only 1 level
        // then we search siblings only
        // Otherwise we search children and then siblings
        // Wrap all allocations in an arena to make it easier to allocate and free
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena_allocator = arena.allocator();
        defer arena.deinit();

        // Parse the selector into something we can use
        var css_selector = try CSSSelector.init(arena_allocator, selector);
        defer css_selector.nodes.deinit(arena_allocator);

        // Create a local copy of the stack that we are going to traverse
        var node_stack = try self.node_stack.clone(arena_allocator);
        defer node_stack.deinit(arena_allocator);

        // Now scan down the tree until we find a match for our first selector
        // then we can start limiting the search to siblings and children as required

        var css_selector_node_index: usize = 0;
        while (css_selector_node_index < css_selector.nodes.items.len) : (css_selector_node_index += 1) {
            const selector_node = css_selector.nodes.items[css_selector_node_index];
            const new_nodes = try traverse(arena_allocator, &node_stack, selector_node);
            std.debug.print("\tTraversed and got {any} using selector {any}\n", .{ new_nodes, selector_node });
            // node_stack.clearRetainingCapacity();
            // node_stack.clearAndFree(self.allocator);
            try node_stack.appendSlice(arena_allocator, new_nodes);
        }

        // Convert nodedata to cssdomnode
        var ret = std.ArrayListUnmanaged(CSSDomNode){};
        for (node_stack.items) |node| {
            try ret.append(self.allocator, .{ .element = node.node.element, .text = null });
        }
        return try ret.toOwnedSlice(self.allocator);
    }

    // TODO: return owned slice of dom nodes, and not just the first one that matches
    // Caller owns the memory and is responsible for freeing
    pub fn parse(self: *const CSSParser, selector: []const u8) !?CSSDomNode {
        // Wrap all allocations in an arena to make it easier to allocate and free
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena_allocator = arena.allocator();
        defer arena.deinit();

        // Parse the selector into something we can use
        var css_selector = try CSSSelector.init(arena_allocator, selector);
        defer css_selector.nodes.deinit(arena_allocator);
        try css_selector.print();

        // Which element in the selector we are up to
        var css_selector_node_index: usize = 0;

        // Create a local copy of the stack that we are going to traverse
        var node_stack = try self.node_stack.clone(arena_allocator);
        defer node_stack.deinit(arena_allocator);

        // Prepare our return that currently contains null ptrs
        var final_node: ?CSSDomNode = null;

        std.debug.print("\nEntering cssparser.parse with {d} nodes\n", .{node_stack.items.len});

        // Start traversing the tree scanning for our selector elements.
        // Once we find the parent, all others (currently) have to be
        // direct children so it will filter childrens at that point
        while (node_stack.items.len > 0) {

            // Exit once we have completed scanning for all elements in the selector
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
                            // It matched everything we were looking for
                            final_node = .{
                                .element = element,
                                .text = null,
                            };

                            // Bump the index if there are children to keep processing
                            css_selector_node_index += 1;
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
                                    try node_stack.append(arena_allocator, .{ .node = node, .depth = item.depth + 1 });
                                },
                                // We do not process cdata unless it is the final node
                                .cdata => {},
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
                                    try node_stack.append(arena_allocator, .{ .node = node, .depth = item.depth + 1 });
                                },
                                else => {},
                            }
                        }
                    }
                },
                // Effectively unreachable, we don't prcoess anything to do with cdata
                .cdata => {},
            }
        }

        // If this is the final item in the stack and it is a cdata, save it
        if (final_node != null and node_stack.items.len > 0) {
            while (node_stack.items.len > 0) {
                const cdata_item = node_stack.pop();

                switch (cdata_item.node) {
                    .cdata => |cd| {
                        switch (cd.interface) {
                            .text => {
                                // There should only be 1 text node as a child
                                if (final_node.?.text == null) {
                                    final_node.?.text = std.zig.fmtEscapes(cd.data.items).data;
                                } else {
                                    std.debug.print("\tSomehow we have more .text types", .{});
                                }
                            },

                            // We do not care about comments
                            .comment => {},
                        }
                    },
                    // We have already processed everything we need from elements
                    .element => {},
                }
            }
        }

        return final_node;
    }
};

pub const CSSSelectorNode = struct {
    element_type: ?rem.Dom.ElementType,
    id: ?[]const u8,
    attribute_name: ?[]const u8,
    attribute_value: ?[]const u8,
    class_name: ?[]const u8,
    next_is_direct_child: bool,

    // Only supports a small subset of elementtypes that we require
    // TODO: expand when needed
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

        // Process selectors that are only direct tree branches.
        // TODO: Support any level, instead of direct children only
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

// test "basic css selectors parsing" {
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

// test "css parsing into dom node parsing" {
//     const input = @embedFile("chap.html");
//     @setEvalBranchQuota(100000);
//     const decoded_input = &rem.util.utf8DecodeStringComptime(input);

//     // Create the DOM in which the parsed Document will be created.
//     var dom = rem.Dom{ .allocator = std.testing.allocator };
//     defer dom.deinit();

//     // Create the HTML parser.
//     var parser = try rem.Parser.init(&dom, decoded_input, std.testing.allocator, .report, false);
//     defer parser.deinit();

//     // This causes the parser to read the input and produce a Document.
//     try parser.run();

//     // `errors` returns the list of parse errors that were encountered while parsing.
//     // Since we know that our input was well-formed HTML, we expect there to be 0 parse errors.
//     const errors = parser.errors();
//     std.debug.assert(errors.len == 0);

//     // We can now print the resulting Document to the console.
//     const document = parser.getDocument();

//     if (document.element) |document_element| {
//         var css_parser = try CSSParser.init(std.testing.allocator, document_element);
//         defer css_parser.node_stack.deinit(std.testing.allocator);

//         // Create arena around css selector
//         // var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//         // const arena_allocator = arena.allocator();
//         // defer arena.deinit();
//         const node = try css_parser.parse("div#article>p");
//         if (node) |n| {
//             if (n.element) |e| {
//                 // std.debug.print("Element: {any}\n", .{e});
//                 const num = e.numAttributes();
//                 for (0..num) |idx| {
//                     const a = e.attributes.get(idx);
//                     std.debug.print("\tAttribute: ({s})=({s})\n", .{ a.key.local_name, a.value });
//                 }
//             }

//             if (n.text) |t| {
//                 std.debug.print("\tText: {s}", .{t});
//                 try std.testing.expectEqualStrings(" Chapter 3157: Absolute Shocker ", t);
//             }
//         }
//     }
// }

test "css parsing via parse2" {
    const input = @embedFile("search.html");
    @setEvalBranchQuota(200000);
    const decoded_input = &rem.util.utf8DecodeStringComptime(input);
    // _ = decoded_input;

    // Create the DOM in which the parsed Document will be created.
    var dom = rem.Dom{ .allocator = std.testing.allocator };
    defer dom.deinit();

    // Create the HTML parser.
    var parser = try rem.Parser.init(&dom, decoded_input, std.testing.allocator, .ignore, false);
    defer parser.deinit();

    // This causes the parser to read the input and produce a Document.
    try parser.run();

    // `errors` returns the list of parse errors that were encountered while parsing.
    // Since we know that our input was well-formed HTML, we expect there to be 0 parse errors.
    const errors = parser.errors();
    for (errors) |err| {
        std.debug.print("{any}\n", .{err});
    }
    std.debug.assert(errors.len == 0);

    // We can now print the resulting Document to the console.
    const document = parser.getDocument();

    if (document.element) |document_element| {
        var css_parser = try CSSParser.init(std.testing.allocator, document_element);
        defer css_parser.node_stack.deinit(std.testing.allocator);

        const nodes = try css_parser.parse2("div[class=\"li-row\"]");
        defer std.testing.allocator.free(nodes);
        for (nodes) |n| {
            if (n.element) |e| {
                std.debug.print("Element: {any}\n", .{e});
                const num = e.numAttributes();
                for (0..num) |idx| {
                    const a = e.attributes.get(idx);
                    std.debug.print("\tAttribute: ({s})=({s})\n", .{ a.key.local_name, a.value });
                }
            }

            if (n.text) |t| {
                std.debug.print("\tText: {s}", .{t});
                try std.testing.expectEqualStrings(" Chapter 3157: Absolute Shocker ", t);
            }
        }
    }
}

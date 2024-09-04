// TODO: Managed and Unmanaged versions
// currently all basically unmanaged.

const std = @import("std");
const rem = @import("rem");
const logz = @import("logz");
const zul = @import("zul");

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

    pub fn deinit(self: *CSSParser) void {
        self.node_stack.deinit(self.allocator);
    }

    fn is_match(element: *const rem.Dom.Element, selector_node: CSSSelectorNode) bool {
        var match = element.element_type == selector_node.element_type;

        if (selector_node.id) |id| {
            if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "id" })) |e_id| {
                match = match and std.mem.eql(u8, id, e_id);
            } else {
                match = false;
            }
        }

        if (selector_node.class_name) |cn| {
            if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "class" })) |e_cn| {
                match = match and std.mem.eql(u8, cn, e_cn);
            } else {
                match = false;
            }
        }

        if (selector_node.attribute_name) |name| {
            if (selector_node.attribute_value) |value| {
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

        return match;
    }

    fn traverse(allocator: Allocator, node_stack: *std.ArrayListUnmanaged(NodeData), selector: CSSSelectorNode) ![]NodeData {
        var final_nodes = std.ArrayListUnmanaged(NodeData){};

        while (node_stack.items.len > 0) {
            const item = node_stack.pop();

            switch (item.node) {
                // We don't need to do anything for cdata as it is auxillary content for our final item
                .cdata => {},

                .element => |element| {
                    if (is_match(element, selector)) {
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
    }

    fn process_cdata(sb: *zul.StringBuilder, element: *const rem.Dom.Element, depth: usize) !void {
        // As we don't require going lower than 1 child, just exit early it we reach it
        if (depth > 1) {
            logz
                .warn()
                .ctx("css_parser.process_cdata")
                .int("depth", depth)
                .string("msg", "depth > 1 for child cdata")
                .log();
            return;
        }

        const num_children = element.children.items.len;
        var ii: u5 = 0;
        while (ii < num_children) : (ii += 1) {
            switch (element.children.items[ii]) {
                .cdata => |cd| {
                    switch (cd.interface) {
                        .text => {
                            const text = std.zig.fmtEscapes(cd.data.items).data;

                            // Only save texts that start with " " as they seem to be part of the
                            // chapter and those that are trimmed are ads
                            if (depth == 0 and std.mem.startsWith(u8, text, " ")) {
                                try sb.write(text);
                            } else {
                                try sb.write(text);
                            }

                            logz
                                .debug()
                                .ctx("css_parser.process_cdata")
                                .int("num_children", num_children)
                                .int("ii", ii)
                                .int("depth", depth)
                                .string("msg", "processed cdata to get")
                                .string("text", text)
                                .string("sb", sb.string())
                                .log();
                        },

                        .comment => {},
                    }
                },

                .element => |child_element| {
                    try process_cdata(sb, child_element, depth + 1);
                },
            }
        }
    }

    pub fn parse_many(self: *const CSSParser, selector: []const u8) ![]CSSDomNode {
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
        try css_selector.log();

        // Create a local copy of the stack that we are going to traverse
        var node_stack = try self.node_stack.clone(arena_allocator);
        defer node_stack.deinit(arena_allocator);
        // Now scan down the tree until we find a match for our first selector
        // then we can start limiting the search to siblings and children as required

        var css_selector_node_index: usize = 0;
        while (css_selector_node_index < css_selector.nodes.items.len) : (css_selector_node_index += 1) {
            const selector_node = css_selector.nodes.items[css_selector_node_index];
            const new_nodes = try traverse(arena_allocator, &node_stack, selector_node);

            try node_stack.appendSlice(arena_allocator, new_nodes);
        }

        // Convert nodedata to cssdomnode
        // and append its cdata text to the node
        var ret = std.ArrayListUnmanaged(CSSDomNode){};
        for (node_stack.items) |node| {
            var final_node: CSSDomNode = .{ .element = node.node.element, .text = null };

            var sb = zul.StringBuilder.init(arena_allocator);
            defer sb.deinit();

            // Find matching cdata
            try process_cdata(&sb, node.node.element, 0);

            final_node.text = try self.allocator.dupe(u8, sb.string());

            try ret.append(self.allocator, final_node);
        }

        return try ret.toOwnedSlice(self.allocator);
    }

    pub fn parse_single(self: *const CSSParser, selector: []const u8) !?CSSDomNode {
        // Wrap all allocations in an arena to make it easier to allocate and free
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena_allocator = arena.allocator();
        defer arena.deinit();

        // Parse the selector into something we can use
        var css_selector = try CSSSelector.init(arena_allocator, selector);
        defer css_selector.nodes.deinit(arena_allocator);
        try css_selector.log();

        // Which element in the selector we are up to
        var css_selector_node_index: usize = 0;

        // Create a local copy of the stack that we are going to traverse
        var node_stack = try self.node_stack.clone(arena_allocator);
        defer node_stack.deinit(arena_allocator);

        // Prepare our return that currently contains null ptrs
        var final_node: ?CSSDomNode = null;

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
                        if (is_match(element, css_selector_node)) {
                            logz.debug()
                                .ctx("parse_single.match")
                                .string("msg", "Match found, saving element")
                                .string("element type", element.element_type.toLocalName())
                                .int("css_selector_node_index", css_selector_node_index)
                                .log();

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
                },
                // Effectively unreachable, we don't prcoess anything to do with cdata
                .cdata => {},
            }
        }

        // If this is the final item in the stack and it is a cdata, save it
        if (final_node) |final_node_| {
            logz.debug()
                .ctx("css_parser.parse_single")
                .string("msg", "processing cdata for final node")
                .log();

            var sb = zul.StringBuilder.init(arena_allocator);
            defer sb.deinit();

            const element = final_node_.element orelse unreachable;
            try process_cdata(&sb, element, 0);

            final_node.?.text = try self.allocator.dupe(u8, sb.string());
        }

        logz.debug().ctx("css_parser.parse_single").string("msg", "returning final_node").log();

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

    pub fn log(self: *const CSSSelector) !void {
        for (self.nodes.items) |node| {
            logz.debug().ctx("css_parser.CSSSelector.print").string("msg", "Printing node.").log();

            if (node.element_type) |et| {
                logz.debug().ctx("css_parser.CSSSelector.print").fmt("element type", "{any}", .{et}).log();
            }
            if (node.id) |id| {
                logz.debug().ctx("css_parser.CSSSelector.print").string("id", id).log();
            }
            if (node.class_name) |cn| {
                logz.debug().ctx("css_parser.CSSSelector.print").string("class_name", cn).log();
            }
            if (node.attribute_name) |an| {
                logz.debug().ctx("css_parser.CSSSelector.print").string("attribute_name", an).log();
            }
            if (node.attribute_value) |av| {
                logz.debug().ctx("css_parser.CSSSelector.print").string("attribute_value", av).log();
            }

            logz.debug().ctx("css_parser.CSSSelector.print").string("msg", "Printed node.").log();
        }
    }
};

const t = std.testing;

test "basic css selectors parsing" {
    const test_cases: []const struct {
        s: []const u8,
        e: struct {
            len: u3,
            e: []const struct {
                element_type: ?rem.Dom.ElementType,
                class_name: ?[]const u8,
            },
        },
    } = &.{
        .{
            .s = "h1.tit",
            .e = .{
                .len = 1,
                .e = &.{
                    .{
                        .element_type = .html_h1,
                        .class_name = "tit",
                    },
                },
            },
        },
        .{
            .s = "h1[class=\"tit\"]>a",
            .e = .{
                .len = 2,
                .e = &.{
                    .{
                        .element_type = .html_h1,
                        .class_name = "tit",
                    },
                    .{
                        .element_type = .html_a,
                        .class_name = null,
                    },
                },
            },
        },
        .{
            .s = "em[class=\"num\"]",
            .e = .{
                .len = 1,
                .e = &.{
                    .{
                        .element_type = .html_em,
                        .class_name = "num",
                    },
                },
            },
        },
        .{
            .s = "div[class=\"txt \"]",
            .e = .{
                .len = 1,
                .e = &.{
                    .{
                        .element_type = .html_div,
                        .class_name = "txt ",
                    },
                },
            },
        },
        .{
            .s = "span.s1",
            .e = .{
                .len = 1,
                .e = &.{
                    .{
                        .element_type = .html_span,
                        .class_name = "s1",
                    },
                },
            },
        },
    };

    for (test_cases) |tc| {
        var selector = try CSSSelector.init(std.testing.allocator, tc.s);
        defer selector.nodes.deinit(std.testing.allocator);

        try t.expectEqual(tc.e.len, selector.nodes.items.len);
        for (tc.e.e, 0..) |ce, ii| {
            if (ce.element_type) |et| {
                try t.expectEqual(et, selector.nodes.items[ii].element_type);
            }
            if (ce.class_name) |cn| {

                // Class name can be either stored in class_name or in attributes
                const sn = selector.nodes.items[ii];

                var done = false;

                if (sn.class_name) |s_cn| {
                    try t.expectEqualStrings(cn, s_cn);
                    done = true;
                }

                if (sn.attribute_name) |s_an| {
                    try t.expectEqualStrings("class", s_an);
                    const av = sn.attribute_value orelse unreachable;
                    try t.expectEqualStrings(cn, av);
                    done = true;
                }

                try t.expect(done);
            }
        }
    }
}

test "parse sample search.html" {
    const allocator = t.allocator;

    const input = @embedFile("tests/search.html");
    @setEvalBranchQuota(200000);
    const decoded_input = &rem.util.utf8DecodeStringComptime(input);
    // defer allocator.free(decoded_input);

    // Create the DOM in which the parsed Document will be created.
    var dom = rem.Dom{ .allocator = allocator };
    defer dom.deinit();

    var parser = try rem.Parser.init(&dom, decoded_input, allocator, .ignore, false);
    defer parser.deinit();

    // This causes the parser to read the input and produce a Document.
    try parser.run();

    // `errors` returns the list of parse errors that were encountered while parsing.
    // Since we know that our input was well-formed HTML, we expect there to be 0 parse errors.
    const errors = parser.errors();
    try t.expect(errors.len == 0);

    // We can now print the resulting Document to the console.
    const document = parser.getDocument();
    try t.expect(document.element != null);

    if (document.element) |document_element| {
        var css = try CSSParser.init(allocator, document_element);
        defer css.deinit();

        const rows = try css.parse_many("div.li-row");
        defer {
            for (rows) |row| {
                if (row.text) |text| {
                    allocator.free(text);
                }
            }
            allocator.free(rows);
        }
        try t.expectEqual(50, rows.len);

        const row = rows[0];
        const element = row.element orelse unreachable;
        var row_css = try CSSParser.init(allocator, element);
        defer row_css.deinit();

        const href_node = try row_css.parse_single("h3.tit>a") orelse unreachable;
        defer if (href_node.text) |text| allocator.free(text);

        const href_element = href_node.element orelse unreachable;
        const attr = href_element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "title" }) orelse unreachable;

        try t.expectEqualStrings("Martial Cultivator", attr);
    }
}

test "parse sample chap.html" {
    const allocator = t.allocator;

    const input = @embedFile("tests/chap.html");
    @setEvalBranchQuota(200000);
    const decoded_input = &rem.util.utf8DecodeStringComptime(input);
    // defer allocator.free(decoded_input);

    // Create the DOM in which the parsed Document will be created.
    var dom = rem.Dom{ .allocator = allocator };
    defer dom.deinit();

    var parser = try rem.Parser.init(&dom, decoded_input, allocator, .ignore, false);
    defer parser.deinit();

    // This causes the parser to read the input and produce a Document.
    try parser.run();

    // `errors` returns the list of parse errors that were encountered while parsing.
    // Since we know that our input was well-formed HTML, we expect there to be 0 parse errors.
    const errors = parser.errors();
    try t.expect(errors.len == 0);

    // We can now print the resulting Document to the console.
    const document = parser.getDocument();
    try t.expect(document.element != null);

    if (document.element) |document_element| {
        var css = try CSSParser.init(allocator, document_element);
        defer css.deinit();

        const chapter_row = try css.parse_single("span.chapter") orelse unreachable;
        const text = chapter_row.text orelse unreachable;
        defer allocator.free(text);
        try t.expectEqualStrings("Chapter 3157 - 3157: Absolute Shocker", text);
    }
}

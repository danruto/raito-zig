const std = @import("std");
const zul = @import("zul");
const rem = @import("rem");

const css_parser = @import("css_parser.zig");
const dom_utils = @import("dom_utils.zig");

const Allocator = std.mem.Allocator;

const Novel = struct {
    id: []const u8,
    title: []const u8,
    url: []const u8,
    chapters: usize,
    chapter: usize,
};

// TODO: Revisit this later, need to figure out how to transfer ownership of `parser`
// so that all the pointers don't get free'd before we can do anything with them
fn load_dom(allocator: Allocator, html: []const u8) !?rem.Dom.Element {
    // Create the DOM in which the parsed Document will be created.
    var dom = rem.Dom{ .allocator = allocator };
    defer dom.deinit();

    // Create the HTML parser.
    const decoded_input = try dom_utils.utf8DecodeStringRuntime(allocator, html);
    defer allocator.free(decoded_input);

    var parser = try rem.Parser.init(&dom, decoded_input, allocator, .ignore, false);
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
        return document_element.*;
    }

    return null;
}

pub const Freewebnovel = struct {
    const Host = "freewebnovel.noveleast.com";
    const ChapterPrefix = "chapter-";
    const UserAgent = "raito/0.1";

    allocator: Allocator,

    pub fn init(allocator: Allocator) Freewebnovel {
        return .{
            .allocator = allocator,
        };
    }

    fn make_post_req(self: *const Freewebnovel, url: []const u8, form: ?*const std.StringHashMap([]const u8)) anyerror![]const u8 {
        var client = zul.http.Client.init(self.allocator);
        defer client.deinit();

        var req = try client.request(url);
        defer req.deinit();
        req.method = .POST;

        if (form) |f| {
            var iter = f.iterator();
            while (iter.next()) |fd| {
                try req.formBody(fd.key_ptr.*, fd.value_ptr.*);
            }
        }

        var res = try req.getResponse(.{});
        if (res.status != 200) {
            return error.InvalidStatusCode;
        }

        const sb = try res.allocBody(self.allocator, .{});
        defer sb.deinit();
        return sb.copy(self.allocator);
    }

    pub fn search(self: *const Freewebnovel, term: []const u8) ![]Novel {
        var novels = std.ArrayListUnmanaged(Novel){};

        const url = try std.mem.concat(self.allocator, u8, &.{ "https://", Host, "/search/" });
        defer self.allocator.free(url);

        var form = std.StringHashMap([]const u8).init(self.allocator);
        defer form.deinit();

        try form.put("searchkey", std.mem.trim(u8, term, " "));

        const s = try self.make_post_req(url, &form);
        defer self.allocator.free(s);

        // if (try load_dom(self.allocator, s)) |document| {

        // Create the DOM in which the parsed Document will be created.
        var dom = rem.Dom{ .allocator = self.allocator };
        defer dom.deinit();

        // Create the HTML parser.
        const decoded_input = try dom_utils.utf8DecodeStringRuntime(self.allocator, s);
        defer self.allocator.free(decoded_input);

        var parser = try rem.Parser.init(&dom, decoded_input, self.allocator, .ignore, false);
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
            // First scan for the container divs that contain the info we want
            // then read its children
            var css = try css_parser.CSSParser.init(self.allocator, document_element);
            defer css.deinit();

            const rows = try css.parse2("div.li-row");
            defer self.allocator.free(rows);

            for (rows) |row| {
                if (row.element) |row_element| {
                    var novel: Novel = .{
                        .id = "",
                        .title = "",
                        .url = "",
                        .chapters = 0,
                        .chapter = 0,
                    };

                    var local_css = try css_parser.CSSParser.init(self.allocator, row_element);
                    defer local_css.deinit();

                    std.debug.print("\tProcessing h3.tit>a\n", .{});
                    if (try local_css.parse("h3.tit>a")) |href_node| {
                        std.debug.print("\tProcessed h3.tit>a\n", .{});
                        if (href_node.element) |element| {
                            std.debug.print("\tProcessing h3.tit>a href_node\n", .{});
                            if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "title" })) |attr_title| {
                                novel.title = try self.allocator.dupe(u8, attr_title);
                            }

                            if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "href" })) |attr_url| {
                                // The string size will only reduce, so we just allocate the original size and do our replacements
                                const output = try self.allocator.alloc(u8, attr_url.len);

                                _ = std.mem.replace(u8, attr_url, ".html", "", output);
                                _ = std.mem.replace(u8, attr_url, "/free-novel", "", output);

                                novel.url = output;
                            }
                        }
                    }

                    std.debug.print("\tProcessing span.s1\n", .{});
                    if (try local_css.parse("span.s1")) |chapters_node| {
                        std.debug.print("\tProcessed span.s1\n", .{});
                        if (chapters_node.text) |text| {
                            std.debug.print("\tProcessing span.s1 chapters_node\n", .{});
                            const size = std.mem.replacementSize(u8, text, "Chapters", "");
                            const output = try self.allocator.alloc(u8, size);
                            defer self.allocator.free(output);
                            _ = std.mem.replace(u8, text, "Chapters", "", output);

                            // std.mem.replaceScalar(u8, text, "Chapters", "");
                            novel.chapters = try std.fmt.parseUnsigned(usize, std.mem.trim(u8, output, " "), 10);
                            // Start at the first chapter
                            novel.chapter = 1;
                            std.debug.print("\tProcessed span.s1 chapters_node\n", .{});
                        }
                    }

                    if (!std.mem.eql(u8, novel.title, "")) {
                        try novels.append(self.allocator, novel);
                    }
                }
            }
        }

        // std.debug.print("\tReturning novels: {any}\n", .{novels});
        // const slice = try novels.toOwnedSlice();
        // std.debug.print("\tReturning novels as slice: {any}\n", .{slice});
        std.debug.print("Returning owned slice of novels\n", .{});
        return try novels.toOwnedSlice(self.allocator);
    }
};

// test "can make post request to search url" {
//     const url = try std.mem.concat(std.testing.allocator, u8, &.{ "https://", "freewebnovel.noveleast.com", "/search/" });
//     defer std.testing.allocator.free(url);

//     var form = std.StringHashMap([]const u8).init(std.testing.allocator);
//     defer form.deinit();

//     try form.put("searchkey", std.mem.trim(u8, "marital", " "));

//     const freewebnovel = Freewebnovel.init(std.testing.allocator);
//     const s = try freewebnovel.make_post_req(url, &form);
//     defer std.testing.allocator.free(s);
// }

test "can load search file and parse the results" {
    // const freewebnovel = Freewebnovel.init(std.testing.allocator);
    // const resp = try freewebnovel.search("martial");
    // std.debug.print("Got resp: {any}\n", .{resp[0]});
    // try std.testing.expectEqual(50, resp.len);
    // defer {
    //     for (resp) |item| {
    //         std.testing.allocator.free(item.id);
    //         std.testing.allocator.free(item.title);
    //         std.testing.allocator.free(item.url);
    //         // std.testing.allocator.free(item.chapters);
    //         // std.testing.allocator.free(item.chapter);
    //     }
    //     // defer std.testing.allocator.free(resp);
    // }

    const allocator = std.testing.allocator;

    // Create the DOM in which the parsed Document will be created.
    var dom = rem.Dom{ .allocator = allocator };
    defer dom.deinit();

    // Create the HTML parser.
    const file = try std.fs.cwd().openFile("src/search.html", .{});
    defer file.close(); // Ensure the file is closed after use

    // Read the entire file into memory
    const file_size = try file.getEndPos();
    const file_content = try allocator.alloc(u8, file_size);
    defer allocator.free(file_content);

    // Read the file content
    _ = try file.read(file_content);

    // Convert the file content to a string and print it
    const s = file_content[0..];
    const decoded_input = try dom_utils.utf8DecodeStringRuntime(allocator, s);
    defer allocator.free(decoded_input);

    var parser = try rem.Parser.init(&dom, decoded_input, allocator, .ignore, false);
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
        var novels = std.ArrayList(Novel).init(allocator);
        defer {
            for (novels.items) |novel| {
                allocator.free(novel.id);
                allocator.free(novel.title);
                allocator.free(novel.url);
            }
            novels.deinit();
        }

        var css = try css_parser.CSSParser.init(allocator, document_element);
        defer css.deinit();

        const rows = try css.parse2("div.li-row");
        defer allocator.free(rows);

        for (rows) |row| {
            if (row.element) |row_element| {
                var novel: Novel = .{
                    .id = "",
                    .title = "",
                    .url = "",
                    .chapters = 0,
                    .chapter = 0,
                };

                var local_css = try css_parser.CSSParser.init(allocator, row_element);
                defer local_css.deinit();

                std.debug.print("\tProcessing h3.tit>a\n", .{});
                if (try local_css.parse("h3.tit>a")) |href_node| {
                    std.debug.print("\tProcessed h3.tit>a\n", .{});
                    if (href_node.element) |element| {
                        std.debug.print("\tProcessing h3.tit>a href_node\n", .{});
                        if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "title" })) |attr_title| {
                            novel.title = try allocator.dupe(u8, attr_title);
                        }

                        if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "href" })) |attr_url| {
                            // The string size will only reduce, so we just allocate the original size and do our replacements
                            const output = try allocator.alloc(u8, attr_url.len);

                            _ = std.mem.replace(u8, attr_url, ".html", "", output);
                            _ = std.mem.replace(u8, attr_url, "/free-novel", "", output);

                            novel.url = output;
                        }
                    }
                }

                std.debug.print("\tProcessing span.s1\n", .{});
                if (try local_css.parse("span.s1")) |chapters_node| {
                    std.debug.print("\tProcessed span.s1\n", .{});
                    if (chapters_node.text) |text| {
                        std.debug.print("\tProcessing span.s1 chapters_node\n", .{});
                        const size = std.mem.replacementSize(u8, text, "Chapters", "");
                        const output = try allocator.alloc(u8, size);
                        defer allocator.free(output);
                        _ = std.mem.replace(u8, text, "Chapters", "", output);

                        // std.mem.replaceScalar(u8, text, "Chapters", "");
                        novel.chapters = try std.fmt.parseUnsigned(usize, std.mem.trim(u8, output, " "), 10);
                        // Start at the first chapter
                        novel.chapter = 1;
                        std.debug.print("\tProcessed span.s1 chapters_node\n", .{});
                    }
                }

                if (!std.mem.eql(u8, novel.title, "")) {
                    try novels.append(novel);
                }
            }
        }

        for (novels.items) |novel| {
            std.debug.print("\tNovel: t: {s}, u: {s}, c: {any}\n", .{ novel.title, novel.url, novel.chapters });
        }
    }
}

// test "can load dom from str" {
// const input = @embedFile("search.html");
// @setEvalBranchQuota(200000);
// const decoded_input = &rem.util.utf8DecodeStringComptime(input);

// if (try load_dom(std.testing.allocator, input)) |document| {
//     var css = try css_parser.CSSParser.init(std.testing.allocator, &document);
//     defer css.node_stack.deinit(std.testing.allocator);

//     const rows = try css.parse2("div.li-row");
//     defer std.testing.allocator.free(rows);
// }

// }

test "can search and parse the results" {
    const freewebnovel = Freewebnovel.init(std.testing.allocator);
    const resp = try freewebnovel.search("martial");
    std.debug.print("Got resp: {any}\n", .{resp});
    try std.testing.expectEqual(50, resp.len);
    defer {
        for (resp) |item| {
            // _ = item;
            std.testing.allocator.free(item.id);
            std.testing.allocator.free(item.title);
            std.testing.allocator.free(item.url);
            // std.testing.allocator.free(item.chapters);
            // std.testing.allocator.free(item.chapter);
        }
        defer std.testing.allocator.free(resp);
    }
}

// TODO: Managed and Unmanaged versions
// currently all basically unmanaged.

const std = @import("std");
const zul = @import("zul");
const rem = @import("rem");

const css_parser = @import("css_parser.zig");
const dom_utils = @import("dom_utils.zig");

const Allocator = std.mem.Allocator;

pub const Novel = struct {
    id: []const u8,
    title: []const u8,
    url: []const u8,
    chapters: usize,
    chapter: usize,

    pub fn deinit(self: *const Novel, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.url);
    }
};

pub const Chapter = struct {
    title: []const u8,
    number: usize,
    lines: std.ArrayList([]const u8),
    // TODO: status, if required (for latest chapter reached etc)

    pub fn deinit(self: *const Chapter, allocator: Allocator) void {
        allocator.free(self.title);
        for (self.lines.items) |line| {
            allocator.free(line);
        }
        self.lines.deinit();
    }
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
    // const SlugPrefix = "/free-novel";
    const SlugPrefix = "";
    const ChapterPrefix = "chapter-";
    const UserAgent = "raito/0.1";

    allocator: Allocator,

    pub fn init(allocator: Allocator) Freewebnovel {
        return .{
            .allocator = allocator,
        };
    }

    fn make_get_req(self: *const Freewebnovel, url: []const u8) ![]const u8 {
        var client = zul.http.Client.init(self.allocator);
        defer client.deinit();

        var req = try client.request(url);
        defer req.deinit();

        // TODO: Add more headers later i.e. UserAgent

        var res = try req.getResponse(.{});
        if (res.status != 200) {
            return error.InvalidStatusCode;
        }

        const sb = try res.allocBody(self.allocator, .{});
        defer sb.deinit();
        return sb.copy(self.allocator);
    }

    fn make_post_req(self: *const Freewebnovel, url: []const u8, form: ?*const std.StringHashMap([]const u8)) anyerror![]const u8 {
        var client = zul.http.Client.init(self.allocator);
        defer client.deinit();

        var req = try client.request(url);
        defer req.deinit();
        req.method = .POST;

        // TODO: Add more headers later i.e. UserAgent

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

            const rows = try css.parse_many("div.li-row");
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

                    if (try local_css.parse_single("h3.tit>a")) |href_node| {
                        if (href_node.element) |element| {
                            if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "title" })) |attr_title| {
                                novel.title = try self.allocator.dupe(u8, attr_title);
                            }

                            if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "href" })) |attr_url| {
                                // The string size will only reduce, so we just allocate the original size and do our replacements
                                const output = try self.allocator.alloc(u8, attr_url.len);

                                _ = std.mem.replace(u8, attr_url, ".html", "", output);
                                _ = std.mem.replace(u8, attr_url, SlugPrefix, "", output);

                                novel.url = output;
                            }
                        }
                    }

                    if (try local_css.parse_single("span.s1")) |chapters_node| {
                        if (chapters_node.text) |text| {
                            const size = std.mem.replacementSize(u8, text, "Chapters", "");
                            const output = try self.allocator.alloc(u8, size);
                            defer self.allocator.free(output);
                            _ = std.mem.replace(u8, text, "Chapters", "", output);

                            // std.mem.replaceScalar(u8, text, "Chapters", "");
                            novel.chapters = try std.fmt.parseUnsigned(usize, std.mem.trim(u8, output, " "), 10);
                            // Start at the first chapter
                            novel.chapter = 1;
                        }
                    }

                    if (!std.mem.eql(u8, novel.title, "")) {
                        try novels.append(self.allocator, novel);
                    }
                }
            }
        }

        return try novels.toOwnedSlice(self.allocator);
    }

    pub fn fetch(self: *const Freewebnovel, slug: []const u8, chapter_number: usize) !Chapter {
        const chapter_number_str = try std.fmt.allocPrint(self.allocator, "{d}", .{chapter_number});
        defer self.allocator.free(chapter_number_str);

        std.debug.print("Allocated chapter number as str {s}\n", .{chapter_number_str});

        const url = try std.mem.concat(self.allocator, u8, &.{ "https://", Host, SlugPrefix, if (std.mem.startsWith(u8, slug, "/")) "" else "/", slug, if (std.mem.endsWith(u8, slug, "/")) "" else "/", ChapterPrefix, chapter_number_str });
        defer self.allocator.free(url);

        std.debug.print("Making get request to {s}\n", .{url});

        const s = try self.make_get_req(url);
        defer self.allocator.free(s);

        std.debug.print("Made get request to {s} and got {s}\n", .{ url, s });

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
            std.debug.print("Got a root document element\n", .{});

            var chapter: Chapter = .{ .title = "", .number = chapter_number, .lines = std.ArrayList([]const u8).init(self.allocator) };

            // First scan for the container divs that contain the info we want
            // then read its children
            var css = try css_parser.CSSParser.init(self.allocator, document_element);
            defer css.deinit();

            const row = try css.parse_single("span.chapter");

            std.debug.print("Parsed span.chapter with {any}\n", .{row});

            if (row) |row_title| {
                if (row_title.text) |text| {
                    std.debug.print("Found title: {s}\n", .{text});
                    chapter.title = try self.allocator.dupe(u8, text);
                }
            }

            if (std.mem.eql(u8, chapter.title, "")) {
                std.debug.print("Didn't find the title, so we failed.\n", .{});
                // Latest chapter reached as we didn't find a title
                return error.LatestChapterReached;
            }

            std.debug.print("Parsing div.#article>p\n", .{});

            const content = try css.parse_many("div#article>p");
            defer self.allocator.free(content);

            std.debug.print("Parsed div.txt >#article>p\n", .{});

            for (content) |line| {
                if (line.text) |text| {
                    try chapter.lines.append(try self.allocator.dupe(u8, text));
                }
            }

            std.debug.print("Processed fetching lines content\n", .{});

            return chapter;
        }

        return error.FailedToFetchChapter;
    }

    pub fn sample_novel(self: *const Freewebnovel) Novel {
        _ = self;
        return .{
            .id = "",
            .title = "",
            .url = "",
            .chapters = 0,
            .chapter = 0,
        };
    }

    pub fn sample_chapter(self: *const Freewebnovel, number: usize) !Chapter {
        var chapter: Chapter = .{
            .title = "",
            .number = number,
            .lines = std.ArrayList([]const u8).init(self.allocator),
        };

        for (0..number) |ii| {
            try chapter.lines.append(try std.fmt.allocPrint(self.allocator, "Line {d}", .{ii}));
        }

        return chapter;
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

// test "can load search file and parse the results" {
//     const allocator = std.testing.allocator;

//     // Create the DOM in which the parsed Document will be created.
//     var dom = rem.Dom{ .allocator = allocator };
//     defer dom.deinit();

//     // Create the HTML parser.
//     const file = try std.fs.cwd().openFile("src/search.html", .{});
//     defer file.close(); // Ensure the file is closed after use

//     // Read the entire file into memory
//     const file_size = try file.getEndPos();
//     const file_content = try allocator.alloc(u8, file_size);
//     defer allocator.free(file_content);

//     // Read the file content
//     _ = try file.read(file_content);

//     // Convert the file content to a string and print it
//     const s = file_content[0..];
//     const decoded_input = try dom_utils.utf8DecodeStringRuntime(allocator, s);
//     defer allocator.free(decoded_input);

//     var parser = try rem.Parser.init(&dom, decoded_input, allocator, .ignore, false);
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
//         var novels = std.ArrayList(Novel).init(allocator);
//         defer {
//             for (novels.items) |novel| {
//                 allocator.free(novel.id);
//                 allocator.free(novel.title);
//                 allocator.free(novel.url);
//             }
//             novels.deinit();
//         }

//         var css = try css_parser.CSSParser.init(allocator, document_element);
//         defer css.deinit();

//         const rows = try css.parse_many("div.li-row");
//         defer allocator.free(rows);

//         for (rows) |row| {
//             if (row.element) |row_element| {
//                 var novel: Novel = .{
//                     .id = "",
//                     .title = "",
//                     .url = "",
//                     .chapters = 0,
//                     .chapter = 0,
//                 };

//                 var local_css = try css_parser.CSSParser.init(allocator, row_element);
//                 defer local_css.deinit();

//                 std.debug.print("\tProcessing h3.tit>a\n", .{});
//                 if (try local_css.parse_single("h3.tit>a")) |href_node| {
//                     std.debug.print("\tProcessed h3.tit>a\n", .{});
//                     if (href_node.element) |element| {
//                         std.debug.print("\tProcessing h3.tit>a href_node\n", .{});
//                         if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "title" })) |attr_title| {
//                             novel.title = try allocator.dupe(u8, attr_title);
//                         }

//                         if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "href" })) |attr_url| {
//                             // The string size will only reduce, so we just allocate the original size and do our replacements
//                             const output = try allocator.alloc(u8, attr_url.len);

//                             _ = std.mem.replace(u8, attr_url, ".html", "", output);
//                             _ = std.mem.replace(u8, attr_url, "/free-novel", "", output);

//                             novel.url = output;
//                         }
//                     }
//                 }

//                 std.debug.print("\tProcessing span.s1\n", .{});
//                 if (try local_css.parse_single("span.s1")) |chapters_node| {
//                     std.debug.print("\tProcessed span.s1\n", .{});
//                     if (chapters_node.text) |text| {
//                         std.debug.print("\tProcessing span.s1 chapters_node\n", .{});
//                         const size = std.mem.replacementSize(u8, text, "Chapters", "");
//                         const output = try allocator.alloc(u8, size);
//                         defer allocator.free(output);
//                         _ = std.mem.replace(u8, text, "Chapters", "", output);

//                         // std.mem.replaceScalar(u8, text, "Chapters", "");
//                         novel.chapters = try std.fmt.parseUnsigned(usize, std.mem.trim(u8, output, " "), 10);
//                         // Start at the first chapter
//                         novel.chapter = 1;
//                         std.debug.print("\tProcessed span.s1 chapters_node\n", .{});
//                     }
//                 }

//                 if (!std.mem.eql(u8, novel.title, "")) {
//                     try novels.append(novel);
//                 }
//             }
//         }

//         for (novels.items) |novel| {
//             std.debug.print("\tNovel: t: {s}, u: {s}, c: {any}\n", .{ novel.title, novel.url, novel.chapters });
//         }
//     }
// }

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

// test "can search and parse the results" {
//     const freewebnovel = Freewebnovel.init(std.testing.allocator);
//     const resp = try freewebnovel.search("martial");
//     std.debug.print("Got resp: {any}\n", .{resp});
//     try std.testing.expectEqual(50, resp.len);
//     defer {
//         for (resp) |item| {
//             // _ = item;
//             std.testing.allocator.free(item.id);
//             std.testing.allocator.free(item.title);
//             std.testing.allocator.free(item.url);
// item.deinit();
//         }
//         defer std.testing.allocator.free(resp);
//     }
// }

// test "can fetch a chapter" {
//     @setEvalBranchQuota(200000);
//     const freewebnovel = Freewebnovel.init(std.testing.allocator);
//     const chapter = try freewebnovel.fetch("/martial-god-asura-novel", 1);
//     defer chapter.deinit(std.testing.allocator);
//     try std.testing.expectEqualStrings("Chapter 1 Outer Court Disciple", chapter.title);
// }

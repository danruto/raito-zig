// TODO: Managed and Unmanaged versions
// currently all basically unmanaged.

const std = @import("std");
const zul = @import("zul");
const rem = @import("rem");
const logz = @import("logz");

const css_parser = @import("css_parser.zig");
const dom_utils = @import("dom_utils.zig");

const Chapter = @import("chapter.zig");
const Novel = @import("novel.zig");
const Allocator = std.mem.Allocator;

pub const Freewebnovel = @This();

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
    logz.debug().ctx("fwn.make_post_req").string("url", url).boolean("form given", form != null).log();

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
        logz.err().ctx("fwn.make_post_req").string("msg", "status was not 200").log();
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
    if (errors.len > 0) {
        logz.err()
            .ctx("fwn.search")
            .string("msg", "errors parsing dom")
            .fmt("errors", "{any}", .{errors})
            .log();
    }
    std.debug.assert(errors.len == 0);

    // We can now print the resulting Document to the console.
    const document = parser.getDocument();

    if (document.element) |document_element| {
        // First scan for the container divs that contain the info we want
        // then read its children
        var css = try css_parser.CSSParser.init(self.allocator, document_element);
        defer css.deinit();

        const rows = try css.parse_many("div.li-row");
        defer {
            for (rows) |row| {
                if (row.text) |text| {
                    self.allocator.free(text);
                }
            }
            self.allocator.free(rows);
        }

        for (rows) |row| {
            if (row.element) |row_element| {
                var novel: Novel = .{
                    .id = "",
                    .title = "",
                    .slug = "",
                    .chapters = 0,
                    .chapter = 0,
                };

                var local_css = try css_parser.CSSParser.init(self.allocator, row_element);
                defer local_css.deinit();

                if (try local_css.parse_single("h3.tit>a")) |href_node| {
                    if (href_node.element) |element| {
                        if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "title" })) |attr_title| {
                            logz.debug().ctx("fwn.search").string("msg", "found a title").string("attr_title", attr_title).log();
                            novel.title = try self.allocator.dupe(u8, attr_title);
                        }

                        if (element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "href" })) |attr_url| {
                            logz.debug().ctx("fwn.search").string("msg", "found a url").string("attr_url", attr_url).log();
                            // The string size will only reduce, so we just allocate the original size and do our replacements
                            const output = try self.allocator.alloc(u8, attr_url.len);

                            _ = std.mem.replace(u8, attr_url, ".html", "", output);
                            // _ = std.mem.replace(u8, attr_url, SlugPrefix, "", output);

                            novel.slug = output;

                            // novel id is slug without any extra tags fwn might insert
                            // in the most recent version, this is just the prefix `/`
                            novel.id = try self.allocator.dupe(u8, output[1..]);

                            logz.debug().ctx("fwn.search").string("msg", "save and replaced to").string("output", output).log();
                        }
                    }
                }

                if (try local_css.parse_single("span.s1")) |chapters_node| {
                    if (chapters_node.text) |text| {
                        logz.debug().ctx("fwn.search").string("msg", "found chapters text").string("text", text).log();
                        const size = std.mem.replacementSize(u8, text, "Chapters", "");
                        const output = try self.allocator.alloc(u8, size);
                        defer self.allocator.free(output);
                        _ = std.mem.replace(u8, text, "Chapters", "", output);

                        // std.mem.replaceScalar(u8, text, "Chapters", "");
                        novel.chapters = try std.fmt.parseUnsigned(usize, std.mem.trim(u8, output, " "), 10);
                        // Start at the first chapter
                        novel.chapter = 1;

                        logz.debug().ctx("fwn.search").string("msg", "parsed and saved chapters text").string("text", text).log();
                    }
                }

                if (!std.mem.eql(u8, novel.title, "")) {
                    logz.debug().ctx("fwn.search").string("msg", "appending novel to ret").log();
                    try novels.append(self.allocator, novel);
                    logz.debug().ctx("fwn.search").string("msg", "appended novel to ret").log();
                }
            }
        }
    }

    logz.debug().ctx("fwn.search").string("msg", "returning owned slice").log();
    return try novels.toOwnedSlice(self.allocator);
}

pub fn fetch(self: *const Freewebnovel, novel: Novel, chapter_number: usize) !Chapter {
    const chapter_number_str = try std.fmt.allocPrint(self.allocator, "{d}", .{chapter_number});
    defer self.allocator.free(chapter_number_str);

    const url = try std.mem.concat(self.allocator, u8, &.{ "https://", Host, SlugPrefix, if (std.mem.startsWith(u8, novel.slug, "/")) "" else "/", novel.slug, if (std.mem.endsWith(u8, novel.slug, "/")) "" else "/", ChapterPrefix, chapter_number_str });
    defer self.allocator.free(url);

    const s = try self.make_get_req(url);
    defer self.allocator.free(s);

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
        var chapter: Chapter = .{ .novel_id = try self.allocator.dupe(u8, novel.id), .title = "", .number = chapter_number, .lines = std.ArrayList([]const u8).init(self.allocator) };

        // First scan for the container divs that contain the info we want
        // then read its children
        var css = try css_parser.CSSParser.init(self.allocator, document_element);
        defer css.deinit();

        const row = try css.parse_single("span.chapter");

        if (row) |row_title| {
            if (row_title.text) |text| {
                chapter.title = try self.allocator.dupe(u8, text);
            }
        }

        if (std.mem.eql(u8, chapter.title, "")) {
            // Latest chapter reached as we didn't find a title
            return error.LatestChapterReached;
        }

        const content = try css.parse_many("div#article>p");
        defer {
            for (content) |content_row| {
                if (content_row.text) |text| {
                    self.allocator.free(text);
                }
            }
            self.allocator.free(content);
        }

        for (content) |line| {
            if (line.text) |text| {
                try chapter.lines.append(try self.allocator.dupe(u8, text));
            }
        }

        return chapter;
    }

    return error.FailedToFetchChapter;
}

pub fn get_novel(self: *const Freewebnovel, slug: []const u8) !Novel {
    const url = try std.mem.concat(self.allocator, u8, &.{ "https://", Host, SlugPrefix, if (std.mem.startsWith(u8, slug, "/")) "" else "/", slug });
    defer self.allocator.free(url);

    const s = try self.make_get_req(url);
    defer self.allocator.free(s);

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
        var novel: Novel = .{
            .id = if (std.mem.startsWith(u8, slug, "/")) try self.allocator.dupe(u8, slug[1..]) else try self.allocator.dupe(u8, slug),
            .title = "",
            .slug = try self.allocator.dupe(u8, slug),
            .chapters = 1,
            .chapter = 1,
        };
        var css = try css_parser.CSSParser.init(self.allocator, document_element);
        defer css.deinit();

        const row = try css.parse_single("h1.tit");
        if (row) |row_title| {
            if (row_title.text) |text| {
                novel.title = try self.allocator.dupe(u8, text);
            }
        }

        return novel;
    }

    return error.NotFound;
}

pub fn sample_novel(self: *const Freewebnovel) Novel {
    _ = self;
    return Novel.sample();
}

pub fn sample_chapter(self: *const Freewebnovel, number: usize) !Chapter {
    return try Chapter.sample(self.allocator, number);
}

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

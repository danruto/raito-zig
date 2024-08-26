const std = @import("std");
const zul = @import("zul");
const rem = @import("rem");

const Allocator = std.mem.Allocator;

const Novel = struct {
    title: []const u8,
};

fn load_dom(allocator: Allocator, html: []const u8) !?*rem.Dom.Element {
    @setEvalBranchQuota(100000);

    // Create the DOM in which the parsed Document will be created.
    var dom = rem.Dom{ .allocator = allocator };
    defer dom.deinit();

    // Create the HTML parser.
    var parser = try rem.Parser.init(&dom, html, allocator, .report, false);
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
        return document_element;
    }

    return null;
}

pub const Freewebnovel = struct {
    const Host = "freewebnovel.noveleast.com";
    const ChapterPrefix = "chapter-";
    const UserAgent = "raito/0.1";

    allocator: Allocator,

    pub fn init(allocator: Allocator) !Freewebnovel {
        .{
            .allocator = allocator,
        };
    }

    fn make_post_req(self: *const Freewebnovel, url: []const u8, form: ?*std.StringHashMap(u8)) ![]const u8 {
        var client = zul.http.Client.init(self.allocator);
        defer client.deinit();

        var req = try client.request(url);
        defer req.deinit();

        if (form) |f| {
            while (f.iterator().next()) |fd| {
                _ = fd;
            }
        }

        var res = try req.getResponse(.{});
        if (res.status != 200) {
            return;
        }

        const sb = try res.allocBody(self.allocator, .{});
        return sb.string();
    }

    pub fn search(self: *const Freewebnovel, term: []const u8) !Novel {
        const url = try std.mem.concat(self.allocator, u8, &.{ "https://", Host, "/search/" });

        const form = std.StringHashMap(u8).init(self.allocator);
        defer form.deinit();

        try form.put("searchkey", try std.mem.trim(u8, term, " "));

        const s = try self.make_post_req(url, null);
        defer self.allocator.free(s);

        const document = try load_dom(self.allocator, s);
        _ = document;
    }
};

const TuiHomePage = @import("home.zig");
const TuiSearchPage = @import("search.zig");
const TuiReaderPage = @import("reader.zig");

pub const PageContext = struct {
    home: ?*TuiHomePage,
    search: ?*TuiSearchPage,
    reader: ?*TuiReaderPage,
};

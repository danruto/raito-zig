const std = @import("std");
const logz = @import("logz");
const zul = @import("zul");
const rem = @import("rem");
const zqlite = @import("zqlite");
const datetime = @import("../datetime.zig");

const Novel = @import("../novel.zig");

const Allocator = std.mem.Allocator;

const Self = @This();

const TABLE_NAMES = .{ "novels", "sync" };

const XataListTableColumns = struct {
    columns: []struct {
        name: []const u8,
        type: []const u8,
    },
};

const XataSetTableSchemaColumn = struct {
    name: []const u8,
    type: []const u8,

    notNull: ?bool = null,
    defaultValue: ?[]const u8 = null,
    unique: ?bool = null,
};

const XataSetTableSchema = struct {
    columns: []const XataSetTableSchemaColumn,
};

const XataPreparedStatement = struct {
    statement: []const u8,
    params: ?[]const u8,
    responseType: []const u8,
};

const XataBulkInsertRecordSync = struct {
    id: []const u8,
    updated: []const u8,
};

const XataBulkInsertSync = struct {
    records: []XataBulkInsertRecordSync,
};

const XataBulkInsertRecordNovels = struct {
    id: []const u8,
    novel_id: []const u8,
    slug: []const u8,
    title: []const u8,
    chapter: ?u16,
    max_chapters: ?u16,
    created: []const u8,
    updated: []const u8,
};

const XataBulkInsertNovels = struct {
    records: []XataBulkInsertRecordNovels,
};

const XataNovel = struct {
    novel_id: []const u8,
    slug: []const u8,
    title: []const u8,
    chapter: ?u16,
    max_chapters: ?u16,
    created: []const u8,
    updated: []const u8,
};

const XataNovelQuery = struct {
    records: []XataNovel,
};

const XataQueryRequest = struct {
    columns: [][]const u8,
};

const XataSync = struct {
    id: []const u8,
    updated: []const u8,
};

allocator: Allocator,
base_url: []const u8,
api_key: []const u8,

pub fn init(allocator: Allocator) ?Self {
    const base_url = std.process.getEnvVarOwned(allocator, "API_URL") catch return null;
    const api_key = std.process.getEnvVarOwned(allocator, "API_KEY") catch return null;

    return .{
        .allocator = allocator,
        .base_url = base_url,
        .api_key = api_key,
    };
}

pub fn destroy(self: *const Self) void {
    self.allocator.free(self.base_url);
    self.allocator.free(self.api_key);
}

fn make_get_req(self: *const Self, comptime T: anytype, url: []const u8) !zul.Managed(T) {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    const arena_allocator = arena.allocator();
    defer arena.deinit();

    var client = zul.http.Client.init(self.allocator);
    defer client.deinit();

    var req = try client.request(url);
    defer req.deinit();

    req.method = .GET;
    try req.header("Authorization", self.api_key);

    const res = try req.getResponse(.{});
    if (res.status != 200) {
        const sb = try res.allocBody(arena_allocator, .{});
        defer sb.deinit();

        logz.err().ctx("xata.make_get_req").int("status", res.status).string("body", sb.string()).log();

        return error.InvalidStatusCode;
    }

    const res_body = res.json(T, self.allocator, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        const sb = try res.allocBody(arena_allocator, .{});
        defer sb.deinit();

        logz.err().ctx("xata.make_get_req").err(err).string("body", sb.string()).log();
        return err;
    };

    return res_body;
}

fn make_query_req(self: *const Self, comptime T: anytype, url: []const u8, body: XataQueryRequest) !zul.Managed(T) {
    logz.info().ctx("xata.make_query_req").string("url", url).log();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    const arena_allocator = arena.allocator();
    defer arena.deinit();

    var client = zul.http.Client.init(self.allocator);
    defer client.deinit();

    var req = try client.request(url);
    defer req.deinit();

    req.method = .POST;
    try req.header("Authorization", self.api_key);

    const s = try std.json.stringifyAlloc(arena_allocator, body, .{});
    req.body(s);

    const res = try req.getResponse(.{});
    if (res.status == 200 or res.status == 204 or res.status == 422) {
        logz.info().ctx("xata.make_query_req").string("message", "successful status code").int("status", res.status).log();

        const res_body = res.json(T, self.allocator, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            const sb = try res.allocBody(arena_allocator, .{});
            defer sb.deinit();

            logz.err().ctx("xata.make_get_req").err(err).string("body", sb.string()).log();
            return err;
        };

        return res_body;
    }

    return error.InvalidStatusCode;
}

fn make_body_req(self: *const Self, method: std.http.Method, url: []const u8, body: anytype) !void {
    logz.info().ctx("xata.make_body_req").string("url", url).log();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    const arena_allocator = arena.allocator();
    defer arena.deinit();

    var client = zul.http.Client.init(self.allocator);
    defer client.deinit();

    var req = try client.request(url);
    defer req.deinit();

    req.method = method;
    try req.header("Authorization", self.api_key);

    if (@typeInfo(@TypeOf(body)) != .Optional) {
        const s = try std.json.stringifyAlloc(arena_allocator, body, .{});

        logz.info().ctx("xata.make_body_req").string("message", "body is not an optional type").fmt("body", "{}", .{body}).string("s", s).log();

        req.body(s);
    }

    const res = try req.getResponse(.{});
    if (res.status == 200 or res.status == 204 or res.status == 422) {
        logz.info().ctx("xata.make_body_req").string("message", "successful status code").int("status", res.status).log();

        return;
    }

    const sb = try res.allocBody(arena_allocator, .{});
    defer sb.deinit();

    logz.info().ctx("xata.make_body_req").string("url", url).int("status", res.status).string("err", sb.string()).log();

    return error.InvalidStatusCode;
}

fn create_table(self: *const Self, name: []const u8) !void {
    const url = try std.fmt.allocPrint(self.allocator, "{s}/tables/{s}", .{ self.base_url, name });
    defer self.allocator.free(url);

    try self.make_body_req(.PUT, url, null);
}

fn create_tables(self: *const Self) !void {
    inline for (TABLE_NAMES) |name| {
        try self.create_table(name);
    }
}

fn has_migration_run_on_table(self: *const Self, name: []const u8, expected: usize) !bool {
    const url = try std.fmt.allocPrint(self.allocator, "{s}/tables/{s}/columns", .{ self.base_url, name });
    defer self.allocator.free(url);

    const body = try self.make_get_req(XataListTableColumns, url);
    defer body.deinit();

    return body.value.columns.len == expected;
}

fn migrate_table(self: *const Self, name: []const u8, payload: XataSetTableSchema) !void {
    // Check if table schema already exists, if it does then do nothing
    if (self.has_migration_run_on_table(name, payload.columns.len) catch false) {
        logz.info().ctx("migrate_table").string("message", "table has already run migration").string("table", name).log();
        return;
    }

    const url = try std.fmt.allocPrint(self.allocator, "{s}/tables/{s}/schema", .{ self.base_url, name });
    defer self.allocator.free(url);

    try self.make_body_req(.PUT, url, payload);
}

fn migrate_tables(self: *const Self) !void {
    try self.migrate_table("novels", .{
        .columns = &[_]XataSetTableSchemaColumn{
            .{
                .name = "novel_id",
                .type = "text",
            },
            .{
                .name = "slug",
                .type = "text",
            },
            .{
                .name = "title",
                .type = "text",
            },
            .{
                .name = "chapter",
                .type = "int",
            },
            .{
                .name = "max_chapters",
                .type = "int",
            },
            .{
                .name = "created",
                .type = "datetime",
            },
            .{
                .name = "updated",
                .type = "datetime",
            },
        },
    });

    try self.migrate_table("sync", .{
        .columns = &[_]XataSetTableSchemaColumn{
            .{
                .name = "updated",
                .type = "datetime",
            },
        },
    });
}

pub fn migrate(self: *const Self) !void {
    try self.create_tables();
    try self.migrate_tables();
}

fn get_by_id(self: *const Self, comptime T: type, table: []const u8, id: []const u8) !zul.Managed(T) {
    const url = try std.fmt.allocPrint(self.allocator, "{s}/tables/{s}/data/{s}", .{ self.base_url, table, id });
    defer self.allocator.free(url);

    const managed = try self.make_get_req(T, url);
    return managed;
}

fn upload_sync(self: *const Self) !void {
    logz.info().ctx("xata.upload_sync").log();

    // Update the servers sync table
    const url = try std.fmt.allocPrint(self.allocator, "{s}/tables/sync/bulk", .{self.base_url});
    defer self.allocator.free(url);

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    const arena_allocator = arena.allocator();
    defer arena.deinit();

    const dt = datetime.fromTimestamp(@intCast(std.time.timestamp()));
    logz.info().ctx("xata.upload_sync").string("dt", &dt.toRFC3339()).log();

    var records = std.ArrayList(XataBulkInsertRecordSync).init(arena_allocator);
    defer records.deinit();
    try records.append(.{
        .id = "0",
        .updated = try arena_allocator.dupe(u8, &dt.toRFC3339()),
    });

    try self.make_body_req(.POST, url, XataBulkInsertSync{
        .records = records.items,
    });
}

fn upload_novels(self: *const Self, conn: *const zqlite.Conn) !void {
    logz.info().ctx("xata.upload_novels").log();

    // Read from the local db and then wrap that in the xata structs
    const novels = try Novel.get_all_impl(conn, self.allocator);
    defer {
        for (novels) |novel| novel.destroy(self.allocator);
        self.allocator.free(novels);
    }

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    const arena_allocator = arena.allocator();
    defer arena.deinit();

    var bulk = std.ArrayList(XataBulkInsertRecordNovels).init(arena_allocator);
    defer bulk.deinit();

    // Convert to xata struct
    for (novels) |novel| {
        const dt = datetime.fromTimestamp(@intCast(std.time.timestamp()));

        try bulk.append(.{
            .id = novel.id,
            .novel_id = novel.id,
            .slug = novel.slug,
            .title = novel.title,
            .chapter = @intCast(novel.chapter),
            .max_chapters = @intCast(novel.chapters),
            .created = &dt.toRFC3339(),
            .updated = &dt.toRFC3339(),
        });
    }

    // Save as payload
    const url = try std.fmt.allocPrint(self.allocator, "{s}/tables/novels/bulk", .{self.base_url});
    defer self.allocator.free(url);

    try self.make_body_req(.POST, url, XataBulkInsertNovels{
        .records = bulk.items,
    });
}

pub fn upload(self: *const Self, conn: *const zqlite.Conn) !void {
    logz.info().ctx("xata.upload").log();

    try self.upload_sync();
    try self.upload_novels(conn);
}

pub fn download(self: *const Self, conn: *const zqlite.Conn) !void {
    logz.info().ctx("xata.download").log();

    const url = try std.fmt.allocPrint(self.allocator, "{s}/tables/novels/query", .{self.base_url});
    defer self.allocator.free(url);

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    const arena_allocator = arena.allocator();
    defer arena.deinit();

    var columns = std.ArrayList([]const u8).init(arena_allocator);
    defer columns.deinit();
    try columns.append("*");
    const body = try self.make_query_req(XataNovelQuery, url, XataQueryRequest{ .columns = columns.items });
    defer body.deinit();

    for (body.value.records) |xnovel| {
        const novel = Novel{
            .id = try arena_allocator.dupe(u8, xnovel.novel_id),
            .title = try arena_allocator.dupe(u8, xnovel.title),
            .slug = try arena_allocator.dupe(u8, xnovel.slug),
            .chapters = xnovel.max_chapters orelse 0,
            .chapter = xnovel.chapter orelse 0,
        };
        defer novel.destroy(arena_allocator);

        logz.info().ctx("xata.download").string("message", "upserting novel").log();
        try novel.upsert_impl(conn);
    }
}

pub fn sync(self: *const Self, ts: []const u8, conn: *const zqlite.Conn) !void {
    // Pull last sync'd date. If we have newer data, send it up,
    // otherwise update our local `novels` table
    const sync_row = try self.get_by_id(XataSync, "sync", "0");
    defer sync_row.deinit();

    logz.info().ctx("xata.sync").string("updated", sync_row.value.updated).string("ts", ts).log();

    const dt = datetime.fromRFC3339(sync_row.value.updated) catch datetime.ZERO;
    const local_dt = datetime.fromRFC3339(ts) catch datetime.ZERO;

    // const should_upload = local_dt.greaterThan(dt);
    const should_upload = false;

    logz.info().ctx("xata.sync").boolean("should_upload", should_upload).string("dt", &dt.toRFC3339()).string("local_dt", &local_dt.toRFC3339()).log();

    if (should_upload) {
        // If we are newer, force an update
        try self.upload(conn);
    } else {
        // Download the update
        try self.download(conn);
    }
}

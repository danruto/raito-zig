const std = @import("std");
const zqlite = @import("zqlite");
const logz = @import("logz");

const Allocator = std.mem.Allocator;

const Self = @This();

id: []const u8,
title: []const u8,
slug: []const u8,
chapters: usize,
chapter: usize,

pub fn deinit(self: *const Self, allocator: Allocator) void {
    allocator.free(self.id);
    allocator.free(self.title);
    allocator.free(self.slug);
}

pub fn sample() Self {
    return .{
        .id = "",
        .title = "",
        .slug = "",
        .chapters = 0,
        .chapter = 0,
    };
}

pub fn get(pool: *zqlite.Pool, allocator: Allocator, id: []const u8) !?Self {
    const conn = pool.acquire();
    defer pool.release(conn);

    if (try conn.row("SELECT id, slug, title, chapter, max_chapters FROM novel WHERE id = ?", .{id})) |row| {
        defer row.deinit();

        logz.debug().ctx("Novel.get").string("msg", "found novel in database").string("id", id).log();
        return .{
            .id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, row.text(2)),
            .slug = try allocator.dupe(u8, row.text(1)),
            .chapter = @intCast(row.int(3)),
            .chapters = @intCast(row.int(4)),
        };
    }

    logz.debug().ctx("Novel.get").string("msg", "couldn't find novel in database").string("id", id).log();
    return null;
}

pub fn get_all(pool: *zqlite.Pool, allocator: Allocator) ![]Self {
    const conn = pool.acquire();
    defer pool.release(conn);

    var rows = try conn.rows("SELECT id, slug, title, chapter, max_chapters FROM novel", .{});
    defer rows.deinit();

    var novels = std.ArrayList(Self).init(allocator);

    while (rows.next()) |row| {
        const novel: Self = .{
            .id = try allocator.dupe(u8, row.text(0)),
            .title = try allocator.dupe(u8, row.text(2)),
            .slug = try allocator.dupe(u8, row.text(1)),
            .chapter = @intCast(row.int(3)),
            .chapters = @intCast(row.int(4)),
        };

        try novels.append(novel);
    }

    if (rows.err) |err| {
        logz.err().ctx("Novel.get_all").err(err).log();
    }

    return novels.toOwnedSlice();
}

pub fn upsert(self: *const Self, pool: *zqlite.Pool) !void {
    const conn = pool.acquire();
    defer pool.release(conn);

    logz.debug().ctx("Novel.upsert").fmt("novel", "{any}", .{self}).log();

    try conn.exec("INSERT OR REPLACE INTO novel (id, slug, title, chapter, max_chapters) VALUES (?1, ?2, ?3, ?4, ?5)", .{ self.id, self.slug, self.title, self.chapter, self.chapters });
}

pub fn clone(self: *const Self, allocator: Allocator) !Self {
    return .{
        .id = try allocator.dupe(u8, self.id),
        .title = try allocator.dupe(u8, self.title),
        .slug = try allocator.dupe(u8, self.slug),
        .chapters = self.chapters,
        .chapter = self.chapter,
    };
}

const std = @import("std");
const zqlite = @import("zqlite");
const logz = @import("logz");

const Allocator = std.mem.Allocator;

const Self = @This();

id: []const u8,
title: []const u8,
url: []const u8,
chapters: usize,
chapter: usize,

pub fn deinit(self: *const Self, allocator: Allocator) void {
    allocator.free(self.id);
    allocator.free(self.title);
    allocator.free(self.url);
}

pub fn sample() Self {
    return .{
        .id = "",
        .title = "",
        .url = "",
        .chapters = 0,
        .chapter = 0,
    };
}

pub fn get(pool: *zqlite.Pool, allocator: Allocator, id: []const u8) !?Self {
    const conn = pool.acquire();
    defer pool.release(conn);

    if (try conn.row("SELECT id, slug, title, chapter, max_chapters FROM novel WHERE id = ?", .{id})) |row| {
        defer row.deinit();

        return .{
            .id = id,
            .title = try allocator.dupe(u8, row.text(2)),
            .url = try allocator.dupe(u8, row.text(1)),
            .chapter = row.int(3),
            .chapters = row.int(4),
        };
    }

    return null;
}

pub fn get_all(pool: *zqlite.Pool, allocator: Allocator) ![]Self {
    const conn = pool.acquire();
    defer pool.release(conn);

    var rows = try conn.rows("SELECT id, slug, title, chapter, max_chapters FROM novel", .{});
    defer rows.deinit();

    var novels = std.ArrayList(Self).init(allocator);

    while (rows.next()) |row| {
        const novel = .{
            .id = row.int(0),
            .title = try allocator.dupe(u8, row.text(2)),
            .url = try allocator.dupe(u8, row.text(1)),
            .chapter = row.int(3),
            .chapters = row.int(4),
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

    try conn.exec("INSERT OR REPLACE INTO novel (id, slug, title, chapter, max_chapters) VALUES (?1, ?2, ?3, ?4, ?5)", .{ self.id, self.url, self.title, self.chapter, self.chapters });
}

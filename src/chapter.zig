const std = @import("std");
const zqlite = @import("zqlite");
const logz = @import("logz");

const Allocator = std.mem.Allocator;

const Self = @This();

novel_id: []const u8,
title: []const u8,
number: usize,
lines: std.ArrayList([]const u8),

pub fn destroy(self: *const Self, allocator: Allocator) void {
    allocator.free(self.novel_id);
    allocator.free(self.title);
    for (self.lines.items) |line| {
        allocator.free(line);
    }
    self.lines.deinit();
}

pub fn sample(allocator: Allocator, number: usize) !Self {
    var chapter = .{
        .novel_id = try std.fmt.allocPrint(allocator, "sample-novel-id", .{}),
        .title = try std.fmt.allocPrint(allocator, "sample title", .{}),
        .number = number,
        .lines = std.ArrayList([]const u8).init(allocator),
    };

    for (0..number) |ii| {
        try chapter.lines.append(try std.fmt.allocPrint(allocator, "Line {d}", .{ii}));
    }

    return chapter;
}

pub fn get(pool: *zqlite.Pool, allocator: Allocator, novel_id: []const u8, number: usize) !?Self {
    const conn = pool.acquire();
    defer pool.release(conn);

    // const row = conn.row("SELECT title, number, lines, status FROM chapter WHERE novel_id = ?1 AND number = ?2", .{ novel_id, number }) catch unreachable orelse return null;
    // defer row.deinit();

    if (try conn.row("SELECT title, number, lines, status FROM chapter WHERE novel_id = ?1 AND number = ?2", .{ novel_id, number })) |row| {
        defer row.deinit();

        var chapter: Self = .{
            .novel_id = try allocator.dupe(u8, novel_id),
            .title = try allocator.dupe(u8, row.text(0)),
            .number = number,
            .lines = std.ArrayList([]const u8).init(allocator),
        };

        const lines = row.blob(2);
        var it = std.mem.splitScalar(u8, lines, '\n');
        while (it.next()) |line| {
            try chapter.lines.append(try allocator.dupe(u8, line));
        }

        return chapter;
    }

    return null;
}

pub fn upsert(self: *const Self, pool: *zqlite.Pool, allocator: Allocator) !void {
    const conn = pool.acquire();
    defer pool.release(conn);

    const lines = try std.mem.join(allocator, "\n", self.lines.items[0..]);
    defer allocator.free(lines);

    try conn.exec("INSERT OR REPLACE INTO chapter (number, title, raw_html, lines, status, novel_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6)", .{ self.number, self.title, "", lines, "Available", self.novel_id });
}

pub fn delete(novel_id: []const u8, pool: *zqlite.Pool) !void {
    const conn = pool.acquire();
    defer pool.release(conn);

    try conn.exec("DELETE FROM chapter WHERE novel_id = $1", .{novel_id});
}

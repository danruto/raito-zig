const std = @import("std");
const datetime = @import("../../datetime.zig");
const migrations = @import("migrations.zig");

const Conn = migrations.Conn;

pub fn run(conn: Conn) !void {
    try conn.execNoArgs("migration.create.novels",
        \\ CREATE TABLE IF NOT EXISTS novel (
        \\   id TEXT PRIMARY KEY,
        \\   slug TEXT NOT NULL,
        \\   title TEXT NOT NULL,
        \\   chapter INTEGER,
        \\   max_chapters INTEGER
        \\   created INTEGER NOT NULL default(unixepoch()),
        \\   updated INTEGER NOT NULL default(unixepoch())
        \\ );
    );

    try conn.execNoArgs("migration.create.chapters",
        \\ CREATE TABLE IF NOT EXISTS chapter (
        \\   number INTEGER NOT NULL,
        \\   title TEXT NOT NULL,
        \\   raw_html TEXT,
        \\   lines TEXT NOT NULL,
        \\   status TEXT NOT NULL,
        \\   novel_id INTEGER NOT NULL,
        \\   FOREIGN KEY (novel_id) REFERENCES novel (id),
        \\   PRIMARY KEY (novel_id, number)
        \\ );
    );

    try conn.execNoArgs("migration.create.sync",
        \\ CREATE TABLE IF NOT EXISTS sync (
        \\   id INTEGER PRIMARY KEY,
        \\   timestamp STRING NOT NULL
        \\ );
    );

    // Insert default row for sync data
    try conn.exec("migration.create.sync_default_row",
        \\ INSERT OR IGNORE INTO sync (id, timestamp) VALUES (?1, ?2);
    , .{
        1,
        &datetime.fromTimestamp(@intCast(std.time.timestamp())).toRFC3339(),
    });
}

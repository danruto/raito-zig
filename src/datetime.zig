// https://www.aolium.com/karlseguin/cf03dee6-90e1-85ac-8442-cf9e6c11602a#:~:text=When%20it%20comes%20to%20date%20and
const std = @import("std");

const Self = @This();

year: u16,
month: u8,
day: u8,
hour: u8,
minute: u8,
second: u8,

fn paddingTwoDigits(buf: *[2]u8, value: u8) void {
    switch (value) {
        0 => buf.* = "00".*,
        1 => buf.* = "01".*,
        2 => buf.* = "02".*,
        3 => buf.* = "03".*,
        4 => buf.* = "04".*,
        5 => buf.* = "05".*,
        6 => buf.* = "06".*,
        7 => buf.* = "07".*,
        8 => buf.* = "08".*,
        9 => buf.* = "09".*,
        // todo: optionally can do all the way to 59 if you want
        else => _ = std.fmt.formatIntBuf(buf, value, 10, .lower, .{}),
    }
}

pub fn toRFC3339(self: *const Self) [20]u8 {
    var buf: [20]u8 = undefined;

    _ = std.fmt.formatIntBuf(buf[0..4], self.year, 10, .lower, .{ .width = 4, .fill = '0' });
    buf[4] = '-';
    paddingTwoDigits(buf[5..7], self.month);
    buf[7] = '-';
    paddingTwoDigits(buf[8..10], self.day);
    buf[10] = 'T';

    paddingTwoDigits(buf[11..13], self.hour);
    buf[13] = ':';
    paddingTwoDigits(buf[14..16], self.minute);
    buf[16] = ':';
    paddingTwoDigits(buf[17..19], self.second);
    buf[19] = 'Z';

    return buf;
}

pub fn fromTimestamp(ts: u64) Self {
    const SECONDS_PER_DAY = 86400;
    const DAYS_PER_YEAR = 365;
    const DAYS_IN_4YEARS = 1461;
    const DAYS_IN_100YEARS = 36524;
    const DAYS_IN_400YEARS = 146097;
    const DAYS_BEFORE_EPOCH = 719468;

    const seconds_since_midnight: u64 = @rem(ts, SECONDS_PER_DAY);
    var day_n: u64 = DAYS_BEFORE_EPOCH + ts / SECONDS_PER_DAY;
    var temp: u64 = 0;

    temp = 4 * (day_n + DAYS_IN_100YEARS + 1) / DAYS_IN_400YEARS - 1;
    var year: u16 = @intCast(100 * temp);
    day_n -= DAYS_IN_100YEARS * temp + temp / 4;

    temp = 4 * (day_n + DAYS_PER_YEAR + 1) / DAYS_IN_4YEARS - 1;
    year += @intCast(temp);
    day_n -= DAYS_PER_YEAR * temp + temp / 4;

    var month: u8 = @intCast((5 * day_n + 2) / 153);
    const day: u8 = @intCast(day_n - (@as(u64, @intCast(month)) * 153 + 2) / 5 + 1);

    month += 3;
    if (month > 12) {
        month -= 12;
        year += 1;
    }

    return Self{
        .year = year,
        .month = month,
        .day = day,
        .hour = @intCast(seconds_since_midnight / 3600),
        .minute = @intCast(seconds_since_midnight % 3600 / 60),
        .second = @intCast(seconds_since_midnight % 60),
    };
}

pub fn fromRFC3339(ts: []const u8) !Self {
    // Simply reverse the toRFC3339 function.
    const year = try std.fmt.parseInt(u16, ts[0..4], 10);
    const month = try std.fmt.parseInt(u8, ts[5..7], 10);
    const day = try std.fmt.parseInt(u8, ts[8..10], 10);
    const hour = try std.fmt.parseInt(u8, ts[11..13], 10);
    const minute = try std.fmt.parseInt(u8, ts[14..16], 10);
    const second = try std.fmt.parseInt(u8, ts[17..19], 10);

    return Self{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

pub fn greaterThan(self: *const Self, other: Self) bool {
    if (self.year > other.year) return true;
    if (self.month > other.month) return true;
    if (self.day > other.day) return true;
    if (self.hour > other.hour) return true;
    if (self.minute > other.minute) return true;
    if (self.second > other.second) return true;

    return false;
}

pub const ZERO = Self{
    .year = 0,
    .month = 0,
    .day = 0,
    .hour = 0,
    .minute = 0,
    .second = 0,
};

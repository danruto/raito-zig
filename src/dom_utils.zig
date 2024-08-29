const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn utf8DecodeStringLen(string: []const u8) usize {
    var i: usize = 0;
    var decoded_len: usize = 0;
    while (i < string.len) {
        i += std.unicode.utf8ByteSequenceLength(string[i]) catch unreachable;
        decoded_len += 1;
    }
    return decoded_len;
}

pub fn utf8DecodeString(string: []const u8) ![]u21 {
    var result: []u21 = undefined;
    if (result.len == 0) return result;
    const view = try std.unicode.Utf8View.init(string);
    var decoded_it = view.iterator();
    var i: usize = 0;
    while (decoded_it.nextCodepoint()) |codepoint| {
        result[i] = codepoint;
        i += 1;
    }
    return result;
}

pub fn utf8DecodeStringRuntimeLen(string: []const u8) usize {
    var i: usize = 0;
    var decoded_len: usize = 0;
    while (i < string.len) {
        // Safe handling of potential errors
        const byte_len = std.unicode.utf8ByteSequenceLength(string[i]) catch {
            // Handle the error appropriately if UTF-8 decoding fails
            // For now, we just return the length we've computed
            return decoded_len;
        };
        i += byte_len;
        decoded_len += 1;
    }
    return decoded_len;
}

pub fn utf8DecodeStringRuntime(allocator: Allocator, string: []const u8) ![]u21 {
    // Compute the length of the decoded UTF-8 string
    const decoded_len = utf8DecodeStringRuntimeLen(string);

    // Allocate memory for the decoded string
    var result = try allocator.alloc(u21, decoded_len);

    const view = try std.unicode.Utf8View.init(string);
    var decoded_it = view.iterator();
    var i: usize = 0;

    while (decoded_it.nextCodepoint()) |codepoint| {
        result[i] = codepoint;
        i += 1;
    }

    return result;
}

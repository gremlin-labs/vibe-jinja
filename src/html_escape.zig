//! Shared HTML escaping with an explicit slash policy.
const std = @import("std");

pub fn needsEscaping(input: []const u8, escape_slash: bool) bool {
    for (input) |byte| {
        switch (byte) {
            '&', '<', '>', '"', '\'' => return true,
            '/' => if (escape_slash) return true,
            else => {},
        }
    }
    return false;
}

pub fn escapeOwned(allocator: std.mem.Allocator, input: []const u8, escape_slash: bool) ![]u8 {
    var capacity = input.len;
    for (input) |byte| {
        capacity = try std.math.add(usize, capacity, switch (byte) {
            '&' => 4,
            '<', '>' => 3,
            '"' => 5,
            '\'' => 5,
            '/' => if (escape_slash) 5 else 0,
            else => 0,
        });
    }

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, capacity);
    for (input) |byte| {
        const replacement: ?[]const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#x27;",
            '/' => if (escape_slash) "&#x2F;" else null,
            else => null,
        };
        if (replacement) |escaped| output.appendSliceAssumeCapacity(escaped) else output.appendAssumeCapacity(byte);
    }
    return output.toOwnedSlice(allocator);
}

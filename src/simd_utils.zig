//! SIMD-Accelerated String Operations
//! Phase 7 optimization: Use SIMD for fast scanning of template delimiters
//!
//! This module provides vectorized implementations of common string operations
//! used during template parsing, specifically scanning for:
//! - Variable delimiters: {{ and }}
//! - Block delimiters: {% and %}
//! - Comment delimiters: {# and #}
//!
//! On platforms that support SIMD (x86_64, aarch64), these operations can be
//! 4-16x faster than scalar code for large templates.

const std = @import("std");

/// Marker representing a found delimiter position
pub const Marker = struct {
    position: usize,
    kind: Kind,

    pub const Kind = enum {
        variable_begin, // {{
        variable_end, // }}
        block_begin, // {%
        block_end, // %}
        comment_begin, // {#
        comment_end, // #}
    };
};

/// SIMD vector size (16 bytes)
const VECTOR_SIZE = 16;

/// SIMD-accelerated scan for opening braces
/// Returns the index of the first `{` character, or null if not found
pub fn findOpenBrace(input: []const u8) ?usize {
    if (input.len == 0) return null;

    // Use SIMD for large inputs
    if (input.len >= VECTOR_SIZE) {
        return findOpenBraceSimd(input);
    }

    // Scalar fallback for small inputs
    return std.mem.indexOfScalar(u8, input, '{');
}

/// SIMD-accelerated scan for closing braces
pub fn findCloseBrace(input: []const u8) ?usize {
    if (input.len == 0) return null;

    if (input.len >= VECTOR_SIZE) {
        return findCloseBraceSimd(input);
    }

    return std.mem.indexOfScalar(u8, input, '}');
}

/// Find all delimiter markers in the input using SIMD
pub fn findDelimiters(allocator: std.mem.Allocator, input: []const u8) ![]Marker {
    var markers = std.ArrayList(Marker).empty;
    errdefer markers.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        // Look for opening brace first
        const brace_pos = findOpenBraceFrom(input, i) orelse break;

        // Check what follows the brace
        if (brace_pos + 1 < input.len) {
            const next = input[brace_pos + 1];
            switch (next) {
                '{' => {
                    try markers.append(allocator, .{ .position = brace_pos, .kind = .variable_begin });
                    i = brace_pos + 2;
                },
                '%' => {
                    try markers.append(allocator, .{ .position = brace_pos, .kind = .block_begin });
                    i = brace_pos + 2;
                },
                '#' => {
                    try markers.append(allocator, .{ .position = brace_pos, .kind = .comment_begin });
                    i = brace_pos + 2;
                },
                else => {
                    i = brace_pos + 1;
                },
            }
        } else {
            i = brace_pos + 1;
        }
    }

    // Also find closing delimiters
    i = 0;
    while (i < input.len) {
        const brace_pos = findCloseBraceFrom(input, i) orelse break;

        // Check what precedes the brace
        if (brace_pos > 0) {
            const prev = input[brace_pos - 1];
            switch (prev) {
                '}' => {
                    // Check if we already counted this as part of }}
                    const search_pos = brace_pos - 1;
                    // Only add if the previous } wasn't part of }}
                    var already_counted = false;
                    for (markers.items) |m| {
                        if (m.position == search_pos and m.kind == .variable_end) {
                            already_counted = true;
                            break;
                        }
                    }
                    if (!already_counted) {
                        try markers.append(allocator, .{ .position = search_pos, .kind = .variable_end });
                    }
                    i = brace_pos + 1;
                },
                '%' => {
                    try markers.append(allocator, .{ .position = brace_pos - 1, .kind = .block_end });
                    i = brace_pos + 1;
                },
                '#' => {
                    try markers.append(allocator, .{ .position = brace_pos - 1, .kind = .comment_end });
                    i = brace_pos + 1;
                },
                else => {
                    i = brace_pos + 1;
                },
            }
        } else {
            i = brace_pos + 1;
        }
    }

    // Sort by position
    std.mem.sort(Marker, markers.items, {}, struct {
        fn lessThan(_: void, a: Marker, b: Marker) bool {
            return a.position < b.position;
        }
    }.lessThan);

    return try markers.toOwnedSlice(allocator);
}

fn findOpenBraceFrom(input: []const u8, start: usize) ?usize {
    if (start >= input.len) return null;
    const result = findOpenBrace(input[start..]);
    if (result) |pos| return start + pos;
    return null;
}

fn findCloseBraceFrom(input: []const u8, start: usize) ?usize {
    if (start >= input.len) return null;
    const result = findCloseBrace(input[start..]);
    if (result) |pos| return start + pos;
    return null;
}

/// SIMD implementation for finding `{`
fn findOpenBraceSimd(input: []const u8) ?usize {
    const Vec = @Vector(VECTOR_SIZE, u8);
    const target: Vec = @splat('{');

    var i: usize = 0;

    // Process full vectors
    while (i + VECTOR_SIZE <= input.len) {
        const chunk: Vec = input[i..][0..VECTOR_SIZE].*;
        const matches = chunk == target;

        // Convert bool vector to integer mask
        const mask = @as(u16, @bitCast(matches));
        if (mask != 0) {
            // Find first set bit (position of first match)
            return i + @ctz(mask);
        }
        i += VECTOR_SIZE;
    }

    // Handle remaining bytes with scalar
    while (i < input.len) {
        if (input[i] == '{') return i;
        i += 1;
    }

    return null;
}

/// SIMD implementation for finding `}`
fn findCloseBraceSimd(input: []const u8) ?usize {
    const Vec = @Vector(VECTOR_SIZE, u8);
    const target: Vec = @splat('}');

    var i: usize = 0;

    while (i + VECTOR_SIZE <= input.len) {
        const chunk: Vec = input[i..][0..VECTOR_SIZE].*;
        const matches = chunk == target;

        const mask = @as(u16, @bitCast(matches));
        if (mask != 0) {
            return i + @ctz(mask);
        }
        i += VECTOR_SIZE;
    }

    while (i < input.len) {
        if (input[i] == '}') return i;
        i += 1;
    }

    return null;
}

/// SIMD-accelerated check if string contains any special HTML characters
/// Returns true if ANY of: <, >, &, ", ' are found
pub fn containsHtmlSpecial(input: []const u8) bool {
    if (input.len == 0) return false;

    // Use SIMD for larger inputs
    if (input.len >= VECTOR_SIZE) {
        return containsHtmlSpecialSimd(input);
    }

    // Scalar fallback
    for (input) |c| {
        if (c == '<' or c == '>' or c == '&' or c == '"' or c == '\'') {
            return true;
        }
    }
    return false;
}

fn containsHtmlSpecialSimd(input: []const u8) bool {
    const Vec = @Vector(VECTOR_SIZE, u8);
    const lt: Vec = @splat('<');
    const gt: Vec = @splat('>');
    const amp: Vec = @splat('&');
    const quot: Vec = @splat('"');
    const apos: Vec = @splat('\'');

    var i: usize = 0;

    while (i + VECTOR_SIZE <= input.len) {
        const chunk: Vec = input[i..][0..VECTOR_SIZE].*;

        // Check for any special characters
        const lt_match = chunk == lt;
        const gt_match = chunk == gt;
        const amp_match = chunk == amp;
        const quot_match = chunk == quot;
        const apos_match = chunk == apos;

        // Combine all matches with OR
        const any_match = @reduce(.Or, lt_match) or @reduce(.Or, gt_match) or @reduce(.Or, amp_match) or @reduce(.Or, quot_match) or @reduce(.Or, apos_match);

        if (any_match) return true;

        i += VECTOR_SIZE;
    }

    // Handle remaining bytes
    while (i < input.len) {
        const c = input[i];
        if (c == '<' or c == '>' or c == '&' or c == '"' or c == '\'') {
            return true;
        }
        i += 1;
    }

    return false;
}

/// Check if string needs case conversion (has any lowercase chars)
pub fn hasLowercase(input: []const u8) bool {
    for (input) |c| {
        if (std.ascii.isLower(c)) return true;
    }
    return false;
}

/// Check if string needs case conversion (has any uppercase chars)
pub fn hasUppercase(input: []const u8) bool {
    for (input) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

// Tests
test "findOpenBrace scalar" {
    try std.testing.expectEqual(@as(?usize, 0), findOpenBrace("{"));
    try std.testing.expectEqual(@as(?usize, 5), findOpenBrace("hello{world"));
    try std.testing.expectEqual(@as(?usize, null), findOpenBrace("no braces here"));
}

test "findOpenBrace SIMD" {
    // Create input large enough for SIMD
    var input: [64]u8 = undefined;
    @memset(&input, 'x');
    input[32] = '{';

    try std.testing.expectEqual(@as(?usize, 32), findOpenBrace(&input));
}

test "containsHtmlSpecial" {
    try std.testing.expect(!containsHtmlSpecial("Hello World"));
    try std.testing.expect(containsHtmlSpecial("<script>"));
    try std.testing.expect(containsHtmlSpecial("a & b"));
    try std.testing.expect(containsHtmlSpecial("\"quoted\""));
}

test "findDelimiters" {
    const allocator = std.testing.allocator;
    const input = "Hello {{ name }}! {% if show %}yes{% endif %}";

    const markers = try findDelimiters(allocator, input);
    defer allocator.free(markers);

    try std.testing.expect(markers.len >= 4);
}

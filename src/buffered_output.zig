//! Buffered Output - Efficient string concatenation for template rendering
//! Phase 4 optimization to reduce allocations and improve cache locality
//!
//! Instead of many small allocations, buffers output in a fixed-size buffer
//! and flushes to the final output when full.

const std = @import("std");

/// Buffered output writer for efficient string concatenation
/// Uses a fixed-size stack buffer to batch writes
pub const BufferedOutput = struct {
    /// Stack buffer for batching small writes
    buffer: [BUFFER_SIZE]u8,
    /// Current position in buffer
    pos: usize,
    /// Final output destination
    final_output: *std.ArrayList(u8),
    /// Allocator for final output
    allocator: std.mem.Allocator,

    const Self = @This();
    const BUFFER_SIZE = 4096;

    /// Initialize buffered output with destination
    pub fn init(allocator: std.mem.Allocator, final_output: *std.ArrayList(u8)) Self {
        return .{
            .buffer = undefined,
            .pos = 0,
            .final_output = final_output,
            .allocator = allocator,
        };
    }

    /// Write data to buffer, flushing if necessary
    pub fn write(self: *Self, data: []const u8) !void {
        if (data.len == 0) return;

        // If data fits in remaining buffer space, just copy
        if (self.pos + data.len <= BUFFER_SIZE) {
            @memcpy(self.buffer[self.pos..][0..data.len], data);
            self.pos += data.len;
            return;
        }

        // Flush current buffer first
        try self.flush();

        // If data is larger than buffer, write directly to output
        if (data.len > BUFFER_SIZE) {
            try self.final_output.appendSlice(self.allocator, data);
        } else {
            // Copy to buffer
            @memcpy(self.buffer[0..data.len], data);
            self.pos = data.len;
        }
    }

    /// Write a single byte
    pub fn writeByte(self: *Self, byte: u8) !void {
        if (self.pos >= BUFFER_SIZE) {
            try self.flush();
        }
        self.buffer[self.pos] = byte;
        self.pos += 1;
    }

    /// Write an integer without allocation
    pub fn writeInt(self: *Self, n: i64) !void {
        // Ensure we have space for max i64 digits (20) + sign
        if (self.pos + 21 > BUFFER_SIZE) {
            try self.flush();
        }

        const written = std.fmt.formatInt(
            self.buffer[self.pos..],
            n,
            10,
            .lower,
            .{},
        );
        self.pos += written;
    }

    /// Write a float without allocation
    pub fn writeFloat(self: *Self, f: f64) !void {
        // Ensure we have space for float representation
        if (self.pos + 32 > BUFFER_SIZE) {
            try self.flush();
        }

        // Use formatFloat for proper representation
        const result = std.fmt.formatFloat(
            self.buffer[self.pos..],
            f,
            .{},
        );
        self.pos += result.len;
    }

    /// Flush buffer to final output
    pub fn flush(self: *Self) !void {
        if (self.pos > 0) {
            try self.final_output.appendSlice(self.allocator, self.buffer[0..self.pos]);
            self.pos = 0;
        }
    }

    /// Get current buffered content (without flushing)
    pub fn buffered(self: *const Self) []const u8 {
        return self.buffer[0..self.pos];
    }

    /// Get total output length (buffered + flushed)
    pub fn totalLen(self: *const Self) usize {
        return self.final_output.items.len + self.pos;
    }

    /// Finish writing and get final output
    /// Caller owns the returned slice
    pub fn finish(self: *Self) ![]u8 {
        try self.flush();
        return try self.final_output.toOwnedSlice(self.allocator);
    }
};

/// Pre-sized output builder that estimates final size
pub const OutputBuilder = struct {
    segments: std.ArrayList(Segment),
    total_estimated: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    const Segment = union(enum) {
        /// Static string (no allocation during output)
        static: []const u8,
        /// Dynamic string (already allocated)
        dynamic: []const u8,
        /// Integer (format on finalize)
        integer: i64,
        /// Float (format on finalize)
        float: f64,
    };

    pub fn init(allocator: std.mem.Allocator, estimated_segments: usize) Self {
        return .{
            .segments = std.ArrayList(Segment).initCapacity(allocator, estimated_segments) catch .empty,
            .total_estimated = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.segments.deinit(self.allocator);
    }

    /// Append a static string (reference only, no copy)
    pub fn appendStatic(self: *Self, s: []const u8) !void {
        try self.segments.append(self.allocator, .{ .static = s });
        self.total_estimated += s.len;
    }

    /// Append a dynamic string (already owned)
    pub fn appendDynamic(self: *Self, s: []const u8) !void {
        try self.segments.append(self.allocator, .{ .dynamic = s });
        self.total_estimated += s.len;
    }

    /// Append an integer
    pub fn appendInt(self: *Self, n: i64) !void {
        try self.segments.append(self.allocator, .{ .integer = n });
        self.total_estimated += 21; // Max i64 length
    }

    /// Append a float
    pub fn appendFloat(self: *Self, f: f64) !void {
        try self.segments.append(self.allocator, .{ .float = f });
        self.total_estimated += 32; // Conservative estimate
    }

    /// Finalize and build the output string
    pub fn finalize(self: *Self) ![]u8 {
        var result = try self.allocator.alloc(u8, self.total_estimated);
        var pos: usize = 0;

        for (self.segments.items) |segment| {
            switch (segment) {
                .static, .dynamic => |s| {
                    @memcpy(result[pos..][0..s.len], s);
                    pos += s.len;
                },
                .integer => |n| {
                    const written = std.fmt.formatInt(result[pos..], n, 10, .lower, .{});
                    pos += written;
                },
                .float => |f| {
                    const written = std.fmt.formatFloat(result[pos..], f, .{});
                    pos += written.len;
                },
            }
        }

        // Shrink to actual size
        if (pos < result.len) {
            return self.allocator.realloc(result, pos) catch result[0..pos];
        }
        return result[0..pos];
    }
};

// Tests
test "BufferedOutput basic writes" {
    const allocator = std.testing.allocator;

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var buf = BufferedOutput.init(allocator, &output);

    try buf.write("Hello, ");
    try buf.write("World!");
    try buf.flush();

    try std.testing.expectEqualStrings("Hello, World!", output.items);
}

test "BufferedOutput writeInt" {
    const allocator = std.testing.allocator;

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var buf = BufferedOutput.init(allocator, &output);

    try buf.write("Value: ");
    try buf.writeInt(42);
    try buf.flush();

    try std.testing.expectEqualStrings("Value: 42", output.items);
}

test "BufferedOutput large write" {
    const allocator = std.testing.allocator;

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var buf = BufferedOutput.init(allocator, &output);

    // Write more than buffer size
    const large = "x" ** 5000;
    try buf.write(large);
    try buf.flush();

    try std.testing.expectEqual(@as(usize, 5000), output.items.len);
}

test "OutputBuilder segments" {
    const allocator = std.testing.allocator;

    var builder = OutputBuilder.init(allocator, 4);
    defer builder.deinit();

    try builder.appendStatic("Count: ");
    try builder.appendInt(123);
    try builder.appendStatic(" items");

    const result = try builder.finalize();
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Count: 123 items", result);
}

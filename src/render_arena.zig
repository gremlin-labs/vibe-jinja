//! Render Arena - Phase 2 Memory Optimization
//!
//! Provides arena-based memory allocation for template rendering.
//! All intermediate allocations during render use the arena, which is
//! freed in bulk at the end. Only the final output is copied to the
//! caller's allocator.
//!
//! Benefits:
//! - Dramatically reduces allocation count (bulk free)
//! - Better cache locality
//! - Faster allocation (bump allocator)
//! - No individual free() calls needed

const std = @import("std");

/// Arena allocator wrapper for render operations
pub const RenderArena = struct {
    arena: std.heap.ArenaAllocator,

    /// Pre-allocated output buffer to reduce reallocations
    output_buffer: std.ArrayList(u8),

    /// Statistics for diagnostics
    stats: Stats = .{},

    pub const Stats = struct {
        allocations: u64 = 0,
        bytes_allocated: u64 = 0,
    };

    const Self = @This();

    /// Initialize with estimated output size for pre-allocation
    pub fn init(backing: std.mem.Allocator, estimated_output_size: usize) Self {
        var arena = std.heap.ArenaAllocator.init(backing);
        const arena_alloc = arena.allocator();

        // Pre-allocate output buffer with estimated size
        const output = std.ArrayList(u8).initCapacity(arena_alloc, estimated_output_size) catch
            std.ArrayList(u8){};

        return Self{
            .arena = arena,
            .output_buffer = output,
        };
    }

    /// Initialize with default size
    pub fn initDefault(backing: std.mem.Allocator) Self {
        return init(backing, 4096); // 4KB default
    }

    /// Free all arena memory at once
    pub fn deinit(self: *Self) void {
        // Arena deinit frees everything including output_buffer
        self.arena.deinit();
    }

    /// Get the arena allocator for intermediate allocations
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Append to output buffer
    pub fn appendOutput(self: *Self, data: []const u8) !void {
        try self.output_buffer.appendSlice(self.arena.allocator(), data);
    }

    /// Append a single byte
    pub fn appendByte(self: *Self, byte: u8) !void {
        try self.output_buffer.append(self.arena.allocator(), byte);
    }

    /// Get current output as slice (valid only while arena is alive)
    pub fn getOutputSlice(self: *const Self) []const u8 {
        return self.output_buffer.items;
    }

    /// Copy final output to caller's allocator
    /// This is the only allocation that escapes the arena
    pub fn getOutput(self: *Self, final_allocator: std.mem.Allocator) ![]u8 {
        return try final_allocator.dupe(u8, self.output_buffer.items);
    }

    /// Reset arena for reuse (keeps capacity)
    pub fn reset(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
        self.output_buffer.clearRetainingCapacity();
        self.stats = .{};
    }

    /// Estimate output size based on template characteristics
    pub fn estimateOutputSize(
        static_content_size: usize,
        variable_count: usize,
        loop_count: usize,
    ) usize {
        var estimate: usize = static_content_size;

        // Estimate ~20 bytes per variable on average
        estimate += variable_count * 20;

        // Estimate loops multiply content (assume 10 iterations avg)
        if (loop_count > 0) {
            estimate *= 10;
        }

        // Add 20% buffer
        return estimate + (estimate / 5);
    }
};

// Tests
test "RenderArena basic usage" {
    const allocator = std.testing.allocator;

    var arena = RenderArena.init(allocator, 100);
    defer arena.deinit();

    try arena.appendOutput("Hello, ");
    try arena.appendOutput("World!");

    const output = try arena.getOutput(allocator);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("Hello, World!", output);
}

test "RenderArena reset and reuse" {
    const allocator = std.testing.allocator;

    var arena = RenderArena.init(allocator, 100);
    defer arena.deinit();

    try arena.appendOutput("First");
    try std.testing.expectEqualStrings("First", arena.getOutputSlice());

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.getOutputSlice().len);

    try arena.appendOutput("Second");
    try std.testing.expectEqualStrings("Second", arena.getOutputSlice());
}

test "RenderArena estimateOutputSize" {
    // Static only
    try std.testing.expectEqual(@as(usize, 120), RenderArena.estimateOutputSize(100, 0, 0));

    // With variables
    try std.testing.expectEqual(@as(usize, 168), RenderArena.estimateOutputSize(100, 2, 0));

    // With loops (multiplier)
    try std.testing.expectEqual(@as(usize, 1200), RenderArena.estimateOutputSize(100, 0, 1));
}

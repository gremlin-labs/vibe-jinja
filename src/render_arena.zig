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

/// Maximum arena capacity retained between renders by the thread-local cache.
/// A pathologically large render frees back down to this on release.
const max_retained_bytes: usize = 1 * 1024 * 1024;

/// Thread-local cached arena reused across render() calls. Backed by
/// page_allocator (caller-independent, invisible to leak-checking test
/// allocators); chunks are retained between renders so steady-state renders
/// never touch a backing allocator except for the returned result string.
threadlocal var cached_arena: ?std.heap.ArenaAllocator = null;
threadlocal var cached_in_use: bool = false;

/// A per-render arena scope. Obtain with `acquire`, free with `release`.
/// Not copyable while in use (the Allocator interface points into it).
pub const ScopedArena = struct {
    ptr: *std.heap.ArenaAllocator,
    from_cache: bool,
    backing: std.mem.Allocator,

    pub fn allocator(self: *const ScopedArena) std.mem.Allocator {
        return self.ptr.allocator();
    }

    pub fn release(self: *ScopedArena) void {
        if (self.from_cache) {
            _ = self.ptr.reset(.{ .retain_with_limit = max_retained_bytes });
            cached_in_use = false;
        } else {
            self.ptr.deinit();
            self.backing.destroy(self.ptr);
        }
    }
};

/// Acquire the thread-local render arena. If a render is already live on this
/// thread (reentrant render, e.g. an extension rendering a template
/// mid-render), falls back to a fresh arena on the caller's allocator so the
/// cached arena is never corrupted.
pub fn acquire(backing: std.mem.Allocator) !ScopedArena {
    if (!cached_in_use) {
        if (cached_arena == null) {
            cached_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        }
        cached_in_use = true;
        return .{ .ptr = &cached_arena.?, .from_cache = true, .backing = backing };
    }
    const ptr = try backing.create(std.heap.ArenaAllocator);
    ptr.* = std.heap.ArenaAllocator.init(backing);
    return .{ .ptr = ptr, .from_cache = false, .backing = backing };
}

/// Free the thread-local cached arena. Optional — the cache is retained for
/// the thread's lifetime by design; call from tests or leak-sensitive hosts.
pub fn deinitThreadArena() void {
    if (cached_arena) |*a| {
        std.debug.assert(!cached_in_use);
        a.deinit();
        cached_arena = null;
    }
}

/// Arena allocator wrapper for render operations
pub const RenderArena = struct {
    arena: std.heap.ArenaAllocator,

    /// Output buffer (allocated on demand from the arena)
    output_buffer: std.ArrayList(u8),

    /// Statistics for diagnostics
    stats: Stats = .{},

    pub const Stats = struct {
        allocations: u64 = 0,
        bytes_allocated: u64 = 0,
    };

    const Self = @This();

    /// Initialize. `estimated_output_size` is retained for API compatibility
    /// but no longer forces an eager backing-allocator chunk allocation — the
    /// output buffer grows on demand from the arena.
    pub fn init(backing: std.mem.Allocator, estimated_output_size: usize) Self {
        _ = estimated_output_size;
        return Self{
            .arena = std.heap.ArenaAllocator.init(backing),
            .output_buffer = std.ArrayList(u8){},
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

//! Counting Allocator Wrapper
//!
//! This module provides an allocator wrapper that tracks allocation statistics
//! for performance profiling and optimization analysis.
//!
//! # Usage
//!
//! ```zig
//! var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//! var counting = CountingAllocator.init(gpa.allocator());
//! const alloc = counting.allocator();
//!
//! // Use alloc for all operations...
//! const data = try alloc.alloc(u8, 1024);
//! defer alloc.free(data);
//!
//! // Check statistics
//! std.debug.print("Allocations: {}\n", .{counting.allocation_count});
//! std.debug.print("Peak memory: {} bytes\n", .{counting.peak_bytes});
//! ```

const std = @import("std");
const diagnostics = @import("diagnostics.zig");

/// Counting allocator that wraps another allocator and tracks allocation statistics
pub const CountingAllocator = struct {
    /// The underlying allocator to delegate to
    parent: std.mem.Allocator,

    /// Total number of allocations made
    allocation_count: u64 = 0,

    /// Total number of deallocations made
    deallocation_count: u64 = 0,

    /// Total bytes allocated (cumulative, not accounting for frees)
    total_bytes: u64 = 0,

    /// Current bytes allocated (allocated - freed)
    current_bytes: u64 = 0,

    /// Peak memory usage (maximum current_bytes seen)
    peak_bytes: u64 = 0,

    /// Number of resize operations
    resize_count: u64 = 0,

    /// Optional diagnostics to update
    diag: ?*diagnostics.RenderDiagnostics = null,

    const Self = @This();

    /// Initialize a counting allocator wrapping another allocator
    pub fn init(parent: std.mem.Allocator) Self {
        return Self{
            .parent = parent,
        };
    }

    /// Initialize with diagnostics tracking
    pub fn initWithDiagnostics(parent: std.mem.Allocator, diag: *diagnostics.RenderDiagnostics) Self {
        return Self{
            .parent = parent,
            .diag = diag,
        };
    }

    /// Get an allocator interface for this counting allocator
    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// Reset all counters to zero
    pub fn reset(self: *Self) void {
        self.allocation_count = 0;
        self.deallocation_count = 0;
        self.total_bytes = 0;
        self.current_bytes = 0;
        self.peak_bytes = 0;
        self.resize_count = 0;
    }

    /// Get a summary of allocation statistics
    pub fn getStats(self: *const Self) AllocationStats {
        return .{
            .allocation_count = self.allocation_count,
            .deallocation_count = self.deallocation_count,
            .total_bytes = self.total_bytes,
            .current_bytes = self.current_bytes,
            .peak_bytes = self.peak_bytes,
            .resize_count = self.resize_count,
        };
    }

    /// Print a summary of allocation statistics
    pub fn printStats(self: *const Self) void {
        std.debug.print(
            \\Allocation Statistics:
            \\  Allocations:   {}
            \\  Deallocations: {}
            \\  Resizes:       {}
            \\  Total bytes:   {} ({} KB)
            \\  Current bytes: {} ({} KB)
            \\  Peak bytes:    {} ({} KB)
            \\
        , .{
            self.allocation_count,
            self.deallocation_count,
            self.resize_count,
            self.total_bytes,
            self.total_bytes / 1024,
            self.current_bytes,
            self.current_bytes / 1024,
            self.peak_bytes,
            self.peak_bytes / 1024,
        });
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Update statistics
        self.allocation_count += 1;
        self.total_bytes += len;
        self.current_bytes += len;
        self.peak_bytes = @max(self.peak_bytes, self.current_bytes);

        // Update diagnostics if available
        if (self.diag) |diag| {
            diag.recordAllocation(len);
        }

        // Delegate to parent allocator
        return self.parent.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;

        // Attempt resize on parent
        const result = self.parent.rawResize(buf, buf_align, new_len, ret_addr);

        if (result) {
            self.resize_count += 1;

            // Update byte tracking
            if (new_len > old_len) {
                const delta = new_len - old_len;
                self.total_bytes += delta;
                self.current_bytes += delta;

                if (self.diag) |diag| {
                    diag.recordAllocation(delta);
                }
            } else if (new_len < old_len) {
                const delta = old_len - new_len;
                if (self.current_bytes >= delta) {
                    self.current_bytes -= delta;
                }

                if (self.diag) |diag| {
                    diag.recordDeallocation(delta);
                }
            }

            self.peak_bytes = @max(self.peak_bytes, self.current_bytes);
        }

        return result;
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;

        // Attempt remap on parent
        const result = self.parent.rawRemap(buf, buf_align, new_len, ret_addr);

        if (result != null) {
            self.resize_count += 1;

            // Update byte tracking
            if (new_len > old_len) {
                const delta = new_len - old_len;
                self.total_bytes += delta;
                self.current_bytes += delta;

                if (self.diag) |diag| {
                    diag.recordAllocation(delta);
                }
            } else if (new_len < old_len) {
                const delta = old_len - new_len;
                if (self.current_bytes >= delta) {
                    self.current_bytes -= delta;
                }

                if (self.diag) |diag| {
                    diag.recordDeallocation(delta);
                }
            }

            self.peak_bytes = @max(self.peak_bytes, self.current_bytes);
        }

        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Update statistics
        self.deallocation_count += 1;
        if (self.current_bytes >= buf.len) {
            self.current_bytes -= buf.len;
        }

        // Update diagnostics if available
        if (self.diag) |diag| {
            diag.recordDeallocation(buf.len);
        }

        // Delegate to parent allocator
        self.parent.rawFree(buf, buf_align, ret_addr);
    }
};

/// Allocation statistics snapshot
pub const AllocationStats = struct {
    allocation_count: u64,
    deallocation_count: u64,
    total_bytes: u64,
    current_bytes: u64,
    peak_bytes: u64,
    resize_count: u64,

    /// Check if there are memory leaks (allocations != deallocations)
    pub fn hasLeaks(self: *const AllocationStats) bool {
        return self.current_bytes > 0;
    }

    /// Get number of outstanding allocations
    pub fn outstandingAllocations(self: *const AllocationStats) u64 {
        if (self.allocation_count >= self.deallocation_count) {
            return self.allocation_count - self.deallocation_count;
        }
        return 0;
    }
};

/// Scoped counting allocator that automatically tracks within a scope
pub const ScopedCountingAllocator = struct {
    counting: CountingAllocator,
    start_stats: AllocationStats,

    const Self = @This();

    /// Create a scoped counting allocator
    pub fn init(parent: std.mem.Allocator) Self {
        var counting = CountingAllocator.init(parent);
        return Self{
            .counting = counting,
            .start_stats = counting.getStats(),
        };
    }

    /// Get the allocator
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.counting.allocator();
    }

    /// Get delta from start
    pub fn getDelta(self: *const Self) AllocationStats {
        const current = self.counting.getStats();
        return .{
            .allocation_count = current.allocation_count - self.start_stats.allocation_count,
            .deallocation_count = current.deallocation_count - self.start_stats.deallocation_count,
            .total_bytes = current.total_bytes - self.start_stats.total_bytes,
            .current_bytes = current.current_bytes,
            .peak_bytes = current.peak_bytes,
            .resize_count = current.resize_count - self.start_stats.resize_count,
        };
    }
};

// Tests
test "CountingAllocator basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var counting = CountingAllocator.init(gpa.allocator());
    const alloc = counting.allocator();

    // Allocate some memory
    const data1 = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(u64, 1), counting.allocation_count);
    try std.testing.expectEqual(@as(u64, 100), counting.current_bytes);
    try std.testing.expectEqual(@as(u64, 100), counting.peak_bytes);

    // Allocate more
    const data2 = try alloc.alloc(u8, 200);
    try std.testing.expectEqual(@as(u64, 2), counting.allocation_count);
    try std.testing.expectEqual(@as(u64, 300), counting.current_bytes);
    try std.testing.expectEqual(@as(u64, 300), counting.peak_bytes);

    // Free first allocation
    alloc.free(data1);
    try std.testing.expectEqual(@as(u64, 1), counting.deallocation_count);
    try std.testing.expectEqual(@as(u64, 200), counting.current_bytes);
    try std.testing.expectEqual(@as(u64, 300), counting.peak_bytes); // Peak unchanged

    // Free second allocation
    alloc.free(data2);
    try std.testing.expectEqual(@as(u64, 2), counting.deallocation_count);
    try std.testing.expectEqual(@as(u64, 0), counting.current_bytes);
}

test "CountingAllocator reset" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var counting = CountingAllocator.init(gpa.allocator());
    const alloc = counting.allocator();

    // Allocate and free
    const data = try alloc.alloc(u8, 100);
    alloc.free(data);

    try std.testing.expect(counting.allocation_count > 0);

    // Reset
    counting.reset();

    try std.testing.expectEqual(@as(u64, 0), counting.allocation_count);
    try std.testing.expectEqual(@as(u64, 0), counting.total_bytes);
    try std.testing.expectEqual(@as(u64, 0), counting.peak_bytes);
}

test "CountingAllocator with diagnostics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var diag = diagnostics.RenderDiagnostics{};
    var counting = CountingAllocator.initWithDiagnostics(gpa.allocator(), &diag);
    const alloc = counting.allocator();

    // Allocate
    const data = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(u64, 1), diag.total_allocations);
    try std.testing.expectEqual(@as(u64, 100), diag.total_bytes_allocated);

    // Free
    alloc.free(data);
}

test "AllocationStats hasLeaks" {
    const stats_no_leaks = AllocationStats{
        .allocation_count = 10,
        .deallocation_count = 10,
        .total_bytes = 1000,
        .current_bytes = 0,
        .peak_bytes = 500,
        .resize_count = 0,
    };
    try std.testing.expect(!stats_no_leaks.hasLeaks());

    const stats_with_leaks = AllocationStats{
        .allocation_count = 10,
        .deallocation_count = 8,
        .total_bytes = 1000,
        .current_bytes = 200,
        .peak_bytes = 500,
        .resize_count = 0,
    };
    try std.testing.expect(stats_with_leaks.hasLeaks());
}

//! Optimized Loop Context
//!
//! This module provides an optimized loop context for for-loops that:
//! - Avoids allocation per iteration
//! - Uses direct field access instead of Dict lookups
//! - References items instead of deep copying
//! - Provides lazy evaluation for previtem/nextitem
//!
//! Performance characteristics:
//! - Zero allocations per iteration (after initial setup)
//! - O(1) access to loop variables (loop.index, loop.first, etc.)
//! - No Dict creation or hashmap operations

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const value_pool = @import("value_pool.zig");

/// Optimized loop context that avoids per-iteration allocations
///
/// Instead of creating a new Dict every iteration with deep-copied values,
/// this struct maintains direct fields that are updated in-place.
pub const OptimizedLoopContext = struct {
    // Loop counters (updated each iteration - no allocation)
    index: i64 = 1, // 1-based index
    index0: i64 = 0, // 0-based index
    revindex: i64 = 0, // Reverse 1-based index
    revindex0: i64 = 0, // Reverse 0-based index
    first: bool = true,
    last: bool = false,
    length: i64 = 0,
    depth: i64 = 1, // Nesting depth (1 for top-level loop)
    depth0: i64 = 0, // 0-based nesting depth

    // Current iteration state - REFERENCES, not copies
    // These point directly into the items array, avoiding deep copies
    current_item_index: usize = 0,

    // Items array reference (owned by caller, not copied)
    items_ptr: [*]const Value = undefined,
    items_len: usize = 0,

    // Loop variable name (for resolution)
    var_name: []const u8 = "",

    // Optional: track if we're in a recursive loop
    // Note: Currently not fully implemented but reserved for future
    parent_loop: ?*const OptimizedLoopContext = null,

    const Self = @This();

    /// Initialize for a new loop
    pub fn init(items: []const Value, var_name: []const u8, parent_loop: ?*const OptimizedLoopContext) Self {
        const len: i64 = @intCast(items.len);
        const depth = if (parent_loop) |p| p.depth + 1 else 1;

        return Self{
            .index = 1,
            .index0 = 0,
            .revindex = len,
            .revindex0 = if (len > 0) len - 1 else 0,
            .first = true,
            .last = items.len <= 1,
            .length = len,
            .depth = depth,
            .depth0 = depth - 1,
            .current_item_index = 0,
            .items_ptr = items.ptr,
            .items_len = items.len,
            .var_name = var_name,
            .parent_loop = parent_loop,
        };
    }

    /// Advance to the next iteration
    /// This is O(1) with no allocations
    pub fn advance(self: *Self) void {
        self.current_item_index += 1;
        const i: i64 = @intCast(self.current_item_index);

        self.index = i + 1;
        self.index0 = i;
        self.revindex = self.length - i;
        self.revindex0 = if (self.length > i + 1) self.length - i - 1 else 0;
        self.first = false;
        self.last = (i + 1 >= self.length);
    }

    /// Get current item (no copy - returns reference)
    pub fn getCurrentItem(self: *const Self) Value {
        if (self.current_item_index < self.items_len) {
            return self.items_ptr[self.current_item_index];
        }
        return value_pool.getNull(); // Use pool singleton
    }

    /// Get previous item (no copy - returns reference)
    pub fn getPrevItem(self: *const Self) Value {
        if (self.current_item_index > 0) {
            return self.items_ptr[self.current_item_index - 1];
        }
        return value_pool.getNull(); // Use pool singleton
    }

    /// Get next item (no copy - returns reference)
    pub fn getNextItem(self: *const Self) Value {
        if (self.current_item_index + 1 < self.items_len) {
            return self.items_ptr[self.current_item_index + 1];
        }
        return value_pool.getNull(); // Use pool singleton
    }

    /// Check if this is the variable we're looking for
    pub fn isLoopVar(self: *const Self, name: []const u8) bool {
        return std.mem.eql(u8, name, self.var_name);
    }

    /// Resolve a loop.* attribute directly (no Dict creation)
    /// Returns null if not a loop attribute
    /// Uses ValuePool for booleans to avoid allocations
    pub fn resolveLoopAttr(self: *const Self, attr: []const u8) ?Value {
        // Fast switch on first character for common attributes
        if (attr.len == 0) return null;

        return switch (attr[0]) {
            'i' => blk: {
                if (std.mem.eql(u8, attr, "index")) {
                    break :blk Value{ .integer = self.index };
                } else if (std.mem.eql(u8, attr, "index0")) {
                    break :blk Value{ .integer = self.index0 };
                }
                break :blk null;
            },
            // Use pool for boolean values (no allocation)
            'f' => if (std.mem.eql(u8, attr, "first")) value_pool.getBool(self.first) else null,
            'l' => blk: {
                if (std.mem.eql(u8, attr, "last")) {
                    // Use pool for boolean (no allocation)
                    break :blk value_pool.getBool(self.last);
                } else if (std.mem.eql(u8, attr, "length")) {
                    break :blk Value{ .integer = self.length };
                }
                break :blk null;
            },
            'r' => blk: {
                if (std.mem.eql(u8, attr, "revindex")) {
                    break :blk Value{ .integer = self.revindex };
                } else if (std.mem.eql(u8, attr, "revindex0")) {
                    break :blk Value{ .integer = self.revindex0 };
                }
                break :blk null;
            },
            'd' => blk: {
                if (std.mem.eql(u8, attr, "depth")) {
                    break :blk Value{ .integer = self.depth };
                } else if (std.mem.eql(u8, attr, "depth0")) {
                    break :blk Value{ .integer = self.depth0 };
                }
                break :blk null;
            },
            'p' => if (std.mem.eql(u8, attr, "previtem")) self.getPrevItem() else null,
            'n' => if (std.mem.eql(u8, attr, "nextitem")) self.getNextItem() else null,
            else => null,
        };
    }

    /// Check if we have more iterations
    pub fn hasMore(self: *const Self) bool {
        return self.current_item_index < self.items_len;
    }

    /// Reset for reuse (e.g., in nested loops)
    pub fn reset(self: *Self, items: []const Value, var_name: []const u8) void {
        const len: i64 = @intCast(items.len);

        self.index = 1;
        self.index0 = 0;
        self.revindex = len;
        self.revindex0 = if (len > 0) len - 1 else 0;
        self.first = true;
        self.last = items.len <= 1;
        self.length = len;
        self.current_item_index = 0;
        self.items_ptr = items.ptr;
        self.items_len = items.len;
        self.var_name = var_name;
    }
};

/// A synthetic Dict-like Value that wraps OptimizedLoopContext
/// This allows `loop` to be used as a dict (loop["index"]) while avoiding allocation
pub const LoopProxy = struct {
    loop_ctx: *const OptimizedLoopContext,

    const Self = @This();

    pub fn init(loop_ctx: *const OptimizedLoopContext) Self {
        return Self{ .loop_ctx = loop_ctx };
    }

    /// Get an attribute from the loop context
    pub fn get(self: *const Self, key: []const u8) ?Value {
        return self.loop_ctx.resolveLoopAttr(key);
    }
};

// Tests
test "OptimizedLoopContext basic iteration" {
    const items = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
        Value{ .integer = 3 },
    };

    var loop = OptimizedLoopContext.init(&items, "i", null);

    // First iteration
    try std.testing.expectEqual(@as(i64, 1), loop.index);
    try std.testing.expectEqual(@as(i64, 0), loop.index0);
    try std.testing.expect(loop.first);
    try std.testing.expect(!loop.last);
    try std.testing.expectEqual(@as(i64, 3), loop.length);

    const item1 = loop.getCurrentItem();
    try std.testing.expectEqual(@as(i64, 1), item1.integer);

    // Second iteration
    loop.advance();
    try std.testing.expectEqual(@as(i64, 2), loop.index);
    try std.testing.expectEqual(@as(i64, 1), loop.index0);
    try std.testing.expect(!loop.first);
    try std.testing.expect(!loop.last);

    const prev = loop.getPrevItem();
    try std.testing.expectEqual(@as(i64, 1), prev.integer);

    const item2 = loop.getCurrentItem();
    try std.testing.expectEqual(@as(i64, 2), item2.integer);

    const next = loop.getNextItem();
    try std.testing.expectEqual(@as(i64, 3), next.integer);

    // Third iteration (last)
    loop.advance();
    try std.testing.expectEqual(@as(i64, 3), loop.index);
    try std.testing.expect(loop.last);
}

test "OptimizedLoopContext resolveLoopAttr" {
    const items = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
    };

    var loop = OptimizedLoopContext.init(&items, "item", null);

    // Test all attributes
    try std.testing.expectEqual(@as(i64, 1), loop.resolveLoopAttr("index").?.integer);
    try std.testing.expectEqual(@as(i64, 0), loop.resolveLoopAttr("index0").?.integer);
    try std.testing.expectEqual(@as(i64, 2), loop.resolveLoopAttr("revindex").?.integer);
    try std.testing.expectEqual(@as(i64, 1), loop.resolveLoopAttr("revindex0").?.integer);
    try std.testing.expect(loop.resolveLoopAttr("first").?.boolean);
    try std.testing.expect(!loop.resolveLoopAttr("last").?.boolean);
    try std.testing.expectEqual(@as(i64, 2), loop.resolveLoopAttr("length").?.integer);
    try std.testing.expectEqual(@as(i64, 1), loop.resolveLoopAttr("depth").?.integer);
    try std.testing.expectEqual(@as(i64, 0), loop.resolveLoopAttr("depth0").?.integer);

    // Unknown attribute
    try std.testing.expect(loop.resolveLoopAttr("unknown") == null);
}

test "OptimizedLoopContext empty loop" {
    const items = [_]Value{};

    var loop = OptimizedLoopContext.init(&items, "i", null);

    try std.testing.expectEqual(@as(i64, 0), loop.length);
    try std.testing.expect(!loop.hasMore());
}

test "OptimizedLoopContext single item" {
    const items = [_]Value{Value{ .integer = 42 }};

    const loop = OptimizedLoopContext.init(&items, "x", null);

    try std.testing.expect(loop.first);
    try std.testing.expect(loop.last);
    try std.testing.expectEqual(@as(i64, 1), loop.length);
}

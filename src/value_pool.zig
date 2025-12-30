//! Value Pool - Phase 2 Memory Optimization
//!
//! Provides flyweight/singleton values for common cases to avoid
//! unnecessary allocations. Instead of creating new Value objects
//! for common values like true, false, null, small integers, etc.,
//! we return pre-allocated singleton instances.
//!
//! Benefits:
//! - Zero allocations for boolean values
//! - Zero allocations for small integers (-128 to 127)
//! - Zero allocations for null
//! - Reduced memory pressure

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

/// Pool of commonly-used values to avoid allocations
pub const ValuePool = struct {
    // Small integer cache (-128 to 127, like Python/Java)
    small_ints: [256]Value,

    // Interned strings (optional, for frequently used strings)
    string_cache: std.StringHashMap([]const u8),

    allocator: std.mem.Allocator,

    const Self = @This();

    // ============================================================
    // Singleton common values (no allocation needed)
    // ============================================================

    /// Boolean true singleton
    pub const TRUE = Value{ .boolean = true };

    /// Boolean false singleton
    pub const FALSE = Value{ .boolean = false };

    /// Null singleton
    pub const NULL = Value{ .null = {} };

    /// Zero integer singleton
    pub const ZERO = Value{ .integer = 0 };

    /// One integer singleton
    pub const ONE = Value{ .integer = 1 };

    /// Empty string singleton (doesn't own memory)
    pub const EMPTY_STRING = Value{ .string = "" };

    // ============================================================
    // Pool instance methods
    // ============================================================

    pub fn init(allocator: std.mem.Allocator) Self {
        var pool = Self{
            .small_ints = undefined,
            .string_cache = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };

        // Pre-populate small integers (-128 to 127)
        for (&pool.small_ints, 0..) |*v, i| {
            const n: i64 = @as(i64, @intCast(i)) - 128;
            v.* = Value{ .integer = n };
        }

        return pool;
    }

    pub fn deinit(self: *Self) void {
        // Free interned strings
        var iter = self.string_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.string_cache.deinit();
    }

    /// Get integer value, using cache for small integers
    pub fn getInt(self: *const Self, n: i64) Value {
        if (n >= -128 and n <= 127) {
            const index: usize = @intCast(n + 128);
            return self.small_ints[index];
        }
        return Value{ .integer = n };
    }

    /// Get boolean value (always uses singleton)
    pub fn getBool(_: *const Self, b: bool) Value {
        return if (b) TRUE else FALSE;
    }

    /// Get null value (always uses singleton)
    pub fn getNull(_: *const Self) Value {
        return NULL;
    }

    /// Intern a string (cache for reuse)
    pub fn internString(self: *Self, s: []const u8) ![]const u8 {
        if (s.len == 0) return "";

        if (self.string_cache.get(s)) |cached| {
            return cached;
        }

        const owned = try self.allocator.dupe(u8, s);
        try self.string_cache.put(owned, owned);
        return owned;
    }

    // ============================================================
    // Static helper functions (no pool instance needed)
    // ============================================================

    /// Get boolean without pool instance
    pub fn getBoolStatic(b: bool) Value {
        return if (b) TRUE else FALSE;
    }

    /// Get small integer without pool instance (returns null if out of range)
    pub fn getSmallIntStatic(n: i64) ?Value {
        if (n >= -128 and n <= 127) {
            return Value{ .integer = n };
        }
        return null;
    }

    /// Check if a value is a pool singleton (doesn't need deallocation)
    pub fn isSingleton(val: Value) bool {
        return switch (val) {
            .boolean => true, // All booleans are effectively singletons
            .null => true,
            .integer => |n| n >= -128 and n <= 127,
            .string => |s| s.len == 0, // Empty string
            else => false,
        };
    }
};

// ============================================================
// Global convenience functions
// ============================================================

/// Get boolean value (no pool needed)
pub inline fn getBool(b: bool) Value {
    return ValuePool.getBoolStatic(b);
}

/// Get null value (no pool needed)
pub inline fn getNull() Value {
    return ValuePool.NULL;
}

/// Get true value
pub inline fn getTrue() Value {
    return ValuePool.TRUE;
}

/// Get false value
pub inline fn getFalse() Value {
    return ValuePool.FALSE;
}

/// Get zero
pub inline fn getZero() Value {
    return ValuePool.ZERO;
}

/// Get one
pub inline fn getOne() Value {
    return ValuePool.ONE;
}

/// Get empty string
pub inline fn getEmptyString() Value {
    return ValuePool.EMPTY_STRING;
}

// Tests
test "ValuePool singleton values" {
    try std.testing.expectEqual(true, ValuePool.TRUE.boolean);
    try std.testing.expectEqual(false, ValuePool.FALSE.boolean);
    try std.testing.expectEqual(@as(i64, 0), ValuePool.ZERO.integer);
    try std.testing.expectEqual(@as(i64, 1), ValuePool.ONE.integer);
    try std.testing.expectEqualStrings("", ValuePool.EMPTY_STRING.string);
}

test "ValuePool getBool" {
    const t = getBool(true);
    const f = getBool(false);

    try std.testing.expectEqual(true, t.boolean);
    try std.testing.expectEqual(false, f.boolean);
}

test "ValuePool small integers" {
    const allocator = std.testing.allocator;
    var pool = ValuePool.init(allocator);
    defer pool.deinit();

    // Test cached range
    try std.testing.expectEqual(@as(i64, -128), pool.getInt(-128).integer);
    try std.testing.expectEqual(@as(i64, 0), pool.getInt(0).integer);
    try std.testing.expectEqual(@as(i64, 127), pool.getInt(127).integer);

    // Test outside range (not cached, but still works)
    try std.testing.expectEqual(@as(i64, 1000), pool.getInt(1000).integer);
    try std.testing.expectEqual(@as(i64, -1000), pool.getInt(-1000).integer);
}

test "ValuePool isSingleton" {
    try std.testing.expect(ValuePool.isSingleton(Value{ .boolean = true }));
    try std.testing.expect(ValuePool.isSingleton(Value{ .boolean = false }));
    try std.testing.expect(ValuePool.isSingleton(Value{ .null = {} }));
    try std.testing.expect(ValuePool.isSingleton(Value{ .integer = 0 }));
    try std.testing.expect(ValuePool.isSingleton(Value{ .integer = 127 }));
    try std.testing.expect(ValuePool.isSingleton(Value{ .integer = -128 }));
    try std.testing.expect(!ValuePool.isSingleton(Value{ .integer = 1000 }));
    try std.testing.expect(ValuePool.isSingleton(Value{ .string = "" }));
}

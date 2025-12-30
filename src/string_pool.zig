//! String Pool - Interns strings to avoid duplicate allocations
//! Phase 4 optimization for string-heavy templates
//!
//! Template literals are interned at compile time, allowing:
//! - Zero-copy string references during render
//! - Reduced memory usage for repeated strings
//! - Fast string comparison by pointer equality

const std = @import("std");

/// String pool for interning template literals
/// All strings are stored once and referenced by index
pub const StringPool = struct {
    /// Map from string content to index
    strings: std.StringArrayHashMap(u32),
    /// Storage for all interned strings
    storage: std.ArrayList([]const u8),
    /// Allocator for string storage
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new string pool
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .strings = std.StringArrayHashMap(u32).init(allocator),
            .storage = std.ArrayList([]const u8).empty,
            .allocator = allocator,
        };
    }

    /// Deinitialize the string pool
    pub fn deinit(self: *Self) void {
        // Free all stored strings
        for (self.storage.items) |s| {
            self.allocator.free(s);
        }
        self.storage.deinit(self.allocator);
        self.strings.deinit();
    }

    /// Intern a string - returns index for later retrieval
    /// If string already exists, returns existing index (no allocation)
    pub fn intern(self: *Self, s: []const u8) !u32 {
        // Check if already interned
        if (self.strings.get(s)) |idx| {
            return idx;
        }

        // New string - store it
        const idx: u32 = @intCast(self.storage.items.len);
        const owned = try self.allocator.dupe(u8, s);
        errdefer self.allocator.free(owned);

        try self.storage.append(self.allocator, owned);
        try self.strings.put(owned, idx);

        return idx;
    }

    /// Get string by index (O(1) lookup)
    pub fn get(self: *const Self, idx: u32) []const u8 {
        return self.storage.items[idx];
    }

    /// Check if a string is already interned
    pub fn contains(self: *const Self, s: []const u8) bool {
        return self.strings.contains(s);
    }

    /// Get the index of an existing string (returns null if not found)
    pub fn indexOf(self: *const Self, s: []const u8) ?u32 {
        return self.strings.get(s);
    }

    /// Number of interned strings
    pub fn count(self: *const Self) usize {
        return self.storage.items.len;
    }

    /// Total bytes stored
    pub fn totalBytes(self: *const Self) usize {
        var total: usize = 0;
        for (self.storage.items) |s| {
            total += s.len;
        }
        return total;
    }
};

/// Interned string reference - zero-copy string that references pool
pub const InternedString = struct {
    pool: *const StringPool,
    index: u32,

    /// Get the actual string slice (no allocation)
    pub fn slice(self: InternedString) []const u8 {
        return self.pool.get(self.index);
    }

    /// Compare two interned strings (fast - pointer comparison if same pool)
    pub fn eql(self: InternedString, other: InternedString) bool {
        if (self.pool == other.pool) {
            // Same pool - can compare indices directly
            return self.index == other.index;
        }
        // Different pools - must compare content
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

// Tests
test "StringPool basic operations" {
    const allocator = std.testing.allocator;

    var pool = StringPool.init(allocator);
    defer pool.deinit();

    // Intern strings
    const idx1 = try pool.intern("hello");
    const idx2 = try pool.intern("world");
    const idx3 = try pool.intern("hello"); // Should return same index

    try std.testing.expectEqual(idx1, idx3); // Same string = same index
    try std.testing.expect(idx1 != idx2); // Different strings = different indices

    // Retrieve strings
    try std.testing.expectEqualStrings("hello", pool.get(idx1));
    try std.testing.expectEqualStrings("world", pool.get(idx2));

    // Count
    try std.testing.expectEqual(@as(usize, 2), pool.count());
}

test "StringPool interned string comparison" {
    const allocator = std.testing.allocator;

    var pool = StringPool.init(allocator);
    defer pool.deinit();

    const idx1 = try pool.intern("test");
    const idx2 = try pool.intern("test");

    const s1 = InternedString{ .pool = &pool, .index = idx1 };
    const s2 = InternedString{ .pool = &pool, .index = idx2 };

    try std.testing.expect(s1.eql(s2)); // Should be equal (same pool, same index)
    try std.testing.expectEqualStrings("test", s1.slice());
}

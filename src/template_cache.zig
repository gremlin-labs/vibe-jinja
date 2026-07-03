const std = @import("std");
const nodes = @import("nodes.zig");

/// LRU Cache node for doubly-linked list
const LRUNode = struct {
    key: []const u8,
    value: *TemplateCacheEntry,
    prev: ?*LRUNode,
    next: ?*LRUNode,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, key: []const u8, value: *TemplateCacheEntry) !Self {
        return Self{
            .key = try allocator.dupe(u8, key),
            .value = value,
            .prev = null,
            .next = null,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

/// Template cache entry
///
/// Represents a single entry in the template cache, storing the compiled template AST
/// along with metadata for cache management and auto-reload functionality.
pub const TemplateCacheEntry = struct {
    template: *nodes.Template,
    last_modified: i64, // Unix timestamp
    access_count: usize, // Number of times accessed
    source_checksum: u64, // Hash/checksum of template source (for auto-reload)

    pub fn deinit(self: *TemplateCacheEntry, allocator: std.mem.Allocator) void {
        self.template.deinit(allocator);
        allocator.destroy(self.template);
    }

    /// Calculate checksum of source content
    pub fn calculateChecksum(source: []const u8) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(source);
        return hasher.final();
    }
};

/// LRU Cache for templates
///
/// An LRU (Least Recently Used) cache implementation for storing compiled templates.
/// When the cache reaches capacity, the least recently used template is evicted.
///
/// The cache tracks statistics including hits, misses, and evictions for monitoring
/// cache performance.
///
/// # Example
///
/// ```zig
/// var cache = jinja.cache.LRUCache.init(allocator, 100);
/// defer cache.deinit();
///
/// // Add template to cache
/// const entry = try allocator.create(jinja.cache.TemplateCacheEntry);
/// entry.* = jinja.cache.TemplateCacheEntry{
///     .template = template,
///     .last_modified = std.time.timestamp(),
///     .access_count = 0,
///     .source_checksum = checksum,
/// };
/// try cache.put("template.jinja", entry);
///
/// // Get template from cache
/// if (cache.get("template.jinja")) |entry| {
///     // Use entry.template
/// }
///
/// // Get statistics
/// const stats = cache.getStats();
/// std.debug.print("Hit rate: {d:.2}%\n", .{stats.hit_rate * 100.0});
/// ```
pub const LRUCache = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    map: std.StringHashMap(*LRUNode),
    head: ?*LRUNode,
    tail: ?*LRUNode,

    // Statistics
    hits: usize,
    misses: usize,
    evictions: usize,

    const Self = @This();

    /// Initialize a new LRU cache
    pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
        return Self{
            .allocator = allocator,
            .capacity = capacity,
            .map = std.StringHashMap(*LRUNode).init(allocator),
            .head = null,
            .tail = null,
            .hits = 0,
            .misses = 0,
            .evictions = 0,
        };
    }

    /// Deinitialize the cache and free all memory
    pub fn deinit(self: *Self) void {
        // Free all nodes
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            node.value.deinit(self.allocator);
            self.allocator.destroy(node.value);
            node.deinit(self.allocator);
            self.allocator.destroy(node);
            current = next;
        }
        self.map.deinit();
    }

    /// Get a value from the cache
    pub fn get(self: *Self, key: []const u8) ?*TemplateCacheEntry {
        if (self.map.get(key)) |node| {
            // Move to front (most recently used)
            self.moveToFront(node);
            self.hits += 1;
            node.value.access_count += 1;
            return node.value;
        }
        self.misses += 1;
        return null;
    }

    /// Put a value into the cache
    pub fn put(self: *Self, key: []const u8, value: *TemplateCacheEntry) !void {
        // Check if key already exists
        if (self.map.get(key)) |existing_node| {
            // Update value and move to front
            existing_node.value.deinit(self.allocator);
            self.allocator.destroy(existing_node.value);
            existing_node.value = value;
            self.moveToFront(existing_node);
            return;
        }

        // Check if we need to evict
        if (self.map.count() >= self.capacity) {
            try self.evict();
        }

        // Create new node
        const node = try self.allocator.create(LRUNode);
        errdefer self.allocator.destroy(node);
        node.* = try LRUNode.init(self.allocator, key, value);

        // Add to front
        self.addToFront(node);

        // Add to map
        try self.map.put(node.key, node);
    }

    /// Remove a value from the cache
    pub fn remove(self: *Self, key: []const u8) bool {
        if (self.map.fetchRemove(key)) |kv| {
            const node = kv.value;
            self.removeNode(node);
            node.value.deinit(self.allocator);
            self.allocator.destroy(node.value);
            node.deinit(self.allocator);
            self.allocator.destroy(node);
            return true;
        }
        return false;
    }

    /// Get cache statistics
    pub fn getStats(self: *const Self) CacheStats {
        const total = self.hits + self.misses;
        const hit_rate = if (total > 0) @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) else 0.0;

        return CacheStats{
            .size = self.map.count(),
            .capacity = self.capacity,
            .hits = self.hits,
            .misses = self.misses,
            .evictions = self.evictions,
            .hit_rate = hit_rate,
        };
    }

    /// Get current cache size
    pub fn count(self: *const Self) usize {
        return self.map.count();
    }

    /// Clear the cache
    pub fn clear(self: *Self) void {
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            node.value.deinit(self.allocator);
            self.allocator.destroy(node.value);
            node.deinit(self.allocator);
            self.allocator.destroy(node);
            current = next;
        }
        self.map.clearAndFree();
        self.head = null;
        self.tail = null;
    }

    /// Move node to front (most recently used)
    fn moveToFront(self: *Self, node: *LRUNode) void {
        if (self.head == node) {
            return; // Already at front
        }

        self.removeNode(node);
        self.addToFront(node);
    }

    /// Add node to front
    fn addToFront(self: *Self, node: *LRUNode) void {
        node.prev = null;
        node.next = self.head;

        if (self.head) |head| {
            head.prev = node;
        } else {
            self.tail = node;
        }

        self.head = node;
    }

    /// Remove node from list
    fn removeNode(self: *Self, node: *LRUNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.head = node.next;
        }

        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.tail = node.prev;
        }
    }

    /// Evict least recently used item
    fn evict(self: *Self) !void {
        if (self.tail) |tail| {
            _ = self.map.remove(tail.key);
            self.removeNode(tail);
            tail.value.deinit(self.allocator);
            self.allocator.destroy(tail.value);
            tail.deinit(self.allocator);
            self.allocator.destroy(tail);
            self.evictions += 1;
        }
    }
};

/// Cache statistics
///
/// Provides statistics about cache performance including hit rate, misses, and evictions.
pub const CacheStats = struct {
    size: usize,
    capacity: usize,
    hits: usize,
    misses: usize,
    evictions: usize,
    hit_rate: f64,
};

// ============================================================================

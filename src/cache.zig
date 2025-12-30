//! Template Caching System
//!
//! This module provides caching infrastructure for compiled templates and bytecode.
//! Caching significantly improves performance by avoiding re-parsing and re-compiling
//! templates that haven't changed.
//!
//! # Template Cache
//!
//! The `LRUCache` stores compiled template ASTs with automatic eviction of least-recently-used
//! entries when the cache reaches its size limit. Features include:
//!
//! - **LRU Eviction**: Automatically evicts least-recently-used templates
//! - **Size Limit**: Configurable maximum number of cached templates
//! - **Auto-Reload**: Detects template changes via checksums and timestamps
//! - **Statistics**: Hit rate, miss count, and eviction tracking
//!
//! # Bytecode Cache
//!
//! The `BytecodeCache` interface allows storing compiled bytecode to persistent storage,
//! enabling caching across process restarts. Implementations include:
//!
//! - **FileSystemBytecodeCache**: Stores bytecode in files on disk
//! - **MemcachedBytecodeCache**: Stores bytecode in a Memcached server
//!
//! # Usage
//!
//! ```zig
//! // Template caching is automatic when using Environment
//! var env = jinja.Environment.init(allocator);
//! // cache_size = 400 by default
//!
//! // Access cache statistics
//! if (env.getCacheStats()) |stats| {
//!     std.debug.print("Hit rate: {d:.1}%\n", .{stats.hitRate() * 100});
//! }
//!
//! // Clear cache when templates change
//! env.clearTemplateCache();
//! ```
//!
//! # Bytecode Cache Usage
//!
//! ```zig
//! var fs_cache = try jinja.cache.FileSystemBytecodeCache.init(allocator, "/tmp/jinja_cache", null);
//! defer fs_cache.deinit();
//!
//! // Check if bytecode exists
//! if (try fs_cache.cache.loadBytecode("template_key")) |bytecode| {
//!     // Use cached bytecode
//! }
//!
//! // Store bytecode
//! try fs_cache.cache.dumpBytecode("template_key", bytecode, checksum);
//! ```

const std = @import("std");
const nodes = @import("nodes.zig");
const bytecode_mod = @import("bytecode.zig");

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
// Bytecode Cache
// ============================================================================

/// Magic bytes to identify Jinja bytecode cache files
/// Format: "vj2" + version (1 byte) + zig_version_major (1 byte) + zig_version_minor (1 byte)
pub const bc_magic: [6]u8 = .{ 'v', 'j', '2', bc_version, @truncate(@as(u32, @intCast(@import("builtin").zig_version.major))), @truncate(@as(u32, @intCast(@import("builtin").zig_version.minor))) };

/// Bytecode cache version - increment when bytecode format changes
pub const bc_version: u8 = 1;

/// Bucket for storing bytecode for one template
/// Contains checksum for automatic cache invalidation
pub const Bucket = struct {
    key: []const u8,
    checksum: u64,
    bytecode: ?bytecode_mod.Bytecode,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new bucket
    pub fn init(allocator: std.mem.Allocator, key: []const u8, checksum: u64) !Self {
        return Self{
            .key = try allocator.dupe(u8, key),
            .checksum = checksum,
            .bytecode = null,
            .allocator = allocator,
        };
    }

    /// Deinitialize the bucket
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.key);
        if (self.bytecode) |*bc| {
            bc.deinit();
        }
    }

    /// Reset the bucket (unload bytecode)
    pub fn reset(self: *Self) void {
        if (self.bytecode) |*bc| {
            bc.deinit();
        }
        self.bytecode = null;
    }

    /// Load bytecode from a reader
    pub fn loadBytecode(self: *Self, reader: anytype) !void {
        // Read and verify magic header
        var magic: [6]u8 = undefined;
        const bytes_read = try reader.readAll(&magic);
        if (bytes_read != 6 or !std.mem.eql(u8, &magic, &bc_magic)) {
            self.reset();
            return;
        }

        // Read checksum
        const stored_checksum = try reader.readInt(u64, .little);
        if (stored_checksum != self.checksum) {
            self.reset();
            return;
        }

        // Deserialize bytecode
        self.bytecode = try deserializeBytecode(self.allocator, reader);
    }

    /// Write bytecode to a writer
    pub fn writeBytecode(self: *Self, writer: anytype) !void {
        if (self.bytecode == null) {
            return error.EmptyBucket;
        }

        // Write magic header
        try writer.writeAll(&bc_magic);

        // Write checksum
        try writer.writeInt(u64, self.checksum, .little);

        // Serialize bytecode
        try serializeBytecode(self.bytecode.?, writer);
    }

    /// Load bytecode from bytes
    pub fn bytecodeFromString(self: *Self, data: []const u8) !void {
        var stream = std.io.fixedBufferStream(data);
        try self.loadBytecode(stream.reader());
    }

    /// Return bytecode as bytes
    pub fn bytecodeToString(self: *Self) ![]const u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(self.allocator);
        try self.writeBytecode(buf.writer(self.allocator));
        return try buf.toOwnedSlice(self.allocator);
    }
};

/// Serialize bytecode to a writer
fn serializeBytecode(bc: bytecode_mod.Bytecode, writer: anytype) !void {
    // Write instruction count
    try writer.writeInt(u32, @intCast(bc.instructions.items.len), .little);

    // Write instructions
    for (bc.instructions.items) |instr| {
        try writer.writeInt(u8, @intFromEnum(instr.opcode), .little);
        try writer.writeInt(u32, instr.operand, .little);
    }

    // Write string pool
    try writer.writeInt(u32, @intCast(bc.strings.items.len), .little);
    for (bc.strings.items) |str| {
        try writer.writeInt(u32, @intCast(str.len), .little);
        try writer.writeAll(str);
    }

    // Write name pool
    try writer.writeInt(u32, @intCast(bc.names.items.len), .little);
    for (bc.names.items) |name| {
        try writer.writeInt(u32, @intCast(name.len), .little);
        try writer.writeAll(name);
    }

    // Note: constants pool contains AST node pointers which cannot be serialized
    // The bytecode must be regenerated if constants are needed
    try writer.writeInt(u32, 0, .little); // Placeholder for constants count
}

/// Deserialize bytecode from a reader
fn deserializeBytecode(allocator: std.mem.Allocator, reader: anytype) !bytecode_mod.Bytecode {
    var bc = bytecode_mod.Bytecode.init(allocator);
    errdefer bc.deinit();

    // Read instruction count
    const instr_count = try reader.readInt(u32, .little);

    // Read instructions
    var i: u32 = 0;
    while (i < instr_count) : (i += 1) {
        const opcode_byte = try reader.readInt(u8, .little);
        const operand = try reader.readInt(u32, .little);
        const opcode = @as(bytecode_mod.Opcode, @enumFromInt(opcode_byte));
        try bc.addInstruction(opcode, operand);
    }

    // Read string pool
    const str_count = try reader.readInt(u32, .little);
    var s: u32 = 0;
    while (s < str_count) : (s += 1) {
        const str_len = try reader.readInt(u32, .little);
        const str = try allocator.alloc(u8, str_len);
        errdefer allocator.free(str);
        const bytes_read = try reader.readAll(str);
        if (bytes_read != str_len) {
            allocator.free(str);
            return error.UnexpectedEof;
        }
        try bc.strings.append(allocator, str);
    }

    // Read name pool
    const name_count = try reader.readInt(u32, .little);
    var n: u32 = 0;
    while (n < name_count) : (n += 1) {
        const name_len = try reader.readInt(u32, .little);
        const name = try allocator.alloc(u8, name_len);
        errdefer allocator.free(name);
        const bytes_read = try reader.readAll(name);
        if (bytes_read != name_len) {
            allocator.free(name);
            return error.UnexpectedEof;
        }
        try bc.names.append(allocator, name);
    }

    // Read constants placeholder (always 0 for now)
    _ = try reader.readInt(u32, .little);

    return bc;
}

/// Bytecode cache interface
/// Subclasses implement loadBytecode and dumpBytecode
pub const BytecodeCache = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        loadBytecode: *const fn (ptr: *anyopaque, bucket: *Bucket) void,
        dumpBytecode: *const fn (ptr: *anyopaque, bucket: *Bucket) anyerror!void,
        clear: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Load bytecode into bucket (if available)
    pub fn loadBytecode(self: *BytecodeCache, bucket: *Bucket) void {
        self.vtable.loadBytecode(self.ptr, bucket);
    }

    /// Dump bytecode from bucket to cache
    pub fn dumpBytecode(self: *BytecodeCache, bucket: *Bucket) !void {
        try self.vtable.dumpBytecode(self.ptr, bucket);
    }

    /// Clear the cache
    pub fn clear(self: *BytecodeCache) void {
        self.vtable.clear(self.ptr);
    }

    /// Deinitialize the cache
    pub fn deinit(self: *BytecodeCache) void {
        self.vtable.deinit(self.ptr);
    }

    /// Get cache key for a template
    pub fn getCacheKey(name: []const u8, filename: ?[]const u8) [40]u8 {
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(name);
        if (filename) |f| {
            hasher.update("|");
            hasher.update(f);
        }
        const digest = hasher.finalResult();

        // Convert to hex string
        var result: [40]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (digest, 0..) |byte, i| {
            result[i * 2] = hex_chars[byte >> 4];
            result[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        return result;
    }

    /// Get checksum for template source
    pub fn getSourceChecksum(source: []const u8) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(source);
        return hasher.final();
    }

    /// Get a bucket for the given template
    pub fn getBucket(self: *BytecodeCache, allocator: std.mem.Allocator, name: []const u8, filename: ?[]const u8, source: []const u8) !*Bucket {
        const key = getCacheKey(name, filename);
        const checksum = getSourceChecksum(source);

        const bucket = try allocator.create(Bucket);
        errdefer allocator.destroy(bucket);
        bucket.* = try Bucket.init(allocator, &key, checksum);

        // Try to load existing bytecode
        self.loadBytecode(bucket);

        return bucket;
    }

    /// Put bucket into cache
    pub fn setBucket(self: *BytecodeCache, bucket: *Bucket) !void {
        try self.dumpBytecode(bucket);
    }
};

/// File system bytecode cache
/// Stores bytecode files on disk for persistence across application restarts
pub const FileSystemBytecodeCache = struct {
    allocator: std.mem.Allocator,
    directory: []const u8,
    pattern: []const u8,
    cache: BytecodeCache,

    const Self = @This();

    /// Default cache pattern
    pub const DEFAULT_PATTERN = "__jinja2_%s.cache";

    /// Initialize with directory and optional pattern
    /// If directory is null, uses system temp directory
    pub fn init(allocator: std.mem.Allocator, directory: ?[]const u8, pattern: ?[]const u8) !Self {
        const dir = if (directory) |d|
            try allocator.dupe(u8, d)
        else
            try getDefaultCacheDir(allocator);
        errdefer allocator.free(dir);

        const pat = try allocator.dupe(u8, pattern orelse DEFAULT_PATTERN);

        // Ensure directory exists
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var self = Self{
            .allocator = allocator,
            .directory = dir,
            .pattern = pat,
            .cache = undefined,
        };

        self.cache = BytecodeCache{
            .ptr = @ptrCast(&self),
            .vtable = &vtable,
        };

        return self;
    }

    /// Get cache interface
    pub fn getCache(self: *Self) *BytecodeCache {
        self.cache.ptr = @ptrCast(self);
        return &self.cache;
    }

    /// Deinitialize
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.directory);
        self.allocator.free(self.pattern);
    }

    /// Get default cache directory
    fn getDefaultCacheDir(allocator: std.mem.Allocator) ![]const u8 {
        // Use a user-specific subdirectory in /tmp
        const dirname = "_jinja2-cache";

        // Check if /tmp exists by trying to access it
        std.fs.cwd().access("/tmp", .{}) catch {
            // Fall back to current directory
            return try allocator.dupe(u8, ".jinja2_cache");
        };

        return try std.fmt.allocPrint(allocator, "/tmp/{s}", .{dirname});
    }

    /// Get cache filename for a bucket
    fn getCacheFilename(self: *Self, bucket: *Bucket) ![]const u8 {
        // Replace %s in pattern with bucket key
        var result = std.ArrayList(u8){};
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.pattern.len) {
            if (i + 1 < self.pattern.len and self.pattern[i] == '%' and self.pattern[i + 1] == 's') {
                try result.appendSlice(self.allocator, bucket.key);
                i += 2;
            } else {
                try result.append(self.allocator, self.pattern[i]);
                i += 1;
            }
        }

        const filename = try result.toOwnedSlice(self.allocator);
        defer self.allocator.free(filename);

        return try std.fs.path.join(self.allocator, &[_][]const u8{ self.directory, filename });
    }

    /// VTable implementation
    const vtable = BytecodeCache.VTable{
        .loadBytecode = loadBytecodeImpl,
        .dumpBytecode = dumpBytecodeImpl,
        .clear = clearImpl,
        .deinit = deinitImpl,
    };

    fn loadBytecodeImpl(ptr: *anyopaque, bucket: *Bucket) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const filename = self.getCacheFilename(bucket) catch return;
        defer self.allocator.free(filename);

        // Read entire file into memory
        const file_data = std.fs.cwd().readFileAlloc(self.allocator, filename, 1024 * 1024) catch return;
        defer self.allocator.free(file_data);

        bucket.bytecodeFromString(file_data) catch {
            bucket.reset();
        };
    }

    fn dumpBytecodeImpl(ptr: *anyopaque, bucket: *Bucket) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const filename = try self.getCacheFilename(bucket);
        defer self.allocator.free(filename);

        // Serialize to memory first
        const data = try bucket.bytecodeToString();
        defer self.allocator.free(data);

        // Write to temporary file first, then rename (atomic write)
        const tmp_filename = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{filename});
        defer self.allocator.free(tmp_filename);

        const file = try std.fs.cwd().createFile(tmp_filename, .{});
        errdefer {
            file.close();
            std.fs.cwd().deleteFile(tmp_filename) catch {};
        }

        try file.writeAll(data);
        file.close();

        // Rename to final filename
        std.fs.cwd().rename(tmp_filename, filename) catch |err| {
            std.fs.cwd().deleteFile(tmp_filename) catch {};
            return err;
        };
    }

    fn clearImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        var dir = std.fs.cwd().openDir(self.directory, .{ .iterate = true }) catch return;
        defer dir.close();

        // Build pattern for matching (replace %s with wildcard logic)
        const prefix_end = std.mem.indexOf(u8, self.pattern, "%s") orelse return;
        const prefix = self.pattern[0..prefix_end];
        const suffix = if (prefix_end + 2 < self.pattern.len) self.pattern[prefix_end + 2 ..] else "";

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;

            // Check if filename matches pattern
            if (std.mem.startsWith(u8, entry.name, prefix) and
                std.mem.endsWith(u8, entry.name, suffix))
            {
                dir.deleteFile(entry.name) catch {};
            }
        }
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Memcached client interface
/// This is the minimal interface required for memcached compatibility
pub const MemcachedClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, key: []const u8) ?[]const u8,
        set: *const fn (ptr: *anyopaque, key: []const u8, value: []const u8, timeout: ?u32) anyerror!void,
    };

    /// Get a value from memcached
    pub fn get(self: *MemcachedClient, key: []const u8) ?[]const u8 {
        return self.vtable.get(self.ptr, key);
    }

    /// Set a value in memcached
    pub fn set(self: *MemcachedClient, key: []const u8, value: []const u8, timeout: ?u32) !void {
        try self.vtable.set(self.ptr, key, value, timeout);
    }
};

/// Memcached bytecode cache
/// Stores bytecode in memcached for distributed caching
pub const MemcachedBytecodeCache = struct {
    allocator: std.mem.Allocator,
    client: *MemcachedClient,
    prefix: []const u8,
    timeout: ?u32,
    ignore_memcache_errors: bool,
    cache: BytecodeCache,

    const Self = @This();

    /// Default key prefix
    pub const DEFAULT_PREFIX = "jinja2/bytecode/";

    /// Initialize with memcached client
    pub fn init(
        allocator: std.mem.Allocator,
        client: *MemcachedClient,
        prefix: ?[]const u8,
        timeout: ?u32,
        ignore_memcache_errors: bool,
    ) !Self {
        const pref = try allocator.dupe(u8, prefix orelse DEFAULT_PREFIX);

        var self = Self{
            .allocator = allocator,
            .client = client,
            .prefix = pref,
            .timeout = timeout,
            .ignore_memcache_errors = ignore_memcache_errors,
            .cache = undefined,
        };

        self.cache = BytecodeCache{
            .ptr = @ptrCast(&self),
            .vtable = &vtable,
        };

        return self;
    }

    /// Get cache interface
    pub fn getCache(self: *Self) *BytecodeCache {
        self.cache.ptr = @ptrCast(self);
        return &self.cache;
    }

    /// Deinitialize
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.prefix);
    }

    /// VTable implementation
    const vtable = BytecodeCache.VTable{
        .loadBytecode = loadBytecodeImpl,
        .dumpBytecode = dumpBytecodeImpl,
        .clear = clearImpl,
        .deinit = deinitImpl,
    };

    fn loadBytecodeImpl(ptr: *anyopaque, bucket: *Bucket) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const key = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, bucket.key }) catch return;
        defer self.allocator.free(key);

        const data = self.client.get(key) orelse return;

        bucket.bytecodeFromString(data) catch {
            if (!self.ignore_memcache_errors) {
                bucket.reset();
            }
        };
    }

    fn dumpBytecodeImpl(ptr: *anyopaque, bucket: *Bucket) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const key = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, bucket.key });
        defer self.allocator.free(key);

        const data = bucket.bytecodeToString() catch |err| {
            if (!self.ignore_memcache_errors) return err;
            return;
        };
        defer self.allocator.free(data);

        self.client.set(key, data, self.timeout) catch |err| {
            if (!self.ignore_memcache_errors) return err;
        };
    }

    fn clearImpl(_: *anyopaque) void {
        // Memcached cache does not support clearing
        // This is intentional per Jinja2 spec
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

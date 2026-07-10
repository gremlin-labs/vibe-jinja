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
const bytecode_mod = @import("bytecode.zig");
const template_cache = @import("template_cache.zig");

/// Canonical template-cache types. Bytecode caches remain implemented below.
pub const TemplateCacheEntry = template_cache.TemplateCacheEntry;
pub const LRUCache = template_cache.LRUCache;
pub const CacheStats = template_cache.CacheStats;

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
        // Final size is exactly pattern minus "%s" plus the key; reserve once.
        try result.ensureTotalCapacity(self.allocator, self.pattern.len + bucket.key.len);

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
            std.fs.cwd().deleteFile(tmp_filename) catch |err| {
                std.log.debug("vibe-jinja: tmp cache file cleanup failed: {s}", .{@errorName(err)});
            };
        }

        try file.writeAll(data);
        file.close();

        // Rename to final filename
        std.fs.cwd().rename(tmp_filename, filename) catch |err| {
            std.fs.cwd().deleteFile(tmp_filename) catch |del_err| {
                std.log.debug("vibe-jinja: tmp cache file cleanup failed: {s}", .{@errorName(del_err)});
            };
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
                dir.deleteFile(entry.name) catch |err| {
                    std.log.debug("vibe-jinja: cache clear could not delete {s}: {s}", .{ entry.name, @errorName(err) });
                };
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

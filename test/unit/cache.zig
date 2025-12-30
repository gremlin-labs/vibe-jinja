const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const cache_mod = vibe_jinja.cache;
const nodes = vibe_jinja.nodes;
const bytecode_mod = vibe_jinja.bytecode;

test "LRU cache basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var lru = cache_mod.LRUCache.init(allocator, 3);
    defer lru.deinit();

    // Create dummy template entries
    const template1 = try allocator.create(nodes.Template);
    template1.* = nodes.Template.init(allocator, 1, "test1");
    // Note: Don't manually deinit template1 - the cache will handle it

    const entry1 = try allocator.create(cache_mod.TemplateCacheEntry);
    entry1.* = cache_mod.TemplateCacheEntry{
        .template = template1,
        .last_modified = 1000,
        .access_count = 0,
        .source_checksum = 0,
    };

    try lru.put("template1", entry1);

    const retrieved = lru.get("template1");
    try testing.expect(retrieved != null);
    try testing.expect(retrieved.?.template == template1);
}

test "LRU cache eviction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var lru = cache_mod.LRUCache.init(allocator, 2);
    defer lru.deinit();

    // Create templates
    const template1 = try allocator.create(nodes.Template);
    template1.* = nodes.Template.init(allocator, 1, "test1");
    // Note: Don't manually deinit templates - the cache will handle them

    const template2 = try allocator.create(nodes.Template);
    template2.* = nodes.Template.init(allocator, 1, "test2");

    const template3 = try allocator.create(nodes.Template);
    template3.* = nodes.Template.init(allocator, 1, "test3");

    const entry1 = try allocator.create(cache_mod.TemplateCacheEntry);
    entry1.* = cache_mod.TemplateCacheEntry{
        .template = template1,
        .last_modified = 1000,
        .access_count = 0,
        .source_checksum = 0,
    };

    const entry2 = try allocator.create(cache_mod.TemplateCacheEntry);
    entry2.* = cache_mod.TemplateCacheEntry{
        .template = template2,
        .last_modified = 2000,
        .access_count = 0,
        .source_checksum = 0,
    };

    const entry3 = try allocator.create(cache_mod.TemplateCacheEntry);
    entry3.* = cache_mod.TemplateCacheEntry{
        .template = template3,
        .last_modified = 3000,
        .access_count = 0,
        .source_checksum = 0,
    };

    try lru.put("template1", entry1);
    try lru.put("template2", entry2);
    
    // Access template1 to make it more recently used
    _ = lru.get("template1");
    
    // Add template3 - should evict template2 (least recently used)
    try lru.put("template3", entry3);

    try testing.expect(lru.get("template1") != null);
    try testing.expect(lru.get("template3") != null);
    try testing.expect(lru.get("template2") == null);
}

test "LRU cache statistics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var lru = cache_mod.LRUCache.init(allocator, 2);
    defer lru.deinit();

    const template1 = try allocator.create(nodes.Template);
    template1.* = nodes.Template.init(allocator, 1, "test1");
    // Note: Don't manually deinit template1 - the cache will handle it

    const entry1 = try allocator.create(cache_mod.TemplateCacheEntry);
    entry1.* = cache_mod.TemplateCacheEntry{
        .template = template1,
        .last_modified = 1000,
        .access_count = 0,
        .source_checksum = 0,
    };

    try lru.put("template1", entry1);
    _ = lru.get("template1"); // hit
    _ = lru.get("template2"); // miss

    const stats = lru.getStats();
    try testing.expectEqual(@as(usize, 1), stats.size);
    try testing.expectEqual(@as(usize, 1), stats.hits);
    try testing.expectEqual(@as(usize, 1), stats.misses);
    try testing.expect(stats.hit_rate > 0.0);
}

// ============================================================================
// Bytecode Cache Tests
// ============================================================================

test "bytecode cache magic header" {
    // Verify magic header format
    try testing.expectEqual(@as(u8, 'v'), cache_mod.bc_magic[0]);
    try testing.expectEqual(@as(u8, 'j'), cache_mod.bc_magic[1]);
    try testing.expectEqual(@as(u8, '2'), cache_mod.bc_magic[2]);
    try testing.expectEqual(cache_mod.bc_version, cache_mod.bc_magic[3]);
}

test "bytecode cache getCacheKey generates consistent keys" {
    const key1 = cache_mod.BytecodeCache.getCacheKey("template.html", null);
    const key2 = cache_mod.BytecodeCache.getCacheKey("template.html", null);
    
    // Same inputs should produce same key
    try testing.expectEqualSlices(u8, &key1, &key2);
    
    // Different inputs should produce different keys
    const key3 = cache_mod.BytecodeCache.getCacheKey("other.html", null);
    try testing.expect(!std.mem.eql(u8, &key1, &key3));
    
    // Filename affects key
    const key4 = cache_mod.BytecodeCache.getCacheKey("template.html", "/path/to/file");
    try testing.expect(!std.mem.eql(u8, &key1, &key4));
}

test "bytecode cache getSourceChecksum generates consistent checksums" {
    const checksum1 = cache_mod.BytecodeCache.getSourceChecksum("Hello {{ name }}");
    const checksum2 = cache_mod.BytecodeCache.getSourceChecksum("Hello {{ name }}");
    
    // Same source should produce same checksum
    try testing.expectEqual(checksum1, checksum2);
    
    // Different source should produce different checksum
    const checksum3 = cache_mod.BytecodeCache.getSourceChecksum("Hello {{ other }}");
    try testing.expect(checksum1 != checksum3);
}

test "bucket initialization and cleanup" {
    const allocator = testing.allocator;
    
    var bucket = try cache_mod.Bucket.init(allocator, "test_key", 12345);
    defer bucket.deinit();
    
    try testing.expectEqualStrings("test_key", bucket.key);
    try testing.expectEqual(@as(u64, 12345), bucket.checksum);
    try testing.expect(bucket.bytecode == null);
}

test "bucket reset clears bytecode" {
    const allocator = testing.allocator;
    
    var bucket = try cache_mod.Bucket.init(allocator, "test_key", 12345);
    defer bucket.deinit();
    
    // Manually set some bytecode
    bucket.bytecode = bytecode_mod.Bytecode.init(allocator);
    try testing.expect(bucket.bytecode != null);
    
    // Reset should clear it
    bucket.reset();
    try testing.expect(bucket.bytecode == null);
}

test "filesystem bytecode cache initialization" {
    const allocator = testing.allocator;
    
    // Use a test-specific directory
    var fs_cache = try cache_mod.FileSystemBytecodeCache.init(
        allocator,
        "/tmp/vibe_jinja_test_cache",
        null,
    );
    defer fs_cache.deinit();
    
    try testing.expectEqualStrings("/tmp/vibe_jinja_test_cache", fs_cache.directory);
    try testing.expectEqualStrings(cache_mod.FileSystemBytecodeCache.DEFAULT_PATTERN, fs_cache.pattern);
}

test "filesystem bytecode cache custom pattern" {
    const allocator = testing.allocator;
    
    var fs_cache = try cache_mod.FileSystemBytecodeCache.init(
        allocator,
        "/tmp/vibe_jinja_test_cache",
        "custom_%s.bc",
    );
    defer fs_cache.deinit();
    
    try testing.expectEqualStrings("custom_%s.bc", fs_cache.pattern);
}

test "filesystem bytecode cache write and read" {
    const allocator = testing.allocator;
    
    var fs_cache = try cache_mod.FileSystemBytecodeCache.init(
        allocator,
        "/tmp/vibe_jinja_test_cache",
        null,
    );
    defer fs_cache.deinit();
    
    var cache = fs_cache.getCache();
    
    // Create a bucket with bytecode
    const key = cache_mod.BytecodeCache.getCacheKey("test_template", null);
    const checksum = cache_mod.BytecodeCache.getSourceChecksum("{{ hello }}");
    
    var bucket = try cache_mod.Bucket.init(allocator, &key, checksum);
    defer bucket.deinit();
    
    // Create some bytecode
    var bc = bytecode_mod.Bytecode.init(allocator);
    try bc.addInstruction(.LOAD_STRING, 0);
    _ = try bc.addString("hello");
    try bc.addInstruction(.OUTPUT, 1);
    try bc.addInstruction(.END, 0);
    bucket.bytecode = bc;
    
    // Write to cache
    try cache.dumpBytecode(&bucket);
    
    // Create a new bucket to read back
    var bucket2 = try cache_mod.Bucket.init(allocator, &key, checksum);
    defer bucket2.deinit();
    
    // Read from cache
    cache.loadBytecode(&bucket2);
    
    // Verify bytecode was loaded
    try testing.expect(bucket2.bytecode != null);
    try testing.expectEqual(@as(usize, 3), bucket2.bytecode.?.instructions.items.len);
    
    // Clean up test files
    cache.clear();
}

test "filesystem bytecode cache checksum mismatch" {
    const allocator = testing.allocator;
    
    var fs_cache = try cache_mod.FileSystemBytecodeCache.init(
        allocator,
        "/tmp/vibe_jinja_test_cache",
        null,
    );
    defer fs_cache.deinit();
    
    var cache = fs_cache.getCache();
    
    // Create and write a bucket
    const key = cache_mod.BytecodeCache.getCacheKey("checksum_test", null);
    const checksum1 = cache_mod.BytecodeCache.getSourceChecksum("version 1");
    
    var bucket = try cache_mod.Bucket.init(allocator, &key, checksum1);
    defer bucket.deinit();
    
    var bc = bytecode_mod.Bytecode.init(allocator);
    try bc.addInstruction(.LOAD_INT, 42);
    try bc.addInstruction(.END, 0);
    bucket.bytecode = bc;
    
    try cache.dumpBytecode(&bucket);
    
    // Try to read with different checksum (simulating source change)
    const checksum2 = cache_mod.BytecodeCache.getSourceChecksum("version 2");
    var bucket2 = try cache_mod.Bucket.init(allocator, &key, checksum2);
    defer bucket2.deinit();
    
    cache.loadBytecode(&bucket2);
    
    // Bytecode should NOT be loaded due to checksum mismatch
    try testing.expect(bucket2.bytecode == null);
    
    // Clean up
    cache.clear();
}

test "bytecode serialization roundtrip" {
    const allocator = testing.allocator;
    
    // Create bytecode with various instructions
    var bc = bytecode_mod.Bytecode.init(allocator);
    // Note: NOT using defer bc.deinit() because bucket takes ownership
    
    try bc.addInstruction(.LOAD_STRING, 0);
    _ = try bc.addString("test string");
    try bc.addInstruction(.LOAD_INT, 42);
    try bc.addInstruction(.LOAD_VAR, 0);
    _ = try bc.addName("variable");
    try bc.addInstruction(.BIN_OP, 0);
    try bc.addInstruction(.OUTPUT, 1);
    try bc.addInstruction(.END, 0);
    
    // Create bucket and serialize - bucket takes ownership of bytecode
    var bucket = try cache_mod.Bucket.init(allocator, "test", 12345);
    defer bucket.deinit();  // bucket.deinit() will clean up the bytecode
    bucket.bytecode = bc;
    
    const serialized = try bucket.bytecodeToString();
    defer allocator.free(serialized);
    
    // Create new bucket and deserialize
    var bucket2 = try cache_mod.Bucket.init(allocator, "test", 12345);
    defer bucket2.deinit();
    
    try bucket2.bytecodeFromString(serialized);
    
    // Verify
    try testing.expect(bucket2.bytecode != null);
    const bc2 = bucket2.bytecode.?;
    
    try testing.expectEqual(@as(usize, 6), bc2.instructions.items.len);
    try testing.expectEqual(@as(usize, 1), bc2.strings.items.len);
    try testing.expectEqualStrings("test string", bc2.strings.items[0]);
    try testing.expectEqual(@as(usize, 1), bc2.names.items.len);
    try testing.expectEqualStrings("variable", bc2.names.items[0]);
}

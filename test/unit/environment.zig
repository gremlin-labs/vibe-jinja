const std = @import("std");
const testing = std.testing;
const jinja = @import("vibe_jinja");
const Environment = jinja.Environment;
const getSpontaneousEnvironment = jinja.getSpontaneousEnvironment;
const clearSpontaneousCache = jinja.clearSpontaneousCache;

// ============================================================================
// 5.1 Overlay Environments Tests
// ============================================================================

test "environment overlay creates new environment with shared data" {
    const allocator = testing.allocator;
    
    var env = Environment.init(allocator);
    defer env.deinit();
    
    // Add a custom filter to parent
    try env.addFilter("custom_filter", customTestFilter);
    
    // Create overlay
    const overlay_env = try env.overlay(.{});
    defer {
        // Clean up overlay cache
        if (overlay_env.template_cache) |cache| {
            cache.deinit();
            allocator.destroy(cache);
        }
        // Don't clean up shared resources (filters, tests, globals)
        allocator.destroy(overlay_env);
    }
    
    // Overlay should be marked as overlayed and linked to parent
    try testing.expect(overlay_env.overlayed);
    try testing.expectEqual(&env, overlay_env.linked_to.?);
    
    // Overlay should have access to parent's filter (shared reference)
    try testing.expect(overlay_env.getFilter("custom_filter") != null);
}

test "environment overlay can override settings" {
    const allocator = testing.allocator;
    
    var env = Environment.init(allocator);
    defer env.deinit();
    
    // Parent has trim_blocks = false (default)
    try testing.expect(!env.trim_blocks);
    
    // Create overlay with different settings
    const overlay_env = try env.overlay(.{
        .trim_blocks = true,
        .lstrip_blocks = true,
        .autoescape = .{ .bool = true },
    });
    defer {
        if (overlay_env.template_cache) |cache| {
            cache.deinit();
            allocator.destroy(cache);
        }
        allocator.destroy(overlay_env);
    }
    
    // Overlay should have overridden settings
    try testing.expect(overlay_env.trim_blocks);
    try testing.expect(overlay_env.lstrip_blocks);
    try testing.expectEqual(true, overlay_env.autoescape.bool);
    
    // Parent should be unchanged
    try testing.expect(!env.trim_blocks);
    try testing.expect(!env.lstrip_blocks);
}

test "environment overlay has its own cache" {
    const allocator = testing.allocator;
    
    var env = Environment.init(allocator);
    defer env.deinit();
    
    // Create overlay
    const overlay_env = try env.overlay(.{});
    defer {
        if (overlay_env.template_cache) |cache| {
            cache.deinit();
            allocator.destroy(cache);
        }
        allocator.destroy(overlay_env);
    }
    
    // Both should have caches
    try testing.expect(env.template_cache != null);
    try testing.expect(overlay_env.template_cache != null);
    
    // Caches should be different instances
    try testing.expect(env.template_cache != overlay_env.template_cache);
}

test "environment overlay can override cache size" {
    const allocator = testing.allocator;
    
    var env = Environment.init(allocator);
    defer env.deinit();
    
    // Create overlay with no cache
    const overlay_env = try env.overlay(.{
        .cache_size = 0,
    });
    defer {
        // overlay_env.template_cache should be null
        allocator.destroy(overlay_env);
    }
    
    // Overlay should have no cache
    try testing.expect(overlay_env.template_cache == null);
    try testing.expectEqual(@as(usize, 0), overlay_env.cache_size);
}

test "environment overlay can override delimiters" {
    const allocator = testing.allocator;
    
    var env = Environment.init(allocator);
    defer env.deinit();
    
    // Create overlay with custom delimiters
    const overlay_env = try env.overlay(.{
        .block_start_string = "<%",
        .block_end_string = "%>",
        .variable_start_string = "<<",
        .variable_end_string = ">>",
    });
    defer {
        if (overlay_env.template_cache) |cache| {
            cache.deinit();
            allocator.destroy(cache);
        }
        allocator.destroy(overlay_env);
    }
    
    try testing.expectEqualStrings("<%", overlay_env.block_start_string);
    try testing.expectEqualStrings("%>", overlay_env.block_end_string);
    try testing.expectEqualStrings("<<", overlay_env.variable_start_string);
    try testing.expectEqualStrings(">>", overlay_env.variable_end_string);
    
    // Parent should be unchanged
    try testing.expectEqualStrings("{%", env.block_start_string);
    try testing.expectEqualStrings("%}", env.block_end_string);
}

// ============================================================================
// 5.2 Finalize Callback Tests
// ============================================================================

fn nullToEmptyFinalize(_: std.mem.Allocator, val: jinja.Value) jinja.Value {
    // Convert null to empty string
    return switch (val) {
        .null => jinja.Value{ .string = "" },
        else => val,
    };
}

fn uppercaseFinalize(allocator: std.mem.Allocator, val: jinja.Value) jinja.Value {
    // Convert strings to uppercase
    return switch (val) {
        .string => |s| blk: {
            const upper = allocator.alloc(u8, s.len) catch return val;
            for (s, 0..) |c, i| {
                upper[i] = std.ascii.toUpper(c);
            }
            break :blk jinja.Value{ .string = upper };
        },
        else => val,
    };
}

test "environment finalize callback is initially null" {
    const allocator = testing.allocator;
    
    var env = Environment.init(allocator);
    defer env.deinit();
    
    try testing.expect(env.finalize == null);
}

test "environment finalize callback can be set" {
    const allocator = testing.allocator;
    
    var env = Environment.init(allocator);
    defer env.deinit();
    
    env.finalize = nullToEmptyFinalize;
    try testing.expect(env.finalize != null);
}

test "environment applyFinalize returns value unchanged when no callback" {
    const allocator = testing.allocator;
    
    var env = Environment.init(allocator);
    defer env.deinit();
    
    const val = jinja.Value{ .string = "test" };
    const result = env.applyFinalize(val);
    
    try testing.expectEqualStrings("test", result.string);
}

test "environment applyFinalize applies callback when set" {
    const allocator = testing.allocator;
    
    var env = Environment.init(allocator);
    defer env.deinit();
    
    env.finalize = nullToEmptyFinalize;
    
    // Test with null value - should become empty string
    const null_val = jinja.Value{ .null = {} };
    const result = env.applyFinalize(null_val);
    
    try testing.expectEqualStrings("", result.string);
}

test "environment overlay inherits finalize from parent" {
    const allocator = testing.allocator;
    
    var env = Environment.init(allocator);
    defer env.deinit();
    
    env.finalize = nullToEmptyFinalize;
    
    // Create overlay without overriding finalize
    const overlay_env = try env.overlay(.{});
    defer {
        if (overlay_env.template_cache) |cache| {
            cache.deinit();
            allocator.destroy(cache);
        }
        allocator.destroy(overlay_env);
    }
    
    // Overlay should have same finalize callback
    try testing.expectEqual(env.finalize, overlay_env.finalize);
}

test "environment overlay can override finalize" {
    const allocator = testing.allocator;
    
    var env = Environment.init(allocator);
    defer env.deinit();
    
    env.finalize = nullToEmptyFinalize;
    
    // Create overlay with different finalize
    const overlay_env = try env.overlay(.{
        .finalize = uppercaseFinalize,
    });
    defer {
        if (overlay_env.template_cache) |cache| {
            cache.deinit();
            allocator.destroy(cache);
        }
        allocator.destroy(overlay_env);
    }
    
    // Overlay should have different finalize
    try testing.expectEqual(uppercaseFinalize, overlay_env.finalize.?);
    try testing.expectEqual(nullToEmptyFinalize, env.finalize.?);
}

// ============================================================================
// 5.3 Spontaneous Environments Tests
// ============================================================================

test "spontaneous environment is created with default settings" {
    const allocator = testing.allocator;
    defer clearSpontaneousCache(allocator);
    
    const env = try getSpontaneousEnvironment(allocator, .{});
    
    // Should be marked as shared
    try testing.expect(env.shared);
    
    // Should have default settings
    try testing.expectEqualStrings("{%", env.block_start_string);
    try testing.expectEqualStrings("%}", env.block_end_string);
}

test "spontaneous environment is cached and reused" {
    const allocator = testing.allocator;
    defer clearSpontaneousCache(allocator);
    
    const env1 = try getSpontaneousEnvironment(allocator, .{});
    const env2 = try getSpontaneousEnvironment(allocator, .{});
    
    // Should return the same instance
    try testing.expectEqual(env1, env2);
}

test "spontaneous environment with different options creates different instances" {
    const allocator = testing.allocator;
    defer clearSpontaneousCache(allocator);
    
    const env1 = try getSpontaneousEnvironment(allocator, .{});
    const env2 = try getSpontaneousEnvironment(allocator, .{
        .trim_blocks = true,
    });
    
    // Should be different instances
    try testing.expect(env1 != env2);
}

test "spontaneous environment can have custom delimiters" {
    const allocator = testing.allocator;
    defer clearSpontaneousCache(allocator);
    
    const env = try getSpontaneousEnvironment(allocator, .{
        .block_start_string = "<%",
        .block_end_string = "%>",
    });
    
    try testing.expectEqualStrings("<%", env.block_start_string);
    try testing.expectEqualStrings("%>", env.block_end_string);
}

test "clear spontaneous cache removes all cached environments" {
    const allocator = testing.allocator;
    
    // Create some spontaneous environments
    _ = try getSpontaneousEnvironment(allocator, .{});
    _ = try getSpontaneousEnvironment(allocator, .{ .trim_blocks = true });
    
    // Clear cache
    clearSpontaneousCache(allocator);
    
    // Creating a new one should succeed (cache is cleared)
    const env = try getSpontaneousEnvironment(allocator, .{});
    try testing.expect(env.shared);
    
    // Clean up
    clearSpontaneousCache(allocator);
}

// ============================================================================
// 5.4 Global Functions Tests (Jinja2 parity: range, dict, lipsum)
// ============================================================================

test "environment has builtin global functions" {
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    // Check that builtin globals are registered
    try testing.expect(env.getGlobal("range") != null);
    try testing.expect(env.getGlobal("dict") != null);
    try testing.expect(env.getGlobal("lipsum") != null);
}

test "range global function with single argument" {
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    // Get range global
    const range_val = env.getGlobal("range") orelse return error.TestUnexpectedResult;
    try testing.expect(range_val == .callable);

    // Call range(5)
    var args = [_]jinja.Value{jinja.Value{ .integer = 5 }};
    const result = try range_val.callable.func.?(allocator, &args, null, null);
    defer result.deinit(allocator);

    // Check result is a list [0, 1, 2, 3, 4]
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 5), result.list.items.items.len);
    try testing.expectEqual(@as(i64, 0), result.list.items.items[0].integer);
    try testing.expectEqual(@as(i64, 1), result.list.items.items[1].integer);
    try testing.expectEqual(@as(i64, 4), result.list.items.items[4].integer);
}

test "range global function with two arguments" {
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    // Get range global
    const range_val = env.getGlobal("range") orelse return error.TestUnexpectedResult;

    // Call range(2, 7)
    var args = [_]jinja.Value{
        jinja.Value{ .integer = 2 },
        jinja.Value{ .integer = 7 },
    };
    const result = try range_val.callable.func.?(allocator, &args, null, null);
    defer result.deinit(allocator);

    // Check result is a list [2, 3, 4, 5, 6]
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 5), result.list.items.items.len);
    try testing.expectEqual(@as(i64, 2), result.list.items.items[0].integer);
    try testing.expectEqual(@as(i64, 6), result.list.items.items[4].integer);
}

test "range global function with three arguments (step)" {
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    // Get range global
    const range_val = env.getGlobal("range") orelse return error.TestUnexpectedResult;

    // Call range(0, 10, 2)
    var args = [_]jinja.Value{
        jinja.Value{ .integer = 0 },
        jinja.Value{ .integer = 10 },
        jinja.Value{ .integer = 2 },
    };
    const result = try range_val.callable.func.?(allocator, &args, null, null);
    defer result.deinit(allocator);

    // Check result is a list [0, 2, 4, 6, 8]
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 5), result.list.items.items.len);
    try testing.expectEqual(@as(i64, 0), result.list.items.items[0].integer);
    try testing.expectEqual(@as(i64, 2), result.list.items.items[1].integer);
    try testing.expectEqual(@as(i64, 8), result.list.items.items[4].integer);
}

test "range global function with negative step" {
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    // Get range global
    const range_val = env.getGlobal("range") orelse return error.TestUnexpectedResult;

    // Call range(10, 0, -2)
    var args = [_]jinja.Value{
        jinja.Value{ .integer = 10 },
        jinja.Value{ .integer = 0 },
        jinja.Value{ .integer = -2 },
    };
    const result = try range_val.callable.func.?(allocator, &args, null, null);
    defer result.deinit(allocator);

    // Check result is a list [10, 8, 6, 4, 2]
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 5), result.list.items.items.len);
    try testing.expectEqual(@as(i64, 10), result.list.items.items[0].integer);
    try testing.expectEqual(@as(i64, 2), result.list.items.items[4].integer);
}

test "dict global function returns empty dict" {
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    // Get dict global
    const dict_val = env.getGlobal("dict") orelse return error.TestUnexpectedResult;
    try testing.expect(dict_val == .callable);

    // Call dict() with no arguments
    var args = [_]jinja.Value{};
    const result = try dict_val.callable.func.?(allocator, &args, null, null);
    defer result.deinit(allocator);

    // Check result is an empty dict
    try testing.expect(result == .dict);
    try testing.expectEqual(@as(usize, 0), result.dict.map.count());
}

test "lipsum global function returns lorem ipsum text" {
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    // Get lipsum global
    const lipsum_val = env.getGlobal("lipsum") orelse return error.TestUnexpectedResult;
    try testing.expect(lipsum_val == .callable);

    // Call lipsum(1, false) - 1 paragraph, no HTML
    var args = [_]jinja.Value{
        jinja.Value{ .integer = 1 },
        jinja.Value{ .boolean = false },
    };
    const result = try lipsum_val.callable.func.?(allocator, &args, null, null);
    defer result.deinit(allocator);

    // Check result is a string containing lorem ipsum
    try testing.expect(result == .string);
    try testing.expect(result.string.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.string, "lorem") != null);
}

test "lipsum global function with HTML wrapping" {
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    // Get lipsum global
    const lipsum_val = env.getGlobal("lipsum") orelse return error.TestUnexpectedResult;

    // Call lipsum(1, true) - 1 paragraph, with HTML
    var args = [_]jinja.Value{
        jinja.Value{ .integer = 1 },
        jinja.Value{ .boolean = true },
    };
    const result = try lipsum_val.callable.func.?(allocator, &args, null, null);
    defer result.deinit(allocator);

    // Check result contains HTML paragraph tags
    try testing.expect(result == .string);
    try testing.expect(std.mem.indexOf(u8, result.string, "<p>") != null);
    try testing.expect(std.mem.indexOf(u8, result.string, "</p>") != null);
}

// ============================================================================
// Helper functions for tests
// ============================================================================

fn customTestFilter(
    _: std.mem.Allocator,
    value: jinja.Value,
    _: []jinja.Value,
    _: *const std.StringHashMap(jinja.Value),
    _: ?*jinja.context.Context,
    _: ?*Environment,
) !jinja.Value {
    _ = value;
    return jinja.Value{ .string = "filtered" };
}

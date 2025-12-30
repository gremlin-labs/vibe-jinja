const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const extensions = vibe_jinja.extensions;
const filters = vibe_jinja.filters;
const tests_module = vibe_jinja.tests;
const value = vibe_jinja.value;
const context = vibe_jinja.context;
const environment = vibe_jinja.environment;

test "extension registry init" {
    const allocator = testing.allocator;

    var registry = extensions.ExtensionRegistry.init(allocator);
    defer registry.deinit();

    try testing.expect(registry.extensions.items.len == 0);
}

test "extension registry register extension" {
    const allocator = testing.allocator;

    var registry = extensions.ExtensionRegistry.init(allocator);
    defer registry.deinit();

    // Create a simple extension
    const ext = try allocator.create(extensions.Extension);
    ext.* = try extensions.Extension.init(allocator, "test_extension");

    try registry.register(ext);

    try testing.expect(registry.extensions.items.len == 1);
}

test "extension registry get extension by name" {
    const allocator = testing.allocator;

    var registry = extensions.ExtensionRegistry.init(allocator);
    defer registry.deinit();

    // Create and register an extension
    const ext = try allocator.create(extensions.Extension);
    ext.* = try extensions.Extension.init(allocator, "my_extension");

    try registry.register(ext);

    // Get by name
    const found = registry.get("my_extension");
    try testing.expect(found != null);
    try testing.expectEqualStrings("my_extension", found.?.name);

    // Not found
    const not_found = registry.get("nonexistent");
    try testing.expect(not_found == null);
}

test "extension registry priority sorting" {
    const allocator = testing.allocator;

    var registry = extensions.ExtensionRegistry.init(allocator);
    defer registry.deinit();

    // Create extensions with different priorities
    const ext1 = try allocator.create(extensions.Extension);
    ext1.* = try extensions.Extension.init(allocator, "low_priority");
    ext1.priority = 200;

    const ext2 = try allocator.create(extensions.Extension);
    ext2.* = try extensions.Extension.init(allocator, "high_priority");
    ext2.priority = 50;

    const ext3 = try allocator.create(extensions.Extension);
    ext3.* = try extensions.Extension.init(allocator, "default_priority");
    ext3.priority = 100;

    try registry.register(ext1);
    try registry.register(ext2);
    try registry.register(ext3);

    // Should be sorted by priority (lower = higher priority)
    const exts = registry.iterExtensions();
    try testing.expect(exts.len == 3);
    try testing.expectEqualStrings("high_priority", exts[0].name);
    try testing.expectEqualStrings("default_priority", exts[1].name);
    try testing.expectEqualStrings("low_priority", exts[2].name);
}

test "extension init" {
    const allocator = testing.allocator;

    var ext = try extensions.Extension.init(allocator, "test_extension");
    defer ext.deinit();

    try testing.expectEqualStrings("test_extension", ext.name);
    try testing.expect(ext.priority == 100);
    try testing.expect(ext.environment == null);
}

test "extension add tag" {
    const allocator = testing.allocator;

    var ext = try extensions.Extension.init(allocator, "test_extension");
    defer ext.deinit();

    try ext.addTag("mytag");
    try ext.addTag("anothertag");

    try testing.expect(ext.tags.items.len == 2);
    try testing.expectEqualStrings("mytag", ext.tags.items[0]);
    try testing.expectEqualStrings("anothertag", ext.tags.items[1]);
}

test "extension registry handles tag" {
    const allocator = testing.allocator;

    var registry = extensions.ExtensionRegistry.init(allocator);
    defer registry.deinit();

    // Create extension with tags
    const ext = try allocator.create(extensions.Extension);
    ext.* = try extensions.Extension.init(allocator, "tag_extension");
    try ext.addTag("debug");
    try ext.addTag("cache");

    try registry.register(ext);

    try testing.expect(registry.handlesTag("debug"));
    try testing.expect(registry.handlesTag("cache"));
    try testing.expect(!registry.handlesTag("unknown"));
}

test "extension add filter" {
    const allocator = testing.allocator;

    var ext = try extensions.Extension.init(allocator, "filter_extension");
    defer ext.deinit();

    const filterFn = struct {
        fn filter(
            alloc: std.mem.Allocator,
            val: value.Value,
            args: []value.Value,
            ctx: ?*context.Context,
            env: ?*environment.Environment,
        ) filters.FilterError!value.Value {
            _ = val;
            _ = args;
            _ = ctx;
            _ = env;
            return .{ .string = try alloc.dupe(u8, "filtered") };
        }
    }.filter;

    try ext.addFilter("myfilter", filterFn);

    try testing.expect(ext.filters.count() == 1);
    try testing.expect(ext.filters.contains("myfilter"));
}

test "extension add test" {
    const allocator = testing.allocator;

    var ext = try extensions.Extension.init(allocator, "test_extension");
    defer ext.deinit();

    const testFn = struct {
        fn testImpl(
            val: value.Value,
            args: []const value.Value,
            ctx: ?*context.Context,
            env: ?*environment.Environment,
        ) bool {
            _ = val;
            _ = args;
            _ = ctx;
            _ = env;
            return true;
        }
    }.testImpl;

    try ext.addTest("mytest", testFn);

    try testing.expect(ext.tests.count() == 1);
    try testing.expect(ext.tests.contains("mytest"));
}

test "extension preprocess default" {
    const allocator = testing.allocator;

    var ext = try extensions.Extension.init(allocator, "test_extension");
    defer ext.deinit();

    const source = "Hello {{ name }}";
    const processed = try ext.preprocess(source, null, null);
    defer allocator.free(processed);

    try testing.expectEqualStrings(source, processed);
}

test "extension bind to environment" {
    const allocator = testing.allocator;

    var ext = try extensions.Extension.init(allocator, "test_extension");
    defer ext.deinit();

    try ext.addTag("mytag");

    // Create environment
    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Bind extension to environment
    var bound = try ext.bind(&env);
    defer bound.deinit();

    try testing.expectEqualStrings("test_extension", bound.name);
    try testing.expect(bound.environment == &env);
    try testing.expect(bound.tags.items.len == 1);
    try testing.expectEqualStrings("mytag", bound.tags.items[0]);
}

// ============================================================================
// Built-in Extension Tests
// ============================================================================

test "do extension init" {
    const allocator = testing.allocator;
    
    var do_ext = try extensions.DoExtension.init(allocator);
    defer do_ext.deinit();
    
    try testing.expectEqualStrings("jinja2.ext.do", do_ext.extension.name);
    try testing.expect(do_ext.extension.tags.items.len == 1);
    try testing.expectEqualStrings("do", do_ext.extension.tags.items[0]);
}

test "debug extension init" {
    const allocator = testing.allocator;
    
    var debug_ext = try extensions.DebugExtension.init(allocator);
    defer debug_ext.deinit();
    
    try testing.expectEqualStrings("jinja2.ext.debug", debug_ext.extension.name);
    try testing.expect(debug_ext.extension.tags.items.len == 1);
    try testing.expectEqualStrings("debug", debug_ext.extension.tags.items[0]);
}

test "loop control extension init" {
    const allocator = testing.allocator;
    
    var lc_ext = try extensions.LoopControlExtension.init(allocator);
    defer lc_ext.deinit();
    
    try testing.expectEqualStrings("jinja2.ext.loopcontrols", lc_ext.extension.name);
    try testing.expect(lc_ext.extension.tags.items.len == 2);
    try testing.expectEqualStrings("break", lc_ext.extension.tags.items[0]);
    try testing.expectEqualStrings("continue", lc_ext.extension.tags.items[1]);
}

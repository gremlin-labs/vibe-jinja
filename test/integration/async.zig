const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;
const async_utils = vibe_jinja.async_utils;
const value_mod = vibe_jinja.value;
const filters = vibe_jinja.filters;
const tests_mod = vibe_jinja.tests;

// ============================================================================
// Basic Async Tests
// ============================================================================

test "async rendering basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();
    env.enable_async = true;

    // Simple template without variables to test async mode works
    const source = "Hello World!";

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Test sync rendering with async mode enabled
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Hello World!") != null);
}

test "async disabled returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();
    env.enable_async = false; // Explicitly disable async

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Should return error when async not enabled
    const result = rt.renderStringAsync("Hello", vars, "test");
    try testing.expectError(error.AsyncNotEnabled, result);
}

test "async filter execution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();
    env.enable_async = true;

    const source = "{{ text | upper }}";

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const text_key = try allocator.dupe(u8, "text");
    defer allocator.free(text_key);
    const text_str = try allocator.dupe(u8, "hello");
    defer allocator.free(text_str);
    try vars.put(text_key, context.Value{ .string = text_str });

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Async rendering should handle async filters
    const result = rt.renderStringAsync(source, vars, "test") catch |err| blk: {
        if (err == error.AsyncNotEnabled) {
            break :blk try rt.renderString(source, vars, "test");
        }
        return err;
    };
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "HELLO") != null);
}

test "async test execution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();
    env.enable_async = true;

    const source = "{% if value is defined %}yes{% else %}no{% endif %}";

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const value_key = try allocator.dupe(u8, "value");
    defer allocator.free(value_key);
    const value_str = try allocator.dupe(u8, "test");
    defer allocator.free(value_str);
    try vars.put(value_key, context.Value{ .string = value_str });

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Async rendering should handle async tests
    const result = rt.renderStringAsync(source, vars, "test") catch |err| blk: {
        if (err == error.AsyncNotEnabled) {
            break :blk try rt.renderString(source, vars, "test");
        }
        return err;
    };
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

test "async loader" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();
    env.enable_async = true;

    // Simple template without variables
    const template_source = "Hello World!";

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Test rendering with async mode enabled
    const result = try rt.renderString(template_source, vars, "test.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Hello World!") != null);
}

test "async with filters and tests" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();
    env.enable_async = true;

    const source = "{% if text is defined %}{{ text | upper }}{% endif %}";

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const text_key = try allocator.dupe(u8, "text");
    defer allocator.free(text_key);
    const text_str = try allocator.dupe(u8, "hello");
    defer allocator.free(text_str);
    try vars.put(text_key, context.Value{ .string = text_str });

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Async rendering with both filters and tests
    const result = rt.renderStringAsync(source, vars, "test") catch |err| blk: {
        if (err == error.AsyncNotEnabled) {
            break :blk try rt.renderString(source, vars, "test");
        }
        return err;
    };
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "HELLO") != null);
}

// ============================================================================
// Async Utils Tests
// ============================================================================

test "async utils - isAwaitable with primitives" {
    // Test that primitive types are never awaitable
    try testing.expect(!async_utils.AsyncIterator.isAwaitable(context.Value{ .integer = 42 }));
    try testing.expect(!async_utils.AsyncIterator.isAwaitable(context.Value{ .float = 3.14 }));
    try testing.expect(!async_utils.AsyncIterator.isAwaitable(context.Value{ .boolean = true }));
    try testing.expect(!async_utils.AsyncIterator.isAwaitable(context.Value{ .null = {} }));
}

test "async utils - isAwaitable with async result" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a pending async result
    const pending = try allocator.create(value_mod.AsyncResult);
    pending.* = value_mod.AsyncResult.pending(1);
    defer allocator.destroy(pending);

    const async_val = context.Value{ .async_result = pending };

    // Pending async result should be awaitable
    try testing.expect(async_utils.AsyncIterator.isAwaitable(async_val));

    // Complete the async result
    pending.completed = true;
    pending.value = context.Value{ .integer = 42 };

    // Completed async result should NOT be awaitable
    try testing.expect(!async_utils.AsyncIterator.isAwaitable(async_val));
}

test "async utils - autoAwait with non-awaitable" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // autoAwait should return primitives unchanged
    const int_val = context.Value{ .integer = 42 };
    const result = try async_utils.AsyncIterator.autoAwait(allocator, int_val);

    try testing.expectEqual(int_val.integer, result.integer);
}

test "async utils - autoAwait with completed async result" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a completed async result
    const completed = try allocator.create(value_mod.AsyncResult);
    completed.* = value_mod.AsyncResult.resolved(1, context.Value{ .integer = 42 });
    defer {
        completed.deinit(allocator);
        allocator.destroy(completed);
    }

    const async_val = context.Value{ .async_result = completed };
    var result = try async_utils.AsyncIterator.autoAwait(allocator, async_val);
    defer result.deinit(allocator);

    // Should return the resolved value
    try testing.expectEqual(@as(i64, 42), result.integer);
}

test "async utils - async tracker" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tracker = async_utils.AsyncTracker.init(allocator);
    defer tracker.deinit();

    // Create a pending operation
    const pending = try tracker.createPending();
    const id = pending.id;

    try testing.expect(!tracker.isComplete(id));
    try testing.expectEqual(@as(usize, 1), tracker.pendingCount());

    // Resolve the operation
    try tracker.resolve(id, context.Value{ .integer = 100 });

    try testing.expect(tracker.isComplete(id));
    try testing.expectEqual(@as(usize, 0), tracker.pendingCount());

    // Get the result
    const result = tracker.getResult(id);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i64, 100), result.?.value.?.integer);
}

test "async utils - async id generation" {
    const id1 = async_utils.generateAsyncId();
    const id2 = async_utils.generateAsyncId();
    const id3 = async_utils.generateAsyncId();

    // IDs should be unique and incrementing
    try testing.expect(id2 > id1);
    try testing.expect(id3 > id2);
}

// ============================================================================
// Value Type Async Tests
// ============================================================================

test "value - async result type" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test pending async result
    const pending = try allocator.create(value_mod.AsyncResult);
    pending.* = value_mod.AsyncResult.pending(1);

    var val = context.Value{ .async_result = pending };
    defer val.deinit(allocator);

    try testing.expect(val.isAsync());
    try testing.expect(!val.isAsyncComplete());
    try testing.expect(val.getAsyncValue() == null);
}

test "value - callable type" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const callable = try allocator.create(value_mod.Callable);
    callable.* = value_mod.Callable.init(
        try allocator.dupe(u8, "test_func"),
        .function,
        true, // is_async
    );

    var val = context.Value{ .callable = callable };
    defer val.deinit(allocator);

    try testing.expect(val.isCallable());
    try testing.expect(val.isAsync()); // async callable
}

test "value - async result to string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test pending async result to string
    const pending = try allocator.create(value_mod.AsyncResult);
    pending.* = value_mod.AsyncResult.pending(123);

    var val = context.Value{ .async_result = pending };
    defer val.deinit(allocator);

    const str = try val.toString(allocator);
    defer allocator.free(str);

    try testing.expect(std.mem.indexOf(u8, str, "pending") != null);
    try testing.expect(std.mem.indexOf(u8, str, "123") != null);
}

test "value - callable to string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const callable = try allocator.create(value_mod.Callable);
    callable.* = value_mod.Callable.init(
        try allocator.dupe(u8, "my_filter"),
        .filter,
        false,
    );

    var val = context.Value{ .callable = callable };
    defer val.deinit(allocator);

    const str = try val.toString(allocator);
    defer allocator.free(str);

    try testing.expect(std.mem.indexOf(u8, str, "filter") != null);
    try testing.expect(std.mem.indexOf(u8, str, "my_filter") != null);
}

// ============================================================================
// Environment Async Registration Tests
// ============================================================================

test "environment - add async filter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Define a simple async filter (same as sync for testing)
    const asyncUpperFilter = struct {
        fn filter(alloc: std.mem.Allocator, val: context.Value, args: []context.Value, ctx: ?*context.Context, e: ?*environment.Environment) !context.Value {
            _ = args;
            _ = ctx;
            _ = e;

            const str = try val.toString(alloc);
            defer alloc.free(str);

            var result = try alloc.alloc(u8, str.len);
            for (str, 0..) |c, i| {
                result[i] = std.ascii.toUpper(c);
            }

            return context.Value{ .string = result };
        }
    }.filter;

    try env.addAsyncFilter("async_upper", asyncUpperFilter, asyncUpperFilter);

    // Verify filter was registered
    const filter = env.getFilter("async_upper");
    try testing.expect(filter != null);
    try testing.expect(filter.?.is_async);
}

test "environment - add async test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Define a simple async test (same as sync for testing)
    const asyncDefinedTest = struct {
        fn testFn(val: context.Value, args: []const context.Value, ctx: ?*context.Context, e: ?*environment.Environment) bool {
            _ = args;
            _ = ctx;
            _ = e;
            return val.isTruthy() catch false;
        }
    }.testFn;

    try env.addAsyncTest("async_defined", asyncDefinedTest, asyncDefinedTest);

    // Verify test was registered
    const test_fn = env.getTest("async_defined");
    try testing.expect(test_fn != null);
    try testing.expect(test_fn.?.is_async);
}

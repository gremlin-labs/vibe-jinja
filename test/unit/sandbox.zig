const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const sandbox = vibe_jinja.sandbox;
const environment = vibe_jinja.environment;
const value = vibe_jinja.value;

// ============================================================================
// Safe Range Tests (7.1)
// ============================================================================

test "sandbox safe range basic iteration" {
    // Test basic range iteration
    var iter = try sandbox.safeRange(0, 5, null);
    
    var count: i64 = 0;
    while (iter.next()) |val| {
        try testing.expectEqual(count, val);
        count += 1;
    }
    try testing.expectEqual(@as(i64, 5), count);
}

test "sandbox safe range with step" {
    // Test range with custom step
    var iter = try sandbox.safeRange(0, 10, 2);
    
    const expected = [_]i64{ 0, 2, 4, 6, 8 };
    var i: usize = 0;
    while (iter.next()) |val| {
        try testing.expectEqual(expected[i], val);
        i += 1;
    }
    try testing.expectEqual(@as(usize, 5), i);
}

test "sandbox safe range negative step" {
    // Test range with negative step (countdown)
    var iter = try sandbox.safeRange(10, 0, -2);
    
    const expected = [_]i64{ 10, 8, 6, 4, 2 };
    var i: usize = 0;
    while (iter.next()) |val| {
        try testing.expectEqual(expected[i], val);
        i += 1;
    }
    try testing.expectEqual(@as(usize, 5), i);
}

test "sandbox safe range single arg (end only)" {
    // When only one arg provided, it's the end and start is 0
    var iter = try sandbox.safeRange(5, null, null);
    
    var count: i64 = 0;
    while (iter.next()) |val| {
        try testing.expectEqual(count, val);
        count += 1;
    }
    try testing.expectEqual(@as(i64, 5), count);
}

test "sandbox safe range empty range" {
    // Empty range (start >= end with positive step)
    var iter = try sandbox.safeRange(5, 3, 1);
    try testing.expectEqual(@as(?i64, null), iter.next());
}

test "sandbox safe range too large" {
    // Range exceeding MAX_RANGE should error
    const result = sandbox.safeRange(0, sandbox.MAX_RANGE + 1, null);
    try testing.expectError(sandbox.RangeError.RangeTooLarge, result);
}

test "sandbox safe range zero step" {
    // Zero step should error
    const result = sandbox.safeRange(0, 10, 0);
    try testing.expectError(sandbox.RangeError.RangeTooLarge, result);
}

test "sandbox safe range to list" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var iter = try sandbox.safeRange(0, 5, null);
    const list = try iter.toList(allocator);
    defer {
        list.deinit(allocator);
        allocator.destroy(list);
    }
    
    try testing.expectEqual(@as(usize, 5), list.items.items.len);
}

test "sandbox MAX_RANGE constant" {
    // Verify MAX_RANGE is set to the expected value
    try testing.expectEqual(@as(i64, 100000), sandbox.MAX_RANGE);
}

// ============================================================================
// Mutable Type Restriction Tests (7.2)
// ============================================================================

test "sandbox modifies known mutable - list operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer {
        list.deinit(allocator);
        allocator.destroy(list);
    }
    
    const list_val = value.Value{ .list = list };
    
    // Mutable operations should be detected
    try testing.expect(sandbox.modifiesKnownMutable(list_val, "append"));
    try testing.expect(sandbox.modifiesKnownMutable(list_val, "clear"));
    try testing.expect(sandbox.modifiesKnownMutable(list_val, "pop"));
    try testing.expect(sandbox.modifiesKnownMutable(list_val, "remove"));
    try testing.expect(sandbox.modifiesKnownMutable(list_val, "insert"));
    try testing.expect(sandbox.modifiesKnownMutable(list_val, "sort"));
    try testing.expect(sandbox.modifiesKnownMutable(list_val, "reverse"));
    try testing.expect(sandbox.modifiesKnownMutable(list_val, "extend"));
    
    // Non-mutable operations should not be detected
    try testing.expect(!sandbox.modifiesKnownMutable(list_val, "index"));
    try testing.expect(!sandbox.modifiesKnownMutable(list_val, "count"));
    try testing.expect(!sandbox.modifiesKnownMutable(list_val, "length"));
}

test "sandbox modifies known mutable - dict operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    defer {
        dict.deinit(allocator);
        allocator.destroy(dict);
    }
    
    const dict_val = value.Value{ .dict = dict };
    
    // Mutable operations should be detected
    try testing.expect(sandbox.modifiesKnownMutable(dict_val, "clear"));
    try testing.expect(sandbox.modifiesKnownMutable(dict_val, "pop"));
    try testing.expect(sandbox.modifiesKnownMutable(dict_val, "popitem"));
    try testing.expect(sandbox.modifiesKnownMutable(dict_val, "setdefault"));
    try testing.expect(sandbox.modifiesKnownMutable(dict_val, "update"));
    
    // Non-mutable operations should not be detected
    try testing.expect(!sandbox.modifiesKnownMutable(dict_val, "get"));
    try testing.expect(!sandbox.modifiesKnownMutable(dict_val, "keys"));
    try testing.expect(!sandbox.modifiesKnownMutable(dict_val, "values"));
    try testing.expect(!sandbox.modifiesKnownMutable(dict_val, "items"));
}

test "sandbox modifies known mutable - string operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var string_val = value.Value{ .string = try allocator.dupe(u8, "test") };
    defer string_val.deinit(allocator);
    
    // Strings are immutable, so no operations should be flagged
    try testing.expect(!sandbox.modifiesKnownMutable(string_val, "upper"));
    try testing.expect(!sandbox.modifiesKnownMutable(string_val, "lower"));
    try testing.expect(!sandbox.modifiesKnownMutable(string_val, "replace"));
}

// ============================================================================
// Function Call Restriction Tests (7.3)
// ============================================================================

test "sandbox is internal attribute - double underscore" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var test_val = value.Value{ .string = try allocator.dupe(u8, "test") };
    defer test_val.deinit(allocator);
    
    // Double underscore attributes are internal
    try testing.expect(sandbox.isInternalAttribute(test_val, "__class__"));
    try testing.expect(sandbox.isInternalAttribute(test_val, "__dict__"));
    try testing.expect(sandbox.isInternalAttribute(test_val, "__module__"));
    
    // Regular attributes are not internal
    try testing.expect(!sandbox.isInternalAttribute(test_val, "length"));
    try testing.expect(!sandbox.isInternalAttribute(test_val, "upper"));
}

test "sandbox callable safety flags" {
    // Test unsafe callable detection
    var safe_callable = value.Callable.init("safe_func", .function, false);
    try testing.expect(!sandbox.hasUnsafeCallableMarker(value.Value{ .callable = safe_callable }));
    
    // Mark as unsafe
    safe_callable.markUnsafe();
    try testing.expect(sandbox.hasUnsafeCallableMarker(value.Value{ .callable = safe_callable }));
    
    // Test alters_data flag
    var data_callable = value.Callable.init("data_func", .function, false);
    data_callable.markAltersData();
    try testing.expect(sandbox.hasUnsafeCallableMarker(value.Value{ .callable = data_callable }));
    
    // Test initUnsafe
    const unsafe_callable = value.Callable.initUnsafe("danger_func", .function);
    try testing.expect(sandbox.hasUnsafeCallableMarker(value.Value{ .callable = unsafe_callable }));
}

test "sandbox unsafe callable names" {
    // Known unsafe callable names should be blocked
    var eval_callable = value.Callable.init("eval", .function, false);
    try testing.expect(!sandbox.isSafeCallableModule(value.Value{ .callable = eval_callable }));
    
    var exec_callable = value.Callable.init("exec", .function, false);
    try testing.expect(!sandbox.isSafeCallableModule(value.Value{ .callable = exec_callable }));
    
    var open_callable = value.Callable.init("open", .function, false);
    try testing.expect(!sandbox.isSafeCallableModule(value.Value{ .callable = open_callable }));
    
    // Safe names should pass
    var safe_callable = value.Callable.init("upper", .function, false);
    try testing.expect(sandbox.isSafeCallableModule(value.Value{ .callable = safe_callable }));
}

// ============================================================================
// SandboxedEnvironment Tests
// ============================================================================

test "sandbox environment init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sandbox_env = try sandbox.SandboxedEnvironment.init(allocator);
    defer sandbox_env.deinit();

    try testing.expect(sandbox_env.sandboxed == true);
    try testing.expect(sandbox_env.base.sandboxed == true);
}

test "sandbox environment safe range check" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sandbox_env = try sandbox.SandboxedEnvironment.init(allocator);
    defer sandbox_env.deinit();

    // Small range should succeed
    var iter = try sandbox_env.checkSafeRange(0, 100, null);
    var count: i64 = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(i64, 100), count);
    
    // Large range should fail
    const result = sandbox_env.checkSafeRange(0, sandbox.MAX_RANGE + 1, null);
    try testing.expectError(sandbox.RangeError.RangeTooLarge, result);
}

test "sandbox unsafe attribute check" {
    try testing.expect(sandbox.isUnsafeAttribute("__class__"));
    try testing.expect(sandbox.isUnsafeAttribute("__dict__"));
    try testing.expect(sandbox.isUnsafeAttribute("__init__"));
    try testing.expect(sandbox.isUnsafeAttribute("_private"));
    try testing.expect(!sandbox.isUnsafeAttribute("safe_attr"));
    try testing.expect(!sandbox.isUnsafeAttribute("public_method"));
}

test "sandbox safe attribute check" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sandbox_env = try sandbox.SandboxedEnvironment.init(allocator);
    defer sandbox_env.deinit();

    var test_val = value.Value{ .string = try allocator.dupe(u8, "test") };
    defer test_val.deinit(allocator);

    // Safe attribute should pass
    try testing.expect(sandbox_env.isSafeAttributeAccess(test_val, "safe_attr"));

    // Unsafe attribute should fail
    try testing.expect(!sandbox_env.isSafeAttributeAccess(test_val, "__class__"));
    try testing.expect(!sandbox_env.isSafeAttributeAccess(test_val, "__dict__"));
}

test "sandbox safe callable check" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sandbox_env = try sandbox.SandboxedEnvironment.init(allocator);
    defer sandbox_env.deinit();

    // Safe callable
    const safe_callable = value.Callable.init("safe_func", .function, false);
    try testing.expect(sandbox_env.isSafeCallableCheck(value.Value{ .callable = safe_callable }));
    
    // Unsafe callable
    const unsafe_callable = value.Callable.initUnsafe("danger_func", .function);
    try testing.expect(!sandbox_env.isSafeCallableCheck(value.Value{ .callable = unsafe_callable }));
}

test "sandbox add safe attribute" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sandbox_env = try sandbox.SandboxedEnvironment.init(allocator);
    defer sandbox_env.deinit();

    try sandbox_env.addSafeAttribute("custom_attr");

    var test_val = value.Value{ .string = try allocator.dupe(u8, "test") };
    defer test_val.deinit(allocator);

    try testing.expect(sandbox_env.isSafeAttributeAccess(test_val, "custom_attr"));
}

test "sandbox add safe function" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sandbox_env = try sandbox.SandboxedEnvironment.init(allocator);
    defer sandbox_env.deinit();

    try sandbox_env.addSafeFunction("custom_func");

    const callable = value.Callable.init("custom_func", .function, false);
    try testing.expect(sandbox_env.isSafeCallableCheck(value.Value{ .callable = callable }));
}

// ============================================================================
// ImmutableSandboxedEnvironment Tests
// ============================================================================

test "immutable sandbox environment init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sandbox_env = try sandbox.ImmutableSandboxedEnvironment.init(allocator);
    defer sandbox_env.deinit();

    try testing.expect(sandbox_env.inner.sandboxed == true);
    try testing.expect(sandbox_env.inner.block_mutable_operations == true);
}

test "immutable sandbox blocks mutable list operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sandbox_env = try sandbox.ImmutableSandboxedEnvironment.init(allocator);
    defer sandbox_env.deinit();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer {
        list.deinit(allocator);
        allocator.destroy(list);
    }
    
    const list_val = value.Value{ .list = list };

    // Mutable operations should be blocked
    try testing.expect(!sandbox_env.isSafeAttributeAccess(list_val, "append"));
    try testing.expect(!sandbox_env.isSafeAttributeAccess(list_val, "clear"));
    try testing.expect(!sandbox_env.isSafeAttributeAccess(list_val, "pop"));
    
    // Non-mutable operations should be allowed
    try testing.expect(sandbox_env.isSafeAttributeAccess(list_val, "index"));
    try testing.expect(sandbox_env.isSafeAttributeAccess(list_val, "count"));
}

test "immutable sandbox blocks mutable dict operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sandbox_env = try sandbox.ImmutableSandboxedEnvironment.init(allocator);
    defer sandbox_env.deinit();

    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    defer {
        dict.deinit(allocator);
        allocator.destroy(dict);
    }
    
    const dict_val = value.Value{ .dict = dict };

    // Mutable operations should be blocked
    try testing.expect(!sandbox_env.isSafeAttributeAccess(dict_val, "clear"));
    try testing.expect(!sandbox_env.isSafeAttributeAccess(dict_val, "pop"));
    try testing.expect(!sandbox_env.isSafeAttributeAccess(dict_val, "update"));
    
    // Non-mutable operations should be allowed
    try testing.expect(sandbox_env.isSafeAttributeAccess(dict_val, "get"));
    try testing.expect(sandbox_env.isSafeAttributeAccess(dict_val, "keys"));
}

test "sandbox module level safe attribute" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_val = value.Value{ .string = try allocator.dupe(u8, "test") };
    defer test_val.deinit(allocator);

    try testing.expect(sandbox.isSafeAttributeModule(test_val, "safe_attr"));
    try testing.expect(!sandbox.isSafeAttributeModule(test_val, "__class__"));
}

test "sandbox module level safe callable" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_val = value.Value{ .string = try allocator.dupe(u8, "test") };
    defer test_val.deinit(allocator);

    // Non-callable values are safe to call (they'll just error at runtime)
    const result = sandbox.isSafeCallableModule(test_val);
    try testing.expect(result);
}

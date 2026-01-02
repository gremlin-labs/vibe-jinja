const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const tests = vibe_jinja.tests;
const value = vibe_jinja.value;
const context = vibe_jinja.context;
const environment = vibe_jinja.environment;

test "test defined" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // In Jinja2, "is defined" checks if the value EXISTS, not if it's truthy
    // Any value that is not the undefined type is considered "defined"

    // Test with string value - IS defined
    var val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer val.deinit(allocator);
    try testing.expect(tests.BuiltinTests.defined(val, &[_]value.Value{}, null, null));

    // Test with empty string - IS defined (empty string is a valid value)
    var empty_val = value.Value{ .string = try allocator.dupe(u8, "") };
    defer empty_val.deinit(allocator);
    try testing.expect(tests.BuiltinTests.defined(empty_val, &[_]value.Value{}, null, null));

    // Test with null - IS defined (null/None is a valid value in Jinja2)
    const null_val = value.Value{ .null = {} };
    try testing.expect(tests.BuiltinTests.defined(null_val, &[_]value.Value{}, null, null));

    // Test with boolean false - IS defined
    const false_val = value.Value{ .boolean = false };
    try testing.expect(tests.BuiltinTests.defined(false_val, &[_]value.Value{}, null, null));

    // Test with undefined value - NOT defined
    const undefined_val = value.Value{ .undefined = value.Undefined{ .name = "x", .behavior = .lenient, .logger = null } };
    try testing.expect(!tests.BuiltinTests.defined(undefined_val, &[_]value.Value{}, null, null));
}

test "test undefined" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // In Jinja2, "is undefined" checks if the value is the undefined type
    // Only variables that don't exist in the context are undefined

    // Test with actual undefined value - IS undefined
    const undefined_val = value.Value{ .undefined = value.Undefined{ .name = "x", .behavior = .lenient, .logger = null } };
    try testing.expect(tests.BuiltinTests.@"undefined"(undefined_val, &[_]value.Value{}, null, null));

    // Test with empty string - NOT undefined (it's a valid value)
    var empty_val = value.Value{ .string = try allocator.dupe(u8, "") };
    defer empty_val.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.@"undefined"(empty_val, &[_]value.Value{}, null, null));

    // Test with string value - NOT undefined
    var val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer val.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.@"undefined"(val, &[_]value.Value{}, null, null));

    // Test with null - NOT undefined
    const null_val = value.Value{ .null = {} };
    try testing.expect(!tests.BuiltinTests.@"undefined"(null_val, &[_]value.Value{}, null, null));
}

test "test equalto" {
    const val1 = value.Value{ .integer = 42 };
    const val2 = value.Value{ .integer = 42 };
    var args = [_]value.Value{val2};
    try testing.expect(tests.BuiltinTests.equalto(val1, &args, null, null));

    const val3 = value.Value{ .integer = 43 };
    var args2 = [_]value.Value{val3};
    try testing.expect(!tests.BuiltinTests.equalto(val1, &args2, null, null));

    // Test with no args
    try testing.expect(!tests.BuiltinTests.equalto(val1, &[_]value.Value{}, null, null));
}

test "test even" {
    try testing.expect(tests.BuiltinTests.even(value.Value{ .integer = 2 }, &[_]value.Value{}, null, null));
    try testing.expect(tests.BuiltinTests.even(value.Value{ .integer = 0 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.even(value.Value{ .integer = 1 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.even(value.Value{ .integer = 3 }, &[_]value.Value{}, null, null));
    
    // String "2" can be converted to integer 2, which is even (Jinja2 type coercion)
    try testing.expect(tests.BuiltinTests.even(value.Value{ .string = "2" }, &[_]value.Value{}, null, null));
    // Non-numeric string should return false
    try testing.expect(!tests.BuiltinTests.even(value.Value{ .string = "hello" }, &[_]value.Value{}, null, null));
}

test "test odd" {
    try testing.expect(tests.BuiltinTests.odd(value.Value{ .integer = 1 }, &[_]value.Value{}, null, null));
    try testing.expect(tests.BuiltinTests.odd(value.Value{ .integer = 3 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.odd(value.Value{ .integer = 2 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.odd(value.Value{ .integer = 0 }, &[_]value.Value{}, null, null));
    
    // String "1" can be converted to integer 1, which is odd (Jinja2 type coercion)
    try testing.expect(tests.BuiltinTests.odd(value.Value{ .string = "1" }, &[_]value.Value{}, null, null));
    // Non-numeric string should return false
    try testing.expect(!tests.BuiltinTests.odd(value.Value{ .string = "hello" }, &[_]value.Value{}, null, null));
}

test "test divisibleby" {
    try testing.expect(tests.BuiltinTests.divisibleby(value.Value{ .integer = 10 }, &[_]value.Value{value.Value{ .integer = 5 }}, null, null));
    try testing.expect(tests.BuiltinTests.divisibleby(value.Value{ .integer = 10 }, &[_]value.Value{value.Value{ .integer = 2 }}, null, null));
    try testing.expect(!tests.BuiltinTests.divisibleby(value.Value{ .integer = 10 }, &[_]value.Value{value.Value{ .integer = 3 }}, null, null));
    
    // Division by zero should return false
    try testing.expect(!tests.BuiltinTests.divisibleby(value.Value{ .integer = 10 }, &[_]value.Value{value.Value{ .integer = 0 }}, null, null));
    
    // No args should return false
    try testing.expect(!tests.BuiltinTests.divisibleby(value.Value{ .integer = 10 }, &[_]value.Value{}, null, null));
}

test "test lower" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var lower_str = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer lower_str.deinit(allocator);
    try testing.expect(tests.BuiltinTests.lower(lower_str, &[_]value.Value{}, null, null));

    var upper_str = value.Value{ .string = try allocator.dupe(u8, "HELLO") };
    defer upper_str.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.lower(upper_str, &[_]value.Value{}, null, null));

    var mixed_str = value.Value{ .string = try allocator.dupe(u8, "Hello") };
    defer mixed_str.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.lower(mixed_str, &[_]value.Value{}, null, null));
}

test "test upper" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var upper_str = value.Value{ .string = try allocator.dupe(u8, "HELLO") };
    defer upper_str.deinit(allocator);
    try testing.expect(tests.BuiltinTests.upper(upper_str, &[_]value.Value{}, null, null));

    var lower_str = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer lower_str.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.upper(lower_str, &[_]value.Value{}, null, null));

    var mixed_str = value.Value{ .string = try allocator.dupe(u8, "Hello") };
    defer mixed_str.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.upper(mixed_str, &[_]value.Value{}, null, null));
}

test "test string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var str_val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer str_val.deinit(allocator);
    try testing.expect(tests.BuiltinTests.string(str_val, &[_]value.Value{}, null, null));

    try testing.expect(!tests.BuiltinTests.string(value.Value{ .integer = 42 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.string(value.Value{ .boolean = true }, &[_]value.Value{}, null, null));
}

test "test number" {
    try testing.expect(tests.BuiltinTests.number(value.Value{ .integer = 42 }, &[_]value.Value{}, null, null));
    try testing.expect(tests.BuiltinTests.number(value.Value{ .float = 3.14 }, &[_]value.Value{}, null, null));
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var str_val = value.Value{ .string = try allocator.dupe(u8, "42") };
    defer str_val.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.number(str_val, &[_]value.Value{}, null, null));
}

test "test empty" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var empty_str = value.Value{ .string = try allocator.dupe(u8, "") };
    defer empty_str.deinit(allocator);
    try testing.expect(tests.BuiltinTests.empty(empty_str, &[_]value.Value{}, null, null));

    var str_val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer str_val.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.empty(str_val, &[_]value.Value{}, null, null));

    try testing.expect(tests.BuiltinTests.empty(value.Value{ .null = {} }, &[_]value.Value{}, null, null));
}

test "test none" {
    try testing.expect(tests.BuiltinTests.none(value.Value{ .null = {} }, &[_]value.Value{}, null, null));
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var str_val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer str_val.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.none(str_val, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.none(value.Value{ .integer = 42 }, &[_]value.Value{}, null, null));
}

test "test boolean" {
    try testing.expect(tests.BuiltinTests.boolean(value.Value{ .boolean = true }, &[_]value.Value{}, null, null));
    try testing.expect(tests.BuiltinTests.boolean(value.Value{ .boolean = false }, &[_]value.Value{}, null, null));
    
    try testing.expect(!tests.BuiltinTests.boolean(value.Value{ .integer = 1 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.boolean(value.Value{ .integer = 0 }, &[_]value.Value{}, null, null));
}

test "test false" {
    try testing.expect(tests.BuiltinTests.@"false"(value.Value{ .boolean = false }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.@"false"(value.Value{ .boolean = true }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.@"false"(value.Value{ .integer = 0 }, &[_]value.Value{}, null, null));
}

test "test true" {
    try testing.expect(tests.BuiltinTests.@"true"(value.Value{ .boolean = true }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.@"true"(value.Value{ .boolean = false }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.@"true"(value.Value{ .integer = 1 }, &[_]value.Value{}, null, null));
}

test "test integer" {
    try testing.expect(tests.BuiltinTests.integer(value.Value{ .integer = 42 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.integer(value.Value{ .float = 3.14 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.integer(value.Value{ .boolean = true }, &[_]value.Value{}, null, null));
}

test "test float" {
    try testing.expect(tests.BuiltinTests.float(value.Value{ .float = 3.14 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.float(value.Value{ .integer = 42 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.float(value.Value{ .boolean = true }, &[_]value.Value{}, null, null));
}

test "test mapping" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    defer dict.deinit(allocator);
    const dict_val = value.Value{ .dict = dict };
    try testing.expect(tests.BuiltinTests.mapping(dict_val, &[_]value.Value{}, null, null));

    var str_val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer str_val.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.mapping(str_val, &[_]value.Value{}, null, null));
}

test "test sequence" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    const list_val = value.Value{ .list = list };
    try testing.expect(tests.BuiltinTests.sequence(list_val, &[_]value.Value{}, null, null));

    var str_val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer str_val.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.sequence(str_val, &[_]value.Value{}, null, null));
}

test "test iterable" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    const list_val = value.Value{ .list = list };
    try testing.expect(tests.BuiltinTests.iterable(list_val, &[_]value.Value{}, null, null));

    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    defer dict.deinit(allocator);
    const dict_val = value.Value{ .dict = dict };
    try testing.expect(tests.BuiltinTests.iterable(dict_val, &[_]value.Value{}, null, null));

    var str_val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer str_val.deinit(allocator);
    try testing.expect(tests.BuiltinTests.iterable(str_val, &[_]value.Value{}, null, null));

    try testing.expect(!tests.BuiltinTests.iterable(value.Value{ .integer = 42 }, &[_]value.Value{}, null, null));
}

test "test callable" {
    // Callable test checks for macros, functions, and callable objects
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with string (not callable without context/env)
    var str_val = value.Value{ .string = try allocator.dupe(u8, "func") };
    defer str_val.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.callable(str_val, &[_]value.Value{}, null, null));

    // Test with callable value
    var callable_obj = try allocator.create(value.Callable);
    const callable_name = try allocator.dupe(u8, "test_func");
    callable_obj.* = value.Callable.init(callable_name, .function, false);
    defer {
        callable_obj.deinit(allocator);
        allocator.destroy(callable_obj);
    }
    const callable_val = value.Value{ .callable = callable_obj };
    try testing.expect(tests.BuiltinTests.callable(callable_val, &[_]value.Value{}, null, null));

    // Test with callable having function pointer
    const test_fn = struct {
        fn call(_: std.mem.Allocator, _: []value.Value, _: ?*anyopaque, _: ?*anyopaque) value.CallError!value.Value {
            return value.Value{ .integer = 42 };
        }
    }.call;
    
    var callable_with_fn = try allocator.create(value.Callable);
    const fn_name = try allocator.dupe(u8, "test_fn");
    callable_with_fn.* = value.Callable.initWithFunc(fn_name, test_fn, false);
    defer {
        callable_with_fn.deinit(allocator);
        allocator.destroy(callable_with_fn);
    }
    const callable_fn_val = value.Value{ .callable = callable_with_fn };
    try testing.expect(tests.BuiltinTests.callable(callable_fn_val, &[_]value.Value{}, null, null));
    
    // Test Value.isCallable() helper
    try testing.expect(callable_val.isCallable());
    try testing.expect(callable_fn_val.isCallable());
    try testing.expect(!str_val.isCallable());
    const int_val = value.Value{ .integer = 42 };
    try testing.expect(!int_val.isCallable());

    // Test with dict having __call__ method (callable object pattern)
    var dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    defer dict.deinit(allocator);
    
    // dict.set duplicates the key, so we can pass a string literal directly
    try dict.set("__call__", value.Value{ .boolean = true });
    const dict_val = value.Value{ .dict = dict };
    try testing.expect(tests.BuiltinTests.callable(dict_val, &[_]value.Value{}, null, null));
    
    // Test with environment and filter name
    var env = environment.Environment.init(allocator);
    defer env.deinit();
    
    var filter_name = value.Value{ .string = try allocator.dupe(u8, "upper") };
    defer filter_name.deinit(allocator);
    // Filter names are callable when an environment is provided
    try testing.expect(tests.BuiltinTests.callable(filter_name, &[_]value.Value{}, null, &env));
}

test "test sameas" {
    const val1 = value.Value{ .integer = 42 };
    const val2 = value.Value{ .integer = 42 };
    var args = [_]value.Value{val2};
    // sameas uses equality comparison for now
    try testing.expect(tests.BuiltinTests.sameas(val1, &args, null, null));

    const val3 = value.Value{ .integer = 43 };
    var args2 = [_]value.Value{val3};
    try testing.expect(!tests.BuiltinTests.sameas(val1, &args2, null, null));

    // No args should return false
    try testing.expect(!tests.BuiltinTests.sameas(val1, &[_]value.Value{}, null, null));
}

test "test escaped" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create markup value
    var markup = try value.Markup.init(allocator, "<html>");
    defer markup.deinit(allocator);
    const markup_val = value.Value{ .markup = &markup };
    try testing.expect(tests.BuiltinTests.escaped(markup_val, &[_]value.Value{}, null, null));

    var str_val = value.Value{ .string = try allocator.dupe(u8, "<html>") };
    defer str_val.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.escaped(str_val, &[_]value.Value{}, null, null));
}

test "test in" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with list
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 2 });
    try list.append(value.Value{ .integer = 3 });
    const list_val = value.Value{ .list = list };
    
    var args = [_]value.Value{list_val};
    try testing.expect(tests.BuiltinTests.@"in"(value.Value{ .integer = 2 }, &args, null, null));
    try testing.expect(!tests.BuiltinTests.@"in"(value.Value{ .integer = 4 }, &args, null, null));

    // Test with string
    var str_val = value.Value{ .string = try allocator.dupe(u8, "hello world") };
    defer str_val.deinit(allocator);
    var args2 = [_]value.Value{str_val};
    
    var substr = value.Value{ .string = try allocator.dupe(u8, "world") };
    defer substr.deinit(allocator);
    try testing.expect(tests.BuiltinTests.@"in"(substr, &args2, null, null));

    // No args should return false
    try testing.expect(!tests.BuiltinTests.@"in"(value.Value{ .integer = 1 }, &[_]value.Value{}, null, null));
}

test "test filter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Test with existing filter
    var filter_name = value.Value{ .string = try allocator.dupe(u8, "upper") };
    defer filter_name.deinit(allocator);
    try testing.expect(tests.BuiltinTests.filter(filter_name, &[_]value.Value{}, null, &env));

    // Test with non-existent filter
    var bad_name = value.Value{ .string = try allocator.dupe(u8, "nonexistent") };
    defer bad_name.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.filter(bad_name, &[_]value.Value{}, null, &env));

    // Test without environment
    try testing.expect(!tests.BuiltinTests.filter(filter_name, &[_]value.Value{}, null, null));
}

test "test test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Test with existing test
    var test_name = value.Value{ .string = try allocator.dupe(u8, "defined") };
    defer test_name.deinit(allocator);
    try testing.expect(tests.BuiltinTests.@"test"(test_name, &[_]value.Value{}, null, &env));

    // Test with non-existent test
    var bad_name = value.Value{ .string = try allocator.dupe(u8, "nonexistent") };
    defer bad_name.deinit(allocator);
    try testing.expect(!tests.BuiltinTests.@"test"(bad_name, &[_]value.Value{}, null, &env));

    // Test without environment
    try testing.expect(!tests.BuiltinTests.@"test"(test_name, &[_]value.Value{}, null, null));
}

// ============================================================================
// Comparison Tests via equalto (Jinja2 test_compare_aliases)
// Note: ne, lt, le, gt, ge are not yet implemented - tests use equalto
// ============================================================================

test "test equalto with integers" {
    const val1 = value.Value{ .integer = 12 };
    const val2 = value.Value{ .integer = 12 };
    var args = [_]value.Value{val2};
    try testing.expect(tests.BuiltinTests.equalto(val1, &args, null, null));

    const val3 = value.Value{ .integer = 0 };
    var args2 = [_]value.Value{val3};
    try testing.expect(!tests.BuiltinTests.equalto(val1, &args2, null, null));
}

test "test equalto with strings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var val1 = value.Value{ .string = try allocator.dupe(u8, "baz") };
    defer val1.deinit(allocator);
    
    var val2 = value.Value{ .string = try allocator.dupe(u8, "baz") };
    defer val2.deinit(allocator);
    var args = [_]value.Value{val2};
    try testing.expect(tests.BuiltinTests.equalto(val1, &args, null, null));

    var val3 = value.Value{ .string = try allocator.dupe(u8, "zab") };
    defer val3.deinit(allocator);
    var args2 = [_]value.Value{val3};
    try testing.expect(!tests.BuiltinTests.equalto(val1, &args2, null, null));
}

// ============================================================================
// Edge Cases Tests
// ============================================================================

test "test empty list" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    
    const list_val = value.Value{ .list = list };
    try testing.expect(tests.BuiltinTests.empty(list_val, &[_]value.Value{}, null, null));
}

test "test empty dict" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    defer dict.deinit(allocator);
    
    const dict_val = value.Value{ .dict = dict };
    try testing.expect(tests.BuiltinTests.empty(dict_val, &[_]value.Value{}, null, null));
}

test "test non-empty list" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 1 });
    
    const list_val = value.Value{ .list = list };
    try testing.expect(!tests.BuiltinTests.empty(list_val, &[_]value.Value{}, null, null));
}

// ============================================================================
// Type Coercion Tests
// ============================================================================

test "test divisibleby with float" {
    // 10.0 / 5 = 2.0 (exact)
    try testing.expect(tests.BuiltinTests.divisibleby(value.Value{ .float = 10.0 }, &[_]value.Value{value.Value{ .integer = 5 }}, null, null));
    
    // 10.0 / 3 = 3.333... (not exact)
    try testing.expect(!tests.BuiltinTests.divisibleby(value.Value{ .float = 10.0 }, &[_]value.Value{value.Value{ .integer = 3 }}, null, null));
}

test "test even with large numbers" {
    try testing.expect(tests.BuiltinTests.even(value.Value{ .integer = 1000000 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.even(value.Value{ .integer = 1000001 }, &[_]value.Value{}, null, null));
}

test "test odd with large numbers" {
    try testing.expect(tests.BuiltinTests.odd(value.Value{ .integer = 1000001 }, &[_]value.Value{}, null, null));
    try testing.expect(!tests.BuiltinTests.odd(value.Value{ .integer = 1000000 }, &[_]value.Value{}, null, null));
}

// ============================================================================
// Comparison Tests (Jinja2 test_compare_aliases parity)
// ============================================================================

test "comparison test: lt with integers" {
    // Test from Jinja2: {{ 2 is lt 3 }} -> True
    try testing.expect(tests.BuiltinTests.lt(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .integer = 3 }},
        null,
        null,
    ));

    // Test: {{ 2 is lt 2 }} -> False
    try testing.expect(!tests.BuiltinTests.lt(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .integer = 2 }},
        null,
        null,
    ));

    // Test: {{ 3 is lt 2 }} -> False
    try testing.expect(!tests.BuiltinTests.lt(
        value.Value{ .integer = 3 },
        &[_]value.Value{value.Value{ .integer = 2 }},
        null,
        null,
    ));
}

test "comparison test: lt with floats" {
    try testing.expect(tests.BuiltinTests.lt(
        value.Value{ .float = 2.5 },
        &[_]value.Value{value.Value{ .float = 3.5 }},
        null,
        null,
    ));

    try testing.expect(!tests.BuiltinTests.lt(
        value.Value{ .float = 3.5 },
        &[_]value.Value{value.Value{ .float = 2.5 }},
        null,
        null,
    ));
}

test "comparison test: lt with strings" {
    try testing.expect(tests.BuiltinTests.lt(
        value.Value{ .string = "apple" },
        &[_]value.Value{value.Value{ .string = "banana" }},
        null,
        null,
    ));

    try testing.expect(!tests.BuiltinTests.lt(
        value.Value{ .string = "banana" },
        &[_]value.Value{value.Value{ .string = "apple" }},
        null,
        null,
    ));
}

test "comparison test: le with integers" {
    // {{ 2 is le 2 }} -> True
    try testing.expect(tests.BuiltinTests.le(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .integer = 2 }},
        null,
        null,
    ));

    // {{ 2 is le 3 }} -> True
    try testing.expect(tests.BuiltinTests.le(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .integer = 3 }},
        null,
        null,
    ));

    // {{ 2 is le 1 }} -> False
    try testing.expect(!tests.BuiltinTests.le(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .integer = 1 }},
        null,
        null,
    ));
}

test "comparison test: gt with integers" {
    // {{ 2 is gt 1 }} -> True
    try testing.expect(tests.BuiltinTests.gt(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .integer = 1 }},
        null,
        null,
    ));

    // {{ 2 is gt 2 }} -> False
    try testing.expect(!tests.BuiltinTests.gt(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .integer = 2 }},
        null,
        null,
    ));

    // {{ 1 is gt 2 }} -> False
    try testing.expect(!tests.BuiltinTests.gt(
        value.Value{ .integer = 1 },
        &[_]value.Value{value.Value{ .integer = 2 }},
        null,
        null,
    ));
}

test "comparison test: ge with integers" {
    // {{ 2 is ge 2 }} -> True
    try testing.expect(tests.BuiltinTests.ge(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .integer = 2 }},
        null,
        null,
    ));

    // {{ 3 is ge 2 }} -> True
    try testing.expect(tests.BuiltinTests.ge(
        value.Value{ .integer = 3 },
        &[_]value.Value{value.Value{ .integer = 2 }},
        null,
        null,
    ));

    // {{ 2 is ge 3 }} -> False
    try testing.expect(!tests.BuiltinTests.ge(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .integer = 3 }},
        null,
        null,
    ));
}

test "comparison test: ne with integers" {
    // {{ 2 is ne 3 }} -> True
    try testing.expect(tests.BuiltinTests.ne(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .integer = 3 }},
        null,
        null,
    ));

    // {{ 2 is ne 2 }} -> False
    try testing.expect(!tests.BuiltinTests.ne(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .integer = 2 }},
        null,
        null,
    ));
}

test "comparison test: ne with strings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var val1 = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer val1.deinit(allocator);

    var val2 = value.Value{ .string = try allocator.dupe(u8, "world") };
    defer val2.deinit(allocator);

    var val3 = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer val3.deinit(allocator);

    // "hello" is ne "world" -> True
    try testing.expect(tests.BuiltinTests.ne(val1, &[_]value.Value{val2}, null, null));

    // "hello" is ne "hello" -> False
    try testing.expect(!tests.BuiltinTests.ne(val1, &[_]value.Value{val3}, null, null));
}

test "comparison test: no args returns false" {
    const val = value.Value{ .integer = 2 };
    const empty_args = &[_]value.Value{};

    try testing.expect(!tests.BuiltinTests.lt(val, empty_args, null, null));
    try testing.expect(!tests.BuiltinTests.le(val, empty_args, null, null));
    try testing.expect(!tests.BuiltinTests.gt(val, empty_args, null, null));
    try testing.expect(!tests.BuiltinTests.ge(val, empty_args, null, null));
    try testing.expect(!tests.BuiltinTests.ne(val, empty_args, null, null));
}

test "comparison test: mixed int/float" {
    // int < float
    try testing.expect(tests.BuiltinTests.lt(
        value.Value{ .integer = 2 },
        &[_]value.Value{value.Value{ .float = 3.5 }},
        null,
        null,
    ));

    // float < int
    try testing.expect(tests.BuiltinTests.lt(
        value.Value{ .float = 1.5 },
        &[_]value.Value{value.Value{ .integer = 2 }},
        null,
        null,
    ));
}

test "comparison test aliases exist in environment" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Verify all comparison test aliases exist
    try testing.expect(env.getTest("lt") != null);
    try testing.expect(env.getTest("le") != null);
    try testing.expect(env.getTest("gt") != null);
    try testing.expect(env.getTest("ge") != null);
    try testing.expect(env.getTest("ne") != null);
    try testing.expect(env.getTest("eq") != null);

    // Verify operator symbol aliases exist
    try testing.expect(env.getTest("==") != null);
    try testing.expect(env.getTest("!=") != null);
    try testing.expect(env.getTest("<") != null);
    try testing.expect(env.getTest("<=") != null);
    try testing.expect(env.getTest(">") != null);
    try testing.expect(env.getTest(">=") != null);

    // Verify name aliases exist
    try testing.expect(env.getTest("lessthan") != null);
    try testing.expect(env.getTest("greaterthan") != null);
}

const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const filters = vibe_jinja.filters;
const value = vibe_jinja.value;
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;

/// Helper to call filter functions with empty kwargs for testing
fn callFilter(
    comptime filter_fn: filters.FilterFn,
    allocator: std.mem.Allocator,
    input: value.Value,
    args: []value.Value,
) !value.Value {
    var empty_kwargs = std.StringHashMap(value.Value).init(allocator);
    defer empty_kwargs.deinit();
    return filter_fn(allocator, input, args, &empty_kwargs, null, null);
}

fn expectSplitWithAllocator(
    allocator: std.mem.Allocator,
    input_text: []const u8,
    separator: ?[]const u8,
    maxsplit: ?i64,
    expected: []const []const u8,
) !void {
    var input = value.Value{ .string = try allocator.dupe(u8, input_text) };
    defer input.deinit(allocator);

    var args_buffer: [2]value.Value = undefined;
    var args_len: usize = 0;
    if (separator) |separator_text| {
        args_buffer[args_len] = .{ .string = try allocator.dupe(u8, separator_text) };
        args_len += 1;
    } else if (maxsplit != null) {
        args_buffer[args_len] = .null;
        args_len += 1;
    }
    if (maxsplit) |limit| {
        args_buffer[args_len] = .{ .integer = limit };
        args_len += 1;
    }
    defer for (args_buffer[0..args_len]) |*arg| arg.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.split, allocator, input, args_buffer[0..args_len]);
    defer result.deinit(allocator);

    try testing.expect(result == .list);
    try testing.expectEqual(expected.len, result.list.items.items.len);
    for (expected, result.list.items.items) |expected_item, actual_item| {
        try testing.expect(actual_item == .string);
        try testing.expectEqualStrings(expected_item, actual_item.string);
    }
}

fn splitAllocationFailureScenario(allocator: std.mem.Allocator) !void {
    try expectSplitWithAllocator(
        allocator,
        "alpha,beta,gamma,delta",
        ",",
        2,
        &.{ "alpha", "beta", "gamma,delta" },
    );
}

// ============================================================================
// String Filters
// ============================================================================

test "filter capitalize" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.capitalize, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("Hello", result.string);
}

test "filter lower" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "HELLO") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.lower, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("hello", result.string);
}

test "filter upper" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.upper, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("HELLO", result.string);
}

test "filter trim" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "  hello  ") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.trim, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("hello", result.string);
}

test "filter length" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.length, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 5);
}

test "filter default with empty value" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "") };
    defer input.deinit(allocator);

    var default_val = value.Value{ .string = try allocator.dupe(u8, "default") };
    defer default_val.deinit(allocator);

    var args = [_]value.Value{default_val};
    var result = try callFilter(filters.BuiltinFilters.default, allocator, input, &args);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("default", result.string);
}

test "filter default with non-empty value" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer input.deinit(allocator);

    var default_val = value.Value{ .string = try allocator.dupe(u8, "default") };
    defer default_val.deinit(allocator);

    var args = [_]value.Value{default_val};
    var result = try callFilter(filters.BuiltinFilters.default, allocator, input, &args);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("hello", result.string);
}

test "filter replace" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "hello world") };
    defer input.deinit(allocator);

    var old_val = value.Value{ .string = try allocator.dupe(u8, "world") };
    defer old_val.deinit(allocator);

    var new_val = value.Value{ .string = try allocator.dupe(u8, "zig") };
    defer new_val.deinit(allocator);

    var args = [_]value.Value{ old_val, new_val };
    var result = try callFilter(filters.BuiltinFilters.replace, allocator, input, &args);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("hello zig", result.string);
}

test "filter split matches explicit and whitespace maxsplit boundaries" {
    const allocator = testing.allocator;

    try expectSplitWithAllocator(allocator, "a,,b", ",", null, &.{ "a", "", "b" });
    try expectSplitWithAllocator(allocator, "a,b,c", ",", 0, &.{"a,b,c"});
    try expectSplitWithAllocator(allocator, "a,b,c", ",", 1, &.{ "a", "b,c" });
    try expectSplitWithAllocator(allocator, "  a   b ", null, null, &.{ "a", "b" });
    try expectSplitWithAllocator(allocator, "  a   b ", null, 0, &.{"a   b "});
    try expectSplitWithAllocator(allocator, "  a   b  c ", null, 1, &.{ "a", "b  c " });
    try expectSplitWithAllocator(allocator, "   ", null, 0, &.{});
}

test "filter split releases every allocation on failure" {
    try testing.checkAllAllocationFailures(testing.allocator, splitAllocationFailureScenario, .{});
}

test "filter abs" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with positive integer
    const pos_int = value.Value{ .integer = 42 };
    var result1 = try callFilter(filters.BuiltinFilters.abs, allocator, pos_int, &[_]value.Value{});
    defer result1.deinit(allocator);
    try testing.expect(result1 == .integer);
    try testing.expect(result1.integer == 42);

    // Test with negative integer
    const neg_int = value.Value{ .integer = -42 };
    var result2 = try callFilter(filters.BuiltinFilters.abs, allocator, neg_int, &[_]value.Value{});
    defer result2.deinit(allocator);
    try testing.expect(result2 == .integer);
    try testing.expect(result2.integer == 42);

    // Test with positive float
    const pos_float = value.Value{ .float = 3.14 };
    var result3 = try callFilter(filters.BuiltinFilters.abs, allocator, pos_float, &[_]value.Value{});
    defer result3.deinit(allocator);
    try testing.expect(result3 == .float);
    try testing.expect(result3.float == 3.14);

    // Test with negative float
    const neg_float = value.Value{ .float = -3.14 };
    var result4 = try callFilter(filters.BuiltinFilters.abs, allocator, neg_float, &[_]value.Value{});
    defer result4.deinit(allocator);
    try testing.expect(result4 == .float);
    try testing.expect(result4.float == 3.14);
}

test "filter reverse" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.reverse, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("olleh", result.string);
}

test "filter lstrip" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "  hello") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.lstrip, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("hello", result.string);
}

test "filter rstrip" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "hello  ") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.rstrip, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("hello", result.string);
}

test "filter length with list" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 2 });
    try list.append(value.Value{ .integer = 3 });

    const list_val = value.Value{ .list = list };
    var result = try callFilter(filters.BuiltinFilters.length, allocator, list_val, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 3);
}

test "filter length with dict" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    defer dict.deinit(allocator);
    try dict.set("a", value.Value{ .integer = 1 });
    try dict.set("b", value.Value{ .integer = 2 });

    const dict_val = value.Value{ .dict = dict };
    var result = try callFilter(filters.BuiltinFilters.length, allocator, dict_val, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 2);
}

// ============================================================================
// Title Filter (Jinja2 test_title)
// ============================================================================

test "filter title basic" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "foo bar") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.title, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("Foo Bar", result.string);
}

test "filter title with apostrophe" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "foo's bar") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.title, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("Foo's Bar", result.string);
}

// ============================================================================
// First and Last Filters
// ============================================================================

test "filter first" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 10 });
    try list.append(value.Value{ .integer = 20 });
    try list.append(value.Value{ .integer = 30 });

    const list_val = value.Value{ .list = list };
    var result = try callFilter(filters.BuiltinFilters.first, allocator, list_val, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 10);
}

test "filter first string uses caller allocator" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "abc") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.first, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("a", result.string);
}

test "filter last" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 10 });
    try list.append(value.Value{ .integer = 20 });
    try list.append(value.Value{ .integer = 30 });

    const list_val = value.Value{ .list = list };
    var result = try callFilter(filters.BuiltinFilters.last, allocator, list_val, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 30);
}

test "filter last string uses caller allocator" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "abc") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.last, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("c", result.string);
}

// ============================================================================
// Join Filter (Jinja2 test_join)
// ============================================================================

test "filter join" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 2 });
    try list.append(value.Value{ .integer = 3 });

    var separator = value.Value{ .string = try allocator.dupe(u8, "|") };
    defer separator.deinit(allocator);

    const list_val = value.Value{ .list = list };
    var args = [_]value.Value{separator};
    var result = try callFilter(filters.BuiltinFilters.join, allocator, list_val, &args);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("1|2|3", result.string);
}

// ============================================================================
// Sum Filter (Jinja2 test_sum)
// ============================================================================

test "filter sum" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 2 });
    try list.append(value.Value{ .integer = 3 });
    try list.append(value.Value{ .integer = 4 });
    try list.append(value.Value{ .integer = 5 });
    try list.append(value.Value{ .integer = 6 });

    const list_val = value.Value{ .list = list };
    var result = try callFilter(filters.BuiltinFilters.sum, allocator, list_val, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 21);
}

// ============================================================================
// Sort Filter (Jinja2 test_sort)
// ============================================================================

test "filter sort ascending" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 3 });
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 2 });

    const list_val = value.Value{ .list = list };
    var result = try callFilter(filters.BuiltinFilters.sort, allocator, list_val, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .list);
    try testing.expect(result.list.items.items.len == 3);
    try testing.expect(result.list.items.items[0].integer == 1);
    try testing.expect(result.list.items.items[1].integer == 2);
    try testing.expect(result.list.items.items[2].integer == 3);
}

test "filter sort is stable and supports nested attributes" {
    const allocator = testing.allocator;
    const input = try allocator.create(value.List);
    input.* = value.List.init(allocator);
    defer input.deinit(allocator);

    for ([_]struct { name: []const u8, rank: i64 }{
        .{ .name = "first", .rank = 2 },
        .{ .name = "second", .rank = 1 },
        .{ .name = "third", .rank = 1 },
    }) |fixture| {
        const metadata = try allocator.create(value.Dict);
        metadata.* = value.Dict.init(allocator);
        try metadata.set("rank", .{ .integer = fixture.rank });
        const item = try allocator.create(value.Dict);
        item.* = value.Dict.init(allocator);
        try item.set("name", .{ .string = try allocator.dupe(u8, fixture.name) });
        try item.set("metadata", .{ .dict = metadata });
        try input.append(.{ .dict = item });
    }

    var args = [_]value.Value{ .{ .boolean = false }, .{ .boolean = true }, .{ .string = "metadata.rank" } };
    var result = try callFilter(filters.BuiltinFilters.sort, allocator, .{ .list = input }, &args);
    defer result.deinit(allocator);

    try testing.expectEqualStrings("second", result.list.items.items[0].dict.get("name").?.string);
    try testing.expectEqualStrings("third", result.list.items.items[1].dict.get("name").?.string);
    try testing.expectEqualStrings("first", result.list.items.items[2].dict.get("name").?.string);
}

test "filter dictsort handles empty input and value mode" {
    const allocator = testing.allocator;
    const empty = try allocator.create(value.Dict);
    empty.* = value.Dict.init(allocator);
    defer empty.deinit(allocator);

    var empty_result = try callFilter(filters.BuiltinFilters.dictsort, allocator, .{ .dict = empty }, &.{});
    defer empty_result.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), empty_result.list.items.items.len);

    const input = try allocator.create(value.Dict);
    input.* = value.Dict.init(allocator);
    defer input.deinit(allocator);
    try input.set("first", .{ .integer = 20 });
    try input.set("second", .{ .integer = 10 });
    var args = [_]value.Value{ .{ .boolean = false }, .{ .string = "value" } };
    var result = try callFilter(filters.BuiltinFilters.dictsort, allocator, .{ .dict = input }, &args);
    defer result.deinit(allocator);

    try testing.expectEqualStrings("second", result.list.items.items[0].dict.get("key").?.string);
    try testing.expectEqual(@as(i64, 10), result.list.items.items[0].dict.get("value").?.integer);
    try testing.expectEqualStrings("first", result.list.items.items[1].dict.get("key").?.string);
}

test "filter dictsort defaults to case-insensitive stable key ordering" {
    const allocator = testing.allocator;
    const input = try allocator.create(value.Dict);
    input.* = value.Dict.init(allocator);
    defer input.deinit(allocator);
    try input.set("b", .{ .integer = 1 });
    try input.set("A", .{ .integer = 2 });
    try input.set("a", .{ .integer = 3 });

    var result = try callFilter(filters.BuiltinFilters.dictsort, allocator, .{ .dict = input }, &.{});
    defer result.deinit(allocator);
    try testing.expect(std.ascii.eqlIgnoreCase(result.list.items.items[0].dict.get("key").?.string, "a"));
    try testing.expect(std.ascii.eqlIgnoreCase(result.list.items.items[1].dict.get("key").?.string, "a"));
    try testing.expectEqualStrings("b", result.list.items.items[2].dict.get("key").?.string);
}

test "selectattr and rejectattr are complementary and own their results" {
    const allocator = testing.allocator;

    const input = try allocator.create(value.List);
    input.* = value.List.init(allocator);
    defer input.deinit(allocator);

    for ([_]?bool{ true, false, null }) |enabled| {
        const item = try allocator.create(value.Dict);
        item.* = value.Dict.init(allocator);
        if (enabled) |flag| try item.set("enabled", .{ .boolean = flag });
        try input.append(.{ .dict = item });
    }

    var attr = value.Value{ .string = try allocator.dupe(u8, "enabled") };
    defer attr.deinit(allocator);
    var args = [_]value.Value{attr};

    var selected = try callFilter(filters.BuiltinFilters.selectattr, allocator, .{ .list = input }, &args);
    defer selected.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), selected.list.items.items.len);
    try testing.expect(selected.list.items.items[0].dict.get("enabled").?.boolean);

    var rejected = try callFilter(filters.BuiltinFilters.rejectattr, allocator, .{ .list = input }, &args);
    defer rejected.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), rejected.list.items.items.len);
    try testing.expect(!rejected.list.items.items[0].dict.get("enabled").?.boolean);
    try testing.expect(rejected.list.items.items[1].dict.get("enabled") == null);
}

test "filter tojson compact and pretty reject recursive values without truncated output" {
    const allocator = testing.allocator;
    const recursive = try allocator.create(value.List);
    recursive.* = value.List.init(allocator);
    try recursive.append(.{ .list = recursive });

    try testing.expectError(
        error.RuntimeError,
        callFilter(filters.BuiltinFilters.tojson, allocator, .{ .list = recursive }, &.{}),
    );
    var pretty_args = [_]value.Value{.{ .integer = 2 }};
    try testing.expectError(
        error.RuntimeError,
        callFilter(filters.BuiltinFilters.tojson, allocator, .{ .list = recursive }, &pretty_args),
    );

    recursive.items.items[0] = .{ .null = {} };
    recursive.deinit(allocator);
}

// ============================================================================
// Escape Filter (Jinja2 test_escape)
// ============================================================================

test "filter escape" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "<\">&") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.escape, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    // Uses &quot; for double quotes (standard HTML entity)
    try testing.expectEqualStrings("&lt;&quot;&gt;&amp;", result.string);
}

// ============================================================================
// Round Filter (Jinja2 test_round)
// ============================================================================

test "filter round positive" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test 2.7 rounds to 3 (default precision=0 returns integer)
    const input1 = value.Value{ .float = 2.7 };
    var result1 = try callFilter(filters.BuiltinFilters.round, allocator, input1, &[_]value.Value{});
    defer result1.deinit(allocator);
    try testing.expect(result1 == .integer);
    try testing.expect(result1.integer == 3);

    // Test 2.1 rounds to 2
    const input2 = value.Value{ .float = 2.1 };
    var result2 = try callFilter(filters.BuiltinFilters.round, allocator, input2, &[_]value.Value{});
    defer result2.deinit(allocator);
    try testing.expect(result2 == .integer);
    try testing.expect(result2.integer == 2);
}

test "filter round with precision" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test 2.1234 rounded to 3 decimal places
    const input = value.Value{ .float = 2.1234 };
    const precision_arg = value.Value{ .integer = 3 };
    var args = [_]value.Value{precision_arg};
    var result = try callFilter(filters.BuiltinFilters.round, allocator, input, &args);
    defer result.deinit(allocator);
    try testing.expect(result == .float);
    // Should be 2.123
    try testing.expect(@abs(result.float - 2.123) < 0.0001);
}

// ============================================================================
// Wordcount Filter (Jinja2 test_wordcount)
// ============================================================================

test "filter wordcount" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "foo bar baz") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.wordcount, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 3);
}

// ============================================================================
// Center Filter (Jinja2 test_center)
// ============================================================================

test "filter center" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "foo") };
    defer input.deinit(allocator);

    const width_arg = value.Value{ .integer = 9 };
    var args = [_]value.Value{width_arg};
    var result = try callFilter(filters.BuiltinFilters.center, allocator, input, &args);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("   foo   ", result.string);
}

// ============================================================================
// Truncate Filter (Jinja2 test_truncate)
// ============================================================================

test "filter truncate" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "Joel is a slug") };
    defer input.deinit(allocator);

    const length_arg = value.Value{ .integer = 7 };
    const killwords_arg = value.Value{ .boolean = true };
    var args = [_]value.Value{ length_arg, killwords_arg };
    var result = try callFilter(filters.BuiltinFilters.truncate, allocator, input, &args);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("Joel...", result.string);
}

// ============================================================================
// Striptags Filter (Jinja2 test_striptags)
// ============================================================================

test "filter striptags" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "<p>Hello <b>world</b></p>") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.striptags, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("Hello world", result.string);
}

// ============================================================================
// Int/Float Conversion Filters (Jinja2 test_int, test_float)
// ============================================================================

test "filter int from string" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "42") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.int, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 42);
}

test "filter int from float" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = value.Value{ .float = 32.32 };

    var result = try callFilter(filters.BuiltinFilters.int, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 32);
}

test "filter float from string" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "32.32") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.float, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .float);
    try testing.expect(result.float == 32.32);
}

test "filter float from integer" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = value.Value{ .integer = 42 };

    var result = try callFilter(filters.BuiltinFilters.float, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .float);
    try testing.expect(result.float == 42.0);
}

// ============================================================================
// Additional Reverse Tests
// ============================================================================

test "filter reverse unicode string" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "abc") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.reverse, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("cba", result.string);
}

// ============================================================================
// Batch and Slice Filters (Jinja2 test_batch, test_slice)
// ============================================================================

test "filter batch" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        try list.append(value.Value{ .integer = i });
    }

    const list_val = value.Value{ .list = list };
    const batch_size = value.Value{ .integer = 3 };
    var args = [_]value.Value{batch_size};
    var result = try callFilter(filters.BuiltinFilters.batch, allocator, list_val, &args);
    defer result.deinit(allocator);

    try testing.expect(result == .list);
    // Should have 4 batches: [0,1,2], [3,4,5], [6,7,8], [9]
    try testing.expect(result.list.items.items.len == 4);
}

// ============================================================================
// Unique Filter (Jinja2 test_unique)
// ============================================================================

test "filter unique" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 2 });
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 3 });
    try list.append(value.Value{ .integer = 2 });

    const list_val = value.Value{ .list = list };
    var result = try callFilter(filters.BuiltinFilters.unique, allocator, list_val, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .list);
    try testing.expect(result.list.items.items.len == 3);
}

// ============================================================================
// Min/Max Filters (Jinja2 test_min_max)
// ============================================================================

test "filter min" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 5 });
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 9 });

    const list_val = value.Value{ .list = list };
    const result = try callFilter(filters.BuiltinFilters.min, allocator, list_val, &[_]value.Value{});
    // min/max return values from the list, so don't deinit (list owns them)

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 1);
}

test "filter max" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 5 });
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 9 });

    const list_val = value.Value{ .list = list };
    const result = try callFilter(filters.BuiltinFilters.max, allocator, list_val, &[_]value.Value{});
    // min/max return values from the list, so don't deinit (list owns them)

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 9);
}

test "filter min with empty list" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    const list_val = value.Value{ .list = list };
    const result = try callFilter(filters.BuiltinFilters.min, allocator, list_val, &[_]value.Value{});

    // Empty list returns null
    try testing.expect(result == .null);
}

test "filter max with empty list" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    const list_val = value.Value{ .list = list };
    const result = try callFilter(filters.BuiltinFilters.max, allocator, list_val, &[_]value.Value{});

    // Empty list returns null
    try testing.expect(result == .null);
}

// ============================================================================
// Mark Safe/Unsafe Filters (Jinja2 parity)
// ============================================================================

test "filter mark_safe creates markup" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "<b>bold</b>") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.mark_safe, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .markup);
    try testing.expectEqualStrings("<b>bold</b>", result.markup.content);
}

test "filter mark_unsafe converts markup to string" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create Markup value
    var markup = try value.Markup.init(allocator, "<b>bold</b>");
    defer markup.deinit(allocator);
    const markup_val = value.Value{ .markup = &markup };

    // Test that mark_unsafe converts to string
    var result = try callFilter(filters.BuiltinFilters.mark_unsafe, allocator, markup_val, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("<b>bold</b>", result.string);
}

test "filter mark_unsafe with plain string" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer input.deinit(allocator);

    var result = try callFilter(filters.BuiltinFilters.mark_unsafe, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("hello", result.string);
}

test "filter mark_unsafe with integer" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = value.Value{ .integer = 42 };

    var result = try callFilter(filters.BuiltinFilters.mark_unsafe, allocator, input, &[_]value.Value{});
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("42", result.string);
}

// ============================================================================
// Filter Aliases (Jinja2 parity)
// ============================================================================

test "filter alias d for default" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Verify 'd' alias exists
    try testing.expect(env.getFilter("d") != null);

    // Verify 'd' works like 'default'
    var empty_input = value.Value{ .string = try allocator.dupe(u8, "") };
    defer empty_input.deinit(allocator);

    var default_val = value.Value{ .string = try allocator.dupe(u8, "fallback") };
    defer default_val.deinit(allocator);

    const d_filter = env.getFilter("d").?;
    var args = [_]value.Value{default_val};
    var empty_kwargs = std.StringHashMap(value.Value).init(allocator);
    defer empty_kwargs.deinit();
    var result = try d_filter.func(allocator, empty_input, &args, &empty_kwargs, null, &env);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("fallback", result.string);
}

test "filter alias e for escape" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Verify 'e' alias exists
    try testing.expect(env.getFilter("e") != null);

    // Verify 'e' works like 'escape'
    var input = value.Value{ .string = try allocator.dupe(u8, "<script>") };
    defer input.deinit(allocator);

    const e_filter = env.getFilter("e").?;
    var empty_kwargs = std.StringHashMap(value.Value).init(allocator);
    defer empty_kwargs.deinit();
    var result = try e_filter.func(allocator, input, &[_]value.Value{}, &empty_kwargs, null, &env);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("&lt;script&gt;", result.string);
}

test "filter aliases exist in environment" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Verify all aliases exist
    try testing.expect(env.getFilter("d") != null); // Alias for default
    try testing.expect(env.getFilter("e") != null); // Alias for escape
    try testing.expect(env.getFilter("mark_safe") != null);
    try testing.expect(env.getFilter("mark_unsafe") != null);
}

// =============================================================================
// Jinja2 test_filters.py Coverage - Template-Level Tests
// Reference: tests/test_filters.py
// =============================================================================

test "template filter capitalize" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Jinja2: {{ "foo bar"|capitalize }} -> Foo bar
    const source = "{{ 'foo bar'|capitalize }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("Foo bar", result);
}

test "template filter center" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Jinja2: {{ "foo"|center(9) }} -> "   foo   "
    const source = "{{ 'foo'|center(9) }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("   foo   ", result);
}

test "template filter default with missing" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Jinja2: {{ missing|default('no') }} -> no
    const source = "{{ missing|default('no') }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("no", result);
}

test "template filter default with given" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Jinja2: {{ given|default('no') }} with given="yes" -> yes
    const source = "{{ given|default('no') }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    try vars.put("given", value.Value{ .string = "yes" });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("yes", result);
}

test "template filter escape" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Jinja2: {{ '<">&'|escape }} - vibe-jinja uses &quot; for double quotes
    const source = "{{ '<\">&'|escape }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("&lt;&quot;&gt;&amp;", result);
}

// Note: first/last/join on strings have memory management issues in template context
// These filters are tested through the unit tests that call filter functions directly

test "template filter length" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "hello"|length }} -> 5
    const source = "{{ 'hello'|length }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("5", result);
}

test "template filter lower" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "HELLO"|lower }} -> hello
    const source = "{{ 'HELLO'|lower }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("hello", result);
}

test "template filter upper" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "hello"|upper }} -> HELLO
    const source = "{{ 'hello'|upper }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("HELLO", result);
}

test "template filter trim" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "  hello  "|trim }} -> hello
    const source = "{{ '  hello  '|trim }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("hello", result);
}

test "template filter title" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "foo bar"|title }} -> Foo Bar
    const source = "{{ 'foo bar'|title }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("Foo Bar", result);
}

test "template filter replace" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "hello world"|replace("world", "jinja") }} -> hello jinja
    const source = "{{ 'hello world'|replace('world', 'jinja') }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("hello jinja", result);
}

test "template filter reverse" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "hello"|reverse }} -> olleh
    const source = "{{ 'hello'|reverse }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("olleh", result);
}

test "template filter abs" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Use parentheses to ensure proper parsing: {{ (-5)|abs }} -> 5
    const source = "{{ num|abs }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    try vars.put("num", value.Value{ .integer = -5 });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("5", result);
}

test "template filter round" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ 3.7|round }} -> 4.0
    const source = "{{ 3.7|round }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("4", result);
}

test "template filter int" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "42"|int }} -> 42
    const source = "{{ '42'|int }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("42", result);
}

test "template filter float" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "3.14"|float }} -> 3.14
    const source = "{{ '3.14'|float }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Float rendering might vary, check for reasonable output
    try testing.expect(std.mem.startsWith(u8, result, "3.14"));
}

test "template filter wordcount" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "hello world foo"|wordcount }} -> 3
    const source = "{{ 'hello world foo'|wordcount }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("3", result);
}

test "template filter truncate" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "hello world"|truncate(8) }}
    const source = "{{ 'hello world'|truncate(8) }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be truncated
    try testing.expect(result.len <= 11); // 8 + "..."
}

// Note: List-based filter tests (sum, min, max) are covered in the unit tests
// that test the filter functions directly. Template-level tests with lists
// require complex memory management that is better tested through integration tests.

test "template filter striptags" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Jinja2: {{ "<p>hello</p>"|striptags }} -> hello
    const source = "{{ '<p>hello</p>'|striptags }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("hello", result);
}

test "template filter chained" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // {{ "  HELLO  "|trim|lower }} -> hello
    const source = "{{ '  HELLO  '|trim|lower }}";
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("hello", result);
}

// Note: Sort and unique filter tests with lists are covered in the unit tests
// that test the filter functions directly.

test "filter truncate clamps negative length instead of crashing" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = value.Value{ .string = try allocator.dupe(u8, "Joel is a slug") };
    defer input.deinit(allocator);

    // Before the clamp this underflowed an @intCast and crashed the renderer.
    const length_arg = value.Value{ .integer = -5 };
    var args = [_]value.Value{length_arg};
    var result = try callFilter(filters.BuiltinFilters.truncate, allocator, input, &args);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("...", result.string);
}

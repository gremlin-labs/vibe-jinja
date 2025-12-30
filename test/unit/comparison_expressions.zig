const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const value = vibe_jinja.value;

/// Helper to clean up vars map - frees all keys and values
fn cleanupVars(vars: *std.StringHashMap(value.Value), allocator: std.mem.Allocator) void {
    var iter = vars.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.deinit(allocator);
    }
    vars.deinit();
}

test "in operator with list" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 2 in [1, 2, 3] }}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("true", result);
}

test "not in operator with list" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 5 not in [1, 2, 3] }}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("true", result);
}

test "in operator with string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 'lo' in 'hello' }}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("true", result);
}

test "in operator with dict keys" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 'name' in user }}";
    
    // Create dict value
    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    // Note: Don't defer dict.deinit here - vars cleanup will handle it
    
    // Note: Dict.set duplicates keys internally, so pass string literals directly.
    // Values are NOT duplicated by Dict.set, so we must dupe string values.
    const name_val = try allocator.dupe(u8, "Alice");
    try dict.set("name", value.Value{ .string = name_val });
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer cleanupVars(&vars, allocator);
    const user_key = try allocator.dupe(u8, "user");
    try vars.put(user_key, value.Value{ .dict = dict });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("true", result);
}

test "comparison operators" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ (5 == 5) and (3 != 5) and (3 < 5) and (5 <= 5) and (10 > 2) and (10 >= 10) }}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("true", result);
}

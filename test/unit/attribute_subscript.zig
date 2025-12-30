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

test "dict attribute access" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ user.name }}";
    
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

    try testing.expectEqualStrings("Alice", result);
}

test "list subscript access" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ items[0] }}";
    
    // Create list value
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    // Note: Don't defer list.deinit here - vars cleanup will handle it
    
    const item1 = value.Value{ .string = try allocator.dupe(u8, "first") };
    const item2 = value.Value{ .string = try allocator.dupe(u8, "second") };
    try list.append(item1);
    try list.append(item2);
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer cleanupVars(&vars, allocator);
    const items_key = try allocator.dupe(u8, "items");
    try vars.put(items_key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("first", result);
}

test "dict subscript access" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ user['name'] }}";
    
    // Create dict value
    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    // Note: Don't defer dict.deinit here - vars cleanup will handle it
    
    // Note: Dict.set duplicates keys internally, so pass string literals directly.
    const name_val = try allocator.dupe(u8, "Bob");
    try dict.set("name", value.Value{ .string = name_val });
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer cleanupVars(&vars, allocator);
    const user_key = try allocator.dupe(u8, "user");
    try vars.put(user_key, value.Value{ .dict = dict });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("Bob", result);
}

test "string subscript access" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ text[0] }}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer cleanupVars(&vars, allocator);
    const text_key = try allocator.dupe(u8, "text");
    const text_val = try allocator.dupe(u8, "Hello");
    try vars.put(text_key, value.Value{ .string = text_val });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("H", result);
}

test "chained attribute and subscript access" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ user.items[0] }}";
    
    // Create nested structure: user.items[0]
    const items_list = try allocator.create(value.List);
    items_list.* = value.List.init(allocator);
    // Note: Don't defer deinit here - user_dict takes ownership via Dict.set
    
    const item1 = value.Value{ .string = try allocator.dupe(u8, "item1") };
    try items_list.append(item1);
    
    const user_dict = try allocator.create(value.Dict);
    user_dict.* = value.Dict.init(allocator);
    // Note: Don't defer user_dict.deinit here - vars cleanup will handle it
    
    // Note: Dict.set duplicates keys internally, so pass string literals directly.
    // The list value is NOT copied - user_dict takes ownership of items_list.
    try user_dict.set("items", value.Value{ .list = items_list });
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer cleanupVars(&vars, allocator);
    const user_key = try allocator.dupe(u8, "user");
    try vars.put(user_key, value.Value{ .dict = user_dict });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("item1", result);
}

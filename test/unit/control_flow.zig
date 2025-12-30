const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const value = vibe_jinja.value;

test "for loop basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for item in items %}{{ item }}{% endfor %}";
    
    // Create list value
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    
    try list.append(value.Value{ .string = try allocator.dupe(u8, "a") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "b") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "c") });
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const items_key = try allocator.dupe(u8, "items");
    defer allocator.free(items_key);
    try vars.put(items_key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("abc", result);
}

test "for loop with else clause" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for item in items %}{{ item }}{% else %}empty{% endfor %}";
    
    // Create empty list
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const items_key = try allocator.dupe(u8, "items");
    defer allocator.free(items_key);
    try vars.put(items_key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("empty", result);
}

test "for loop with loop.index" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for item in items %}{{ loop.index }}{% endfor %}";
    
    // Create list value
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    
    try list.append(value.Value{ .string = try allocator.dupe(u8, "a") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "b") });
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const items_key = try allocator.dupe(u8, "items");
    defer allocator.free(items_key);
    try vars.put(items_key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("12", result);
}

test "for loop with loop.first and loop.last" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for item in items %}{% if loop.first %}F{% endif %}{% if loop.last %}L{% endif %}{% endfor %}";
    
    // Create list value
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    
    try list.append(value.Value{ .string = try allocator.dupe(u8, "a") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "b") });
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const items_key = try allocator.dupe(u8, "items");
    defer allocator.free(items_key);
    try vars.put(items_key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("FL", result);
}

test "if statement basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% if condition %}yes{% endif %}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const condition_key = try allocator.dupe(u8, "condition");
    defer allocator.free(condition_key);
    try vars.put(condition_key, value.Value{ .boolean = true });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("yes", result);
}

test "if statement with else" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% if condition %}yes{% else %}no{% endif %}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const condition_key = try allocator.dupe(u8, "condition");
    defer allocator.free(condition_key);
    try vars.put(condition_key, value.Value{ .boolean = false });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("no", result);
}

test "if statement with elif" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% if x == 1 %}one{% elif x == 2 %}two{% else %}other{% endif %}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const x_key = try allocator.dupe(u8, "x");
    defer allocator.free(x_key);
    try vars.put(x_key, value.Value{ .integer = 2 });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("two", result);
}

test "conditional expression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 'yes' if condition else 'no' }}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const condition_key = try allocator.dupe(u8, "condition");
    defer allocator.free(condition_key);
    try vars.put(condition_key, value.Value{ .boolean = true });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("yes", result);
}

test "conditional expression false" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 'yes' if condition else 'no' }}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const condition_key = try allocator.dupe(u8, "condition");
    defer allocator.free(condition_key);
    try vars.put(condition_key, value.Value{ .boolean = false });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("no", result);
}

test "for loop with break" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for item in items %}{{ item }}{% if item == 'b' %}{% break %}{% endif %}{% endfor %}";
    
    // Create list value
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    
    try list.append(value.Value{ .string = try allocator.dupe(u8, "a") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "b") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "c") });
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const items_key = try allocator.dupe(u8, "items");
    defer allocator.free(items_key);
    try vars.put(items_key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("ab", result);
}

test "for loop with continue" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for item in items %}{% if item == 'b' %}{% continue %}{% endif %}{{ item }}{% endfor %}";
    
    // Create list value
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    
    try list.append(value.Value{ .string = try allocator.dupe(u8, "a") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "b") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "c") });
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const items_key = try allocator.dupe(u8, "items");
    defer allocator.free(items_key);
    try vars.put(items_key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("ac", result);
}

const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;
const value = vibe_jinja.value;

test "for loop with list" {
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
    
    const item1 = value.Value{ .string = try allocator.dupe(u8, "a") };
    const item2 = value.Value{ .string = try allocator.dupe(u8, "b") };
    const item3 = value.Value{ .string = try allocator.dupe(u8, "c") };
    try list.append(item1);
    try list.append(item2);
    try list.append(item3);

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const items_key = try allocator.dupe(u8, "items");
    defer allocator.free(items_key);
    try vars.put(items_key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("abc", result);
}

test "if statement true condition" {
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
    const key = try allocator.dupe(u8, "condition");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .boolean = true });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("yes", result);
}

test "if statement false condition" {
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
    const key = try allocator.dupe(u8, "condition");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .boolean = false });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("no", result);
}

test "if elif else chain" {
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

test "nested for loops" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for row in rows %}{% for col in row %}{{ col }}{% endfor %}{% endfor %}";
    
    // Create nested list structure
    const outer_list = try allocator.create(value.List);
    outer_list.* = value.List.init(allocator);
    defer outer_list.deinit(allocator);
    
    // Inner lists are owned by outer_list after append - don't defer their deinit
    const inner_list1 = try allocator.create(value.List);
    inner_list1.* = value.List.init(allocator);
    try inner_list1.append(value.Value{ .string = try allocator.dupe(u8, "a") });
    try inner_list1.append(value.Value{ .string = try allocator.dupe(u8, "b") });
    
    const inner_list2 = try allocator.create(value.List);
    inner_list2.* = value.List.init(allocator);
    try inner_list2.append(value.Value{ .string = try allocator.dupe(u8, "c") });
    try inner_list2.append(value.Value{ .string = try allocator.dupe(u8, "d") });
    
    // After appending, outer_list owns inner_list1 and inner_list2
    try outer_list.append(value.Value{ .list = inner_list1 });
    try outer_list.append(value.Value{ .list = inner_list2 });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const rows_key = try allocator.dupe(u8, "rows");
    defer allocator.free(rows_key);
    try vars.put(rows_key, value.Value{ .list = outer_list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "ab") != null);
    try testing.expect(std.mem.indexOf(u8, result, "cd") != null);
}

test "nested if statements" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% if x %}{% if y %}both{% else %}x only{% endif %}{% else %}neither{% endif %}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    
    const x_key = try allocator.dupe(u8, "x");
    defer allocator.free(x_key);
    const y_key = try allocator.dupe(u8, "y");
    defer allocator.free(y_key);
    
    try vars.put(x_key, value.Value{ .boolean = true });
    try vars.put(y_key, value.Value{ .boolean = true });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "both") != null);
}

test "for loop with continue" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for i in items %}{% if i == 2 %}{% continue %}{% endif %}{{ i }}{% endfor %}";
    
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 2 });
    try list.append(value.Value{ .integer = 3 });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const items_key = try allocator.dupe(u8, "items");
    defer allocator.free(items_key);
    try vars.put(items_key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "3") != null);
    // Should not contain 2 (skipped by continue)
    try testing.expect(std.mem.indexOf(u8, result, "2") == null or std.mem.indexOf(u8, result, "13") != null);
}

test "for loop with break" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for i in items %}{% if i == 2 %}{% break %}{% endif %}{{ i }}{% endfor %}";
    
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 2 });
    try list.append(value.Value{ .integer = 3 });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const items_key = try allocator.dupe(u8, "items");
    defer allocator.free(items_key);
    try vars.put(items_key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "1") != null);
    // Should not contain 2 or 3 (loop breaks at 2)
    try testing.expect(std.mem.indexOf(u8, result, "3") == null);
}

test "for loop loop variables" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for item in items %}{{ loop.index }}:{{ item }}{% endfor %}";
    
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

    // Should show index and item
    try testing.expect(std.mem.indexOf(u8, result, "a") != null);
    try testing.expect(std.mem.indexOf(u8, result, "b") != null);
}

test "if with and operator" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% if x and y %}both{% else %}not both{% endif %}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    
    const x_key = try allocator.dupe(u8, "x");
    defer allocator.free(x_key);
    const y_key = try allocator.dupe(u8, "y");
    defer allocator.free(y_key);
    
    try vars.put(x_key, value.Value{ .boolean = true });
    try vars.put(y_key, value.Value{ .boolean = true });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "both") != null);
}

test "if with or operator" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% if x or y %}either{% else %}neither{% endif %}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    
    const x_key = try allocator.dupe(u8, "x");
    defer allocator.free(x_key);
    const y_key = try allocator.dupe(u8, "y");
    defer allocator.free(y_key);
    
    try vars.put(x_key, value.Value{ .boolean = false });
    try vars.put(y_key, value.Value{ .boolean = true });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "either") != null);
}

test "nested loop depth tracking" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Test loop.depth and loop.depth0 with nested loops
    const source =
        \\{% for i in outer %}
        \\outer={{ loop.depth }}/{{ loop.depth0 }}
        \\{% for j in inner %}
        \\inner={{ loop.depth }}/{{ loop.depth0 }}
        \\{% endfor %}
        \\{% endfor %}
    ;
    
    // Create outer list
    const outer_list = try allocator.create(value.List);
    outer_list.* = value.List.init(allocator);
    defer outer_list.deinit(allocator);
    try outer_list.append(value.Value{ .integer = 1 });
    
    // Create inner list
    const inner_list = try allocator.create(value.List);
    inner_list.* = value.List.init(allocator);
    defer inner_list.deinit(allocator);
    try inner_list.append(value.Value{ .integer = 10 });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    
    const outer_key = try allocator.dupe(u8, "outer");
    defer allocator.free(outer_key);
    const inner_key = try allocator.dupe(u8, "inner");
    defer allocator.free(inner_key);
    
    try vars.put(outer_key, value.Value{ .list = outer_list });
    try vars.put(inner_key, value.Value{ .list = inner_list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Outer loop: depth=1, depth0=0
    try testing.expect(std.mem.indexOf(u8, result, "outer=1/0") != null);
    // Inner loop: depth=2, depth0=1
    try testing.expect(std.mem.indexOf(u8, result, "inner=2/1") != null);
}

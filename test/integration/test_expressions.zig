const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;

test "test expression is defined" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if value is defined %}yes{% else %}no{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    const value_key = try allocator.dupe(u8, "value");
    defer allocator.free(value_key);
    const value_val = context.Value{ .string = try allocator.dupe(u8, "test") };
    defer value_val.deinit(allocator);
    try vars.put(value_key, value_val);

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

test "test expression is undefined" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if value is undefined %}yes{% else %}no{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

test "test expression is even" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if num is even %}even{% else %}odd{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();
    
    const num_key = try allocator.dupe(u8, "num");
    defer allocator.free(num_key);
    try vars.put(num_key, context.Value{ .integer = 4 });

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "even") != null);
}

test "test expression is odd" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if num is odd %}odd{% else %}even{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();
    
    const num_key = try allocator.dupe(u8, "num");
    defer allocator.free(num_key);
    try vars.put(num_key, context.Value{ .integer = 3 });

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "odd") != null);
}

test "test expression is divisibleby" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if num is divisibleby(3) %}yes{% else %}no{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();
    
    const num_key = try allocator.dupe(u8, "num");
    defer allocator.free(num_key);
    try vars.put(num_key, context.Value{ .integer = 9 });

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

test "test expression is equalto" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if value is equalto(42) %}yes{% else %}no{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();
    
    const value_key = try allocator.dupe(u8, "value");
    defer allocator.free(value_key);
    try vars.put(value_key, context.Value{ .integer = 42 });

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

test "test expression is string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if value is string %}yes{% else %}no{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }
    
    const value_key = try allocator.dupe(u8, "value");
    defer allocator.free(value_key);
    const value_val = context.Value{ .string = try allocator.dupe(u8, "test") };
    defer value_val.deinit(allocator);
    try vars.put(value_key, value_val);

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

test "test expression is number" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if value is number %}yes{% else %}no{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();
    
    const value_key = try allocator.dupe(u8, "value");
    defer allocator.free(value_key);
    try vars.put(value_key, context.Value{ .integer = 42 });

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

test "test expression is empty" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if value is empty %}yes{% else %}no{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }
    
    const value_key = try allocator.dupe(u8, "value");
    defer allocator.free(value_key);
    const value_val = context.Value{ .string = try allocator.dupe(u8, "") };
    defer value_val.deinit(allocator);
    try vars.put(value_key, value_val);

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

test "test expression is in" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if item is in(items) %}yes{% else %}no{% endif %}";
    
    const list = try allocator.create(vibe_jinja.value.List);
    list.* = vibe_jinja.value.List.init(allocator);
    defer list.deinit(allocator);
    
    try list.append(vibe_jinja.value.Value{ .string = try allocator.dupe(u8, "a") });
    try list.append(vibe_jinja.value.Value{ .string = try allocator.dupe(u8, "b") });
    try list.append(vibe_jinja.value.Value{ .string = try allocator.dupe(u8, "c") });

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    const items_key = try allocator.dupe(u8, "items");
    defer allocator.free(items_key);
    try vars.put(items_key, context.Value{ .list = list });
    
    const item_key = try allocator.dupe(u8, "item");
    defer allocator.free(item_key);
    const item_val = context.Value{ .string = try allocator.dupe(u8, "b") };
    defer item_val.deinit(allocator);
    try vars.put(item_key, item_val);

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

test "test expression chain" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Test chaining: is defined and is number
    const source = "{% if value is defined and value is number %}yes{% else %}no{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();
    
    const value_key = try allocator.dupe(u8, "value");
    defer allocator.free(value_key);
    try vars.put(value_key, context.Value{ .integer = 42 });

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

test "test expression is filter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if 'upper' is filter %}yes{% else %}no{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should detect that 'upper' is a filter
    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

test "test expression is test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if 'defined' is test %}yes{% else %}no{% endif %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should detect that 'defined' is a test
    try testing.expect(std.mem.indexOf(u8, result, "yes") != null);
}

// ============================================================================
// Global Functions Integration Tests (range, dict, lipsum)
// ============================================================================

test "range global function in for loop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% for i in range(5) %}{{ i }}{% endfor %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should output: 01234
    try testing.expectEqualStrings("01234", result);
}

test "range global function with start and stop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% for i in range(2, 6) %}{{ i }}{% endfor %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should output: 2345
    try testing.expectEqualStrings("2345", result);
}

test "range global function with step" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% for i in range(0, 10, 2) %}{{ i }},{% endfor %}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should output: 0,2,4,6,8,
    try testing.expectEqualStrings("0,2,4,6,8,", result);
}

test "range global function with count filter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Test using range with filters (Jinja2 pattern: range(10 - users|count))
    const source = "{{ range(5)|length }}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should output: 5
    try testing.expectEqualStrings("5", result);
}

test "lipsum global function generates text" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ lipsum(1, false) }}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should contain lorem ipsum text
    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "lorem") != null);
}

const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;

test "set statement" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source =
        \\{% set x = 42 %}
        \\{{ x }}
    ;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "42") != null);
}

test "set block" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source =
        \\{% set x %}
        \\Hello World
        \\{% endset %}
        \\{{ x }}
    ;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Hello World") != null);
}

test "with statement" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source =
        \\{% with x = 10, y = 20 %}
        \\{{ x + y }}
        \\{% endwith %}
    ;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "30") != null);
}

test "with statement scoping" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source =
        \\{% set x = 5 %}
        \\{{ x }}
        \\{% with x = 10 %}
        \\{{ x }}
        \\{% endwith %}
        \\{{ x }}
    ;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should show 5, 10, 5 (with creates new scope)
    try testing.expect(std.mem.indexOf(u8, result, "5") != null);
    try testing.expect(std.mem.indexOf(u8, result, "10") != null);
}

// ============================================================================
// Namespace tests (for Jinja2 namespace() global function)
// ============================================================================

test "namespace creation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    // Test basic namespace creation
    const source = "{% set ns = namespace() %}{% if ns %}NS_EXISTS{% endif %}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "NS_EXISTS") != null);
}

test "namespace dict access" {
    // Test that a dict's attribute can be accessed with dot notation
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const value = vibe_jinja.value;
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    // Pass a dict directly to test attribute access
    const data_dict = try allocator.create(value.Dict);
    data_dict.* = value.Dict.init(allocator);
    try data_dict.set("x", value.Value{ .integer = 42 });

    const data_key = try allocator.dupe(u8, "data");
    try vars.put(data_key, value.Value{ .dict = data_dict });

    // Test attribute access on dict
    const source = "{{ data.x }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("42", result);
}

test "namespace attribute assignment" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    // Test namespace attribute assignment without initial kwargs
    // Create empty namespace, then set attribute
    const source =
        \\{% set ns = namespace() %}
        \\{% set ns.found = true %}
        \\{% if ns.found %}FOUND{% else %}NOT{% endif %}
    ;
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "FOUND") != null);
}

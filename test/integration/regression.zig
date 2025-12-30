const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const value = vibe_jinja.value;

// ============================================================================
// Corner Case Tests (Jinja2 TestCorner)
// ============================================================================

test "regression - assigned scoping in for loop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Loop variable should not override outer variable after loop
    const source =
        \\{% for item in [1, 2, 3, 4] %}[{{ item }}]{% endfor %}{{ item }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const item_key = try allocator.dupe(u8, "item");
    defer allocator.free(item_key);
    try vars.put(item_key, value.Value{ .integer = 42 });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("[1][2][3][4]42", result);
}

test "regression - set after for loop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% for item in [1, 2, 3, 4] %}[{{ item }}]{% endfor %}{% set item = 42 %}{{ item }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("[1][2][3][4]42", result);
}

// ============================================================================
// Bug Fix Tests (Jinja2 TestBug)
// ============================================================================

test "regression - partial conditional assignments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% if b %}{% set a = 42 %}{% endif %}{{ a }}";

    // Without b set - should use outer a
    {
        var vars = std.StringHashMap(value.Value).init(allocator);
        defer vars.deinit();
        const a_key = try allocator.dupe(u8, "a");
        defer allocator.free(a_key);
        try vars.put(a_key, value.Value{ .integer = 23 });

        const result = try rt.renderString(source, vars, "test");
        defer allocator.free(result);

        try testing.expectEqualStrings("23", result);
    }

    // With b = true - should use inner set a
    {
        var vars = std.StringHashMap(value.Value).init(allocator);
        defer vars.deinit();
        const b_key = try allocator.dupe(u8, "b");
        defer allocator.free(b_key);
        try vars.put(b_key, value.Value{ .boolean = true });

        const result = try rt.renderString(source, vars, "test");
        defer allocator.free(result);

        try testing.expectEqualStrings("42", result);
    }
}

test "regression - old macro loop scoping bug" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for i in [1, 2] %}{{ i }}{% endfor %}{% macro i() %}3{% endmacro %}{{ i() }}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("123", result);
}

test "regression - else loop bug" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% for x in y %}{{ loop.index0 }}{% else %}{% for i in range(3) %}{{ i }}{% endfor %}{% endfor %}
    ;

    // Empty list should trigger else clause
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const empty_list = try allocator.create(value.List);
    empty_list.* = value.List.init(allocator);
    // Don't defer deinit - ownership transfers to Value
    try vars.put("y", value.Value{ .list = empty_list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should render the else block
    try testing.expect(std.mem.indexOf(u8, result, "012") != null);
}

test "regression - empty if" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% if foo %}{% else %}42{% endif %}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const foo_key = try allocator.dupe(u8, "foo");
    defer allocator.free(foo_key);
    try vars.put(foo_key, value.Value{ .boolean = false });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("42", result);
}

test "regression - variable reuse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for x in x.y %}{{ x }}{% endfor %}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    // Create x.y = [0, 1, 2]
    // Note: ownership transfers to vars, so no separate deinit on inner_dict
    const inner_dict = try allocator.create(value.Dict);
    inner_dict.* = value.Dict.init(allocator);

    const y_list = try allocator.create(value.List);
    y_list.* = value.List.init(allocator);
    try y_list.append(value.Value{ .integer = 0 });
    try y_list.append(value.Value{ .integer = 1 });
    try y_list.append(value.Value{ .integer = 2 });

    try inner_dict.set("y", value.Value{ .list = y_list });
    try vars.put("x", value.Value{ .dict = inner_dict });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("012", result);
}

// ============================================================================
// Whitespace Handling
// ============================================================================

test "regression - whitespace control" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{%- for i in [1, 2, 3] -%}{{ i }}{%- endfor -%}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // No extra whitespace should be in output
    try testing.expectEqualStrings("123", result);
}

test "regression - preserve internal whitespace" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 'hello   world' }}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Internal whitespace in strings should be preserved
    try testing.expectEqualStrings("hello   world", result);
}

// ============================================================================
// Filter Chaining
// ============================================================================

test "regression - filter chaining" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 'HELLO'|lower|upper }}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("HELLO", result);
}

// ============================================================================
// Nested Loop Scoping
// ============================================================================

test "regression - nested loop scoping" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% for outer in [1, 2] %}{% for inner in [3, 4] %}{{ outer }}{{ inner }}{% endfor %}{% endfor %}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("13142324", result);
}

// ============================================================================
// Conditional Expression Edge Cases
// ============================================================================

test "regression - conditional in expression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 'yes' if true else 'no' }}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("yes", result);
}

test "regression - conditional with undefined" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 'yes' if missing is defined else 'no' }}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("no", result);
}

// ============================================================================
// Escape Sequence Handling
// ============================================================================

test "regression - string escape sequences" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 'hello\\nworld' }}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should render with actual newline
    try testing.expect(std.mem.indexOf(u8, result, "\n") != null);
}

// ============================================================================
// Arithmetic Edge Cases
// ============================================================================

test "regression - integer division" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 7 // 2 }}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("3", result);
}

test "regression - modulo operator" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 7 % 3 }}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("1", result);
}

test "regression - power operator" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ 2 ** 8 }}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("256", result);
}

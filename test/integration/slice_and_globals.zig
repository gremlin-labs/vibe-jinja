//! Integration tests for slice syntax and new global functions
//!
//! Tests for critical missing features documented in vibe-jinja-missing-features-audit.md:
//! - Array/List Slice Syntax [start:end:step]
//! - raise_exception() global function
//! - loop.cycle() method
//! - loop.changed() method
//! - cycler(), joiner(), namespace() globals

const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const value = vibe_jinja.value;

// ============================================================================
// SLICE SYNTAX TESTS
// ============================================================================

test "slice: messages[1:] - skip first element" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for m in messages[1:] %}{{ m }}{% endfor %}";

    // Create messages list
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    try list.append(value.Value{ .string = try allocator.dupe(u8, "first") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "second") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "third") });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "messages");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("secondthird", result);
}

test "slice: messages[:-1] - skip last element" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for m in messages[:-1] %}{{ m }}{% endfor %}";

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    try list.append(value.Value{ .string = try allocator.dupe(u8, "first") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "second") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "third") });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "messages");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("firstsecond", result);
}

test "slice: messages[1:3] - range slice" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for m in messages[1:3] %}{{ m }}{% endfor %}";

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    try list.append(value.Value{ .string = try allocator.dupe(u8, "a") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "b") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "c") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "d") });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "messages");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("bc", result);
}

test "slice: messages[::2] - step slice (every other)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for m in messages[::2] %}{{ m }}{% endfor %}";

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    try list.append(value.Value{ .string = try allocator.dupe(u8, "a") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "b") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "c") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "d") });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "messages");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("ac", result);
}

test "slice: string slicing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ text[1:4] }}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }
    const key = try allocator.dupe(u8, "text");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .string = try allocator.dupe(u8, "Hello World") });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("ell", result);
}

// ============================================================================
// LOOP.CYCLE() TESTS
// ============================================================================

test "loop.cycle: alternating odd/even" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% for i in items %}{{ loop.cycle('odd', 'even') }}{% endfor %}
    ;

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 2 });
    try list.append(value.Value{ .integer = 3 });
    try list.append(value.Value{ .integer = 4 });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "items");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("oddevenoddeven", result);
}

test "loop.cycle: three values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% for i in items %}{{ loop.cycle('a', 'b', 'c') }}{% endfor %}
    ;

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < 7) : (i += 1) {
        try list.append(value.Value{ .integer = 0 });
    }

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "items");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("abcabca", result);
}

// ============================================================================
// LOOP.CHANGED() TESTS
// ============================================================================

test "loop.changed: detect category changes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% for item in items %}{% if loop.changed(item) %}[{{ item }}]{% endif %}{% endfor %}
    ;

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    // Same values should not trigger changed
    try list.append(value.Value{ .string = try allocator.dupe(u8, "A") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "A") }); // same - no output
    try list.append(value.Value{ .string = try allocator.dupe(u8, "B") }); // different
    try list.append(value.Value{ .string = try allocator.dupe(u8, "B") }); // same - no output
    try list.append(value.Value{ .string = try allocator.dupe(u8, "A") }); // different

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "items");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("[A][B][A]", result);
}

// ============================================================================
// GLOBAL FUNCTIONS TESTS
// ============================================================================

test "cycler global: creates cycler object" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% set row = cycler('odd', 'even') %}{{ row._type }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("cycler", result);
}

test "joiner global: creates joiner object" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% set sep = joiner(', ') %}{{ sep._type }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("joiner", result);
}

test "namespace global: creates namespace object" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% set ns = namespace() %}{{ ns._type }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("namespace", result);
}

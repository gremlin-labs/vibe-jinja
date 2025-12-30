const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;
const loaders = vibe_jinja.loaders;

test "import basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const utils_source =
        \\{% macro greet(name) %}
        \\Hello, {{ name }}!
        \\{% endmacro %}
    ;

    const main_source =
        \\{% import 'utils.jinja' as utils %}
        \\{{ utils.greet("World") }}
    ;

    var mapping = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = mapping.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        mapping.deinit();
    }

    try mapping.put(try allocator.dupe(u8, "utils.jinja"), try allocator.dupe(u8, utils_source));
    try mapping.put(try allocator.dupe(u8, "main.jinja"), try allocator.dupe(u8, main_source));

    var loader = try loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = &loader.loader;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(main_source, vars, "main.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Hello, World!") != null);
}

test "from import" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const utils_source =
        \\{% macro greet(name) %}
        \\Hello, {{ name }}!
        \\{% endmacro %}
        \\{% macro farewell(name) %}
        \\Goodbye, {{ name }}!
        \\{% endmacro %}
    ;

    const main_source =
        \\{% from 'utils.jinja' import greet %}
        \\{{ greet("World") }}
    ;

    var mapping = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = mapping.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        mapping.deinit();
    }

    try mapping.put(try allocator.dupe(u8, "utils.jinja"), try allocator.dupe(u8, utils_source));
    try mapping.put(try allocator.dupe(u8, "main.jinja"), try allocator.dupe(u8, main_source));

    var loader = try loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = &loader.loader;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(main_source, vars, "main.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Hello, World!") != null);
}

test "from import multiple" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const utils_source =
        \\{% macro greet(name) %}
        \\Hello, {{ name }}!
        \\{% endmacro %}
        \\{% macro farewell(name) %}
        \\Goodbye, {{ name }}!
        \\{% endmacro %}
    ;

    const main_source =
        \\{% from 'utils.jinja' import greet, farewell %}
        \\{{ greet("World") }}
        \\{{ farewell("World") }}
    ;

    var mapping = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = mapping.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        mapping.deinit();
    }

    try mapping.put(try allocator.dupe(u8, "utils.jinja"), try allocator.dupe(u8, utils_source));
    try mapping.put(try allocator.dupe(u8, "main.jinja"), try allocator.dupe(u8, main_source));

    var loader = try loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = &loader.loader;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(main_source, vars, "main.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Hello, World!") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Goodbye, World!") != null);
}

test "import namespace access" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const utils_source =
        \\{% macro func1() %}Function 1{% endmacro %}
        \\{% macro func2() %}Function 2{% endmacro %}
    ;

    const main_source =
        \\{% import 'utils.jinja' as utils %}
        \\{{ utils.func1() }}
        \\{{ utils.func2() }}
    ;

    var mapping = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = mapping.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        mapping.deinit();
    }

    try mapping.put(try allocator.dupe(u8, "utils.jinja"), try allocator.dupe(u8, utils_source));
    try mapping.put(try allocator.dupe(u8, "main.jinja"), try allocator.dupe(u8, main_source));

    var loader = try loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = &loader.loader;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(main_source, vars, "main.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Function 1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Function 2") != null);
}

test "import with context" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const utils_source =
        \\{% macro greet() %}
        \\Hello, {{ name }}!
        \\{% endmacro %}
    ;

    const main_source =
        \\{% import 'utils.jinja' as utils with context %}
        \\{{ utils.greet() }}
    ;

    var mapping = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = mapping.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        mapping.deinit();
    }

    try mapping.put(try allocator.dupe(u8, "utils.jinja"), try allocator.dupe(u8, utils_source));
    try mapping.put(try allocator.dupe(u8, "main.jinja"), try allocator.dupe(u8, main_source));

    var loader = try loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = &loader.loader;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    const name_key = try allocator.dupe(u8, "name");
    defer allocator.free(name_key);
    const name_val = context.Value{ .string = try allocator.dupe(u8, "World") };
    defer name_val.deinit(allocator);
    try vars.put(name_key, name_val);

    const result = try rt.renderString(main_source, vars, "main.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Hello, World!") != null);
}

test "import without context" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const utils_source =
        \\{% macro greet() %}
        \\Hello, {{ name | default("Unknown") }}!
        \\{% endmacro %}
    ;

    const main_source =
        \\{% import 'utils.jinja' as utils %}
        \\{{ utils.greet() }}
    ;

    var mapping = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = mapping.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        mapping.deinit();
    }

    try mapping.put(try allocator.dupe(u8, "utils.jinja"), try allocator.dupe(u8, utils_source));
    try mapping.put(try allocator.dupe(u8, "main.jinja"), try allocator.dupe(u8, main_source));

    var loader = try loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = &loader.loader;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(main_source, vars, "main.jinja");
    defer allocator.free(result);

    // Without context, name should be undefined/default
    try testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
}

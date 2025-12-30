const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;
const loaders = vibe_jinja.loaders;

test "template inheritance basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Create parent template
    const parent_source =
        \\<html>
        \\<head><title>{% block title %}Default Title{% endblock %}</title></head>
        \\<body>
        \\  {% block content %}Default content{% endblock %}
        \\</body>
        \\</html>
    ;

    // Create child template
    const child_source =
        \\{% extends "parent.jinja" %}
        \\{% block title %}Child Title{% endblock %}
        \\{% block content %}Child content{% endblock %}
    ;

    // Use DictLoader for templates
    var mapping = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = mapping.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        mapping.deinit();
    }

    try mapping.put(try allocator.dupe(u8, "parent.jinja"), try allocator.dupe(u8, parent_source));
    try mapping.put(try allocator.dupe(u8, "child.jinja"), try allocator.dupe(u8, child_source));

    var loader = try loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = &loader.loader;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(child_source, vars, "child.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Child Title") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Child content") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Default Title") == null);
}

test "template inheritance with super" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const parent_source =
        \\<div class="header">
        \\  {% block header %}Default Header{% endblock %}
        \\</div>
    ;

    const child_source =
        \\{% extends "parent.jinja" %}
        \\{% block header %}Custom Header - {{ super() }}{% endblock %}
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

    try mapping.put(try allocator.dupe(u8, "parent.jinja"), try allocator.dupe(u8, parent_source));
    try mapping.put(try allocator.dupe(u8, "child.jinja"), try allocator.dupe(u8, child_source));

    var loader = try loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = &loader.loader;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(child_source, vars, "child.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Custom Header") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Default Header") != null);
}

test "template inheritance multiple levels" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const grandparent_source =
        \\<html>
        \\  {% block content %}Grandparent{% endblock %}
        \\</html>
    ;

    const parent_source =
        \\{% extends "grandparent.jinja" %}
        \\{% block content %}Parent - {{ super() }}{% endblock %}
    ;

    const child_source =
        \\{% extends "parent.jinja" %}
        \\{% block content %}Child - {{ super() }}{% endblock %}
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

    try mapping.put(try allocator.dupe(u8, "grandparent.jinja"), try allocator.dupe(u8, grandparent_source));
    try mapping.put(try allocator.dupe(u8, "parent.jinja"), try allocator.dupe(u8, parent_source));
    try mapping.put(try allocator.dupe(u8, "child.jinja"), try allocator.dupe(u8, child_source));

    var loader = try loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = &loader.loader;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(child_source, vars, "child.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Child") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Parent") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Grandparent") != null);
}

test "template inheritance block scoping" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const parent_source =
        \\{% block outer %}
        \\  {% block inner %}Inner default{% endblock %}
        \\{% endblock %}
    ;

    const child_source =
        \\{% extends "parent.jinja" %}
        \\{% block inner %}Inner override{% endblock %}
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

    try mapping.put(try allocator.dupe(u8, "parent.jinja"), try allocator.dupe(u8, parent_source));
    try mapping.put(try allocator.dupe(u8, "child.jinja"), try allocator.dupe(u8, child_source));

    var loader = try loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = &loader.loader;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(child_source, vars, "child.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Inner override") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Inner default") == null);
}

test "template inheritance multiple blocks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const parent_source =
        \\<html>
        \\  <head>{% block head %}{% endblock %}</head>
        \\  <body>
        \\    {% block body %}Body default{% endblock %}
        \\  </body>
        \\</html>
    ;

    const child_source =
        \\{% extends "parent.jinja" %}
        \\{% block head %}<title>Child Title</title>{% endblock %}
        \\{% block body %}Child body{% endblock %}
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

    try mapping.put(try allocator.dupe(u8, "parent.jinja"), try allocator.dupe(u8, parent_source));
    try mapping.put(try allocator.dupe(u8, "child.jinja"), try allocator.dupe(u8, child_source));

    var loader = try loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = &loader.loader;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(child_source, vars, "child.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Child Title") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Child body") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Body default") == null);
}

test "template inheritance required block overridden" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Parent template with required block (only whitespace inside)
    const parent_source =
        \\<html>
        \\  {% block content required %}
        \\  {% endblock %}
        \\</html>
    ;

    // Child template overrides the required block
    const child_source =
        \\{% extends "parent.jinja" %}
        \\{% block content %}Child content{% endblock %}
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

    try mapping.put(try allocator.dupe(u8, "parent.jinja"), try allocator.dupe(u8, parent_source));
    try mapping.put(try allocator.dupe(u8, "child.jinja"), try allocator.dupe(u8, child_source));

    var loader = loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = loader.getLoader();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(child_source, vars, "child.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Child content") != null);
}

test "template inheritance scoped block" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Parent template with scoped block
    const parent_source =
        \\{% for item in items %}
        \\  {% block item scoped %}{{ item }}{% endblock %}
        \\{% endfor %}
    ;

    // Child template overrides the scoped block
    const child_source =
        \\{% extends "parent.jinja" %}
        \\{% block item %}[{{ item }}]{% endblock %}
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

    try mapping.put(try allocator.dupe(u8, "parent.jinja"), try allocator.dupe(u8, parent_source));
    try mapping.put(try allocator.dupe(u8, "child.jinja"), try allocator.dupe(u8, child_source));

    var loader = loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();
    env.loader = loader.getLoader();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Create list value for items
    const items_list = try allocator.create(context.List);
    items_list.* = context.List.init(allocator);
    try items_list.append(context.Value{ .integer = 1 });
    try items_list.append(context.Value{ .integer = 2 });
    try items_list.append(context.Value{ .integer = 3 });

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }
    try vars.put("items", context.Value{ .list = items_list });

    const result = try rt.renderString(child_source, vars, "child.jinja");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "[1]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[2]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[3]") != null);
}

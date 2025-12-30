const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;

test "raw block" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source =
        \\{% raw %}
        \\{{ variable }}
        \\{% for item in items %}
        \\{% endfor %}
        \\{% endraw %}
    ;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Raw content should be output as-is without processing
    try testing.expect(std.mem.indexOf(u8, result, "{{ variable }}") != null);
    try testing.expect(std.mem.indexOf(u8, result, "{% for item in items %}") != null);
    try testing.expect(std.mem.indexOf(u8, result, "{% endfor %}") != null);
}

test "raw block with variables outside" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source =
        \\Before: {{ name }}
        \\{% raw %}
        \\{{ name }}
        \\{% endraw %}
        \\After: {{ name }}
    ;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();
    try vars.put("name", context.Value{ .string = try allocator.dupe(u8, "World") });
    defer allocator.free(vars.get("name").?.string);

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Variables outside raw block should be processed
    try testing.expect(std.mem.indexOf(u8, result, "Before: World") != null);
    try testing.expect(std.mem.indexOf(u8, result, "After: World") != null);
    // Variable inside raw block should be literal
    try testing.expect(std.mem.indexOf(u8, result, "{{ name }}") != null);
}

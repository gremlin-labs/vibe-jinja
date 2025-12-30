const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;

test "filter block" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source =
        \\{% filter upper %}
        \\hello world
        \\{% endfilter %}
    ;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "HELLO WORLD") != null);
}

test "filter block with trim" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source =
        \\{% filter trim %}
        \\  hello world  
        \\{% endfilter %}
    ;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "hello world") != null);
}

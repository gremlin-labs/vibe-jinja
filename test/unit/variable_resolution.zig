const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const value = vibe_jinja.value;

test "variable resolution from context" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ name }}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        // Free keys and values since Context.init makes its own copy
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }
    const name_key = try allocator.dupe(u8, "name");
    const name_val = try allocator.dupe(u8, "John");
    try vars.put(name_key, value.Value{ .string = name_val });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("John", result);
}

test "undefined variable lenient behavior" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();
    env.undefined_behavior = value.UndefinedBehavior.lenient;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ undefined_var }}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("", result);
}

test "undefined variable debug behavior" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();
    env.undefined_behavior = value.UndefinedBehavior.debug;

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ undefined_var }}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "undefined variable") != null);
}

test "variable resolution from environment globals" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();
    
    const global_key = try allocator.dupe(u8, "global_var");
    defer allocator.free(global_key);
    const global_val = try allocator.dupe(u8, "global_value");
    try env.addGlobal(global_key, value.Value{ .string = global_val });

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ global_var }}";
    
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("global_value", result);
}

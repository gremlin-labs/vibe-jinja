const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;

test "filter chain basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ text | upper | reverse }}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    const text_key = try allocator.dupe(u8, "text");
    defer allocator.free(text_key);
    const text_val = context.Value{ .string = try allocator.dupe(u8, "hello") };
    defer text_val.deinit(allocator);
    try vars.put(text_key, text_val);

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be "OLLEH" (upper then reverse)
    try testing.expect(std.mem.indexOf(u8, result, "OLLEH") != null);
}

test "filter chain with arguments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ text | replace('world', 'zig') | upper }}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    const text_key = try allocator.dupe(u8, "text");
    defer allocator.free(text_key);
    const text_val = context.Value{ .string = try allocator.dupe(u8, "hello world") };
    defer text_val.deinit(allocator);
    try vars.put(text_key, text_val);

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be "HELLO ZIG" (replace then upper)
    try testing.expect(std.mem.indexOf(u8, result, "HELLO ZIG") != null);
}

test "filter chain multiple filters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ text | trim | upper | reverse }}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    const text_key = try allocator.dupe(u8, "text");
    defer allocator.free(text_key);
    const text_val = context.Value{ .string = try allocator.dupe(u8, "  hello  ") };
    defer text_val.deinit(allocator);
    try vars.put(text_key, text_val);

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be "OLLEH" (trim, upper, reverse)
    try testing.expect(std.mem.indexOf(u8, result, "OLLEH") != null);
}

test "filter with default argument" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ value | default('N/A') | upper }}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    // Empty value should use default
    const value_key = try allocator.dupe(u8, "value");
    defer allocator.free(value_key);
    const value_val = context.Value{ .string = try allocator.dupe(u8, "") };
    defer value_val.deinit(allocator);
    try vars.put(value_key, value_val);

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be "N/A" (default then upper)
    try testing.expect(std.mem.indexOf(u8, result, "N/A") != null);
}

test "filter error handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Filter that might error (e.g., division by zero)
    const source = "{{ value | default('safe') }}";
    
    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    // Use undefined value
    const value_key = try allocator.dupe(u8, "value");
    defer allocator.free(value_key);
    const value_val = context.Value{ .null = {} };
    try vars.put(value_key, value_val);

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should use default value
    try testing.expect(std.mem.indexOf(u8, result, "safe") != null);
}

test "filter with list operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ items | length | string }}";
    
    const list = try allocator.create(vibe_jinja.value.List);
    list.* = vibe_jinja.value.List.init(allocator);
    defer list.deinit(allocator);
    
    try list.append(vibe_jinja.value.Value{ .integer = 1 });
    try list.append(vibe_jinja.value.Value{ .integer = 2 });
    try list.append(vibe_jinja.value.Value{ .integer = 3 });

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

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should show length as string
    try testing.expect(std.mem.indexOf(u8, result, "3") != null);
}

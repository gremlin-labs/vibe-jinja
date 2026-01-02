const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const value = vibe_jinja.value;

// ============================================================================
// HuggingFace Chat Template Compatibility Tests
// Tests for Llama 3.2 and other HuggingFace model chat templates
// ============================================================================

// Tests 1-6 already verified passing

test "HF 7: in operator for dict key check" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const msg = try allocator.create(value.Dict);
    msg.* = value.Dict.init(allocator);
    try msg.set("role", value.Value{ .string = try allocator.dupe(u8, "assistant") });

    const tool_calls = try allocator.create(value.List);
    tool_calls.* = value.List.init(allocator);
    try msg.set("tool_calls", value.Value{ .list = tool_calls });

    const key = try allocator.dupe(u8, "message");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .dict = msg });

    const source = "{% if 'tool_calls' in message %}HAS{% else %}NO{% endif %}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("HAS", result);
}

test "HF 8: tojson filter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const data = try allocator.create(value.Dict);
    data.* = value.Dict.init(allocator);
    try data.set("name", value.Value{ .string = try allocator.dupe(u8, "test") });
    try data.set("value", value.Value{ .integer = 42 });

    const key = try allocator.dupe(u8, "data");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .dict = data });

    const source = "{{ data | tojson }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "42") != null);
}

test "HF 9: strftime_now direct call" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Simple strftime_now call
    const source = "{{ strftime_now('%Y') }}";

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should output current year
    try testing.expect(std.mem.indexOf(u8, result, "202") != null);
}

test "HF 10: mapping test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const data = try allocator.create(value.Dict);
    data.* = value.Dict.init(allocator);
    try data.set("key", value.Value{ .string = try allocator.dupe(u8, "value") });

    const key = try allocator.dupe(u8, "data");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .dict = data });

    const source = "{% if data is mapping %}MAP{% endif %}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("MAP", result);
}

test "HF 11: complex nested condition" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    const msg = try allocator.create(value.Dict);
    msg.* = value.Dict.init(allocator);
    try msg.set("role", value.Value{ .string = try allocator.dupe(u8, "user") });
    try msg.set("content", value.Value{ .string = try allocator.dupe(u8, "Hello") });

    const key = try allocator.dupe(u8, "message");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .dict = msg });

    // Test complex condition from Llama template
    const source = "{% if not (message.role == 'ipython' or message.role == 'tool' or 'tool_calls' in message) %}NORMAL{% else %}SPECIAL{% endif %}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("NORMAL", result);
}

// ----------------------------------------------------------------------------
// Llama 3.2 Style Template Tests
// ----------------------------------------------------------------------------

test "Llama: bos_token rendering" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    // Just test bos_token rendering
    const bos_key = try allocator.dupe(u8, "bos_token");
    defer allocator.free(bos_key);
    try vars.put(bos_key, value.Value{ .string = try allocator.dupe(u8, "<|begin|>") });

    const source = "{{ bos_token }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("<|begin|>", result);
}

test "Llama: basic chat format with system extraction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }

    // Create messages list
    const messages_list = try allocator.create(value.List);
    messages_list.* = value.List.init(allocator);

    const system_msg = try allocator.create(value.Dict);
    system_msg.* = value.Dict.init(allocator);
    try system_msg.set("role", value.Value{ .string = try allocator.dupe(u8, "system") });
    try system_msg.set("content", value.Value{ .string = try allocator.dupe(u8, "You are helpful.") });
    try messages_list.append(value.Value{ .dict = system_msg });

    const user_msg = try allocator.create(value.Dict);
    user_msg.* = value.Dict.init(allocator);
    try user_msg.set("role", value.Value{ .string = try allocator.dupe(u8, "user") });
    try user_msg.set("content", value.Value{ .string = try allocator.dupe(u8, "Hello!") });
    try messages_list.append(value.Value{ .dict = user_msg });

    const messages_key = try allocator.dupe(u8, "messages");
    defer allocator.free(messages_key);
    try vars.put(messages_key, value.Value{ .list = messages_list });

    const bos_key = try allocator.dupe(u8, "bos_token");
    defer allocator.free(bos_key);
    try vars.put(bos_key, value.Value{ .string = try allocator.dupe(u8, "<BOS>") });

    const add_gen_key = try allocator.dupe(u8, "add_generation_prompt");
    defer allocator.free(add_gen_key);
    try vars.put(add_gen_key, value.Value{ .boolean = true });

    // Simplified Llama-style template without whitespace control
    const source =
        \\{{ bos_token }}
        \\{% if messages[0]['role'] == 'system' %}
        \\{% set system_message = messages[0]['content']|trim %}
        \\{% set messages = messages[1:] %}
        \\[SYS]{{ system_message }}[/SYS]
        \\{% endif %}
        \\{% for message in messages %}
        \\[{{ message['role']|upper }}]{{ message['content']|trim }}[/{{ message['role']|upper }}]
        \\{% endfor %}
        \\{% if add_generation_prompt %}
        \\[ASSISTANT]
        \\{% endif %}
    ;

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Verify structure
    try testing.expect(std.mem.indexOf(u8, result, "<BOS>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[SYS]You are helpful.[/SYS]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[USER]Hello![/USER]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[ASSISTANT]") != null);
}

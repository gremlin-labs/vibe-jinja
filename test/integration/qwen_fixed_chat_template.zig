const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");

const qwen_fixed = @embedFile("templates/qwen3.5-3.6-froggeric-v21.3.jinja");

fn renderCase(json_source: []const u8) ![]const u8 {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_source, .{});
    defer parsed.deinit();

    var vars = std.StringHashMap(vibe_jinja.Value).init(allocator);
    defer {
        var iterator = vars.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit(allocator);
        vars.deinit();
    }

    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        const converted = try vibe_jinja.json_value.toValue(allocator, entry.value_ptr.*);
        errdefer converted.deinit(allocator);
        try vars.put(entry.key_ptr.*, converted);
    }

    var environment = vibe_jinja.Environment.init(allocator);
    defer environment.deinit();
    environment.undefined_behavior = .strict;

    var runtime = vibe_jinja.runtime.Runtime.init(&environment, allocator);
    defer runtime.deinit();
    return runtime.renderString(qwen_fixed, vars, "qwen3.5-3.6-froggeric-v21.3");
}

fn expectContainsAll(output: []const u8, expected: []const []const u8) !void {
    for (expected) |needle| try testing.expect(std.mem.indexOf(u8, output, needle) != null);
}

fn expectContainsNone(output: []const u8, unexpected: []const []const u8) !void {
    for (unexpected) |needle| try testing.expect(std.mem.indexOf(u8, output, needle) == null);
}

test "Qwen 3.5/3.6 auto-disables thinking with tools when requested" {
    const output = try renderCase(
        \\{"messages":[{"role":"user","content":"Hello!"}],"tools":[{"name":"test_tool"}],"auto_disable_thinking_with_tools":true,"add_generation_prompt":true}
    );
    defer testing.allocator.free(output);
    try expectContainsAll(output, &.{"<think>\n\n</think>\n\n"});
}

test "Qwen 3.5/3.6 preserves thinking with tools by default" {
    const output = try renderCase(
        \\{"messages":[{"role":"user","content":"Hello!"}],"tools":[{"name":"test_tool"}],"auto_disable_thinking_with_tools":false,"add_generation_prompt":true}
    );
    defer testing.allocator.free(output);
    try expectContainsAll(output, &.{"<think>\n"});
    try expectContainsNone(output, &.{"<think>\n</think>\n"});
}

test "Qwen 3.5/3.6 inline think-on overrides auto-disable" {
    const output = try renderCase(
        \\{"messages":[{"role":"user","content":"Hello! <|think_on|>"}],"tools":[{"name":"test_tool"}],"auto_disable_thinking_with_tools":true,"add_generation_prompt":true}
    );
    defer testing.allocator.free(output);
    try expectContainsAll(output, &.{"<think>\n"});
    try expectContainsNone(output, &.{ "<think>\n</think>\n", "<|think_on|>" });
}

test "Qwen 3.5/3.6 truncates tool arguments" {
    const output = try renderCase(
        \\{"messages":[{"role":"user","content":"Call tool"},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"test","arguments":{"param":"1234567890"}}}]}],"max_tool_arg_chars":5,"add_generation_prompt":true}
    );
    defer testing.allocator.free(output);
    try expectContainsAll(output, &.{"<parameter=param>\n12345\n[TRUNCATED"});
}

test "Qwen 3.5/3.6 truncates tool responses" {
    const output = try renderCase(
        \\{"messages":[{"role":"user","content":"Do it"},{"role":"assistant","content":"calling","tool_calls":[{"name":"test"}]},{"role":"tool","content":"1234567890"}],"max_tool_response_chars":5,"add_generation_prompt":true}
    );
    defer testing.allocator.free(output);
    try expectContainsAll(output, &.{"<tool_response>\n12345\n[TRUNCATED"});
}

test "Qwen 3.5/3.6 renders mid-conversation system prompts" {
    const output = try renderCase(
        \\{"messages":[{"role":"user","content":"Hello"},{"role":"system","content":"Reminder: Be polite"}],"add_generation_prompt":true}
    );
    defer testing.allocator.free(output);
    try expectContainsAll(output, &.{"<|im_start|>system\nReminder: Be polite<|im_end|>"});
}

test "Qwen 3.5/3.6 delimits parallel tool calls" {
    const output = try renderCase(
        \\{"messages":[{"role":"user","content":"x"},{"role":"assistant","content":"","tool_calls":[{"name":"t1"},{"name":"t2"}]}],"add_generation_prompt":true}
    );
    defer testing.allocator.free(output);
    try expectContainsAll(output, &.{"</function>\n</tool_call>\n\n<tool_call>\n<function=t2>"});
}

test "Qwen 3.5/3.6 handles deep agent history without a user message" {
    const output = try renderCase(
        \\{"messages":[{"role":"system","content":"Sys"},{"role":"tool","content":"test"}],"add_generation_prompt":true}
    );
    defer testing.allocator.free(output);
    try expectContainsAll(output, &.{ "<|im_start|>system\nSys", "<|im_start|>user\n<tool_response>" });
}

test "Qwen 3.5/3.6 escalates consecutive tool errors" {
    const output = try renderCase(
        \\{"messages":[{"role":"user","content":"Do it"},{"role":"tool","content":"error: something failed"},{"role":"assistant","content":"calling"},{"role":"tool","content":"error: failed again"}],"add_generation_prompt":true}
    );
    defer testing.allocator.free(output);
    try expectContainsAll(output, &.{ "SYSTEM WARNING: 2 consecutive tool errors", "<think>\n\n</think>\n\n" });
}

test "Qwen 3.5/3.6 supports the JSON tool-call override" {
    const output = try renderCase(
        \\{"messages":[{"role":"user","content":"Call tool"},{"role":"assistant","content":"","tool_calls":[{"function":{"name":"test","arguments":{"par":"1234567890"}}}]}],"tools":[{"type":"function","function":{"name":"test","description":"test tool"}}],"tool_call_format":"json","add_generation_prompt":true}
    );
    defer testing.allocator.free(output);
    try expectContainsAll(output, &.{
        "Function calls MUST follow the specified format: a single JSON object with \"name\" and \"arguments\"",
        "{\"name\": \"test\", \"arguments\": {\"par\":\"1234567890\"}}",
    });
}

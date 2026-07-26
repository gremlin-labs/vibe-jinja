const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");

const qwen3_coder_next = @embedFile("templates/qwen3-coder-next.jinja");

// Expected output is locked to Pallets Jinja at reference commit
// 5ef70112a1ff19c05324ff889dd30405b1002044.

fn renderTemplate(template: []const u8, json_source: []const u8) ![]const u8 {
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
    return runtime.renderString(template, vars, "qwen3-coder-next");
}

test "filtered mapping iteration preserves string keys for macro subscripts" {
    const template =
        \\{% macro render_extra_keys(json_dict, handled_keys) %}
        \\{%- if json_dict is mapping %}
        \\{%- for json_key in json_dict if json_key not in handled_keys %}
        \\{%- if json_dict[json_key] is string %}<{{ json_key }}>{{ json_dict[json_key] }}</{{ json_key }}>{% endif %}
        \\{%- endfor %}
        \\{%- endif %}
        \\{%- endmacro %}
        \\{{- render_extra_keys(payload, ['handled']) }}
    ;
    const output = try renderTemplate(template, "{\"payload\":{\"handled\":\"skip\",\"extra\":\"value\"}}");
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<extra>value</extra>", output);
}

test "mapping macro does not subscript non-mapping arguments" {
    const template =
        \\{% macro render_extra_keys(json_dict) %}
        \\{%- if json_dict is mapping %}
        \\{%- for json_key in json_dict %}{{ json_dict[json_key] }}{% endfor %}
        \\{%- endif %}
        \\{%- endmacro %}
        \\{{- render_extra_keys(payload) }}
    ;
    const output = try renderTemplate(template, "{\"payload\":\"plain text\"}");
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("", output);
}

test "bytecode mapping iteration yields keys that can subscript the mapping" {
    const output = try renderTemplate(
        "{% for key in payload %}<{{ key }}>{{ payload[key] }}</{{ key }}>{% endfor %}",
        "{\"payload\":{\"extra\":\"value\"}}",
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<extra>value</extra>", output);
}

test "filtered loop retains nested conditional expressions in its iterable" {
    const output = try renderTemplate(
        "{% for item in ([1] if true else [2]) if item == 1 %}{{ item }}{% endfor %}",
        "{}",
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("1", output);
}

test "malformed filtered loop recovery releases partial expressions" {
    try testing.expectError(
        error.UndefinedError,
        renderTemplate(
            "{% for key in payload if %}{{ key }}{% endfor %}",
            "{\"payload\":{\"extra\":\"value\"}}",
        ),
    );
}

test "environment trailing newline policy matches Jinja" {
    const allocator = testing.allocator;
    var vars = std.StringHashMap(vibe_jinja.Value).init(allocator);
    defer vars.deinit();

    var environment = vibe_jinja.Environment.init(allocator);
    defer environment.deinit();
    var runtime = vibe_jinja.runtime.Runtime.init(&environment, allocator);
    defer runtime.deinit();

    const stripped = try runtime.renderString("line\n", vars, "default-newline-policy");
    defer allocator.free(stripped);
    try testing.expectEqualStrings("line", stripped);

    environment.keep_trailing_newline = true;
    const preserved = try runtime.renderString("line\n", vars, "preserve-newline-policy");
    defer allocator.free(preserved);
    try testing.expectEqualStrings("line\n", preserved);
}

test "Qwen3 Coder Next renders messages without a generation prompt" {
    const output = try renderTemplate(
        qwen3_coder_next,
        "{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"add_generation_prompt\":false}",
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<|im_start|>user\nHello<|im_end|>\n", output);
}

test "Qwen3 Coder Next renders a leading system message" {
    const output = try renderTemplate(
        qwen3_coder_next,
        "{\"messages\":[{\"role\":\"system\",\"content\":\"Follow the rules.\"},{\"role\":\"user\",\"content\":\"Hello\"}],\"add_generation_prompt\":false}",
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<|im_start|>system\nFollow the rules.<|im_end|>\n<|im_start|>user\nHello<|im_end|>\n",
        output,
    );
}

test "Qwen3 Coder Next renders tools and extra mapping keys" {
    const output = try renderTemplate(
        qwen3_coder_next,
        "{\"messages\":[{\"role\":\"user\",\"content\":\"Find cats\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"description\":\" Search things \",\"parameters\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\" Search term \",\"enum\":[\"cats\",\"dogs\"]}},\"additionalProperties\":false},\"vendor\":\"local\"}}],\"add_generation_prompt\":false}",
    );
    defer testing.allocator.free(output);
    const expected =
        \\<|im_start|>system
        \\You are Qwen, a helpful AI assistant that can interact with a computer to solve tasks.
        \\
        \\# Tools
        \\
        \\You have access to the following functions:
        \\
        \\<tools>
        \\<function>
        \\<name>lookup</name>
        \\<description>Search things</description>
        \\<parameters>
        \\<parameter>
        \\<name>query</name>
        \\<type>string</type>
        \\<description>Search term</description>
        \\<enum>["cats", "dogs"]</enum>
        \\</parameter>
        \\<additionalProperties>false</additionalProperties>
        \\</parameters>
        \\<vendor>local</vendor>
        \\</function>
        \\</tools>
        \\
        \\If you choose to call a function ONLY reply in the following format with NO suffix:
        \\
        \\<tool_call>
        \\<function=example_function_name>
        \\<parameter=example_parameter_1>
        \\value_1
        \\</parameter>
        \\<parameter=example_parameter_2>
        \\This is the value for the second parameter
        \\that can span
        \\multiple lines
        \\</parameter>
        \\</function>
        \\</tool_call>
        \\
        \\<IMPORTANT>
        \\Reminder:
        \\- Function calls MUST follow the specified format: an inner <function=...></function> block must be nested within <tool_call></tool_call> XML tags
        \\- Required parameters MUST be specified
        \\- You may provide optional reasoning for your function call in natural language BEFORE the function call, but NOT after
        \\- If there is no function call available, answer the question like normal with your current knowledge and do not tell the user about function calls
        \\</IMPORTANT><|im_end|>
        \\<|im_start|>user
        \\Find cats<|im_end|>
    ;
    try testing.expectEqualStrings(expected ++ "\n", output);
}

test "Qwen3 Coder Next renders messages and generation prompt" {
    const output = try renderTemplate(
        qwen3_coder_next,
        "{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"add_generation_prompt\":true}",
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n",
        output,
    );
}

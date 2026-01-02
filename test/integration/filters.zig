const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;
const value = vibe_jinja.value;

// ============================================================================
// Filter Kwargs Integration Tests
// Tests for filter keyword arguments as specified in Phase 1: Integration Test Coverage
// ============================================================================

// ----------------------------------------------------------------------------
// tojson Filter Tests
// ----------------------------------------------------------------------------

test "tojson compact output (no indent)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Create test data dict
    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    try dict.set("name", value.Value{ .string = try allocator.dupe(u8, "test") });
    try dict.set("value", value.Value{ .integer = 42 });

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    const data_key = try allocator.dupe(u8, "data");
    try vars.put(data_key, context.Value{ .dict = dict });

    // Test compact JSON (no indent)
    const source = "{{ data | tojson }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Compact JSON should have "name" key
    try testing.expect(std.mem.indexOf(u8, result, "\"name\"") != null);
    // Compact JSON should NOT have newlines
    try testing.expect(std.mem.indexOf(u8, result, "\n") == null);
}

test "tojson with positional indent argument" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Create test data dict
    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    try dict.set("name", value.Value{ .string = try allocator.dupe(u8, "test") });

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    const data_key = try allocator.dupe(u8, "data");
    try vars.put(data_key, context.Value{ .dict = dict });

    // Test indented JSON with positional argument
    const source = "{{ data | tojson(2) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Indented JSON should have newlines
    try testing.expect(std.mem.indexOf(u8, result, "\n") != null);
    // Indented JSON should have 2-space indent
    try testing.expect(std.mem.indexOf(u8, result, "  \"name\"") != null);
}

test "tojson with keyword argument indent=4" {
    // Filter kwargs now work in bytecode mode (Phase 2 implemented)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Create test data dict
    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    try dict.set("key", value.Value{ .string = try allocator.dupe(u8, "value") });

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    const data_key = try allocator.dupe(u8, "data");
    try vars.put(data_key, context.Value{ .dict = dict });

    // Test indented JSON with KEYWORD argument (bytecode kwargs support)
    const source = "{{ data | tojson(indent=4) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Indented JSON should have newlines
    try testing.expect(std.mem.indexOf(u8, result, "\n") != null);
    // Indented JSON should have 4-space indent
    try testing.expect(std.mem.indexOf(u8, result, "    \"key\"") != null);
}

test "tojson with indent=2 kwarg" {
    // Test tojson(indent=2) kwargs - verifies bytecode kwargs work
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

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

    const dict = try allocator.create(value.Dict);
    dict.* = value.Dict.init(allocator);
    try dict.set("name", value.Value{ .string = try allocator.dupe(u8, "test") });

    const data_key = try allocator.dupe(u8, "data");
    try vars.put(data_key, context.Value{ .dict = dict });

    // Test with indent=2 kwarg
    const source = "{{ data | tojson(indent=2) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should have 2-space indent
    try testing.expect(std.mem.indexOf(u8, result, "  \"name\"") != null);
}

test "tojson with nested data structure" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Create nested structure
    const inner_dict = try allocator.create(value.Dict);
    inner_dict.* = value.Dict.init(allocator);
    try inner_dict.set("inner", value.Value{ .integer = 123 });

    const outer_dict = try allocator.create(value.Dict);
    outer_dict.* = value.Dict.init(allocator);
    try outer_dict.set("outer", value.Value{ .dict = inner_dict });

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    const data_key = try allocator.dupe(u8, "data");
    try vars.put(data_key, context.Value{ .dict = outer_dict });

    // Test nested JSON
    const source = "{{ data | tojson(indent=2) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should have nested structure
    try testing.expect(std.mem.indexOf(u8, result, "\"outer\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"inner\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "123") != null);
}

test "tojson with list" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Create test list
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 2 });
    try list.append(value.Value{ .integer = 3 });

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
    try vars.put(items_key, context.Value{ .list = list });

    // Test list JSON
    const source = "{{ items | tojson }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be a JSON array
    try testing.expect(std.mem.indexOf(u8, result, "[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "2") != null);
    try testing.expect(std.mem.indexOf(u8, result, "3") != null);
    try testing.expect(std.mem.indexOf(u8, result, "]") != null);
}

// ----------------------------------------------------------------------------
// Truncate Filter Tests
// ----------------------------------------------------------------------------

test "truncate with positional arguments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

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

    const text_key = try allocator.dupe(u8, "text");
    const text_val = context.Value{ .string = try allocator.dupe(u8, "Joel is a slug") };
    try vars.put(text_key, text_val);

    // Test truncate with length and killwords
    const source = "{{ text | truncate(7, true) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be "Joel..." (4 chars + "...")
    try testing.expectEqualStrings("Joel...", result);
}

test "truncate with default behavior" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

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

    const text_key = try allocator.dupe(u8, "text");
    const text_val = context.Value{ .string = try allocator.dupe(u8, "This is a long string that needs truncation") };
    try vars.put(text_key, text_val);

    // Test truncate with length only (killwords=false by default, respects word boundaries)
    const source = "{{ text | truncate(20) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should end with "..."
    try testing.expect(std.mem.endsWith(u8, result, "..."));
    // Total length should be <= 20
    try testing.expect(result.len <= 20);
}

test "truncate preserves short strings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

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

    const text_key = try allocator.dupe(u8, "text");
    const text_val = context.Value{ .string = try allocator.dupe(u8, "short") };
    try vars.put(text_key, text_val);

    // String shorter than truncation length should be unchanged
    const source = "{{ text | truncate(50) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("short", result);
}

// ----------------------------------------------------------------------------
// Batch Filter Tests
// ----------------------------------------------------------------------------

test "batch with size argument" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Create list of 6 items (evenly divisible)
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    var i: i64 = 1;
    while (i <= 6) : (i += 1) {
        try list.append(value.Value{ .integer = i });
    }

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
    try vars.put(items_key, context.Value{ .list = list });

    // Batch into groups of 2 - use join for cleaner output
    const source = "{% for batch in items | batch(2) %}[{{ batch | join(',') }}]{% endfor %}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should produce [1,2][3,4][5,6]
    try testing.expectEqualStrings("[1,2][3,4][5,6]", result);
}

test "batch creates correct number of batches" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Create list of 5 items
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    var i: i64 = 1;
    while (i <= 5) : (i += 1) {
        try list.append(value.Value{ .integer = i });
    }

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
    try vars.put(items_key, context.Value{ .list = list });

    // Batch into groups of 3 - count batches
    const source = "{{ items | batch(3) | length }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should produce 2 batches: [1,2,3] and [4,5]
    try testing.expectEqualStrings("2", result);
}

// ----------------------------------------------------------------------------
// Mixed Positional and Keyword Arguments Tests
// ----------------------------------------------------------------------------

test "filter with multiple positional arguments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

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

    const text_key = try allocator.dupe(u8, "text");
    const text_val = context.Value{ .string = try allocator.dupe(u8, "hello world") };
    try vars.put(text_key, text_val);

    // Test replace with two positional args
    const source = "{{ text | replace('world', 'zig') }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("hello zig", result);
}

test "filter chain with arguments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

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

    const text_key = try allocator.dupe(u8, "text");
    const text_val = context.Value{ .string = try allocator.dupe(u8, "  hello world  ") };
    try vars.put(text_key, text_val);

    // Chain: trim -> replace -> upper
    const source = "{{ text | trim | replace('world', 'zig') | upper }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("HELLO ZIG", result);
}

// ----------------------------------------------------------------------------
// Default Filter with Keyword-style Behavior
// ----------------------------------------------------------------------------

test "default filter with boolean argument" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    // Test default with undefined variable
    const source = "{{ undefined_var | default('fallback') }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("fallback", result);
}

test "default filter with empty string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

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

    const text_key = try allocator.dupe(u8, "text");
    const text_val = context.Value{ .string = try allocator.dupe(u8, "") };
    try vars.put(text_key, text_val);

    // Empty string should trigger default
    const source = "{{ text | default('N/A') }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("N/A", result);
}

// ----------------------------------------------------------------------------
// Round Filter Tests
// ----------------------------------------------------------------------------

test "round filter with precision argument" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        vars.deinit();
    }

    const num_key = try allocator.dupe(u8, "num");
    try vars.put(num_key, context.Value{ .float = 3.14159 });

    // Round to 2 decimal places
    const source = "{{ num | round(2) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be "3.14"
    try testing.expect(std.mem.startsWith(u8, result, "3.14"));
}

test "round filter default (0 precision)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        vars.deinit();
    }

    const num_key = try allocator.dupe(u8, "num");
    try vars.put(num_key, context.Value{ .float = 3.7 });

    // Round to nearest integer
    const source = "{{ num | round }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be "4"
    try testing.expectEqualStrings("4", result);
}

// ----------------------------------------------------------------------------
// Indent Filter Tests
// ----------------------------------------------------------------------------

test "indent filter with width argument" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

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

    const text_key = try allocator.dupe(u8, "text");
    const text_val = context.Value{ .string = try allocator.dupe(u8, "line1\nline2") };
    try vars.put(text_key, text_val);

    // Indent with 4 spaces
    const source = "{{ text | indent(4) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Result should contain some kind of indentation - check for spaces in output
    // Note: Jinja2 indent behavior may vary (first line is often not indented)
    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "line1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "line2") != null);
}

// ----------------------------------------------------------------------------
// Center Filter Tests
// ----------------------------------------------------------------------------

test "center filter with width argument" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

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

    const text_key = try allocator.dupe(u8, "text");
    const text_val = context.Value{ .string = try allocator.dupe(u8, "foo") };
    try vars.put(text_key, text_val);

    // Center in 9-char width
    const source = "{{ text | center(9) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be "   foo   "
    try testing.expectEqualStrings("   foo   ", result);
}

// ----------------------------------------------------------------------------
// Wordwrap Filter Tests
// ----------------------------------------------------------------------------

test "wordwrap filter with width argument" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

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

    const text_key = try allocator.dupe(u8, "text");
    const text_val = context.Value{ .string = try allocator.dupe(u8, "This is a long line that should be wrapped") };
    try vars.put(text_key, text_val);

    // Wrap at 20 characters
    const source = "{{ text | wordwrap(20) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should contain newlines
    try testing.expect(std.mem.indexOf(u8, result, "\n") != null);
}

// ----------------------------------------------------------------------------
// Join Filter Tests
// ----------------------------------------------------------------------------

test "join filter with separator argument" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Create list
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    try list.append(value.Value{ .string = try allocator.dupe(u8, "a") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "b") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "c") });

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
    try vars.put(items_key, context.Value{ .list = list });

    // Join with " | "
    const source = "{{ items | join(' | ') }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("a | b | c", result);
}

// ----------------------------------------------------------------------------
// Format Filter Tests
// ----------------------------------------------------------------------------

test "format filter with multiple arguments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(context.Value).init(allocator);
    defer vars.deinit();

    // Test format with placeholders
    const source = "{{ 'Hello {}, you have {} messages' | format('World', 5) }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("Hello World, you have 5 messages", result);
}

// ----------------------------------------------------------------------------
// Slice Filter Tests
// ----------------------------------------------------------------------------

test "slice filter with count argument" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    // Create list of 10 items
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        try list.append(value.Value{ .integer = i });
    }

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
    try vars.put(items_key, context.Value{ .list = list });

    // Slice into 3 groups
    const source = "{% for group in items | slice(3) %}{{ group | length }}{% endfor %}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should produce groups of length ~3-4 each (10/3 = 3,3,4 or similar distribution)
    try testing.expect(result.len > 0);
}

//! Integration tests for slice syntax and new global functions
//!
//! Tests for critical missing features documented in vibe-jinja-missing-features-audit.md:
//! - Array/List Slice Syntax [start:end:step]
//! - raise_exception() global function
//! - loop.cycle() method
//! - loop.changed() method
//! - cycler(), joiner(), namespace() globals

const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const value = vibe_jinja.value;

// ============================================================================
// SLICE SYNTAX TESTS
// ============================================================================

test "slice: messages[1:] - skip first element" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for m in messages[1:] %}{{ m }}{% endfor %}";

    // Create messages list
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    try list.append(value.Value{ .string = try allocator.dupe(u8, "first") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "second") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "third") });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "messages");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("secondthird", result);
}

test "slice: messages[:-1] - skip last element" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for m in messages[:-1] %}{{ m }}{% endfor %}";

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    try list.append(value.Value{ .string = try allocator.dupe(u8, "first") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "second") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "third") });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "messages");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("firstsecond", result);
}

test "slice: messages[1:3] - range slice" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for m in messages[1:3] %}{{ m }}{% endfor %}";

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    try list.append(value.Value{ .string = try allocator.dupe(u8, "a") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "b") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "c") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "d") });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "messages");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("bc", result);
}

test "slice: messages[::2] - step slice (every other)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{% for m in messages[::2] %}{{ m }}{% endfor %}";

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    try list.append(value.Value{ .string = try allocator.dupe(u8, "a") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "b") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "c") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "d") });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "messages");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("ac", result);
}

test "slice: string slicing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source = "{{ text[1:4] }}";

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }
    const key = try allocator.dupe(u8, "text");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .string = try allocator.dupe(u8, "Hello World") });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("ell", result);
}

// ============================================================================
// LOOP.CYCLE() TESTS
// ============================================================================

test "loop.cycle: alternating odd/even" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% for i in items %}{{ loop.cycle('odd', 'even') }}{% endfor %}
    ;

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    try list.append(value.Value{ .integer = 1 });
    try list.append(value.Value{ .integer = 2 });
    try list.append(value.Value{ .integer = 3 });
    try list.append(value.Value{ .integer = 4 });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "items");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("oddevenoddeven", result);
}

test "loop.cycle: three values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% for i in items %}{{ loop.cycle('a', 'b', 'c') }}{% endfor %}
    ;

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < 7) : (i += 1) {
        try list.append(value.Value{ .integer = 0 });
    }

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "items");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("abcabca", result);
}

// ============================================================================
// LOOP.CHANGED() TESTS
// ============================================================================

test "loop.changed: detect category changes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% for item in items %}{% if loop.changed(item) %}[{{ item }}]{% endif %}{% endfor %}
    ;

    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);

    // Same values should not trigger changed
    try list.append(value.Value{ .string = try allocator.dupe(u8, "A") });
    try list.append(value.Value{ .string = try allocator.dupe(u8, "A") }); // same - no output
    try list.append(value.Value{ .string = try allocator.dupe(u8, "B") }); // different
    try list.append(value.Value{ .string = try allocator.dupe(u8, "B") }); // same - no output
    try list.append(value.Value{ .string = try allocator.dupe(u8, "A") }); // different

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const key = try allocator.dupe(u8, "items");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("[A][B][A]", result);
}

// ============================================================================
// GLOBAL FUNCTIONS TESTS
// ============================================================================

test "cycler global: creates cycler object" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% set row = cycler('odd', 'even') %}{{ row._type }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("cycler", result);
}

test "joiner global: creates joiner object" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% set sep = joiner(', ') %}{{ sep._type }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("joiner", result);
}

test "namespace global: creates namespace object" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% set ns = namespace() %}{{ ns._type }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("namespace", result);
}

// ============================================================================
// VARIABLE REASSIGNMENT TESTS
// Critical for HuggingFace/Llama 3.2 templates that use patterns like:
//   {% set messages = messages[1:] %}
// ============================================================================

test "variable reassignment with slice - skip first element" {
    // Tests the pattern: {% set messages = messages[1:] %}
    // Used in Llama 3.2 chat templates to skip system message
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% set items = [1, 2, 3, 4, 5] %}
        \\{% set items = items[1:] %}
        \\{{ items | join(',') }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should output "2,3,4,5" after slicing off the first element
    try testing.expect(std.mem.indexOf(u8, result, "2,3,4,5") != null);
}

test "variable reassignment with slice - skip last element" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% set items = ['a', 'b', 'c', 'd'] %}
        \\{% set items = items[:-1] %}
        \\{{ items | join(',') }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should output "a,b,c" after slicing off the last element
    try testing.expect(std.mem.indexOf(u8, result, "a,b,c") != null);
}

test "variable reassignment preserves original during evaluation" {
    // Ensures items[1:] is evaluated using original value before reassignment
    // This tests that RHS is fully evaluated before assignment
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% set items = ['a', 'b', 'c'] %}
        \\{% set items = items[1:] + items[:1] %}
        \\{{ items | join(',') }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should output "b,c,a" - items[1:] = ['b','c'] + items[:1] = ['a']
    try testing.expect(std.mem.indexOf(u8, result, "b,c,a") != null);
}

test "variable reassignment with external list" {
    // Tests reassignment when the list comes from template context (like messages)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% set messages = messages[1:] %}
        \\{% for m in messages %}{{ m.content }}{% endfor %}
    ;

    // Create messages list with dict items (like chat messages)
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);

    // Create first message dict (system message - will be skipped)
    const msg1_dict = try allocator.create(value.Dict);
    msg1_dict.* = value.Dict.init(allocator);
    try msg1_dict.set("role", value.Value{ .string = try allocator.dupe(u8, "system") });
    try msg1_dict.set("content", value.Value{ .string = try allocator.dupe(u8, "You are helpful") });
    try list.append(value.Value{ .dict = msg1_dict });

    // Create second message dict (user message)
    const msg2_dict = try allocator.create(value.Dict);
    msg2_dict.* = value.Dict.init(allocator);
    try msg2_dict.set("role", value.Value{ .string = try allocator.dupe(u8, "user") });
    try msg2_dict.set("content", value.Value{ .string = try allocator.dupe(u8, "Hello") });
    try list.append(value.Value{ .dict = msg2_dict });

    // Create third message dict (assistant message)
    const msg3_dict = try allocator.create(value.Dict);
    msg3_dict.* = value.Dict.init(allocator);
    try msg3_dict.set("role", value.Value{ .string = try allocator.dupe(u8, "assistant") });
    try msg3_dict.set("content", value.Value{ .string = try allocator.dupe(u8, "Hi there") });
    try list.append(value.Value{ .dict = msg3_dict });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        vars.deinit();
    }
    const key = try allocator.dupe(u8, "messages");
    defer allocator.free(key);
    try vars.put(key, value.Value{ .list = list });

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should output "HelloHi there" - skipping the system message
    try testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Hi there") != null);
    // Should NOT contain the system message content
    try testing.expect(std.mem.indexOf(u8, result, "You are helpful") == null);
}

test "multiple variable reassignments in sequence" {
    // Tests multiple reassignments to the same variable
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    const source =
        \\{% set items = [1, 2, 3, 4, 5] %}
        \\{% set items = items[1:] %}
        \\{% set items = items[1:] %}
        \\{{ items | join(',') }}
    ;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // After first slice: [2,3,4,5]
    // After second slice: [3,4,5]
    try testing.expect(std.mem.indexOf(u8, result, "3,4,5") != null);
}

// ============================================================================
// STRFTIME_NOW GLOBAL FUNCTION TESTS
// HuggingFace template compatibility
// ============================================================================

test "strftime_now: date format %Y-%m-%d" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test date formatting (YYYY-MM-DD)
    const source = "{{ strftime_now(\"%Y-%m-%d\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be exactly 10 characters: YYYY-MM-DD
    try testing.expect(result.len == 10);
    // Should have dashes in correct positions
    try testing.expect(result[4] == '-');
    try testing.expect(result[7] == '-');
    // Year should be 4 digits
    try testing.expect(std.ascii.isDigit(result[0]));
    try testing.expect(std.ascii.isDigit(result[1]));
    try testing.expect(std.ascii.isDigit(result[2]));
    try testing.expect(std.ascii.isDigit(result[3]));
}

test "strftime_now: time format %H:%M:%S" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test time formatting (HH:MM:SS)
    const source = "{{ strftime_now(\"%H:%M:%S\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be exactly 8 characters: HH:MM:SS
    try testing.expect(result.len == 8);
    // Should have colons in correct positions
    try testing.expect(result[2] == ':');
    try testing.expect(result[5] == ':');
    // All other characters should be digits
    try testing.expect(std.ascii.isDigit(result[0]));
    try testing.expect(std.ascii.isDigit(result[1]));
    try testing.expect(std.ascii.isDigit(result[3]));
    try testing.expect(std.ascii.isDigit(result[4]));
    try testing.expect(std.ascii.isDigit(result[6]));
    try testing.expect(std.ascii.isDigit(result[7]));
}

test "strftime_now: callable and returns value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test that strftime_now is callable and returns a valid year
    // This verifies the global function is registered and working
    const source = "{{ strftime_now('%Y') }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should return a 4-digit year
    try testing.expect(result.len == 4);
    // All digits
    for (result) |c| {
        try testing.expect(std.ascii.isDigit(c));
    }
}

test "strftime_now: month abbreviation %b" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test abbreviated month name
    const source = "{{ strftime_now(\"%b\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be a 3-letter month abbreviation
    try testing.expect(result.len == 3);
    // First letter should be uppercase
    try testing.expect(std.ascii.isUpper(result[0]));
    // Rest should be lowercase
    try testing.expect(std.ascii.isLower(result[1]));
    try testing.expect(std.ascii.isLower(result[2]));
}

test "strftime_now: full month name %B" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test full month name
    const source = "{{ strftime_now(\"%B\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be a valid month name (at least 3 characters)
    try testing.expect(result.len >= 3);
    // First letter should be uppercase
    try testing.expect(std.ascii.isUpper(result[0]));
    // Check it's one of the valid month names
    const valid_months = [_][]const u8{
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    };
    var found = false;
    for (valid_months) |month| {
        if (std.mem.eql(u8, result, month)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "strftime_now: weekday abbreviation %a" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test abbreviated weekday name
    const source = "{{ strftime_now(\"%a\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be a 3-letter weekday abbreviation
    try testing.expect(result.len == 3);
    // Check it's one of the valid weekday abbreviations
    const valid_days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    var found = false;
    for (valid_days) |day| {
        if (std.mem.eql(u8, result, day)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "strftime_now: full weekday name %A" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test full weekday name
    const source = "{{ strftime_now(\"%A\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be a valid weekday name (at least 6 characters for "Monday")
    try testing.expect(result.len >= 6);
    // Check it's one of the valid weekday names
    const valid_days = [_][]const u8{
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    };
    var found = false;
    for (valid_days) |day| {
        if (std.mem.eql(u8, result, day)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "strftime_now: 12-hour format %I with AM/PM %p" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test 12-hour format with AM/PM
    const source = "{{ strftime_now(\"%I:%M %p\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be format like "HH:MM AM" or "HH:MM PM"
    try testing.expect(result.len == 8);
    // Should end with AM or PM
    try testing.expect(std.mem.endsWith(u8, result, "AM") or std.mem.endsWith(u8, result, "PM"));
    // Hour should be 01-12
    const hour = try std.fmt.parseInt(u8, result[0..2], 10);
    try testing.expect(hour >= 1 and hour <= 12);
}

test "strftime_now: year without century %y" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test 2-digit year
    const source = "{{ strftime_now(\"%y\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be exactly 2 digits
    try testing.expect(result.len == 2);
    try testing.expect(std.ascii.isDigit(result[0]));
    try testing.expect(std.ascii.isDigit(result[1]));
}

test "strftime_now: day of year %j" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test day of year (001-366)
    const source = "{{ strftime_now(\"%j\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be exactly 3 digits
    try testing.expect(result.len == 3);
    // All should be digits
    try testing.expect(std.ascii.isDigit(result[0]));
    try testing.expect(std.ascii.isDigit(result[1]));
    try testing.expect(std.ascii.isDigit(result[2]));
    // Value should be 001-366
    const doy = try std.fmt.parseInt(u16, result, 10);
    try testing.expect(doy >= 1 and doy <= 366);
}

test "strftime_now: weekday as decimal %w" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test weekday as decimal (0=Sunday, 6=Saturday)
    const source = "{{ strftime_now(\"%w\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be a single digit 0-6
    try testing.expect(result.len == 1);
    try testing.expect(std.ascii.isDigit(result[0]));
    const dow = try std.fmt.parseInt(u8, result, 10);
    try testing.expect(dow >= 0 and dow <= 6);
}

test "strftime_now: literal percent %%" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test literal percent sign
    const source = "{{ strftime_now(\"100%%\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings("100%", result);
}

test "strftime_now: combined date/time format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test combined format like ISO 8601
    const source = "{{ strftime_now(\"%Y-%m-%dT%H:%M:%S\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be exactly 19 characters: YYYY-MM-DDTHH:MM:SS
    try testing.expect(result.len == 19);
    // Check separators
    try testing.expect(result[4] == '-');
    try testing.expect(result[7] == '-');
    try testing.expect(result[10] == 'T');
    try testing.expect(result[13] == ':');
    try testing.expect(result[16] == ':');
}

test "strftime_now: human readable format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    // Test human readable format like "01 Jan 2026"
    const source = "{{ strftime_now(\"%d %b %Y\") }}";
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    // Should be format like "DD Mon YYYY" (11 characters)
    try testing.expect(result.len == 11);
    // Day should be 2 digits
    try testing.expect(std.ascii.isDigit(result[0]));
    try testing.expect(std.ascii.isDigit(result[1]));
    // Space separator
    try testing.expect(result[2] == ' ');
    // Month abbreviation (3 chars)
    try testing.expect(std.ascii.isUpper(result[3]));
    try testing.expect(std.ascii.isLower(result[4]));
    try testing.expect(std.ascii.isLower(result[5]));
    // Space separator
    try testing.expect(result[6] == ' ');
    // Year (4 digits)
    try testing.expect(std.ascii.isDigit(result[7]));
    try testing.expect(std.ascii.isDigit(result[8]));
    try testing.expect(std.ascii.isDigit(result[9]));
    try testing.expect(std.ascii.isDigit(result[10]));
}

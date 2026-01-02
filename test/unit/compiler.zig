const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const compiler = vibe_jinja.compiler;
const context = vibe_jinja.context;
const nodes = vibe_jinja.nodes;
const value = vibe_jinja.value;

test "visit string literal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const string_lit = try allocator.create(nodes.StringLiteral);
    string_lit.* = try nodes.StringLiteral.init(allocator, "hello", 1, "test");
    defer {
        string_lit.deinit(allocator);
        allocator.destroy(string_lit);
    }

    var comp = compiler.Compiler.init(&env, "test", allocator);
    defer comp.deinit();

    var frame = compiler.Frame.init("test", null, allocator);
    defer frame.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    var expr = nodes.Expression{ .string_literal = string_lit };
    var result = try comp.visitExpression(&expr, &frame, &ctx);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("hello", result.string);
}

test "visit integer literal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const int_lit = try allocator.create(nodes.IntegerLiteral);
    int_lit.* = nodes.IntegerLiteral.init(1, "test", 42);
    defer {
        int_lit.deinit(allocator);
        allocator.destroy(int_lit);
    }

    var comp = compiler.Compiler.init(&env, "test", allocator);
    defer comp.deinit();

    var frame = compiler.Frame.init("test", null, allocator);
    defer frame.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    var expr = nodes.Expression{ .integer_literal = int_lit };
    var result = try comp.visitExpression(&expr, &frame, &ctx);
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 42);
}

test "visit boolean literal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const bool_lit = try allocator.create(nodes.BooleanLiteral);
    bool_lit.* = nodes.BooleanLiteral.init(1, "test", true);
    defer {
        bool_lit.deinit(allocator);
        allocator.destroy(bool_lit);
    }

    var comp = compiler.Compiler.init(&env, "test", allocator);
    defer comp.deinit();

    var frame = compiler.Frame.init("test", null, allocator);
    defer frame.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    var expr = nodes.Expression{ .boolean_literal = bool_lit };
    var result = try comp.visitExpression(&expr, &frame, &ctx);
    defer result.deinit(allocator);

    try testing.expect(result == .boolean);
    try testing.expect(result.boolean == true);
}

test "visit name expression resolves variable" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const name_node = try allocator.create(nodes.Name);
    name_node.* = try nodes.Name.init(allocator, "test_var", .load, 1, "test");
    defer {
        name_node.deinit(allocator);
        allocator.destroy(name_node);
    }

    var comp = compiler.Compiler.init(&env, "test", allocator);
    defer comp.deinit();

    var frame = compiler.Frame.init("test", null, allocator);
    defer frame.deinit();

    // Set variable in context
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    const name_copy = try allocator.dupe(u8, "test_var");
    defer allocator.free(name_copy);
    const val_copy = try allocator.dupe(u8, "test_value");
    // We own val_copy - context doesn't free it because owns_vars=false
    defer allocator.free(val_copy);
    try vars.put(name_copy, value.Value{ .string = val_copy });

    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    var expr = nodes.Expression{ .name = name_node };
    var result = try comp.visitExpression(&expr, &frame, &ctx);
    // visitExpression returns a deep copy - caller owns it and must clean it up
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("test_value", result.string);
}

test "visit binary addition expression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const left_lit = try allocator.create(nodes.IntegerLiteral);
    left_lit.* = nodes.IntegerLiteral.init(1, "test", 10);
    // Don't defer free - bin_expr owns it

    const right_lit = try allocator.create(nodes.IntegerLiteral);
    right_lit.* = nodes.IntegerLiteral.init(1, "test", 20);
    // Don't defer free - bin_expr owns it

    const bin_expr = try allocator.create(nodes.BinExpr);
    bin_expr.* = nodes.BinExpr{
        .base = nodes.Node{ .lineno = 1, .filename = "test", .environment = null },
        .left = nodes.Expression{ .integer_literal = left_lit },
        .right = nodes.Expression{ .integer_literal = right_lit },
        .op = .ADD,
    };
    // bin_expr.deinit will free left_lit and right_lit
    defer {
        bin_expr.deinit(allocator);
        allocator.destroy(bin_expr);
    }

    var comp = compiler.Compiler.init(&env, "test", allocator);
    defer comp.deinit();

    var frame = compiler.Frame.init("test", null, allocator);
    defer frame.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    var expr = nodes.Expression{ .bin_expr = bin_expr };
    var result = try comp.visitExpression(&expr, &frame, &ctx);
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 30);
}

test "visit output statement with plain text" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const output = try allocator.create(nodes.Output);
    output.* = try nodes.Output.initPlainText(allocator, "Hello", 1, "test");
    defer {
        output.deinit(allocator);
        allocator.destroy(output);
    }

    var comp = compiler.Compiler.init(&env, "test", allocator);
    defer comp.deinit();

    var frame = compiler.Frame.init("test", null, allocator);
    defer frame.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    const result = try comp.visitOutput(output, &frame, &ctx);
    defer allocator.free(result);

    try testing.expectEqualStrings("Hello", result);
}

test "renderWithOptions basic rendering" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    // Note: env.deinit() will clean up cached templates
    defer env.deinit();

    // Create a simple template (will be cached by environment)
    const template = try env.fromString("Hello {{ name }}!", "test");
    // Don't deinit template - it's managed by the cache

    // Compile it
    var comp = compiler.Compiler.init(&env, "test", allocator);
    defer comp.deinit();
    var compiled = try comp.compile(template, false);
    defer compiled.deinit();

    // Create context with a variable
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }
    const name_str = try allocator.dupe(u8, "World");
    try vars.put("name", value.Value{ .string = name_str });
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    // Render with options (no timeout, no tracing)
    const result = try compiled.renderWithOptions(&ctx, allocator, .{});
    defer allocator.free(result);

    try testing.expectEqualStrings("Hello World!", result);
}

test "renderWithOptions with timeout succeeds for quick templates" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    // Note: env.deinit() will clean up cached templates
    defer env.deinit();

    // Create a simple template (will be cached by environment)
    const template = try env.fromString("Quick: {{ 1 + 2 }}", "test");
    // Don't deinit template - it's managed by the cache

    // Compile it
    var comp = compiler.Compiler.init(&env, "test", allocator);
    defer comp.deinit();
    var compiled = try comp.compile(template, false);
    defer compiled.deinit();

    // Create empty context
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    // Render with generous timeout (should succeed)
    const result = try compiled.renderWithOptions(&ctx, allocator, .{
        .timeout_ms = 10000, // 10 second timeout
        .debug_trace = false,
    });
    defer allocator.free(result);

    try testing.expectEqualStrings("Quick: 3", result);
}

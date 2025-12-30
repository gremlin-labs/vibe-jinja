const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const nodes = vibe_jinja.nodes;
const value = vibe_jinja.value;
const context = vibe_jinja.context;

test "node string literal init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var str_lit = try nodes.StringLiteral.init(allocator, "hello", 1, "test.jinja");
    defer str_lit.deinit(allocator);

    try testing.expectEqualStrings("hello", str_lit.value);
    try testing.expect(str_lit.base.lineno == 1);
}

test "node integer literal init" {
    var int_lit = nodes.IntegerLiteral.init(1, "test.jinja", 42);
    try testing.expect(int_lit.value == 42);
    try testing.expect(int_lit.base.lineno == 1);
}

test "node boolean literal init" {
    var bool_lit = nodes.BooleanLiteral.init(1, "test.jinja", true);
    try testing.expect(bool_lit.value == true);
    try testing.expect(bool_lit.base.lineno == 1);
}

test "node float literal init" {
    var float_lit = nodes.FloatLiteral.init(1, "test.jinja", 3.14);
    try testing.expect(float_lit.value == 3.14);
    try testing.expect(float_lit.base.lineno == 1);
}

test "node name expression eval" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = vibe_jinja.environment.Environment.init(allocator);
    defer env.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    
    var test_val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer test_val.deinit(allocator);
    try vars.put(try allocator.dupe(u8, "test_var"), test_val);

    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    var name_node = try nodes.Name.init(allocator, "test_var", 1, "test.jinja");
    defer name_node.deinit(allocator);

    var expr = nodes.Expression{ .name = name_node };
    var result = try expr.eval(&ctx, allocator);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("hello", result.string);
}

test "node binary expression eval" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = vibe_jinja.environment.Environment.init(allocator);
    defer env.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    var left = try nodes.IntegerLiteral.init(allocator, 10, 1, "test.jinja");
    defer left.deinit(allocator);
    var right = try nodes.IntegerLiteral.init(allocator, 5, 1, "test.jinja");
    defer right.deinit(allocator);

    var bin_expr = try nodes.BinExpr.init(allocator, .add, &left.base, &right.base, 1, "test.jinja");
    defer bin_expr.deinit(allocator);

    var expr = nodes.Expression{ .bin_expr = bin_expr };
    var result = try expr.eval(&ctx, allocator);
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expect(result.integer == 15);
}

test "node template init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var template = try nodes.Template.init(allocator, "test_template", 1, "test.jinja");
    defer template.deinit(allocator);

    try testing.expect(template.name != null);
    try testing.expectEqualStrings("test_template", template.name.?);
    try testing.expect(template.body.items.len == 0);
}

test "node output statement init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var output = try nodes.Output.init(allocator, 1, "test.jinja");
    defer output.deinit(allocator);

    try testing.expect(output.base.lineno == 1);
    try testing.expect(output.nodes.items.len == 0);
}

test "node if statement init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cond = try nodes.BooleanLiteral.init(allocator, true, 1, "test.jinja");
    defer cond.deinit(allocator);

    var if_stmt = try nodes.If.init(allocator, &cond.base, 1, "test.jinja");
    defer if_stmt.deinit(allocator);

    try testing.expect(if_stmt.base.lineno == 1);
    try testing.expect(if_stmt.body.items.len == 0);
}

test "node for loop init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var target = try nodes.Name.init(allocator, "item", 1, "test.jinja");
    defer target.deinit(allocator);

    var iter = try nodes.Name.init(allocator, "items", 1, "test.jinja");
    defer iter.deinit(allocator);

    var for_loop = try nodes.For.init(allocator, &target.base, &iter.base, 1, "test.jinja");
    defer for_loop.deinit(allocator);

    try testing.expect(for_loop.base.lineno == 1);
    try testing.expect(for_loop.body.items.len == 0);
}

test "node block statement init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var block = try nodes.Block.init(allocator, "content", 1, "test.jinja");
    defer block.deinit(allocator);

    try testing.expectEqualStrings("content", block.name);
    try testing.expect(block.base.lineno == 1);
    try testing.expect(block.body.items.len == 0);
}

test "node macro init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var macro = try nodes.Macro.init(allocator, "test_macro", 1, "test.jinja");
    defer macro.deinit(allocator);

    try testing.expectEqualStrings("test_macro", macro.name);
    try testing.expect(macro.base.lineno == 1);
    try testing.expect(macro.args.items.len == 0);
    try testing.expect(macro.body.items.len == 0);
}

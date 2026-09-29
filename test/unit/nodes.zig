const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const nodes = vibe_jinja.nodes;
const value = vibe_jinja.value;
const context = vibe_jinja.context;

fn integerExpression(allocator: std.mem.Allocator, number: i64) !nodes.Expression {
    const literal = try allocator.create(nodes.IntegerLiteral);
    literal.* = nodes.IntegerLiteral.init(1, "test.jinja", number);
    return .{ .integer_literal = literal };
}

fn booleanExpression(allocator: std.mem.Allocator, boolean: bool) !nodes.Expression {
    const literal = try allocator.create(nodes.BooleanLiteral);
    literal.* = nodes.BooleanLiteral.init(1, "test.jinja", boolean);
    return .{ .boolean_literal = literal };
}

fn nameExpression(allocator: std.mem.Allocator, name: []const u8, ctx: nodes.Name.NameContext) !nodes.Expression {
    const name_node = try allocator.create(nodes.Name);
    errdefer allocator.destroy(name_node);
    name_node.* = try nodes.Name.init(allocator, name, ctx, 1, "test.jinja");
    return .{ .name = name_node };
}

test "node literal initialization" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var string = try nodes.StringLiteral.init(allocator, "hello", 1, "test.jinja");
    defer string.deinit(allocator);
    const integer = nodes.IntegerLiteral.init(2, "test.jinja", 42);
    const boolean = nodes.BooleanLiteral.init(3, "test.jinja", true);
    const float = nodes.FloatLiteral.init(4, "test.jinja", 3.14);

    try testing.expectEqualStrings("hello", string.value);
    try testing.expectEqual(@as(usize, 1), string.base.lineno);
    try testing.expectEqual(@as(i64, 42), integer.value);
    try testing.expect(boolean.value);
    try testing.expectEqual(@as(f64, 3.14), float.value);
}

test "node name expression eval" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = vibe_jinja.environment.Environment.init(allocator);
    defer env.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var test_value = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer test_value.deinit(allocator);
    try vars.put("test_var", test_value);

    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    var expression = try nameExpression(allocator, "test_var", .load);
    defer expression.deinit(allocator);
    var result = try expression.eval(&ctx, allocator);
    defer result.deinit(allocator);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("hello", result.string);
}

test "node binary expression eval" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = vibe_jinja.environment.Environment.init(allocator);
    defer env.deinit();
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    const binary = try allocator.create(nodes.BinExpr);
    binary.* = .{
        .base = .{ .lineno = 1, .filename = "test.jinja", .environment = null },
        .left = try integerExpression(allocator, 10),
        .right = try integerExpression(allocator, 5),
        .op = .ADD,
    };
    var expression = nodes.Expression{ .bin_expr = binary };
    defer expression.deinit(allocator);
    var result = try expression.eval(&ctx, allocator);
    defer result.deinit(allocator);

    try testing.expect(result == .integer);
    try testing.expectEqual(@as(i64, 15), result.integer);
}

test "node statement initialization" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var template = nodes.Template.init(allocator, 1, "test.jinja");
    template.name = try allocator.dupe(u8, "test_template");
    defer template.deinit(allocator);

    var output = nodes.Output.initExpression(allocator, 2, "test.jinja");
    defer output.deinit(allocator);
    var if_statement = nodes.If.init(allocator, try booleanExpression(allocator, true), 3, "test.jinja");
    defer if_statement.deinit(allocator);
    var for_loop = nodes.For.init(
        allocator,
        try nameExpression(allocator, "item", .store),
        try nameExpression(allocator, "items", .load),
        4,
        "test.jinja",
    );
    defer for_loop.deinit(allocator);

    try testing.expectEqualStrings("test_template", template.name.?);
    try testing.expectEqual(@as(usize, 2), output.base.base.lineno);
    try testing.expectEqual(@as(usize, 3), if_statement.base.base.lineno);
    try testing.expectEqual(@as(usize, 4), for_loop.base.base.lineno);
    try testing.expectEqual(@as(usize, 0), template.body.items.len);
    try testing.expectEqual(@as(usize, 0), output.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), if_statement.body.items.len);
    try testing.expectEqual(@as(usize, 0), for_loop.body.items.len);
}

test "node block and macro initialization" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var block = try nodes.Block.init(allocator, "content", 1, "test.jinja");
    defer block.deinit(allocator);
    var macro = try nodes.Macro.init(allocator, "test_macro", 2, "test.jinja");
    defer macro.deinit(allocator);

    try testing.expectEqualStrings("content", block.name);
    try testing.expectEqual(@as(usize, 1), block.base.base.lineno);
    try testing.expectEqualStrings("test_macro", macro.name);
    try testing.expectEqual(@as(usize, 2), macro.base.base.lineno);
    try testing.expectEqual(@as(usize, 0), macro.args.items.len);
    try testing.expectEqual(@as(usize, 0), macro.body.items.len);
}

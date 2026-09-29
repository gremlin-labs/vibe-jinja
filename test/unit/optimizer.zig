const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const optimizer = vibe_jinja.optimizer;
const nodes = vibe_jinja.nodes;

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

fn stringExpression(allocator: std.mem.Allocator, string: []const u8) !nodes.Expression {
    const literal = try allocator.create(nodes.StringLiteral);
    errdefer allocator.destroy(literal);
    literal.* = try nodes.StringLiteral.init(allocator, string, 1, "test.jinja");
    return .{ .string_literal = literal };
}

fn binaryExpression(allocator: std.mem.Allocator, left: nodes.Expression, right: nodes.Expression) !nodes.Expression {
    const binary = try allocator.create(nodes.BinExpr);
    binary.* = .{
        .base = .{ .lineno = 1, .filename = "test.jinja", .environment = null },
        .left = left,
        .right = right,
        .op = .ADD,
    };
    return .{ .bin_expr = binary };
}

fn plainOutput(allocator: std.mem.Allocator, content: []const u8) !*nodes.Output {
    const output = try allocator.create(nodes.Output);
    errdefer allocator.destroy(output);
    output.* = try nodes.Output.initPlainText(allocator, content, 1, "test.jinja");
    return output;
}

test "optimizer constant folds integer and string addition" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var opt = optimizer.Optimizer.init(allocator);

    var integer_expr = try binaryExpression(allocator, try integerExpression(allocator, 10), try integerExpression(allocator, 5));
    defer integer_expr.deinit(allocator);
    var integer_result = (try opt.optimizeExpression(&integer_expr)).?;
    defer integer_result.deinit(allocator);
    try testing.expectEqual(@as(i64, 15), integer_result.integer);

    var string_expr = try binaryExpression(allocator, try stringExpression(allocator, "hello"), try stringExpression(allocator, " world"));
    defer string_expr.deinit(allocator);
    var string_result = (try opt.optimizeExpression(&string_expr)).?;
    defer string_result.deinit(allocator);
    try testing.expectEqualStrings("hello world", string_result.string);
}

test "optimizer transfers constant branches before destroying the if node" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var opt = optimizer.Optimizer.init(allocator);

    var template = nodes.Template.init(allocator, 1, "test.jinja");
    defer template.deinit(allocator);
    const if_statement = try allocator.create(nodes.If);
    if_statement.* = nodes.If.init(allocator, try booleanExpression(allocator, true), 1, "test.jinja");
    const output = try plainOutput(allocator, "reachable");
    try if_statement.body.append(allocator, &output.base);
    try template.body.append(allocator, &if_statement.base);

    try opt.optimize(&template);

    try testing.expectEqual(@as(usize, 1), template.body.items.len);
    try testing.expectEqual(nodes.StmtTag.output, template.body.items[0].tag);
    const retained = @as(*nodes.Output, @ptrCast(@alignCast(template.body.items[0])));
    try testing.expectEqualStrings("reachable", retained.content);
}

test "optimizer eliminates false branch and merges adjacent output" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var opt = optimizer.Optimizer.init(allocator);

    var template = nodes.Template.init(allocator, 1, "test.jinja");
    defer template.deinit(allocator);
    const if_statement = try allocator.create(nodes.If);
    if_statement.* = nodes.If.init(allocator, try booleanExpression(allocator, false), 1, "test.jinja");
    try template.body.append(allocator, &if_statement.base);
    const first = try plainOutput(allocator, "hello");
    const second = try plainOutput(allocator, " world");
    try template.body.append(allocator, &first.base);
    try template.body.append(allocator, &second.base);

    try opt.optimize(&template);

    try testing.expectEqual(@as(usize, 1), template.body.items.len);
    const merged = @as(*nodes.Output, @ptrCast(@alignCast(template.body.items[0])));
    try testing.expectEqualStrings("hello world", merged.content);
}

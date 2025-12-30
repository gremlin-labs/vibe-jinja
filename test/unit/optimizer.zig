const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const optimizer = vibe_jinja.optimizer;
const nodes = vibe_jinja.nodes;

test "optimizer init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var opt = optimizer.Optimizer.init(allocator);
    defer opt.deinit();

    try testing.expect(opt.allocator == allocator);
}

test "optimizer constant folding integer addition" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var opt = optimizer.Optimizer.init(allocator);
    defer opt.deinit();

    // Create a binary expression with constant values
    var left = try nodes.IntegerLiteral.init(allocator, 10, 1, "test.jinja");
    defer left.deinit(allocator);
    var right = try nodes.IntegerLiteral.init(allocator, 5, 1, "test.jinja");
    defer right.deinit(allocator);

    var bin_expr = try nodes.BinExpr.init(allocator, .add, &left.base, &right.base, 1, "test.jinja");
    defer bin_expr.deinit(allocator);

    // Optimize should fold constants
    var optimized = try opt.optimizeExpression(&bin_expr.base);
    defer optimized.deinit(allocator);

    // Result should be a constant integer literal
    try testing.expect(optimized == .integer_literal);
    try testing.expect(optimized.integer_literal.value == 15);
}

test "optimizer constant folding string concatenation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var opt = optimizer.Optimizer.init(allocator);
    defer opt.deinit();

    var left = try nodes.StringLiteral.init(allocator, "hello", 1, "test.jinja");
    defer left.deinit(allocator);
    var right = try nodes.StringLiteral.init(allocator, " world", 1, "test.jinja");
    defer right.deinit(allocator);

    var bin_expr = try nodes.BinExpr.init(allocator, .add, &left.base, &right.base, 1, "test.jinja");
    defer bin_expr.deinit(allocator);

    var optimized = try opt.optimizeExpression(&bin_expr.base);
    defer optimized.deinit(allocator);

    // Result should be a constant string literal
    try testing.expect(optimized == .string_literal);
    try testing.expectEqualStrings("hello world", optimized.string_literal.value);
}

test "optimizer dead code elimination" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var opt = optimizer.Optimizer.init(allocator);
    defer opt.deinit();

    // Create an if statement with false condition
    var false_cond = try nodes.BooleanLiteral.init(allocator, false, 1, "test.jinja");
    defer false_cond.deinit(allocator);

    var if_stmt = try nodes.If.init(allocator, &false_cond.base, 1, "test.jinja");
    defer if_stmt.deinit(allocator);

    // Add some statements to the body
    var output = try nodes.Output.init(allocator, 2, "test.jinja");
    defer output.deinit(allocator);
    try if_stmt.body.append(allocator, &output.base);

    // Optimize should eliminate dead code
    var optimized = try opt.optimizeStatement(&if_stmt.base);
    defer optimized.deinit(allocator);

    // Result should be empty or removed
    try testing.expect(optimized == .if_stmt);
    // Body should be empty after optimization
    try testing.expect(optimized.if_stmt.body.items.len == 0);
}

test "optimizer output merging" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var opt = optimizer.Optimizer.init(allocator);
    defer opt.deinit();

    // Create consecutive output statements
    var output1 = try nodes.Output.init(allocator, 1, "test.jinja");
    defer output1.deinit(allocator);
    
    var str1 = try nodes.StringLiteral.init(allocator, "hello", 1, "test.jinja");
    defer str1.deinit(allocator);
    try output1.nodes.append(allocator, &str1.base);

    var output2 = try nodes.Output.init(allocator, 2, "test.jinja");
    defer output2.deinit(allocator);
    
    var str2 = try nodes.StringLiteral.init(allocator, " world", 2, "test.jinja");
    defer str2.deinit(allocator);
    try output2.nodes.append(allocator, &str2.base);

    // Optimize should merge consecutive outputs
    // Note: This is a simplified test - actual merging happens at template level
    var optimized1 = try opt.optimizeStatement(&output1.base);
    defer optimized1.deinit(allocator);
    var optimized2 = try opt.optimizeStatement(&output2.base);
    defer optimized2.deinit(allocator);

    try testing.expect(optimized1 == .output);
    try testing.expect(optimized2 == .output);
}

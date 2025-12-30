const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const parser = vibe_jinja.parser;
const lexer = vibe_jinja.lexer;
const nodes = vibe_jinja.nodes;
const compiler = vibe_jinja.compiler;
const context = vibe_jinja.context;
const value = vibe_jinja.value;

test "parse float literal expression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ 3.14 }}";
    var lex = lexer.Lexer.init(&env, source, "test");
    const stream = try lex.tokenize(allocator);
    defer allocator.free(stream.tokens);

    var p = parser.Parser.init(&env, stream, "test", allocator);
    const template = try p.parse();
    defer {
        template.deinit(allocator);
        allocator.destroy(template);
    }

    try testing.expect(template.body.items.len == 1);
    const stmt = template.body.items[0];
    try testing.expect(stmt.tag == .output);
    const output = @as(*nodes.Output, @ptrCast(@alignCast(stmt)));
    try testing.expect(output.nodes.items.len == 1);
    try testing.expect(output.nodes.items[0] == .float_literal);
    const float_lit = output.nodes.items[0].float_literal;
    try testing.expect(float_lit.value == 3.14);
}

test "visit float literal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const float_lit = try allocator.create(nodes.FloatLiteral);
    float_lit.* = nodes.FloatLiteral.init(1, "test", 3.14);
    defer {
        float_lit.deinit(allocator);
        allocator.destroy(float_lit);
    }

    var comp = compiler.Compiler.init(&env, "test", allocator);
    defer comp.deinit();

    var frame = compiler.Frame.init("test", null, allocator);
    defer frame.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    var expr = nodes.Expression{ .float_literal = float_lit };
    const result = try comp.visitExpression(&expr, &frame, &ctx);
    defer result.deinit(allocator);

    try testing.expect(result == .float);
    try testing.expect(result.float == 3.14);
}

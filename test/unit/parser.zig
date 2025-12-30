const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const parser = vibe_jinja.parser;
const lexer = vibe_jinja.lexer;
const nodes = vibe_jinja.nodes;

test "parse plain text" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "Hello, World!";
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
    try testing.expectEqualStrings("Hello, World!", output.content);
}

test "parse string literal expression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ 'hello' }}";
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
    try testing.expect(output.nodes.items[0] == .string_literal);
}

test "parse integer literal expression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ 42 }}";
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
    try testing.expect(output.nodes.items[0] == .integer_literal);
    const int_lit = output.nodes.items[0].integer_literal;
    try testing.expect(int_lit.value == 42);
}

test "parse boolean literal expression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ true }}";
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
    try testing.expect(output.nodes.items[0] == .boolean_literal);
    const bool_lit = output.nodes.items[0].boolean_literal;
    try testing.expect(bool_lit.value == true);
}

test "parse name expression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ name }}";
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
    try testing.expect(output.nodes.items[0] == .name);
    const name_expr = output.nodes.items[0].name;
    try testing.expectEqualStrings("name", name_expr.name);
}

test "parse binary addition expression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ 1 + 2 }}";
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
    try testing.expect(output.nodes.items[0] == .bin_expr);
    const bin_expr = output.nodes.items[0].bin_expr;
    try testing.expect(bin_expr.op == .ADD);
}

test "parse filter expression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ 'hello' | upper }}";
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
    try testing.expect(output.nodes.items[0] == .filter);
    const filter_expr = output.nodes.items[0].filter;
    try testing.expectEqualStrings("upper", filter_expr.name);
}

test "parse comment" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{# This is a comment #}";
    var lex = lexer.Lexer.init(&env, source, "test");
    const stream = try lex.tokenize(allocator);
    defer allocator.free(stream.tokens);

    var p = parser.Parser.init(&env, stream, "test", allocator);
    const template = try p.parse();
    defer {
        template.deinit(allocator);
        allocator.destroy(template);
    }

    // Comments don't produce output statements
    try testing.expect(template.body.items.len == 0);
}

test "parse autoescape block" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% autoescape true %}Hello{% endautoescape %}";
    var lex = lexer.Lexer.init(&env, source, "test");
    const stream = try lex.tokenize(allocator);
    defer allocator.free(stream.tokens);

    var p = parser.Parser.init(&env, stream, "test", allocator);
    const template = try p.parse();
    defer {
        template.deinit(allocator);
        allocator.destroy(template);
    }

    // Should have one autoescape statement
    try testing.expect(template.body.items.len == 1);
    const stmt = template.body.items[0];
    try testing.expect(stmt.tag == .autoescape);
    
    // Cast to Autoescape to check internals
    const autoescape_stmt = @as(*nodes.Autoescape, @ptrCast(@alignCast(stmt)));
    
    // Check that the enabled expression is a boolean literal (true)
    try testing.expect(autoescape_stmt.enabled == .boolean_literal);
    try testing.expect(autoescape_stmt.enabled.boolean_literal.value == true);
    
    // Check that body has one item (the "Hello" text)
    try testing.expect(autoescape_stmt.body.items.len == 1);
}

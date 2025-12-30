const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const parser = vibe_jinja.parser;
const lexer = vibe_jinja.lexer;
const nodes = vibe_jinja.nodes;

test "autoescape block parses correctly with true" {
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
    
    // Check that body has content
    try testing.expect(autoescape_stmt.body.items.len == 1);
}

test "autoescape block parses correctly with false" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% autoescape false %}World{% endautoescape %}";
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
    try testing.expect(stmt.tag == .autoescape);
    
    const autoescape_stmt = @as(*nodes.Autoescape, @ptrCast(@alignCast(stmt)));
    try testing.expect(autoescape_stmt.enabled == .boolean_literal);
    try testing.expect(autoescape_stmt.enabled.boolean_literal.value == false);
}

test "autoescape block parses with expression output inside" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% autoescape true %}{{ name }}{% endautoescape %}";
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
    try testing.expect(stmt.tag == .autoescape);
    
    const autoescape_stmt = @as(*nodes.Autoescape, @ptrCast(@alignCast(stmt)));
    
    // Body should have the {{ name }} expression output
    try testing.expect(autoescape_stmt.body.items.len == 1);
    try testing.expect(autoescape_stmt.body.items[0].tag == .output);
}

test "autoescape block parses with mixed content" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% autoescape true %}Hello {{ name }}!{% endautoescape %}";
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
    try testing.expect(stmt.tag == .autoescape);
    
    const autoescape_stmt = @as(*nodes.Autoescape, @ptrCast(@alignCast(stmt)));
    
    // Body should have: "Hello ", {{ name }}, "!"
    try testing.expect(autoescape_stmt.body.items.len == 3);
}

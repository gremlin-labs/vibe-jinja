const std = @import("std");
const Token = @import("lexer.zig").Token;
const TokenKind = @import("lexer.zig").TokenKind;
const TokenStream = @import("lexer.zig").TokenStream;
const exceptions = @import("exceptions.zig");
const nodes = @import("nodes.zig");
const environment = @import("environment.zig");

/// Parser for Jinja templates
/// Converts tokens into an AST (Abstract Syntax Tree)
pub const Parser = struct {
    environment: *environment.Environment,
    stream: TokenStream,
    filename: ?[]const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize parser with environment and token stream
    pub fn init(env: *environment.Environment, stream: TokenStream, filename: ?[]const u8, allocator: std.mem.Allocator) Self {
        return Self{
            .environment = env,
            .stream = stream,
            .filename = filename,
            .allocator = allocator,
        };
    }

    /// Parse the template and return the AST root node
    /// Includes error recovery - skips to next statement boundary on error
    pub fn parse(self: *Self) !*nodes.Template {
        const template = try self.allocator.create(nodes.Template);
        template.* = nodes.Template.init(self.allocator, 1, self.filename);

        // Parse all statements until EOF
        while (self.stream.hasNext()) {
            // Try to parse statement with error recovery
            if (self.parseStatement()) |stmt_opt| {
                if (stmt_opt) |stmt| {
                    try template.body.append(self.allocator, stmt);
                }
            } else |err| {
                // On error, try to recover by skipping to next statement boundary
                switch (err) {
                    exceptions.TemplateError.SyntaxError => {
                        self.recoverToNextStatement();
                    },
                    else => return err,
                }
            }

            // Check if we're at EOF
            const token = self.stream.current();
            if (token == null or token.?.kind == .EOF) {
                break;
            }
            // Skip whitespace and continue
            self.skipWhitespace();
            if (!self.stream.hasNext()) {
                break;
            }
        }

        return template;
    }

    /// Error recovery: skip to next statement boundary
    /// This allows parsing to continue after syntax errors
    fn recoverToNextStatement(self: *Self) void {
        while (self.stream.hasNext()) {
            const token = self.stream.current() orelse break;

            // Stop at statement boundaries
            if (token.kind == .BLOCK_BEGIN or
                token.kind == .VARIABLE_BEGIN or
                token.kind == .COMMENT_BEGIN or
                token.kind == .EOF)
            {
                break;
            }

            _ = self.stream.next();
        }
    }

    /// Parse a statement
    /// Returns null on EOF or when no statement can be parsed
    /// Returns error on syntax errors (caller should use error recovery)
    fn parseStatement(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?*nodes.Stmt {
        // Skip whitespace
        self.skipWhitespace();

        if (!self.stream.hasNext()) {
            return null;
        }

        const token = self.stream.current() orelse return null;

        // Check for line comment
        if (token.kind == .LINECOMMENT) {
            // Line comments don't produce output, just skip them
            _ = self.stream.next();
            return null;
        }

        // Check for comment
        if (token.kind == .COMMENT_BEGIN) {
            // Parse comment (comments don't produce output, just skip them)
            try self.parseComment();
            return null; // Comments don't produce output
        }

        // Check for raw block
        if (token.kind == .RAW_BEGIN) {
            return try self.parseRawBlock();
        }

        // Check for block statements
        if (token.kind == .BLOCK_BEGIN) {
            _ = self.stream.next();
            self.skipWhitespace();

            const name_token = self.stream.current();
            if (name_token) |nt| {
                if (nt.kind == .FOR) {
                    // Parse for loop and return as statement
                    const for_stmt = try self.parseFor();
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(for_stmt)));
                } else if (nt.kind == .IF) {
                    // Parse if statement and return as statement
                    const if_stmt = try self.parseIf();
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(if_stmt)));
                } else if (nt.kind == .CONTINUE) {
                    // Parse continue statement
                    const continue_stmt = try self.parseContinue();
                    // ContinueStmt has no fields beyond base, but use ptrCast for consistency
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(continue_stmt)));
                } else if (nt.kind == .BREAK) {
                    // Parse break statement
                    const break_stmt = try self.parseBreak();
                    // BreakStmt has no fields beyond base, but use ptrCast for consistency
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(break_stmt)));
                } else if (nt.kind == .DO) {
                    // Parse do statement (expression statement)
                    const do_stmt = try self.parseDo();
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(do_stmt)));
                } else if (nt.kind == .DEBUG) {
                    // Parse debug statement
                    const debug_stmt = try self.parseDebug();
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(debug_stmt)));
                } else if (nt.kind == .EXTENDS) {
                    // Parse extends statement
                    const extends_stmt = try self.parseExtends();
                    // Return pointer to full struct - the base field is at offset 0
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(extends_stmt)));
                } else if (nt.kind == .BLOCK) {
                    // Parse block statement
                    const block_stmt = try self.parseBlock();
                    // Return pointer to full struct - the base field is at offset 0
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(block_stmt)));
                } else if (nt.kind == .INCLUDE) {
                    // Parse include statement
                    const include_stmt = try self.parseInclude();
                    // Return pointer to full struct - the base field is at offset 0
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(include_stmt)));
                } else if (nt.kind == .IMPORT) {
                    // Parse import statement
                    const import_stmt = try self.parseImport();
                    // Return pointer to full struct - the base field is at offset 0
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(import_stmt)));
                } else if (nt.kind == .FROM) {
                    // Parse from import statement
                    const from_import_stmt = try self.parseFromImport();
                    // Return pointer to full struct - the base field is at offset 0
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(from_import_stmt)));
                } else if (nt.kind == .MACRO) {
                    // Parse macro statement
                    const macro_stmt = try self.parseMacro();
                    // Return pointer to full struct - the base field is at offset 0
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(macro_stmt)));
                } else if (nt.kind == .CALL) {
                    // Check if this is a call block ({% call macro() %}{% endcall %})
                    // by looking ahead for BLOCK_END (call statement) vs checking for endcall
                    // For now, parse as regular call - call blocks will be handled separately
                    // when we see {% call ... %} followed by body and {% endcall %}
                    const call_stmt = try self.parseCall();
                    // Return pointer to full struct - the base field is at offset 0
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(call_stmt)));
                } else if (nt.kind == .SET) {
                    // Parse set statement
                    const set_stmt = try self.parseSet();
                    // Return pointer to full struct - the base field is at offset 0
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(set_stmt)));
                } else if (nt.kind == .WITH) {
                    // Parse with statement
                    const with_stmt = try self.parseWith();
                    // Return pointer to full struct - the base field is at offset 0
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(with_stmt)));
                } else if (nt.kind == .NAME) {
                    const name = nt.value;

                    // Check for filter block ({% filter filter_name %})
                    if (std.mem.eql(u8, name, "filter")) {
                        const filter_block_stmt = try self.parseFilterBlock();
                        // Return pointer to full struct - the base field is at offset 0
                        return @as(*nodes.Stmt, @ptrCast(@alignCast(filter_block_stmt)));
                    }

                    // Check for autoescape block ({% autoescape true %}{% endautoescape %})
                    if (std.mem.eql(u8, name, "autoescape")) {
                        const autoescape_stmt = try self.parseAutoescape();
                        // Return pointer to full struct - the base field is at offset 0
                        return @as(*nodes.Stmt, @ptrCast(@alignCast(autoescape_stmt)));
                    }

                    // Check for call block ({% call macro() %}{% endcall %})
                    if (std.mem.eql(u8, name, "call")) {
                        const call_block_stmt = try self.parseCallBlock();
                        // Return pointer to full struct - the base field is at offset 0
                        return @as(*nodes.Stmt, @ptrCast(@alignCast(call_block_stmt)));
                    }

                    // Check if this is an extension tag
                    if (self.environment.extension_registry) |registry| {
                        // Try to get tag name
                        if (nt.kind == .NAME) {
                            const tag_name = nt.value;
                            if (registry.handlesTag(tag_name)) {
                                // Parse extension tag
                                if (try registry.parseTag(self, tag_name)) |stmt| {
                                    return stmt;
                                }
                            }
                        }
                    }

                    // Unknown block statement
                    return null;
                }
            }
        }

        // Check for variable output
        if (token.kind == .VARIABLE_BEGIN) {
            const output = try self.parseVariableOutput();
            if (output) |out| {
                // Output extends Stmt, so we can cast it
                return @as(*nodes.Stmt, @ptrCast(@alignCast(out)));
            }
            return null;
        }

        // Parse plain text
        return try self.parsePlainText();
    }

    /// Parse raw block ({% raw %}...{% endraw %})
    fn parseRawBlock(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?*nodes.Stmt {
        const raw_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next(); // consume RAW_BEGIN

        // Collect raw content until RAW_END
        var content = std.ArrayList(u8){};
        defer content.deinit(self.allocator);

        while (self.stream.hasNext()) {
            const token = self.stream.current() orelse break;

            if (token.kind == .RAW_END) {
                _ = self.stream.next();
                break;
            }

            // Collect all tokens as raw content
            if (token.kind == .DATA) {
                try content.appendSlice(self.allocator, token.value);
            }
            _ = self.stream.next();
        }

        // Create output node with raw content
        const owned_content = try content.toOwnedSlice(self.allocator);
        defer self.allocator.free(owned_content);
        
        const output = try self.allocator.create(nodes.Output);
        output.* = try nodes.Output.initPlainText(self.allocator, owned_content, raw_token.lineno, raw_token.filename);
        // Output extends Stmt, so we can cast it
        return @as(*nodes.Stmt, @ptrCast(@alignCast(output)));
    }

    /// Parse comment statement (just skip it, don't create a node)
    fn parseComment(self: *Self) !void {
        const start_token = self.stream.current() orelse return;

        if (start_token.kind != .COMMENT_BEGIN) {
            return;
        }

        _ = self.stream.next();

        // Skip until COMMENT_END
        while (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .COMMENT_END) {
                    _ = self.stream.next();
                    return;
                }
            }
            _ = self.stream.next();
        }

        // Unterminated comment
        return exceptions.TemplateError.SyntaxError;
    }

    /// Parse variable output (expressions)
    fn parseVariableOutput(self: *Self) !?*nodes.Output {
        const start_token = self.stream.current() orelse return null;

        if (start_token.kind != .VARIABLE_BEGIN) {
            return null;
        }

        _ = self.stream.next();
        self.skipWhitespace();

        // Parse expression
        const expr = try self.parseExpression() orelse return null;

        self.skipWhitespace();

        // Expect VARIABLE_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .VARIABLE_END) {
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        const output = try self.allocator.create(nodes.Output);
        output.* = nodes.Output.initExpression(self.allocator, start_token.lineno, start_token.filename);
        try output.nodes.append(self.allocator, expr);

        return output;
    }

    /// Parse plain text output
    fn parsePlainText(self: *Self) !?*nodes.Stmt {
        var text = std.ArrayList(u8){};
        defer text.deinit(self.allocator);

        const start_token = self.stream.current() orelse return null;
        const lineno = start_token.lineno;
        const filename = start_token.filename;

        while (self.stream.hasNext()) {
            const token = self.stream.current() orelse break;

            // Stop at any Jinja delimiter
            if (token.kind == .COMMENT_BEGIN or
                token.kind == .COMMENT_END or
                token.kind == .VARIABLE_BEGIN or
                token.kind == .VARIABLE_END or
                token.kind == .BLOCK_BEGIN or
                token.kind == .BLOCK_END)
            {
                break;
            }

            // Collect DATA and WHITESPACE tokens as plain text
            try text.appendSlice(self.allocator, token.value);
            _ = self.stream.next();
        }

        const content = try text.toOwnedSlice(self.allocator);
        if (content.len == 0) {
            self.allocator.free(content);
            return null;
        }

        const output = try self.allocator.create(nodes.Output);
        output.* = try nodes.Output.initPlainText(self.allocator, content, lineno, filename);
        // Note: initPlainText duplicates the content, so we free the original
        self.allocator.free(content);
        // Output extends Stmt, so we can cast it
        return @as(*nodes.Stmt, @ptrCast(@alignCast(output)));
    }

    /// Parse expression with operator precedence
    /// Expression precedence (lowest to highest):
    /// - or
    /// - and
    /// - not
    /// - compare (==, !=, <, <=, >, >=)
    /// - add/sub (+,-)
    /// - mul/div/mod/floordiv (*, /, %, //)
    /// - power (**)
    /// - unary (+,-,~)
    /// - primary (literals, names, calls, etc.)
    fn parseExpression(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        return try self.parseOr();
    }

    /// Parse OR expression (lowest precedence)
    fn parseOr(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        var left = try self.parseAnd() orelse return null;

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .OR) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const right = try self.parseAnd() orelse {
                        left.deinit(self.allocator);
                        return exceptions.TemplateError.SyntaxError;
                    };

                    // Create BinExpr node for OR
                    const bin_expr = try self.allocator.create(nodes.BinExpr);
                    bin_expr.* = nodes.BinExpr{
                        .base = nodes.Node{
                            .lineno = t.lineno,
                            .filename = t.filename,
                            .environment = self.environment,
                        },
                        .left = left,
                        .right = right,
                        .op = .OR,
                    };

                    left = nodes.Expression{ .bin_expr = bin_expr };
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        // Check for conditional expression (x if y else z) - lowest precedence
        if (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .IF) {
                    _ = self.stream.next();
                    self.skipWhitespace();

                    // Parse condition
                    const condition = try self.parseOr() orelse return exceptions.TemplateError.SyntaxError;

                    self.skipWhitespace();

                    // Expect 'else'
                    const else_token = self.stream.current();
                    if (else_token == null or else_token.?.kind != .ELSE) {
                        condition.deinit(self.allocator);
                        return exceptions.TemplateError.SyntaxError;
                    }
                    _ = self.stream.next();
                    self.skipWhitespace();

                    // Parse false branch
                    const false_expr = try self.parseOr() orelse {
                        condition.deinit(self.allocator);
                        return exceptions.TemplateError.SyntaxError;
                    };

                    // Create CondExpr node
                    const cond_expr = try self.allocator.create(nodes.CondExpr);
                    cond_expr.* = nodes.CondExpr.init(condition, left, false_expr, t.lineno, t.filename);

                    return nodes.Expression{ .cond_expr = cond_expr };
                }
            }
        }

        return left;
    }

    /// Parse AND expression
    fn parseAnd(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        var left = try self.parseNot() orelse return null;

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Stop if we see a pipe (filter operator) - filters have lower precedence
                if (t.kind == .PIPE) {
                    break;
                }
                if (t.kind == .AND) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const right = try self.parseNot() orelse {
                        left.deinit(self.allocator);
                        return exceptions.TemplateError.SyntaxError;
                    };

                    // Create BinExpr node for AND
                    const bin_expr = try self.allocator.create(nodes.BinExpr);
                    bin_expr.* = nodes.BinExpr{
                        .base = nodes.Node{
                            .lineno = t.lineno,
                            .filename = t.filename,
                            .environment = self.environment,
                        },
                        .left = left,
                        .right = right,
                        .op = .AND,
                    };

                    left = nodes.Expression{ .bin_expr = bin_expr };
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        return left;
    }

    /// Parse NOT expression
    fn parseNot(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        const token = self.stream.current();
        if (token) |t| {
            if (t.kind == .NOT) {
                _ = self.stream.next();
                self.skipWhitespace();
                const expr = try self.parseCompare() orelse return exceptions.TemplateError.SyntaxError;

                // Create UnaryExpr node for NOT
                const unary_expr = try self.allocator.create(nodes.UnaryExpr);
                unary_expr.* = nodes.UnaryExpr{
                    .base = nodes.Node{
                        .lineno = t.lineno,
                        .filename = t.filename,
                        .environment = self.environment,
                    },
                    .node = expr,
                    .op = .NOT,
                };

                return nodes.Expression{ .unary_expr = unary_expr };
            }
        }

        return try self.parseCompare();
    }

    /// Parse comparison expression
    fn parseCompare(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        var left = try self.parseAdd() orelse return null;

        // Parse comparison operators (==, !=, <, <=, >, >=, in, not in)
        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Handle 'not in' operator (two tokens)
                if (t.kind == .NOT) {
                    const not_token = t;
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const next_token = self.stream.current();
                    if (next_token) |next| {
                        if (next.kind == .IN) {
                            // This is 'not in' - create IN expression and wrap in NOT
                            _ = self.stream.next();
                            self.skipWhitespace();
                            const right = try self.parseAdd() orelse {
                                // Clean up left before returning error
                                left.deinit(self.allocator);
                                return exceptions.TemplateError.SyntaxError;
                            };

                            // Create BinExpr node for 'in'
                            const bin_expr = try self.allocator.create(nodes.BinExpr);
                            bin_expr.* = nodes.BinExpr{
                                .base = nodes.Node{
                                    .lineno = not_token.lineno,
                                    .filename = not_token.filename,
                                    .environment = self.environment,
                                },
                                .left = left,
                                .right = right,
                                .op = .IN,
                            };

                            // Wrap in UnaryExpr(NOT) for 'not in'
                            const unary_expr = try self.allocator.create(nodes.UnaryExpr);
                            unary_expr.* = nodes.UnaryExpr{
                                .base = nodes.Node{
                                    .lineno = not_token.lineno,
                                    .filename = not_token.filename,
                                    .environment = self.environment,
                                },
                                .node = nodes.Expression{ .bin_expr = bin_expr },
                                .op = .NOT,
                            };

                            left = nodes.Expression{ .unary_expr = unary_expr };
                            continue;
                        } else {
                            // Not followed by 'in', so this is just a NOT operator
                            // Break and let parseNot handle it
                            break;
                        }
                    } else {
                        break;
                    }
                }

                // Handle 'in' operator
                if (t.kind == .IN) {
                    const op = t.kind;
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const right = try self.parseAdd() orelse {
                        // Clean up left before returning error
                        left.deinit(self.allocator);
                        return exceptions.TemplateError.SyntaxError;
                    };

                    // Create BinExpr node for 'in'
                    const bin_expr = try self.allocator.create(nodes.BinExpr);
                    bin_expr.* = nodes.BinExpr{
                        .base = nodes.Node{
                            .lineno = t.lineno,
                            .filename = t.filename,
                            .environment = self.environment,
                        },
                        .left = left,
                        .right = right,
                        .op = op,
                    };

                    left = nodes.Expression{ .bin_expr = bin_expr };
                    continue;
                }

                // Handle other comparison operators (==, !=, <, <=, >, >=)
                if (t.kind == .EQ or t.kind == .NE or t.kind == .LT or
                    t.kind == .LTEQ or t.kind == .GT or t.kind == .GTEQ)
                {
                    const op = t.kind;
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const right = try self.parseAdd() orelse {
                        // Clean up left before returning error
                        left.deinit(self.allocator);
                        return exceptions.TemplateError.SyntaxError;
                    };

                    // Create BinExpr node for comparison
                    const bin_expr = try self.allocator.create(nodes.BinExpr);
                    bin_expr.* = nodes.BinExpr{
                        .base = nodes.Node{
                            .lineno = t.lineno,
                            .filename = t.filename,
                            .environment = self.environment,
                        },
                        .left = left,
                        .right = right,
                        .op = op,
                    };

                    left = nodes.Expression{ .bin_expr = bin_expr };
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        // Parse test expressions (value is test)
        // Check if next token is 'is'
        if (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .IS) {
                    _ = self.stream.next();
                    self.skipWhitespace();

                    // Parse test name
                    const test_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
                    if (test_token.kind != .NAME) {
                        return exceptions.TemplateError.SyntaxError;
                    }
                    const test_name = test_token.value;
                    _ = self.stream.next();
                    self.skipWhitespace();

                    // Parse test arguments if present
                    var test_args = std.ArrayList(nodes.Expression).empty;
                    errdefer test_args.deinit(self.allocator);
                    errdefer {
                        for (test_args.items) |*arg| {
                            arg.deinit(self.allocator);
                        }
                        test_args.deinit(self.allocator);
                    }

                    // Check for arguments in parentheses
                    if (self.stream.hasNext()) {
                        const next_token = self.stream.current();
                        if (next_token) |next| {
                            if (next.kind == .LPAREN) {
                                _ = self.stream.next();
                                self.skipWhitespace();

                                // Parse argument list
                                while (self.stream.hasNext()) {
                                    const arg_token = self.stream.current();
                                    if (arg_token) |arg_t| {
                                        if (arg_t.kind == .RPAREN) {
                                            _ = self.stream.next();
                                            break;
                                        }
                                        if (arg_t.kind == .COMMA) {
                                            _ = self.stream.next();
                                            self.skipWhitespace();
                                            continue;
                                        }

                                        const arg_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                                        try test_args.append(self.allocator, arg_expr);

                                        self.skipWhitespace();
                                        const after_arg = self.stream.current();
                                        if (after_arg) |after| {
                                            if (after.kind == .RPAREN) {
                                                _ = self.stream.next();
                                                break;
                                            }
                                            if (after.kind != .COMMA) {
                                                return exceptions.TemplateError.SyntaxError;
                                            }
                                        }
                                    } else {
                                        break;
                                    }
                                }
                            }
                        }
                    }

                    // Create TestExpr node
                    const test_expr = try self.allocator.create(nodes.TestExpr);
                    test_expr.* = try nodes.TestExpr.init(self.allocator, left, test_name, t.lineno, t.filename);
                    test_expr.args = test_args;

                    return nodes.Expression{ .test_expr = test_expr };
                }
            }
        }

        // Parse filters on the result
        return try self.parseFilter(left);
    }

    /// Parse addition/subtraction expression
    fn parseAdd(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        var left = try self.parseMul() orelse return null;

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Stop if we see a pipe (filter operator) - filters have lower precedence
                if (t.kind == .PIPE) {
                    break;
                }
                if (t.kind == .ADD or t.kind == .SUB) {
                    const op = t.kind;
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const right = try self.parseMul() orelse {
                        left.deinit(self.allocator);
                        return exceptions.TemplateError.SyntaxError;
                    };

                    // Create BinExpr node
                    const bin_expr = try self.allocator.create(nodes.BinExpr);
                    bin_expr.* = nodes.BinExpr{
                        .base = nodes.Node{
                            .lineno = t.lineno,
                            .filename = t.filename,
                            .environment = self.environment,
                        },
                        .left = left,
                        .right = right,
                        .op = op,
                    };

                    left = nodes.Expression{ .bin_expr = bin_expr };
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        return left;
    }

    /// Parse multiplication/division/modulo expression
    fn parseMul(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        var left = try self.parsePower() orelse return null;

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Stop if we see a pipe (filter operator) - filters have lower precedence
                if (t.kind == .PIPE) {
                    break;
                }
                if (t.kind == .MUL or t.kind == .DIV or t.kind == .MOD or t.kind == .FLOORDIV) {
                    const op = t.kind;
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const right = try self.parsePower() orelse {
                        left.deinit(self.allocator);
                        return exceptions.TemplateError.SyntaxError;
                    };

                    // Create BinExpr node
                    const bin_expr = try self.allocator.create(nodes.BinExpr);
                    bin_expr.* = nodes.BinExpr{
                        .base = nodes.Node{
                            .lineno = t.lineno,
                            .filename = t.filename,
                            .environment = self.environment,
                        },
                        .left = left,
                        .right = right,
                        .op = op,
                    };

                    left = nodes.Expression{ .bin_expr = bin_expr };
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        return left;
    }

    /// Parse power expression
    fn parsePower(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        var left = try self.parseUnary() orelse return null;

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Stop if we see a pipe (filter operator) - filters have lower precedence
                if (t.kind == .PIPE) {
                    break;
                }
                if (t.kind == .POW) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const right = try self.parseUnary() orelse {
                        left.deinit(self.allocator);
                        return exceptions.TemplateError.SyntaxError;
                    };

                    // Create BinExpr node for power
                    const bin_expr = try self.allocator.create(nodes.BinExpr);
                    bin_expr.* = nodes.BinExpr{
                        .base = nodes.Node{
                            .lineno = t.lineno,
                            .filename = t.filename,
                            .environment = self.environment,
                        },
                        .left = left,
                        .right = right,
                        .op = .POW,
                    };

                    left = nodes.Expression{ .bin_expr = bin_expr };
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        return left;
    }

    /// Parse unary expression
    fn parseUnary(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        if (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .ADD or t.kind == .SUB or t.kind == .TILDE) {
                    const op = t.kind;
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const expr = try self.parsePrimary() orelse return exceptions.TemplateError.SyntaxError;

                    // Parse filters on the expression
                    const filtered_expr = try self.parseFilter(expr);

                    // Create UnaryExpr node
                    const unary_expr = try self.allocator.create(nodes.UnaryExpr);
                    unary_expr.* = nodes.UnaryExpr{
                        .base = nodes.Node{
                            .lineno = t.lineno,
                            .filename = t.filename,
                            .environment = self.environment,
                        },
                        .node = filtered_expr,
                        .op = op,
                    };

                    return nodes.Expression{ .unary_expr = unary_expr };
                }
            }
        }

        const primary_expr = try self.parsePrimary() orelse return null;
        // Parse filters on the primary expression
        return try self.parseFilter(primary_expr);
    }

    /// Parse primary expression (literals, names, calls, etc.)
    fn parsePrimary(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        if (!self.stream.hasNext()) {
            return null;
        }

        const token = self.stream.current() orelse return null;

        // Parse literals
        if (token.kind == .STRING) {
            return try self.parseStringLiteral();
        }

        if (token.kind == .INTEGER) {
            return try self.parseIntegerLiteral();
        }

        if (token.kind == .FLOAT) {
            return try self.parseFloatLiteral();
        }

        if (token.kind == .BOOLEAN) {
            return try self.parseBooleanLiteral();
        }

        if (token.kind == .NULL) {
            return try self.parseNullLiteral();
        }

        // Parse list literal [a, b, c]
        if (token.kind == .LBRACKET) {
            return try self.parseListLiteral();
        }

        // Parse name (variable reference) - may be followed by function call
        if (token.kind == .NAME) {
            const name_expr = try self.parseName();
            // Check if this is a function call (name followed by LPAREN)
            self.skipWhitespace();
            const next_token = self.stream.current();
            if (next_token) |nt| {
                if (nt.kind == .LPAREN) {
                    // Parse function call
                    if (name_expr) |expr| {
                        return try self.parseCallExpr(expr);
                    }
                }
            }
            return name_expr orelse return null;
        }

        // Parse parenthesized expression
        if (token.kind == .LPAREN) {
            _ = self.stream.next();
            self.skipWhitespace();
            const expr_opt = try self.parseExpression();
            const expr = expr_opt orelse return exceptions.TemplateError.SyntaxError;
            self.skipWhitespace();

            const end_token = self.stream.current();
            if (end_token == null or end_token.?.kind != .RPAREN) {
                return exceptions.TemplateError.SyntaxError;
            }
            _ = self.stream.next();

            // Check if this is a function call (parenthesized expr followed by LPAREN)
            self.skipWhitespace();
            const next_token = self.stream.current();
            if (next_token) |nt| {
                if (nt.kind == .LPAREN) {
                    // Parse function call
                    return try self.parseCallExpr(expr);
                }
            }
            return expr;
        }

        return null;
    }

    /// Parse function call expression (func(args))
    fn parseCallExpr(self: *Self, func_expr: nodes.Expression) (exceptions.TemplateError || std.mem.Allocator.Error)!nodes.Expression {
        const call_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next(); // consume LPAREN
        self.skipWhitespace();

        var args = std.ArrayList(nodes.Expression){};
        errdefer {
            for (args.items) |*arg| {
                arg.deinit(self.allocator);
            }
            args.deinit(self.allocator);
        }

        var kwargs = std.StringHashMap(nodes.Expression).init(self.allocator);
        errdefer {
            var kw_iter = kwargs.iterator();
            while (kw_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(self.allocator);
            }
            kwargs.deinit();
        }

        // Parse argument list
        while (self.stream.hasNext()) {
            const arg_token = self.stream.current();
            if (arg_token) |at| {
                if (at.kind == .RPAREN) {
                    _ = self.stream.next();
                    break;
                }

                // Check for keyword argument (name=value)
                if (at.kind == .NAME) {
                    const name_str = at.value;
                    _ = self.stream.next();
                    self.skipWhitespace();

                    const assign_token = self.stream.current();
                    if (assign_token) |ass_t| {
                        if (ass_t.kind == .ASSIGN) {
                            // Keyword argument
                            _ = self.stream.next();
                            self.skipWhitespace();
                            const kw_value = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                            const kw_name = try self.allocator.dupe(u8, name_str);
                            try kwargs.put(kw_name, kw_value);

                            self.skipWhitespace();
                            const next_token = self.stream.current();
                            if (next_token) |nt| {
                                if (nt.kind == .COMMA) {
                                    _ = self.stream.next();
                                    self.skipWhitespace();
                                    continue;
                                } else if (nt.kind == .RPAREN) {
                                    _ = self.stream.next();
                                    break;
                                }
                            }
                            continue;
                        }
                    }

                    // Positional argument - parse as expression starting from name
                    const name_expr_node = try self.allocator.create(nodes.Name);
                    name_expr_node.* = try nodes.Name.init(self.allocator, name_str, .load, at.lineno, at.filename);
                    const name_expr = nodes.Expression{ .name = name_expr_node };
                    try args.append(self.allocator, name_expr);

                    self.skipWhitespace();
                    const next_token = self.stream.current();
                    if (next_token) |nt| {
                        if (nt.kind == .COMMA) {
                            _ = self.stream.next();
                            self.skipWhitespace();
                            continue;
                        } else if (nt.kind == .RPAREN) {
                            _ = self.stream.next();
                            break;
                        }
                    }
                } else {
                    // Positional argument expression
                    const arg_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                    try args.append(self.allocator, arg_expr);

                    self.skipWhitespace();
                    const next_token = self.stream.current();
                    if (next_token) |nt| {
                        if (nt.kind == .COMMA) {
                            _ = self.stream.next();
                            self.skipWhitespace();
                            continue;
                        } else if (nt.kind == .RPAREN) {
                            _ = self.stream.next();
                            break;
                        }
                    }
                }
            } else {
                break;
            }
        }

        // Create CallExpr node
        const call_expr_node = try self.allocator.create(nodes.CallExpr);
        call_expr_node.* = nodes.CallExpr.init(self.allocator, func_expr, call_token.lineno, call_token.filename);

        // Move args to call_expr_node
        for (args.items) |arg| {
            try call_expr_node.args.append(self.allocator, arg);
        }
        args.deinit(self.allocator);

        // Move kwargs to call_expr_node
        var kw_iter = kwargs.iterator();
        while (kw_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            try call_expr_node.kwargs.put(key, value);
        }
        kwargs.deinit();

        return nodes.Expression{ .call_expr = call_expr_node };
    }

    /// Parse filter expression (applies filters to an expression)
    /// Filters are chained using the pipe operator (|)
    fn parseFilter(self: *Self, expr: nodes.Expression) (exceptions.TemplateError || std.mem.Allocator.Error)!nodes.Expression {
        var current_expr = expr;

        // Parse filter chain (expr | filter1 | filter2 ...)
        while (self.stream.hasNext()) {
            const token = self.stream.current() orelse break;

            if (token.kind != .PIPE) {
                break;
            }

            _ = self.stream.next();
            self.skipWhitespace();

            // Parse filter name
            const filter_name_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
            if (filter_name_token.kind != .NAME) {
                return exceptions.TemplateError.SyntaxError;
            }
            const filter_name = try self.allocator.dupe(u8, filter_name_token.value);
            errdefer self.allocator.free(filter_name);

            _ = self.stream.next();
            self.skipWhitespace();

            // Parse filter arguments (if any)
            var args = std.ArrayList(nodes.Expression){};
            errdefer {
                for (args.items) |*arg| {
                    arg.deinit(self.allocator);
                }
                args.deinit(self.allocator);
            }

            // Check for filter arguments (in parentheses)
            if (self.stream.hasNext()) {
                const next_token = self.stream.current();
                if (next_token) |nt| {
                    if (nt.kind == .LPAREN) {
                        _ = self.stream.next();
                        self.skipWhitespace();

                        // Parse argument list
                        while (self.stream.hasNext()) {
                            const arg_expr = try self.parseExpression();
                            if (arg_expr) |arg| {
                                try args.append(self.allocator, arg);
                                self.skipWhitespace();

                                // Check for comma or closing paren
                                const sep_token = self.stream.current();
                                if (sep_token) |st| {
                                    if (st.kind == .COMMA) {
                                        _ = self.stream.next();
                                        self.skipWhitespace();
                                        continue;
                                    } else if (st.kind == .RPAREN) {
                                        _ = self.stream.next();
                                        self.skipWhitespace();
                                        break;
                                    } else {
                                        return exceptions.TemplateError.SyntaxError;
                                    }
                                } else {
                                    return exceptions.TemplateError.SyntaxError;
                                }
                            } else {
                                // No more arguments
                                const close_token = self.stream.current();
                                if (close_token) |ct| {
                                    if (ct.kind == .RPAREN) {
                                        _ = self.stream.next();
                                        self.skipWhitespace();
                                        break;
                                    }
                                }
                                return exceptions.TemplateError.SyntaxError;
                            }
                        }
                    }
                }
            }

            // Create filter expression node
            const filter_node = try self.allocator.create(nodes.FilterExpr);
            filter_node.* = nodes.FilterExpr{
                .base = nodes.Node{
                    .lineno = filter_name_token.lineno,
                    .filename = filter_name_token.filename,
                    .environment = self.environment,
                },
                .node = current_expr,
                .name = filter_name,
                .args = args,
            };

            current_expr = nodes.Expression{ .filter = filter_node };
        }

        return current_expr;
    }

    /// Parse string literal
    fn parseStringLiteral(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        const token = self.stream.current() orelse return null;

        if (token.kind != .STRING) {
            return null;
        }

        _ = self.stream.next();

        // Extract string value (remove quotes)
        const token_value = token.value;
        var value: []const u8 = token_value;
        if (token_value.len >= 2 and
            ((token_value[0] == '\'' and token_value[token_value.len - 1] == '\'') or
                (token_value[0] == '"' and token_value[token_value.len - 1] == '"')))
        {
            value = token_value[1 .. token_value.len - 1];
        }

        const string_lit = try self.allocator.create(nodes.StringLiteral);
        string_lit.* = try nodes.StringLiteral.init(self.allocator, value, token.lineno, token.filename);

        return nodes.Expression{ .string_literal = string_lit };
    }

    /// Parse integer literal
    fn parseIntegerLiteral(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        const token = self.stream.current() orelse return null;

        if (token.kind != .INTEGER) {
            return null;
        }

        _ = self.stream.next();

        const int_value = std.fmt.parseInt(i64, token.value, 10) catch return null;

        const int_lit = try self.allocator.create(nodes.IntegerLiteral);
        int_lit.* = nodes.IntegerLiteral.init(token.lineno, token.filename, int_value);

        return nodes.Expression{ .integer_literal = int_lit };
    }

    /// Parse float literal
    fn parseFloatLiteral(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        const token = self.stream.current() orelse return null;

        if (token.kind != .FLOAT) {
            return null;
        }

        _ = self.stream.next();

        const float_value = std.fmt.parseFloat(f64, token.value) catch return null;

        // Create FloatLiteral node
        const float_lit = try self.allocator.create(nodes.FloatLiteral);
        float_lit.* = nodes.FloatLiteral.init(token.lineno, token.filename, float_value);

        return nodes.Expression{ .float_literal = float_lit };
    }

    /// Parse boolean literal
    fn parseBooleanLiteral(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        const token = self.stream.current() orelse return null;

        if (token.kind != .BOOLEAN) {
            return null;
        }

        _ = self.stream.next();

        const bool_value = std.mem.eql(u8, token.value, "true");

        const bool_lit = try self.allocator.create(nodes.BooleanLiteral);
        bool_lit.* = nodes.BooleanLiteral.init(token.lineno, token.filename, bool_value);

        return nodes.Expression{ .boolean_literal = bool_lit };
    }

    /// Parse null literal (null, none, None)
    fn parseNullLiteral(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        const token = self.stream.current() orelse return null;

        if (token.kind != .NULL) {
            return null;
        }

        _ = self.stream.next();

        const null_lit = try self.allocator.create(nodes.NullLiteral);
        null_lit.* = nodes.NullLiteral.init(token.lineno, token.filename);

        return nodes.Expression{ .null_literal = null_lit };
    }

    /// Parse list literal [a, b, c]
    fn parseListLiteral(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        const token = self.stream.current() orelse return null;

        if (token.kind != .LBRACKET) {
            return null;
        }

        _ = self.stream.next();
        self.skipWhitespace();

        const list_lit = try self.allocator.create(nodes.ListLiteral);
        list_lit.* = nodes.ListLiteral.init(token.lineno, token.filename);
        errdefer {
            list_lit.deinit(self.allocator);
            self.allocator.destroy(list_lit);
        }

        // Parse elements
        while (self.stream.hasNext()) {
            const elem_token = self.stream.current();
            if (elem_token) |et| {
                // Check for empty list or end of list
                if (et.kind == .RBRACKET) {
                    _ = self.stream.next();
                    return nodes.Expression{ .list_literal = list_lit };
                }

                // Parse element expression
                const elem = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                try list_lit.elements.append(self.allocator, elem);

                self.skipWhitespace();

                // Check for comma or end bracket
                const next_token = self.stream.current();
                if (next_token) |nt| {
                    if (nt.kind == .RBRACKET) {
                        _ = self.stream.next();
                        return nodes.Expression{ .list_literal = list_lit };
                    }
                    if (nt.kind == .COMMA) {
                        _ = self.stream.next();
                        self.skipWhitespace();
                        continue;
                    }
                }

                return exceptions.TemplateError.SyntaxError;
            } else {
                break;
            }
        }

        return exceptions.TemplateError.SyntaxError;
    }

    /// Parse name (variable reference)
    /// Parse name expression, including attribute and subscript access
    /// Handles: name, name.attr, name[index], name.attr[index], etc.
    fn parseName(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        const token = self.stream.current() orelse return null;

        if (token.kind != .NAME) {
            return null;
        }

        _ = self.stream.next();

        // Create initial name node
        const name_node = try self.allocator.create(nodes.Name);
        name_node.* = try nodes.Name.init(self.allocator, token.value, .load, token.lineno, token.filename);

        var current_expr: nodes.Expression = nodes.Expression{ .name = name_node };

        // Parse attribute access (.attr) and subscript access ([index])
        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const next_token = self.stream.current() orelse break;

            // Attribute access: .attr
            if (next_token.kind == .DOT) {
                _ = self.stream.next();
                self.skipWhitespace();

                const attr_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
                if (attr_token.kind != .NAME) {
                    return exceptions.TemplateError.SyntaxError;
                }
                _ = self.stream.next();

                const getattr_node = try self.allocator.create(nodes.Getattr);
                getattr_node.* = try nodes.Getattr.init(self.allocator, current_expr, attr_token.value, attr_token.lineno, attr_token.filename);

                current_expr = nodes.Expression{ .getattr = getattr_node };
            }
            // Subscript access: [index] or slice [start:stop:step]
            else if (next_token.kind == .LBRACKET) {
                _ = self.stream.next();
                self.skipWhitespace();

                // Check if this is slice syntax (starts with : or has : after expression)
                const first_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
                
                if (first_token.kind == .COLON) {
                    // Slice starting with : like [:stop] or [:]
                    const slice_expr = try self.parseSlice(null, next_token.lineno, next_token.filename);
                    
                    const getitem_node = try self.allocator.create(nodes.Getitem);
                    getitem_node.* = nodes.Getitem.init(current_expr, slice_expr, next_token.lineno, next_token.filename);
                    current_expr = nodes.Expression{ .getitem = getitem_node };
                } else {
                    // Parse first expression (could be index or slice start)
                    const first_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                    self.skipWhitespace();

                    const after_first = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
                    
                    if (after_first.kind == .COLON) {
                        // This is slice syntax [start:...]
                        const slice_expr = try self.parseSlice(first_expr, next_token.lineno, next_token.filename);
                        
                        const getitem_node = try self.allocator.create(nodes.Getitem);
                        getitem_node.* = nodes.Getitem.init(current_expr, slice_expr, next_token.lineno, next_token.filename);
                        current_expr = nodes.Expression{ .getitem = getitem_node };
                    } else if (after_first.kind == .RBRACKET) {
                        // Regular index access [index]
                        _ = self.stream.next();
                        
                        const getitem_node = try self.allocator.create(nodes.Getitem);
                        getitem_node.* = nodes.Getitem.init(current_expr, first_expr, next_token.lineno, next_token.filename);
                        current_expr = nodes.Expression{ .getitem = getitem_node };
                    } else {
                        return exceptions.TemplateError.SyntaxError;
                    }
                }
            } else {
                // Not an attribute or subscript access, stop parsing
                break;
            }
        }

        return current_expr;
    }

    /// Parse slice syntax [start:stop:step]
    /// Called when we've already parsed start (if any) and are at a colon
    /// Returns a Slice expression wrapped in Expression
    fn parseSlice(self: *Self, start: ?nodes.Expression, lineno: usize, filename: ?[]const u8) (exceptions.TemplateError || std.mem.Allocator.Error)!nodes.Expression {
        // We're at the first colon
        const colon_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (colon_token.kind != .COLON) {
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next(); // consume first colon
        self.skipWhitespace();

        // Parse stop expression (optional)
        var stop: ?nodes.Expression = null;
        const after_colon = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        
        if (after_colon.kind != .COLON and after_colon.kind != .RBRACKET) {
            // There's a stop expression
            stop = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
            self.skipWhitespace();
        }

        // Check for second colon (step)
        var step: ?nodes.Expression = null;
        const after_stop = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        
        if (after_stop.kind == .COLON) {
            _ = self.stream.next(); // consume second colon
            self.skipWhitespace();
            
            const after_second_colon = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
            if (after_second_colon.kind != .RBRACKET) {
                // There's a step expression
                step = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                self.skipWhitespace();
            }
        }

        // Expect closing bracket
        const end_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (end_token.kind != .RBRACKET) {
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        // Create Slice node
        const slice_node = try self.allocator.create(nodes.Slice);
        slice_node.* = nodes.Slice.init(start, stop, step, lineno, filename);
        
        return nodes.Expression{ .slice = slice_node };
    }

    /// Parse for loop statement
    fn parseFor(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.For {
        const for_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse target (variable name)
        const target_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (target_token.kind != .NAME) {
            return exceptions.TemplateError.SyntaxError;
        }
        const target_name = try self.allocator.dupe(u8, target_token.value);
        _ = self.stream.next();
        self.skipWhitespace();

        // Expect 'in'
        const in_token = self.stream.current();
        if (in_token == null or in_token.?.kind != .IN) {
            self.allocator.free(target_name);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse iterable expression
        const iter_expr = try self.parseExpression() orelse {
            self.allocator.free(target_name);
            return exceptions.TemplateError.SyntaxError;
        };

        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            // Clean up on error
            iter_expr.deinit(self.allocator);
            self.allocator.free(target_name);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        // Parse body (statements until {% endfor %})
        var body = std.ArrayList(*nodes.Stmt){};
        errdefer {
            for (body.items) |stmt| {
                stmt.deinit(self.allocator);
            }
            body.deinit(self.allocator);
        }

        var else_body = std.ArrayList(*nodes.Stmt){};
        errdefer {
            for (else_body.items) |stmt| {
                stmt.deinit(self.allocator);
            }
            else_body.deinit(self.allocator);
        }

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Check for {% endfor %} or {% else %}
                if (t.kind == .BLOCK_BEGIN) {
                    // Peek past BLOCK_BEGIN and any whitespace to find the keyword
                    var peek_offset: usize = 1;
                    while (self.stream.peek(peek_offset)) |pt| {
                        if (pt.kind != .WHITESPACE) break;
                        peek_offset += 1;
                    }
                    const next_token = self.stream.peek(peek_offset);
                    if (next_token) |nt| {
                        if (nt.kind == .ENDFOR) {
                            // Consume BLOCK_BEGIN, whitespace, ENDFOR, and BLOCK_END
                            _ = self.stream.next(); // consume BLOCK_BEGIN
                            self.skipWhitespace();
                            _ = self.stream.next(); // consume ENDFOR
                            self.skipWhitespace();
                            const block_end = self.stream.current();
                            if (block_end) |be| {
                                if (be.kind == .BLOCK_END) {
                                    _ = self.stream.next();
                                    break;
                                }
                            }
                        } else if (nt.kind == .ELSE) {
                            // Consume BLOCK_BEGIN, whitespace, and ELSE
                            _ = self.stream.next(); // consume BLOCK_BEGIN
                            self.skipWhitespace();
                            _ = self.stream.next(); // consume ELSE
                            self.skipWhitespace();
                            const block_end = self.stream.current();
                            if (block_end) |be| {
                                if (be.kind == .BLOCK_END) {
                                    _ = self.stream.next();

                                    // Parse else body until {% endfor %}
                                    while (self.stream.hasNext()) {
                                        self.skipWhitespace();
                                        const else_token = self.stream.current();
                                        if (else_token) |et| {
                                            if (et.kind == .BLOCK_BEGIN) {
                                                // Peek past BLOCK_BEGIN and whitespace
                                                var else_peek_offset: usize = 1;
                                                while (self.stream.peek(else_peek_offset)) |ept| {
                                                    if (ept.kind != .WHITESPACE) break;
                                                    else_peek_offset += 1;
                                                }
                                                const else_next_token = self.stream.peek(else_peek_offset);
                                                if (else_next_token) |ent| {
                                                    if (ent.kind == .ENDFOR) {
                                                        _ = self.stream.next(); // consume BLOCK_BEGIN
                                                        self.skipWhitespace();
                                                        _ = self.stream.next(); // consume ENDFOR
                                                        self.skipWhitespace();
                                                        const else_block_end = self.stream.current();
                                                        if (else_block_end) |ebe| {
                                                            if (ebe.kind == .BLOCK_END) {
                                                                _ = self.stream.next();
                                                                break;
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // Parse statement
                                        if (try self.parseStatement()) |stmt| {
                                            try else_body.append(self.allocator, stmt);
                                        } else {
                                            // Check if we're at EOF
                                            const eof_token = self.stream.current();
                                            if (eof_token == null or eof_token.?.kind == .EOF) {
                                                break;
                                            }
                                        }
                                    }
                                    break;
                                }
                            }
                        }
                        // If it's neither ENDFOR nor ELSE, fall through to parse the statement
                    }
                }
            }

            // Parse statement
            if (try self.parseStatement()) |stmt| {
                try body.append(self.allocator, stmt);
            } else {
                // Check if we're at EOF
                const eof_token = self.stream.current();
                if (eof_token == null or eof_token.?.kind == .EOF) {
                    break;
                }
            }
        }

        // Create For node
        const target_name_node = try self.allocator.create(nodes.Name);
        target_name_node.* = try nodes.Name.init(self.allocator, target_name, .store, for_token.lineno, for_token.filename);
        self.allocator.free(target_name);

        const for_node = try self.allocator.create(nodes.For);
        for_node.* = nodes.For.init(self.allocator, nodes.Expression{ .name = target_name_node }, iter_expr, for_token.lineno, for_token.filename);

        // Move body items to for_node
        for (body.items) |stmt| {
            try for_node.body.append(self.allocator, stmt);
        }
        body.deinit(self.allocator);

        // Move else body items to for_node
        for (else_body.items) |stmt| {
            try for_node.else_body.append(self.allocator, stmt);
        }
        else_body.deinit(self.allocator);

        return for_node;
    }

    /// Parse continue statement
    fn parseContinue(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.ContinueStmt {
        const continue_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        const continue_stmt = try self.allocator.create(nodes.ContinueStmt);
        continue_stmt.* = nodes.ContinueStmt.init(continue_token.lineno, continue_token.filename);
        return continue_stmt;
    }

    /// Parse break statement
    fn parseBreak(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.BreakStmt {
        const break_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        const break_stmt = try self.allocator.create(nodes.BreakStmt);
        break_stmt.* = nodes.BreakStmt.init(break_token.lineno, break_token.filename);
        return break_stmt;
    }

    /// Parse do statement (expression statement)
    /// {% do expression %}
    /// Evaluates the expression without producing output (for side effects)
    fn parseDo(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.ExprStmt {
        const do_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse the expression (can be a tuple/multiple expressions)
        const expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;

        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            expr.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        const do_stmt = try self.allocator.create(nodes.ExprStmt);
        do_stmt.* = nodes.ExprStmt.init(do_token.lineno, do_token.filename, expr);
        return do_stmt;
    }

    /// Parse debug statement
    /// {% debug %}
    /// Outputs debug information about context, filters, and tests
    fn parseDebug(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.DebugStmt {
        const debug_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Expect BLOCK_END (debug takes no arguments)
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        const debug_stmt = try self.allocator.create(nodes.DebugStmt);
        debug_stmt.* = nodes.DebugStmt.init(debug_token.lineno, debug_token.filename);
        return debug_stmt;
    }

    /// Parse extends statement
    fn parseExtends(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.Extends {
        const extends_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse template name expression
        const template_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;

        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            template_expr.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        const extends_stmt = try self.allocator.create(nodes.Extends);
        extends_stmt.* = nodes.Extends.init(self.allocator, template_expr, extends_token.lineno, extends_token.filename);

        return extends_stmt;
    }

    /// Parse block statement
    fn parseBlock(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.Block {
        const block_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse block name
        const name_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (name_token.kind != .NAME) {
            return exceptions.TemplateError.SyntaxError;
        }
        const block_name = try self.allocator.dupe(u8, name_token.value);
        errdefer self.allocator.free(block_name);
        _ = self.stream.next();
        self.skipWhitespace();

        // Check for modifiers (scoped, required)
        var scoped = false;
        var required = false;

        while (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .NAME) {
                    if (std.mem.eql(u8, t.value, "scoped")) {
                        scoped = true;
                        _ = self.stream.next();
                        self.skipWhitespace();
                    } else if (std.mem.eql(u8, t.value, "required")) {
                        required = true;
                        _ = self.stream.next();
                        self.skipWhitespace();
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            self.allocator.free(block_name);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        // Parse block body (statements until {% endblock %})
        var body = std.ArrayList(*nodes.Stmt){};
        errdefer {
            for (body.items) |stmt| {
                stmt.deinit(self.allocator);
            }
            body.deinit(self.allocator);
        }

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Check for {% endblock %}
                if (t.kind == .BLOCK_BEGIN) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const name_token_inner = self.stream.current();
                    if (name_token_inner) |nt| {
                        if (nt.kind == .ENDBLOCK) {
                            _ = self.stream.next();
                            self.skipWhitespace();
                            const block_end = self.stream.current();
                            if (block_end) |be| {
                                if (be.kind == .BLOCK_END) {
                                    _ = self.stream.next();
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            // Parse statement
            if (try self.parseStatement()) |stmt| {
                try body.append(self.allocator, stmt);
            } else {
                // Check if we're at EOF
                const eof_token = self.stream.current();
                if (eof_token == null or eof_token.?.kind == .EOF) {
                    break;
                }
            }
        }

        const block_stmt = try self.allocator.create(nodes.Block);
        block_stmt.* = try nodes.Block.init(self.allocator, block_name, block_token.lineno, block_token.filename);
        block_stmt.scoped = scoped;
        block_stmt.required = required;

        // Move body items to block_stmt
        for (body.items) |stmt| {
            try block_stmt.body.append(self.allocator, stmt);
        }
        body.deinit(self.allocator);

        return block_stmt;
    }

    /// Parse include statement
    fn parseInclude(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.Include {
        const include_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse template name expression
        const template_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;

        self.skipWhitespace();

        // Check for modifiers (with context, ignore missing)
        var with_context = true;
        var ignore_missing = false;

        while (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .NAME) {
                    if (std.mem.eql(u8, t.value, "with")) {
                        _ = self.stream.next();
                        self.skipWhitespace();
                        const context_token = self.stream.current();
                        if (context_token) |ct| {
                            if (ct.kind == .NAME and std.mem.eql(u8, ct.value, "context")) {
                                with_context = true;
                                _ = self.stream.next();
                                self.skipWhitespace();
                            }
                        }
                    } else if (std.mem.eql(u8, t.value, "ignore")) {
                        _ = self.stream.next();
                        self.skipWhitespace();
                        const missing_token = self.stream.current();
                        if (missing_token) |mt| {
                            if (mt.kind == .NAME and std.mem.eql(u8, mt.value, "missing")) {
                                ignore_missing = true;
                                _ = self.stream.next();
                                self.skipWhitespace();
                            }
                        }
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            template_expr.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        const include_stmt = try self.allocator.create(nodes.Include);
        include_stmt.* = nodes.Include.init(self.allocator, template_expr, include_token.lineno, include_token.filename);
        include_stmt.with_context = with_context;
        include_stmt.ignore_missing = ignore_missing;

        return include_stmt;
    }

    /// Parse import statement
    fn parseImport(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.Import {
        const import_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse template name expression
        const template_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;

        self.skipWhitespace();

        // Expect 'as'
        const as_token = self.stream.current();
        if (as_token == null or as_token.?.kind != .NAME or !std.mem.eql(u8, as_token.?.value, "as")) {
            template_expr.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse target name
        const target_token = self.stream.current();
        if (target_token == null or target_token.?.kind != .NAME) {
            template_expr.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        const target_name = try self.allocator.dupe(u8, target_token.?.value);
        errdefer self.allocator.free(target_name);
        _ = self.stream.next();
        self.skipWhitespace();

        // Check for 'with context' modifier
        var with_context = false;
        if (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .NAME and std.mem.eql(u8, t.value, "with")) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const context_token = self.stream.current();
                    if (context_token) |ct| {
                        if (ct.kind == .NAME and std.mem.eql(u8, ct.value, "context")) {
                            with_context = true;
                            _ = self.stream.next();
                            self.skipWhitespace();
                        }
                    }
                }
            }
        }

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            template_expr.deinit(self.allocator);
            self.allocator.free(target_name);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        const import_stmt = try self.allocator.create(nodes.Import);
        import_stmt.* = try nodes.Import.init(self.allocator, template_expr, target_name, import_token.lineno, import_token.filename);
        import_stmt.with_context = with_context;

        return import_stmt;
    }

    /// Parse from import statement
    fn parseFromImport(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.FromImport {
        const from_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse template name expression
        const template_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;

        self.skipWhitespace();

        // Expect 'import'
        const import_token = self.stream.current();
        if (import_token == null or import_token.?.kind != .IMPORT) {
            template_expr.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse import list
        var imports = std.ArrayList([]const u8){};
        errdefer {
            for (imports.items) |import_name| {
                self.allocator.free(import_name);
            }
            imports.deinit(self.allocator);
        }

        while (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .NAME) {
                    const import_name = try self.allocator.dupe(u8, t.value);
                    try imports.append(self.allocator, import_name);
                    _ = self.stream.next();
                    self.skipWhitespace();

                    // Check for comma or BLOCK_END
                    const next_token = self.stream.current();
                    if (next_token) |nt| {
                        if (nt.kind == .COMMA) {
                            _ = self.stream.next();
                            self.skipWhitespace();
                            continue;
                        } else if (nt.kind == .BLOCK_END) {
                            break;
                        }
                    }
                } else if (t.kind == .BLOCK_END) {
                    break;
                } else {
                    return exceptions.TemplateError.SyntaxError;
                }
            } else {
                break;
            }
        }

        // Check for 'with context' modifier
        var with_context = false;
        if (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .NAME and std.mem.eql(u8, t.value, "with")) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const context_token = self.stream.current();
                    if (context_token) |ct| {
                        if (ct.kind == .NAME and std.mem.eql(u8, ct.value, "context")) {
                            with_context = true;
                            _ = self.stream.next();
                            self.skipWhitespace();
                        }
                    }
                }
            }
        }

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            template_expr.deinit(self.allocator);
            for (imports.items) |import_name| {
                self.allocator.free(import_name);
            }
            imports.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        const from_import_stmt = try self.allocator.create(nodes.FromImport);
        from_import_stmt.* = nodes.FromImport.init(self.allocator, template_expr, from_token.lineno, from_token.filename);
        from_import_stmt.with_context = with_context;

        // Move imports to from_import_stmt
        for (imports.items) |import_name| {
            try from_import_stmt.imports.append(self.allocator, import_name);
        }
        imports.deinit(self.allocator);

        return from_import_stmt;
    }

    /// Parse macro statement
    fn parseMacro(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.Macro {
        const macro_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse macro name
        const name_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (name_token.kind != .NAME) {
            return exceptions.TemplateError.SyntaxError;
        }
        // Note: Don't dupe here - Macro.init will dupe the name
        const macro_name = name_token.value;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse macro arguments (optional)
        var args = std.ArrayList(nodes.MacroArg){};
        errdefer {
            for (args.items) |*arg| {
                arg.deinit(self.allocator);
            }
            args.deinit(self.allocator);
        }

        if (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .LPAREN) {
                    _ = self.stream.next();
                    self.skipWhitespace();

                    // Parse argument list
                    while (self.stream.hasNext()) {
                        const arg_token = self.stream.current();
                        if (arg_token) |at| {
                            if (at.kind == .RPAREN) {
                                _ = self.stream.next();
                                break;
                            }

                            if (at.kind == .NAME) {
                                // Note: Don't dupe here - MacroArg.init will dupe the name
                                const arg_name = at.value;
                                _ = self.stream.next();
                                self.skipWhitespace();

                                // Check for default value
                                var default_value: ?nodes.Expression = null;
                                if (self.stream.hasNext()) {
                                    const default_token = self.stream.current();
                                    if (default_token) |dt| {
                                        if (dt.kind == .ASSIGN) {
                                            _ = self.stream.next();
                                            self.skipWhitespace();
                                            default_value = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                                        }
                                    }
                                }

                                const macro_arg = try nodes.MacroArg.init(self.allocator, arg_name, default_value);
                                try args.append(self.allocator, macro_arg);

                                self.skipWhitespace();

                                // Check for comma or closing paren
                                const next_token = self.stream.current();
                                if (next_token) |nt| {
                                    if (nt.kind == .COMMA) {
                                        _ = self.stream.next();
                                        self.skipWhitespace();
                                        continue;
                                    } else if (nt.kind == .RPAREN) {
                                        _ = self.stream.next();
                                        break;
                                    }
                                }
                            } else {
                                return exceptions.TemplateError.SyntaxError;
                            }
                        } else {
                            break;
                        }
                    }
                }
            }
        }

        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            // macro_name is not allocated (it's a slice to token value)
            // but args are allocated and need cleanup
            for (args.items) |*arg| {
                arg.deinit(self.allocator);
            }
            args.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        // Parse macro body (statements until {% endmacro %})
        var body = std.ArrayList(*nodes.Stmt){};
        errdefer {
            for (body.items) |stmt| {
                stmt.deinit(self.allocator);
            }
            body.deinit(self.allocator);
        }

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Check for {% endmacro %}
                if (t.kind == .BLOCK_BEGIN) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const name_token_inner = self.stream.current();
                    if (name_token_inner) |nt| {
                        if (nt.kind == .ENDMACRO) {
                            _ = self.stream.next();
                            self.skipWhitespace();
                            const block_end = self.stream.current();
                            if (block_end) |be| {
                                if (be.kind == .BLOCK_END) {
                                    _ = self.stream.next();
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            // Parse statement
            if (try self.parseStatement()) |stmt| {
                try body.append(self.allocator, stmt);
            } else {
                // Check if we're at EOF
                const eof_token = self.stream.current();
                if (eof_token == null or eof_token.?.kind == .EOF) {
                    break;
                }
            }
        }

        const macro_stmt = try self.allocator.create(nodes.Macro);
        macro_stmt.* = try nodes.Macro.init(self.allocator, macro_name, macro_token.lineno, macro_token.filename);

        // Move args to macro_stmt
        for (args.items) |arg| {
            try macro_stmt.args.append(self.allocator, arg);
        }
        args.deinit(self.allocator);

        // Move body items to macro_stmt
        for (body.items) |stmt| {
            try macro_stmt.body.append(self.allocator, stmt);
        }
        body.deinit(self.allocator);

        // Detect if varargs or kwargs are used in the macro body
        // This is done by scanning for references to 'varargs' or 'kwargs' names
        macro_stmt.catch_varargs = self.containsNameReference(macro_stmt.body.items, "varargs");
        macro_stmt.catch_kwargs = self.containsNameReference(macro_stmt.body.items, "kwargs");

        return macro_stmt;
    }

    /// Check if any statement in the list references a given variable name
    fn containsNameReference(self: *Self, stmts: []*nodes.Stmt, name: []const u8) bool {
        _ = self;
        for (stmts) |stmt| {
            if (stmtContainsNameReference(stmt, name)) {
                return true;
            }
        }
        return false;
    }

    /// Parse call statement
    fn parseCall(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.Call {
        const call_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse macro name expression
        const macro_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;

        self.skipWhitespace();

        // Parse arguments (optional)
        var args = std.ArrayList(nodes.Expression){};
        errdefer {
            for (args.items) |*arg| {
                arg.deinit(self.allocator);
            }
            args.deinit(self.allocator);
        }

        var kwargs = std.StringHashMap(nodes.Expression).init(self.allocator);
        errdefer {
            var kw_iter = kwargs.iterator();
            while (kw_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(self.allocator);
            }
            kwargs.deinit();
        }

        if (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .LPAREN) {
                    _ = self.stream.next();
                    self.skipWhitespace();

                    // Parse argument list
                    while (self.stream.hasNext()) {
                        const arg_token = self.stream.current();
                        if (arg_token) |at| {
                            if (at.kind == .RPAREN) {
                                _ = self.stream.next();
                                break;
                            }

                            // Check for keyword argument (name=value)
                            if (at.kind == .NAME) {
                                const name_str = at.value;
                                _ = self.stream.next();
                                self.skipWhitespace();

                                const assign_token = self.stream.current();
                                if (assign_token) |ass_t| {
                                    if (ass_t.kind == .ASSIGN) {
                                        // Keyword argument
                                        _ = self.stream.next();
                                        self.skipWhitespace();
                                        const kw_value = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                                        const kw_name = try self.allocator.dupe(u8, name_str);
                                        try kwargs.put(kw_name, kw_value);

                                        self.skipWhitespace();
                                        const next_token = self.stream.current();
                                        if (next_token) |nt| {
                                            if (nt.kind == .COMMA) {
                                                _ = self.stream.next();
                                                self.skipWhitespace();
                                                continue;
                                            } else if (nt.kind == .RPAREN) {
                                                _ = self.stream.next();
                                                break;
                                            }
                                        }
                                        continue;
                                    }
                                }

                                // Positional argument - parse as expression starting from name
                                // We already consumed the name token, need to backtrack
                                // Create a name expression and parse from there
                                const name_expr_node = try self.allocator.create(nodes.Name);
                                name_expr_node.* = try nodes.Name.init(self.allocator, name_str, .load, at.lineno, at.filename);
                                const name_expr = nodes.Expression{ .name = name_expr_node };

                                // Check if this is part of a larger expression (like obj.method())
                                // For now, treat standalone name as a simple name expression
                                try args.append(self.allocator, name_expr);

                                self.skipWhitespace();
                                const next_token = self.stream.current();
                                if (next_token) |nt| {
                                    if (nt.kind == .COMMA) {
                                        _ = self.stream.next();
                                        self.skipWhitespace();
                                        continue;
                                    } else if (nt.kind == .RPAREN) {
                                        _ = self.stream.next();
                                        break;
                                    }
                                }
                            } else {
                                // Positional argument expression
                                const arg_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                                try args.append(self.allocator, arg_expr);

                                self.skipWhitespace();
                                const next_token = self.stream.current();
                                if (next_token) |nt| {
                                    if (nt.kind == .COMMA) {
                                        _ = self.stream.next();
                                        self.skipWhitespace();
                                        continue;
                                    } else if (nt.kind == .RPAREN) {
                                        _ = self.stream.next();
                                        break;
                                    }
                                }
                            }
                        } else {
                            break;
                        }
                    }
                }
            }
        }

        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            macro_expr.deinit(self.allocator);
            for (args.items) |*arg| {
                arg.deinit(self.allocator);
            }
            args.deinit(self.allocator);
            var kw_iter = kwargs.iterator();
            while (kw_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(self.allocator);
            }
            kwargs.deinit();
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        const call_stmt = try self.allocator.create(nodes.Call);
        call_stmt.* = nodes.Call.init(self.allocator, macro_expr, call_token.lineno, call_token.filename);

        // Move args to call_stmt
        for (args.items) |arg| {
            try call_stmt.args.append(self.allocator, arg);
        }
        args.deinit(self.allocator);

        // Move kwargs to call_stmt
        var kw_iter = kwargs.iterator();
        while (kw_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            try call_stmt.kwargs.put(key, value);
        }
        kwargs.deinit();

        return call_stmt;
    }

    /// Parse set statement
    fn parseSet(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.Set {
        const set_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse variable name
        const name_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (name_token.kind != .NAME) {
            return exceptions.TemplateError.SyntaxError;
        }
        // Note: Don't duplicate var_name here - Set.init will duplicate it internally
        const var_name = name_token.value;
        _ = self.stream.next();
        self.skipWhitespace();

        // Check for block variant ({% set x %}{% endset %})
        if (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .BLOCK_END) {
                    _ = self.stream.next();

                    // Parse block body
                    var body = std.ArrayList(*nodes.Stmt){};
                    errdefer {
                        for (body.items) |stmt| {
                            stmt.deinit(self.allocator);
                        }
                        body.deinit(self.allocator);
                    }

                    while (self.stream.hasNext()) {
                        self.skipWhitespace();
                        const body_token = self.stream.current();
                        if (body_token) |bt| {
                            if (bt.kind == .BLOCK_BEGIN) {
                                _ = self.stream.next();
                                self.skipWhitespace();
                                const name_token_inner = self.stream.current();
                                if (name_token_inner) |nt| {
                                    if (std.mem.eql(u8, nt.value, "endset")) {
                                        _ = self.stream.next();
                                        self.skipWhitespace();
                                        const block_end = self.stream.current();
                                        if (block_end) |be| {
                                            if (be.kind == .BLOCK_END) {
                                                _ = self.stream.next();
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Parse statement
                        if (try self.parseStatement()) |stmt| {
                            try body.append(self.allocator, stmt);
                        } else {
                            const eof_token = self.stream.current();
                            if (eof_token == null or eof_token.?.kind == .EOF) {
                                break;
                            }
                        }
                    }

                    // Create set block - for now, create a dummy expression
                    // In real implementation, we'd render the body to get the value
                    const dummy_expr_node = try self.allocator.create(nodes.StringLiteral);
                    dummy_expr_node.* = try nodes.StringLiteral.init(self.allocator, "", set_token.lineno, set_token.filename);
                    const dummy_expr = nodes.Expression{ .string_literal = dummy_expr_node };

                    const set_stmt = try self.allocator.create(nodes.Set);
                    set_stmt.* = try nodes.Set.init(self.allocator, var_name, dummy_expr, set_token.lineno, set_token.filename);
                    set_stmt.body = body;

                    return set_stmt;
                }
            }
        }

        // Regular set statement ({% set x = value %})
        // Expect ASSIGN
        const assign_token = self.stream.current();
        if (assign_token == null or assign_token.?.kind != .ASSIGN) {
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse value expression
        const value_expr = try self.parseExpression() orelse {
            return exceptions.TemplateError.SyntaxError;
        };

        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            value_expr.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        const set_stmt = try self.allocator.create(nodes.Set);
        set_stmt.* = try nodes.Set.init(self.allocator, var_name, value_expr, set_token.lineno, set_token.filename);

        return set_stmt;
    }

    /// Parse with statement
    fn parseWith(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.With {
        const with_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        const with_stmt = try self.allocator.create(nodes.With);
        with_stmt.* = nodes.With.init(self.allocator, with_token.lineno, with_token.filename);
        errdefer with_stmt.deinit(self.allocator);

        // Parse target variables and values
        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .BLOCK_END) {
                    _ = self.stream.next();
                    break;
                }

                // Parse target name
                if (t.kind == .NAME) {
                    const target_name = try self.allocator.dupe(u8, t.value);
                    errdefer self.allocator.free(target_name);
                    try with_stmt.targets.append(self.allocator, target_name);
                    _ = self.stream.next();
                    self.skipWhitespace();

                    // Expect ASSIGN
                    const assign_token = self.stream.current();
                    if (assign_token == null or assign_token.?.kind != .ASSIGN) {
                        return exceptions.TemplateError.SyntaxError;
                    }
                    _ = self.stream.next();
                    self.skipWhitespace();

                    // Parse value expression
                    const value_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                    try with_stmt.values.append(self.allocator, value_expr);

                    self.skipWhitespace();

                    // Check for comma or BLOCK_END
                    const next_token = self.stream.current();
                    if (next_token) |nt| {
                        if (nt.kind == .COMMA) {
                            _ = self.stream.next();
                            self.skipWhitespace();
                            continue;
                        } else if (nt.kind == .BLOCK_END) {
                            _ = self.stream.next();
                            break;
                        }
                    }
                } else {
                    return exceptions.TemplateError.SyntaxError;
                }
            } else {
                break;
            }
        }

        // Parse with body (statements until {% endwith %})
        var body = std.ArrayList(*nodes.Stmt){};
        errdefer {
            for (body.items) |stmt| {
                stmt.deinit(self.allocator);
            }
            body.deinit(self.allocator);
        }

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Check for {% endwith %}
                if (t.kind == .BLOCK_BEGIN) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const name_token_inner = self.stream.current();
                    if (name_token_inner) |nt| {
                        if (nt.kind == .ENDWITH) {
                            _ = self.stream.next();
                            self.skipWhitespace();
                            const block_end = self.stream.current();
                            if (block_end) |be| {
                                if (be.kind == .BLOCK_END) {
                                    _ = self.stream.next();
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            // Parse statement
            if (try self.parseStatement()) |stmt| {
                try body.append(self.allocator, stmt);
            } else {
                const eof_token = self.stream.current();
                if (eof_token == null or eof_token.?.kind == .EOF) {
                    break;
                }
            }
        }

        // Move body items to with_stmt
        for (body.items) |stmt| {
            try with_stmt.body.append(self.allocator, stmt);
        }
        body.deinit(self.allocator);

        return with_stmt;
    }

    /// Parse filter block statement
    fn parseFilterBlock(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.FilterBlock {
        const filter_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse filter expression
        const filter_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;

        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            filter_expr.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        // Parse filter block body (statements until {% endfilter %})
        var body = std.ArrayList(*nodes.Stmt){};
        errdefer {
            for (body.items) |stmt| {
                stmt.deinit(self.allocator);
            }
            body.deinit(self.allocator);
        }

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Check for {% endfilter %}
                if (t.kind == .BLOCK_BEGIN) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const name_token_inner = self.stream.current();
                    if (name_token_inner) |nt| {
                        if (std.mem.eql(u8, nt.value, "endfilter")) {
                            _ = self.stream.next();
                            self.skipWhitespace();
                            const block_end = self.stream.current();
                            if (block_end) |be| {
                                if (be.kind == .BLOCK_END) {
                                    _ = self.stream.next();
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            // Parse statement
            if (try self.parseStatement()) |stmt| {
                try body.append(self.allocator, stmt);
            } else {
                const eof_token = self.stream.current();
                if (eof_token == null or eof_token.?.kind == .EOF) {
                    break;
                }
            }
        }

        const filter_block_stmt = try self.allocator.create(nodes.FilterBlock);
        filter_block_stmt.* = nodes.FilterBlock.init(self.allocator, filter_expr, filter_token.lineno, filter_token.filename);

        // Move body items to filter_block_stmt
        for (body.items) |stmt| {
            try filter_block_stmt.body.append(self.allocator, stmt);
        }
        body.deinit(self.allocator);

        return filter_block_stmt;
    }

    /// Parse autoescape block statement ({% autoescape true %}{% endautoescape %})
    fn parseAutoescape(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.Autoescape {
        const autoescape_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next(); // consume "autoescape"
        self.skipWhitespace();

        // Parse autoescape expression (true/false or any expression that evaluates to bool)
        const autoescape_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;

        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            autoescape_expr.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        // Parse autoescape block body (statements until {% endautoescape %})
        var body = std.ArrayList(*nodes.Stmt){};
        errdefer {
            for (body.items) |stmt| {
                stmt.deinit(self.allocator);
            }
            body.deinit(self.allocator);
        }

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Check for {% endautoescape %}
                if (t.kind == .BLOCK_BEGIN) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const name_token_inner = self.stream.current();
                    if (name_token_inner) |nt| {
                        if (std.mem.eql(u8, nt.value, "endautoescape")) {
                            _ = self.stream.next();
                            self.skipWhitespace();
                            const block_end = self.stream.current();
                            if (block_end) |be| {
                                if (be.kind == .BLOCK_END) {
                                    _ = self.stream.next();
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            // Parse statement
            if (try self.parseStatement()) |stmt| {
                try body.append(self.allocator, stmt);
            } else {
                const eof_token = self.stream.current();
                if (eof_token == null or eof_token.?.kind == .EOF) {
                    break;
                }
            }
        }

        const autoescape_stmt = try self.allocator.create(nodes.Autoescape);
        autoescape_stmt.* = nodes.Autoescape.init(self.allocator, autoescape_expr, autoescape_token.lineno, autoescape_token.filename);

        // Move body items to autoescape_stmt
        for (body.items) |stmt| {
            try autoescape_stmt.body.append(self.allocator, stmt);
        }
        body.deinit(self.allocator);

        return autoescape_stmt;
    }

    /// Parse call block statement ({% call macro() %}{% endcall %})
    fn parseCallBlock(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.CallBlock {
        const call_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next(); // consume "call"
        self.skipWhitespace();

        // Parse call expression (macro name with optional arguments)
        const call_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;

        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            call_expr.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        // Parse call block body (statements until {% endcall %})
        var body = std.ArrayList(*nodes.Stmt){};
        errdefer {
            for (body.items) |stmt| {
                stmt.deinit(self.allocator);
            }
            body.deinit(self.allocator);
        }

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Check for {% endcall %} by peeking ahead
                if (t.kind == .BLOCK_BEGIN) {
                    // Peek at next token to see if it's "endcall"
                    if (self.stream.peek(1)) |next_tok| {
                        // Skip any whitespace tokens between BLOCK_BEGIN and name
                        var peek_offset: usize = 1;
                        var name_tok = next_tok;
                        while (name_tok.kind == .WHITESPACE) {
                            peek_offset += 1;
                            if (self.stream.peek(peek_offset)) |peeked| {
                                name_tok = peeked;
                            } else {
                                break;
                            }
                        }

                        if (std.mem.eql(u8, name_tok.value, "endcall")) {
                            // Now consume the tokens
                            _ = self.stream.next(); // consume BLOCK_BEGIN
                            self.skipWhitespace();
                            _ = self.stream.next(); // consume "endcall"
                            self.skipWhitespace();
                            const block_end = self.stream.current();
                            if (block_end) |be| {
                                if (be.kind == .BLOCK_END) {
                                    _ = self.stream.next();
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            // Parse statement
            if (try self.parseStatement()) |stmt| {
                try body.append(self.allocator, stmt);
            } else {
                const eof_token = self.stream.current();
                if (eof_token == null or eof_token.?.kind == .EOF) {
                    break;
                }
                // Advance the stream if parseStatement returned null to avoid infinite loop
                _ = self.stream.next();
            }
        }

        const call_block_stmt = try self.allocator.create(nodes.CallBlock);
        call_block_stmt.* = nodes.CallBlock.init(self.allocator, call_expr, call_token.lineno, call_token.filename);

        // Move body items to call_block_stmt
        for (body.items) |stmt| {
            try call_block_stmt.body.append(self.allocator, stmt);
        }
        body.deinit(self.allocator);

        return call_block_stmt;
    }

    /// Parse if statement
    fn parseIf(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!*nodes.If {
        const if_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Parse condition expression
        const condition = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;

        self.skipWhitespace();

        // Expect BLOCK_END
        const end_token = self.stream.current();
        if (end_token == null or end_token.?.kind != .BLOCK_END) {
            // Clean up on error
            condition.deinit(self.allocator);
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        // Parse body (statements until {% endif %} or {% elif %} or {% else %})
        // We track the main if body separately from the current parsing body
        var if_body = std.ArrayList(*nodes.Stmt){};
        var body = std.ArrayList(*nodes.Stmt){}; // Current body being parsed
        errdefer {
            for (if_body.items) |stmt| {
                stmt.deinit(self.allocator);
            }
            if_body.deinit(self.allocator);
            for (body.items) |stmt| {
                stmt.deinit(self.allocator);
            }
            body.deinit(self.allocator);
        }

        var elif_conditions = std.ArrayList(nodes.Expression){};
        var elif_bodies = std.ArrayList(std.ArrayList(*nodes.Stmt)){};
        var else_body = std.ArrayList(*nodes.Stmt){};
        var has_else = false;
        var if_body_saved = false; // Track if if_body has been saved

        errdefer {
            for (elif_conditions.items) |*expr| {
                expr.deinit(self.allocator);
            }
            elif_conditions.deinit(self.allocator);
            for (elif_bodies.items) |*elif_body| {
                for (elif_body.items) |stmt| {
                    stmt.deinit(self.allocator);
                }
                elif_body.deinit(self.allocator);
            }
            elif_bodies.deinit(self.allocator);
            for (else_body.items) |stmt| {
                stmt.deinit(self.allocator);
            }
            else_body.deinit(self.allocator);
        }

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current();
            if (token) |t| {
                // Check for {% endif %}, {% elif %}, or {% else %}
                if (t.kind == .BLOCK_BEGIN) {
                    // Peek past BLOCK_BEGIN and any whitespace to find the keyword
                    var peek_offset: usize = 1;
                    while (self.stream.peek(peek_offset)) |pt| {
                        if (pt.kind != .WHITESPACE) break;
                        peek_offset += 1;
                    }
                    const next_token = self.stream.peek(peek_offset);
                    if (next_token) |nt| {
                        if (nt.kind == .ENDIF) {
                            _ = self.stream.next(); // consume BLOCK_BEGIN
                            self.skipWhitespace();
                            _ = self.stream.next(); // consume ENDIF
                            self.skipWhitespace();
                            const block_end = self.stream.current();
                            if (block_end) |be| {
                                if (be.kind == .BLOCK_END) {
                                    _ = self.stream.next();
                                    break;
                                }
                            }
                        } else if (nt.kind == .ELIF) {
                            _ = self.stream.next(); // consume BLOCK_BEGIN
                            self.skipWhitespace();
                            _ = self.stream.next(); // consume ELIF
                            self.skipWhitespace();
                            const elif_condition = try self.parseExpression() orelse {
                                return exceptions.TemplateError.SyntaxError;
                            };
                            self.skipWhitespace();
                            const elif_end = self.stream.current();
                            if (elif_end == null or elif_end.?.kind != .BLOCK_END) {
                                // Clean up on error
                                elif_condition.deinit(self.allocator);
                                return exceptions.TemplateError.SyntaxError;
                            }
                            _ = self.stream.next();

                            // Save the if body first if this is the first elif
                            if (!if_body_saved) {
                                for (body.items) |stmt| {
                                    try if_body.append(self.allocator, stmt);
                                }
                                body.deinit(self.allocator);
                                body = std.ArrayList(*nodes.Stmt){};
                                if_body_saved = true;
                            } else {
                                // Save current body as elif body
                                try elif_bodies.append(self.allocator, body);
                                // Start new body for next elif
                                body = std.ArrayList(*nodes.Stmt){};
                            }

                            try elif_conditions.append(self.allocator, elif_condition);
                        } else if (nt.kind == .ELSE) {
                            _ = self.stream.next(); // consume BLOCK_BEGIN
                            self.skipWhitespace();
                            _ = self.stream.next(); // consume ELSE
                            self.skipWhitespace();
                            const else_end = self.stream.current();
                            if (else_end == null or else_end.?.kind != .BLOCK_END) {
                                return exceptions.TemplateError.SyntaxError;
                            }
                            _ = self.stream.next();

                            // Save current body (if body or last elif body)
                            if (elif_conditions.items.len > 0) {
                                // Save as the last elif body
                                try elif_bodies.append(self.allocator, body);
                            } else {
                                // Save as the main if body
                                for (body.items) |stmt| {
                                    try if_body.append(self.allocator, stmt);
                                }
                                body.deinit(self.allocator);
                                if_body_saved = true;
                            }

                            // Start new body for else
                            body = std.ArrayList(*nodes.Stmt){};
                            has_else = true;
                        }
                        // If it's neither ENDIF, ELIF, nor ELSE, fall through to parse the statement
                    }
                }
            }

            // Parse statement
            if (try self.parseStatement()) |stmt| {
                try body.append(self.allocator, stmt);
            } else {
                // Check if we're at EOF
                const eof_token = self.stream.current();
                if (eof_token == null or eof_token.?.kind == .EOF) {
                    break;
                }
            }
        }

        // Create If node
        const if_node = try self.allocator.create(nodes.If);
        if_node.* = nodes.If.init(self.allocator, condition, if_token.lineno, if_token.filename);

        // Move if body items to if_node
        if (if_body_saved) {
            // If body was saved when we saw ELIF or ELSE
            for (if_body.items) |stmt| {
                try if_node.body.append(self.allocator, stmt);
            }
            if_body.deinit(self.allocator);
        } else {
            // Simple if without ELIF or ELSE, body is still in `body`
            for (body.items) |stmt| {
                try if_node.body.append(self.allocator, stmt);
            }
            body.deinit(self.allocator);
        }

        // Move elif conditions and bodies
        for (elif_conditions.items) |expr| {
            try if_node.elif_conditions.append(self.allocator, expr);
        }
        elif_conditions.deinit(self.allocator);

        // Handle elif bodies - the last elif body might still be in `body` if we didn't see ELSE
        if (elif_conditions.items.len > 0 and !has_else and if_body_saved) {
            // The last elif body is still in `body`
            try elif_bodies.append(self.allocator, body);
        }

        for (elif_bodies.items) |*elif_body| {
            var new_body = std.ArrayList(*nodes.Stmt){};
            for (elif_body.items) |stmt| {
                try new_body.append(self.allocator, stmt);
            }
            try if_node.elif_bodies.append(self.allocator, new_body);
            elif_body.deinit(self.allocator);
        }
        elif_bodies.deinit(self.allocator);

        // Move else body if present
        if (has_else) {
            // Else body is in `body` (we reset body when we saw ELSE)
            for (body.items) |stmt| {
                try if_node.else_body.append(self.allocator, stmt);
            }
            body.deinit(self.allocator);
        }
        // Note: else_body ArrayList is no longer used, just deinit it
        else_body.deinit(self.allocator);

        return if_node;
    }

    /// Skip whitespace tokens
    fn skipWhitespace(self: *Self) void {
        while (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .WHITESPACE) {
                    _ = self.stream.next();
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }
};

/// Check if a statement or its children reference a given variable name
fn stmtContainsNameReference(stmt: *nodes.Stmt, name: []const u8) bool {
    return switch (stmt.tag) {
        .output => {
            const output = @as(*nodes.Output, @ptrCast(@alignCast(stmt)));
            for (output.nodes.items) |*expr| {
                if (exprContainsNameReference(expr, name)) {
                    return true;
                }
            }
            return false;
        },
        .for_loop => {
            const for_stmt = @as(*nodes.For, @ptrCast(@alignCast(stmt)));
            if (exprContainsNameReference(&for_stmt.iter, name)) return true;
            for (for_stmt.body.items) |s| {
                if (stmtContainsNameReference(s, name)) return true;
            }
            for (for_stmt.else_body.items) |s| {
                if (stmtContainsNameReference(s, name)) return true;
            }
            return false;
        },
        .if_stmt => {
            const if_stmt = @as(*nodes.If, @ptrCast(@alignCast(stmt)));
            if (exprContainsNameReference(&if_stmt.condition, name)) return true;
            for (if_stmt.body.items) |s| {
                if (stmtContainsNameReference(s, name)) return true;
            }
            for (if_stmt.elif_conditions.items) |*cond| {
                if (exprContainsNameReference(cond, name)) return true;
            }
            for (if_stmt.elif_bodies.items) |body| {
                for (body.items) |s| {
                    if (stmtContainsNameReference(s, name)) return true;
                }
            }
            for (if_stmt.else_body.items) |s| {
                if (stmtContainsNameReference(s, name)) return true;
            }
            return false;
        },
        .set => {
            const set_stmt = @as(*nodes.Set, @ptrCast(@alignCast(stmt)));
            if (exprContainsNameReference(&set_stmt.value, name)) return true;
            if (set_stmt.body) |*body| {
                for (body.items) |s| {
                    if (stmtContainsNameReference(s, name)) return true;
                }
            }
            return false;
        },
        .with => {
            const with_stmt = @as(*nodes.With, @ptrCast(@alignCast(stmt)));
            for (with_stmt.values.items) |*val| {
                if (exprContainsNameReference(val, name)) return true;
            }
            for (with_stmt.body.items) |s| {
                if (stmtContainsNameReference(s, name)) return true;
            }
            return false;
        },
        .filter_block => {
            const filter_block = @as(*nodes.FilterBlock, @ptrCast(@alignCast(stmt)));
            if (exprContainsNameReference(&filter_block.filter_expr, name)) return true;
            for (filter_block.body.items) |s| {
                if (stmtContainsNameReference(s, name)) return true;
            }
            return false;
        },
        .call => {
            const call_stmt = @as(*nodes.Call, @ptrCast(@alignCast(stmt)));
            if (exprContainsNameReference(&call_stmt.macro_expr, name)) return true;
            for (call_stmt.args.items) |*arg| {
                if (exprContainsNameReference(arg, name)) return true;
            }
            return false;
        },
        .expr_stmt => {
            const expr_stmt = @as(*nodes.ExprStmt, @ptrCast(@alignCast(stmt)));
            return exprContainsNameReference(&expr_stmt.node, name);
        },
        else => false,
    };
}

/// Check if an expression or its children reference a given variable name
fn exprContainsNameReference(expr: *const nodes.Expression, name: []const u8) bool {
    return switch (expr.*) {
        .name => |n| std.mem.eql(u8, n.name, name),
        .bin_expr => |b| exprContainsNameReference(&b.left, name) or exprContainsNameReference(&b.right, name),
        .unary_expr => |u| exprContainsNameReference(&u.node, name),
        .filter => |f| {
            if (exprContainsNameReference(&f.node, name)) return true;
            for (f.args.items) |*arg| {
                if (exprContainsNameReference(arg, name)) return true;
            }
            return false;
        },
        .getattr => |g| exprContainsNameReference(&g.node, name),
        .getitem => |g| exprContainsNameReference(&g.node, name) or exprContainsNameReference(&g.arg, name),
        .test_expr => |t| {
            if (exprContainsNameReference(&t.node, name)) return true;
            for (t.args.items) |*arg| {
                if (exprContainsNameReference(arg, name)) return true;
            }
            return false;
        },
        .cond_expr => |c| {
            return exprContainsNameReference(&c.condition, name) or
                exprContainsNameReference(&c.true_expr, name) or
                exprContainsNameReference(&c.false_expr, name);
        },
        .call_expr => |c| {
            if (exprContainsNameReference(&c.func, name)) return true;
            for (c.args.items) |*arg| {
                if (exprContainsNameReference(arg, name)) return true;
            }
            return false;
        },
        .list_literal => |l| {
            for (l.elements.items) |*elem| {
                if (exprContainsNameReference(elem, name)) return true;
            }
            return false;
        },
        .concat => |c| {
            for (c.nodes.items) |*node| {
                if (exprContainsNameReference(node, name)) return true;
            }
            return false;
        },
        else => false,
    };
}

/// Convenience function to parse tokens into a Template
pub fn parse(env: *environment.Environment, stream: TokenStream, filename: ?[]const u8, allocator: std.mem.Allocator) !*nodes.Template {
    var parser = Parser.init(env, stream, filename, allocator);
    return try parser.parse();
}

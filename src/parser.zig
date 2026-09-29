const std = @import("std");
const Token = @import("lexer.zig").Token;
const TokenKind = @import("lexer.zig").TokenKind;
const TokenStream = @import("lexer.zig").TokenStream;
const exceptions = @import("exceptions.zig");
const nodes = @import("nodes.zig");

pub const ParseError = exceptions.TemplateError || std.mem.Allocator.Error;

pub const ExtensionRegistryHandle = struct {
    ptr: *anyopaque,
    handlesTagFn: *const fn (*anyopaque, []const u8) bool,
    parseTagFn: *const fn (*anyopaque, *Parser, []const u8) ParseError!?*nodes.Stmt,

    pub fn handlesTag(self: ExtensionRegistryHandle, tag: []const u8) bool {
        return self.handlesTagFn(self.ptr, tag);
    }

    pub fn parseTag(self: ExtensionRegistryHandle, pars: *Parser, tag: []const u8) ParseError!?*nodes.Stmt {
        return try self.parseTagFn(self.ptr, pars, tag);
    }
};

/// Parser for Jinja templates
/// Converts tokens into an AST (Abstract Syntax Tree)
/// Maximum expression nesting depth accepted by the recursive-descent parser.
/// Bounds every downstream AST recursion; adversarially nested templates fail
/// with SyntaxError instead of exhausting the native stack.
const max_expr_depth: usize = 256;

pub const Parser = struct {
    environment: *anyopaque,
    extension_registry: ?ExtensionRegistryHandle,
    stream: TokenStream,
    filename: ?[]const u8,
    allocator: std.mem.Allocator,
    /// Current expression nesting depth (bounded by `max_expr_depth`).
    expr_depth: usize = 0,
    /// A for-loop iterable suppresses a conditional expression only at its
    /// outer parse depth; parenthesized and collection expressions retain it.
    conditional_expression_suppression_depth: ?usize = null,

    const Self = @This();

    /// Initialize parser with environment and token stream
    pub fn init(env: anytype, stream: TokenStream, filename: ?[]const u8, allocator: std.mem.Allocator) Self {
        const Env = @typeInfo(@TypeOf(env)).pointer.child;
        return Self{
            .environment = @ptrCast(env),
            .extension_registry = if (@hasDecl(Env, "parserExtensionRegistry"))
                env.parserExtensionRegistry()
            else
                null,
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
            const cursor_before = self.stream.cursor;

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

            // Guarantee forward progress: if neither the statement parse nor
            // error recovery consumed anything, drop one token instead of
            // spinning on it forever
            if (self.stream.cursor == cursor_before and self.stream.hasNext()) {
                _ = self.stream.next();
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

    /// Skip the remainder of a block statement, up to and including its BLOCK_END
    /// Stops early (without consuming) at the start of another statement or EOF
    fn skipToBlockEnd(self: *Self) void {
        while (self.stream.hasNext()) {
            const token = self.stream.current() orelse return;

            if (token.kind == .BLOCK_END) {
                _ = self.stream.next();
                return;
            }

            if (token.kind == .BLOCK_BEGIN or
                token.kind == .VARIABLE_BEGIN or
                token.kind == .COMMENT_BEGIN or
                token.kind == .EOF)
            {
                return;
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

        // Stray closing delimiters can never start a statement; consume them so
        // callers looping on parseStatement always make forward progress
        // (parsePlainText stops at them without consuming, which would spin forever)
        if (token.kind == .BLOCK_END or token.kind == .VARIABLE_END or
            token.kind == .COMMENT_END or token.kind == .RAW_END)
        {
            _ = self.stream.next();
            return null;
        }

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
                    // In Jinja2, {% call %} is always a call block with body until {% endcall %}
                    // Parse as CallBlock to properly handle caller() variable
                    const call_block_stmt = try self.parseCallBlock();
                    // Return pointer to full struct - the base field is at offset 0
                    return @as(*nodes.Stmt, @ptrCast(@alignCast(call_block_stmt)));
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

                    // Check if this is an extension tag
                    if (self.extension_registry) |registry| {
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

                    // Unknown block statement — skip the whole {% ... %} block so
                    // the caller's parse loop makes forward progress
                    self.skipToBlockEnd();
                    return null;
                }
            }

            // Orphaned or unrecognized block tag (e.g. a stray {% endif %} left
            // behind by error recovery) — skip it rather than spinning on it
            self.skipToBlockEnd();
            return null;
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
        var content = std.ArrayList(u8).empty;
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
        var text = std.ArrayList(u8).empty;
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
        if (self.expr_depth >= max_expr_depth) {
            return exceptions.TemplateError.SyntaxError;
        }
        self.expr_depth += 1;
        defer self.expr_depth -= 1;
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
                const conditional_allowed = self.conditional_expression_suppression_depth == null or
                    self.conditional_expression_suppression_depth.? != self.expr_depth;
                if (conditional_allowed and t.kind == .IF) {
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

    const ComparisonOperator = struct {
        token: Token,
        kind: TokenKind,
        negate: bool = false,
    };

    fn consumeComparisonOperator(self: *Self) ?ComparisonOperator {
        const token = self.stream.current() orelse return null;
        const simple = switch (token.kind) {
            .IN, .EQ, .NE, .LT, .LTEQ, .GT, .GTEQ => true,
            else => false,
        };
        if (simple) {
            _ = self.stream.next();
            return .{ .token = token, .kind = token.kind };
        }
        if (token.kind != .NOT) return null;

        var offset: usize = 1;
        while (self.stream.peek(offset)) |next| : (offset += 1) {
            if (next.kind == .WHITESPACE) continue;
            if (next.kind != .IN) return null;
            _ = self.stream.next();
            self.skipWhitespace();
            _ = self.stream.next();
            return .{ .token = token, .kind = .IN, .negate = true };
        }
        return null;
    }

    fn createBinary(self: *Self, left: nodes.Expression, right: nodes.Expression, op: TokenKind, token: Token) ParseError!nodes.Expression {
        const binary = self.allocator.create(nodes.BinExpr) catch |err| {
            var owned_left = left;
            var owned_right = right;
            owned_left.deinit(self.allocator);
            owned_right.deinit(self.allocator);
            return err;
        };
        binary.* = .{
            .base = .{ .lineno = token.lineno, .filename = token.filename, .environment = self.environment },
            .left = left,
            .right = right,
            .op = op,
        };
        return .{ .bin_expr = binary };
    }

    fn negateExpression(self: *Self, expression: nodes.Expression, token: Token) ParseError!nodes.Expression {
        const unary = self.allocator.create(nodes.UnaryExpr) catch |err| {
            var owned = expression;
            owned.deinit(self.allocator);
            return err;
        };
        unary.* = .{
            .base = .{ .lineno = token.lineno, .filename = token.filename, .environment = self.environment },
            .node = expression,
            .op = .NOT,
        };
        return .{ .unary_expr = unary };
    }

    fn parseParenthesizedArguments(self: *Self) ParseError!std.ArrayList(nodes.Expression) {
        var args = std.ArrayList(nodes.Expression).empty;
        errdefer {
            for (args.items) |*arg| arg.deinit(self.allocator);
            args.deinit(self.allocator);
        }

        const opening = self.stream.current() orelse return args;
        if (opening.kind != .LPAREN) return args;
        _ = self.stream.next();
        self.skipWhitespace();

        while (self.stream.hasNext()) {
            const token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
            if (token.kind == .RPAREN) {
                _ = self.stream.next();
                return args;
            }

            const argument = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
            try args.append(self.allocator, argument);
            self.skipWhitespace();

            const separator = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
            switch (separator.kind) {
                .COMMA => {
                    _ = self.stream.next();
                    self.skipWhitespace();
                },
                .RPAREN => {
                    _ = self.stream.next();
                    return args;
                },
                else => return exceptions.TemplateError.SyntaxError,
            }
        }
        return exceptions.TemplateError.SyntaxError;
    }

    fn parseTest(self: *Self, left: nodes.Expression) ParseError!nodes.Expression {
        const is_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        // Negated test: x is not none / x is not defined
        var negated = false;
        if (self.stream.current()) |maybe_not| {
            if (maybe_not.kind == .NOT) {
                negated = true;
                _ = self.stream.next();
                self.skipWhitespace();
            }
        }

        const name = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (name.kind != .NAME and name.kind != .IN and name.kind != .NULL and name.kind != .BOOLEAN) {
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();
        self.skipWhitespace();

        var args = try self.parseParenthesizedArguments();
        errdefer {
            for (args.items) |*arg| arg.deinit(self.allocator);
            args.deinit(self.allocator);
        }
        const test_expression = self.allocator.create(nodes.TestExpr) catch |err| {
            var owned_left = left;
            owned_left.deinit(self.allocator);
            return err;
        };
        test_expression.* = nodes.TestExpr.init(self.allocator, left, name.value, is_token.lineno, is_token.filename) catch |err| {
            self.allocator.destroy(test_expression);
            var owned_left = left;
            owned_left.deinit(self.allocator);
            return err;
        };
        test_expression.args = args;
        args = std.ArrayList(nodes.Expression).empty;
        const test_expr = nodes.Expression{ .test_expr = test_expression };
        if (negated) return try self.negateExpression(test_expr, is_token);
        return test_expr;
    }

    /// Parse comparison expression
    fn parseCompare(self: *Self) ParseError!?nodes.Expression {
        var left = try self.parseConcat() orelse return null;

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const comparison = self.consumeComparisonOperator() orelse break;
            self.skipWhitespace();
            const right = self.parseConcat() catch |err| {
                left.deinit(self.allocator);
                return err;
            } orelse {
                left.deinit(self.allocator);
                return exceptions.TemplateError.SyntaxError;
            };
            left = try self.createBinary(left, right, comparison.kind, comparison.token);
            if (comparison.negate) left = try self.negateExpression(left, comparison.token);
        }

        self.skipWhitespace();
        if (self.stream.current()) |token| {
            if (token.kind == .IS) return try self.parseTest(left);
        }
        return try self.parseFilter(left);
    }

    /// Parse Jinja's string concatenation operator (`~`).
    fn parseConcat(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        var left = try self.parseAdd() orelse return null;
        var concat: ?*nodes.Concat = null;
        errdefer if (concat) |node| {
            node.deinit(self.allocator);
            self.allocator.destroy(node);
        } else left.deinit(self.allocator);

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const token = self.stream.current() orelse break;
            if (token.kind != .TILDE) break;

            if (concat == null) {
                const node = try self.allocator.create(nodes.Concat);
                node.* = nodes.Concat.init(self.allocator, token.lineno, token.filename);
                node.nodes.append(self.allocator, left) catch |err| {
                    node.deinit(self.allocator);
                    self.allocator.destroy(node);
                    return err;
                };
                concat = node;
            }

            _ = self.stream.next();
            self.skipWhitespace();
            var right = try self.parseAdd() orelse return exceptions.TemplateError.SyntaxError;
            concat.?.nodes.append(self.allocator, right) catch |err| {
                right.deinit(self.allocator);
                return err;
            };
        }

        if (concat) |node| return .{ .concat = node };
        return left;
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

        // Parse the base expression, then apply postfix trailers
        // (.attr, [index], (args)) uniformly — trailers are valid after
        // names, literals, and parenthesized expressions alike
        const base: ?nodes.Expression = switch (token.kind) {
            .STRING => try self.parseStringLiteral(),
            .INTEGER => try self.parseIntegerLiteral(),
            .FLOAT => try self.parseFloatLiteral(),
            .BOOLEAN => try self.parseBooleanLiteral(),
            .NULL => try self.parseNullLiteral(),
            .LBRACKET => try self.parseListLiteral(),
            .NAME => try self.parseName(),
            .LPAREN => blk: {
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
                break :blk expr;
            },
            else => null,
        };

        if (base) |b| {
            return try self.parsePostfix(b);
        }
        return null;
    }

    /// Parse function call expression (func(args))
    fn parseCallExpr(self: *Self, func_expr: nodes.Expression) (exceptions.TemplateError || std.mem.Allocator.Error)!nodes.Expression {
        const call_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next(); // consume LPAREN
        self.skipWhitespace();

        var args = std.ArrayList(nodes.Expression).empty;
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

                // A keyword argument is the narrow `name = value` form. Save
                // and restore the cursor so positional expressions beginning
                // with a name still retain their trailers (`message.content`,
                // calls, subscripts, filters, and operators).
                var parsed_keyword = false;
                if (at.kind == .NAME) {
                    const argument_start = self.stream.cursor;
                    const name_str = at.value;
                    _ = self.stream.next();
                    self.skipWhitespace();
                    if (self.stream.current()) |assign_token| {
                        if (assign_token.kind == .ASSIGN) {
                            _ = self.stream.next();
                            self.skipWhitespace();
                            const kw_value = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                            const kw_name = try self.allocator.dupe(u8, name_str);
                            kwargs.put(kw_name, kw_value) catch |err| {
                                self.allocator.free(kw_name);
                                var owned_value = kw_value;
                                owned_value.deinit(self.allocator);
                                return err;
                            };
                            parsed_keyword = true;
                        }
                    }
                    if (!parsed_keyword) self.stream.cursor = argument_start;
                }

                if (!parsed_keyword) {
                    const arg_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                    try args.append(self.allocator, arg_expr);
                }

                self.skipWhitespace();
                const next_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
                if (next_token.kind == .COMMA) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    continue;
                }
                if (next_token.kind == .RPAREN) {
                    _ = self.stream.next();
                    break;
                }
                return exceptions.TemplateError.SyntaxError;
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
    /// Supports both positional args and kwargs: {{ value | filter(arg1, kwarg=value) }}
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
            var args = std.ArrayList(nodes.Expression).empty;
            errdefer {
                for (args.items) |*arg| {
                    arg.deinit(self.allocator);
                }
                args.deinit(self.allocator);
            }

            // Parse filter kwargs (if any)
            var kwargs = std.StringHashMap(nodes.Expression).init(self.allocator);
            errdefer {
                var iter = kwargs.iterator();
                while (iter.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.deinit(self.allocator);
                }
                kwargs.deinit();
            }

            // Check for filter arguments (in parentheses)
            if (self.stream.hasNext()) {
                const next_token = self.stream.current();
                if (next_token) |nt| {
                    if (nt.kind == .LPAREN) {
                        _ = self.stream.next();
                        self.skipWhitespace();

                        // Parse argument list (positional and keyword)
                        while (self.stream.hasNext()) {
                            // Check for closing paren first
                            const check_close = self.stream.current();
                            if (check_close) |cc| {
                                if (cc.kind == .RPAREN) {
                                    _ = self.stream.next();
                                    self.skipWhitespace();
                                    break;
                                }
                            }

                            // Check for kwarg: identifier followed by '='
                            const is_kwarg = blk: {
                                const cur = self.stream.current() orelse break :blk false;
                                if (cur.kind != .NAME) break :blk false;
                                // Peek at next token for '='
                                const saved_cursor = self.stream.cursor;
                                _ = self.stream.next();
                                self.skipWhitespace();
                                const peek = self.stream.current();
                                self.stream.cursor = saved_cursor; // restore
                                if (peek) |p| {
                                    break :blk p.kind == .ASSIGN;
                                }
                                break :blk false;
                            };

                            if (is_kwarg) {
                                // Parse kwarg: name = value
                                const kwarg_name_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
                                const kwarg_name = try self.allocator.dupe(u8, kwarg_name_token.value);
                                errdefer self.allocator.free(kwarg_name);
                                _ = self.stream.next();
                                self.skipWhitespace();
                                // Consume '='
                                const assign_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
                                if (assign_token.kind != .ASSIGN) {
                                    return exceptions.TemplateError.SyntaxError;
                                }
                                _ = self.stream.next();
                                self.skipWhitespace();
                                // Parse kwarg value expression
                                const kwarg_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                                try kwargs.put(kwarg_name, kwarg_expr);
                            } else {
                                // Parse positional argument
                                const arg_expr = try self.parseExpression();
                                if (arg_expr) |arg| {
                                    try args.append(self.allocator, arg);
                                } else {
                                    // No expression, check for closing paren
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
                .kwargs = kwargs,
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
    fn parseName(self: *Self) (exceptions.TemplateError || std.mem.Allocator.Error)!?nodes.Expression {
        const token = self.stream.current() orelse return null;

        if (token.kind != .NAME) {
            return null;
        }

        _ = self.stream.next();

        const name_node = try self.allocator.create(nodes.Name);
        name_node.* = try nodes.Name.init(self.allocator, token.value, .load, token.lineno, token.filename);

        return nodes.Expression{ .name = name_node };
    }

    /// Parse postfix trailers after any primary expression
    /// Handles chains of attribute access (.attr), subscript/slice ([i], [a:b]),
    /// and calls ((args)) on any base: names, literals, and call results alike,
    /// e.g. 'a b'.split(' ')[-1] or [1,2][0]
    fn parsePostfix(self: *Self, base: nodes.Expression) (exceptions.TemplateError || std.mem.Allocator.Error)!nodes.Expression {
        var current_expr: nodes.Expression = base;

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            const next_token = self.stream.current() orelse break;

            // Call: (args)
            if (next_token.kind == .LPAREN) {
                current_expr = try self.parseCallExpr(current_expr);
            }
            // Attribute access: .attr
            else if (next_token.kind == .DOT) {
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
                // Not a call, attribute, or subscript access, stop parsing
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

    const ParsedBody = struct {
        statements: std.ArrayList(*nodes.Stmt),
        terminator: TokenKind,

        fn deinit(self: *ParsedBody, allocator: std.mem.Allocator) void {
            for (self.statements.items) |stmt| stmt.deinit(allocator);
            self.statements.deinit(allocator);
        }
    };

    fn peekStatementTag(self: *Self) ?TokenKind {
        const current = self.stream.current() orelse return null;
        if (current.kind != .BLOCK_BEGIN) return null;
        var offset: usize = 1;
        while (self.stream.peek(offset)) |token| : (offset += 1) {
            if (token.kind != .WHITESPACE) return token.kind;
        }
        return null;
    }

    fn consumeStatementTag(self: *Self, expected: TokenKind) ParseError!void {
        const begin = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (begin.kind != .BLOCK_BEGIN) return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();
        const tag = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (tag.kind != expected) return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();
        const end = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (end.kind != .BLOCK_END) return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
    }

    fn isTerminator(kind: TokenKind, terminators: []const TokenKind) bool {
        for (terminators) |terminator| {
            if (kind == terminator) return true;
        }
        return false;
    }

    fn parseBodyUntil(self: *Self, terminators: []const TokenKind) ParseError!ParsedBody {
        var statements = std.ArrayList(*nodes.Stmt).empty;
        errdefer {
            for (statements.items) |stmt| stmt.deinit(self.allocator);
            statements.deinit(self.allocator);
        }

        while (self.stream.hasNext()) {
            self.skipWhitespace();
            if (self.peekStatementTag()) |tag| {
                if (isTerminator(tag, terminators)) {
                    try self.consumeStatementTag(tag);
                    return .{ .statements = statements, .terminator = tag };
                }
            }

            if (try self.parseStatement()) |stmt| {
                try statements.append(self.allocator, stmt);
                continue;
            }

            const token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
            if (token.kind == .EOF) return exceptions.TemplateError.SyntaxError;
            _ = self.stream.next();
        }
        return exceptions.TemplateError.SyntaxError;
    }

    /// Parse for loop statement
    fn parseFor(self: *Self) ParseError!*nodes.For {
        const for_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        const target_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (target_token.kind != .NAME) return exceptions.TemplateError.SyntaxError;
        const first_target = try self.allocator.create(nodes.Name);
        first_target.* = try nodes.Name.init(self.allocator, target_token.value, .store, target_token.lineno, target_token.filename);
        var target_expr = nodes.Expression{ .name = first_target };
        var target_moved = false;
        errdefer if (!target_moved) target_expr.deinit(self.allocator);
        _ = self.stream.next();
        self.skipWhitespace();

        if (self.stream.current()) |token| {
            if (token.kind == .COMMA) {
                const targets = try self.allocator.create(nodes.ListLiteral);
                targets.* = nodes.ListLiteral.init(target_token.lineno, target_token.filename);
                var targets_moved = false;
                errdefer if (!targets_moved) {
                    targets.deinit(self.allocator);
                    self.allocator.destroy(targets);
                };
                try targets.elements.append(self.allocator, target_expr);
                target_expr = .{ .list_literal = targets };
                targets_moved = true;

                while (self.stream.current()) |comma| {
                    if (comma.kind != .COMMA) break;
                    _ = self.stream.next();
                    self.skipWhitespace();
                    const name_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
                    if (name_token.kind != .NAME) return exceptions.TemplateError.SyntaxError;
                    const name = try self.allocator.create(nodes.Name);
                    name.* = try nodes.Name.init(self.allocator, name_token.value, .store, name_token.lineno, name_token.filename);
                    try targets.elements.append(self.allocator, .{ .name = name });
                    _ = self.stream.next();
                    self.skipWhitespace();
                }
            }
        }

        const in_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (in_token.kind != .IN) return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        const previous_suppression_depth = self.conditional_expression_suppression_depth;
        self.conditional_expression_suppression_depth = self.expr_depth + 1;
        var iter_expr = self.parseExpression() catch |err| {
            self.conditional_expression_suppression_depth = previous_suppression_depth;
            return err;
        } orelse {
            self.conditional_expression_suppression_depth = previous_suppression_depth;
            return exceptions.TemplateError.SyntaxError;
        };
        self.conditional_expression_suppression_depth = previous_suppression_depth;
        var iter_moved = false;
        errdefer if (!iter_moved) iter_expr.deinit(self.allocator);
        self.skipWhitespace();

        var test_expr: ?nodes.Expression = null;
        var test_moved = false;
        errdefer if (!test_moved) if (test_expr) |*expression| expression.deinit(self.allocator);
        if (self.stream.current()) |token| {
            if (token.kind == .IF) {
                _ = self.stream.next();
                self.skipWhitespace();
                test_expr = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                self.skipWhitespace();
            }
        }

        const header_end = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (header_end.kind != .BLOCK_END) return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();

        var body = try self.parseBodyUntil(&.{ .ELSE, .ENDFOR });
        errdefer body.deinit(self.allocator);
        var else_body = ParsedBody{ .statements = std.ArrayList(*nodes.Stmt).empty, .terminator = .ENDFOR };
        errdefer else_body.deinit(self.allocator);
        if (body.terminator == .ELSE) {
            else_body = try self.parseBodyUntil(&.{.ENDFOR});
        }

        const for_node = try self.allocator.create(nodes.For);
        for_node.* = nodes.For.init(self.allocator, target_expr, iter_expr, for_token.lineno, for_token.filename);
        target_moved = true;
        iter_moved = true;
        for_node.test_expr = test_expr;
        test_moved = true;
        for_node.body.deinit(self.allocator);
        for_node.body = body.statements;
        body.statements = std.ArrayList(*nodes.Stmt).empty;
        for_node.else_body.deinit(self.allocator);
        for_node.else_body = else_body.statements;
        else_body.statements = std.ArrayList(*nodes.Stmt).empty;
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
        const block_name = name_token.value;
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
            return exceptions.TemplateError.SyntaxError;
        }
        _ = self.stream.next();

        // Parse block body (statements until {% endblock %})
        var body = std.ArrayList(*nodes.Stmt).empty;
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
                // Check for {% endblock %} without consuming a nested block's
                // BLOCK_BEGIN token.
                if (t.kind == .BLOCK_BEGIN) {
                    var peek_offset: usize = 1;
                    while (self.stream.peek(peek_offset)) |peeked| {
                        if (peeked.kind != .WHITESPACE) break;
                        peek_offset += 1;
                    }
                    if (self.stream.peek(peek_offset)) |next_token| {
                        if (next_token.kind == .ENDBLOCK) {
                            _ = self.stream.next(); // BLOCK_BEGIN
                            self.skipWhitespace();
                            _ = self.stream.next(); // ENDBLOCK
                            self.skipWhitespace();
                            // An optional repeated block name is accepted.
                            if (self.stream.current()) |maybe_name| {
                                if (maybe_name.kind == .NAME) {
                                    _ = self.stream.next();
                                    self.skipWhitespace();
                                }
                            }
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
                _ = self.stream.next();
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
                if (t.kind == .WITH or t.kind == .NAME) {
                    if (t.kind == .WITH or std.mem.eql(u8, t.value, "with")) {
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
        const target_name = target_token.?.value;
        _ = self.stream.next();
        self.skipWhitespace();

        // Check for 'with context' modifier
        var with_context = false;
        if (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .WITH or (t.kind == .NAME and std.mem.eql(u8, t.value, "with"))) {
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
        var imports = std.ArrayList([]const u8).empty;
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
                if (t.kind == .WITH or (t.kind == .NAME and std.mem.eql(u8, t.value, "with"))) {
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

    fn deinitMacroArgs(allocator: std.mem.Allocator, args: *std.ArrayList(nodes.MacroArg)) void {
        for (args.items) |*arg| arg.deinit(allocator);
        args.deinit(allocator);
    }

    fn parseMacroArguments(self: *Self) ParseError!std.ArrayList(nodes.MacroArg) {
        var args = std.ArrayList(nodes.MacroArg).empty;
        errdefer deinitMacroArgs(self.allocator, &args);
        const opening = self.stream.current() orelse return args;
        if (opening.kind != .LPAREN) return args;
        _ = self.stream.next();
        self.skipWhitespace();

        while (self.stream.hasNext()) {
            const token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
            if (token.kind == .RPAREN) {
                _ = self.stream.next();
                return args;
            }
            if (token.kind != .NAME) return exceptions.TemplateError.SyntaxError;
            const name = token.value;
            _ = self.stream.next();
            self.skipWhitespace();

            var default_value: ?nodes.Expression = null;
            if (self.stream.current()) |next| {
                if (next.kind == .ASSIGN) {
                    _ = self.stream.next();
                    self.skipWhitespace();
                    default_value = try self.parseExpression() orelse return exceptions.TemplateError.SyntaxError;
                }
            }

            var arg = try nodes.MacroArg.init(self.allocator, name, default_value);
            args.append(self.allocator, arg) catch |err| {
                arg.deinit(self.allocator);
                return err;
            };
            self.skipWhitespace();

            const separator = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
            switch (separator.kind) {
                .COMMA => {
                    _ = self.stream.next();
                    self.skipWhitespace();
                },
                .RPAREN => {
                    _ = self.stream.next();
                    return args;
                },
                else => return exceptions.TemplateError.SyntaxError,
            }
        }
        return exceptions.TemplateError.SyntaxError;
    }

    /// Parse macro statement
    fn parseMacro(self: *Self) ParseError!*nodes.Macro {
        const macro_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();
        self.skipWhitespace();

        const name_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (name_token.kind != .NAME) return exceptions.TemplateError.SyntaxError;
        const macro_name = name_token.value;
        _ = self.stream.next();
        self.skipWhitespace();

        var args = try self.parseMacroArguments();
        errdefer deinitMacroArgs(self.allocator, &args);
        self.skipWhitespace();
        const header_end = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (header_end.kind != .BLOCK_END) return exceptions.TemplateError.SyntaxError;
        _ = self.stream.next();

        var body = try self.parseBodyUntil(&.{.ENDMACRO});
        errdefer body.deinit(self.allocator);

        const macro = try self.allocator.create(nodes.Macro);
        macro.* = try nodes.Macro.init(self.allocator, macro_name, macro_token.lineno, macro_token.filename);
        errdefer macro.deinit(self.allocator);
        macro.args.deinit(self.allocator);
        macro.args = args;
        args = std.ArrayList(nodes.MacroArg).empty;
        macro.body.deinit(self.allocator);
        macro.body = body.statements;
        body.statements = std.ArrayList(*nodes.Stmt).empty;

        macro.catch_varargs = self.containsNameReference(macro.body.items, "varargs");
        macro.catch_kwargs = self.containsNameReference(macro.body.items, "kwargs");
        return macro;
    }

    /// Check if any statement in the list references a given variable name
    fn containsNameReference(self: *Self, stmts: []*nodes.Stmt, name: []const u8) bool {
        _ = self;
        for (stmts) |stmt| {
            if (stmtContainsNameReference(stmt, name, 0)) {
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
        var args = std.ArrayList(nodes.Expression).empty;
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

        // Parse variable name (may be simple "name" or namespace "name.attr")
        const name_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
        if (name_token.kind != .NAME) {
            return exceptions.TemplateError.SyntaxError;
        }
        // Note: Don't duplicate var_name here - Set.init will duplicate it internally
        const var_name = name_token.value;
        _ = self.stream.next();

        // Check for namespace attribute assignment ({% set ns.attr = val %})
        var target_attr: ?[]const u8 = null;
        if (self.stream.current()) |tok| {
            if (tok.kind == .DOT) {
                _ = self.stream.next(); // consume DOT
                const attr_token = self.stream.current() orelse return exceptions.TemplateError.SyntaxError;
                if (attr_token.kind != .NAME) {
                    return exceptions.TemplateError.SyntaxError;
                }
                target_attr = attr_token.value;
                _ = self.stream.next();
            }
        }

        self.skipWhitespace();

        // Check for block variant ({% set x %}{% endset %})
        if (self.stream.hasNext()) {
            const token = self.stream.current();
            if (token) |t| {
                if (t.kind == .BLOCK_END) {
                    _ = self.stream.next();

                    // Parse block body
                    var body = std.ArrayList(*nodes.Stmt).empty;
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
                    if (target_attr) |attr| {
                        set_stmt.* = try nodes.Set.initWithAttr(self.allocator, var_name, attr, dummy_expr, set_token.lineno, set_token.filename);
                    } else {
                        set_stmt.* = try nodes.Set.init(self.allocator, var_name, dummy_expr, set_token.lineno, set_token.filename);
                    }
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
        if (target_attr) |attr| {
            set_stmt.* = try nodes.Set.initWithAttr(self.allocator, var_name, attr, value_expr, set_token.lineno, set_token.filename);
        } else {
            set_stmt.* = try nodes.Set.init(self.allocator, var_name, value_expr, set_token.lineno, set_token.filename);
        }

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
        var body = std.ArrayList(*nodes.Stmt).empty;
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
        var body = std.ArrayList(*nodes.Stmt).empty;
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
        var body = std.ArrayList(*nodes.Stmt).empty;
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
        var body = std.ArrayList(*nodes.Stmt).empty;
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
        var if_body = std.ArrayList(*nodes.Stmt).empty;
        var body = std.ArrayList(*nodes.Stmt).empty; // Current body being parsed
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

        var elif_conditions = std.ArrayList(nodes.Expression).empty;
        var elif_bodies = std.ArrayList(std.ArrayList(*nodes.Stmt)).empty;
        var else_body = std.ArrayList(*nodes.Stmt).empty;
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
                                body = std.ArrayList(*nodes.Stmt).empty;
                                if_body_saved = true;
                            } else {
                                // Save current body as elif body
                                try elif_bodies.append(self.allocator, body);
                                // Start new body for next elif
                                body = std.ArrayList(*nodes.Stmt).empty;
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
                            body = std.ArrayList(*nodes.Stmt).empty;
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
            var new_body = std.ArrayList(*nodes.Stmt).empty;
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
fn stmtContainsNameReference(stmt: *nodes.Stmt, name: []const u8, depth: usize) bool {
    // Parser bounds expression nesting at max_expr_depth; this cap is a backstop.
    // At the cap, conservatively report "references it" so callers keep the dep.
    if (depth >= max_expr_depth) return true;
    return switch (stmt.tag) {
        .output => {
            const output = @as(*nodes.Output, @ptrCast(@alignCast(stmt)));
            for (output.nodes.items) |*expr| {
                if (exprContainsNameReference(expr, name, depth + 1)) {
                    return true;
                }
            }
            return false;
        },
        .for_loop => {
            const for_stmt = @as(*nodes.For, @ptrCast(@alignCast(stmt)));
            if (exprContainsNameReference(&for_stmt.iter, name, depth + 1)) return true;
            if (for_stmt.test_expr) |*test_expr| {
                if (exprContainsNameReference(test_expr, name, depth + 1)) return true;
            }
            for (for_stmt.body.items) |s| {
                if (stmtContainsNameReference(s, name, depth + 1)) return true;
            }
            for (for_stmt.else_body.items) |s| {
                if (stmtContainsNameReference(s, name, depth + 1)) return true;
            }
            return false;
        },
        .if_stmt => {
            const if_stmt = @as(*nodes.If, @ptrCast(@alignCast(stmt)));
            if (exprContainsNameReference(&if_stmt.condition, name, depth + 1)) return true;
            for (if_stmt.body.items) |s| {
                if (stmtContainsNameReference(s, name, depth + 1)) return true;
            }
            for (if_stmt.elif_conditions.items) |*cond| {
                if (exprContainsNameReference(cond, name, depth + 1)) return true;
            }
            for (if_stmt.elif_bodies.items) |body| {
                for (body.items) |s| {
                    if (stmtContainsNameReference(s, name, depth + 1)) return true;
                }
            }
            for (if_stmt.else_body.items) |s| {
                if (stmtContainsNameReference(s, name, depth + 1)) return true;
            }
            return false;
        },
        .set => {
            const set_stmt = @as(*nodes.Set, @ptrCast(@alignCast(stmt)));
            if (exprContainsNameReference(&set_stmt.value, name, depth + 1)) return true;
            if (set_stmt.body) |*body| {
                for (body.items) |s| {
                    if (stmtContainsNameReference(s, name, depth + 1)) return true;
                }
            }
            return false;
        },
        .with => {
            const with_stmt = @as(*nodes.With, @ptrCast(@alignCast(stmt)));
            for (with_stmt.values.items) |*val| {
                if (exprContainsNameReference(val, name, depth + 1)) return true;
            }
            for (with_stmt.body.items) |s| {
                if (stmtContainsNameReference(s, name, depth + 1)) return true;
            }
            return false;
        },
        .filter_block => {
            const filter_block = @as(*nodes.FilterBlock, @ptrCast(@alignCast(stmt)));
            if (exprContainsNameReference(&filter_block.filter_expr, name, depth + 1)) return true;
            for (filter_block.body.items) |s| {
                if (stmtContainsNameReference(s, name, depth + 1)) return true;
            }
            return false;
        },
        .call => {
            const call_stmt = @as(*nodes.Call, @ptrCast(@alignCast(stmt)));
            if (exprContainsNameReference(&call_stmt.macro_expr, name, depth + 1)) return true;
            for (call_stmt.args.items) |*arg| {
                if (exprContainsNameReference(arg, name, depth + 1)) return true;
            }
            return false;
        },
        .expr_stmt => {
            const expr_stmt = @as(*nodes.ExprStmt, @ptrCast(@alignCast(stmt)));
            return exprContainsNameReference(&expr_stmt.node, name, depth + 1);
        },
        else => false,
    };
}

/// Check if an expression or its children reference a given variable name
fn exprContainsNameReference(expr: *const nodes.Expression, name: []const u8, depth: usize) bool {
    if (depth >= max_expr_depth) return true;
    return switch (expr.*) {
        .name => |n| std.mem.eql(u8, n.name, name),
        .bin_expr => |b| exprContainsNameReference(&b.left, name, depth + 1) or exprContainsNameReference(&b.right, name, depth + 1),
        .unary_expr => |u| exprContainsNameReference(&u.node, name, depth + 1),
        .filter => |f| {
            if (exprContainsNameReference(&f.node, name, depth + 1)) return true;
            for (f.args.items) |*arg| {
                if (exprContainsNameReference(arg, name, depth + 1)) return true;
            }
            return false;
        },
        .getattr => |g| exprContainsNameReference(&g.node, name, depth + 1),
        .getitem => |g| exprContainsNameReference(&g.node, name, depth + 1) or exprContainsNameReference(&g.arg, name, depth + 1),
        .test_expr => |t| {
            if (exprContainsNameReference(&t.node, name, depth + 1)) return true;
            for (t.args.items) |*arg| {
                if (exprContainsNameReference(arg, name, depth + 1)) return true;
            }
            return false;
        },
        .cond_expr => |c| {
            return exprContainsNameReference(&c.condition, name, depth + 1) or
                exprContainsNameReference(&c.true_expr, name, depth + 1) or
                exprContainsNameReference(&c.false_expr, name, depth + 1);
        },
        .call_expr => |c| {
            if (exprContainsNameReference(&c.func, name, depth + 1)) return true;
            for (c.args.items) |*arg| {
                if (exprContainsNameReference(arg, name, depth + 1)) return true;
            }
            return false;
        },
        .list_literal => |l| {
            for (l.elements.items) |*elem| {
                if (exprContainsNameReference(elem, name, depth + 1)) return true;
            }
            return false;
        },
        .concat => |c| {
            for (c.nodes.items) |*node| {
                if (exprContainsNameReference(node, name, depth + 1)) return true;
            }
            return false;
        },
        else => false,
    };
}

/// Convenience function to parse tokens into a Template
pub fn parse(env: anytype, stream: TokenStream, filename: ?[]const u8, allocator: std.mem.Allocator) !*nodes.Template {
    var parser = Parser.init(env, stream, filename, allocator);
    return try parser.parse();
}

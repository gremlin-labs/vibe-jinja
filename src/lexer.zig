//! Jinja2-compatible Template Lexer
//!
//! This module implements the lexer (tokenizer) for Jinja2 templates. It converts
//! template source code into a stream of tokens that can be consumed by the parser.
//!
//! The lexer recognizes:
//! - Template delimiters: `{{ }}`, `{% %}`, `{# #}`
//! - Operators: `+`, `-`, `*`, `/`, `//`, `%`, `**`, `~`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `=`
//! - Punctuation: `.`, `,`, `:`, `;`, `|`, `(`, `)`, `[`, `]`, `{`, `}`
//! - Literals: strings, integers, floats, booleans, null
//! - Keywords: for, in, if, else, elif, endif, endfor, block, extends, include, etc.
//! - Identifiers (names)
//! - Comments and whitespace
//!
//! # Configuration
//!
//! The lexer uses configurable delimiters from the Environment:
//! - Block delimiters: default `{%` and `%}`
//! - Variable delimiters: default `{{` and `}}`
//! - Comment delimiters: default `{#` and `#}`
//! - Optional line statement prefix (e.g., `#` for `# for item in items`)
//! - Optional line comment prefix
//!
//! # Example
//!
//! ```zig
//! var lexer = jinja.lexer.Lexer.init(&env, source, "template.jinja");
//! const tokens = try lexer.tokenize(allocator);
//! defer allocator.free(tokens.tokens);
//!
//! while (tokens.hasNext()) {
//!     const token = tokens.next().?;
//!     // Process token
//! }
//! ```
//!
//! # Token Categories
//!
//! Tokens are categorized by their `TokenKind`:
//! - **Delimiters**: `BLOCK_BEGIN`, `BLOCK_END`, `VARIABLE_BEGIN`, `VARIABLE_END`, etc.
//! - **Operators**: `ADD`, `SUB`, `MUL`, `DIV`, `EQ`, `NE`, `LT`, `GT`, etc.
//! - **Literals**: `STRING`, `INTEGER`, `FLOAT`, `BOOLEAN`, `NULL`
//! - **Keywords**: `FOR`, `IF`, `ELSE`, `BLOCK`, `EXTENDS`, etc.
//! - **Control**: `WHITESPACE`, `DATA`, `COMMENT`, `EOF`

const std = @import("std");
const defaults = @import("defaults.zig");

/// Token types matching Jinja2
pub const TokenKind = enum {
    // Delimiters
    BLOCK_BEGIN,
    BLOCK_END,
    VARIABLE_BEGIN,
    VARIABLE_END,
    COMMENT_BEGIN,
    COMMENT_END,
    RAW_BEGIN,
    RAW_END,

    // Operators
    ADD, // +
    SUB, // -
    MUL, // *
    DIV, // /
    FLOORDIV, // //
    MOD, // %
    POW, // **
    TILDE, // ~
    EQ, // ==
    NE, // !=
    LT, // <
    LTEQ, // <=
    GT, // >
    GTEQ, // >=
    ASSIGN, // =
    DOT, // .
    COMMA, // ,
    COLON, // :
    SEMICOLON, // ;
    PIPE, // |

    // Brackets
    LPAREN, // (
    RPAREN, // )
    LBRACKET, // [
    RBRACKET, // ]
    LBRACE, // {
    RBRACE, // }

    // Literals
    STRING,
    INTEGER,
    FLOAT,
    NAME,
    BOOLEAN,
    NULL,

    // Control
    WHITESPACE,
    DATA,
    COMMENT,
    LINECOMMENT,
    EOF,

    // Keywords
    FOR,
    IN,
    IF,
    ELSE,
    ELIF,
    ENDIF,
    ENDFOR,
    BLOCK,
    ENDBLOCK,
    EXTENDS,
    INCLUDE,
    IMPORT,
    FROM,
    MACRO,
    ENDMACRO,
    CALL,
    SET,
    WITH,
    ENDWITH,
    CONTINUE,
    BREAK,
    /// Expression statement tag ({% do %}) - extension
    DO,
    /// Debug tag ({% debug %}) - extension
    DEBUG,
    AND,
    OR,
    NOT,
    IS,
};

/// Token with position information
pub const Token = struct {
    kind: TokenKind,
    value: []const u8,
    trim_left: bool = false,
    trim_right: bool = false,
    /// Line number where this token appears (1-indexed)
    lineno: usize,
    /// Column number where this token starts (1-indexed)
    column: usize,
    /// Filename where this token appears (if available)
    filename: ?[]const u8,

    const Self = @This();

    fn init(kind: TokenKind, value: []const u8, lineno: usize, column: usize, filename: ?[]const u8) Token {
        return Token{
            .kind = kind,
            .value = value,
            .lineno = lineno,
            .column = column,
            .filename = filename,
        };
    }

    pub fn log(self: *const Self) void {
        var repr = self.value;
        if (std.mem.eql(u8, "\n", repr)) {
            repr = "newline";
        }
        if (self.filename) |filename| {
            std.debug.print("(token {s} \"{s}\" at {s}:{d}:{d})\n", .{ @tagName(self.kind), repr, filename, self.lineno, self.column });
        } else {
            std.debug.print("(token {s} \"{s}\" at line {d}:{d})\n", .{ @tagName(self.kind), repr, self.lineno, self.column });
        }
    }
};

/// Token stream for iterating over tokens
pub const TokenStream = struct {
    tokens: []const Token,
    cursor: usize,

    const Self = @This();

    pub fn init(tokens: []const Token) Self {
        return Self{
            .tokens = tokens,
            .cursor = 0,
        };
    }

    pub fn current(self: *const Self) ?Token {
        if (self.cursor < self.tokens.len) {
            return self.tokens[self.cursor];
        }
        return null;
    }

    pub fn next(self: *Self) ?Token {
        if (self.cursor < self.tokens.len) {
            const token = self.tokens[self.cursor];
            self.cursor += 1;
            return token;
        }
        return null;
    }

    pub fn peek(self: *const Self, offset: usize) ?Token {
        const idx = self.cursor + offset;
        if (idx < self.tokens.len) {
            return self.tokens[idx];
        }
        return null;
    }

    pub fn hasNext(self: *const Self) bool {
        return self.cursor < self.tokens.len;
    }
};

const keyword_token_kinds = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "for", .FOR },
    .{ "in", .IN },
    .{ "if", .IF },
    .{ "else", .ELSE },
    .{ "elif", .ELIF },
    .{ "endif", .ENDIF },
    .{ "endfor", .ENDFOR },
    .{ "block", .BLOCK },
    .{ "endblock", .ENDBLOCK },
    .{ "extends", .EXTENDS },
    .{ "include", .INCLUDE },
    .{ "import", .IMPORT },
    .{ "from", .FROM },
    .{ "macro", .MACRO },
    .{ "endmacro", .ENDMACRO },
    .{ "call", .CALL },
    .{ "set", .SET },
    .{ "with", .WITH },
    .{ "endwith", .ENDWITH },
    .{ "continue", .CONTINUE },
    .{ "break", .BREAK },
    .{ "do", .DO },
    .{ "debug", .DEBUG },
    .{ "and", .AND },
    .{ "or", .OR },
    .{ "not", .NOT },
    .{ "is", .IS },
    .{ "true", .BOOLEAN },
    .{ "false", .BOOLEAN },
    .{ "null", .NULL },
    .{ "none", .NULL },
    .{ "None", .NULL },
});

/// Jinja2-compatible lexer
pub const Lexer = struct {
    /// Source code to tokenize
    source: []const u8,
    /// Filename (for error reporting)
    filename: ?[]const u8,
    /// Current position in source
    cursor: usize,
    /// Current line number (1-indexed)
    lineno: usize,
    /// Current column number (1-indexed)
    column: usize,

    // Configurable delimiters
    block_start: []const u8,
    block_end: []const u8,
    variable_start: []const u8,
    variable_end: []const u8,
    comment_start: []const u8,
    comment_end: []const u8,
    line_statement_prefix: ?[]const u8,
    line_comment_prefix: ?[]const u8,

    // State
    state: LexerState,

    const Self = @This();

    const LexerState = enum {
        initial,
        in_block,
        in_variable,
        in_comment,
        in_raw,
    };

    /// Initialize lexer with environment
    pub fn init(env: anytype, source: []const u8, filename: ?[]const u8) Self {
        return Self{
            .source = source,
            .filename = filename,
            .cursor = 0,
            .lineno = 1,
            .column = 1,
            .block_start = env.block_start_string,
            .block_end = env.block_end_string,
            .variable_start = env.variable_start_string,
            .variable_end = env.variable_end_string,
            .comment_start = env.comment_start_string,
            .comment_end = env.comment_end_string,
            .line_statement_prefix = env.line_statement_prefix,
            .line_comment_prefix = env.line_comment_prefix,
            .state = .initial,
        };
    }

    /// Initialize lexer with defaults (backward compatibility)
    pub fn initDefault(source: []const u8, path: []const u8) Self {
        return Self{
            .source = source,
            .filename = if (path.len > 0) path else null,
            .cursor = 0,
            .lineno = 1,
            .column = 1,
            .block_start = defaults.BLOCK_START_STRING,
            .block_end = defaults.BLOCK_END_STRING,
            .variable_start = defaults.VARIABLE_START_STRING,
            .variable_end = defaults.VARIABLE_END_STRING,
            .comment_start = defaults.COMMENT_START_STRING,
            .comment_end = defaults.COMMENT_END_STRING,
            .line_statement_prefix = null,
            .line_comment_prefix = null,
            .state = .initial,
        };
    }

    fn consumeLeadingTrim(pending: *bool, token: *Token) bool {
        if (!pending.*) return false;
        pending.* = false;
        if (token.kind != .DATA) return false;
        token.value = std.mem.trimLeft(u8, token.value, " \t\r\n");
        return token.value.len == 0;
    }

    fn applyTrailingTrim(tokens: *std.ArrayList(Token), requested: bool) void {
        if (!requested) return;
        var index = tokens.items.len;
        while (index > 0) {
            index -= 1;
            if (tokens.items[index].kind == .DATA) {
                tokens.items[index].value = std.mem.trimRight(u8, tokens.items[index].value, " \t\r\n");
                if (tokens.items[index].value.len == 0) _ = tokens.orderedRemove(index);
                return;
            }
            if (tokens.items[index].kind != .WHITESPACE) return;
        }
    }

    /// Tokenize the entire source into a token stream
    pub fn tokenize(self: *Self, allocator: std.mem.Allocator) !TokenStream {
        var tokens = std.ArrayList(Token){};
        defer tokens.deinit(allocator);
        // Rough upper-bound heuristic (about one token per 4 source bytes) to
        // avoid repeated growth reallocations while tokenizing large templates.
        try tokens.ensureTotalCapacity(allocator, self.source.len / 4 + 8);

        var trim_leading_data = false;
        while (self.cursor < self.source.len) {
            var token = try self.nextToken(allocator);
            if (consumeLeadingTrim(&trim_leading_data, &token)) continue;
            applyTrailingTrim(&tokens, token.trim_left);
            trim_leading_data = token.trim_right;

            try tokens.append(allocator, token);
            if (token.kind == .EOF) break;
        }

        const tokens_slice = try tokens.toOwnedSlice(allocator);
        return TokenStream.init(tokens_slice);
    }

    /// Get the next token
    const PrefixPosition = struct { cursor: usize, column: usize };

    fn linePrefixPosition(self: *const Self) PrefixPosition {
        var position = PrefixPosition{ .cursor = self.cursor, .column = self.column };
        while (position.cursor < self.source.len and
            std.ascii.isWhitespace(self.source[position.cursor]) and
            self.source[position.cursor] != '\n')
        {
            position.cursor += 1;
            position.column += 1;
        }
        return position;
    }

    fn tokenizeLinePrefix(self: *Self, start_line: usize, start_column: usize) !?Token {
        const position = self.linePrefixPosition();
        if (position.column > 10) return null;

        if (self.line_statement_prefix) |prefix| {
            if (self.checkStartsWithAt(prefix, position.cursor)) {
                self.cursor = position.cursor;
                self.column = position.column;
                return self.tokenizeDelimiter(.BLOCK_BEGIN, prefix, start_line, start_column);
            }
        }
        if (self.line_comment_prefix) |prefix| {
            if (self.checkStartsWithAt(prefix, position.cursor)) {
                self.cursor = position.cursor;
                self.column = position.column;
                return try self.tokenizeLineComment(prefix, start_line, start_column);
            }
        }
        return null;
    }

    fn tokenizeRawState(self: *Self, start_line: usize, start_column: usize) !Token {
        if (self.startsWith(self.block_start)) {
            const saved_cursor = self.cursor;
            const saved_column = self.column;
            self.cursor += self.block_start.len;
            self.column += @intCast(self.block_start.len);
            self.skipWhitespace();

            if (self.startsWith("endraw")) {
                self.cursor += 6;
                self.column += 6;
                self.skipWhitespace();
                if (self.startsWith(self.block_end)) {
                    self.cursor += self.block_end.len;
                    self.column += @intCast(self.block_end.len);
                    self.state = .initial;
                    return Token.init(.RAW_END, "{% endraw %}", start_line, start_column, self.filename);
                }
            }

            self.cursor = saved_cursor;
            self.column = saved_column;
        }
        return try self.tokenizeRawContent(start_line, start_column);
    }

    fn tokenizeInitialState(self: *Self, start_line: usize, start_column: usize) Token {
        if (self.startsWith(self.block_start)) {
            const saved_cursor = self.cursor;
            const saved_column = self.column;
            const saved_lineno = self.lineno;
            self.cursor += self.block_start.len;
            self.column += @intCast(self.block_start.len);
            self.skipWhitespace();

            if (self.startsWith("raw")) {
                self.cursor += 3;
                self.column += 3;
                self.skipWhitespace();
                if (self.startsWith(self.block_end)) {
                    self.cursor += self.block_end.len;
                    self.column += @intCast(self.block_end.len);
                    self.state = .in_raw;
                    return Token.init(.RAW_BEGIN, "{% raw %}", start_line, start_column, self.filename);
                }
            }

            self.cursor = saved_cursor;
            self.column = saved_column;
            self.lineno = saved_lineno;
        }

        if (self.startsWith(self.comment_start)) {
            self.state = .in_comment;
            return self.tokenizeOpeningDelimiter(.COMMENT_BEGIN, self.comment_start, start_line, start_column);
        }
        if (self.startsWith(self.variable_start)) {
            self.state = .in_variable;
            return self.tokenizeOpeningDelimiter(.VARIABLE_BEGIN, self.variable_start, start_line, start_column);
        }
        if (self.startsWith(self.block_start)) {
            self.state = .in_block;
            return self.tokenizeOpeningDelimiter(.BLOCK_BEGIN, self.block_start, start_line, start_column);
        }
        return self.tokenizeData(start_line, start_column);
    }

    fn tokenizeTagEnd(self: *Self, start_line: usize, start_column: usize) ?Token {
        if (self.state == .in_comment and (self.startsWith(self.comment_end) or self.startsWithTrimmedEnd(self.comment_end))) {
            self.state = .initial;
            return self.tokenizeClosingDelimiter(.COMMENT_END, self.comment_end, start_line, start_column);
        }
        if (self.state == .in_variable and (self.startsWith(self.variable_end) or self.startsWithTrimmedEnd(self.variable_end))) {
            self.state = .initial;
            return self.tokenizeClosingDelimiter(.VARIABLE_END, self.variable_end, start_line, start_column);
        }
        if (self.state == .in_block and (self.startsWith(self.block_end) or self.startsWithTrimmedEnd(self.block_end))) {
            self.state = .initial;
            return self.tokenizeClosingDelimiter(.BLOCK_END, self.block_end, start_line, start_column);
        }
        return null;
    }

    fn tokenizeMultiOperator(self: *Self, start_line: usize, start_column: usize) ?Token {
        const operators = [_]struct { text: []const u8, kind: TokenKind }{
            .{ .text = "**", .kind = .POW },
            .{ .text = "//", .kind = .FLOORDIV },
            .{ .text = "==", .kind = .EQ },
            .{ .text = "!=", .kind = .NE },
            .{ .text = "<=", .kind = .LTEQ },
            .{ .text = ">=", .kind = .GTEQ },
        };
        inline for (operators) |operator| {
            if (self.startsWith(operator.text)) {
                return self.tokenizeOperator(operator.kind, operator.text, start_line, start_column);
            }
        }
        return null;
    }

    fn singleOperatorKind(byte: u8) ?TokenKind {
        return switch (byte) {
            '+' => .ADD,
            '-' => .SUB,
            '*' => .MUL,
            '/' => .DIV,
            '%' => .MOD,
            '~' => .TILDE,
            '<' => .LT,
            '>' => .GT,
            '=' => .ASSIGN,
            '.' => .DOT,
            ',' => .COMMA,
            ':' => .COLON,
            ';' => .SEMICOLON,
            '|' => .PIPE,
            '(' => .LPAREN,
            ')' => .RPAREN,
            '[' => .LBRACKET,
            ']' => .RBRACKET,
            '{' => .LBRACE,
            '}' => .RBRACE,
            else => null,
        };
    }

    fn tokenizeTagPayload(self: *Self, start_line: usize, start_column: usize) !Token {
        if (self.tokenizeMultiOperator(start_line, start_column)) |token| return token;
        const byte = self.peek();
        if (singleOperatorKind(byte)) |kind| {
            return self.tokenizeOperator(kind, self.source[self.cursor .. self.cursor + 1], start_line, start_column);
        }
        if (byte == '\n') {
            self.cursor += 1;
            self.lineno += 1;
            self.column = 1;
            return Token.init(.DATA, "\n", start_line, start_column, self.filename);
        }
        if (byte == '\'' or byte == '"') return try self.tokenizeString(start_line, start_column);
        if (std.ascii.isWhitespace(byte)) return self.tokenizeWhitespace(start_line, start_column);
        if (std.ascii.isDigit(byte)) return try self.tokenizeNumber(start_line, start_column);
        if (std.ascii.isAlphabetic(byte) or byte == '_') return try self.tokenizeName(start_line, start_column);

        const char_start = self.cursor;
        self.cursor += 1;
        self.column += 1;
        return Token.init(.DATA, self.source[char_start..self.cursor], start_line, start_column, self.filename);
    }

    /// Get the next token
    pub fn nextToken(self: *Self, allocator: std.mem.Allocator) !Token {
        _ = allocator;
        if (self.cursor >= self.source.len) {
            return Token.init(.EOF, "EOF", self.lineno, self.column, self.filename);
        }

        const start_line = self.lineno;
        const start_column = self.column;
        if (try self.tokenizeLinePrefix(start_line, start_column)) |token| return token;

        return switch (self.state) {
            .in_raw => self.tokenizeRawState(start_line, start_column),
            .initial => self.tokenizeInitialState(start_line, start_column),
            .in_comment => self.tokenizeTagEnd(start_line, start_column) orelse
                self.tokenizeCommentContent(start_line, start_column),
            .in_variable, .in_block => self.tokenizeTagEnd(start_line, start_column) orelse
                try self.tokenizeTagPayload(start_line, start_column),
        };
    }

    fn tokenizeDelimiter(self: *Self, kind: TokenKind, delimiter: []const u8, lineno: usize, column: usize) Token {
        self.cursor += delimiter.len;
        self.column += @intCast(delimiter.len);
        return Token.init(kind, delimiter, lineno, column, self.filename);
    }

    fn tokenizeOpeningDelimiter(self: *Self, kind: TokenKind, delimiter: []const u8, lineno: usize, column: usize) Token {
        var token = self.tokenizeDelimiter(kind, delimiter, lineno, column);
        if (self.cursor < self.source.len and self.source[self.cursor] == '-') {
            self.cursor += 1;
            self.column += 1;
            token.trim_left = true;
        }
        return token;
    }

    fn startsWithTrimmedEnd(self: *const Self, delimiter: []const u8) bool {
        return self.cursor < self.source.len and
            self.source[self.cursor] == '-' and
            std.mem.startsWith(u8, self.source[self.cursor + 1 ..], delimiter);
    }

    fn tokenizeClosingDelimiter(self: *Self, kind: TokenKind, delimiter: []const u8, lineno: usize, column: usize) Token {
        var trim_right = false;
        if (self.startsWithTrimmedEnd(delimiter)) {
            self.cursor += 1;
            self.column += 1;
            trim_right = true;
        }
        var token = self.tokenizeDelimiter(kind, delimiter, lineno, column);
        token.trim_right = trim_right;
        return token;
    }

    /// Tokenize a line comment (from line comment prefix to end of line)
    fn tokenizeLineComment(self: *Self, prefix: []const u8, lineno: usize, column: usize) !Token {
        self.cursor += prefix.len;
        self.column += @intCast(prefix.len);

        // Consume until end of line
        const comment_start = self.cursor;
        while (self.cursor < self.source.len and self.source[self.cursor] != '\n') {
            self.cursor += 1;
            self.column += 1;
        }

        const comment_text = self.source[comment_start..self.cursor];
        return Token.init(.LINECOMMENT, comment_text, lineno, column, self.filename);
    }

    /// Tokenize raw block content (everything until {% endraw %})
    fn tokenizeRawContent(self: *Self, lineno: usize, column: usize) !Token {
        const content_start = self.cursor;
        var content_end = self.cursor;

        // Look ahead for {% endraw %}
        while (self.cursor < self.source.len) {
            if (self.startsWith(self.block_start)) {
                const saved_cursor = self.cursor;
                const saved_column = self.column;
                self.cursor += self.block_start.len;
                self.column += @intCast(self.block_start.len);
                self.skipWhitespace();

                if (self.startsWith("endraw")) {
                    self.cursor += 6;
                    self.column += 6;
                    self.skipWhitespace();
                    if (self.startsWith(self.block_end)) {
                        // Found endraw, stop here
                        content_end = saved_cursor;
                        self.cursor = saved_cursor;
                        self.column = saved_column;
                        break;
                    }
                }

                // Not endraw, restore and continue
                self.cursor = saved_cursor;
                self.column = saved_column;
            }

            // Advance one character
            if (self.source[self.cursor] == '\n') {
                self.lineno += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.cursor += 1;
            content_end = self.cursor;
        }

        const content = self.source[content_start..content_end];
        return Token.init(.DATA, content, lineno, column, self.filename);
    }

    /// Tokenize DATA outside of tags - collect content until we hit a delimiter
    fn tokenizeData(self: *Self, lineno: usize, column: usize) Token {
        const content_start = self.cursor;

        while (self.cursor < self.source.len) {
            // Check for any delimiter that would end DATA
            if (self.startsWith(self.block_start) or
                self.startsWith(self.variable_start) or
                self.startsWith(self.comment_start))
            {
                break;
            }

            // Advance one character
            if (self.source[self.cursor] == '\n') {
                self.lineno += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.cursor += 1;
        }

        const content = self.source[content_start..self.cursor];
        return Token.init(.DATA, content, lineno, column, self.filename);
    }

    /// Tokenize comment content - skip content until we hit comment end
    fn tokenizeCommentContent(self: *Self, lineno: usize, column: usize) Token {
        const content_start = self.cursor;

        while (self.cursor < self.source.len) {
            if (self.startsWith(self.comment_end)) {
                break;
            }

            // Advance one character
            if (self.source[self.cursor] == '\n') {
                self.lineno += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.cursor += 1;
        }

        const content = self.source[content_start..self.cursor];
        return Token.init(.COMMENT, content, lineno, column, self.filename);
    }

    fn tokenizeOperator(self: *Self, kind: TokenKind, op: []const u8, lineno: usize, column: usize) Token {
        self.cursor += op.len;
        self.column += @intCast(op.len);
        return Token.init(kind, op, lineno, column, self.filename);
    }

    fn tokenizeWhitespace(self: *Self, lineno: usize, column: usize) Token {
        const start = self.cursor;
        while (self.cursor < self.source.len and std.ascii.isWhitespace(self.peek()) and self.peek() != '\n') {
            self.cursor += 1;
            self.column += 1;
        }
        return Token.init(.WHITESPACE, self.source[start..self.cursor], lineno, column, self.filename);
    }

    fn tokenizeString(self: *Self, lineno: usize, column: usize) !Token {
        const quote = self.peek();
        const start = self.cursor;
        self.cursor += 1; // Skip opening quote
        self.column += 1;

        var escaped = false;
        while (self.cursor < self.source.len) {
            const ch = self.peek();

            if (escaped) {
                escaped = false;
                self.cursor += 1;
                self.column += 1;
                continue;
            }

            if (ch == '\\') {
                escaped = true;
                self.cursor += 1;
                self.column += 1;
                continue;
            }

            if (ch == quote) {
                self.cursor += 1; // Skip closing quote
                self.column += 1;
                return Token.init(.STRING, self.source[start..self.cursor], lineno, column, self.filename);
            }

            if (ch == '\n') {
                self.lineno += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }

            self.cursor += 1;
        }

        // Unterminated string
        return Token.init(.STRING, self.source[start..], lineno, column, self.filename);
    }

    // fallow-zig-ignore-next-line complexity-hot-function: this cohesive allocation-free scanner advances one cursor through integer, fraction, and exponent states; the token golden suite covers all transitions.
    fn tokenizeNumber(self: *Self, lineno: usize, column: usize) !Token {
        const start = self.cursor;
        var has_dot = false;
        var has_e = false;

        // Parse digits before decimal point
        while (self.cursor < self.source.len and std.ascii.isDigit(self.peek())) {
            self.cursor += 1;
            self.column += 1;
        }

        // Check for decimal point
        if (self.cursor < self.source.len and self.peek() == '.') {
            has_dot = true;
            self.cursor += 1;
            self.column += 1;

            // Parse digits after decimal point
            while (self.cursor < self.source.len and std.ascii.isDigit(self.peek())) {
                self.cursor += 1;
                self.column += 1;
            }
        }

        // Check for exponent
        if (self.cursor < self.source.len and (self.peek() == 'e' or self.peek() == 'E')) {
            has_e = true;
            self.cursor += 1;
            self.column += 1;

            // Optional sign
            if (self.cursor < self.source.len and (self.peek() == '+' or self.peek() == '-')) {
                self.cursor += 1;
                self.column += 1;
            }

            // Parse exponent digits
            while (self.cursor < self.source.len and std.ascii.isDigit(self.peek())) {
                self.cursor += 1;
                self.column += 1;
            }
        }

        const value = self.source[start..self.cursor];
        const kind: TokenKind = if (has_dot or has_e) .FLOAT else .INTEGER;
        return Token.init(kind, value, lineno, column, self.filename);
    }

    fn tokenizeName(self: *Self, lineno: usize, column: usize) !Token {
        const start = self.cursor;

        // First character must be letter or underscore
        if (!std.ascii.isAlphabetic(self.peek()) and self.peek() != '_') {
            // Return a slice of the source string to avoid dangling pointer
            const char_start = self.cursor;
            self.cursor += 1;
            self.column += 1;
            return Token.init(.DATA, self.source[char_start..self.cursor], lineno, column, self.filename);
        }

        self.cursor += 1;
        self.column += 1;

        // Subsequent characters can be letter, digit, or underscore
        while (self.cursor < self.source.len) {
            const ch = self.peek();
            if (std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_') {
                self.cursor += 1;
                self.column += 1;
            } else {
                break;
            }
        }

        const value = self.source[start..self.cursor];
        const kind = self.keywordToTokenKind(value);
        return Token.init(kind, value, lineno, column, self.filename);
    }

    fn keywordToTokenKind(self: *Self, keyword: []const u8) TokenKind {
        _ = self;
        return keyword_token_kinds.get(keyword) orelse .NAME;
    }

    fn startsWith(self: *const Self, prefix: []const u8) bool {
        if (self.cursor + prefix.len > self.source.len) {
            return false;
        }
        return std.mem.eql(u8, self.source[self.cursor .. self.cursor + prefix.len], prefix);
    }

    fn checkStartsWithAt(self: *const Self, prefix: []const u8, pos: usize) bool {
        if (pos + prefix.len > self.source.len) {
            return false;
        }
        return std.mem.eql(u8, self.source[pos .. pos + prefix.len], prefix);
    }

    fn skipWhitespace(self: *Self) void {
        while (self.cursor < self.source.len and std.ascii.isWhitespace(self.peek()) and self.peek() != '\n') {
            self.cursor += 1;
            self.column += 1;
        }
    }

    fn peek(self: *const Self) u8 {
        if (self.cursor >= self.source.len) {
            return 0;
        }
        return self.source[self.cursor];
    }

    /// Check if there are more tokens
    pub fn hasNext(self: *const Self) bool {
        return self.cursor < self.source.len;
    }
};

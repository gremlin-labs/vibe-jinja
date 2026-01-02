//! Abstract Syntax Tree (AST) Nodes
//!
//! This module defines the AST node types for parsed Jinja templates. The AST is produced
//! by the parser and consumed by the compiler/visitor for template rendering.
//!
//! # Node Hierarchy
//!
//! ```
//! Node (base)
//! ├── Template (root)
//! ├── Stmt (statements)
//! │   ├── Output        - {{ expression }}
//! │   ├── For           - {% for ... %}
//! │   ├── If            - {% if ... %}
//! │   ├── Block         - {% block ... %}
//! │   ├── Extends       - {% extends ... %}
//! │   ├── Include       - {% include ... %}
//! │   ├── Import        - {% import ... %}
//! │   ├── Macro         - {% macro ... %}
//! │   ├── Call          - {% call ... %}
//! │   ├── Set           - {% set ... %}
//! │   ├── With          - {% with ... %}
//! │   ├── FilterBlock   - {% filter ... %}
//! │   ├── Autoescape    - {% autoescape ... %}
//! │   ├── ExprStmt      - {% do ... %}
//! │   ├── DebugStmt     - {% debug %}
//! │   └── Comment       - {# ... #}
//! └── Expr (expressions)
//!     ├── Name          - variable
//!     ├── StringLiteral - "string"
//!     ├── IntegerLiteral - 42
//!     ├── FloatLiteral  - 3.14
//!     ├── BooleanLiteral - true/false
//!     ├── ListLiteral   - [1, 2, 3]
//!     ├── DictLiteral   - {"key": "value"}
//!     ├── BinExpr       - a + b
//!     ├── UnaryExpr     - -x, not x
//!     ├── CondExpr      - a if b else c
//!     ├── GetAttr       - obj.attr
//!     ├── GetItem       - obj[key]
//!     ├── CallExpr      - func(args)
//!     ├── FilterExpr    - value | filter
//!     ├── TestExpr      - value is test
//!     └── Concat        - "a" ~ "b"
//! ```
//!
//! # Node Location
//!
//! All nodes store location information (`lineno`, `filename`) for error reporting:
//!
//! ```zig
//! const node = expr.base;
//! std.debug.print("Error at {s}:{d}\n", .{
//!     node.filename orelse "<unknown>",
//!     node.lineno,
//! });
//! ```
//!
//! # Ownership Rules
//!
//! This module uses clear ownership semantics for memory management:
//!
//! ## 1. Template nodes own their child statements and expressions
//!
//! When a Template is deinitialized, it recursively frees all child nodes:
//!
//! ```zig
//! // Template owns all children - single deinit cleans everything
//! template.deinit(allocator);
//! allocator.destroy(template);
//! ```
//!
//! ## 2. Parent template references are NOT owned by child templates
//!
//! When using `{% extends %}`, the child template holds a reference to the parent,
//! but does NOT own it. The parent template must be freed separately:
//!
//! ```zig
//! // Parent is managed by the Environment's template cache
//! // Child template.parent_template is a borrowed reference
//! child_template.deinit(allocator);  // Does NOT free parent
//! ```
//!
//! ## 3. Environment references are borrowed, not owned
//!
//! Nodes store `?*environment.Environment` for filter/test lookup during evaluation.
//! This is a borrowed reference - nodes never free the Environment.
//!
//! ## 4. String ownership
//!
//! String fields in nodes (names, content, etc.) are owned and duplicated at creation.
//! They are freed when the node is deinitialized.
//!
//! ## 5. Deinitialization pattern
//!
//! Always use `deinit()` followed by `destroy()`:
//!
//! ```zig
//! const template = try parser.parse();
//! defer {
//!     template.deinit(allocator);
//!     allocator.destroy(template);
//! }
//! ```
//!
//! # Memory Management
//!
//! Nodes own their children and must be deinitialized:
//!
//! ```zig
//! const template = try parser.parse();
//! defer {
//!     template.deinit(allocator);
//!     allocator.destroy(template);
//! }
//! ```

const std = @import("std");
const environment = @import("environment.zig");
const value_mod = @import("value.zig");
const context_mod = @import("context.zig");
const exceptions = @import("exceptions.zig");

/// Error set for expression evaluation that combines allocator and template errors
pub const EvalError = std.mem.Allocator.Error || exceptions.TemplateError || value_mod.CallError || error{ NotImplemented, Overflow, InvalidCharacter };

/// AST node definitions for Jinja templates
/// This file defines the abstract syntax tree structure matching Jinja2
///
/// Organization:
/// 1. Base types (Node, Stmt, Expr)
/// 2. Template (root node)
/// 3. Statements (Output, Block, For, If, CommentStmt, etc.)
/// 4. Expressions (Name, Literals, BinExpr, UnaryExpr, FilterExpr, Expression union)

// ============================================================================
// Base Types
// ============================================================================

/// Base node type that all AST nodes inherit from
pub const Node = struct {
    /// Line number where this node appears in the source
    lineno: usize,
    /// Filename where this node appears (if available)
    filename: ?[]const u8,
    /// Environment reference (set during parsing)
    environment: ?*environment.Environment,

    const Self = @This();

    /// Deinitialize the node and free any allocated memory
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // Base implementation - subclasses will override
    }
};

/// Statement type tag for type-safe dispatch
pub const StmtTag = enum {
    output,
    for_loop,
    if_stmt,
    block,
    extends,
    include,
    import,
    from_import,
    macro,
    call,
    call_block,
    set,
    with,
    filter_block,
    autoescape,
    comment,
    continue_stmt,
    break_stmt,
    /// Expression statement ({% do expr %}) - evaluates expression without output
    expr_stmt,
    /// Debug statement ({% debug %}) - outputs debug information
    debug_stmt,
};

/// Base type for all statements
pub const Stmt = struct {
    base: Node,
    /// Tag identifying the statement type for safe dispatch
    tag: StmtTag,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
    }
};

/// Helper function to deinit and destroy a statement based on its tag
/// Use this instead of directly calling stmt.deinit() when you have a *Stmt
pub fn deinitStmt(stmt: *Stmt, allocator: std.mem.Allocator) void {
    switch (stmt.tag) {
        .output => {
            const output = @as(*Output, @ptrCast(@alignCast(stmt)));
            output.deinit(allocator);
            allocator.destroy(output);
        },
        .for_loop => {
            const for_loop = @as(*For, @ptrCast(@alignCast(stmt)));
            for_loop.deinit(allocator);
            allocator.destroy(for_loop);
        },
        .if_stmt => {
            const if_stmt = @as(*If, @ptrCast(@alignCast(stmt)));
            if_stmt.deinit(allocator);
            allocator.destroy(if_stmt);
        },
        .block => {
            const block = @as(*Block, @ptrCast(@alignCast(stmt)));
            block.deinit(allocator);
            allocator.destroy(block);
        },
        .extends => {
            const extends = @as(*Extends, @ptrCast(@alignCast(stmt)));
            extends.deinit(allocator);
            allocator.destroy(extends);
        },
        .include => {
            const include = @as(*Include, @ptrCast(@alignCast(stmt)));
            include.deinit(allocator);
            allocator.destroy(include);
        },
        .import => {
            const import_stmt = @as(*Import, @ptrCast(@alignCast(stmt)));
            import_stmt.deinit(allocator);
            allocator.destroy(import_stmt);
        },
        .from_import => {
            const from_import = @as(*FromImport, @ptrCast(@alignCast(stmt)));
            from_import.deinit(allocator);
            allocator.destroy(from_import);
        },
        .macro => {
            const macro = @as(*Macro, @ptrCast(@alignCast(stmt)));
            macro.deinit(allocator);
            allocator.destroy(macro);
        },
        .call => {
            const call = @as(*Call, @ptrCast(@alignCast(stmt)));
            call.deinit(allocator);
            allocator.destroy(call);
        },
        .filter_block => {
            const filter_block = @as(*FilterBlock, @ptrCast(@alignCast(stmt)));
            filter_block.deinit(allocator);
            allocator.destroy(filter_block);
        },
        .set => {
            const set = @as(*Set, @ptrCast(@alignCast(stmt)));
            set.deinit(allocator);
            allocator.destroy(set);
        },
        .with => {
            const with = @as(*With, @ptrCast(@alignCast(stmt)));
            with.deinit(allocator);
            allocator.destroy(with);
        },
        .autoescape => {
            const autoescape = @as(*Autoescape, @ptrCast(@alignCast(stmt)));
            autoescape.deinit(allocator);
            allocator.destroy(autoescape);
        },
        .comment => {
            const comment = @as(*CommentStmt, @ptrCast(@alignCast(stmt)));
            comment.deinit(allocator);
            allocator.destroy(comment);
        },
        .continue_stmt => {
            const continue_stmt = @as(*ContinueStmt, @ptrCast(@alignCast(stmt)));
            continue_stmt.deinit(allocator);
            allocator.destroy(continue_stmt);
        },
        .break_stmt => {
            const break_stmt = @as(*BreakStmt, @ptrCast(@alignCast(stmt)));
            break_stmt.deinit(allocator);
            allocator.destroy(break_stmt);
        },
        .expr_stmt => {
            const expr_stmt = @as(*ExprStmt, @ptrCast(@alignCast(stmt)));
            expr_stmt.deinit(allocator);
            allocator.destroy(expr_stmt);
        },
        .debug_stmt => {
            const debug_stmt = @as(*DebugStmt, @ptrCast(@alignCast(stmt)));
            debug_stmt.deinit(allocator);
            allocator.destroy(debug_stmt);
        },
        .call_block => {
            const call_block = @as(*CallBlock, @ptrCast(@alignCast(stmt)));
            call_block.deinit(allocator);
            allocator.destroy(call_block);
        },
    }
}

/// Base type for all expressions
pub const Expr = struct {
    base: Node,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
    }
};

// ============================================================================
// Template (Root Node)
// ============================================================================

/// Template node - the root of the AST
pub const Template = struct {
    base: Node,
    /// List of statements in the template body
    body: std.ArrayList(*Stmt),
    /// Map of block definitions
    blocks: std.StringHashMap(*Block),
    /// Name of the template
    name: ?[]const u8,
    /// Parent template (if extends)
    parent: ?*Template,

    pub fn init(allocator: std.mem.Allocator, lineno: usize, filename: ?[]const u8) Template {
        return Template{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .body = std.ArrayList(*Stmt){},
            .blocks = std.StringHashMap(*Block).init(allocator),
            .name = null,
            .parent = null,
        };
    }

    pub fn deinit(self: *Template, allocator: std.mem.Allocator) void {
        for (self.body.items) |stmt| {
            // Use type-safe dispatch based on tag
            // All statements are heap-allocated and need both deinit() and destroy()
            switch (stmt.tag) {
                .autoescape => {
                    const autoescape_stmt = @as(*Autoescape, @ptrCast(@alignCast(stmt)));
                    autoescape_stmt.deinit(allocator);
                    allocator.destroy(autoescape_stmt);
                },
                .output => {
                    const output = @as(*Output, @ptrCast(@alignCast(stmt)));
                    output.deinit(allocator);
                    allocator.destroy(output);
                },
                .block => {
                    const block = @as(*Block, @ptrCast(@alignCast(stmt)));
                    block.deinit(allocator);
                    allocator.destroy(block);
                },
                .extends => {
                    const extends = @as(*Extends, @ptrCast(@alignCast(stmt)));
                    extends.deinit(allocator);
                    allocator.destroy(extends);
                },
                .include => {
                    const include = @as(*Include, @ptrCast(@alignCast(stmt)));
                    include.deinit(allocator);
                    allocator.destroy(include);
                },
                .import => {
                    const import_stmt = @as(*Import, @ptrCast(@alignCast(stmt)));
                    import_stmt.deinit(allocator);
                    allocator.destroy(import_stmt);
                },
                .from_import => {
                    const from_import = @as(*FromImport, @ptrCast(@alignCast(stmt)));
                    from_import.deinit(allocator);
                    allocator.destroy(from_import);
                },
                .for_loop => {
                    const for_loop = @as(*For, @ptrCast(@alignCast(stmt)));
                    for_loop.deinit(allocator);
                    allocator.destroy(for_loop);
                },
                .if_stmt => {
                    const if_stmt = @as(*If, @ptrCast(@alignCast(stmt)));
                    if_stmt.deinit(allocator);
                    allocator.destroy(if_stmt);
                },
                .comment => {
                    const comment = @as(*CommentStmt, @ptrCast(@alignCast(stmt)));
                    comment.deinit(allocator);
                    allocator.destroy(comment);
                },
                .continue_stmt => {
                    const continue_stmt = @as(*ContinueStmt, @ptrCast(@alignCast(stmt)));
                    continue_stmt.deinit(allocator);
                    allocator.destroy(continue_stmt);
                },
                .break_stmt => {
                    const break_stmt = @as(*BreakStmt, @ptrCast(@alignCast(stmt)));
                    break_stmt.deinit(allocator);
                    allocator.destroy(break_stmt);
                },
                .expr_stmt => {
                    const expr_stmt = @as(*ExprStmt, @ptrCast(@alignCast(stmt)));
                    expr_stmt.deinit(allocator);
                    allocator.destroy(expr_stmt);
                },
                .debug_stmt => {
                    const debug_stmt = @as(*DebugStmt, @ptrCast(@alignCast(stmt)));
                    debug_stmt.deinit(allocator);
                    allocator.destroy(debug_stmt);
                },
                .macro => {
                    const macro = @as(*Macro, @ptrCast(@alignCast(stmt)));
                    macro.deinit(allocator);
                    allocator.destroy(macro);
                },
                .call => {
                    const call = @as(*Call, @ptrCast(@alignCast(stmt)));
                    call.deinit(allocator);
                    allocator.destroy(call);
                },
                .call_block => {
                    const call_block = @as(*CallBlock, @ptrCast(@alignCast(stmt)));
                    call_block.deinit(allocator);
                    allocator.destroy(call_block);
                },
                .set => {
                    const set = @as(*Set, @ptrCast(@alignCast(stmt)));
                    set.deinit(allocator);
                    allocator.destroy(set);
                },
                .with => {
                    const with = @as(*With, @ptrCast(@alignCast(stmt)));
                    with.deinit(allocator);
                    allocator.destroy(with);
                },
                .filter_block => {
                    const filter_block = @as(*FilterBlock, @ptrCast(@alignCast(stmt)));
                    filter_block.deinit(allocator);
                    allocator.destroy(filter_block);
                },
            }
        }
        self.body.deinit(allocator);
        // Free block map keys (the Block nodes themselves are already freed as part of body)
        var block_iter = self.blocks.iterator();
        while (block_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.blocks.deinit();
        if (self.name) |name| {
            allocator.free(name);
        }
        // Parent template is a borrowed reference (not owned) - see Ownership Rules in module docs
    }
};

// ============================================================================
// Statements
// ============================================================================

/// Output statement - renders expressions (also used for plain text)
pub const Output = struct {
    base: Stmt,
    /// Content to output (for plain text) or expressions to render
    content: []const u8,
    /// Expressions to output (if any)
    nodes: std.ArrayList(Expression),

    const Self = @This();

    pub fn initPlainText(allocator: std.mem.Allocator, content: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .output,
            },
            .content = try allocator.dupe(u8, content),
            .nodes = std.ArrayList(Expression){},
        };
    }

    pub fn initExpression(allocator: std.mem.Allocator, lineno: usize, filename: ?[]const u8) Self {
        _ = allocator;
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .output,
            },
            .content = "",
            .nodes = std.ArrayList(Expression){},
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.content.len > 0) {
            allocator.free(self.content);
        }
        for (self.nodes.items) |*expr| {
            expr.deinit(allocator);
        }
        self.nodes.deinit(allocator);
        // Self is destroyed by the caller after deinit returns - standard Zig pattern
    }

    /// Evaluate the output node
    /// Returns string representation of the output
    /// Context is required for variable resolution in expressions
    pub fn eval(self: *const Self, ctx: *context_mod.Context, allocator: std.mem.Allocator) ![]const u8 {
        if (self.nodes.items.len == 0) {
            // Plain text output
            return try allocator.dupe(u8, self.content);
        }

        // Expression output - evaluate each expression and convert to string
        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        for (self.nodes.items) |*expr| {
            var expr_value = try expr.eval(ctx, allocator);
            defer expr_value.deinit(allocator);
            const expr_str = try expr_value.toString(allocator);
            defer allocator.free(expr_str);
            try result.appendSlice(allocator, expr_str);
        }

        return try result.toOwnedSlice(allocator);
    }
};

/// Block statement
pub const Block = struct {
    base: Stmt,
    /// Block name
    name: []const u8,
    /// Block body statements
    body: std.ArrayList(*Stmt),
    /// Whether this block is required
    required: bool,
    /// Whether this block is scoped
    scoped: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .block,
            },
            .name = try allocator.dupe(u8, name),
            .body = std.ArrayList(*Stmt){},
            .required = false,
            .scoped = false,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.body.items) |stmt| {
            deinitStmt(stmt, allocator);
        }
        self.body.deinit(allocator);
        allocator.free(self.name);
    }
};

/// Extends statement
pub const Extends = struct {
    base: Stmt,
    /// Template name expression
    template: Expression,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, template: Expression, lineno: usize, filename: ?[]const u8) Self {
        _ = allocator;
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .extends,
            },
            .template = template,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.template.deinit(allocator);
    }
};

/// Include statement
pub const Include = struct {
    base: Stmt,
    /// Template name expression
    template: Expression,
    /// Whether to include with context
    with_context: bool,
    /// Whether to ignore missing templates
    ignore_missing: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, template: Expression, lineno: usize, filename: ?[]const u8) Self {
        _ = allocator;
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .include,
            },
            .template = template,
            .with_context = true,
            .ignore_missing = false,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.template.deinit(allocator);
    }
};

/// Import statement
pub const Import = struct {
    base: Stmt,
    /// Template name expression
    template: Expression,
    /// Import target name
    target: []const u8,
    /// Whether to import with context
    with_context: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, template: Expression, target: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .import,
            },
            .template = template,
            .target = try allocator.dupe(u8, target),
            .with_context = false,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.template.deinit(allocator);
        allocator.free(self.target);
    }
};

/// From import statement
pub const FromImport = struct {
    base: Stmt,
    /// Template name expression
    template: Expression,
    /// List of names to import
    imports: std.ArrayList([]const u8),
    /// Whether to import with context
    with_context: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, template: Expression, lineno: usize, filename: ?[]const u8) Self {
        _ = allocator;
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .from_import,
            },
            .template = template,
            .imports = std.ArrayList([]const u8){},
            .with_context = false,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.template.deinit(allocator);
        for (self.imports.items) |import_name| {
            allocator.free(import_name);
        }
        self.imports.deinit(allocator);
    }
};

/// For loop statement
pub const For = struct {
    base: Stmt,
    /// Loop variable name
    target: Expression,
    /// Iterable expression
    iter: Expression,
    /// Loop body statements
    body: std.ArrayList(*Stmt),
    /// Else clause statements (if any)
    else_body: std.ArrayList(*Stmt),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, target: Expression, iter: Expression, lineno: usize, filename: ?[]const u8) Self {
        _ = allocator;
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .for_loop,
            },
            .target = target,
            .iter = iter,
            .body = std.ArrayList(*Stmt){},
            .else_body = std.ArrayList(*Stmt){},
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        self.iter.deinit(allocator);
        for (self.body.items) |stmt| {
            deinitStmt(stmt, allocator);
        }
        self.body.deinit(allocator);
        for (self.else_body.items) |stmt| {
            deinitStmt(stmt, allocator);
        }
        self.else_body.deinit(allocator);
    }
};

/// If statement
pub const If = struct {
    base: Stmt,
    /// Condition expression
    condition: Expression,
    /// If body statements
    body: std.ArrayList(*Stmt),
    /// Elif conditions and bodies
    elif_conditions: std.ArrayList(Expression),
    elif_bodies: std.ArrayList(std.ArrayList(*Stmt)),
    /// Else body statements
    else_body: std.ArrayList(*Stmt),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, condition: Expression, lineno: usize, filename: ?[]const u8) Self {
        _ = allocator;
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .if_stmt,
            },
            .condition = condition,
            .body = std.ArrayList(*Stmt){},
            .elif_conditions = std.ArrayList(Expression){},
            .elif_bodies = std.ArrayList(std.ArrayList(*Stmt)){},
            .else_body = std.ArrayList(*Stmt){},
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.condition.deinit(allocator);
        for (self.body.items) |stmt| {
            deinitStmt(stmt, allocator);
        }
        self.body.deinit(allocator);
        for (self.elif_conditions.items) |*expr| {
            expr.deinit(allocator);
        }
        self.elif_conditions.deinit(allocator);
        for (self.elif_bodies.items) |*body| {
            for (body.items) |stmt| {
                deinitStmt(stmt, allocator);
            }
            body.deinit(allocator);
        }
        self.elif_bodies.deinit(allocator);
        for (self.else_body.items) |stmt| {
            deinitStmt(stmt, allocator);
        }
        self.else_body.deinit(allocator);
    }
};

/// Comment statement - ignored during rendering
pub const CommentStmt = struct {
    base: Stmt,

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .comment,
            },
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    /// Evaluate the comment (returns empty string)
    pub fn eval(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        _ = allocator;
        return "";
    }
};

/// Continue statement (for loops)
pub const ContinueStmt = struct {
    base: Stmt,

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .continue_stmt,
            },
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Break statement (for loops)
pub const BreakStmt = struct {
    base: Stmt,

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .break_stmt,
            },
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Expression statement - evaluates expression without producing output
/// This is used by the `do` extension: {% do expr %}
/// Matches Python's jinja2.nodes.ExprStmt
pub const ExprStmt = struct {
    base: Stmt,
    /// The expression to evaluate
    node: Expression,

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8, node: Expression) Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .expr_stmt,
            },
            .node = node,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
    }
};

/// Debug statement - outputs debug information about context, filters, and tests
/// This is used by the `debug` extension: {% debug %}
/// Matches Python's jinja2.ext.DebugExtension
pub const DebugStmt = struct {
    base: Stmt,

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .debug_stmt,
            },
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Macro argument definition
pub const MacroArg = struct {
    name: []const u8,
    default_value: ?Expression,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, default_value: ?Expression) !Self {
        return Self{
            .name = try allocator.dupe(u8, name),
            .default_value = default_value,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.default_value) |*default_val| {
            default_val.deinit(allocator);
        }
    }
};

/// Macro statement
pub const Macro = struct {
    base: Stmt,
    /// Macro name
    name: []const u8,
    /// Macro arguments
    args: std.ArrayList(MacroArg),
    /// Macro body statements
    body: std.ArrayList(*Stmt),
    /// Whether the macro catches extra positional arguments as `varargs`
    /// This is true if `varargs` is referenced in the macro body
    catch_varargs: bool,
    /// Whether the macro catches extra keyword arguments as `kwargs`
    /// This is true if `kwargs` is referenced in the macro body
    catch_kwargs: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .macro,
            },
            .name = try allocator.dupe(u8, name),
            .args = std.ArrayList(MacroArg).empty,
            .body = std.ArrayList(*Stmt){},
            .catch_varargs = false,
            .catch_kwargs = false,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.args.items) |*arg| {
            arg.deinit(allocator);
        }
        self.args.deinit(allocator);
        for (self.body.items) |stmt| {
            deinitStmt(stmt, allocator);
        }
        self.body.deinit(allocator);
    }
};

/// Call statement (macro call)
pub const Call = struct {
    base: Stmt,
    /// Macro name expression
    macro_expr: Expression,
    /// Positional arguments
    args: std.ArrayList(Expression),
    /// Keyword arguments (name -> expression)
    kwargs: std.StringHashMap(Expression),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, macro_expr: Expression, lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .call,
            },
            .macro_expr = macro_expr,
            .args = std.ArrayList(Expression){},
            .kwargs = std.StringHashMap(Expression).init(allocator),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.macro_expr.deinit(allocator);
        for (self.args.items) |*arg| {
            arg.deinit(allocator);
        }
        self.args.deinit(allocator);
        var kw_iter = self.kwargs.iterator();
        while (kw_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        self.kwargs.deinit();
    }
};

/// Call block statement (call macro with body)
pub const CallBlock = struct {
    base: Stmt,
    /// Call expression
    call_expr: Expression,
    /// Call block body
    body: std.ArrayList(*Stmt),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, call_expr: Expression, lineno: usize, filename: ?[]const u8) Self {
        _ = allocator; // Reserved for potential string duplication
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .call_block,
            },
            .call_expr = call_expr,
            .body = std.ArrayList(*Stmt){},
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.call_expr.deinit(allocator);
        for (self.body.items) |stmt| {
            deinitStmt(stmt, allocator);
        }
        self.body.deinit(allocator);
    }
};

/// Set statement (variable assignment)
/// Supports both simple assignment ({% set x = val %}) and namespace attribute
/// assignment ({% set ns.attr = val %}) for Jinja2 namespace() compatibility.
pub const Set = struct {
    base: Stmt,
    /// Variable name (for simple) or namespace name (for namespace attr)
    name: []const u8,
    /// Optional attribute name for namespace attribute assignment (e.g., "found" in ns.found)
    target_attr: ?[]const u8,
    /// Value expression
    value: Expression,
    /// Body statements (for set block variant)
    body: ?std.ArrayList(*Stmt),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, value: Expression, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .set,
            },
            .name = try allocator.dupe(u8, name),
            .target_attr = null,
            .value = value,
            .body = null,
        };
    }

    /// Initialize with namespace attribute target (e.g., {% set ns.attr = val %})
    pub fn initWithAttr(allocator: std.mem.Allocator, name: []const u8, attr: []const u8, value: Expression, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .set,
            },
            .name = try allocator.dupe(u8, name),
            .target_attr = try allocator.dupe(u8, attr),
            .value = value,
            .body = null,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.target_attr) |attr| {
            allocator.free(attr);
        }
        self.value.deinit(allocator);
        if (self.body) |*body| {
            for (body.items) |stmt| {
                deinitStmt(stmt, allocator);
            }
            body.deinit(allocator);
        }
    }
};

/// With statement (scoped variables)
pub const With = struct {
    base: Stmt,
    /// Target variable names
    targets: std.ArrayList([]const u8),
    /// Value expressions
    values: std.ArrayList(Expression),
    /// With body statements
    body: std.ArrayList(*Stmt),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, lineno: usize, filename: ?[]const u8) Self {
        _ = allocator;
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .with,
            },
            .targets = std.ArrayList([]const u8){},
            .values = std.ArrayList(Expression){},
            .body = std.ArrayList(*Stmt){},
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.targets.items) |target| {
            allocator.free(target);
        }
        self.targets.deinit(allocator);
        for (self.values.items) |*value| {
            value.deinit(allocator);
        }
        self.values.deinit(allocator);
        for (self.body.items) |stmt| {
            deinitStmt(stmt, allocator);
        }
        self.body.deinit(allocator);
    }
};

/// Filter block statement
pub const FilterBlock = struct {
    base: Stmt,
    /// Filter expression
    filter_expr: Expression,
    /// Filter block body
    body: std.ArrayList(*Stmt),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, filter_expr: Expression, lineno: usize, filename: ?[]const u8) Self {
        _ = allocator;
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .filter_block,
            },
            .filter_expr = filter_expr,
            .body = std.ArrayList(*Stmt){},
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.filter_expr.deinit(allocator);
        for (self.body.items) |stmt| {
            deinitStmt(stmt, allocator);
        }
        self.body.deinit(allocator);
    }
};

/// Autoescape block statement
pub const Autoescape = struct {
    base: Stmt,
    /// Autoescape expression (evaluates to bool)
    enabled: Expression,
    /// Autoescape block body
    body: std.ArrayList(*Stmt),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, enabled: Expression, lineno: usize, filename: ?[]const u8) Self {
        _ = allocator;
        return Self{
            .base = Stmt{
                .base = Node{
                    .lineno = lineno,
                    .filename = filename,
                    .environment = null,
                },
                .tag = .autoescape,
            },
            .enabled = enabled,
            .body = std.ArrayList(*Stmt).empty,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.enabled.deinit(allocator);
        // Clean up body statements - we own them and need to free them
        for (self.body.items) |stmt| {
            // Use the module-level deinitStmt helper
            deinitStmt(stmt, allocator);
        }
        self.body.deinit(allocator);
    }
};

// ============================================================================
// Expressions
// ============================================================================

/// Name expression - variable reference
pub const Name = struct {
    base: Node,
    /// Variable name
    name: []const u8,
    /// Context: 'load', 'store', or 'param'
    ctx: NameContext,

    const Self = @This();

    pub const NameContext = enum {
        load,
        store,
        param,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, ctx: NameContext, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .name = try allocator.dupe(u8, name),
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Literal expression base
pub const Literal = struct {
    base: Node,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// String literal expression
pub const StringLiteral = struct {
    base: Node,
    /// String value (without quotes)
    value: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, val: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        // Process escape sequences in the string
        const unescaped = try unescapeString(allocator, val);
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .value = unescaped,
        };
    }

    /// Process escape sequences in a string literal
    fn unescapeString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        // Quick check: if no backslashes, return as-is
        var has_backslash = false;
        for (input) |c| {
            if (c == '\\') {
                has_backslash = true;
                break;
            }
        }
        if (!has_backslash) {
            return try allocator.dupe(u8, input);
        }

        // Process escape sequences
        var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '\\' and i + 1 < input.len) {
                const next = input[i + 1];
                switch (next) {
                    'n' => {
                        try result.append(allocator, '\n');
                        i += 2;
                    },
                    'r' => {
                        try result.append(allocator, '\r');
                        i += 2;
                    },
                    't' => {
                        try result.append(allocator, '\t');
                        i += 2;
                    },
                    '\\' => {
                        try result.append(allocator, '\\');
                        i += 2;
                    },
                    '\'' => {
                        try result.append(allocator, '\'');
                        i += 2;
                    },
                    '"' => {
                        try result.append(allocator, '"');
                        i += 2;
                    },
                    '0' => {
                        try result.append(allocator, 0);
                        i += 2;
                    },
                    else => {
                        // Unknown escape sequence - keep as is
                        try result.append(allocator, input[i]);
                        i += 1;
                    },
                }
            } else {
                try result.append(allocator, input[i]);
                i += 1;
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }

    /// Evaluate the string literal
    pub fn eval(self: *const Self, allocator: std.mem.Allocator) !value_mod.Value {
        return value_mod.Value{ .string = try allocator.dupe(u8, self.value) };
    }
};

/// Integer literal expression
pub const IntegerLiteral = struct {
    base: Node,
    /// Integer value
    value: i64,

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8, val: i64) Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .value = val,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    /// Evaluate the integer literal
    pub fn eval(self: *const Self, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator;
        return value_mod.Value{ .integer = self.value };
    }
};

/// Boolean literal expression
pub const BooleanLiteral = struct {
    base: Node,
    /// Boolean value
    value: bool,

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8, val: bool) Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .value = val,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    /// Evaluate the boolean literal
    pub fn eval(self: *const Self, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator;
        return value_mod.Value{ .boolean = self.value };
    }
};

/// Float literal expression
pub const FloatLiteral = struct {
    base: Node,
    /// Float value
    value: f64,

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8, val: f64) Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .value = val,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    /// Evaluate the float literal
    pub fn eval(self: *const Self, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator;
        return value_mod.Value{ .float = self.value };
    }
};

/// Null literal expression (null, none, None)
pub const NullLiteral = struct {
    base: Node,

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    /// Evaluate the null literal
    pub fn eval(self: *const Self, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        _ = allocator;
        return value_mod.Value{ .null = {} };
    }
};

/// List literal expression [a, b, c]
pub const ListLiteral = struct {
    base: Node,
    /// Elements in the list
    elements: std.ArrayList(Expression),

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .elements = std.ArrayList(Expression){},
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.elements.items) |*elem| {
            elem.deinit(allocator);
        }
        self.elements.deinit(allocator);
    }
};

/// Binary expression
pub const BinExpr = struct {
    base: Node,
    /// Left operand
    left: Expression,
    /// Right operand
    right: Expression,
    /// Operator token kind
    op: TokenKind,

    const Self = @This();
    const TokenKind = @import("lexer.zig").TokenKind;

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.left.deinit(allocator);
        self.right.deinit(allocator);
    }
};

/// Unary expression
pub const UnaryExpr = struct {
    base: Node,
    /// Operand
    node: Expression,
    /// Operator token kind
    op: TokenKind,

    const Self = @This();
    const TokenKind = @import("lexer.zig").TokenKind;

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
    }
};

/// Filter expression - applies a filter to an expression
pub const FilterExpr = struct {
    base: Node,
    /// Expression to filter
    node: Expression,
    /// Filter name
    name: []const u8,
    /// Filter positional arguments
    args: std.ArrayList(Expression),
    /// Filter keyword arguments (kwargs)
    kwargs: std.StringHashMap(Expression),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, node: Expression, name: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Node.init(.filter_expr, lineno, filename, null),
            .node = node,
            .name = name,
            .args = std.ArrayList(Expression).init(allocator),
            .kwargs = std.StringHashMap(Expression).init(allocator),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        allocator.free(self.name);
        for (self.args.items) |*arg| {
            arg.deinit(allocator);
        }
        self.args.deinit(allocator);
        // Free kwargs keys and deinit expression values
        var iter = self.kwargs.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        self.kwargs.deinit();
    }
};

/// Get attribute expression - access object attribute (obj.attr)
pub const Getattr = struct {
    base: Node,
    /// Object expression
    node: Expression,
    /// Attribute name
    attr: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, node: Expression, attr: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .node = node,
            .attr = try allocator.dupe(u8, attr),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        allocator.free(self.attr);
    }
};

/// Get item expression - access list/dict item (obj[index])
pub const Getitem = struct {
    base: Node,
    /// Object expression
    node: Expression,
    /// Index/key expression
    arg: Expression,

    const Self = @This();

    pub fn init(node: Expression, arg: Expression, lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .node = node,
            .arg = arg,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.arg.deinit(allocator);
    }
};

/// Test expression - applies a test to an expression (value is test)
pub const TestExpr = struct {
    base: Node,
    /// Expression to test
    node: Expression,
    /// Test name
    name: []const u8,
    /// Test arguments
    args: std.ArrayList(Expression),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, node: Expression, name: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .node = node,
            .name = try allocator.dupe(u8, name),
            .args = std.ArrayList(Expression).empty,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        allocator.free(self.name);
        for (self.args.items) |*arg| {
            arg.deinit(allocator);
        }
        self.args.deinit(allocator);
    }
};

/// Conditional expression (x if y else z)
pub const CondExpr = struct {
    base: Node,
    /// Condition expression
    condition: Expression,
    /// True branch expression
    true_expr: Expression,
    /// False branch expression
    false_expr: Expression,

    const Self = @This();

    pub fn init(condition: Expression, true_expr: Expression, false_expr: Expression, lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .condition = condition,
            .true_expr = true_expr,
            .false_expr = false_expr,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.condition.deinit(allocator);
        self.true_expr.deinit(allocator);
        self.false_expr.deinit(allocator);
    }
};

/// Function call expression
pub const CallExpr = struct {
    base: Node,
    /// Function expression (name or attribute access)
    func: Expression,
    /// Positional arguments
    args: std.ArrayList(Expression),
    /// Keyword arguments (name -> expression)
    kwargs: std.StringHashMap(Expression),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, func: Expression, lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .func = func,
            .args = std.ArrayList(Expression){},
            .kwargs = std.StringHashMap(Expression).init(allocator),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.func.deinit(allocator);
        for (self.args.items) |*arg| {
            arg.deinit(allocator);
        }
        self.args.deinit(allocator);
        var kw_iter = self.kwargs.iterator();
        while (kw_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        self.kwargs.deinit();
    }
};

/// Namespace reference expression - reference to a namespace value assignment
/// Used for accessing attributes of namespace objects (e.g., imported template namespaces)
pub const NSRef = struct {
    base: Node,
    /// Namespace name
    name: []const u8,
    /// Attribute name
    attr: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, attr: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .name = try allocator.dupe(u8, name),
            .attr = try allocator.dupe(u8, attr),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.attr);
    }
};

/// Slice expression - slicing syntax [start:end:step]
pub const Slice = struct {
    base: Node,
    /// Start expression (optional)
    start: ?Expression,
    /// Stop expression (optional)
    stop: ?Expression,
    /// Step expression (optional)
    step: ?Expression,

    const Self = @This();

    pub fn init(start: ?Expression, stop: ?Expression, step: ?Expression, lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .start = start,
            .stop = stop,
            .step = step,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.start) |*s| s.deinit(allocator);
        if (self.stop) |*s| s.deinit(allocator);
        if (self.step) |*s| s.deinit(allocator);
    }
};

/// Concat expression - concatenates list of expressions after converting to strings
/// This is an optimization node for string concatenation
pub const Concat = struct {
    base: Node,
    /// List of expressions to concatenate
    nodes: std.ArrayList(Expression),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, lineno: usize, filename: ?[]const u8) Self {
        _ = allocator;
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .nodes = std.ArrayList(Expression).empty,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.nodes.items) |*node| {
            node.deinit(allocator);
        }
        self.nodes.deinit(allocator);
    }
};

/// Environment attribute expression - loads an attribute from the environment object
/// Useful for extensions that want to call callbacks stored on the environment
pub const EnvironmentAttribute = struct {
    base: Node,
    /// Attribute name
    name: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .name = try allocator.dupe(u8, name),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Extension attribute expression - returns attribute of an extension bound to the environment
/// The identifier is the identifier of the Extension
pub const ExtensionAttribute = struct {
    base: Node,
    /// Extension identifier
    identifier: []const u8,
    /// Attribute name
    name: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, identifier: []const u8, name: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .identifier = try allocator.dupe(u8, identifier),
            .name = try allocator.dupe(u8, name),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.identifier);
        allocator.free(self.name);
    }
};

/// Imported name expression - returns imported name on evaluation
/// Imports are optimized by the compiler so there is no need to assign them to local variables
pub const ImportedName = struct {
    base: Node,
    /// Import name (e.g., "cgi.escape")
    importname: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, importname: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .importname = try allocator.dupe(u8, importname),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.importname);
    }
};

/// Internal name expression - an internal name in the compiler
/// Cannot be created directly - use parser's free_identifier method
/// This identifier is not available from the template and is not treated specially by the compiler
pub const InternalName = struct {
    base: Node,
    /// Internal name
    name: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, lineno: usize, filename: ?[]const u8) !Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
            .name = try allocator.dupe(u8, name),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Context reference expression - returns the current template context
/// Can be used like a Name node and will return the current Context object
pub const ContextReference = struct {
    base: Node,

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Derived context reference expression - returns current template context including locals
/// Behaves exactly like ContextReference, but includes local variables (e.g., from a for loop)
pub const DerivedContextReference = struct {
    base: Node,

    const Self = @This();

    pub fn init(lineno: usize, filename: ?[]const u8) Self {
        return Self{
            .base = Node{
                .lineno = lineno,
                .filename = filename,
                .environment = null,
            },
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Expression union type
/// This union represents all possible expression types in the AST
pub const Expression = union(enum) {
    string_literal: *StringLiteral,
    integer_literal: *IntegerLiteral,
    float_literal: *FloatLiteral,
    boolean_literal: *BooleanLiteral,
    null_literal: *NullLiteral,
    list_literal: *ListLiteral,
    name: *Name,
    bin_expr: *BinExpr,
    unary_expr: *UnaryExpr,
    filter: *FilterExpr,
    getattr: *Getattr,
    getitem: *Getitem,
    test_expr: *TestExpr,
    cond_expr: *CondExpr,
    call_expr: *CallExpr,
    nsref: *NSRef,
    slice: *Slice,
    concat: *Concat,
    environment_attribute: *EnvironmentAttribute,
    extension_attribute: *ExtensionAttribute,
    imported_name: *ImportedName,
    internal_name: *InternalName,
    context_reference: *ContextReference,
    derived_context_reference: *DerivedContextReference,

    pub fn deinit(self: *const Expression, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string_literal => |lit| {
                lit.deinit(allocator);
                allocator.destroy(lit);
            },
            .integer_literal => |lit| {
                lit.deinit(allocator);
                allocator.destroy(lit);
            },
            .float_literal => |lit| {
                lit.deinit(allocator);
                allocator.destroy(lit);
            },
            .boolean_literal => |lit| {
                lit.deinit(allocator);
                allocator.destroy(lit);
            },
            .null_literal => |lit| {
                lit.deinit(allocator);
                allocator.destroy(lit);
            },
            .list_literal => |lit| {
                lit.deinit(allocator);
                allocator.destroy(lit);
            },
            .name => |n| {
                n.deinit(allocator);
                allocator.destroy(n);
            },
            .bin_expr => |bin| {
                bin.deinit(allocator);
                allocator.destroy(bin);
            },
            .unary_expr => |unary| {
                unary.deinit(allocator);
                allocator.destroy(unary);
            },
            .filter => |f| {
                f.deinit(allocator);
                allocator.destroy(f);
            },
            .getattr => |g| {
                g.deinit(allocator);
                allocator.destroy(g);
            },
            .getitem => |g| {
                g.deinit(allocator);
                allocator.destroy(g);
            },
            .test_expr => |t| {
                t.deinit(allocator);
                allocator.destroy(t);
            },
            .cond_expr => |c| {
                c.deinit(allocator);
                allocator.destroy(c);
            },
            .call_expr => |c| {
                c.deinit(allocator);
                allocator.destroy(c);
            },
            .nsref => |n| {
                n.deinit(allocator);
                allocator.destroy(n);
            },
            .slice => |s| {
                s.deinit(allocator);
                allocator.destroy(s);
            },
            .concat => |c| {
                c.deinit(allocator);
                allocator.destroy(c);
            },
            .environment_attribute => |e| {
                e.deinit(allocator);
                allocator.destroy(e);
            },
            .extension_attribute => |e| {
                e.deinit(allocator);
                allocator.destroy(e);
            },
            .imported_name => |i| {
                i.deinit(allocator);
                allocator.destroy(i);
            },
            .internal_name => |i| {
                i.deinit(allocator);
                allocator.destroy(i);
            },
            .context_reference => |c| {
                c.deinit(allocator);
                allocator.destroy(c);
            },
            .derived_context_reference => |d| {
                d.deinit(allocator);
                allocator.destroy(d);
            },
        }
    }

    /// Evaluate expression with context
    /// Context is required for variable resolution, filters, tests, etc.
    pub fn eval(self: *const Expression, ctx: *context_mod.Context, allocator: std.mem.Allocator) EvalError!value_mod.Value {
        return switch (self.*) {
            .string_literal => |lit| try lit.eval(allocator),
            .integer_literal => |lit| try lit.eval(allocator),
            .float_literal => |lit| try lit.eval(allocator),
            .boolean_literal => |lit| try lit.eval(allocator),
            .null_literal => |lit| try lit.eval(allocator),
            .list_literal => |lit| try self.evalListLiteral(lit, ctx, allocator),
            .name => |n| try self.evalName(n, ctx, allocator),
            .bin_expr => |bin| try self.evalBinExpr(bin, ctx, allocator),
            .unary_expr => |unary| try self.evalUnaryExpr(unary, ctx, allocator),
            .filter => |f| try self.evalFilter(f, ctx, allocator),
            .getattr => |g| try self.evalGetattr(g, ctx, allocator),
            .getitem => |g| try self.evalGetitem(g, ctx, allocator),
            .test_expr => |t| try self.evalTestExpr(t, ctx, allocator),
            .cond_expr => |c| try self.evalCondExpr(c, ctx, allocator),
            .call_expr => |c| try self.evalCallExpr(c, ctx, allocator),
            .nsref => |n| try self.evalNSRef(n, ctx, allocator),
            .slice => return error.NotImplemented, // Slice is handled in Getitem
            .concat => |c| try self.evalConcat(c, ctx, allocator),
            .environment_attribute => return error.NotImplemented, // Requires compiler
            .extension_attribute => return error.NotImplemented, // Requires compiler
            .imported_name => |i| try self.evalImportedName(i, ctx, allocator),
            .internal_name => return error.NotImplemented, // Internal names not evaluable
            .context_reference => |c| try self.evalContextReference(c, ctx, allocator),
            .derived_context_reference => |d| try self.evalDerivedContextReference(d, ctx, allocator),
        };
    }

    /// Evaluate name expression - resolve variable from context
    fn evalName(self: *const Expression, node: *Name, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        // Resolve name from context
        const val = ctx.resolve(node.name);
        // Check if value is undefined
        if (val != .undefined) {
            // Return a copy of the value (caller will own it)
            return try copyValue(allocator, val);
        }

        // Variable not found - return undefined based on environment's undefined behavior
        const env = ctx.environment;
        const behavior = env.undefined_behavior;
        const name_copy = try allocator.dupe(u8, node.name);
        return value_mod.Value{ .undefined = value_mod.Undefined{
            .name = name_copy,
            .behavior = behavior,
        } };
    }

    /// Evaluate binary expression
    fn evalBinExpr(self: *const Expression, node: *BinExpr, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;

        // Evaluate left and right operands
        var left_val = try node.left.eval(ctx, allocator);
        defer left_val.deinit(allocator);

        var right_val = try node.right.eval(ctx, allocator);
        defer right_val.deinit(allocator);

        // Handle operators
        return switch (node.op) {
            .ADD => evalPlus(left_val, right_val, allocator),
            .SUB => evalMinus(left_val, right_val, allocator),
            .MUL => evalMul(left_val, right_val, allocator),
            .DIV => evalDiv(left_val, right_val, allocator),
            .FLOORDIV => evalFloorDiv(left_val, right_val, allocator),
            .MOD => evalMod(left_val, right_val, allocator),
            .POW => evalPow(left_val, right_val, allocator),
            .EQ => evalEq(left_val, right_val, allocator),
            .NE => evalNe(left_val, right_val, allocator),
            .LT => evalLt(left_val, right_val, allocator),
            .LTEQ => evalLe(left_val, right_val, allocator),
            .GT => evalGt(left_val, right_val, allocator),
            .GTEQ => evalGe(left_val, right_val, allocator),
            .AND => evalAnd(left_val, right_val, allocator),
            .OR => evalOr(left_val, right_val, allocator),
            .IN => evalIn(left_val, right_val, allocator),
            else => {
                // Unknown operator
                return exceptions.TemplateError.RuntimeError;
            },
        };
    }

    /// Evaluate unary expression
    fn evalUnaryExpr(self: *const Expression, node: *UnaryExpr, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;

        // Evaluate operand
        var operand_val = try node.node.eval(ctx, allocator);
        defer operand_val.deinit(allocator);

        return switch (node.op) {
            .NOT => {
                const result = !(operand_val.isTruthy() catch false);
                return value_mod.Value{ .boolean = result };
            },
            .ADD => {
                // Unary plus - convert to number if possible
                return try copyValue(allocator, operand_val);
            },
            .SUB => {
                // Unary minus - negate number
                return switch (operand_val) {
                    .integer => |i| value_mod.Value{ .integer = -i },
                    .float => |f| value_mod.Value{ .float = -f },
                    else => {
                        // Try to convert to number
                        if (operand_val.toInteger()) |i| {
                            return value_mod.Value{ .integer = -i };
                        } else if (operand_val.toFloat()) |f| {
                            return value_mod.Value{ .float = -f };
                        } else {
                            return exceptions.TemplateError.RuntimeError;
                        }
                    },
                };
            },
            else => {
                // Unknown unary operator
                return exceptions.TemplateError.RuntimeError;
            },
        };
    }

    /// Evaluate filter expression
    fn evalFilter(self: *const Expression, node: *FilterExpr, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        // Evaluate base expression
        var base_val = try node.node.eval(ctx, allocator);
        defer base_val.deinit(allocator);

        // Get filter from environment
        const env = ctx.environment;
        const filter = env.getFilter(node.name) orelse {
            return exceptions.TemplateError.RuntimeError;
        };

        // Evaluate filter arguments
        var filter_args = std.ArrayList(value_mod.Value){};
        defer {
            for (filter_args.items) |*arg| {
                arg.deinit(allocator);
            }
            filter_args.deinit(allocator);
        }

        for (node.args.items) |*arg_expr| {
            const arg_val = try arg_expr.eval(ctx, allocator);
            try filter_args.append(allocator, arg_val);
        }

        // Evaluate kwargs
        var filter_kwargs = std.StringHashMap(value_mod.Value).init(allocator);
        defer {
            var iter = filter_kwargs.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit(allocator);
            }
            filter_kwargs.deinit();
        }
        var kwarg_iter = node.kwargs.iterator();
        while (kwarg_iter.next()) |entry| {
            const kwarg_val = try entry.value_ptr.*.eval(ctx, allocator);
            try filter_kwargs.put(entry.key_ptr.*, kwarg_val);
        }

        // Apply filter
        const filtered_value = try filter.func(
            allocator,
            base_val,
            filter_args.items,
            &filter_kwargs,
            ctx,
            env,
        );

        return filtered_value;
    }

    /// Evaluate getattr expression
    fn evalGetattr(self: *const Expression, node: *Getattr, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        // Evaluate object expression
        var obj_val = try node.node.eval(ctx, allocator);
        defer obj_val.deinit(allocator);

        // Get attribute from object
        return try getAttribute(obj_val, node.attr, ctx, allocator);
    }

    /// Evaluate getitem expression
    fn evalGetitem(self: *const Expression, node: *Getitem, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        // Evaluate object expression
        var obj_val = try node.node.eval(ctx, allocator);
        defer obj_val.deinit(allocator);

        // Evaluate index/key expression
        var index_val = try node.arg.eval(ctx, allocator);
        defer index_val.deinit(allocator);

        // Get item from object
        return try getItem(obj_val, index_val, ctx, allocator);
    }

    /// Evaluate list literal expression
    fn evalListLiteral(self: *const Expression, node: *ListLiteral, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        // Create a new list
        const list = try allocator.create(value_mod.List);
        list.* = value_mod.List.init(allocator);
        errdefer {
            list.deinit(allocator);
        }

        // Evaluate each element and add to list
        for (node.elements.items) |*elem_expr| {
            const elem_val = try elem_expr.eval(ctx, allocator);
            try list.append(elem_val);
        }

        return value_mod.Value{ .list = list };
    }

    /// Evaluate test expression
    fn evalTestExpr(self: *const Expression, node: *TestExpr, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        // Evaluate base expression
        var base_val = try node.node.eval(ctx, allocator);
        defer base_val.deinit(allocator);

        // Get test from environment
        const env = ctx.environment;
        const test_func = env.getTest(node.name) orelse {
            return exceptions.TemplateError.RuntimeError;
        };

        // Evaluate test arguments
        var test_args = std.ArrayList(value_mod.Value){};
        defer {
            for (test_args.items) |*arg| {
                arg.deinit(allocator);
            }
            test_args.deinit(allocator);
        }

        for (node.args.items) |*arg_expr| {
            const arg_val = try arg_expr.eval(ctx, allocator);
            try test_args.append(allocator, arg_val);
        }

        // Determine which arguments to pass based on pass_arg setting
        const env_to_pass = switch (test_func.pass_arg) {
            .environment => env,
            else => null,
        };
        const ctx_to_pass = switch (test_func.pass_arg) {
            .context => ctx,
            else => ctx, // Always pass context for now
        };

        // Apply test
        const test_result = test_func.func(
            base_val,
            test_args.items,
            ctx_to_pass,
            env_to_pass,
        );

        return value_mod.Value{ .boolean = test_result };
    }

    /// Evaluate conditional expression (x if y else z)
    fn evalCondExpr(self: *const Expression, node: *CondExpr, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        // Evaluate condition
        var cond_val = try node.condition.eval(ctx, allocator);
        defer cond_val.deinit(allocator);

        // Return true branch if condition is truthy, else false branch
        if (cond_val.isTruthy() catch false) {
            return try node.true_expr.eval(ctx, allocator);
        } else {
            return try node.false_expr.eval(ctx, allocator);
        }
    }

    /// Evaluate function call expression
    fn evalCallExpr(self: *const Expression, node: *CallExpr, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        // Evaluate function expression
        var func_val = try node.func.eval(ctx, allocator);
        defer func_val.deinit(allocator);

        // For now, we'll handle macro calls and basic function calls
        // Get function name if it's a name expression
        if (node.func == .name) {
            const func_name_node = node.func.name;
            const func_name = func_name_node.name;
            const env = ctx.environment;

            // Check if it's a macro
            if (ctx.getMacro(func_name)) |_| {
                // Convert to Expression list for callMacro
                var expr_args = std.ArrayList(Expression){};
                defer expr_args.deinit(allocator);
                for (node.args.items) |arg| {
                    try expr_args.append(allocator, arg);
                }

                // Call macro - this requires compiler, so we'll need to handle it differently
                // For now, return undefined
                const name_copy = try allocator.dupe(u8, func_name);
                return value_mod.Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = env.undefined_behavior,
                } };
            }

            // Check if it's a filter (filters can be called as functions)
            if (env.getFilter(func_name)) |_| {
                // Filters require compiler to call, so return undefined for now
                // This will be handled by the compiler's visitCallExpr
                const name_copy = try allocator.dupe(u8, func_name);
                return value_mod.Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = env.undefined_behavior,
                } };
            }

            // Check if it's a global function
            if (env.getGlobal(func_name)) |global_val| {
                // For now, return the global value as-is
                // Full callable support would require compiler
                return try copyValue(allocator, global_val);
            }

            // Function not found
            const name_copy = try allocator.dupe(u8, func_name);
            return value_mod.Value{ .undefined = value_mod.Undefined{
                .name = name_copy,
                .behavior = env.undefined_behavior,
            } };
        }

        // Non-name function expressions require compiler to evaluate
        // Return undefined for now
        const name_copy = try allocator.dupe(u8, "call");
        return value_mod.Value{ .undefined = value_mod.Undefined{
            .name = name_copy,
            .behavior = ctx.environment.undefined_behavior,
        } };
    }

    /// Evaluate NSRef expression - namespace reference
    fn evalNSRef(self: *const Expression, node: *NSRef, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        // Resolve namespace from context
        const namespace_val = ctx.resolve(node.name);
        if (namespace_val == .undefined) {
            return exceptions.TemplateError.UndefinedError;
        }
        defer namespace_val.deinit(allocator);

        // Get attribute from namespace (typically a dict)
        if (namespace_val == .dict) {
            if (namespace_val.dict.get(node.attr)) |attr_val| {
                return try copyValue(allocator, attr_val);
            }
        }

        // Return undefined if attribute not found
        const attr_name_copy = try allocator.dupe(u8, node.attr);
        return value_mod.Value{ .undefined = value_mod.Undefined{
            .name = attr_name_copy,
            .behavior = ctx.environment.undefined_behavior,
        } };
    }

    /// Evaluate Concat expression - concatenate expressions as strings
    fn evalConcat(self: *const Expression, node: *Concat, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        // Evaluate and concatenate all expressions
        for (node.nodes.items) |*expr| {
            const val = try expr.eval(ctx, allocator);
            defer val.deinit(allocator);

            const str = try val.toString(allocator);
            defer allocator.free(str);
            try result.appendSlice(allocator, str);
        }

        const result_str = try result.toOwnedSlice(allocator);
        return value_mod.Value{ .string = result_str };
    }

    /// Evaluate ImportedName expression - get imported name value
    fn evalImportedName(self: *const Expression, node: *ImportedName, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        // Imported names are resolved from context (from import statements)
        const val = ctx.resolve(node.importname);
        if (val == .undefined) {
            return exceptions.TemplateError.UndefinedError;
        }
        return try copyValue(allocator, val);
    }

    /// Evaluate ContextReference expression - get current template context
    fn evalContextReference(self: *const Expression, node: *ContextReference, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        _ = node;

        // Return a dict representation of the context
        const ctx_dict = try allocator.create(value_mod.Dict);
        ctx_dict.* = value_mod.Dict.init(allocator);
        errdefer ctx_dict.deinit(allocator);
        errdefer allocator.destroy(ctx_dict);

        // Add context properties
        if (ctx.name) |name| {
            // Note: name_copy is used for the value - Dict.set will duplicate for key
            const name_copy = try allocator.dupe(u8, name);
            try ctx_dict.set(name, value_mod.Value{ .string = name_copy });
        }

        // Add exported vars
        // Note: Dict.set duplicates keys internally, so pass original key directly
        var exported_iter = ctx.exported_vars.iterator();
        while (exported_iter.next()) |entry| {
            const val = ctx.resolve(entry.key_ptr.*);
            if (val != .undefined) {
                const val_copy = try val.deepCopy(allocator);
                try ctx_dict.set(entry.key_ptr.*, val_copy);
            }
        }

        return value_mod.Value{ .dict = ctx_dict };
    }

    /// Evaluate DerivedContextReference expression - get current context including locals
    fn evalDerivedContextReference(self: *const Expression, node: *DerivedContextReference, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        _ = self;
        _ = node;

        // Similar to ContextReference but includes local variables
        // Note: This requires frame access which isn't available in eval
        // For now, return same as ContextReference (frame access would be handled by compiler)
        // Return a dict representation of the context
        const ctx_dict = try allocator.create(value_mod.Dict);
        ctx_dict.* = value_mod.Dict.init(allocator);
        errdefer ctx_dict.deinit(allocator);
        errdefer allocator.destroy(ctx_dict);

        // Add context properties
        if (ctx.name) |name| {
            // Note: name_copy is used for the value - Dict.set will duplicate for key
            const name_copy = try allocator.dupe(u8, name);
            try ctx_dict.set(name, value_mod.Value{ .string = name_copy });
        }

        // Add exported vars
        // Note: Dict.set duplicates keys internally, so pass original key directly
        var exported_iter = ctx.exported_vars.iterator();
        while (exported_iter.next()) |entry| {
            const val = ctx.resolve(entry.key_ptr.*);
            if (val != .undefined) {
                const val_copy = try val.deepCopy(allocator);
                try ctx_dict.set(entry.key_ptr.*, val_copy);
            }
        }

        return value_mod.Value{ .dict = ctx_dict };
    }

    /// Helper to copy a value (uses deepCopy)
    fn copyValue(allocator: std.mem.Allocator, val: value_mod.Value) !value_mod.Value {
        return try val.deepCopy(allocator);
    }

    /// Helper to get attribute from object
    fn getAttribute(obj: value_mod.Value, attr: []const u8, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        // Handle undefined with chainable behavior
        if (obj == .undefined) {
            const u = obj.undefined;
            // Log access if logger is set
            u.logAccess("getAttribute");

            // Chainable mode returns undefined for chained access
            if (u.behavior == .chainable) {
                const attr_copy = try allocator.dupe(u8, attr);
                return value_mod.Value{ .undefined = value_mod.Undefined{
                    .name = attr_copy,
                    .behavior = .chainable,
                    .logger = u.logger,
                } };
            }
            // Strict mode raises error
            if (u.behavior == .strict) {
                return exceptions.TemplateError.UndefinedError;
            }
            // Other modes return undefined
            const attr_copy = try allocator.dupe(u8, attr);
            return value_mod.Value{ .undefined = value_mod.Undefined{
                .name = attr_copy,
                .behavior = u.behavior,
                .logger = u.logger,
            } };
        }

        // For dict, try to get key
        if (obj == .dict) {
            if (obj.dict.get(attr)) |val| {
                return try copyValue(allocator, val);
            }
        }

        // Handle string attributes (like .upper, .lower, etc.)
        if (obj == .string) {
            // String methods could be implemented here
            // For now, only dict attributes are supported
        }

        // Handle custom object types
        if (obj == .custom) {
            const custom = obj.custom;

            // Try to get field value first
            if (try custom.getField(attr, allocator)) |field_val| {
                return field_val;
            }

            // Try to get method as a callable
            if (try custom.getMethod(attr, allocator)) |method_fn| {
                // Wrap the method in a Callable value
                const callable = try allocator.create(value_mod.Callable);
                callable.* = value_mod.Callable{
                    .name = try allocator.dupe(u8, attr),
                    .is_async = false,
                    .callable_type = .function,
                    .func = method_fn,
                };
                return value_mod.Value{ .callable = callable };
            }

            // Field/method not found on custom object
            const name_copy = try allocator.dupe(u8, attr);
            const env = ctx.environment;
            return value_mod.Value{ .undefined = value_mod.Undefined{
                .name = name_copy,
                .behavior = env.undefined_behavior,
            } };
        }

        // Attribute not found - return undefined
        const name_copy = try allocator.dupe(u8, attr);
        const env = ctx.environment;
        return value_mod.Value{ .undefined = value_mod.Undefined{
            .name = name_copy,
            .behavior = env.undefined_behavior,
        } };
    }

    /// Helper to get item from object
    fn getItem(obj: value_mod.Value, index: value_mod.Value, ctx: *context_mod.Context, allocator: std.mem.Allocator) !value_mod.Value {
        // Handle undefined with chainable behavior
        if (obj == .undefined) {
            const u = obj.undefined;
            // Log access if logger is set
            u.logAccess("getItem");

            // Chainable mode returns undefined for chained access
            if (u.behavior == .chainable) {
                const name_copy = try allocator.dupe(u8, "item");
                return value_mod.Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = .chainable,
                    .logger = u.logger,
                } };
            }
            // Strict mode raises error
            if (u.behavior == .strict) {
                return exceptions.TemplateError.UndefinedError;
            }
            // Other modes return undefined
            const name_copy = try allocator.dupe(u8, "item");
            return value_mod.Value{ .undefined = value_mod.Undefined{
                .name = name_copy,
                .behavior = u.behavior,
                .logger = u.logger,
            } };
        }

        // For list, use integer index
        if (obj == .list) {
            if (index == .integer) {
                const idx = index.integer;
                if (idx >= 0 and @as(usize, @intCast(idx)) < obj.list.items.items.len) {
                    const item = obj.list.items.items[@intCast(idx)];
                    return try copyValue(allocator, item);
                }
            }
        }

        // For dict, use string key
        if (obj == .dict) {
            if (index == .string) {
                if (obj.dict.get(index.string)) |val| {
                    return try copyValue(allocator, val);
                }
            }
        }

        // Handle custom object subscript access
        if (obj == .custom) {
            const custom = obj.custom;
            if (try custom.getItem(index, allocator)) |item_val| {
                return item_val;
            }
            // If getItem returns null, fall through to undefined
        }

        // Item not found
        const name_copy = try allocator.dupe(u8, "item");
        const env = ctx.environment;
        return value_mod.Value{ .undefined = value_mod.Undefined{
            .name = name_copy,
            .behavior = env.undefined_behavior,
        } };
    }

    // Binary operator evaluation helpers
    fn evalPlus(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        return switch (left) {
            .integer => |l| switch (right) {
                .integer => |r| value_mod.Value{ .integer = l + r },
                .float => |r| value_mod.Value{ .float = @as(f64, @floatFromInt(l)) + r },
                .string => |r| {
                    const l_str = try std.fmt.allocPrint(allocator, "{d}", .{l});
                    defer allocator.free(l_str);
                    const result = try std.fmt.allocPrint(allocator, "{s}{s}", .{ l_str, r });
                    return value_mod.Value{ .string = result };
                },
                else => return exceptions.TemplateError.RuntimeError,
            },
            .float => |l| switch (right) {
                .integer => |r| value_mod.Value{ .float = l + @as(f64, @floatFromInt(r)) },
                .float => |r| value_mod.Value{ .float = l + r },
                else => return exceptions.TemplateError.RuntimeError,
            },
            .string => |l| switch (right) {
                .string => |r| {
                    const result = try std.fmt.allocPrint(allocator, "{s}{s}", .{ l, r });
                    return value_mod.Value{ .string = result };
                },
                else => {
                    const r_str = try right.toString(allocator);
                    defer allocator.free(r_str);
                    const result = try std.fmt.allocPrint(allocator, "{s}{s}", .{ l, r_str });
                    return value_mod.Value{ .string = result };
                },
            },
            else => return exceptions.TemplateError.RuntimeError,
        };
    }

    fn evalMinus(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        return switch (left) {
            .integer => |l| switch (right) {
                .integer => |r| value_mod.Value{ .integer = l - r },
                .float => |r| value_mod.Value{ .float = @as(f64, @floatFromInt(l)) - r },
                else => return exceptions.TemplateError.RuntimeError,
            },
            .float => |l| switch (right) {
                .integer => |r| value_mod.Value{ .float = l - @as(f64, @floatFromInt(r)) },
                .float => |r| value_mod.Value{ .float = l - r },
                else => return exceptions.TemplateError.RuntimeError,
            },
            else => return exceptions.TemplateError.RuntimeError,
        };
    }

    fn evalMul(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        return switch (left) {
            .integer => |l| switch (right) {
                .integer => |r| value_mod.Value{ .integer = l * r },
                .float => |r| value_mod.Value{ .float = @as(f64, @floatFromInt(l)) * r },
                else => return exceptions.TemplateError.RuntimeError,
            },
            .float => |l| switch (right) {
                .integer => |r| value_mod.Value{ .float = l * @as(f64, @floatFromInt(r)) },
                .float => |r| value_mod.Value{ .float = l * r },
                else => return exceptions.TemplateError.RuntimeError,
            },
            .string => |l| switch (right) {
                .integer => |r| {
                    if (r < 0) return exceptions.TemplateError.RuntimeError;
                    var result = std.ArrayList(u8){};
                    defer result.deinit(allocator);
                    var i: i64 = 0;
                    while (i < r) : (i += 1) {
                        try result.appendSlice(allocator, l);
                    }
                    return value_mod.Value{ .string = try result.toOwnedSlice(allocator) };
                },
                else => return exceptions.TemplateError.RuntimeError,
            },
            else => return exceptions.TemplateError.RuntimeError,
        };
    }

    fn evalDiv(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        return switch (left) {
            .integer => |l| switch (right) {
                .integer => |r| {
                    if (r == 0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .float = @as(f64, @floatFromInt(l)) / @as(f64, @floatFromInt(r)) };
                },
                .float => |r| {
                    if (r == 0.0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .float = @as(f64, @floatFromInt(l)) / r };
                },
                else => return exceptions.TemplateError.RuntimeError,
            },
            .float => |l| switch (right) {
                .integer => |r| {
                    if (r == 0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .float = l / @as(f64, @floatFromInt(r)) };
                },
                .float => |r| {
                    if (r == 0.0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .float = l / r };
                },
                else => return exceptions.TemplateError.RuntimeError,
            },
            else => return exceptions.TemplateError.RuntimeError,
        };
    }

    fn evalFloorDiv(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        return switch (left) {
            .integer => |l| switch (right) {
                .integer => |r| {
                    if (r == 0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .integer = @divTrunc(l, r) };
                },
                .float => |r| {
                    if (r == 0.0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .integer = @intFromFloat(@floor(@as(f64, @floatFromInt(l)) / r)) };
                },
                else => return exceptions.TemplateError.RuntimeError,
            },
            .float => |l| switch (right) {
                .integer => |r| {
                    if (r == 0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .integer = @intFromFloat(@floor(l / @as(f64, @floatFromInt(r)))) };
                },
                .float => |r| {
                    if (r == 0.0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .integer = @intFromFloat(@floor(l / r)) };
                },
                else => return exceptions.TemplateError.RuntimeError,
            },
            else => return exceptions.TemplateError.RuntimeError,
        };
    }

    fn evalMod(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        return switch (left) {
            .integer => |l| switch (right) {
                .integer => |r| {
                    if (r == 0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .integer = @mod(l, r) };
                },
                .float => |r| {
                    if (r == 0.0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .float = @mod(@as(f64, @floatFromInt(l)), r) };
                },
                else => return exceptions.TemplateError.RuntimeError,
            },
            .float => |l| switch (right) {
                .integer => |r| {
                    if (r == 0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .float = @mod(l, @as(f64, @floatFromInt(r))) };
                },
                .float => |r| {
                    if (r == 0.0) return exceptions.TemplateError.RuntimeError;
                    return value_mod.Value{ .float = @mod(l, r) };
                },
                else => return exceptions.TemplateError.RuntimeError,
            },
            else => return exceptions.TemplateError.RuntimeError,
        };
    }

    fn evalPow(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        return switch (left) {
            .integer => |l| switch (right) {
                .integer => |r| {
                    if (r < 0) return exceptions.TemplateError.RuntimeError;
                    var result: i64 = 1;
                    var base: i64 = l;
                    var exp: i64 = r;
                    while (exp > 0) {
                        if (exp & 1 == 1) result *= base;
                        base *= base;
                        exp >>= 1;
                    }
                    return value_mod.Value{ .integer = result };
                },
                .float => |r| {
                    return value_mod.Value{ .float = std.math.pow(f64, @as(f64, @floatFromInt(l)), r) };
                },
                else => return exceptions.TemplateError.RuntimeError,
            },
            .float => |l| switch (right) {
                .integer => |r| {
                    return value_mod.Value{ .float = std.math.pow(f64, l, @as(f64, @floatFromInt(r))) };
                },
                .float => |r| {
                    return value_mod.Value{ .float = std.math.pow(f64, l, r) };
                },
                else => return exceptions.TemplateError.RuntimeError,
            },
            else => return exceptions.TemplateError.RuntimeError,
        };
    }

    fn evalEq(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        return value_mod.Value{ .boolean = left.isEqual(right) catch false };
    }

    fn evalNe(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        return value_mod.Value{ .boolean = !(left.isEqual(right) catch false) };
    }

    fn evalLt(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        return value_mod.Value{ .boolean = compareLessThan(left, right) };
    }

    fn evalLe(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        const lt = compareLessThan(left, right);
        const eq = left.isEqual(right) catch false;
        return value_mod.Value{ .boolean = lt or eq };
    }

    fn evalGt(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        return value_mod.Value{ .boolean = compareLessThan(right, left) };
    }

    fn evalGe(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        const lt = compareLessThan(right, left);
        const eq = left.isEqual(right) catch false;
        return value_mod.Value{ .boolean = lt or eq };
    }

    /// Helper to compare values for less than
    fn compareLessThan(left: value_mod.Value, right: value_mod.Value) bool {
        // Try numeric comparison first
        const left_int = left.toInteger();
        const right_int = right.toInteger();
        if (left_int != null and right_int != null) {
            return left_int.? < right_int.?;
        }

        const left_float = left.toFloat();
        const right_float = right.toFloat();
        if (left_float != null and right_float != null) {
            return left_float.? < right_float.?;
        }

        // Mixed int/float
        if (left_int != null and right_float != null) {
            return @as(f64, @floatFromInt(left_int.?)) < right_float.?;
        }
        if (left_float != null and right_int != null) {
            return left_float.? < @as(f64, @floatFromInt(right_int.?));
        }

        // String comparison
        if (left == .string and right == .string) {
            return std.mem.order(u8, left.string, right.string) == .lt;
        }

        // Default: false
        return false;
    }

    fn evalAnd(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        // Short-circuit: if left is falsy, return left, else return right
        if (!(left.isTruthy() catch false)) {
            return try copyValue(allocator, left);
        }
        return try copyValue(allocator, right);
    }

    fn evalOr(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        // Short-circuit: if left is truthy, return left, else return right
        if (left.isTruthy() catch false) {
            return try copyValue(allocator, left);
        }
        return try copyValue(allocator, right);
    }

    fn evalIn(left: value_mod.Value, right: value_mod.Value, allocator: std.mem.Allocator) !value_mod.Value {
        _ = allocator; // Not used in this function
        // Check if left is in right (right must be list or dict/string)
        return switch (right) {
            .list => |l| {
                for (l.items.items) |item| {
                    if (left.isEqual(item) catch false) {
                        return value_mod.Value{ .boolean = true };
                    }
                }
                return value_mod.Value{ .boolean = false };
            },
            .dict => |d| {
                if (left == .string) {
                    return value_mod.Value{ .boolean = d.map.contains(left.string) };
                }
                return value_mod.Value{ .boolean = false };
            },
            .string => |s| {
                if (left == .string) {
                    return value_mod.Value{ .boolean = std.mem.indexOf(u8, s, left.string) != null };
                }
                return value_mod.Value{ .boolean = false };
            },
            else => value_mod.Value{ .boolean = false },
        };
    }
};

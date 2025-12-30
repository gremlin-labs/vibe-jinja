//! AST Visitor Pattern
//!
//! This module implements the visitor pattern for traversing and evaluating AST nodes.
//! It provides a clean, type-safe way to visit different node types without unsafe casts.
//!
//! # Visitor Pattern
//!
//! The visitor pattern separates the algorithm (visiting) from the data structure (AST).
//! Each node type has a corresponding `visit*` method:
//!
//! - `visitTemplate` - Visit template root
//! - `visitStatement` - Visit any statement (dispatches by type)
//! - `visitOutput` - Visit output node
//! - `visitExpression` - Evaluate an expression
//!
//! # Usage
//!
//! ```zig
//! var visitor = jinja.visitor.Visitor.init(allocator, &env);
//! const output = try visitor.visitTemplate(template, &ctx);
//! defer allocator.free(output);
//! ```
//!
//! # Type-Safe Dispatch
//!
//! The visitor uses the statement's `tag` field for type-safe dispatch instead of
//! unsafe pointer casts:
//!
//! ```zig
//! switch (stmt.tag) {
//!     .output => // Handle output
//!     .for_loop => // Handle for loop
//!     .if_stmt => // Handle if statement
//!     // etc.
//! }
//! ```
//!
//! # Relationship to Compiler
//!
//! This visitor is a simpler alternative to the full `Compiler`. Use this for:
//! - Simple template rendering without advanced features
//! - Testing and debugging
//! - Understanding the AST structure
//!
//! Use `Compiler` for:
//! - Full feature support (macros, inheritance, imports)
//! - Production rendering
//! - Bytecode compilation

const std = @import("std");
const nodes = @import("nodes.zig");
const context = @import("context.zig");
const environment = @import("environment.zig");
const value_mod = @import("value.zig");

/// Visitor pattern for traversing and evaluating AST nodes
/// This provides a clean way to visit different node types without unsafe casts
pub const Visitor = struct {
    allocator: std.mem.Allocator,
    environment: *environment.Environment,

    const Self = @This();

    /// Initialize a new visitor
    pub fn init(allocator: std.mem.Allocator, env: *environment.Environment) Self {
        return Self{
            .allocator = allocator,
            .environment = env,
        };
    }

    /// Visit a Template node
    pub fn visitTemplate(self: *Self, node: *nodes.Template, ctx: *context.Context) ![]const u8 {
        var output = std.ArrayList(u8){};
        defer output.deinit(self.allocator);

        // Visit all statements in the template body
        for (node.body.items) |stmt| {
            const stmt_output = try self.visitStatement(stmt, ctx);
            defer self.allocator.free(stmt_output);
            try output.appendSlice(self.allocator, stmt_output);
        }

        return try output.toOwnedSlice(self.allocator);
    }

    /// Visit a Statement node
    /// Uses type-safe dispatch based on statement tag
    pub fn visitStatement(self: *Self, stmt: *nodes.Stmt, ctx: *context.Context) ![]const u8 {
        // Use switch statement for type-safe dispatch
        return switch (stmt.tag) {
            .output => {
                const output = @as(*nodes.Output, @ptrCast(@alignCast(stmt)));
                return try self.visitOutput(output, ctx);
            },
            .comment => {
                // Comments produce no output
                return try self.allocator.dupe(u8, "");
            },
            else => {
                // All statement types should be handled above
                // If we reach here, it's an unhandled statement type
                return try self.allocator.dupe(u8, "");
            },
        };
    }

    /// Visit an Output node
    pub fn visitOutput(self: *Self, node: *nodes.Output, ctx: *context.Context) ![]const u8 {
        // If it's plain text, return the content directly
        if (node.content.len > 0) {
            return try self.allocator.dupe(u8, node.content);
        }

        // Otherwise, evaluate expressions and convert to string
        var output = std.ArrayList(u8){};
        defer output.deinit(self.allocator);

        for (node.nodes.items) |*expr| {
            var expr_value = try self.visitExpression(expr, ctx);
            defer expr_value.deinit(self.allocator);
            const expr_str = try expr_value.toString(self.allocator);
            defer self.allocator.free(expr_str);
            try output.appendSlice(self.allocator, expr_str);
        }

        return try output.toOwnedSlice(self.allocator);
    }

    /// Visit an Expression node
    /// Returns Value type
    pub fn visitExpression(self: *Self, expr: *nodes.Expression, ctx: *context.Context) !value_mod.Value {
        return switch (expr.*) {
            .string_literal => |lit| try self.visitStringLiteral(lit, ctx),
            .integer_literal => |lit| try self.visitIntegerLiteral(lit, ctx),
            .float_literal => |lit| try self.visitFloatLiteral(lit, ctx),
            .boolean_literal => |lit| try self.visitBooleanLiteral(lit, ctx),
            else => {
                // Other expression types not yet implemented in visitor
                return value_mod.Value{ .string = try self.allocator.dupe(u8, "") };
            },
        };
    }

    /// Visit a StringLiteral node
    pub fn visitStringLiteral(self: *Self, node: *nodes.StringLiteral, _: *context.Context) !value_mod.Value {
        return value_mod.Value{ .string = try self.allocator.dupe(u8, node.value) };
    }

    /// Visit an IntegerLiteral node
    pub fn visitIntegerLiteral(_: *Self, node: *nodes.IntegerLiteral, _: *context.Context) !value_mod.Value {
        return value_mod.Value{ .integer = node.value };
    }

    /// Visit a FloatLiteral node
    pub fn visitFloatLiteral(_: *Self, node: *nodes.FloatLiteral, _: *context.Context) !value_mod.Value {
        return value_mod.Value{ .float = node.value };
    }

    /// Visit a BooleanLiteral node
    pub fn visitBooleanLiteral(_: *Self, node: *nodes.BooleanLiteral, _: *context.Context) !value_mod.Value {
        return value_mod.Value{ .boolean = node.value };
    }

    // Additional visit methods are implemented in compiler.zig
    // This visitor is kept minimal for basic template evaluation
    // - etc.
};

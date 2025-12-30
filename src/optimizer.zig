//! AST Optimization
//!
//! This module provides optimization passes for the parsed AST. Optimizations are applied
//! after parsing but before rendering to improve template performance.
//!
//! # Optimization Passes
//!
//! ## Constant Folding
//!
//! Evaluates constant expressions at compile time:
//!
//! ```jinja
//! {# Before optimization #}
//! {{ 1 + 2 * 3 }}
//!
//! {# After optimization #}
//! {{ 7 }}
//! ```
//!
//! ## Dead Code Elimination
//!
//! Removes unreachable code:
//!
//! ```jinja
//! {# Before optimization #}
//! {% if false %}never shown{% endif %}
//!
//! {# After optimization #}
//! (nothing)
//! ```
//!
//! ## Output Optimization
//!
//! Merges adjacent output nodes:
//!
//! ```jinja
//! {# Before: 3 output nodes #}
//! Hello, World!
//!
//! {# After: 1 output node #}
//! Hello, World!
//! ```
//!
//! # Usage
//!
//! Optimization is enabled by default when `env.optimized = true`:
//!
//! ```zig
//! var env = jinja.Environment.init(allocator);
//! env.optimized = true; // Default
//!
//! // Or manually optimize
//! var optimizer = jinja.optimizer.Optimizer.init(allocator);
//! try optimizer.optimize(template);
//! ```
//!
//! # Performance Impact
//!
//! - Constant folding: Reduces runtime computation
//! - Dead code elimination: Reduces AST traversal
//! - Output merging: Reduces string concatenation operations

const std = @import("std");
const nodes = @import("nodes.zig");
const value_mod = @import("value.zig");

/// Optimizer for template AST
/// Performs optimizations like constant folding, dead code elimination, etc.
pub const Optimizer = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new optimizer
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Optimize a template AST
    pub fn optimize(self: *Self, template: *nodes.Template) !void {
        // Perform all optimization passes
        try self.removeDeadCode(template);
        try self.optimizeOutput(template);
    }

    /// Optimize an expression by performing constant folding
    pub fn optimizeExpression(self: *Self, expr: *nodes.Expression) (std.mem.Allocator.Error || error{ Overflow, InvalidCharacter, UndefinedError })!?value_mod.Value {
        return switch (expr.*) {
            .string_literal => |lit| value_mod.Value{ .string = try self.allocator.dupe(u8, lit.value) },
            .integer_literal => |lit| value_mod.Value{ .integer = lit.value },
            .float_literal => |lit| value_mod.Value{ .float = lit.value },
            .boolean_literal => |lit| value_mod.Value{ .boolean = lit.value },
            .bin_expr => |bin| try self.optimizeBinExpr(bin),
            .unary_expr => |unary| try self.optimizeUnaryExpr(unary),
            .cond_expr => |cond| try self.optimizeCondExpr(cond),
            else => null, // Can't optimize at compile time
        };
    }

    /// Optimize binary expression (constant folding)
    fn optimizeBinExpr(self: *Self, bin: *const nodes.BinExpr) !?value_mod.Value {
        // Try to optimize left and right operands first
        // Cast away const since optimizeExpression needs mutable pointer but we're only reading
        const left_expr = @constCast(&bin.left);
        const right_expr = @constCast(&bin.right);
        const left_val = try self.optimizeExpression(left_expr);
        const right_val = try self.optimizeExpression(right_expr);

        // If both are constants, we can fold
        if (left_val) |left| {
            if (right_val) |right| {
                defer left.deinit(self.allocator);
                defer right.deinit(self.allocator);
                return try self.foldBinExpr(left, right, bin.op);
            } else {
                // Only left is constant, can't fold - free left
                var left_mut = left;
                left_mut.deinit(self.allocator);
            }
        } else if (right_val) |right| {
            // Only right is constant, can't fold - free right
            var right_mut = right;
            right_mut.deinit(self.allocator);
        }

        return null;
    }

    /// Optimize unary expression (constant folding)
    fn optimizeUnaryExpr(self: *Self, unary: *const nodes.UnaryExpr) !?value_mod.Value {
        const val = try self.optimizeExpression(@constCast(&unary.node));
        if (val) |v| {
            defer v.deinit(self.allocator);
            return try self.foldUnaryExpr(v, unary.op);
        }
        return null;
    }

    /// Optimize conditional expression (constant folding)
    fn optimizeCondExpr(self: *Self, cond: *const nodes.CondExpr) !?value_mod.Value {
        const cond_val = try self.optimizeExpression(@constCast(&cond.condition));
        if (cond_val) |c| {
            defer c.deinit(self.allocator);
            if (try c.isTruthy()) {
                return try self.optimizeExpression(@constCast(&cond.true_expr));
            } else {
                return try self.optimizeExpression(@constCast(&cond.false_expr));
            }
        }
        return null;
    }

    /// Fold binary expression with constant values
    fn foldBinExpr(self: *Self, left: value_mod.Value, right: value_mod.Value, op: @import("lexer.zig").TokenKind) !value_mod.Value {
        // This is a simplified version - full implementation would handle all operators
        return switch (op) {
            .ADD => {
                const left_int = left.toInteger();
                const right_int = right.toInteger();
                if (left_int != null and right_int != null) {
                    return value_mod.Value{ .integer = left_int.? + right_int.? };
                }
                const left_float = left.toFloat();
                const right_float = right.toFloat();
                if (left_float != null and right_float != null) {
                    return value_mod.Value{ .float = left_float.? + right_float.? };
                }
                // String concatenation
                const left_str = try left.toString(self.allocator);
                defer self.allocator.free(left_str);
                const right_str = try right.toString(self.allocator);
                defer self.allocator.free(right_str);
                var result = std.ArrayList(u8){};
                defer result.deinit(self.allocator);
                try result.appendSlice(self.allocator, left_str);
                try result.appendSlice(self.allocator, right_str);
                return value_mod.Value{ .string = try result.toOwnedSlice(self.allocator) };
            },
            .SUB => {
                const left_int = left.toInteger();
                const right_int = right.toInteger();
                if (left_int != null and right_int != null) {
                    return value_mod.Value{ .integer = left_int.? - right_int.? };
                }
                const left_float = left.toFloat();
                const right_float = right.toFloat();
                if (left_float != null and right_float != null) {
                    return value_mod.Value{ .float = left_float.? - right_float.? };
                }
                return value_mod.Value{ .null = {} };
            },
            .MUL => {
                const left_int = left.toInteger();
                const right_int = right.toInteger();
                if (left_int != null and right_int != null) {
                    return value_mod.Value{ .integer = left_int.? * right_int.? };
                }
                const left_float = left.toFloat();
                const right_float = right.toFloat();
                if (left_float != null and right_float != null) {
                    return value_mod.Value{ .float = left_float.? * right_float.? };
                }
                return value_mod.Value{ .null = {} };
            },
            .DIV => {
                const left_float = left.toFloat();
                const right_float = right.toFloat();
                if (left_float != null and right_float != null) {
                    if (right_float.? == 0.0) {
                        return value_mod.Value{ .null = {} };
                    }
                    return value_mod.Value{ .float = left_float.? / right_float.? };
                }
                return value_mod.Value{ .null = {} };
            },
            .EQ => value_mod.Value{ .boolean = left.isEqual(right) catch false },
            .NE => value_mod.Value{ .boolean = !(left.isEqual(right) catch false) },
            .LT => {
                const left_int = left.toInteger();
                const right_int = right.toInteger();
                if (left_int != null and right_int != null) {
                    return value_mod.Value{ .boolean = left_int.? < right_int.? };
                }
                const left_float = left.toFloat();
                const right_float = right.toFloat();
                if (left_float != null and right_float != null) {
                    return value_mod.Value{ .boolean = left_float.? < right_float.? };
                }
                return value_mod.Value{ .null = {} };
            },
            .GT => {
                const left_int = left.toInteger();
                const right_int = right.toInteger();
                if (left_int != null and right_int != null) {
                    return value_mod.Value{ .boolean = left_int.? > right_int.? };
                }
                const left_float = left.toFloat();
                const right_float = right.toFloat();
                if (left_float != null and right_float != null) {
                    return value_mod.Value{ .boolean = left_float.? > right_float.? };
                }
                return value_mod.Value{ .null = {} };
            },
            .AND => value_mod.Value{ .boolean = (left.isTruthy() catch false) and (right.isTruthy() catch false) },
            .OR => value_mod.Value{ .boolean = (left.isTruthy() catch false) or (right.isTruthy() catch false) },
            else => value_mod.Value{ .null = {} },
        };
    }

    /// Fold unary expression with constant value
    fn foldUnaryExpr(self: *Self, val: value_mod.Value, op: @import("lexer.zig").TokenKind) !value_mod.Value {
        _ = self;
        return switch (op) {
            .ADD => val, // Unary plus - no change
            .SUB => {
                const int_val = val.toInteger();
                if (int_val) |i| {
                    return value_mod.Value{ .integer = -i };
                }
                const float_val = val.toFloat();
                if (float_val) |f| {
                    return value_mod.Value{ .float = -f };
                }
                return value_mod.Value{ .null = {} };
            },
            .NOT => value_mod.Value{ .boolean = !(val.isTruthy() catch false) },
            else => val,
        };
    }

    /// Remove dead code from template
    /// Removes unreachable code (e.g., after return statements, false conditions, etc.)
    pub fn removeDeadCode(self: *Self, template: *nodes.Template) !void {
        // Optimize template body
        try self.optimizeStatements(&template.body);

        // Optimize blocks
        var block_iter = template.blocks.iterator();
        while (block_iter.next()) |entry| {
            const block = entry.value_ptr.*;
            try self.optimizeStatements(&block.body);
        }
    }

    /// Optimize a list of statements, removing dead code
    fn optimizeStatements(self: *Self, statements: *std.ArrayList(*nodes.Stmt)) !void {
        var i: usize = 0;
        while (i < statements.items.len) {
            const stmt = statements.items[i];

            switch (stmt.tag) {
                .if_stmt => {
                    const if_stmt = @as(*nodes.If, @ptrCast(@alignCast(stmt)));
                    // Try to optimize the condition
                    const cond_val = try self.optimizeExpression(&if_stmt.condition);

                    if (cond_val) |val| {
                        defer val.deinit(self.allocator);

                        // If condition is constant, replace if with appropriate branch
                        if (val.isTruthy() catch false) {
                            // Condition is always true - replace with body
                            // First, optimize the body
                            try self.optimizeStatements(&if_stmt.body);

                            // Remove the if statement and replace with its body
                            // Deinit the if statement
                            if_stmt.deinit(self.allocator);
                            self.allocator.destroy(if_stmt);

                            // Insert body statements in place of if
                            const body_stmts = if_stmt.body.items;
                            _ = statements.orderedRemove(i);

                            // Insert body statements
                            for (body_stmts) |body_stmt| {
                                try statements.insert(self.allocator, i, body_stmt);
                                i += 1;
                            }

                            // Don't increment i - we'll process the inserted statements
                            continue;
                        } else {
                            // Condition is always false - check for else/elif
                            if (if_stmt.else_body.items.len > 0) {
                                // Replace with else body
                                try self.optimizeStatements(&if_stmt.else_body);

                                const else_stmts = if_stmt.else_body.items;
                                if_stmt.deinit(self.allocator);
                                self.allocator.destroy(if_stmt);

                                _ = statements.orderedRemove(i);

                                for (else_stmts) |else_stmt| {
                                    try statements.insert(self.allocator, i, else_stmt);
                                    i += 1;
                                }
                                continue;
                            } else {
                                // No else - remove the if statement entirely
                                if_stmt.deinit(self.allocator);
                                self.allocator.destroy(if_stmt);
                                _ = statements.orderedRemove(i);
                                // Don't increment i - check next statement
                                continue;
                            }
                        }
                    } else {
                        // Condition is not constant - optimize branches recursively
                        try self.optimizeStatements(&if_stmt.body);
                        try self.optimizeStatements(&if_stmt.else_body);
                    }
                },
                .for_loop => {
                    const for_loop = @as(*nodes.For, @ptrCast(@alignCast(stmt)));
                    // Optimize loop body
                    try self.optimizeStatements(&for_loop.body);
                    try self.optimizeStatements(&for_loop.else_body);
                },
                .block => {
                    const block = @as(*nodes.Block, @ptrCast(@alignCast(stmt)));
                    try self.optimizeStatements(&block.body);
                },
                .with => {
                    const with_stmt = @as(*nodes.With, @ptrCast(@alignCast(stmt)));
                    try self.optimizeStatements(&with_stmt.body);
                },
                .filter_block => {
                    const filter_block = @as(*nodes.FilterBlock, @ptrCast(@alignCast(stmt)));
                    try self.optimizeStatements(&filter_block.body);
                },
                .call_block => {
                    const call_block = @as(*nodes.CallBlock, @ptrCast(@alignCast(stmt)));
                    try self.optimizeStatements(&call_block.body);
                },
                else => {},
            }

            i += 1;
        }
    }

    /// Optimize output statements
    /// Merges consecutive output statements, removes empty outputs
    pub fn optimizeOutput(self: *Self, template: *nodes.Template) !void {
        // Optimize template body
        try self.optimizeOutputStatements(&template.body);

        // Optimize blocks
        var block_iter = template.blocks.iterator();
        while (block_iter.next()) |entry| {
            const block = entry.value_ptr.*;
            try self.optimizeOutputStatements(&block.body);
        }
    }

    /// Optimize output statements in a statement list
    fn optimizeOutputStatements(self: *Self, statements: *std.ArrayList(*nodes.Stmt)) !void {
        var i: usize = 0;
        while (i < statements.items.len) {
            const stmt = statements.items[i];

            // Check if this is an output statement
            if (stmt.tag == .output) {
                const output = @as(*nodes.Output, @ptrCast(@alignCast(stmt)));

                // Check if output is empty (no content and no expressions)
                const is_empty = (output.content.len == 0 and output.nodes.items.len == 0);

                if (is_empty) {
                    // Remove empty output
                    output.deinit(self.allocator);
                    self.allocator.destroy(output);
                    _ = statements.orderedRemove(i);
                    // Don't increment i - check next statement
                    continue;
                }

                // Try to merge with next consecutive output
                // IMPORTANT: We can only merge safely if both outputs are pure content
                // (no expressions) OR if we maintain the order: content then expressions
                if (i + 1 < statements.items.len) {
                    const next_stmt = statements.items[i + 1];
                    if (next_stmt.tag == .output) {
                        const next_output = @as(*nodes.Output, @ptrCast(@alignCast(next_stmt)));

                        // Only merge if current output has NO expressions
                        // This ensures content ordering is preserved
                        // (content always comes before expressions in Output)
                        if (output.nodes.items.len == 0) {
                            // Safe to merge: current has only content, we can append next's content
                            // then append next's expressions
                            if (next_output.content.len > 0) {
                                if (output.content.len > 0) {
                                    // Concatenate content
                                    var new_content = std.ArrayList(u8).empty;
                                    defer new_content.deinit(self.allocator);
                                    try new_content.appendSlice(self.allocator, output.content);
                                    try new_content.appendSlice(self.allocator, next_output.content);
                                    self.allocator.free(output.content);
                                    output.content = try new_content.toOwnedSlice(self.allocator);
                                } else {
                                    // Move content from next_output to output
                                    output.content = next_output.content;
                                    next_output.content = ""; // Prevent double-free
                                }
                            }

                            // Move expressions from next_output to output
                            for (next_output.nodes.items) |expr| {
                                try output.nodes.append(self.allocator, expr);
                            }

                            // Clear next_output's nodes list (but don't free expressions - they're now in output)
                            next_output.nodes.clearRetainingCapacity();

                            // Remove next_output
                            next_output.deinit(self.allocator);
                            self.allocator.destroy(next_output);
                            _ = statements.orderedRemove(i + 1);

                            // Continue to check if there are more consecutive outputs
                            continue;
                        }
                        // If current has expressions, DON'T merge - preserve ordering
                    }
                }
            } else {
                // Recursively optimize nested statements
                switch (stmt.tag) {
                    .if_stmt => {
                        const if_stmt = @as(*nodes.If, @ptrCast(@alignCast(stmt)));
                        try self.optimizeOutputStatements(&if_stmt.body);
                        try self.optimizeOutputStatements(&if_stmt.else_body);
                    },
                    .for_loop => {
                        const for_loop = @as(*nodes.For, @ptrCast(@alignCast(stmt)));
                        try self.optimizeOutputStatements(&for_loop.body);
                        try self.optimizeOutputStatements(&for_loop.else_body);
                    },
                    .block => {
                        const block = @as(*nodes.Block, @ptrCast(@alignCast(stmt)));
                        try self.optimizeOutputStatements(&block.body);
                    },
                    .with => {
                        const with_stmt = @as(*nodes.With, @ptrCast(@alignCast(stmt)));
                        try self.optimizeOutputStatements(&with_stmt.body);
                    },
                    .filter_block => {
                        const filter_block = @as(*nodes.FilterBlock, @ptrCast(@alignCast(stmt)));
                        try self.optimizeOutputStatements(&filter_block.body);
                    },
                    .call_block => {
                        const call_block = @as(*nodes.CallBlock, @ptrCast(@alignCast(stmt)));
                        try self.optimizeOutputStatements(&call_block.body);
                    },
                    .set => {
                        const set_stmt = @as(*nodes.Set, @ptrCast(@alignCast(stmt)));
                        if (set_stmt.body) |*body| {
                            try self.optimizeOutputStatements(body);
                        }
                    },
                    else => {},
                }
            }

            i += 1;
        }
    }
};

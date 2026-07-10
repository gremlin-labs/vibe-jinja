//! AST-to-bytecode generation.
const std = @import("std");
const nodes = @import("nodes.zig");
const exceptions = @import("exceptions.zig");
const semantics = @import("semantics.zig");
const types = @import("bytecode_types.zig");
const Opcode = types.Opcode;
const MacroParam = types.MacroParam;
const MacroInfo = types.MacroInfo;
const Bytecode = types.Bytecode;

const fast_filter_opcodes = std.StaticStringMap(Opcode).initComptime(.{
    .{ "upper", .FILTER_UPPER },
    .{ "lower", .FILTER_LOWER },
    .{ "escape", .FILTER_ESCAPE },
    .{ "e", .FILTER_ESCAPE },
    .{ "length", .FILTER_LENGTH },
    .{ "trim", .FILTER_TRIM },
    .{ "first", .FILTER_FIRST },
    .{ "last", .FILTER_LAST },
    .{ "string", .FILTER_STRING },
    .{ "int", .FILTER_INT },
});

const loop_attribute_ids = std.StaticStringMap(u32).initComptime(.{
    .{ "index", 1 },
    .{ "index0", 2 },
    .{ "first", 3 },
    .{ "last", 4 },
    .{ "length", 5 },
    .{ "depth", 6 },
    .{ "depth0", 7 },
});

/// Bytecode generator - converts AST to bytecode
pub const BytecodeGenerator = struct {
    allocator: std.mem.Allocator,
    bytecode: Bytecode,

    const Self = @This();

    /// Initialize a new bytecode generator
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .bytecode = Bytecode.init(allocator),
        };
    }

    /// Deinitialize the generator
    pub fn deinit(self: *Self) void {
        self.bytecode.deinit();
    }

    /// Generate bytecode from template AST
    pub fn generate(self: *Self, template: *nodes.Template) !Bytecode {
        // Generate bytecode for template body
        try self.generateStatements(template.body.items);

        // Add END instruction
        try self.bytecode.addInstruction(.END, 0);

        return self.bytecode;
    }

    /// Generate bytecode for a list of statements
    fn generateStatements(self: *Self, statements: []*nodes.Stmt) std.mem.Allocator.Error!void {
        for (statements) |stmt| {
            try self.generateStatement(stmt);
        }
    }

    /// Generate bytecode for a single statement
    fn generateStatement(self: *Self, stmt: *nodes.Stmt) std.mem.Allocator.Error!void {
        switch (stmt.tag) {
            .output => {
                const output = @as(*nodes.Output, @ptrCast(@alignCast(stmt)));
                try self.generateOutput(output);
            },
            .if_stmt => {
                const if_stmt = @as(*nodes.If, @ptrCast(@alignCast(stmt)));
                try self.generateIf(if_stmt);
            },
            .for_loop => {
                const for_loop = @as(*nodes.For, @ptrCast(@alignCast(stmt)));
                try self.generateFor(for_loop);
            },
            .block => {
                const block = @as(*nodes.Block, @ptrCast(@alignCast(stmt)));
                try self.generateStatements(block.body.items);
            },
            .set => {
                const set_stmt = @as(*nodes.Set, @ptrCast(@alignCast(stmt)));
                try self.generateSet(set_stmt);
            },
            .with => {
                const with_stmt = @as(*nodes.With, @ptrCast(@alignCast(stmt)));
                try self.generateWith(with_stmt);
            },
            .break_stmt => {
                // Break out of current loop
                try self.bytecode.addInstruction(.BREAK_LOOP, 0);
            },
            .continue_stmt => {
                // Continue to next loop iteration
                try self.bytecode.addInstruction(.CONTINUE_LOOP, 0);
            },
            .macro => {
                const macro_stmt = @as(*nodes.Macro, @ptrCast(@alignCast(stmt)));
                try self.generateMacro(macro_stmt);
            },
            .call => {
                const call_stmt = @as(*nodes.Call, @ptrCast(@alignCast(stmt)));
                try self.generateCall(call_stmt);
            },
            .call_block => {
                const call_block_stmt = @as(*nodes.CallBlock, @ptrCast(@alignCast(stmt)));
                try self.generateCallBlock(call_block_stmt);
            },
            .extends, .include, .import, .from_import, .filter_block, .comment, .autoescape, .expr_stmt, .debug_stmt => {
                // These are handled at compile time or need special handling
                // For now, skip them in bytecode generation
            },
        }
    }

    /// Generate bytecode for output statement
    fn generateOutput(self: *Self, output: *nodes.Output) !void {
        // Output plain text if present
        if (output.content.len > 0) {
            const text_idx = try self.bytecode.addString(output.content);
            try self.bytecode.addInstruction(.OUTPUT_TEXT, text_idx);
        }

        // Output expressions
        for (output.nodes.items) |expr| {
            try self.generateExpression(expr);
            try self.bytecode.addInstruction(.OUTPUT, 1);
        }
    }

    /// Generate bytecode for if statement
    fn generateIf(self: *Self, if_stmt: *nodes.If) !void {
        // Track all jumps that need to go to the end
        var jumps_to_end = std.ArrayList(u32).empty;
        defer jumps_to_end.deinit(self.allocator);
        try jumps_to_end.ensureTotalCapacity(self.allocator, 1 + if_stmt.elif_conditions.items.len);

        // Generate main if condition
        try self.generateExpression(if_stmt.condition);

        // Jump if false to first elif or else/end
        const jump_if_false_idx = self.bytecode.getCurrentIndex();
        try self.bytecode.addInstruction(.JUMP_IF_FALSE, 0); // Placeholder

        // Generate if body
        try self.generateStatements(if_stmt.body.items);

        // Jump to end (skip elif/else)
        jumps_to_end.appendAssumeCapacity(self.bytecode.getCurrentIndex());
        try self.bytecode.addInstruction(.JUMP, 0); // Placeholder

        // Update jump_if_false to point to first elif or else
        self.bytecode.instructions.items[@as(usize, @intCast(jump_if_false_idx))].operand = self.bytecode.getCurrentIndex();

        // Generate elif conditions and bodies
        for (if_stmt.elif_conditions.items, 0..) |elif_cond, i| {
            // Generate elif condition
            try self.generateExpression(elif_cond);

            // Jump if false to next elif or else/end
            const elif_jump_if_false_idx = self.bytecode.getCurrentIndex();
            try self.bytecode.addInstruction(.JUMP_IF_FALSE, 0); // Placeholder

            // Generate elif body
            try self.generateStatements(if_stmt.elif_bodies.items[i].items);

            // Jump to end
            jumps_to_end.appendAssumeCapacity(self.bytecode.getCurrentIndex());
            try self.bytecode.addInstruction(.JUMP, 0); // Placeholder

            // Update elif jump_if_false to point to next elif or else
            self.bytecode.instructions.items[@as(usize, @intCast(elif_jump_if_false_idx))].operand = self.bytecode.getCurrentIndex();
        }

        // Generate else body if present
        if (if_stmt.else_body.items.len > 0) {
            try self.generateStatements(if_stmt.else_body.items);
        }

        // Update all jumps_to_end to point to here
        const end_idx = self.bytecode.getCurrentIndex();
        for (jumps_to_end.items) |jump_idx| {
            self.bytecode.instructions.items[@as(usize, @intCast(jump_idx))].operand = end_idx;
        }
    }

    /// Generate bytecode for for loop
    fn generateFor(self: *Self, for_loop: *nodes.For) !void {
        // Extract target variable name
        const var_name = switch (for_loop.target) {
            .name => |n| n.name,
            else => return, // Only support simple name targets for now
        };
        const var_name_idx = try self.bytecode.addName(var_name);

        // Generate iterable expression (pushes iterable to stack)
        try self.generateExpression(for_loop.iter);

        // FOR_LOOP_START: operand = variable name index
        // VM will pop iterable, initialize loop state, push first item
        // If iterable is empty, VM will jump past FOR_LOOP_END (to else body or end)
        const loop_start_idx = self.bytecode.getCurrentIndex();
        try self.bytecode.addInstruction(.FOR_LOOP_START, var_name_idx);

        // Store current item to loop variable (VM pushes item, we store it)
        try self.bytecode.addInstruction(.STORE_VAR, var_name_idx);

        // Generate loop body
        try self.generateStatements(for_loop.body.items);

        // FOR_LOOP_END: operand = loop_start_idx (to jump back)
        // VM will advance index, push next item if available, jump back
        try self.bytecode.addInstruction(.FOR_LOOP_END, loop_start_idx);

        // Generate else body if present
        if (for_loop.else_body.items.len > 0) {
            // If loop completed normally (at least one iteration), skip else
            // We add a JUMP here that will be taken after normal loop completion
            const jump_over_else_idx = self.bytecode.getCurrentIndex();
            try self.bytecode.addInstruction(.JUMP, 0); // Placeholder

            // This is where empty iterable jumps to (VM modifies behavior)
            // Actually, we need to mark this as "else start" - VM will jump here for empty
            // For now, generate else body and update jump
            try self.generateStatements(for_loop.else_body.items);

            // Update jump_over_else to skip else body
            const end_idx = self.bytecode.getCurrentIndex();
            self.bytecode.instructions.items[@as(usize, @intCast(jump_over_else_idx))].operand = end_idx;
        }
    }

    /// Generate bytecode for set statement
    fn generateSet(self: *Self, set_stmt: *nodes.Set) !void {
        // Generate value expression
        try self.generateExpression(set_stmt.value);

        // Store variable
        const name_idx = try self.bytecode.addName(set_stmt.name);
        try self.bytecode.addInstruction(.STORE_VAR, name_idx);
    }

    /// Generate bytecode for with statement
    fn generateWith(self: *Self, with_stmt: *nodes.With) !void {
        // Generate context expressions and store variables
        for (with_stmt.targets.items, with_stmt.values.items) |target, val_expr| {
            try self.generateExpression(val_expr);
            const name_idx = try self.bytecode.addName(target);
            try self.bytecode.addInstruction(.STORE_VAR, name_idx);
        }

        // Generate body
        try self.generateStatements(with_stmt.body.items);
    }

    /// Generate bytecode for macro definition
    fn generateMacro(self: *Self, macro: *nodes.Macro) !void {
        // Create macro info
        const name_copy = try self.allocator.dupe(u8, macro.name);
        var macro_info = MacroInfo.init(self.allocator, name_copy);
        try macro_info.params.ensureTotalCapacity(self.allocator, macro.args.items.len);

        // Add macro parameters
        for (macro.args.items) |arg| {
            var param = MacroParam{
                // fallow-zig-ignore-next-line zig-alloc-inside-token-loop: compile-time macro metadata owns parameter names for cached bytecode, not per-render allocation.
                .name = try self.allocator.dupe(u8, arg.name),
                .has_default = arg.default_value != null,
                .default_expr_idx = null,
            };

            if (arg.default_value) |default_expr| {
                // For simple literals, extract the value directly
                // We store the string index for string defaults
                switch (default_expr) {
                    .string_literal => |lit| {
                        const str_idx = try self.bytecode.addString(lit.value);
                        // Encode: high bit set = string, lower bits = string index
                        param.default_expr_idx = 0x80000000 | str_idx;
                    },
                    .integer_literal => |lit| {
                        // Encode: high 2 bits = 01 for int, lower bits = value
                        param.default_expr_idx = 0x40000000 | @as(u32, @intCast(lit.value & 0x3FFFFFFF));
                    },
                    .boolean_literal => |lit| {
                        // Encode: high 2 bits = 11 for bool
                        param.default_expr_idx = 0xC0000000 | (if (lit.value) @as(u32, 1) else 0);
                    },
                    .null_literal => {
                        // Encode: special value for null
                        param.default_expr_idx = 0x00000001;
                    },
                    else => {
                        // Complex expressions not supported yet
                        param.default_expr_idx = 0x00000001; // Default to null
                    },
                }
            }

            macro_info.params.appendAssumeCapacity(param);
        }

        macro_info.catch_varargs = macro.catch_varargs;
        macro_info.catch_kwargs = macro.catch_kwargs;

        // Record macro body start
        // First add a JUMP to skip over macro body (macro defs don't execute inline)
        const jump_over_macro = self.bytecode.getCurrentIndex();
        try self.bytecode.addInstruction(.JUMP, 0); // Placeholder, will be patched

        // Record body start
        macro_info.body_start = self.bytecode.getCurrentIndex();

        // Generate macro body
        try self.generateStatements(macro.body.items);

        // Add RETURN at end of macro body
        try self.bytecode.addInstruction(.RETURN, 0);

        // Record body end
        macro_info.body_end = self.bytecode.getCurrentIndex();

        // Patch the jump to skip over macro body
        self.bytecode.instructions.items[@intCast(jump_over_macro)].operand = macro_info.body_end;

        // Add macro to bytecode
        const macro_idx = try self.bytecode.addMacro(macro_info);

        // Generate DEFINE_MACRO instruction to register at runtime
        const name_idx = try self.bytecode.addName(macro.name);
        // Encode: lower 16 bits = name_idx, upper 16 bits = macro_idx
        const operand = (macro_idx << 16) | (name_idx & 0xFFFF);
        try self.bytecode.addInstruction(.DEFINE_MACRO, operand);
    }

    /// Generate bytecode for macro call
    fn generateCall(self: *Self, call: *nodes.Call) !void {
        // Get macro name
        const macro_name = switch (call.macro_expr) {
            .name => |n| n.name,
            else => {
                // Complex expression - evaluate it and output
                try self.generateExpression(call.macro_expr);
                try self.bytecode.addInstruction(.OUTPUT, 1);
                return;
            },
        };

        // Push arguments onto stack in order
        for (call.args.items) |arg| {
            try self.generateExpression(arg);
        }

        // Push kwargs count and values
        var kwargs_count: u32 = 0;
        var kw_iter = call.kwargs.iterator();
        while (kw_iter.next()) |entry| {
            // Push key name index
            const key_idx = try self.bytecode.addName(entry.key_ptr.*);
            try self.bytecode.addInstruction(.LOAD_INT, key_idx);
            // Push value
            try self.generateExpression(entry.value_ptr.*);
            kwargs_count += 1;
        }

        // Generate CALL_MACRO instruction
        const name_idx = try self.bytecode.addName(macro_name);
        const arg_count: u32 = @intCast(call.args.items.len);
        // Encode: bits [0-7] = arg_count, bits [8-15] = kwargs_count, bits [16-31] = name_idx
        const operand = (name_idx << 16) | (kwargs_count << 8) | (arg_count & 0xFF);
        try self.bytecode.addInstruction(.CALL_MACRO, operand);

        // Output the macro result
        try self.bytecode.addInstruction(.OUTPUT, 1);
    }

    /// Generate bytecode for call block (macro call with body)
    fn generateCallBlock(self: *Self, call_block: *nodes.CallBlock) !void {
        // Extract macro name from call expression
        const macro_name = switch (call_block.call_expr) {
            .name => |n| n.name,
            .call_expr => |call| blk: {
                break :blk switch (call.func) {
                    .name => |n| n.name,
                    else => {
                        // Complex expression - skip for now
                        return;
                    },
                };
            },
            else => return,
        };

        // Generate caller body as a nested bytecode section
        // First, record the jump over caller body
        const jump_over_caller = self.bytecode.getCurrentIndex();
        try self.bytecode.addInstruction(.JUMP, 0); // Placeholder

        // Record caller body start
        const caller_body_start = self.bytecode.getCurrentIndex();

        // Generate caller body
        try self.generateStatements(call_block.body.items);

        // Add RETURN at end of caller body
        try self.bytecode.addInstruction(.RETURN, 0);

        // Record caller body end
        const caller_body_end = self.bytecode.getCurrentIndex();

        // Patch jump
        self.bytecode.instructions.items[@intCast(jump_over_caller)].operand = caller_body_end;

        // Now generate the actual call with caller info
        // Push arguments from call_expr if present
        var arg_count: u32 = 0;
        if (call_block.call_expr == .call_expr) {
            const call = call_block.call_expr.call_expr;
            for (call.args.items) |arg| {
                try self.generateExpression(arg);
            }
            arg_count = @intCast(call.args.items.len);
        }

        // Push caller body location onto stack (as two integers: start, end)
        try self.bytecode.addInstruction(.LOAD_INT, caller_body_start);
        try self.bytecode.addInstruction(.LOAD_INT, caller_body_end);

        // Generate CALL_MACRO_WITH_CALLER instruction
        const name_idx = try self.bytecode.addName(macro_name);
        // Encode: lower 16 bits = name_idx, upper 16 bits = arg_count
        const operand = (arg_count << 16) | (name_idx & 0xFFFF);
        try self.bytecode.addInstruction(.CALL_MACRO_WITH_CALLER, operand);

        // Output the macro result
        try self.bytecode.addInstruction(.OUTPUT, 1);
    }

    /// Generate bytecode for an expression.
    fn generateExpression(self: *Self, expr: nodes.Expression) std.mem.Allocator.Error!void {
        return switch (expr) {
            .string_literal,
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .name,
            .null_literal,
            .list_literal,
            .nsref,
            .slice,
            .concat,
            .environment_attribute,
            .extension_attribute,
            .imported_name,
            .internal_name,
            .context_reference,
            .derived_context_reference,
            => self.generateScalarExpression(expr),
            .bin_expr, .unary_expr => self.generateOperatorExpression(expr),
            .getattr, .getitem => self.generateAccessExpression(expr),
            .filter, .test_expr => self.generateFilterExpression(expr),
            .cond_expr => self.generateConditionalExpression(expr),
            .call_expr => self.generateCallExpression(expr),
        };
    }

    fn generateScalarExpression(self: *Self, expr: nodes.Expression) std.mem.Allocator.Error!void {
        switch (expr) {
            .string_literal => |lit| {
                const str_idx = try self.bytecode.addString(lit.value);
                try self.bytecode.addInstruction(.LOAD_STRING, str_idx);
            },
            .integer_literal => |lit| {
                try self.bytecode.addInstruction(.LOAD_INT, @as(u32, @intCast(lit.value)));
            },
            .float_literal => |lit| {
                // Convert float to u32 bits for storage
                const bits = @as(u32, @bitCast(@as(f32, @floatCast(lit.value))));
                try self.bytecode.addInstruction(.LOAD_FLOAT, bits);
            },
            .boolean_literal => |lit| {
                try self.bytecode.addInstruction(.LOAD_BOOL, if (lit.value) 1 else 0);
            },
            .name => |n| {
                const name_idx = try self.bytecode.addName(n.name);
                try self.bytecode.addInstruction(.LOAD_VAR, name_idx);
            },
            .null_literal => {
                try self.bytecode.addInstruction(.LOAD_NULL, 0);
            },
            .list_literal => |list| {
                // Generate each element
                for (list.elements.items) |elem| {
                    try self.generateExpression(elem);
                }
                // Build list with count of elements
                try self.bytecode.addInstruction(.BUILD_LIST, @as(u32, @intCast(list.elements.items.len)));
            },
            // These expression types are handled specially or not yet implemented in bytecode
            .nsref, .slice, .concat, .environment_attribute, .extension_attribute, .imported_name, .internal_name, .context_reference, .derived_context_reference => {
                // Not yet implemented in bytecode - these require special handling
                // For now, push undefined
                try self.bytecode.addInstruction(.LOAD_NULL, 0);
            },
            else => unreachable,
        }
    }

    fn generateOperatorExpression(self: *Self, expr: nodes.Expression) std.mem.Allocator.Error!void {
        switch (expr) {
            .bin_expr => |bin| {
                // Generate left operand
                try self.generateExpression(bin.left);
                // Generate right operand
                try self.generateExpression(bin.right);
                // Generate binary operation
                const op_val = self.getBinOpValue(bin.op);
                try self.bytecode.addInstruction(.BIN_OP, op_val);
            },
            .unary_expr => |unary| {
                // Generate operand
                try self.generateExpression(unary.node);
                // Generate unary operation
                const op_val = self.getUnaryOpValue(unary.op);
                try self.bytecode.addInstruction(.UNARY_OP, op_val);
            },
            else => unreachable,
        }
    }

    fn generateAccessExpression(self: *Self, expr: nodes.Expression) std.mem.Allocator.Error!void {
        return switch (expr) {
            .getattr => |attribute| self.generateGetattr(attribute),
            .getitem => |item| self.generateGetitem(item),
            else => unreachable,
        };
    }

    fn generateGetattr(self: *Self, attribute: *nodes.Getattr) std.mem.Allocator.Error!void {
        if (attribute.node == .name and std.mem.eql(u8, attribute.node.name.name, "loop")) {
            if (loop_attribute_ids.get(attribute.attr)) |id| {
                return self.bytecode.addInstruction(.GET_LOOP_VAR, id);
            }
        }
        try self.generateExpression(attribute.node);
        const name_index = try self.bytecode.addName(attribute.attr);
        try self.bytecode.addInstruction(.GET_ATTR, name_index);
    }

    fn generateSlice(self: *Self, slice: *nodes.Slice) std.mem.Allocator.Error!void {
        var flags: u32 = 0;
        if (slice.start) |start| {
            try self.generateExpression(start);
            flags |= 1;
        }
        if (slice.stop) |stop| {
            try self.generateExpression(stop);
            flags |= 2;
        }
        if (slice.step) |step| {
            try self.generateExpression(step);
            flags |= 4;
        }
        try self.bytecode.addInstruction(.GET_SLICE, flags);
    }

    fn generateGetitem(self: *Self, item: *nodes.Getitem) std.mem.Allocator.Error!void {
        try self.generateExpression(item.node);
        if (item.arg == .slice) return self.generateSlice(item.arg.slice);
        try self.generateExpression(item.arg);
        try self.bytecode.addInstruction(.GET_ITEM, 0);
    }

    fn generateFilterExpression(self: *Self, expr: nodes.Expression) std.mem.Allocator.Error!void {
        return switch (expr) {
            .filter => |filter| self.generateFilter(filter),
            .test_expr => |test_expression| self.generateTest(test_expression),
            else => unreachable,
        };
    }

    fn generateDefaultFilter(self: *Self, filter: *nodes.FilterExpr) std.mem.Allocator.Error!bool {
        if (!std.mem.eql(u8, filter.name, "default") and !std.mem.eql(u8, filter.name, "d")) return false;
        if (filter.args.items.len == 0) {
            const string_index = try self.bytecode.addString("");
            try self.bytecode.addInstruction(.FILTER_DEFAULT, (1 << 16) | (string_index & 0xFFFF));
            return true;
        }
        return switch (filter.args.items[0]) {
            .string_literal => |literal| blk: {
                const string_index = try self.bytecode.addString(literal.value);
                try self.bytecode.addInstruction(.FILTER_DEFAULT, (1 << 16) | (string_index & 0xFFFF));
                break :blk true;
            },
            .integer_literal => |literal| blk: {
                if (literal.value < 0 or literal.value >= 0x7FFF) break :blk false;
                try self.bytecode.addInstruction(.FILTER_DEFAULT, (2 << 16) | @as(u32, @intCast(literal.value & 0xFFFF)));
                break :blk true;
            },
            .boolean_literal => |literal| blk: {
                try self.bytecode.addInstruction(.FILTER_DEFAULT, (3 << 16) | @as(u32, if (literal.value) 1 else 0));
                break :blk true;
            },
            else => false,
        };
    }

    fn generateGenericFilter(self: *Self, filter: *nodes.FilterExpr) std.mem.Allocator.Error!void {
        for (filter.args.items) |argument| try self.generateExpression(argument);
        var keyword_count: u32 = 0;
        var iterator = filter.kwargs.iterator();
        while (iterator.next()) |entry| {
            const key_index = try self.bytecode.addName(entry.key_ptr.*);
            try self.bytecode.addInstruction(.LOAD_INT, key_index);
            try self.generateExpression(entry.value_ptr.*);
            keyword_count += 1;
        }
        const name_index = try self.bytecode.addName(filter.name);
        const argument_count: u32 = @intCast(filter.args.items.len);
        const operand = (name_index << 16) | ((keyword_count & 0xFF) << 8) | (argument_count & 0xFF);
        try self.bytecode.addInstruction(.APPLY_FILTER, operand);
    }

    fn generateFilter(self: *Self, filter: *nodes.FilterExpr) std.mem.Allocator.Error!void {
        try self.generateExpression(filter.node);
        if (filter.args.items.len == 0) {
            if (fast_filter_opcodes.get(filter.name)) |opcode| {
                return self.bytecode.addInstruction(opcode, 0);
            }
        }
        if (try self.generateDefaultFilter(filter)) return;
        try self.generateGenericFilter(filter);
    }

    fn generateTest(self: *Self, test_expression: *nodes.TestExpr) std.mem.Allocator.Error!void {
        try self.generateExpression(test_expression.node);
        for (test_expression.args.items) |argument| try self.generateExpression(argument);
        const name_index = try self.bytecode.addName(test_expression.name);
        const argument_count: u32 = @intCast(test_expression.args.items.len);
        try self.bytecode.addInstruction(.APPLY_TEST, (argument_count << 16) | (name_index & 0xFFFF));
    }

    fn generateConditionalExpression(self: *Self, expr: nodes.Expression) std.mem.Allocator.Error!void {
        switch (expr) {
            .cond_expr => |cond| {
                // Generate condition
                try self.generateExpression(cond.condition);
                // Jump if false to false branch
                const jump_false_idx = self.bytecode.getCurrentIndex();
                try self.bytecode.addInstruction(.JUMP_IF_FALSE, 0); // Placeholder

                // Generate true branch
                try self.generateExpression(cond.true_expr);

                // Jump to end
                const jump_end_idx = self.bytecode.getCurrentIndex();
                try self.bytecode.addInstruction(.JUMP, 0); // Placeholder

                // Update jump_false
                const false_start_idx = self.bytecode.getCurrentIndex();
                self.bytecode.instructions.items[@as(usize, @intCast(jump_false_idx))].operand = false_start_idx;

                // Generate false branch
                try self.generateExpression(cond.false_expr);

                // Update jump_end
                const end_idx = self.bytecode.getCurrentIndex();
                self.bytecode.instructions.items[@as(usize, @intCast(jump_end_idx))].operand = end_idx;
            },
            else => unreachable,
        }
    }

    fn generateArguments(self: *Self, arguments: []nodes.Expression) std.mem.Allocator.Error!void {
        for (arguments) |argument| try self.generateExpression(argument);
    }

    fn generateKeywordArguments(self: *Self, keywords: *std.StringHashMap(nodes.Expression)) std.mem.Allocator.Error!u32 {
        var count: u32 = 0;
        var iterator = keywords.iterator();
        while (iterator.next()) |entry| {
            const key_index = try self.bytecode.addName(entry.key_ptr.*);
            try self.bytecode.addInstruction(.LOAD_INT, key_index);
            try self.generateExpression(entry.value_ptr.*);
            count += 1;
        }
        return count;
    }

    fn generateNamedCall(self: *Self, call: *nodes.CallExpr) std.mem.Allocator.Error!void {
        const name = call.func.name.name;
        if (std.mem.eql(u8, name, "caller")) return self.bytecode.addInstruction(.INVOKE_CALLER, 0);
        try self.generateArguments(call.args.items);
        const name_index = try self.bytecode.addName(name);
        const argument_count: u32 = @intCast(call.args.items.len);
        if (call.kwargs.count() == 0) {
            return self.bytecode.addInstruction(.CALL_GLOBAL, (argument_count << 16) | (name_index & 0xFFFF));
        }
        const keyword_count = try self.generateKeywordArguments(&call.kwargs);
        try self.bytecode.addInstruction(.CALL_MACRO, (name_index << 16) | (keyword_count << 8) | (argument_count & 0xFF));
    }

    fn generateAttributeCall(self: *Self, call: *nodes.CallExpr) std.mem.Allocator.Error!void {
        const attribute = call.func.getattr;
        if (attribute.node == .name and std.mem.eql(u8, attribute.node.name.name, "loop")) {
            if (std.mem.eql(u8, attribute.attr, "cycle") or std.mem.eql(u8, attribute.attr, "changed")) {
                try self.generateArguments(call.args.items);
                const opcode: Opcode = if (std.mem.eql(u8, attribute.attr, "cycle")) .LOOP_CYCLE else .LOOP_CHANGED;
                return self.bytecode.addInstruction(opcode, @intCast(call.args.items.len));
            }
            try self.generateExpression(call.func);
            try self.generateArguments(call.args.items);
            return self.bytecode.addInstruction(.CALL_FUNC, @intCast(call.args.items.len));
        }

        try self.generateExpression(attribute.node);
        try self.generateArguments(call.args.items);
        const name_index = try self.bytecode.addName(attribute.attr);
        try self.bytecode.addInstruction(.APPLY_FILTER, (name_index << 16) | (@as(u32, @intCast(call.args.items.len)) & 0xFF));
    }

    fn generateCallExpression(self: *Self, expr: nodes.Expression) std.mem.Allocator.Error!void {
        const call = switch (expr) {
            .call_expr => |call| call,
            else => unreachable,
        };
        return switch (call.func) {
            .name => self.generateNamedCall(call),
            .getattr => self.generateAttributeCall(call),
            else => {
                try self.generateExpression(call.func);
                try self.generateArguments(call.args.items);
                return self.bytecode.addInstruction(.CALL_FUNC, @intCast(call.args.items.len));
            },
        };
    }

    /// Get binary operator value for bytecode
    fn getBinOpValue(self: *Self, op: @import("lexer.zig").TokenKind) u32 {
        _ = self;
        return @intFromEnum(semantics.BinaryOp.fromTokenKind(op) orelse .add);
    }

    /// Get unary operator value for bytecode
    fn getUnaryOpValue(self: *Self, op: @import("lexer.zig").TokenKind) u32 {
        _ = self;
        return switch (op) {
            .ADD => 0,
            .SUB => 1,
            .NOT => 2,
            else => 0,
        };
    }

    /// Calculate checksum of template source
    pub fn calculateChecksum(source: []const u8) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(source);
        return hasher.final();
    }
};

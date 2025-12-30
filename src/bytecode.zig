//! Bytecode Compilation and Virtual Machine
//!
//! This module implements the bytecode instruction set and serialization for the Jinja
//! template engine. Bytecode compilation allows templates to be cached in a compact,
//! efficient format that can be quickly loaded and executed.
//!
//! # Instruction Set
//!
//! The bytecode uses a stack-based virtual machine with the following instruction categories:
//!
//! ## Literal Loading
//! - `LOAD_CONST` - Load from constant pool
//! - `LOAD_STRING`, `LOAD_INT`, `LOAD_FLOAT`, `LOAD_BOOL`, `LOAD_NULL` - Load literals
//! - `LOAD_INT_0`, `LOAD_INT_1`, `LOAD_INT_NEG1` - Optimized small integer loads
//!
//! ## Variables
//! - `LOAD_VAR`, `STORE_VAR` - Load/store variables by name
//! - `LOAD_LOCAL`, `STORE_LOCAL` - Optimized local variable access
//!
//! ## Operations
//! - `BIN_OP`, `UNARY_OP` - Generic binary/unary operations
//! - `ADD`, `SUB`, `MUL`, `DIV`, `MOD` - Specialized arithmetic
//! - `COMPARE_EQ`, `COMPARE_NE`, `COMPARE_LT`, etc. - Comparisons
//!
//! ## Control Flow
//! - `JUMP`, `JUMP_IF_FALSE`, `JUMP_IF_TRUE` - Conditional/unconditional jumps
//! - `SETUP_LOOP`, `END_LOOP`, `BREAK_LOOP`, `CONTINUE_LOOP` - Loop control
//!
//! ## Blocks & Templates
//! - `DEFINE_BLOCK`, `CALL_BLOCK`, `SUPER_BLOCK` - Block handling
//! - `INCLUDE`, `EXTENDS` - Template inclusion/inheritance
//!
//! # Serialization
//!
//! Bytecode can be serialized to/from bytes for caching:
//!
//! ```zig
//! // Serialize bytecode
//! const bytes = try bytecode.serialize(allocator);
//! defer allocator.free(bytes);
//!
//! // Deserialize bytecode
//! const loaded = try jinja.bytecode.Bytecode.deserialize(allocator, bytes);
//! defer loaded.deinit(allocator);
//! ```
//!
//! # Bytecode Format
//!
//! The serialization format is:
//! 1. Magic bytes: "VJBC" (4 bytes)
//! 2. Version: u32 (4 bytes)
//! 3. Checksum: u64 (8 bytes)
//! 4. Instruction count: u32 (4 bytes)
//! 5. Instructions (variable)
//! 6. Constant pool (variable)
//! 7. String pool (variable)
//! 8. Name pool (variable)

const std = @import("std");
const nodes = @import("nodes.zig");

/// Bytecode instruction types
/// Optimized instruction set with specialized opcodes for common operations
pub const Opcode = enum(u8) {
    // Literals
    LOAD_CONST, // Load from constant pool (operand = constant index)
    LOAD_STRING, // Load string literal (operand = string index in constants)
    LOAD_INT, // Load integer (operand = integer value)
    LOAD_FLOAT, // Load float (operand = float bits as u32)
    LOAD_BOOL, // Load boolean (operand = 0 for false, 1 for true)
    LOAD_NULL, // Load null value

    // Specialized small integer loads (optimization for common loop values)
    LOAD_INT_0, // Load integer 0 (no operand needed)
    LOAD_INT_1, // Load integer 1 (no operand needed)
    LOAD_INT_NEG1, // Load integer -1 (no operand needed)

    // Variables
    LOAD_VAR, // Load variable (operand = variable name index)
    STORE_VAR, // Store variable (operand = variable name index)
    LOAD_LOCAL, // Load local variable (optimized, operand = slot index)
    STORE_LOCAL, // Store local variable (optimized, operand = slot index)

    // Operations
    BIN_OP, // Binary operation (operand = operator enum value)
    UNARY_OP, // Unary operation (operand = operator enum value)
    GET_ATTR, // Get attribute (operand = attribute name index)
    GET_ITEM, // Get item (operand = key name index, or use stack)
    CALL_FUNC, // Call function (operand = arg count)
    APPLY_FILTER, // Apply filter (operand = filter name index)
    APPLY_TEST, // Apply test (operand = test name index)
    BUILD_LIST, // Build list from stack (operand = element count)
    BUILD_DICT, // Build dict from stack (operand = pair count)

    // Specialized binary operations (optimization for common operations)
    ADD, // Add top two stack values
    SUB, // Subtract top two stack values
    MUL, // Multiply top two stack values
    DIV, // Divide top two stack values
    MOD, // Modulo top two stack values
    EQ, // Compare equality
    NE, // Compare inequality
    LT, // Less than
    LE, // Less than or equal
    GT, // Greater than
    GE, // Greater than or equal

    // Specialized unary operations
    NOT, // Logical not
    NEG, // Negate number

    // Control flow
    JUMP_IF_FALSE, // Jump if false (operand = target instruction index)
    JUMP_IF_TRUE, // Jump if true (operand = target instruction index)
    JUMP, // Unconditional jump (operand = target instruction index)
    RETURN, // Return from function
    POP, // Pop and discard top of stack
    DUP, // Duplicate top of stack

    // Template operations
    OUTPUT, // Output value to result (operand = expression count)
    OUTPUT_TEXT, // Output plain text (operand = text index)
    OUTPUT_ESCAPED, // Output HTML-escaped value (combines escape + output)
    CALL_MACRO, // Call macro (operand = macro name index)

    // Loops
    FOR_LOOP_START, // Start for loop (operand = iterable index)
    FOR_LOOP_END, // End for loop (operand = jump back target)
    FOR_LOOP_NEXT, // Get next loop iteration (optimization)
    GET_LOOP_VAR, // Get loop variable (index, index0, first, last, etc.)
    BREAK_LOOP, // Break out of current loop
    CONTINUE_LOOP, // Continue to next loop iteration

    // Specialized filters (common filters as single opcodes)
    FILTER_UPPER, // Apply upper filter
    FILTER_LOWER, // Apply lower filter
    FILTER_ESCAPE, // Apply escape filter
    FILTER_LENGTH, // Apply length filter
    FILTER_DEFAULT, // Apply default filter (operand = default value index)
    FILTER_TRIM, // Apply trim filter
    FILTER_FIRST, // Apply first filter
    FILTER_LAST, // Apply last filter
    FILTER_STRING, // Apply string filter (convert to string)
    FILTER_INT, // Apply int filter (convert to integer)

    // End marker
    END,
};

/// Bytecode instruction
pub const Instruction = struct {
    opcode: Opcode,
    operand: u32, // Can represent index, value, etc.

    const Self = @This();

    pub fn init(opcode: Opcode, operand: u32) Self {
        return Self{
            .opcode = opcode,
            .operand = operand,
        };
    }
};

/// Bytecode representation of a template
pub const Bytecode = struct {
    instructions: std.ArrayList(Instruction),
    constants: std.ArrayList(*nodes.Expression), // Constant pool for expressions
    strings: std.ArrayList([]const u8), // String constant pool
    names: std.ArrayList([]const u8), // Variable/name constant pool
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new bytecode
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .instructions = std.ArrayList(Instruction).empty,
            .constants = std.ArrayList(*nodes.Expression).empty,
            .strings = std.ArrayList([]const u8).empty,
            .names = std.ArrayList([]const u8).empty,
            .allocator = allocator,
        };
    }

    /// Deinitialize bytecode
    pub fn deinit(self: *Self) void {
        // Constants are owned by template, don't free them
        self.constants.deinit(self.allocator);
        // Free string copies
        for (self.strings.items) |str| {
            self.allocator.free(str);
        }
        self.strings.deinit(self.allocator);
        // Free name copies
        for (self.names.items) |name| {
            self.allocator.free(name);
        }
        self.names.deinit(self.allocator);
        self.instructions.deinit(self.allocator);
    }

    /// Add an instruction
    pub fn addInstruction(self: *Self, opcode: Opcode, operand: u32) !void {
        try self.instructions.append(self.allocator, Instruction.init(opcode, operand));
    }

    /// Add a constant expression to the constant pool
    pub fn addConstant(self: *Self, constant: *nodes.Expression) !u32 {
        const index = @as(u32, @intCast(self.constants.items.len));
        try self.constants.append(self.allocator, constant);
        return index;
    }

    /// Add a string to the string pool
    pub fn addString(self: *Self, str: []const u8) !u32 {
        // Check if string already exists
        for (self.strings.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, str)) {
                return @as(u32, @intCast(i));
            }
        }
        // Add new string
        const str_copy = try self.allocator.dupe(u8, str);
        const index = @as(u32, @intCast(self.strings.items.len));
        try self.strings.append(self.allocator, str_copy);
        return index;
    }

    /// Add a name to the name pool
    pub fn addName(self: *Self, name: []const u8) !u32 {
        // Check if name already exists
        for (self.names.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, name)) {
                return @as(u32, @intCast(i));
            }
        }
        // Add new name
        const name_copy = try self.allocator.dupe(u8, name);
        const index = @as(u32, @intCast(self.names.items.len));
        try self.names.append(self.allocator, name_copy);
        return index;
    }

    /// Get current instruction index (for jumps)
    pub fn getCurrentIndex(self: *const Self) u32 {
        return @as(u32, @intCast(self.instructions.items.len));
    }
};

/// Bytecode cache entry
pub const BytecodeCacheEntry = struct {
    bytecode: Bytecode,
    template_name: []const u8,
    checksum: u64, // Checksum of template source

    pub fn deinit(self: *BytecodeCacheEntry, allocator: std.mem.Allocator) void {
        self.bytecode.deinit();
        allocator.free(self.template_name);
        allocator.destroy(self);
    }
};

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
            .extends, .include, .import, .from_import, .macro, .call, .call_block, .filter_block, .comment, .autoescape, .expr_stmt, .debug_stmt => {
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

        // Generate main if condition
        try self.generateExpression(if_stmt.condition);

        // Jump if false to first elif or else/end
        const jump_if_false_idx = self.bytecode.getCurrentIndex();
        try self.bytecode.addInstruction(.JUMP_IF_FALSE, 0); // Placeholder

        // Generate if body
        try self.generateStatements(if_stmt.body.items);

        // Jump to end (skip elif/else)
        try jumps_to_end.append(self.allocator, self.bytecode.getCurrentIndex());
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
            try jumps_to_end.append(self.allocator, self.bytecode.getCurrentIndex());
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

    /// Generate bytecode for an expression
    fn generateExpression(self: *Self, expr: nodes.Expression) !void {
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
            .getattr => |attr| {
                // Phase 6: Fast path for loop.* attributes
                if (attr.node == .name) {
                    const var_name = attr.node.name.name;
                    if (std.mem.eql(u8, var_name, "loop")) {
                        // Direct loop attribute access - use GET_LOOP_VAR
                        const loop_attr_id: u32 = if (std.mem.eql(u8, attr.attr, "index"))
                            1 // index (1-based)
                        else if (std.mem.eql(u8, attr.attr, "index0"))
                            2 // index0 (0-based)
                        else if (std.mem.eql(u8, attr.attr, "first"))
                            3
                        else if (std.mem.eql(u8, attr.attr, "last"))
                            4
                        else if (std.mem.eql(u8, attr.attr, "length"))
                            5
                        else
                            255; // Unknown - fall through to generic

                        if (loop_attr_id != 255) {
                            try self.bytecode.addInstruction(.GET_LOOP_VAR, loop_attr_id);
                            return;
                        }
                    }
                }

                // Generic attribute access
                try self.generateExpression(attr.node);
                const name_idx = try self.bytecode.addName(attr.attr);
                try self.bytecode.addInstruction(.GET_ATTR, name_idx);
            },
            .getitem => |item| {
                // Generate object expression
                try self.generateExpression(item.node);
                // Generate key/index expression
                try self.generateExpression(item.arg);
                // Get item
                try self.bytecode.addInstruction(.GET_ITEM, 0);
            },
            .filter => |filter| {
                // Generate base expression
                try self.generateExpression(filter.node);

                // Phase 5: Use specialized opcodes for common filters (no lookup overhead)
                // Only use fast path for no-argument filters
                var used_fast_path = false;
                if (filter.args.items.len == 0) {
                    if (std.mem.eql(u8, filter.name, "upper")) {
                        try self.bytecode.addInstruction(.FILTER_UPPER, 0);
                        used_fast_path = true;
                    } else if (std.mem.eql(u8, filter.name, "lower")) {
                        try self.bytecode.addInstruction(.FILTER_LOWER, 0);
                        used_fast_path = true;
                    } else if (std.mem.eql(u8, filter.name, "escape") or std.mem.eql(u8, filter.name, "e")) {
                        try self.bytecode.addInstruction(.FILTER_ESCAPE, 0);
                        used_fast_path = true;
                    } else if (std.mem.eql(u8, filter.name, "length")) {
                        try self.bytecode.addInstruction(.FILTER_LENGTH, 0);
                        used_fast_path = true;
                    } else if (std.mem.eql(u8, filter.name, "trim")) {
                        try self.bytecode.addInstruction(.FILTER_TRIM, 0);
                        used_fast_path = true;
                    } else if (std.mem.eql(u8, filter.name, "first")) {
                        try self.bytecode.addInstruction(.FILTER_FIRST, 0);
                        used_fast_path = true;
                    } else if (std.mem.eql(u8, filter.name, "last")) {
                        try self.bytecode.addInstruction(.FILTER_LAST, 0);
                        used_fast_path = true;
                    } else if (std.mem.eql(u8, filter.name, "string")) {
                        try self.bytecode.addInstruction(.FILTER_STRING, 0);
                        used_fast_path = true;
                    } else if (std.mem.eql(u8, filter.name, "int")) {
                        try self.bytecode.addInstruction(.FILTER_INT, 0);
                        used_fast_path = true;
                    }
                }

                // Phase 6: Optimized default filter with pre-compiled default value
                if (!used_fast_path and (std.mem.eql(u8, filter.name, "default") or std.mem.eql(u8, filter.name, "d"))) {
                    if (filter.args.items.len >= 1) {
                        const default_arg = filter.args.items[0];
                        // Check if default argument is a constant we can pre-compile
                        switch (default_arg) {
                            .string_literal => |lit| {
                                // Store default string in string pool
                                const str_idx = try self.bytecode.addString(lit.value);
                                // Operand: lower 16 bits = string index, bit 16 = is_string flag (1)
                                const operand = (1 << 16) | (str_idx & 0xFFFF);
                                try self.bytecode.addInstruction(.FILTER_DEFAULT, operand);
                                used_fast_path = true;
                            },
                            .integer_literal => |lit| {
                                // Encode integer directly (for small positive integers)
                                // Operand: lower 16 bits = value, bit 16 = 0 (not string), bit 17 = is_int (1)
                                if (lit.value >= 0 and lit.value < 0x7FFF) {
                                    const operand = (2 << 16) | @as(u32, @intCast(lit.value & 0xFFFF));
                                    try self.bytecode.addInstruction(.FILTER_DEFAULT, operand);
                                    used_fast_path = true;
                                }
                            },
                            .boolean_literal => |lit| {
                                // Operand: lower bit = value, bit 16-17 = type (3 = bool)
                                const operand = (3 << 16) | @as(u32, if (lit.value) 1 else 0);
                                try self.bytecode.addInstruction(.FILTER_DEFAULT, operand);
                                used_fast_path = true;
                            },
                            else => {
                                // Complex default expression - fall through to generic filter
                            },
                        }
                    } else {
                        // No argument - use empty string as default
                        const str_idx = try self.bytecode.addString("");
                        const operand = (1 << 16) | (str_idx & 0xFFFF);
                        try self.bytecode.addInstruction(.FILTER_DEFAULT, operand);
                        used_fast_path = true;
                    }
                }

                if (!used_fast_path) {
                    // Generate filter arguments (push to stack in order)
                    for (filter.args.items) |arg| {
                        try self.generateExpression(arg);
                    }

                    // Generic filter - operand encodes name_idx in lower bits, arg count in upper bits
                    const name_idx = try self.bytecode.addName(filter.name);
                    const arg_count: u32 = @intCast(filter.args.items.len);
                    // Pack: lower 16 bits = name_idx, upper 16 bits = arg_count
                    const operand = (arg_count << 16) | (name_idx & 0xFFFF);
                    try self.bytecode.addInstruction(.APPLY_FILTER, operand);
                }
            },
            .test_expr => |test_expr| {
                // Generate expression to test
                try self.generateExpression(test_expr.node);
                // Generate test arguments (push to stack in order)
                for (test_expr.args.items) |arg| {
                    try self.generateExpression(arg);
                }
                // Apply test - operand encodes name_idx in lower bits, arg count in upper bits
                const name_idx = try self.bytecode.addName(test_expr.name);
                const arg_count: u32 = @intCast(test_expr.args.items.len);
                // Pack: lower 16 bits = name_idx, upper 16 bits = arg_count
                const operand = (arg_count << 16) | (name_idx & 0xFFFF);
                try self.bytecode.addInstruction(.APPLY_TEST, operand);
            },
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
            .call_expr => |call| {
                // Generate function expression
                try self.generateExpression(call.func);
                // Generate arguments
                for (call.args.items) |arg| {
                    try self.generateExpression(arg);
                }
                // Call function
                try self.bytecode.addInstruction(.CALL_FUNC, @as(u32, @intCast(call.args.items.len)));
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
        }
    }

    /// Get binary operator value for bytecode
    fn getBinOpValue(self: *Self, op: @import("lexer.zig").TokenKind) u32 {
        _ = self;
        return switch (op) {
            .ADD => 0,
            .SUB => 1,
            .MUL => 2,
            .DIV => 3,
            .FLOORDIV => 4,
            .MOD => 5,
            .POW => 6,
            .EQ => 7,
            .NE => 8,
            .LT => 9,
            .LTEQ => 10,
            .GT => 11,
            .GTEQ => 12,
            .AND => 13,
            .OR => 14,
            .IN => 15,
            else => 0,
        };
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

/// Bytecode VM/Interpreter - executes bytecode
pub const BytecodeVM = struct {
    allocator: std.mem.Allocator,
    bytecode: *const Bytecode,
    stack: std.ArrayList(value_mod.Value),
    variables: std.StringHashMap(value_mod.Value),
    result: std.ArrayList(u8),
    context: *context.Context,
    environment: *environment.Environment,
    /// Loop state stack for nested loops
    loop_stack: std.ArrayList(LoopState),
    /// Phase 6: Local variable slots (O(1) access by index)
    locals: [MAX_LOCALS]?value_mod.Value,
    locals_count: u8,

    const Self = @This();
    const Value = value_mod.Value;
    const Context = @import("context.zig").Context;
    const Environment = @import("environment.zig").Environment;
    const MAX_LOCALS = 64; // Maximum local variables per scope

    /// State for a single loop iteration
    const LoopState = struct {
        iterable: Value, // The iterable value (OWNED - must be freed)
        items: []const Value, // Items being iterated (reference into iterable)
        index: usize, // Current iteration index
        var_name: []const u8, // Loop variable name
        loop_start_pc: u32, // PC of FOR_LOOP_START instruction
        local_slot: u8, // Slot index for loop variable (Phase 6)
    };

    /// Initialize a new VM
    pub fn init(allocator: std.mem.Allocator, bytecode: *const Bytecode, ctx: *Context) Self {
        return Self{
            .allocator = allocator,
            .bytecode = bytecode,
            .stack = std.ArrayList(Value).empty,
            .variables = std.StringHashMap(Value).init(allocator),
            .result = std.ArrayList(u8).empty,
            .context = ctx,
            .environment = ctx.environment,
            .loop_stack = std.ArrayList(LoopState).empty,
            .locals = [_]?Value{null} ** MAX_LOCALS,
            .locals_count = 0,
        };
    }

    /// Deinitialize the VM
    pub fn deinit(self: *Self) void {
        // Clean up loop stack (free any remaining iterables)
        for (self.loop_stack.items) |*state| {
            state.iterable.deinit(self.allocator);
        }
        self.loop_stack.deinit(self.allocator);

        // Clean up stack values
        for (self.stack.items) |*val| {
            val.deinit(self.allocator);
        }
        self.stack.deinit(self.allocator);

        // Clean up variables (keys AND values are owned by VM)
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.variables.deinit();

        // Clean up locals (Phase 6)
        for (&self.locals) |*local| {
            if (local.*) |*val| {
                val.deinit(self.allocator);
                local.* = null;
            }
        }

        self.result.deinit(self.allocator);
    }

    /// Execute bytecode and return result string
    pub fn execute(self: *Self) ![]const u8 {
        var pc: u32 = 0; // Program counter

        while (pc < self.bytecode.instructions.items.len) {
            const instr = self.bytecode.instructions.items[@as(usize, @intCast(pc))];
            pc += 1;

            switch (instr.opcode) {
                .LOAD_STRING => {
                    const str = self.bytecode.strings.items[@as(usize, @intCast(instr.operand))];
                    const str_copy = try self.allocator.dupe(u8, str);
                    try self.stack.append(self.allocator, Value{ .string = str_copy });
                },
                .LOAD_INT => {
                    try self.stack.append(self.allocator, Value{ .integer = @as(i64, @intCast(instr.operand)) });
                },
                .LOAD_FLOAT => {
                    const float_val = @as(f32, @bitCast(instr.operand));
                    try self.stack.append(self.allocator, Value{ .float = @as(f64, @floatCast(float_val)) });
                },
                .LOAD_BOOL => {
                    try self.stack.append(self.allocator, Value{ .boolean = instr.operand != 0 });
                },
                .LOAD_NULL => {
                    try self.stack.append(self.allocator, Value{ .null = {} });
                },
                .LOAD_VAR => {
                    const name = self.bytecode.names.items[@as(usize, @intCast(instr.operand))];
                    const val = try self.loadVariable(name);
                    try self.stack.append(self.allocator, val);
                },
                .STORE_VAR => {
                    const name = self.bytecode.names.items[@as(usize, @intCast(instr.operand))];
                    const val = self.stack.pop() orelse Value{ .null = {} };

                    // Check if variable already exists (re-assignment in loop)
                    if (self.variables.getEntry(name)) |entry| {
                        // Free old value, reuse key
                        entry.value_ptr.*.deinit(self.allocator);
                        entry.value_ptr.* = val;
                    } else {
                        // New variable - duplicate key
                        const name_copy = try self.allocator.dupe(u8, name);
                        try self.variables.put(name_copy, val);
                    }
                },
                // Phase 6: Slot-based local variables (O(1) access)
                .LOAD_LOCAL => {
                    const slot = @as(u8, @intCast(instr.operand));
                    if (slot < MAX_LOCALS) {
                        if (self.locals[slot]) |val| {
                            // Deep copy since caller may modify/free
                            const copy = try val.deepCopy(self.allocator);
                            try self.stack.append(self.allocator, copy);
                        } else {
                            try self.stack.append(self.allocator, Value{ .null = {} });
                        }
                    } else {
                        try self.stack.append(self.allocator, Value{ .null = {} });
                    }
                },
                .STORE_LOCAL => {
                    const slot = @as(u8, @intCast(instr.operand));
                    const val = self.stack.pop() orelse Value{ .null = {} };

                    if (slot < MAX_LOCALS) {
                        // Free old value if exists
                        if (self.locals[slot]) |*old| {
                            old.deinit(self.allocator);
                        }
                        self.locals[slot] = val;
                        if (slot >= self.locals_count) {
                            self.locals_count = slot + 1;
                        }
                    } else {
                        val.deinit(self.allocator);
                    }
                },
                .BIN_OP => {
                    const right = self.stack.pop() orelse Value{ .null = {} };
                    defer right.deinit(self.allocator);
                    const left = self.stack.pop() orelse Value{ .null = {} };
                    defer left.deinit(self.allocator);

                    const result = try self.executeBinOp(left, right, instr.operand);
                    try self.stack.append(self.allocator, result);
                },
                .UNARY_OP => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    const result = try self.executeUnaryOp(val, instr.operand);
                    try self.stack.append(self.allocator, result);
                },
                .GET_ATTR => {
                    const obj = self.stack.pop() orelse Value{ .null = {} };
                    defer obj.deinit(self.allocator);
                    const attr_name = self.bytecode.names.items[@as(usize, @intCast(instr.operand))];

                    const result = try self.getAttribute(obj, attr_name);
                    try self.stack.append(self.allocator, result);
                },
                .GET_ITEM => {
                    const key = self.stack.pop() orelse Value{ .null = {} };
                    defer key.deinit(self.allocator);
                    const obj = self.stack.pop() orelse Value{ .null = {} };
                    defer obj.deinit(self.allocator);

                    const result = try self.getItem(obj, key);
                    try self.stack.append(self.allocator, result);
                },
                .APPLY_FILTER => {
                    // Unpack operand: lower 16 bits = name_idx, upper 16 bits = arg_count
                    const name_idx = instr.operand & 0xFFFF;
                    const arg_count = instr.operand >> 16;

                    // Pop arguments from stack (in reverse order)
                    var args = try self.allocator.alloc(Value, arg_count);
                    defer {
                        for (args) |*arg| {
                            arg.deinit(self.allocator);
                        }
                        self.allocator.free(args);
                    }
                    var i: usize = arg_count;
                    while (i > 0) {
                        i -= 1;
                        args[i] = self.stack.pop() orelse Value{ .null = {} };
                    }

                    // Pop value to filter
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    const filter_name = self.bytecode.names.items[@as(usize, @intCast(name_idx))];
                    const filter = self.environment.getFilter(filter_name) orelse {
                        return exceptions.TemplateError.RuntimeError;
                    };

                    // Apply filter with arguments
                    const result = try filter.func(self.allocator, val, args, self.context, self.environment);
                    try self.stack.append(self.allocator, result);
                },
                // Phase 5: Specialized inline filter opcodes (no lookup overhead)
                .FILTER_UPPER => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    const str = val.toString(self.allocator) catch {
                        val.deinit(self.allocator);
                        try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                        continue;
                    };
                    val.deinit(self.allocator);

                    // Fast path: check if already uppercase
                    var needs_change = false;
                    for (str) |c| {
                        if (std.ascii.isLower(c)) {
                            needs_change = true;
                            break;
                        }
                    }
                    if (!needs_change) {
                        try self.stack.append(self.allocator, Value{ .string = str });
                        continue;
                    }

                    // Convert to uppercase
                    const result = try self.allocator.alloc(u8, str.len);
                    for (str, 0..) |c, i| {
                        result[i] = std.ascii.toUpper(c);
                    }
                    self.allocator.free(str);
                    try self.stack.append(self.allocator, Value{ .string = result });
                },
                .FILTER_LOWER => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    const str = val.toString(self.allocator) catch {
                        val.deinit(self.allocator);
                        try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                        continue;
                    };
                    val.deinit(self.allocator);

                    // Fast path: check if already lowercase
                    var needs_change = false;
                    for (str) |c| {
                        if (std.ascii.isUpper(c)) {
                            needs_change = true;
                            break;
                        }
                    }
                    if (!needs_change) {
                        try self.stack.append(self.allocator, Value{ .string = str });
                        continue;
                    }

                    // Convert to lowercase
                    const result = try self.allocator.alloc(u8, str.len);
                    for (str, 0..) |c, i| {
                        result[i] = std.ascii.toLower(c);
                    }
                    self.allocator.free(str);
                    try self.stack.append(self.allocator, Value{ .string = result });
                },
                .FILTER_ESCAPE => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    const str = val.toString(self.allocator) catch {
                        val.deinit(self.allocator);
                        try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                        continue;
                    };
                    val.deinit(self.allocator);

                    // Fast path: check if any escaping needed
                    var needs_escape = false;
                    for (str) |c| {
                        if (c == '&' or c == '<' or c == '>' or c == '"' or c == '\'') {
                            needs_escape = true;
                            break;
                        }
                    }
                    if (!needs_escape) {
                        try self.stack.append(self.allocator, Value{ .string = str });
                        continue;
                    }

                    // Slow path: actual escaping
                    var result = try std.ArrayList(u8).initCapacity(self.allocator, str.len + str.len / 2);
                    for (str) |c| {
                        switch (c) {
                            '&' => try result.appendSlice(self.allocator, "&amp;"),
                            '<' => try result.appendSlice(self.allocator, "&lt;"),
                            '>' => try result.appendSlice(self.allocator, "&gt;"),
                            '"' => try result.appendSlice(self.allocator, "&quot;"),
                            '\'' => try result.appendSlice(self.allocator, "&#x27;"),
                            else => try result.append(self.allocator, c),
                        }
                    }
                    self.allocator.free(str);
                    try self.stack.append(self.allocator, Value{ .string = try result.toOwnedSlice(self.allocator) });
                },
                .FILTER_LENGTH => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    const len: i64 = switch (val) {
                        .string => |s| @intCast(s.len),
                        .list => |l| @intCast(l.items.items.len),
                        .dict => |d| @intCast(d.map.count()),
                        else => 0,
                    };
                    val.deinit(self.allocator);
                    try self.stack.append(self.allocator, Value{ .integer = len });
                },
                .FILTER_DEFAULT => {
                    // Phase 6: Optimized default filter with pre-compiled default value
                    // Operand encoding:
                    //   bits 16-17: type (1=string, 2=int, 3=bool)
                    //   bits 0-15: value (string index, int value, or bool 0/1)
                    const val = self.stack.pop() orelse Value{ .null = {} };

                    // Fast inline truthiness check - avoid function call overhead
                    const is_truthy = switch (val) {
                        .null => false,
                        .undefined => false,
                        .boolean => |b| b,
                        .integer => |i| i != 0,
                        .float => |f| f != 0.0,
                        .string => |s| s.len > 0,
                        .list => |l| l.items.items.len > 0,
                        .dict => |d| d.map.count() > 0,
                        else => true,
                    };

                    if (is_truthy) {
                        // Value is truthy - return it as-is (already on stack conceptually)
                        try self.stack.append(self.allocator, val);
                    } else {
                        // Value is falsy - use pre-compiled default
                        val.deinit(self.allocator);

                        const value_type = (instr.operand >> 16) & 0x3;
                        const value_data = instr.operand & 0xFFFF;

                        const default_val: Value = switch (value_type) {
                            1 => blk: {
                                // String default
                                const default_str = self.bytecode.strings.items[@as(usize, @intCast(value_data))];
                                break :blk Value{ .string = try self.allocator.dupe(u8, default_str) };
                            },
                            2 => blk: {
                                // Integer default
                                break :blk Value{ .integer = @as(i64, @intCast(value_data)) };
                            },
                            3 => blk: {
                                // Boolean default
                                break :blk Value{ .boolean = value_data != 0 };
                            },
                            else => blk: {
                                // Fallback - empty string
                                break :blk Value{ .string = try self.allocator.dupe(u8, "") };
                            },
                        };
                        try self.stack.append(self.allocator, default_val);
                    }
                },
                .FILTER_TRIM => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    const str = val.toString(self.allocator) catch {
                        val.deinit(self.allocator);
                        try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                        continue;
                    };
                    val.deinit(self.allocator);

                    // Trim whitespace (returns slice into original string)
                    const trimmed = std.mem.trim(u8, str, " \t\n\r");

                    // If same length, no trimming needed - return original
                    if (trimmed.len == str.len) {
                        try self.stack.append(self.allocator, Value{ .string = str });
                    } else {
                        // Allocate trimmed copy, free original
                        const result = try self.allocator.dupe(u8, trimmed);
                        self.allocator.free(str);
                        try self.stack.append(self.allocator, Value{ .string = result });
                    }
                },
                .FILTER_FIRST => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    switch (val) {
                        .list => |l| {
                            if (l.items.items.len > 0) {
                                const first = try l.items.items[0].deepCopy(self.allocator);
                                val.deinit(self.allocator);
                                try self.stack.append(self.allocator, first);
                            } else {
                                val.deinit(self.allocator);
                                try self.stack.append(self.allocator, Value{ .null = {} });
                            }
                        },
                        .string => |s| {
                            if (s.len > 0) {
                                const first_char = try self.allocator.dupe(u8, s[0..1]);
                                val.deinit(self.allocator);
                                try self.stack.append(self.allocator, Value{ .string = first_char });
                            } else {
                                val.deinit(self.allocator);
                                try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                            }
                        },
                        else => {
                            val.deinit(self.allocator);
                            try self.stack.append(self.allocator, Value{ .null = {} });
                        },
                    }
                },
                .FILTER_LAST => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    switch (val) {
                        .list => |l| {
                            if (l.items.items.len > 0) {
                                const last = try l.items.items[l.items.items.len - 1].deepCopy(self.allocator);
                                val.deinit(self.allocator);
                                try self.stack.append(self.allocator, last);
                            } else {
                                val.deinit(self.allocator);
                                try self.stack.append(self.allocator, Value{ .null = {} });
                            }
                        },
                        .string => |s| {
                            if (s.len > 0) {
                                const last_char = try self.allocator.dupe(u8, s[s.len - 1 ..]);
                                val.deinit(self.allocator);
                                try self.stack.append(self.allocator, Value{ .string = last_char });
                            } else {
                                val.deinit(self.allocator);
                                try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                            }
                        },
                        else => {
                            val.deinit(self.allocator);
                            try self.stack.append(self.allocator, Value{ .null = {} });
                        },
                    }
                },
                .FILTER_STRING => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    const str = val.toString(self.allocator) catch try self.allocator.dupe(u8, "");
                    val.deinit(self.allocator);
                    try self.stack.append(self.allocator, Value{ .string = str });
                },
                .FILTER_INT => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    const int_val: i64 = switch (val) {
                        .integer => |i| i,
                        .float => |f| @intFromFloat(f),
                        .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
                        .boolean => |b| if (b) @as(i64, 1) else 0,
                        else => 0,
                    };
                    val.deinit(self.allocator);
                    try self.stack.append(self.allocator, Value{ .integer = int_val });
                },
                .APPLY_TEST => {
                    // Unpack operand: lower 16 bits = name_idx, upper 16 bits = arg_count
                    const name_idx = instr.operand & 0xFFFF;
                    const arg_count = instr.operand >> 16;

                    // Pop arguments from stack (in reverse order)
                    var args = try self.allocator.alloc(Value, arg_count);
                    defer {
                        for (args) |*arg| {
                            arg.deinit(self.allocator);
                        }
                        self.allocator.free(args);
                    }
                    var i: usize = arg_count;
                    while (i > 0) {
                        i -= 1;
                        args[i] = self.stack.pop() orelse Value{ .null = {} };
                    }

                    // Pop value to test
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    const test_name = self.bytecode.names.items[@as(usize, @intCast(name_idx))];
                    const test_func = self.environment.getTest(test_name) orelse {
                        return exceptions.TemplateError.RuntimeError;
                    };

                    // Determine which arguments to pass based on pass_arg setting
                    const env_to_pass = switch (test_func.pass_arg) {
                        .environment => self.environment,
                        else => null,
                    };
                    const ctx_to_pass = switch (test_func.pass_arg) {
                        .context => self.context,
                        else => self.context, // Always pass context for now
                    };

                    // Apply test with arguments
                    const result = test_func.func(val, args, ctx_to_pass, env_to_pass);
                    try self.stack.append(self.allocator, Value{ .boolean = result });
                },
                .BUILD_LIST => {
                    const count = instr.operand;
                    const list_ptr = try self.allocator.create(value_mod.List);
                    list_ptr.* = value_mod.List.init(self.allocator);
                    errdefer {
                        list_ptr.deinit(self.allocator);
                        self.allocator.destroy(list_ptr);
                    }

                    // Collect elements from stack (in reverse order)
                    var temp = std.ArrayList(Value){};
                    defer temp.deinit(self.allocator);
                    var i: u32 = 0;
                    while (i < count) : (i += 1) {
                        const elem = self.stack.pop() orelse Value{ .null = {} };
                        try temp.append(self.allocator, elem);
                    }

                    // Append in reverse to restore original order
                    var j: usize = temp.items.len;
                    while (j > 0) {
                        j -= 1;
                        try list_ptr.append(temp.items[j]);
                    }

                    try self.stack.append(self.allocator, Value{ .list = list_ptr });
                },
                .CALL_FUNC => {
                    // For now, function calls are not fully implemented
                    // Would need to pop args and function, then call
                    _ = instr.operand;
                    return exceptions.TemplateError.RuntimeError;
                },
                .JUMP_IF_FALSE => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    if (!(val.isTruthy() catch false)) {
                        pc = instr.operand;
                    }
                },
                .JUMP_IF_TRUE => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    if (val.isTruthy() catch false) {
                        pc = instr.operand;
                    }
                },
                .JUMP => {
                    pc = instr.operand;
                },
                .OUTPUT => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    const str = try val.toString(self.allocator);
                    defer self.allocator.free(str);
                    try self.result.appendSlice(self.allocator, str);
                },
                .OUTPUT_TEXT => {
                    const text = self.bytecode.strings.items[@as(usize, @intCast(instr.operand))];
                    try self.result.appendSlice(self.allocator, text);
                },
                .FOR_LOOP_START => {
                    // Pop iterable from stack
                    var iterable = self.stack.pop() orelse Value{ .null = {} };

                    // Get items from iterable
                    const items: []const Value = switch (iterable) {
                        .list => |l| l.items.items,
                        else => &[_]Value{}, // Non-iterable = empty loop
                    };

                    // Get variable name from operand
                    const var_name = self.bytecode.names.items[@as(usize, @intCast(instr.operand))];

                    if (items.len == 0) {
                        // Empty iterable - skip loop body but NOT else clause
                        // Find matching FOR_LOOP_END and jump to instruction AFTER it
                        // (which is either else body or the JUMP that skips else)
                        var depth: u32 = 1;
                        while (pc < self.bytecode.instructions.items.len) {
                            const next_instr = self.bytecode.instructions.items[@as(usize, @intCast(pc))];
                            if (next_instr.opcode == .FOR_LOOP_START) depth += 1;
                            if (next_instr.opcode == .FOR_LOOP_END) {
                                depth -= 1;
                                if (depth == 0) {
                                    // Don't skip past FOR_LOOP_END - let main loop increment pc
                                    // This lands on instruction after FOR_LOOP_END
                                    // If there's else: lands on JUMP (will skip else) - WRONG
                                    // We need to skip the JUMP too!
                                    // Check if next instruction is JUMP, and if so, skip it
                                    const after_loop_end = pc + 1;
                                    if (after_loop_end < self.bytecode.instructions.items.len) {
                                        const next_after = self.bytecode.instructions.items[@as(usize, @intCast(after_loop_end))];
                                        if (next_after.opcode == .JUMP) {
                                            // Skip the JUMP to get to else body
                                            pc = after_loop_end + 1;
                                        } else {
                                            pc = after_loop_end;
                                        }
                                    } else {
                                        pc = after_loop_end;
                                    }
                                    break;
                                }
                            }
                            pc += 1;
                        }
                        // Free empty iterable immediately
                        iterable.deinit(self.allocator);
                        continue; // Don't increment pc again in main loop
                    } else {
                        // Push loop state - takes ownership of iterable
                        try self.loop_stack.append(self.allocator, LoopState{
                            .iterable = iterable,
                            .items = items,
                            .index = 0,
                            .var_name = var_name,
                            .loop_start_pc = pc, // PC after FOR_LOOP_START
                            .local_slot = 0, // Reserved for future use
                        });

                        // Push first item to stack (will be stored by next STORE_VAR)
                        const first_item = try items[0].deepCopy(self.allocator);
                        try self.stack.append(self.allocator, first_item);
                    }
                },
                .FOR_LOOP_END => {
                    // Get current loop state
                    if (self.loop_stack.items.len == 0) {
                        return exceptions.TemplateError.RuntimeError;
                    }

                    const loop_state = &self.loop_stack.items[self.loop_stack.items.len - 1];
                    loop_state.index += 1;

                    if (loop_state.index < loop_state.items.len) {
                        // More items - push next item and jump back
                        const next_item = try loop_state.items[loop_state.index].deepCopy(self.allocator);
                        try self.stack.append(self.allocator, next_item);
                        pc = instr.operand + 1; // Jump to instruction after FOR_LOOP_START
                    } else {
                        // Loop complete - free iterable and pop loop state
                        var completed_state = self.loop_stack.pop().?;
                        completed_state.iterable.deinit(self.allocator);
                    }
                },
                // Phase 6: Fast loop variable access
                .GET_LOOP_VAR => {
                    // operand indicates which loop attribute:
                    // 0 = item (current loop item)
                    // 1 = index (1-based)
                    // 2 = index0 (0-based)
                    // 3 = first
                    // 4 = last
                    // 5 = length
                    if (self.loop_stack.items.len == 0) {
                        try self.stack.append(self.allocator, Value{ .null = {} });
                        continue;
                    }

                    const loop_state = &self.loop_stack.items[self.loop_stack.items.len - 1];
                    const result: Value = switch (instr.operand) {
                        0 => try loop_state.items[loop_state.index].deepCopy(self.allocator), // item
                        1 => Value{ .integer = @intCast(loop_state.index + 1) }, // index (1-based)
                        2 => Value{ .integer = @intCast(loop_state.index) }, // index0 (0-based)
                        3 => Value{ .boolean = loop_state.index == 0 }, // first
                        4 => Value{ .boolean = loop_state.index == loop_state.items.len - 1 }, // last
                        5 => Value{ .integer = @intCast(loop_state.items.len) }, // length
                        else => Value{ .null = {} },
                    };
                    try self.stack.append(self.allocator, result);
                },
                .BREAK_LOOP => {
                    // Break out of current loop - find matching FOR_LOOP_END and jump past it
                    if (self.loop_stack.items.len == 0) {
                        return exceptions.TemplateError.RuntimeError;
                    }

                    // Pop the loop state and free iterable
                    var completed_state = self.loop_stack.pop().?;
                    completed_state.iterable.deinit(self.allocator);

                    // Find matching FOR_LOOP_END (skip nested loops)
                    var depth: u32 = 1;
                    while (pc < self.bytecode.instructions.items.len) {
                        const next_instr = self.bytecode.instructions.items[@as(usize, @intCast(pc))];
                        if (next_instr.opcode == .FOR_LOOP_START) depth += 1;
                        if (next_instr.opcode == .FOR_LOOP_END) {
                            depth -= 1;
                            if (depth == 0) {
                                pc += 1; // Skip past FOR_LOOP_END
                                break;
                            }
                        }
                        pc += 1;
                    }
                    continue; // Don't increment pc again
                },
                .CONTINUE_LOOP => {
                    // Continue to next iteration - jump back to FOR_LOOP_END
                    if (self.loop_stack.items.len == 0) {
                        return exceptions.TemplateError.RuntimeError;
                    }

                    // Find matching FOR_LOOP_END (skip nested loops)
                    var depth: u32 = 1;
                    while (pc < self.bytecode.instructions.items.len) {
                        const next_instr = self.bytecode.instructions.items[@as(usize, @intCast(pc))];
                        if (next_instr.opcode == .FOR_LOOP_START) depth += 1;
                        if (next_instr.opcode == .FOR_LOOP_END) {
                            depth -= 1;
                            if (depth == 0) {
                                // Let FOR_LOOP_END handle advancing to next iteration
                                break;
                            }
                        }
                        pc += 1;
                    }
                    continue; // Don't increment pc again, will process FOR_LOOP_END next
                },
                .RETURN => {
                    break;
                },
                .END => {
                    break;
                },
                else => {
                    return exceptions.TemplateError.RuntimeError;
                },
            }
        }

        return try self.result.toOwnedSlice(self.allocator);
    }

    /// Load a variable from context or local variables
    fn loadVariable(self: *Self, name: []const u8) !Value {
        // Check local variables first
        if (self.variables.get(name)) |val| {
            return try val.deepCopy(self.allocator);
        }

        // Check context - resolve returns Value directly (may be undefined)
        const resolved = self.context.resolve(name);
        if (resolved != .undefined) {
            return try resolved.deepCopy(self.allocator);
        }

        // Check environment globals
        if (self.environment.getGlobal(name)) |val| {
            return try val.deepCopy(self.allocator);
        }

        // Return undefined
        const name_copy = try self.allocator.dupe(u8, name);
        return Value{ .undefined = value_mod.Undefined{
            .name = name_copy,
            .behavior = self.environment.undefined_behavior,
        } };
    }

    /// Execute binary operation
    fn executeBinOp(self: *Self, left: Value, right: Value, op: u32) !Value {
        return switch (op) {
            0 => blk: { // PLUS - add
                // Check actual types first - if either is float, use float math
                if (left == .float or right == .float) {
                    const l_flt = left.toFloat() orelse break :blk Value{ .null = {} };
                    const r_flt = right.toFloat() orelse break :blk Value{ .null = {} };
                    break :blk Value{ .float = l_flt + r_flt };
                }
                // Both are integers (or can be coerced to integers)
                if (left.toInteger()) |l_int| {
                    if (right.toInteger()) |r_int| {
                        break :blk Value{ .integer = l_int + r_int };
                    }
                }
                // String concatenation
                if (left == .string or right == .string) {
                    const left_str = try left.toString(self.allocator);
                    defer self.allocator.free(left_str);
                    const right_str = try right.toString(self.allocator);
                    defer self.allocator.free(right_str);
                    const result = try std.mem.concat(self.allocator, u8, &.{ left_str, right_str });
                    break :blk Value{ .string = result };
                }
                break :blk Value{ .null = {} };
            },
            1 => blk: { // MINUS - subtract
                // Check actual types first - if either is float, use float math
                if (left == .float or right == .float) {
                    const l_flt = left.toFloat() orelse break :blk Value{ .null = {} };
                    const r_flt = right.toFloat() orelse break :blk Value{ .null = {} };
                    break :blk Value{ .float = l_flt - r_flt };
                }
                // Both are integers (or can be coerced to integers)
                if (left.toInteger()) |l_int| {
                    if (right.toInteger()) |r_int| {
                        break :blk Value{ .integer = l_int - r_int };
                    }
                }
                break :blk Value{ .null = {} };
            },
            2 => blk: { // MUL - multiply
                // Check actual types first - if either is float, use float math
                if (left == .float or right == .float) {
                    const l_flt = left.toFloat() orelse break :blk Value{ .null = {} };
                    const r_flt = right.toFloat() orelse break :blk Value{ .null = {} };
                    break :blk Value{ .float = l_flt * r_flt };
                }
                // Both are integers (or can be coerced to integers)
                if (left.toInteger()) |l_int| {
                    if (right.toInteger()) |r_int| {
                        break :blk Value{ .integer = l_int * r_int };
                    }
                }
                break :blk Value{ .null = {} };
            },
            3 => blk: { // DIV - divide
                if (left.toFloat()) |l_flt| {
                    if (right.toFloat()) |r_flt| {
                        if (r_flt == 0.0) break :blk Value{ .null = {} };
                        break :blk Value{ .float = l_flt / r_flt };
                    } else if (right.toInteger()) |r_int| {
                        if (r_int == 0) break :blk Value{ .null = {} };
                        break :blk Value{ .float = l_flt / @as(f64, @floatFromInt(r_int)) };
                    }
                } else if (left.toInteger()) |l_int| {
                    if (right.toFloat()) |r_flt| {
                        if (r_flt == 0.0) break :blk Value{ .null = {} };
                        break :blk Value{ .float = @as(f64, @floatFromInt(l_int)) / r_flt };
                    } else if (right.toInteger()) |r_int| {
                        if (r_int == 0) break :blk Value{ .null = {} };
                        break :blk Value{ .float = @as(f64, @floatFromInt(l_int)) / @as(f64, @floatFromInt(r_int)) };
                    }
                }
                break :blk Value{ .null = {} };
            },
            4 => blk: { // FLOORDIV - floor divide
                if (left.toInteger()) |l_int| {
                    if (right.toInteger()) |r_int| {
                        if (r_int == 0) break :blk Value{ .null = {} };
                        break :blk Value{ .integer = @divFloor(l_int, r_int) };
                    }
                }
                break :blk Value{ .null = {} };
            },
            5 => blk: { // MOD - modulo
                if (left.toInteger()) |l_int| {
                    if (right.toInteger()) |r_int| {
                        if (r_int == 0) break :blk Value{ .null = {} };
                        break :blk Value{ .integer = @mod(l_int, r_int) };
                    }
                }
                break :blk Value{ .null = {} };
            },
            6 => blk: { // POW - power
                // Check integers first to preserve integer type when possible
                if (left.toInteger()) |l_int| {
                    if (right.toInteger()) |r_int| {
                        if (r_int >= 0) {
                            break :blk Value{ .integer = std.math.pow(i64, l_int, @as(u6, @intCast(@min(63, r_int)))) };
                        }
                        // Negative exponent - use float
                        break :blk Value{ .float = std.math.pow(f64, @as(f64, @floatFromInt(l_int)), @as(f64, @floatFromInt(r_int))) };
                    } else if (right.toFloat()) |r_flt| {
                        break :blk Value{ .float = std.math.pow(f64, @as(f64, @floatFromInt(l_int)), r_flt) };
                    }
                } else if (left.toFloat()) |l_flt| {
                    if (right.toFloat()) |r_flt| {
                        break :blk Value{ .float = std.math.pow(f64, l_flt, r_flt) };
                    } else if (right.toInteger()) |r_int| {
                        break :blk Value{ .float = std.math.pow(f64, l_flt, @as(f64, @floatFromInt(r_int))) };
                    }
                }
                break :blk Value{ .null = {} };
            },
            7 => Value{ .boolean = left.isEqual(right) catch false }, // EQ
            8 => Value{ .boolean = !(left.isEqual(right) catch false) }, // NE
            9 => blk: { // LT - less than
                if (left.toFloat()) |l_flt| {
                    if (right.toFloat()) |r_flt| {
                        break :blk Value{ .boolean = l_flt < r_flt };
                    } else if (right.toInteger()) |r_int| {
                        break :blk Value{ .boolean = l_flt < @as(f64, @floatFromInt(r_int)) };
                    }
                } else if (left.toInteger()) |l_int| {
                    if (right.toInteger()) |r_int| {
                        break :blk Value{ .boolean = l_int < r_int };
                    } else if (right.toFloat()) |r_flt| {
                        break :blk Value{ .boolean = @as(f64, @floatFromInt(l_int)) < r_flt };
                    }
                }
                break :blk Value{ .boolean = false };
            },
            10 => blk: { // LE - less than or equal
                if (left.toFloat()) |l_flt| {
                    if (right.toFloat()) |r_flt| {
                        break :blk Value{ .boolean = l_flt <= r_flt };
                    } else if (right.toInteger()) |r_int| {
                        break :blk Value{ .boolean = l_flt <= @as(f64, @floatFromInt(r_int)) };
                    }
                } else if (left.toInteger()) |l_int| {
                    if (right.toInteger()) |r_int| {
                        break :blk Value{ .boolean = l_int <= r_int };
                    } else if (right.toFloat()) |r_flt| {
                        break :blk Value{ .boolean = @as(f64, @floatFromInt(l_int)) <= r_flt };
                    }
                }
                break :blk Value{ .boolean = false };
            },
            11 => blk: { // GT - greater than
                if (left.toFloat()) |l_flt| {
                    if (right.toFloat()) |r_flt| {
                        break :blk Value{ .boolean = l_flt > r_flt };
                    } else if (right.toInteger()) |r_int| {
                        break :blk Value{ .boolean = l_flt > @as(f64, @floatFromInt(r_int)) };
                    }
                } else if (left.toInteger()) |l_int| {
                    if (right.toInteger()) |r_int| {
                        break :blk Value{ .boolean = l_int > r_int };
                    } else if (right.toFloat()) |r_flt| {
                        break :blk Value{ .boolean = @as(f64, @floatFromInt(l_int)) > r_flt };
                    }
                }
                break :blk Value{ .boolean = false };
            },
            12 => blk: { // GE - greater than or equal
                if (left.toFloat()) |l_flt| {
                    if (right.toFloat()) |r_flt| {
                        break :blk Value{ .boolean = l_flt >= r_flt };
                    } else if (right.toInteger()) |r_int| {
                        break :blk Value{ .boolean = l_flt >= @as(f64, @floatFromInt(r_int)) };
                    }
                } else if (left.toInteger()) |l_int| {
                    if (right.toInteger()) |r_int| {
                        break :blk Value{ .boolean = l_int >= r_int };
                    } else if (right.toFloat()) |r_flt| {
                        break :blk Value{ .boolean = @as(f64, @floatFromInt(l_int)) >= r_flt };
                    }
                }
                break :blk Value{ .boolean = false };
            },
            13 => Value{ .boolean = (left.isTruthy() catch false) and (right.isTruthy() catch false) }, // AND
            14 => Value{ .boolean = (left.isTruthy() catch false) or (right.isTruthy() catch false) }, // OR
            15 => blk: { // IN - membership test
                switch (right) {
                    .list => |l| {
                        for (l.items.items) |item| {
                            if (left.isEqual(item) catch false) {
                                break :blk Value{ .boolean = true };
                            }
                        }
                        break :blk Value{ .boolean = false };
                    },
                    .string => |s| {
                        if (left == .string) {
                            break :blk Value{ .boolean = std.mem.indexOf(u8, s, left.string) != null };
                        }
                        break :blk Value{ .boolean = false };
                    },
                    .dict => |d| {
                        // Check if key exists in dict
                        if (left == .string) {
                            break :blk Value{ .boolean = d.map.contains(left.string) };
                        }
                        break :blk Value{ .boolean = false };
                    },
                    else => break :blk Value{ .boolean = false },
                }
            },
            else => Value{ .null = {} },
        };
    }

    /// Execute unary operation
    fn executeUnaryOp(self: *Self, val: Value, op: u32) !Value {
        return switch (op) {
            0 => try val.deepCopy(self.allocator), // PLUS (no-op)
            1 => blk: {
                // MINUS - negate number
                if (val.toInteger()) |i| {
                    break :blk Value{ .integer = -i };
                } else if (val.toFloat()) |f| {
                    break :blk Value{ .float = -f };
                } else {
                    break :blk Value{ .null = {} };
                }
            },
            2 => Value{ .boolean = !(val.isTruthy() catch false) }, // NOT
            else => try val.deepCopy(self.allocator),
        };
    }

    /// Get attribute from object
    fn getAttribute(self: *Self, obj: Value, attr_name: []const u8) !Value {
        return switch (obj) {
            .dict => |d| {
                if (d.get(attr_name)) |val| {
                    return try val.deepCopy(self.allocator);
                }
                // Return undefined if not found
                const name_copy = try self.allocator.dupe(u8, attr_name);
                return Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = self.environment.undefined_behavior,
                } };
            },
            else => {
                // Non-dict types don't have user attributes
                const name_copy = try self.allocator.dupe(u8, attr_name);
                return Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = self.environment.undefined_behavior,
                } };
            },
        };
    }

    /// Get item from object
    fn getItem(self: *Self, obj: Value, key: Value) !Value {
        return switch (obj) {
            .list => |l| {
                const idx = key.toInteger() orelse return Value{ .null = {} };
                if (idx < 0 or idx >= @as(i64, @intCast(l.items.items.len))) {
                    return Value{ .null = {} };
                }
                return try l.items.items[@intCast(idx)].deepCopy(self.allocator);
            },
            .dict => |d| {
                const key_str = key.toString(self.allocator) catch return Value{ .null = {} };
                defer self.allocator.free(key_str);
                if (d.get(key_str)) |val| {
                    return try val.deepCopy(self.allocator);
                }
                return Value{ .null = {} };
            },
            .string => |s| {
                const idx = key.toInteger() orelse return Value{ .null = {} };
                if (idx < 0 or idx >= @as(i64, @intCast(s.len))) {
                    return Value{ .null = {} };
                }
                const char_str = try std.fmt.allocPrint(self.allocator, "{c}", .{s[@intCast(idx)]});
                return Value{ .string = char_str };
            },
            else => Value{ .null = {} },
        };
    }

    /// Execute bytecode asynchronously
    /// Properly handles async filters and tests when enable_async is true
    pub fn executeAsync(self: *Self) ![]const u8 {
        var pc: u32 = 0; // Program counter
        const async_utils = @import("async_utils.zig");

        while (pc < self.bytecode.instructions.items.len) {
            const instr = self.bytecode.instructions.items[@as(usize, @intCast(pc))];
            pc += 1;

            switch (instr.opcode) {
                .LOAD_STRING => {
                    const str = self.bytecode.strings.items[@as(usize, @intCast(instr.operand))];
                    const str_copy = try self.allocator.dupe(u8, str);
                    try self.stack.append(self.allocator, Value{ .string = str_copy });
                },
                .LOAD_INT => {
                    try self.stack.append(self.allocator, Value{ .integer = @as(i64, @intCast(instr.operand)) });
                },
                .LOAD_FLOAT => {
                    const float_val = @as(f32, @bitCast(instr.operand));
                    try self.stack.append(self.allocator, Value{ .float = @as(f64, @floatCast(float_val)) });
                },
                .LOAD_BOOL => {
                    try self.stack.append(self.allocator, Value{ .boolean = instr.operand != 0 });
                },
                .LOAD_NULL => {
                    try self.stack.append(self.allocator, Value{ .null = {} });
                },
                .LOAD_VAR => {
                    const name = self.bytecode.names.items[@as(usize, @intCast(instr.operand))];
                    var val = try self.loadVariable(name);

                    // Auto-await if necessary
                    if (async_utils.AsyncIterator.isAwaitable(val)) {
                        val = try async_utils.AsyncIterator.autoAwait(self.allocator, val);
                    }

                    try self.stack.append(self.allocator, val);
                },
                .STORE_VAR => {
                    const name = self.bytecode.names.items[@as(usize, @intCast(instr.operand))];
                    const val = self.stack.pop() orelse Value{ .null = {} };

                    // Check if variable already exists (re-assignment in loop)
                    if (self.variables.getEntry(name)) |entry| {
                        // Free old value, reuse key
                        entry.value_ptr.*.deinit(self.allocator);
                        entry.value_ptr.* = val;
                    } else {
                        // New variable - duplicate key
                        const name_copy = try self.allocator.dupe(u8, name);
                        try self.variables.put(name_copy, val);
                    }
                },
                .BIN_OP => {
                    const right = self.stack.pop() orelse Value{ .null = {} };
                    defer right.deinit(self.allocator);
                    const left = self.stack.pop() orelse Value{ .null = {} };
                    defer left.deinit(self.allocator);

                    const result = try self.executeBinOp(left, right, instr.operand);
                    try self.stack.append(self.allocator, result);
                },
                .UNARY_OP => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    const result = try self.executeUnaryOp(val, instr.operand);
                    try self.stack.append(self.allocator, result);
                },
                .GET_ATTR => {
                    const obj = self.stack.pop() orelse Value{ .null = {} };
                    defer obj.deinit(self.allocator);
                    const attr_name = self.bytecode.names.items[@as(usize, @intCast(instr.operand))];

                    const result = try self.getAttribute(obj, attr_name);
                    try self.stack.append(self.allocator, result);
                },
                .GET_ITEM => {
                    const key = self.stack.pop() orelse Value{ .null = {} };
                    defer key.deinit(self.allocator);
                    const obj = self.stack.pop() orelse Value{ .null = {} };
                    defer obj.deinit(self.allocator);

                    const result = try self.getItem(obj, key);
                    try self.stack.append(self.allocator, result);
                },
                .APPLY_FILTER => {
                    // Unpack operand: lower 16 bits = name_idx, upper 16 bits = arg_count
                    const name_idx = instr.operand & 0xFFFF;
                    const arg_count = instr.operand >> 16;

                    // Pop arguments from stack (in reverse order)
                    var args = try self.allocator.alloc(Value, arg_count);
                    defer {
                        for (args) |*arg| {
                            arg.deinit(self.allocator);
                        }
                        self.allocator.free(args);
                    }
                    var i: usize = arg_count;
                    while (i > 0) {
                        i -= 1;
                        args[i] = self.stack.pop() orelse Value{ .null = {} };
                    }

                    // Pop value to filter
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    const filter_name = self.bytecode.names.items[@as(usize, @intCast(name_idx))];
                    const filter = self.environment.getFilter(filter_name) orelse {
                        return exceptions.TemplateError.RuntimeError;
                    };

                    // Check if async filter should be used
                    const use_async = self.environment.enable_async and filter.is_async;

                    // Apply filter with arguments
                    var result = if (use_async) blk: {
                        // Use async filter function if available
                        if (filter.async_func) |async_func| {
                            break :blk try async_func(self.allocator, val, args, self.context, self.environment);
                        } else {
                            // Fall back to sync function
                            break :blk try filter.func(self.allocator, val, args, self.context, self.environment);
                        }
                    } else try filter.func(self.allocator, val, args, self.context, self.environment);

                    // Auto-await the result if it's an async result
                    if (async_utils.AsyncIterator.isAwaitable(result)) {
                        result = try async_utils.AsyncIterator.autoAwait(self.allocator, result);
                    }

                    try self.stack.append(self.allocator, result);
                },
                .APPLY_TEST => {
                    // Unpack operand: lower 16 bits = name_idx, upper 16 bits = arg_count
                    const name_idx = instr.operand & 0xFFFF;
                    const arg_count = instr.operand >> 16;

                    // Pop arguments from stack (in reverse order)
                    var args = try self.allocator.alloc(Value, arg_count);
                    defer {
                        for (args) |*arg| {
                            arg.deinit(self.allocator);
                        }
                        self.allocator.free(args);
                    }
                    var i: usize = arg_count;
                    while (i > 0) {
                        i -= 1;
                        args[i] = self.stack.pop() orelse Value{ .null = {} };
                    }

                    // Pop value to test
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    const test_name = self.bytecode.names.items[@as(usize, @intCast(name_idx))];
                    const test_func = self.environment.getTest(test_name) orelse {
                        return exceptions.TemplateError.RuntimeError;
                    };

                    // Check if async test should be used
                    const use_async = self.environment.enable_async and test_func.is_async;

                    // Determine which arguments to pass based on pass_arg setting
                    const env_to_pass = switch (test_func.pass_arg) {
                        .environment => self.environment,
                        else => null,
                    };
                    const ctx_to_pass = switch (test_func.pass_arg) {
                        .context => self.context,
                        else => self.context, // Always pass context for now
                    };

                    // Apply test with arguments
                    const result = if (use_async) blk: {
                        // Use async test function if available
                        if (test_func.async_func) |async_func| {
                            break :blk async_func(val, args, ctx_to_pass, env_to_pass);
                        } else {
                            // Fall back to sync function
                            break :blk test_func.func(val, args, ctx_to_pass, env_to_pass);
                        }
                    } else test_func.func(val, args, ctx_to_pass, env_to_pass);

                    try self.stack.append(self.allocator, Value{ .boolean = result });
                },
                .BUILD_LIST => {
                    const count = instr.operand;
                    const list_ptr = try self.allocator.create(value_mod.List);
                    list_ptr.* = value_mod.List.init(self.allocator);
                    errdefer {
                        list_ptr.deinit(self.allocator);
                        self.allocator.destroy(list_ptr);
                    }

                    // Collect elements from stack (in reverse order)
                    var temp = std.ArrayList(Value){};
                    defer temp.deinit(self.allocator);
                    var i: u32 = 0;
                    while (i < count) : (i += 1) {
                        const elem = self.stack.pop() orelse Value{ .null = {} };
                        try temp.append(self.allocator, elem);
                    }

                    // Append in reverse to restore original order
                    var j: usize = temp.items.len;
                    while (j > 0) {
                        j -= 1;
                        try list_ptr.append(temp.items[j]);
                    }

                    try self.stack.append(self.allocator, Value{ .list = list_ptr });
                },
                .CALL_FUNC => {
                    // For now, function calls are not fully implemented
                    // Would need to pop args and function, then call
                    _ = instr.operand;
                    return exceptions.TemplateError.RuntimeError;
                },
                .JUMP_IF_FALSE => {
                    var val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    // Auto-await if necessary before truthiness check
                    if (async_utils.AsyncIterator.isAwaitable(val)) {
                        val = try async_utils.AsyncIterator.autoAwait(self.allocator, val);
                    }

                    if (!(try val.isTruthy())) {
                        pc = instr.operand;
                    }
                },
                .JUMP_IF_TRUE => {
                    var val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    // Auto-await if necessary before truthiness check
                    if (async_utils.AsyncIterator.isAwaitable(val)) {
                        val = try async_utils.AsyncIterator.autoAwait(self.allocator, val);
                    }

                    if (try val.isTruthy()) {
                        pc = instr.operand;
                    }
                },
                .JUMP => {
                    pc = instr.operand;
                },
                .OUTPUT => {
                    var val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    // Auto-await if necessary before output
                    if (async_utils.AsyncIterator.isAwaitable(val)) {
                        val = try async_utils.AsyncIterator.autoAwait(self.allocator, val);
                    }

                    const str = try val.toString(self.allocator);
                    defer self.allocator.free(str);
                    try self.result.appendSlice(self.allocator, str);
                },
                .OUTPUT_TEXT => {
                    const text = self.bytecode.strings.items[@as(usize, @intCast(instr.operand))];
                    try self.result.appendSlice(self.allocator, text);
                },
                .FOR_LOOP_START => {
                    // For loops need special handling - would need to iterate
                    // For now, skip implementation
                    return exceptions.TemplateError.RuntimeError;
                },
                .FOR_LOOP_END => {
                    // Jump back to loop start
                    pc = instr.operand;
                },
                .RETURN => {
                    break;
                },
                .END => {
                    break;
                },
                else => {
                    return exceptions.TemplateError.RuntimeError;
                },
            }
        }

        return try self.result.toOwnedSlice(self.allocator);
    }
};

const exceptions = @import("exceptions.zig");
const value_mod = @import("value.zig");
const context = @import("context.zig");
const environment = @import("environment.zig");

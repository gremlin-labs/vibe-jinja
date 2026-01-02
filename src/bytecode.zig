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
const value_mod = @import("value.zig");
const exceptions = @import("exceptions.zig");
const context = @import("context.zig");
const environment = @import("environment.zig");

/// Normalize a slice index for Python-style slicing semantics
fn normalizeSliceIndex(index: ?i64, length: i64, step: i64, is_start: bool) i64 {
    if (index) |idx| {
        if (idx < 0) {
            return @max(0, length + idx);
        }
        return @min(length, idx);
    } else {
        // Default start/stop depends on step direction
        if (is_start) {
            return if (step > 0) 0 else length - 1;
        } else {
            return if (step > 0) length else -1;
        }
    }
}

/// Compute hash for a Value (for loop.changed())
fn computeValueHashBytecode(val: value_mod.Value) u64 {
    return switch (val) {
        .integer => |i| @as(u64, @bitCast(i)),
        .float => |f| @as(u64, @bitCast(f)),
        .boolean => |b| if (b) @as(u64, 1) else 0,
        .string => |s| std.hash.Wyhash.hash(0, s),
        .null => 0,
        .undefined => 0,
        .list => |l| blk: {
            var h: u64 = 0;
            for (l.items.items) |item| {
                h = h *% 31 +% computeValueHashBytecode(item);
            }
            break :blk h;
        },
        .dict => |d| blk: {
            var h: u64 = 0;
            var iter = d.map.iterator();
            while (iter.next()) |entry| {
                h = h *% 31 +% std.hash.Wyhash.hash(0, entry.key_ptr.*);
                h = h *% 31 +% computeValueHashBytecode(entry.value_ptr.*);
            }
            break :blk h;
        },
        .callable => 0,
        .markup => |m| std.hash.Wyhash.hash(0, m.content),
        .async_result => 0,
        .custom => 0,
    };
}

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
    GET_SLICE, // Get slice (operand encodes which of start/stop/step are present)
    CALL_FUNC, // Call function (operand = arg count)
    CALL_GLOBAL, // Call global function (operand = lower 16 bits name_idx, upper 16 bits arg_count)
    LOOP_CYCLE, // loop.cycle(args) (operand = arg count)
    LOOP_CHANGED, // loop.changed(args) (operand = arg count)
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

    // Macro operations
    DEFINE_MACRO, // Define macro (operand = macro info index)
    CALL_MACRO, // Call macro (operand = lower 16 bits name_idx, upper 16 bits arg_count)
    CALL_MACRO_WITH_CALLER, // Call macro with caller block (similar encoding)
    PUSH_MACRO_FRAME, // Push new frame for macro execution
    POP_MACRO_FRAME, // Pop frame after macro execution
    SET_LOCAL, // Set local variable in current frame (operand = name index)
    GET_LOCAL_VAR, // Get local variable from current frame (operand = name index)
    INVOKE_CALLER, // Invoke caller() inside macro, pushes result

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

/// Macro parameter info for bytecode
pub const MacroParam = struct {
    name: []const u8,
    has_default: bool,
    default_expr_idx: ?u32, // Index into constants pool if has_default
};

/// Macro definition info for bytecode
pub const MacroInfo = struct {
    name: []const u8,
    params: std.ArrayList(MacroParam),
    body_start: u32, // Instruction index where macro body starts
    body_end: u32, // Instruction index where macro body ends
    catch_varargs: bool,
    catch_kwargs: bool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
        return Self{
            .name = name,
            .params = std.ArrayList(MacroParam).empty,
            .body_start = 0,
            .body_end = 0,
            .catch_varargs = false,
            .catch_kwargs = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free macro name
        self.allocator.free(self.name);
        // Free param names
        for (self.params.items) |param| {
            self.allocator.free(param.name);
        }
        self.params.deinit(self.allocator);
    }
};

/// Bytecode representation of a template
pub const Bytecode = struct {
    instructions: std.ArrayList(Instruction),
    constants: std.ArrayList(*nodes.Expression), // Constant pool for expressions
    strings: std.ArrayList([]const u8), // String constant pool
    names: std.ArrayList([]const u8), // Variable/name constant pool
    macros: std.ArrayList(MacroInfo), // Macro definitions
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new bytecode
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .instructions = std.ArrayList(Instruction).empty,
            .constants = std.ArrayList(*nodes.Expression).empty,
            .strings = std.ArrayList([]const u8).empty,
            .names = std.ArrayList([]const u8).empty,
            .macros = std.ArrayList(MacroInfo).empty,
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
        // Free macro infos
        for (self.macros.items) |*macro_info| {
            macro_info.deinit();
        }
        self.macros.deinit(self.allocator);
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

    /// Add a macro definition
    pub fn addMacro(self: *Self, macro_info: MacroInfo) !u32 {
        const index = @as(u32, @intCast(self.macros.items.len));
        try self.macros.append(self.allocator, macro_info);
        return index;
    }

    /// Get macro by name
    pub fn getMacro(self: *const Self, name: []const u8) ?*const MacroInfo {
        for (self.macros.items) |*macro_info| {
            if (std.mem.eql(u8, macro_info.name, name)) {
                return macro_info;
            }
        }
        return null;
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

    /// Generate bytecode for macro definition
    fn generateMacro(self: *Self, macro: *nodes.Macro) !void {
        // Create macro info
        const name_copy = try self.allocator.dupe(u8, macro.name);
        var macro_info = MacroInfo.init(self.allocator, name_copy);

        // Add macro parameters
        for (macro.args.items) |arg| {
            var param = MacroParam{
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

            try macro_info.params.append(self.allocator, param);
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
                        else if (std.mem.eql(u8, attr.attr, "depth"))
                            6 // depth (1-based nesting level)
                        else if (std.mem.eql(u8, attr.attr, "depth0"))
                            7 // depth0 (0-based nesting level)
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
                
                // Check if this is a slice expression
                if (item.arg == .slice) {
                    const slice = item.arg.slice;
                    // Encode which parts are present in the operand
                    // bit 0 = has start, bit 1 = has stop, bit 2 = has step
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
                } else {
                    // Generate key/index expression
                    try self.generateExpression(item.arg);
                    // Get item
                    try self.bytecode.addInstruction(.GET_ITEM, 0);
                }
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

                    // Generate kwargs (push to stack as pairs: key_idx, value)
                    var kwargs_count: u32 = 0;
                    var kw_iter = filter.kwargs.iterator();
                    while (kw_iter.next()) |entry| {
                        // Push key index as integer
                        const key_idx = try self.bytecode.addName(entry.key_ptr.*);
                        try self.bytecode.addInstruction(.LOAD_INT, key_idx);
                        // Push value expression
                        try self.generateExpression(entry.value_ptr.*);
                        kwargs_count += 1;
                    }

                    // Generic filter - operand encodes name_idx, arg_count, and kwargs_count
                    // Encoding: bits [0-7] = arg_count, bits [8-15] = kwargs_count, bits [16-31] = name_idx
                    const name_idx = try self.bytecode.addName(filter.name);
                    const arg_count: u32 = @intCast(filter.args.items.len);
                    const operand = (name_idx << 16) | ((kwargs_count & 0xFF) << 8) | (arg_count & 0xFF);
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
                // Check if this is a call to a global function (name expression)
                if (call.func == .name) {
                    const func_name = call.func.name.name;

                    // Special handling for caller() - this invokes the caller body in {% call %} blocks
                    if (std.mem.eql(u8, func_name, "caller")) {
                        try self.bytecode.addInstruction(.INVOKE_CALLER, 0);
                        return; // caller() doesn't take arguments
                    }

                    // Generate arguments first
                    for (call.args.items) |arg| {
                        try self.generateExpression(arg);
                    }

                    // Check if there are kwargs - if so, we need to use CALL_MACRO encoding
                    if (call.kwargs.count() > 0) {
                        // Push kwargs onto stack (as key_idx, value pairs)
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
                        // Use CALL_MACRO encoding: bits [0-7] = arg_count, bits [8-15] = kwargs_count, bits [16-31] = name_idx
                        const name_idx = try self.bytecode.addName(func_name);
                        const arg_count: u32 = @intCast(call.args.items.len);
                        const operand = (name_idx << 16) | (kwargs_count << 8) | (arg_count & 0xFF);
                        try self.bytecode.addInstruction(.CALL_MACRO, operand);
                    } else {
                        // No kwargs - use simple CALL_GLOBAL
                        const name_idx = try self.bytecode.addName(func_name);
                        const arg_count: u32 = @intCast(call.args.items.len);
                        const operand = (arg_count << 16) | (name_idx & 0xFFFF);
                        try self.bytecode.addInstruction(.CALL_GLOBAL, operand);
                    }
                } else if (call.func == .getattr) {
                    // Check for loop.cycle() and loop.changed()
                    const attr = call.func.getattr;
                    if (attr.node == .name and std.mem.eql(u8, attr.node.name.name, "loop")) {
                        if (std.mem.eql(u8, attr.attr, "cycle")) {
                            // loop.cycle(args) - generate args then LOOP_CYCLE
                            for (call.args.items) |arg| {
                                try self.generateExpression(arg);
                            }
                            try self.bytecode.addInstruction(.LOOP_CYCLE, @as(u32, @intCast(call.args.items.len)));
                        } else if (std.mem.eql(u8, attr.attr, "changed")) {
                            // loop.changed(args) - generate args then LOOP_CHANGED
                            for (call.args.items) |arg| {
                                try self.generateExpression(arg);
                            }
                            try self.bytecode.addInstruction(.LOOP_CHANGED, @as(u32, @intCast(call.args.items.len)));
                        } else {
                            // Other loop method - fallback to generic call
                            try self.generateExpression(call.func);
                            for (call.args.items) |arg| {
                                try self.generateExpression(arg);
                            }
                            try self.bytecode.addInstruction(.CALL_FUNC, @as(u32, @intCast(call.args.items.len)));
                        }
                    } else {
                        // Method call syntax for filters: value.filter_name(args)
                        // In Jinja2, this is equivalent to value | filter_name(args)
                        // First generate the base value (the object the method is called on)
                        try self.generateExpression(attr.node);

                        // Generate arguments for the filter
                        for (call.args.items) |arg| {
                            try self.generateExpression(arg);
                        }

                        // Apply as filter - attr.attr is the filter name
                        const name_idx = try self.bytecode.addName(attr.attr);
                        const arg_count: u32 = @intCast(call.args.items.len);
                        // Encode: lower 8 bits = arg_count, bits [8-15] = kwargs_count (0), bits [16-31] = name_idx
                        const operand = (name_idx << 16) | (arg_count & 0xFF);
                        try self.bytecode.addInstruction(.APPLY_FILTER, operand);
                    }
                } else {
                    // Generic function call
                    try self.generateExpression(call.func);
                    for (call.args.items) |arg| {
                        try self.generateExpression(arg);
                    }
                    try self.bytecode.addInstruction(.CALL_FUNC, @as(u32, @intCast(call.args.items.len)));
                }
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

/// Caller info for macro call blocks
pub const CallerInfo = struct {
    start_pc: u32, // PC where caller body starts
    end_pc: u32, // PC where caller body ends
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
    /// Current loop index (0-based) for loop.cycle()
    loop_index0: i64 = 0,
    /// Last hash for loop.changed()
    last_changed_hash: ?u64 = null,
    /// Runtime macro references (name -> macro index)
    runtime_macros: std.StringHashMap(u32),
    /// Current caller info for {% call %} blocks
    current_caller: ?CallerInfo = null,
    /// Macro frame stack for nested macro calls
    macro_frames: std.ArrayList(MacroFrame),

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

    /// Frame for macro execution
    const MacroFrame = struct {
        variables: std.StringHashMap(Value),
        return_pc: u32, // PC to return to after macro
        caller: ?CallerInfo, // Caller info if called with {% call %}
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
            .runtime_macros = std.StringHashMap(u32).init(allocator),
            .macro_frames = std.ArrayList(MacroFrame).empty,
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

        // Clean up runtime macros
        var macro_iter = self.runtime_macros.iterator();
        while (macro_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.runtime_macros.deinit();

        // Clean up macro frames
        for (self.macro_frames.items) |*frame| {
            var frame_iter = frame.variables.iterator();
            while (frame_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(self.allocator);
            }
            frame.variables.deinit();
        }
        self.macro_frames.deinit(self.allocator);

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
                    // Unpack operand: bits [0-7] = arg_count, bits [8-15] = kwargs_count, bits [16-31] = name_idx
                    const arg_count = instr.operand & 0xFF;
                    const kwargs_count = (instr.operand >> 8) & 0xFF;
                    const name_idx = (instr.operand >> 16) & 0xFFFF;

                    // Pop kwargs from stack (in reverse order, as pairs: value, key_idx)
                    var kwargs = std.StringHashMap(Value).init(self.allocator);
                    defer {
                        var kw_iter = kwargs.iterator();
                        while (kw_iter.next()) |entry| {
                            entry.value_ptr.deinit(self.allocator);
                        }
                        kwargs.deinit();
                    }
                    var kw_i: u32 = 0;
                    while (kw_i < kwargs_count) : (kw_i += 1) {
                        const kwarg_val = self.stack.pop() orelse Value{ .null = {} };
                        const key_idx_val = self.stack.pop() orelse Value{ .null = {} };
                        defer key_idx_val.deinit(self.allocator);

                        if (key_idx_val.toInteger()) |key_idx| {
                            const key_name = self.bytecode.names.items[@as(usize, @intCast(key_idx))];
                            try kwargs.put(key_name, kwarg_val);
                        } else {
                            kwarg_val.deinit(self.allocator);
                        }
                    }

                    // Pop positional arguments from stack (in reverse order)
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

                    // Apply filter with arguments and kwargs
                    const result = try filter.func(self.allocator, val, args, &kwargs, self.context, self.environment);
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
                    // Generic function call - pop function and args
                    const arg_count = instr.operand;
                    
                    // Pop arguments from stack (in reverse order)
                    var args = try self.allocator.alloc(Value, arg_count);
                    defer {
                        for (args) |*arg| {
                            arg.deinit(self.allocator);
                        }
                        self.allocator.free(args);
                    }
                    var call_i: usize = arg_count;
                    while (call_i > 0) {
                        call_i -= 1;
                        args[call_i] = self.stack.pop() orelse Value{ .null = {} };
                    }
                    
                    // Pop function value
                    const func_val = self.stack.pop() orelse Value{ .null = {} };
                    defer func_val.deinit(self.allocator);
                    
                    // Call callable if it has a function pointer
                    if (func_val == .callable) {
                        if (func_val.callable.func) |func| {
                            const result = func(self.allocator, args, self.context, self.environment) catch {
                                return exceptions.TemplateError.RuntimeError;
                            };
                            try self.stack.append(self.allocator, result);
                        } else {
                            try self.stack.append(self.allocator, Value{ .null = {} });
                        }
                    } else {
                        try self.stack.append(self.allocator, Value{ .null = {} });
                    }
                },
                .CALL_GLOBAL => {
                    // Call a global function by name
                    const name_idx = instr.operand & 0xFFFF;
                    const arg_count = instr.operand >> 16;
                    
                    const func_name = self.bytecode.names.items[@as(usize, @intCast(name_idx))];
                    
                    // First check if it's a macro (takes priority)
                    if (self.runtime_macros.get(func_name)) |_| {
                        // It's a macro - execute it
                        const result = try self.executeMacro(func_name, arg_count, 0, null);
                        try self.stack.append(self.allocator, result);
                    } else if (self.context.getMacro(func_name)) |_| {
                        // AST-defined macro
                        const result = try self.executeMacro(func_name, arg_count, 0, null);
                        try self.stack.append(self.allocator, result);
                    } else {
                        // Pop arguments from stack (in reverse order)
                        var args = try self.allocator.alloc(Value, arg_count);
                        defer {
                            for (args) |*arg| {
                                arg.deinit(self.allocator);
                            }
                            self.allocator.free(args);
                        }
                        var global_i: usize = arg_count;
                        while (global_i > 0) {
                            global_i -= 1;
                            args[global_i] = self.stack.pop() orelse Value{ .null = {} };
                        }
                        
                        if (self.environment.getGlobal(func_name)) |global_val| {
                            if (global_val == .callable) {
                                if (global_val.callable.func) |func| {
                                    const result = func(self.allocator, args, self.context, self.environment) catch {
                                        return exceptions.TemplateError.RuntimeError;
                                    };
                                    try self.stack.append(self.allocator, result);
                                } else {
                                    try self.stack.append(self.allocator, Value{ .null = {} });
                                }
                            } else {
                                // Non-callable global - return as-is
                                const result = try global_val.deepCopy(self.allocator);
                                try self.stack.append(self.allocator, result);
                            }
                        } else {
                            // Check if it's a filter that can be called as function
                            if (self.environment.getFilter(func_name)) |filter| {
                                // First arg is the value, rest are args
                                if (args.len > 0) {
                                    const filter_args = args[1..];
                                    // Empty kwargs for bytecode execution
                                    var empty_kwargs = std.StringHashMap(Value).init(self.allocator);
                                    defer empty_kwargs.deinit();
                                    const result = try filter.func(self.allocator, args[0], filter_args, &empty_kwargs, self.context, self.environment);
                                    try self.stack.append(self.allocator, result);
                                } else {
                                    try self.stack.append(self.allocator, Value{ .null = {} });
                                }
                            } else {
                                return exceptions.TemplateError.RuntimeError;
                            }
                        }
                    }
                },
                .GET_SLICE => {
                    // Slice operation: obj[start:stop:step]
                    // Operand encodes which parts are present: bit 0=start, bit 1=stop, bit 2=step
                    const flags = instr.operand;
                    
                    // Pop slice components in reverse order of how they were pushed
                    var step_val: ?i64 = null;
                    var stop_val: ?i64 = null;
                    var start_val: ?i64 = null;
                    
                    if (flags & 4 != 0) {
                        const step = self.stack.pop() orelse Value{ .null = {} };
                        defer step.deinit(self.allocator);
                        step_val = step.toInteger();
                    }
                    if (flags & 2 != 0) {
                        const stop = self.stack.pop() orelse Value{ .null = {} };
                        defer stop.deinit(self.allocator);
                        stop_val = stop.toInteger();
                    }
                    if (flags & 1 != 0) {
                        const start = self.stack.pop() orelse Value{ .null = {} };
                        defer start.deinit(self.allocator);
                        start_val = start.toInteger();
                    }
                    
                    const obj = self.stack.pop() orelse Value{ .null = {} };
                    defer obj.deinit(self.allocator);
                    
                    const step: i64 = step_val orelse 1;
                    if (step == 0) {
                        return exceptions.TemplateError.RuntimeError;
                    }
                    
                    const result = try self.executeSlice(obj, start_val, stop_val, step);
                    try self.stack.append(self.allocator, result);
                },
                .LOOP_CYCLE => {
                    // loop.cycle(args) - return arg at index % arg_count
                    const arg_count = instr.operand;
                    if (arg_count == 0) {
                        return exceptions.TemplateError.TypeError;
                    }
                    
                    // Pop arguments from stack (in reverse order)
                    var args = try self.allocator.alloc(Value, arg_count);
                    defer self.allocator.free(args);
                    var cycle_i: usize = arg_count;
                    while (cycle_i > 0) {
                        cycle_i -= 1;
                        args[cycle_i] = self.stack.pop() orelse Value{ .null = {} };
                    }
                    defer {
                        for (args) |*arg| {
                            arg.deinit(self.allocator);
                        }
                    }
                    
                    // Get current loop index
                    const idx: usize = @intCast(@mod(self.loop_index0, @as(i64, @intCast(arg_count))));
                    const result = try args[idx].deepCopy(self.allocator);
                    try self.stack.append(self.allocator, result);
                },
                .LOOP_CHANGED => {
                    // loop.changed(args) - return true if args hash differs from last call
                    const arg_count = instr.operand;
                    
                    // Pop arguments and compute hash
                    var hash: u64 = 0;
                    var changed_j: u32 = 0;
                    while (changed_j < arg_count) : (changed_j += 1) {
                        const arg = self.stack.pop() orelse Value{ .null = {} };
                        defer arg.deinit(self.allocator);
                        hash = hash *% 31 +% computeValueHashBytecode(arg);
                    }
                    
                    const changed = if (self.last_changed_hash) |last_hash|
                        hash != last_hash
                    else
                        true;
                    
                    self.last_changed_hash = hash;
                    try self.stack.append(self.allocator, Value{ .boolean = changed });
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

                        // Update loop_index0 for loop.cycle() and loop.changed()
                        self.loop_index0 = 0;
                        self.last_changed_hash = null;

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
                        // Update loop_index0 for loop.cycle() and loop.changed()
                        self.loop_index0 = @intCast(loop_state.index);
                        pc = instr.operand + 1; // Jump to instruction after FOR_LOOP_START
                    } else {
                        // Loop complete - free iterable and pop loop state
                        var completed_state = self.loop_stack.pop().?;
                        completed_state.iterable.deinit(self.allocator);
                        // Reset loop_index0 when exiting loop
                        if (self.loop_stack.items.len > 0) {
                            const outer_loop = &self.loop_stack.items[self.loop_stack.items.len - 1];
                            self.loop_index0 = @intCast(outer_loop.index);
                        } else {
                            self.loop_index0 = 0;
                        }
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
                    // 6 = depth (1-based nesting level)
                    // 7 = depth0 (0-based nesting level)
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
                        6 => Value{ .integer = @intCast(self.loop_stack.items.len) }, // depth (1-based)
                        7 => Value{ .integer = @intCast(self.loop_stack.items.len - 1) }, // depth0 (0-based)
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
                .DEFINE_MACRO => {
                    // Register macro in runtime context
                    // Operand: lower 16 bits = name_idx, upper 16 bits = macro_idx
                    const name_idx = instr.operand & 0xFFFF;
                    const macro_idx = instr.operand >> 16;
                    const name = self.bytecode.names.items[@as(usize, @intCast(name_idx))];

                    // Store macro reference in runtime macros map
                    // We store the macro index which can be looked up in bytecode.macros
                    const name_copy = try self.allocator.dupe(u8, name);
                    try self.runtime_macros.put(name_copy, macro_idx);
                },
                .CALL_MACRO => {
                    // Call a macro
                    // Operand: bits [0-7] = arg_count, bits [8-15] = kwargs_count, bits [16-31] = name_idx
                    const arg_count = instr.operand & 0xFF;
                    const kwargs_count = (instr.operand >> 8) & 0xFF;
                    const name_idx = instr.operand >> 16;
                    const macro_name = self.bytecode.names.items[@as(usize, @intCast(name_idx))];

                    // Execute macro and push result
                    const result = try self.executeMacro(macro_name, arg_count, kwargs_count, null);
                    try self.stack.append(self.allocator, result);
                },
                .CALL_MACRO_WITH_CALLER => {
                    // Call macro with caller block
                    // Operand: lower 16 bits = name_idx, upper 16 bits = arg_count
                    const name_idx = instr.operand & 0xFFFF;
                    const arg_count = instr.operand >> 16;
                    const macro_name = self.bytecode.names.items[@as(usize, @intCast(name_idx))];

                    // Pop caller body range from stack
                    const caller_end = self.stack.pop() orelse Value{ .null = {} };
                    defer caller_end.deinit(self.allocator);
                    const caller_start = self.stack.pop() orelse Value{ .null = {} };
                    defer caller_start.deinit(self.allocator);

                    // Create caller info
                    const caller_info = CallerInfo{
                        .start_pc = @intCast(caller_start.toInteger() orelse 0),
                        .end_pc = @intCast(caller_end.toInteger() orelse 0),
                    };

                    // Execute macro with caller
                    const result = try self.executeMacro(macro_name, arg_count, 0, caller_info);
                    try self.stack.append(self.allocator, result);
                },
                .INVOKE_CALLER => {
                    // Invoke caller() inside a macro - execute the caller body
                    if (self.current_caller) |caller_info| {
                        // Save current PC and execute caller body
                        const saved_pc = pc;
                        pc = caller_info.start_pc;

                        // Execute caller body until RETURN or caller_end
                        var caller_result = std.ArrayList(u8){};
                        defer caller_result.deinit(self.allocator);

                        while (pc < caller_info.end_pc and pc < self.bytecode.instructions.items.len) {
                            const caller_instr = self.bytecode.instructions.items[@as(usize, @intCast(pc))];
                            pc += 1;

                            if (caller_instr.opcode == .RETURN) {
                                break;
                            }

                            // Execute instruction (simplified - handle OUTPUT_TEXT and OUTPUT)
                            switch (caller_instr.opcode) {
                                .OUTPUT_TEXT => {
                                    const str = self.bytecode.strings.items[@as(usize, @intCast(caller_instr.operand))];
                                    try caller_result.appendSlice(self.allocator, str);
                                },
                                .OUTPUT => {
                                    const val = self.stack.pop() orelse Value{ .null = {} };
                                    defer val.deinit(self.allocator);
                                    const str = try val.toString(self.allocator);
                                    defer self.allocator.free(str);
                                    try caller_result.appendSlice(self.allocator, str);
                                },
                                else => {
                                    // For simplicity, skip other instructions in caller
                                    // A full implementation would recursively execute
                                },
                            }
                        }

                        // Restore PC
                        pc = saved_pc;

                        // Push result as string
                        const result_str = try caller_result.toOwnedSlice(self.allocator);
                        try self.stack.append(self.allocator, Value{ .string = result_str });
                    } else {
                        // No caller - return empty string
                        try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                    }
                },
                .PUSH_MACRO_FRAME, .POP_MACRO_FRAME, .SET_LOCAL, .GET_LOCAL_VAR => {
                    // These are handled internally by executeMacro
                    // If we reach them in main execution, they're no-ops
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
        // Check macro frame variables first (if in a macro)
        if (self.macro_frames.items.len > 0) {
            const frame = &self.macro_frames.items[self.macro_frames.items.len - 1];
            if (frame.variables.get(name)) |val| {
                return try val.deepCopy(self.allocator);
            }
        }

        // Check local variables
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

    /// Execute a macro and return its output as a Value
    fn executeMacro(self: *Self, macro_name: []const u8, arg_count: u32, kwargs_count: u32, caller: ?CallerInfo) !Value {
        // Look up macro - first in runtime_macros, then in bytecode.macros
        const macro_idx = self.runtime_macros.get(macro_name) orelse {
            // Try AST-based macro lookup via context
            if (self.context.getMacro(macro_name)) |ast_macro| {
                // Fall back to AST execution for macros defined via AST
                return try self.executeAstMacro(ast_macro, arg_count, kwargs_count, caller);
            }
            return Value{ .string = try self.allocator.dupe(u8, "") };
        };

        const macro_info = &self.bytecode.macros.items[@intCast(macro_idx)];

        // Create new macro frame
        var frame = MacroFrame{
            .variables = std.StringHashMap(Value).init(self.allocator),
            .return_pc = 0, // Not used for inline execution
            .caller = caller,
        };

        // Build kwargs map for lookup - kwargs override positional args
        var kwargs_map = std.StringHashMap(Value).init(self.allocator);
        defer {
            // Clean up any unused kwargs (those not matching a parameter)
            var iter = kwargs_map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(self.allocator);
            }
            kwargs_map.deinit();
        }

        // Pop kwargs from stack (in pairs: key_idx, value) - store in kwargs_map
        var kwargs_i: u32 = 0;
        while (kwargs_i < kwargs_count) : (kwargs_i += 1) {
            const val = self.stack.pop() orelse Value{ .null = {} };
            const key_idx_val = self.stack.pop() orelse Value{ .null = {} };
            defer key_idx_val.deinit(self.allocator);

            if (key_idx_val.toInteger()) |key_idx| {
                const key_name = self.bytecode.names.items[@as(usize, @intCast(key_idx))];
                const key_copy = try self.allocator.dupe(u8, key_name);
                try kwargs_map.put(key_copy, val);
            } else {
                val.deinit(self.allocator);
            }
        }

        // Pop positional args from stack
        var args = try self.allocator.alloc(Value, arg_count);
        defer self.allocator.free(args);
        var arg_i: usize = arg_count;
        while (arg_i > 0) {
            arg_i -= 1;
            args[arg_i] = self.stack.pop() orelse Value{ .null = {} };
        }

        // Track which positional args we use (so we can free unused ones)
        var used_positional = try self.allocator.alloc(bool, arg_count);
        defer self.allocator.free(used_positional);
        @memset(used_positional, false);

        // Assign args to parameters - kwargs take priority over positional
        for (macro_info.params.items, 0..) |param, i| {
            var param_value: Value = undefined;
            var found = false;

            // 1. Check keyword argument first (overrides positional)
            if (kwargs_map.fetchRemove(param.name)) |kv| {
                param_value = kv.value;
                self.allocator.free(kv.key); // Free the key since we're using it
                found = true;
            }
            // 2. Then check positional argument
            else if (i < args.len) {
                param_value = args[i];
                used_positional[i] = true;
                found = true;
            }
            // 3. Finally check default value
            else if (param.has_default and param.default_expr_idx != null) {
                // Use default value - decode the packed value
                const encoded = param.default_expr_idx.?;
                const type_bits = encoded >> 30;
                const value_bits = encoded & 0x3FFFFFFF;

                param_value = switch (type_bits) {
                    0b10 => blk: { // String (high bit set)
                        const str_idx = encoded & 0x7FFFFFFF;
                        const str = self.bytecode.strings.items[@intCast(str_idx)];
                        break :blk Value{ .string = try self.allocator.dupe(u8, str) };
                    },
                    0b01 => Value{ .integer = @intCast(value_bits) }, // Integer
                    0b11 => Value{ .boolean = value_bits != 0 }, // Boolean
                    else => Value{ .null = {} }, // Null or unknown
                };
                found = true;
            }

            if (!found) {
                // Required parameter missing - use null
                param_value = Value{ .null = {} };
            }

            const name_copy = try self.allocator.dupe(u8, param.name);
            try frame.variables.put(name_copy, param_value);
        }

        // Build varargs list from unused positional args (beyond parameters)
        // In Jinja2, varargs captures extra positional arguments
        const varargs_list = try self.allocator.create(value_mod.List);
        varargs_list.* = value_mod.List.init(self.allocator);
        for (args, 0..) |arg, i| {
            if (i >= macro_info.params.items.len) {
                // Extra positional arg - add to varargs
                try varargs_list.append(arg);
            } else if (!used_positional[i]) {
                // Unused positional arg (replaced by kwarg) - free it
                var arg_copy = arg;
                arg_copy.deinit(self.allocator);
            }
        }
        const varargs_key = try self.allocator.dupe(u8, "varargs");
        try frame.variables.put(varargs_key, Value{ .list = varargs_list });

        // Build kwargs dict from remaining kwargs (not matched to parameters)
        // In Jinja2, kwargs captures extra keyword arguments
        const kwargs_dict = try self.allocator.create(value_mod.Dict);
        kwargs_dict.* = value_mod.Dict.init(self.allocator);

        // First, collect remaining kwargs and move to dict
        // Dict.set duplicates keys, so we move values but need to free original keys
        var keys_to_free = std.ArrayList([]const u8){};
        defer keys_to_free.deinit(self.allocator);

        var remaining_iter = kwargs_map.iterator();
        while (remaining_iter.next()) |entry| {
            // Dict.set duplicates the key internally, value is moved
            try kwargs_dict.set(entry.key_ptr.*, entry.value_ptr.*);
            try keys_to_free.append(self.allocator, entry.key_ptr.*);
        }

        // Now clear the map and free original keys
        kwargs_map.clearRetainingCapacity();
        for (keys_to_free.items) |key| {
            self.allocator.free(key);
        }

        const kwargs_key = try self.allocator.dupe(u8, "kwargs");
        try frame.variables.put(kwargs_key, Value{ .dict = kwargs_dict });

        // Save current caller and push frame
        const saved_caller = self.current_caller;
        self.current_caller = caller;
        try self.macro_frames.append(self.allocator, frame);

        // Execute macro body using the main execution logic
        // We save and restore the result buffer to capture macro output
        const saved_result = self.result;
        self.result = std.ArrayList(u8){};

        var macro_pc = macro_info.body_start;
        while (macro_pc < macro_info.body_end and macro_pc < self.bytecode.instructions.items.len) {
            const instr = self.bytecode.instructions.items[@as(usize, @intCast(macro_pc))];
            macro_pc += 1;

            if (instr.opcode == .RETURN) {
                break;
            }

            // Execute instruction - handle all necessary opcodes for macros
            switch (instr.opcode) {
                .OUTPUT_TEXT => {
                    const str = self.bytecode.strings.items[@as(usize, @intCast(instr.operand))];
                    try self.result.appendSlice(self.allocator, str);
                },
                .OUTPUT => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);
                    const str = try val.toString(self.allocator);
                    defer self.allocator.free(str);
                    try self.result.appendSlice(self.allocator, str);
                },
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
                    // Store in macro frame
                    if (self.macro_frames.items.len > 0) {
                        const mf = &self.macro_frames.items[self.macro_frames.items.len - 1];
                        if (mf.variables.getEntry(name)) |entry| {
                            entry.value_ptr.*.deinit(self.allocator);
                            entry.value_ptr.* = val;
                        } else {
                            const name_copy = try self.allocator.dupe(u8, name);
                            try mf.variables.put(name_copy, val);
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
                    const bin_result = try self.executeBinOp(left, right, instr.operand);
                    try self.stack.append(self.allocator, bin_result);
                },
                .ADD => {
                    const right = self.stack.pop() orelse Value{ .null = {} };
                    defer right.deinit(self.allocator);
                    const left = self.stack.pop() orelse Value{ .null = {} };
                    defer left.deinit(self.allocator);
                    const add_result = try self.executeBinOp(left, right, 0);
                    try self.stack.append(self.allocator, add_result);
                },
                .UNARY_OP => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);
                    const unary_result = try self.executeUnaryOp(val, instr.operand);
                    try self.stack.append(self.allocator, unary_result);
                },
                .APPLY_FILTER => {
                    // Unpack operand: bits [0-7] = arg_count, bits [8-15] = kwargs_count, bits [16-31] = name_idx
                    const filter_arg_count = instr.operand & 0xFF;
                    const filter_kwargs_count = (instr.operand >> 8) & 0xFF;
                    const filter_name_idx = (instr.operand >> 16) & 0xFFFF;
                    const filter_name = self.bytecode.names.items[@as(usize, @intCast(filter_name_idx))];

                    // Pop kwargs from stack (in reverse order, as pairs: value, key_idx)
                    var filter_kwargs = std.StringHashMap(Value).init(self.allocator);
                    defer {
                        var kw_iter = filter_kwargs.iterator();
                        while (kw_iter.next()) |entry| {
                            entry.value_ptr.deinit(self.allocator);
                        }
                        filter_kwargs.deinit();
                    }
                    var kw_i: u32 = 0;
                    while (kw_i < filter_kwargs_count) : (kw_i += 1) {
                        const kwarg_val = self.stack.pop() orelse Value{ .null = {} };
                        const key_idx_val = self.stack.pop() orelse Value{ .null = {} };
                        defer key_idx_val.deinit(self.allocator);

                        if (key_idx_val.toInteger()) |key_idx| {
                            const key_name = self.bytecode.names.items[@as(usize, @intCast(key_idx))];
                            try filter_kwargs.put(key_name, kwarg_val);
                        } else {
                            kwarg_val.deinit(self.allocator);
                        }
                    }

                    var filter_args = try self.allocator.alloc(Value, filter_arg_count);
                    defer self.allocator.free(filter_args);
                    var fi: usize = filter_arg_count;
                    while (fi > 0) {
                        fi -= 1;
                        filter_args[fi] = self.stack.pop() orelse Value{ .null = {} };
                    }
                    defer {
                        for (filter_args) |*fa| {
                            fa.deinit(self.allocator);
                        }
                    }

                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);

                    if (self.environment.getFilter(filter_name)) |filter| {
                        const filter_result = try filter.func(self.allocator, val, filter_args, &filter_kwargs, self.context, self.environment);
                        try self.stack.append(self.allocator, filter_result);
                    } else {
                        try self.stack.append(self.allocator, Value{ .null = {} });
                    }
                },
                .BUILD_LIST => {
                    const count = instr.operand;
                    const list = try self.allocator.create(value_mod.List);
                    list.* = value_mod.List.init(self.allocator);
                    var li: usize = 0;
                    while (li < count) : (li += 1) {
                        const item = self.stack.pop() orelse Value{ .null = {} };
                        try list.items.insert(self.allocator, 0, item);
                    }
                    try self.stack.append(self.allocator, Value{ .list = list });
                },
                .JUMP_IF_FALSE => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);
                    if (!(try val.isTruthy())) {
                        macro_pc = instr.operand;
                    }
                },
                .JUMP_IF_TRUE => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    defer val.deinit(self.allocator);
                    if (try val.isTruthy()) {
                        macro_pc = instr.operand;
                    }
                },
                .JUMP => {
                    macro_pc = instr.operand;
                },
                .POP => {
                    const val = self.stack.pop() orelse Value{ .null = {} };
                    val.deinit(self.allocator);
                },
                .DUP => {
                    if (self.stack.items.len > 0) {
                        const top = self.stack.items[self.stack.items.len - 1];
                        const dup_val = try top.deepCopy(self.allocator);
                        try self.stack.append(self.allocator, dup_val);
                    }
                },
                .FOR_LOOP_START => {
                    const var_name = self.bytecode.names.items[@as(usize, @intCast(instr.operand))];
                    var iterable = self.stack.pop() orelse Value{ .null = {} };
                    const items: []const Value = switch (iterable) {
                        .list => |l| l.items.items,
                        else => &[_]Value{},
                    };

                    if (items.len == 0) {
                        var depth: u32 = 1;
                        while (macro_pc < macro_info.body_end) {
                            const next = self.bytecode.instructions.items[@as(usize, @intCast(macro_pc))];
                            if (next.opcode == .FOR_LOOP_START) depth += 1;
                            if (next.opcode == .FOR_LOOP_END) {
                                depth -= 1;
                                if (depth == 0) {
                                    macro_pc += 1;
                                    break;
                                }
                            }
                            macro_pc += 1;
                        }
                        iterable.deinit(self.allocator);
                    } else {
                        try self.loop_stack.append(self.allocator, LoopState{
                            .iterable = iterable,
                            .items = items,
                            .index = 0,
                            .var_name = var_name,
                            .loop_start_pc = macro_pc,
                            .local_slot = 0,
                        });
                        const first = try items[0].deepCopy(self.allocator);
                        try self.stack.append(self.allocator, first);
                    }
                },
                .FOR_LOOP_END => {
                    if (self.loop_stack.items.len > 0) {
                        const loop_state = &self.loop_stack.items[self.loop_stack.items.len - 1];
                        loop_state.index += 1;
                        if (loop_state.index < loop_state.items.len) {
                            const next_item = try loop_state.items[loop_state.index].deepCopy(self.allocator);
                            try self.stack.append(self.allocator, next_item);
                            macro_pc = instr.operand + 1;
                        } else {
                            var completed = self.loop_stack.pop().?;
                            completed.iterable.deinit(self.allocator);
                        }
                    }
                },
                .GET_LOOP_VAR => {
                    if (self.loop_stack.items.len > 0) {
                        const loop_state = &self.loop_stack.items[self.loop_stack.items.len - 1];
                        const loop_result: Value = switch (instr.operand) {
                            0 => try loop_state.items[loop_state.index].deepCopy(self.allocator),
                            1 => Value{ .integer = @intCast(loop_state.index + 1) },
                            2 => Value{ .integer = @intCast(loop_state.index) },
                            3 => Value{ .boolean = loop_state.index == 0 },
                            4 => Value{ .boolean = loop_state.index == loop_state.items.len - 1 },
                            5 => Value{ .integer = @intCast(loop_state.items.len) },
                            6 => Value{ .integer = @intCast(self.loop_stack.items.len) }, // depth (1-based)
                            7 => Value{ .integer = @intCast(self.loop_stack.items.len - 1) }, // depth0 (0-based)
                            else => Value{ .null = {} },
                        };
                        try self.stack.append(self.allocator, loop_result);
                    } else {
                        try self.stack.append(self.allocator, Value{ .null = {} });
                    }
                },
                .INVOKE_CALLER => {
                    if (self.current_caller) |caller_info| {
                        const saved_macro_pc = macro_pc;
                        var caller_pc = caller_info.start_pc;

                        var caller_output = std.ArrayList(u8){};
                        while (caller_pc < caller_info.end_pc) {
                            const caller_instr = self.bytecode.instructions.items[@as(usize, @intCast(caller_pc))];
                            caller_pc += 1;
                            if (caller_instr.opcode == .RETURN) break;
                            if (caller_instr.opcode == .OUTPUT_TEXT) {
                                const text = self.bytecode.strings.items[@as(usize, @intCast(caller_instr.operand))];
                                try caller_output.appendSlice(self.allocator, text);
                            } else if (caller_instr.opcode == .OUTPUT) {
                                const v = self.stack.pop() orelse Value{ .null = {} };
                                defer v.deinit(self.allocator);
                                const s = try v.toString(self.allocator);
                                defer self.allocator.free(s);
                                try caller_output.appendSlice(self.allocator, s);
                            }
                        }

                        macro_pc = saved_macro_pc;
                        const caller_str = try caller_output.toOwnedSlice(self.allocator);
                        try self.stack.append(self.allocator, Value{ .string = caller_str });
                    } else {
                        try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                    }
                },
                else => {
                    // Skip unhandled opcodes
                },
            }
        }

        // Get macro output and restore result buffer
        const macro_output = try self.result.toOwnedSlice(self.allocator);
        self.result = saved_result;

        // Pop frame and restore caller
        var completed_frame = self.macro_frames.pop().?;
        var frame_iter = completed_frame.variables.iterator();
        while (frame_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        completed_frame.variables.deinit();
        self.current_caller = saved_caller;

        // Return result as string
        return Value{ .string = macro_output };
    }

    /// Evaluate a constant expression (used for default argument values)
    fn evaluateConstantExpr(self: *Self, expr: *nodes.Expression) !Value {
        return switch (expr.*) {
            .string_literal => |lit| Value{ .string = try self.allocator.dupe(u8, lit.value) },
            .integer_literal => |lit| Value{ .integer = lit.value },
            .float_literal => |lit| Value{ .float = lit.value },
            .boolean_literal => |lit| Value{ .boolean = lit.value },
            .null_literal => Value{ .null = {} },
            .list_literal => |lit| {
                const list = try self.allocator.create(value_mod.List);
                list.* = value_mod.List.init(self.allocator);
                for (lit.elements.items) |*item| {
                    const item_val = try self.evaluateConstantExpr(item);
                    try list.append(item_val);
                }
                return Value{ .list = list };
            },
            .name => |n| {
                // Try to resolve from context
                return try self.loadVariable(n.name);
            },
            else => Value{ .null = {} },
        };
    }

    /// Execute AST-based macro (fallback for macros not in bytecode)
    fn executeAstMacro(self: *Self, macro: *nodes.Macro, arg_count: u32, kwargs_count: u32, caller: ?CallerInfo) !Value {
        _ = kwargs_count;
        _ = caller;

        // Pop args from stack
        var args = try self.allocator.alloc(Value, arg_count);
        defer self.allocator.free(args);
        var arg_i: usize = arg_count;
        while (arg_i > 0) {
            arg_i -= 1;
            args[arg_i] = self.stack.pop() orelse Value{ .null = {} };
        }
        defer {
            for (args) |*arg| {
                arg.deinit(self.allocator);
            }
        }

        // For AST macros, we need to use the compiler's callMacro
        // For now, return empty string as placeholder
        _ = macro;
        return Value{ .string = try self.allocator.dupe(u8, "") };
    }

    /// Execute slice operation on a list or string
    fn executeSlice(self: *Self, obj: Value, start_val: ?i64, stop_val: ?i64, step: i64) !Value {
        return switch (obj) {
            .list => |l| {
                const len = @as(i64, @intCast(l.items.items.len));
                const normalized_start = normalizeSliceIndex(start_val, len, step, true);
                const normalized_stop = normalizeSliceIndex(stop_val, len, step, false);

                const new_list = try self.allocator.create(value_mod.List);
                new_list.* = value_mod.List.init(self.allocator);
                errdefer {
                    new_list.deinit(self.allocator);
                    self.allocator.destroy(new_list);
                }

                var i = normalized_start;
                while (if (step > 0) i < normalized_stop else i > normalized_stop) {
                    if (i >= 0 and i < len) {
                        try new_list.append(try l.items.items[@intCast(i)].deepCopy(self.allocator));
                    }
                    i += step;
                }
                return Value{ .list = new_list };
            },
            .string => |s| {
                const len = @as(i64, @intCast(s.len));
                const normalized_start = normalizeSliceIndex(start_val, len, step, true);
                const normalized_stop = normalizeSliceIndex(stop_val, len, step, false);

                var result_builder = std.ArrayList(u8){};
                errdefer result_builder.deinit(self.allocator);

                var i = normalized_start;
                while (if (step > 0) i < normalized_stop else i > normalized_stop) {
                    if (i >= 0 and i < len) {
                        try result_builder.append(self.allocator, s[@intCast(i)]);
                    }
                    i += step;
                }
                return Value{ .string = try result_builder.toOwnedSlice(self.allocator) };
            },
            else => return exceptions.TemplateError.TypeError,
        };
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
                // List concatenation: [1,2] + [3,4] = [1,2,3,4]
                if (left == .list and right == .list) {
                    const result_list = try self.allocator.create(value_mod.List);
                    result_list.* = value_mod.List.init(self.allocator);
                    errdefer {
                        result_list.deinit(self.allocator);
                        self.allocator.destroy(result_list);
                    }

                    // Copy elements from left list
                    for (left.list.items.items) |item| {
                        const item_copy = try item.deepCopy(self.allocator);
                        try result_list.append(item_copy);
                    }

                    // Copy elements from right list
                    for (right.list.items.items) |item| {
                        const item_copy = try item.deepCopy(self.allocator);
                        try result_list.append(item_copy);
                    }

                    break :blk Value{ .list = result_list };
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
                    // Unpack operand: bits [0-7] = arg_count, bits [8-15] = kwargs_count, bits [16-31] = name_idx
                    const arg_count = instr.operand & 0xFF;
                    const kwargs_count = (instr.operand >> 8) & 0xFF;
                    const name_idx = (instr.operand >> 16) & 0xFFFF;

                    // Pop kwargs from stack (in reverse order, as pairs: value, key_idx)
                    var kwargs = std.StringHashMap(Value).init(self.allocator);
                    defer {
                        var kw_iter = kwargs.iterator();
                        while (kw_iter.next()) |entry| {
                            entry.value_ptr.deinit(self.allocator);
                        }
                        kwargs.deinit();
                    }
                    var kw_i: u32 = 0;
                    while (kw_i < kwargs_count) : (kw_i += 1) {
                        const kwarg_val = self.stack.pop() orelse Value{ .null = {} };
                        const key_idx_val = self.stack.pop() orelse Value{ .null = {} };
                        defer key_idx_val.deinit(self.allocator);

                        if (key_idx_val.toInteger()) |key_idx| {
                            const key_name = self.bytecode.names.items[@as(usize, @intCast(key_idx))];
                            try kwargs.put(key_name, kwarg_val);
                        } else {
                            kwarg_val.deinit(self.allocator);
                        }
                    }

                    // Pop positional arguments from stack (in reverse order)
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

                    // Apply filter with arguments and kwargs
                    var result = if (use_async) blk: {
                        // Use async filter function if available
                        if (filter.async_func) |async_func| {
                            break :blk try async_func(self.allocator, val, args, self.context, self.environment);
                        } else {
                            // Fall back to sync function with kwargs
                            break :blk try filter.func(self.allocator, val, args, &kwargs, self.context, self.environment);
                        }
                    } else try filter.func(self.allocator, val, args, &kwargs, self.context, self.environment);

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
                    // Pop iterable from stack
                    var iterable = self.stack.pop() orelse Value{ .null = {} };

                    // Auto-await if necessary (async iterable)
                    if (async_utils.AsyncIterator.isAwaitable(iterable)) {
                        iterable = try async_utils.AsyncIterator.autoAwait(self.allocator, iterable);
                    }

                    // Get items from iterable
                    const items: []const Value = switch (iterable) {
                        .list => |l| l.items.items,
                        else => &[_]Value{}, // Non-iterable = empty loop
                    };

                    // Get variable name from operand
                    const var_name = self.bytecode.names.items[@as(usize, @intCast(instr.operand))];

                    if (items.len == 0) {
                        // Empty iterable - skip loop body but NOT else clause
                        var depth: u32 = 1;
                        while (pc < self.bytecode.instructions.items.len) {
                            const next_instr = self.bytecode.instructions.items[@as(usize, @intCast(pc))];
                            if (next_instr.opcode == .FOR_LOOP_START) depth += 1;
                            if (next_instr.opcode == .FOR_LOOP_END) {
                                depth -= 1;
                                if (depth == 0) {
                                    const after_loop_end = pc + 1;
                                    if (after_loop_end < self.bytecode.instructions.items.len) {
                                        const next_after = self.bytecode.instructions.items[@as(usize, @intCast(after_loop_end))];
                                        if (next_after.opcode == .JUMP) {
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
                        iterable.deinit(self.allocator);
                        continue;
                    } else {
                        // Push loop state - takes ownership of iterable
                        try self.loop_stack.append(self.allocator, LoopState{
                            .iterable = iterable,
                            .items = items,
                            .index = 0,
                            .var_name = var_name,
                            .loop_start_pc = pc,
                            .local_slot = 0,
                        });

                        // Update loop_index0 for loop.cycle() and loop.changed()
                        self.loop_index0 = 0;
                        self.last_changed_hash = null;

                        // Push first item to stack
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
                        self.loop_index0 = @intCast(loop_state.index);
                        pc = instr.operand + 1; // Jump to instruction after FOR_LOOP_START
                    } else {
                        // Loop complete - free iterable and pop loop state
                        var completed_state = self.loop_stack.pop().?;
                        completed_state.iterable.deinit(self.allocator);
                        // Reset loop_index0 when exiting loop
                        if (self.loop_stack.items.len > 0) {
                            const outer_loop = &self.loop_stack.items[self.loop_stack.items.len - 1];
                            self.loop_index0 = @intCast(outer_loop.index);
                        } else {
                            self.loop_index0 = 0;
                        }
                    }
                },
                .GET_LOOP_VAR => {
                    // Same as sync version
                    if (self.loop_stack.items.len == 0) {
                        try self.stack.append(self.allocator, Value{ .null = {} });
                        continue;
                    }

                    const loop_state = &self.loop_stack.items[self.loop_stack.items.len - 1];
                    const result: Value = switch (instr.operand) {
                        0 => try loop_state.items[loop_state.index].deepCopy(self.allocator),
                        1 => Value{ .integer = @intCast(loop_state.index + 1) },
                        2 => Value{ .integer = @intCast(loop_state.index) },
                        3 => Value{ .boolean = loop_state.index == 0 },
                        4 => Value{ .boolean = loop_state.index == loop_state.items.len - 1 },
                        5 => Value{ .integer = @intCast(loop_state.items.len) },
                        else => Value{ .null = {} },
                    };
                    try self.stack.append(self.allocator, result);
                },
                .BREAK_LOOP => {
                    // Break out of current loop
                    if (self.loop_stack.items.len == 0) {
                        return exceptions.TemplateError.RuntimeError;
                    }

                    var completed_state = self.loop_stack.pop().?;
                    completed_state.iterable.deinit(self.allocator);

                    // Find matching FOR_LOOP_END
                    var depth: u32 = 1;
                    while (pc < self.bytecode.instructions.items.len) {
                        const next_instr = self.bytecode.instructions.items[@as(usize, @intCast(pc))];
                        if (next_instr.opcode == .FOR_LOOP_START) depth += 1;
                        if (next_instr.opcode == .FOR_LOOP_END) {
                            depth -= 1;
                            if (depth == 0) {
                                pc += 1;
                                break;
                            }
                        }
                        pc += 1;
                    }
                    continue;
                },
                .CONTINUE_LOOP => {
                    // Continue to next iteration
                    if (self.loop_stack.items.len == 0) {
                        return exceptions.TemplateError.RuntimeError;
                    }

                    // Find matching FOR_LOOP_END
                    var depth: u32 = 1;
                    while (pc < self.bytecode.instructions.items.len) {
                        const next_instr = self.bytecode.instructions.items[@as(usize, @intCast(pc))];
                        if (next_instr.opcode == .FOR_LOOP_START) depth += 1;
                        if (next_instr.opcode == .FOR_LOOP_END) {
                            depth -= 1;
                            if (depth == 0) {
                                break;
                            }
                        }
                        pc += 1;
                    }
                    continue;
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

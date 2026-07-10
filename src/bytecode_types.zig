//! Low-dependency bytecode schema and owned pools.
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

//! Shared bytecode VM for top-level, macro, caller, and async execution.
const std = @import("std");
const nodes = @import("nodes.zig");
const value_mod = @import("value.zig");
const exceptions = @import("exceptions.zig");
const context = @import("context.zig");
const environment = @import("environment.zig");
const semantics = @import("semantics.zig");
const types = @import("bytecode_types.zig");
const Opcode = types.Opcode;
const Instruction = types.Instruction;
const Bytecode = types.Bytecode;

fn findMatchingLoopEnd(instructions: []const Instruction, start_pc: u32) ?u32 {
    var cursor = start_pc;
    var depth: u32 = 1;
    while (cursor < instructions.len) : (cursor += 1) {
        switch (instructions[@intCast(cursor)].opcode) {
            .FOR_LOOP_START => depth += 1,
            .FOR_LOOP_END => {
                depth -= 1;
                if (depth == 0) return cursor;
            },
            else => {},
        }
    }
    return null;
}

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
    /// Recursion depth of evaluateConstantExpr (bounded; see that function)
    const_eval_depth: usize = 0,

    const Self = @This();
    const Value = value_mod.Value;
    const Context = @import("context.zig").Context;
    const Environment = @import("environment.zig").Environment;
    const MAX_LOCALS = 64; // Maximum local variables per scope
    const MAX_INLINE_ARGS = 8;

    /// State for a single loop iteration
    pub const LoopState = struct {
        iterable: Value, // The iterable value (OWNED - must be freed)
        items: []const Value, // Items being iterated (reference into iterable)
        index: usize, // Current iteration index
        var_name: []const u8, // Loop variable name
        loop_start_pc: u32, // PC of FOR_LOOP_START instruction
        local_slot: u8, // Slot index for loop variable (Phase 6)
        saved_variable: ?SavedVariable,
    };

    pub const SavedVariable = struct {
        key: []const u8,
        value: Value,
    };

    /// Frame for macro execution
    const MacroFrame = struct {
        variables: std.StringHashMap(Value),
        return_pc: u32, // PC to return to after macro
        caller: ?CallerInfo, // Caller info if called with {% call %}
    };

    pub const ArgBuffer = struct {
        allocator: std.mem.Allocator,
        inline_items: [MAX_INLINE_ARGS]Value = undefined,
        heap_items: ?[]Value = null,
        len: usize = 0,

        pub fn initFromStack(vm: *Self, count: usize) !ArgBuffer {
            var buffer = ArgBuffer{
                .allocator = vm.allocator,
                .len = count,
            };
            const args = if (count <= MAX_INLINE_ARGS)
                buffer.inline_items[0..count]
            else blk: {
                buffer.heap_items = try vm.allocator.alloc(Value, count);
                break :blk buffer.heap_items.?;
            };

            var i: usize = count;
            while (i > 0) {
                i -= 1;
                args[i] = vm.stack.pop() orelse Value{ .null = {} };
            }

            return buffer;
        }

        fn items(self: *ArgBuffer) []Value {
            if (self.heap_items) |items_slice| return items_slice;
            return self.inline_items[0..self.len];
        }

        fn deinit(self: *ArgBuffer) void {
            const args = self.items();
            for (args) |*arg| {
                arg.deinit(self.allocator);
            }
            self.freeStorage();
        }

        fn freeStorage(self: *ArgBuffer) void {
            if (self.heap_items) |items_slice| {
                self.allocator.free(items_slice);
            }
        }
    };

    const BoolBuffer = struct {
        allocator: std.mem.Allocator,
        inline_items: [MAX_INLINE_ARGS]bool = undefined,
        heap_items: ?[]bool = null,
        len: usize = 0,

        fn init(allocator: std.mem.Allocator, count: usize, default: bool) !BoolBuffer {
            var buffer = BoolBuffer{
                .allocator = allocator,
                .len = count,
            };
            const items_slice = if (count <= MAX_INLINE_ARGS)
                buffer.inline_items[0..count]
            else blk: {
                buffer.heap_items = try allocator.alloc(bool, count);
                break :blk buffer.heap_items.?;
            };
            @memset(items_slice, default);
            return buffer;
        }

        fn items(self: *BoolBuffer) []bool {
            if (self.heap_items) |items_slice| return items_slice;
            return self.inline_items[0..self.len];
        }

        fn deinit(self: *BoolBuffer) void {
            if (self.heap_items) |items_slice| {
                self.allocator.free(items_slice);
            }
        }
    };

    pub fn createList(self: *Self, capacity: usize) !*value_mod.List {
        const list = try self.allocator.create(value_mod.List);
        list.* = value_mod.List.init(self.allocator);
        errdefer list.deinit(self.allocator);

        if (capacity > 0) {
            try list.items.ensureTotalCapacity(self.allocator, capacity);
        }

        return list;
    }

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
            if (state.saved_variable) |*saved| {
                self.allocator.free(saved.key);
                saved.value.deinit(self.allocator);
            }
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

    fn activeVariableMap(self: *Self) *std.StringHashMap(Value) {
        if (self.macro_frames.items.len > 0) {
            return &self.macro_frames.items[self.macro_frames.items.len - 1].variables;
        }
        return &self.variables;
    }

    fn deinitMacroFrame(self: *Self, frame: *MacroFrame) void {
        var frame_iter = frame.variables.iterator();
        while (frame_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        frame.variables.deinit();
    }

    pub fn saveLoopVariable(self: *Self, name: []const u8) ?SavedVariable {
        const old = self.activeVariableMap().fetchRemove(name) orelse return null;
        return .{ .key = old.key, .value = old.value };
    }

    pub fn restoreLoopVariable(self: *Self, state: *LoopState) void {
        const variables = self.activeVariableMap();
        if (variables.fetchRemove(state.var_name)) |current| {
            self.allocator.free(current.key);
            current.value.deinit(self.allocator);
        }
        if (state.saved_variable) |saved| {
            variables.putAssumeCapacity(saved.key, saved.value);
            state.saved_variable = null;
        }
    }

    pub fn loopVariable(self: *Self, operand: u32) !Value {
        if (self.loop_stack.items.len == 0) return .{ .null = {} };
        const state = &self.loop_stack.items[self.loop_stack.items.len - 1];
        return switch (operand) {
            0 => state.items[state.index].deepCopy(self.allocator),
            1 => .{ .integer = @intCast(state.index + 1) },
            2 => .{ .integer = @intCast(state.index) },
            3 => .{ .boolean = state.index == 0 },
            4 => .{ .boolean = state.index == state.items.len - 1 },
            5 => .{ .integer = @intCast(state.items.len) },
            6 => .{ .integer = @intCast(self.loop_stack.items.len) },
            7 => .{ .integer = @intCast(self.loop_stack.items.len - 1) },
            else => .{ .null = {} },
        };
    }

    /// Execute bytecode and return result string
    inline fn executeStackInstruction(self: *Self, instr: Instruction) anyerror!void {
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
                const variables = self.activeVariableMap();

                // Check if variable already exists (re-assignment in loop)
                if (variables.getEntry(name)) |entry| {
                    // Free old value, reuse key
                    entry.value_ptr.*.deinit(self.allocator);
                    entry.value_ptr.* = val;
                } else {
                    // New variable - duplicate key
                    const name_copy = try self.allocator.dupe(u8, name);
                    try variables.put(name_copy, val);
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
            .BUILD_LIST => {
                const count = instr.operand;
                const list_ptr = try self.createList(count);

                try list_ptr.items.resize(self.allocator, count);

                // Pop in reverse to restore original list order directly.
                var i: usize = count;
                while (i > 0) {
                    i -= 1;
                    list_ptr.items.items[i] = self.stack.pop() orelse Value{ .null = {} };
                }

                try self.stack.append(self.allocator, Value{ .list = list_ptr });
            },
            .ADD => {
                const right = self.stack.pop() orelse Value{ .null = {} };
                defer right.deinit(self.allocator);
                const left = self.stack.pop() orelse Value{ .null = {} };
                defer left.deinit(self.allocator);
                try self.stack.append(self.allocator, try self.executeBinOp(left, right, @intFromEnum(semantics.BinaryOp.add)));
            },
            .POP => {
                const value = self.stack.pop() orelse Value{ .null = {} };
                value.deinit(self.allocator);
            },
            .DUP => {
                if (self.stack.items.len > 0) {
                    try self.stack.append(self.allocator, try self.stack.items[self.stack.items.len - 1].deepCopy(self.allocator));
                }
            },
            else => unreachable,
        }
    }

    inline fn executeFilterInstruction(self: *Self, instr: Instruction) anyerror!void {
        switch (instr.opcode) {
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
                var args_buffer = try ArgBuffer.initFromStack(self, arg_count);
                defer args_buffer.deinit();
                const args = args_buffer.items();

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
            .APPLY_TEST => {
                // Unpack operand: lower 16 bits = name_idx, upper 16 bits = arg_count
                const name_idx = instr.operand & 0xFFFF;
                const arg_count = instr.operand >> 16;

                // Pop arguments from stack (in reverse order)
                var args_buffer = try ArgBuffer.initFromStack(self, arg_count);
                defer args_buffer.deinit();
                const args = args_buffer.items();

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
            else => unreachable,
        }
    }

    inline fn executeFastFilterOne(self: *Self, instr: Instruction) anyerror!void {
        switch (instr.opcode) {
            .FILTER_UPPER => {
                const val = self.stack.pop() orelse Value{ .null = {} };
                const str = val.toString(self.allocator) catch {
                    val.deinit(self.allocator);
                    try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                    return;
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
                    return;
                }

                // Convert to uppercase in place; toString returned an owned buffer.
                const result = @constCast(str);
                for (result) |*c| {
                    c.* = std.ascii.toUpper(c.*);
                }
                try self.stack.append(self.allocator, Value{ .string = result });
            },
            .FILTER_LOWER => {
                const val = self.stack.pop() orelse Value{ .null = {} };
                const str = val.toString(self.allocator) catch {
                    val.deinit(self.allocator);
                    try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                    return;
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
                    return;
                }

                // Convert to lowercase in place; toString returned an owned buffer.
                const result = @constCast(str);
                for (result) |*c| {
                    c.* = std.ascii.toLower(c.*);
                }
                try self.stack.append(self.allocator, Value{ .string = result });
            },
            .FILTER_ESCAPE => {
                const val = self.stack.pop() orelse Value{ .null = {} };
                const str = val.toString(self.allocator) catch {
                    val.deinit(self.allocator);
                    try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                    return;
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
                    return;
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
            else => unreachable,
        }
    }

    inline fn executeFastFilterTwo(self: *Self, instr: Instruction) anyerror!void {
        switch (instr.opcode) {
            .FILTER_TRIM => {
                const val = self.stack.pop() orelse Value{ .null = {} };
                const str = val.toString(self.allocator) catch {
                    val.deinit(self.allocator);
                    try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                    return;
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
            else => unreachable,
        }
    }

    inline fn executeCallInstruction(self: *Self, instr: Instruction) anyerror!void {
        switch (instr.opcode) {
            .CALL_FUNC => {
                // Generic function call - pop function and args
                const arg_count = instr.operand;

                // Pop arguments from stack (in reverse order)
                var args_buffer = try ArgBuffer.initFromStack(self, arg_count);
                defer args_buffer.deinit();
                const args = args_buffer.items();

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
                    var args_buffer = try ArgBuffer.initFromStack(self, arg_count);
                    defer args_buffer.deinit();
                    const args = args_buffer.items();

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
                var args_buffer = try ArgBuffer.initFromStack(self, arg_count);
                defer args_buffer.deinit();
                const args = args_buffer.items();

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
                    hash = hash *% 31 +% arg.hash();
                }

                const changed = if (self.last_changed_hash) |last_hash|
                    hash != last_hash
                else
                    true;

                self.last_changed_hash = hash;
                try self.stack.append(self.allocator, Value{ .boolean = changed });
            },
            else => unreachable,
        }
    }

    inline fn executeFlowInstruction(self: *Self, instr: Instruction, pc: *u32, output: *std.ArrayList(u8)) anyerror!void {
        switch (instr.opcode) {
            .JUMP_IF_FALSE => {
                const val = self.stack.pop() orelse Value{ .null = {} };
                defer val.deinit(self.allocator);

                if (!(val.isTruthy() catch false)) {
                    pc.* = instr.operand;
                }
            },
            .JUMP_IF_TRUE => {
                const val = self.stack.pop() orelse Value{ .null = {} };
                defer val.deinit(self.allocator);

                if (val.isTruthy() catch false) {
                    pc.* = instr.operand;
                }
            },
            .JUMP => {
                pc.* = instr.operand;
            },
            .OUTPUT => {
                const val = self.stack.pop() orelse Value{ .null = {} };
                defer val.deinit(self.allocator);

                const str = try val.toString(self.allocator);
                defer self.allocator.free(str);
                try output.*.appendSlice(self.allocator, str);
            },
            .OUTPUT_TEXT => {
                const text = self.bytecode.strings.items[@as(usize, @intCast(instr.operand))];
                try output.*.appendSlice(self.allocator, text);
            },
            else => unreachable,
        }
    }

    inline fn executeLoopInstruction(self: *Self, instr: Instruction, pc: *u32) anyerror!void {
        switch (instr.opcode) {
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
                    const loop_end = findMatchingLoopEnd(self.bytecode.instructions.items, pc.*) orelse
                        return exceptions.TemplateError.RuntimeError;
                    const after_loop_end = loop_end + 1;
                    if (after_loop_end < self.bytecode.instructions.items.len and
                        self.bytecode.instructions.items[@intCast(after_loop_end)].opcode == .JUMP)
                    {
                        // A non-empty loop executes this jump to skip its else body.
                        pc.* = after_loop_end + 1;
                    } else {
                        pc.* = after_loop_end;
                    }
                    // Free empty iterable immediately
                    iterable.deinit(self.allocator);
                    return;
                } else {
                    // Push loop state - takes ownership of iterable and saves
                    // any same-named outer local for restoration on every exit.
                    try self.loop_stack.ensureUnusedCapacity(self.allocator, 1);
                    const saved_variable = self.saveLoopVariable(var_name);
                    self.loop_stack.appendAssumeCapacity(LoopState{
                        .iterable = iterable,
                        .items = items,
                        .index = 0,
                        .var_name = var_name,
                        .loop_start_pc = pc.*, // PC after FOR_LOOP_START
                        .local_slot = 0, // Reserved for future use
                        .saved_variable = saved_variable,
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
                    pc.* = instr.operand + 1; // Jump to instruction after FOR_LOOP_START
                } else {
                    // Loop complete - free iterable and pop loop state
                    var completed_state = self.loop_stack.pop().?;
                    self.restoreLoopVariable(&completed_state);
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
                try self.stack.append(self.allocator, try self.loopVariable(instr.operand));
            },
            .BREAK_LOOP => {
                // Break out of current loop - find matching FOR_LOOP_END and jump past it
                if (self.loop_stack.items.len == 0) {
                    return exceptions.TemplateError.RuntimeError;
                }

                // Pop the loop state and free iterable
                var completed_state = self.loop_stack.pop().?;
                self.restoreLoopVariable(&completed_state);
                completed_state.iterable.deinit(self.allocator);

                const loop_end = findMatchingLoopEnd(self.bytecode.instructions.items, pc.*) orelse
                    return exceptions.TemplateError.RuntimeError;
                pc.* = loop_end + 1;
                return;
            },
            .CONTINUE_LOOP => {
                // Continue to next iteration - jump back to FOR_LOOP_END
                if (self.loop_stack.items.len == 0) {
                    return exceptions.TemplateError.RuntimeError;
                }

                // Let FOR_LOOP_END advance the active loop state.
                pc.* = findMatchingLoopEnd(self.bytecode.instructions.items, pc.*) orelse
                    return exceptions.TemplateError.RuntimeError;
                return;
            },
            else => unreachable,
        }
    }

    inline fn executeMacroInstruction(self: *Self, instr: Instruction) anyerror!void {
        switch (instr.opcode) {
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
                if (self.current_caller) |caller| {
                    var caller_output = std.ArrayList(u8){};
                    errdefer caller_output.deinit(self.allocator);
                    try self.executeRange(caller.start_pc, caller.end_pc, &caller_output);
                    try self.stack.append(self.allocator, Value{ .string = try caller_output.toOwnedSlice(self.allocator) });
                } else {
                    try self.stack.append(self.allocator, Value{ .string = try self.allocator.dupe(u8, "") });
                }
            },
            .PUSH_MACRO_FRAME, .POP_MACRO_FRAME, .SET_LOCAL, .GET_LOCAL_VAR => {
                // These are handled internally by executeMacro
                // If we reach them in main execution, they're no-ops
            },
            else => unreachable,
        }
    }

    pub inline fn executeInstruction(self: *Self, instr: Instruction, pc: *u32, output: *std.ArrayList(u8)) anyerror!bool {
        switch (instr.opcode) {
            .LOAD_STRING,
            .LOAD_INT,
            .LOAD_FLOAT,
            .LOAD_BOOL,
            .LOAD_NULL,
            .LOAD_VAR,
            .STORE_VAR,
            .LOAD_LOCAL,
            .STORE_LOCAL,
            .BIN_OP,
            .UNARY_OP,
            .GET_ATTR,
            .GET_ITEM,
            .BUILD_LIST,
            .ADD,
            .POP,
            .DUP,
            => try self.executeStackInstruction(instr),
            .APPLY_FILTER, .APPLY_TEST => try self.executeFilterInstruction(instr),
            .FILTER_UPPER,
            .FILTER_LOWER,
            .FILTER_ESCAPE,
            .FILTER_LENGTH,
            .FILTER_DEFAULT,
            => try self.executeFastFilterOne(instr),
            .FILTER_TRIM,
            .FILTER_FIRST,
            .FILTER_LAST,
            .FILTER_STRING,
            .FILTER_INT,
            => try self.executeFastFilterTwo(instr),
            .CALL_FUNC,
            .CALL_GLOBAL,
            .GET_SLICE,
            .LOOP_CYCLE,
            .LOOP_CHANGED,
            => try self.executeCallInstruction(instr),
            .JUMP_IF_FALSE,
            .JUMP_IF_TRUE,
            .JUMP,
            .OUTPUT,
            .OUTPUT_TEXT,
            => try self.executeFlowInstruction(instr, pc, output),
            .FOR_LOOP_START,
            .FOR_LOOP_END,
            .GET_LOOP_VAR,
            .BREAK_LOOP,
            .CONTINUE_LOOP,
            => try self.executeLoopInstruction(instr, pc),
            .DEFINE_MACRO,
            .CALL_MACRO,
            .CALL_MACRO_WITH_CALLER,
            .INVOKE_CALLER,
            .PUSH_MACRO_FRAME,
            .POP_MACRO_FRAME,
            .SET_LOCAL,
            .GET_LOCAL_VAR,
            => try self.executeMacroInstruction(instr),
            .RETURN, .END => return true,
            else => return exceptions.TemplateError.RuntimeError,
        }
        return false;
    }

    fn executeRange(self: *Self, start: u32, end: u32, output: *std.ArrayList(u8)) anyerror!void {
        var pc = start;
        const bounded_end: u32 = @min(end, @as(u32, @intCast(self.bytecode.instructions.items.len)));
        while (pc < bounded_end) {
            const instruction = self.bytecode.instructions.items[@intCast(pc)];
            pc += 1;
            if (try self.executeInstruction(instruction, &pc, output)) break;
        }
    }

    /// Execute bytecode and return result string
    pub fn execute(self: *Self) ![]const u8 {
        try self.executeRange(0, @intCast(self.bytecode.instructions.items.len), &self.result);
        return self.result.toOwnedSlice(self.allocator);
    }

    /// Load a variable from context or local variables
    pub fn loadVariable(self: *Self, name: []const u8) !Value {
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
            if (self.context.getMacro(macro_name)) |ast_macro_handle| {
                // Fall back to AST execution for macros defined via AST
                const ast_macro = @as(*nodes.Macro, @ptrCast(@alignCast(ast_macro_handle)));
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
        var frame_pushed = false;
        errdefer if (!frame_pushed) self.deinitMacroFrame(&frame);
        try frame.variables.ensureTotalCapacity(@intCast(macro_info.params.items.len + 2));

        // Build kwargs map for lookup - kwargs override positional args
        var kwargs_map = std.StringHashMap(Value).init(self.allocator);
        defer {
            // Clean up any unused kwargs (those not matching a parameter)
            var iter = kwargs_map.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit(self.allocator);
            }
            kwargs_map.deinit();
        }
        try kwargs_map.ensureTotalCapacity(kwargs_count);

        // Pop kwargs from stack (in pairs: key_idx, value) - store in kwargs_map
        var kwargs_i: u32 = 0;
        while (kwargs_i < kwargs_count) : (kwargs_i += 1) {
            const val = self.stack.pop() orelse Value{ .null = {} };
            const key_idx_val = self.stack.pop() orelse Value{ .null = {} };
            defer key_idx_val.deinit(self.allocator);

            if (key_idx_val.toInteger()) |key_idx| {
                const key_name = self.bytecode.names.items[@as(usize, @intCast(key_idx))];
                try kwargs_map.put(key_name, val);
            } else {
                val.deinit(self.allocator);
            }
        }

        // Pop positional args from stack
        var args_buffer = try ArgBuffer.initFromStack(self, arg_count);
        defer args_buffer.freeStorage();
        const args = args_buffer.items();

        // Track which positional args we use (so we can free unused ones)
        var used_positional_buffer = try BoolBuffer.init(self.allocator, arg_count, false);
        defer used_positional_buffer.deinit();
        const used_positional = used_positional_buffer.items();

        // Assign args to parameters - kwargs take priority over positional
        for (macro_info.params.items, 0..) |param, i| {
            var param_value: Value = undefined;
            var found = false;

            // 1. Check keyword argument first (overrides positional)
            if (kwargs_map.fetchRemove(param.name)) |kv| {
                param_value = kv.value;
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
                        // fallow-zig-ignore-next-line zig-alloc-inside-token-loop: decoded default strings must be owned by the macro frame beyond the bytecode pool lookup.
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

            // fallow-zig-ignore-next-line zig-alloc-inside-token-loop: macro-frame variable keys must outlive borrowed parameter metadata.
            const name_copy = try self.allocator.dupe(u8, param.name);
            frame.variables.putAssumeCapacity(name_copy, param_value);
        }

        // Build varargs list from unused positional args (beyond parameters)
        // In Jinja2, varargs captures extra positional arguments
        const varargs_capacity = if (args.len > macro_info.params.items.len) args.len - macro_info.params.items.len else 0;
        const varargs_list = try self.createList(varargs_capacity);
        for (args, 0..) |arg, i| {
            if (i >= macro_info.params.items.len) {
                // Extra positional arg - add to varargs
                varargs_list.items.appendAssumeCapacity(arg);
            } else if (!used_positional[i]) {
                // Unused positional arg (replaced by kwarg) - free it
                var arg_copy = arg;
                arg_copy.deinit(self.allocator);
            }
        }
        const varargs_key = try self.allocator.dupe(u8, "varargs");
        frame.variables.putAssumeCapacity(varargs_key, Value{ .list = varargs_list });

        // Build kwargs dict from remaining kwargs (not matched to parameters)
        // In Jinja2, kwargs captures extra keyword arguments
        const kwargs_dict = try self.allocator.create(value_mod.Dict);
        kwargs_dict.* = value_mod.Dict.init(self.allocator);

        // Dict.set duplicates borrowed name-pool keys; values move into kwargs_dict.
        var remaining_iter = kwargs_map.iterator();
        while (remaining_iter.next()) |entry| {
            try kwargs_dict.set(entry.key_ptr.*, entry.value_ptr.*);
        }

        kwargs_map.clearRetainingCapacity();

        const kwargs_key = try self.allocator.dupe(u8, "kwargs");
        frame.variables.putAssumeCapacity(kwargs_key, Value{ .dict = kwargs_dict });

        // Save current caller and push frame
        const saved_caller = self.current_caller;
        try self.macro_frames.append(self.allocator, frame);
        frame_pushed = true;
        self.current_caller = caller;
        defer {
            var completed_frame = self.macro_frames.pop().?;
            self.deinitMacroFrame(&completed_frame);
            self.current_caller = saved_caller;
        }

        // Macro bodies use the same dispatcher as top-level rendering so every
        // supported opcode has identical semantics in both execution contexts.
        var macro_output_builder = std.ArrayList(u8){};
        errdefer macro_output_builder.deinit(self.allocator);
        try self.executeRange(macro_info.body_start, macro_info.body_end, &macro_output_builder);
        const macro_output = try macro_output_builder.toOwnedSlice(self.allocator);

        // Return result as string
        return Value{ .string = macro_output };
    }

    /// Evaluate a constant expression (used for default argument values).
    /// Depth-limited: constant expressions nest via list literals; beyond the
    /// limit the expression is treated as a template error rather than recursing.
    fn evaluateConstantExpr(self: *Self, expr: *nodes.Expression) !Value {
        if (self.const_eval_depth >= 64) {
            return exceptions.TemplateError.RuntimeError;
        }
        self.const_eval_depth += 1;
        defer self.const_eval_depth -= 1;
        return switch (expr.*) {
            .string_literal => |lit| Value{ .string = try self.allocator.dupe(u8, lit.value) },
            .integer_literal => |lit| Value{ .integer = lit.value },
            .float_literal => |lit| Value{ .float = lit.value },
            .boolean_literal => |lit| Value{ .boolean = lit.value },
            .null_literal => Value{ .null = {} },
            .list_literal => |lit| {
                const list = try self.allocator.create(value_mod.List);
                list.* = value_mod.List.init(self.allocator);
                errdefer list.deinit(self.allocator);
                try list.items.ensureTotalCapacity(self.allocator, lit.elements.items.len);
                for (lit.elements.items) |*item| {
                    const item_val = try self.evaluateConstantExpr(item);
                    list.items.appendAssumeCapacity(item_val);
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
                errdefer new_list.deinit(self.allocator);
                try new_list.items.ensureTotalCapacity(self.allocator, l.items.items.len);

                var i = normalized_start;
                while (if (step > 0) i < normalized_stop else i > normalized_stop) {
                    if (i >= 0 and i < len) {
                        new_list.items.appendAssumeCapacity(try l.items.items[@intCast(i)].deepCopy(self.allocator));
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
                try result_builder.ensureTotalCapacity(self.allocator, s.len);

                var i = normalized_start;
                while (if (step > 0) i < normalized_stop else i > normalized_stop) {
                    if (i >= 0 and i < len) {
                        result_builder.appendAssumeCapacity(s[@intCast(i)]);
                    }
                    i += step;
                }
                return Value{ .string = try result_builder.toOwnedSlice(self.allocator) };
            },
            else => return exceptions.TemplateError.TypeError,
        };
    }

    /// Execute binary operation
    pub fn executeBinOp(self: *Self, left: Value, right: Value, op: u32) !Value {
        const binary_op = semantics.BinaryOp.fromOpcode(op) orelse return exceptions.TemplateError.TypeError;
        return semantics.evalBinary(self.allocator, left, right, binary_op);
    }

    /// Execute unary operation
    pub fn executeUnaryOp(self: *Self, val: Value, op: u32) !Value {
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
    pub fn getAttribute(self: *Self, obj: Value, attr_name: []const u8) !Value {
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
    pub fn getItem(self: *Self, obj: Value, key: Value) !Value {
        return semantics.getItem(self.allocator, obj, key, self.environment.undefined_behavior);
    }

    /// Execute bytecode asynchronously
    /// Properly handles async filters and tests when enable_async is true
    /// Execute bytecode asynchronously while sharing the VM's owned state.
    pub fn executeAsync(self: *Self) ![]const u8 {
        return @import("bytecode_async.zig").execute(self);
    }
};

test "findMatchingLoopEnd skips nested loops and rejects malformed bytecode" {
    const nested = [_]Instruction{
        .init(.FOR_LOOP_START, 0),
        .init(.LOAD_NULL, 0),
        .init(.FOR_LOOP_START, 0),
        .init(.FOR_LOOP_END, 2),
        .init(.FOR_LOOP_END, 0),
    };
    try std.testing.expectEqual(@as(?u32, 4), findMatchingLoopEnd(&nested, 1));
    try std.testing.expectEqual(@as(?u32, 3), findMatchingLoopEnd(&nested, 3));

    const malformed = [_]Instruction{
        .init(.FOR_LOOP_START, 0),
        .init(.LOAD_NULL, 0),
    };
    try std.testing.expectEqual(@as(?u32, null), findMatchingLoopEnd(&malformed, 1));
}

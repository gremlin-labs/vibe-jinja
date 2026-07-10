//! Async-specialized opcodes layered over the shared synchronous dispatcher.
const std = @import("std");
const value_mod = @import("value.zig");
const exceptions = @import("exceptions.zig");
const async_utils = @import("async_utils.zig");
const Value = value_mod.Value;

fn executeFilter(vm: anytype, operand: u32) !void {
    const ArgBuffer = @TypeOf(vm.*).ArgBuffer;
    const argument_count = operand & 0xFF;
    const keyword_count = (operand >> 8) & 0xFF;
    const name_index = (operand >> 16) & 0xFFFF;

    var keywords = std.StringHashMap(Value).init(vm.allocator);
    defer {
        var iterator = keywords.iterator();
        while (iterator.next()) |entry| entry.value_ptr.*.deinit(vm.allocator);
        keywords.deinit();
    }
    try keywords.ensureTotalCapacity(keyword_count);
    var index: u32 = 0;
    while (index < keyword_count) : (index += 1) {
        const keyword_value = vm.stack.pop() orelse Value{ .null = {} };
        const key_value = vm.stack.pop() orelse Value{ .null = {} };
        defer key_value.deinit(vm.allocator);
        const key_index = key_value.toInteger() orelse {
            keyword_value.deinit(vm.allocator);
            continue;
        };
        const key = vm.bytecode.names.items[@intCast(key_index)];
        keywords.putAssumeCapacity(key, keyword_value);
    }

    var arguments = try ArgBuffer.initFromStack(vm, argument_count);
    defer arguments.deinit();
    const input = vm.stack.pop() orelse Value{ .null = {} };
    defer input.deinit(vm.allocator);
    const name = vm.bytecode.names.items[@intCast(name_index)];
    const filter = vm.environment.getFilter(name) orelse return exceptions.TemplateError.RuntimeError;

    var result = if (vm.environment.enable_async and filter.is_async and filter.async_func != null)
        try filter.async_func.?(vm.allocator, input, arguments.items(), vm.context, vm.environment)
    else
        try filter.func(vm.allocator, input, arguments.items(), &keywords, vm.context, vm.environment);
    if (async_utils.AsyncIterator.isAwaitable(result)) {
        result = try async_utils.AsyncIterator.autoAwait(vm.allocator, result);
    }
    try vm.stack.append(vm.allocator, result);
}

fn executeTest(vm: anytype, operand: u32) !void {
    const ArgBuffer = @TypeOf(vm.*).ArgBuffer;
    const name_index = operand & 0xFFFF;
    const argument_count = operand >> 16;
    var arguments = try ArgBuffer.initFromStack(vm, argument_count);
    defer arguments.deinit();
    const input = vm.stack.pop() orelse Value{ .null = {} };
    defer input.deinit(vm.allocator);

    const name = vm.bytecode.names.items[@intCast(name_index)];
    const test_function = vm.environment.getTest(name) orelse return exceptions.TemplateError.RuntimeError;
    const environment = if (test_function.pass_arg == .environment) vm.environment else null;
    const context = vm.context;
    const result = if (vm.environment.enable_async and test_function.is_async and test_function.async_func != null)
        test_function.async_func.?(input, arguments.items(), context, environment)
    else
        test_function.func(input, arguments.items(), context, environment);
    try vm.stack.append(vm.allocator, .{ .boolean = result });
}

fn executeOutput(vm: anytype) !void {
    var value = vm.stack.pop() orelse Value{ .null = {} };
    defer value.deinit(vm.allocator);
    if (async_utils.AsyncIterator.isAwaitable(value)) {
        value = try async_utils.AsyncIterator.autoAwait(vm.allocator, value);
    }
    const string = try value.toString(vm.allocator);
    defer vm.allocator.free(string);
    try vm.result.appendSlice(vm.allocator, string);
}

pub fn execute(vm: anytype) ![]const u8 {
    var program_counter: u32 = 0;
    while (program_counter < vm.bytecode.instructions.items.len) {
        const instruction = vm.bytecode.instructions.items[@intCast(program_counter)];
        program_counter += 1;
        switch (instruction.opcode) {
            .LOAD_VAR => {
                const name = vm.bytecode.names.items[@intCast(instruction.operand)];
                var value = try vm.loadVariable(name);
                if (async_utils.AsyncIterator.isAwaitable(value)) {
                    value = try async_utils.AsyncIterator.autoAwait(vm.allocator, value);
                }
                try vm.stack.append(vm.allocator, value);
            },
            .APPLY_FILTER => try executeFilter(vm, instruction.operand),
            .APPLY_TEST => try executeTest(vm, instruction.operand),
            .OUTPUT => try executeOutput(vm),
            else => if (try vm.executeInstruction(instruction, &program_counter, &vm.result)) break,
        }
    }
    return vm.result.toOwnedSlice(vm.allocator);
}

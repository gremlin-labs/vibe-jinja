//! Public bytecode facade. Implementations follow schema -> generator / VM.
const types = @import("bytecode_types.zig");
const generator = @import("bytecode_generator.zig");
const vm = @import("bytecode_vm.zig");

pub const Opcode = types.Opcode;
pub const Instruction = types.Instruction;
pub const MacroParam = types.MacroParam;
pub const MacroInfo = types.MacroInfo;
pub const Bytecode = types.Bytecode;
pub const BytecodeCacheEntry = types.BytecodeCacheEntry;
pub const BytecodeGenerator = generator.BytecodeGenerator;
pub const CallerInfo = vm.CallerInfo;
pub const BytecodeVM = vm.BytecodeVM;

//! Shared expression semantics for the AST interpreter, bytecode VM, and optimizer.

const std = @import("std");
const exceptions = @import("exceptions.zig");
const value_mod = @import("value.zig");
const lexer = @import("lexer.zig");

const token_binary_ops = blk: {
    var operations = [_]?BinaryOp{null} ** @typeInfo(lexer.TokenKind).@"enum".fields.len;
    operations[@intFromEnum(lexer.TokenKind.ADD)] = .add;
    operations[@intFromEnum(lexer.TokenKind.SUB)] = .sub;
    operations[@intFromEnum(lexer.TokenKind.MUL)] = .mul;
    operations[@intFromEnum(lexer.TokenKind.DIV)] = .div;
    operations[@intFromEnum(lexer.TokenKind.FLOORDIV)] = .floor_div;
    operations[@intFromEnum(lexer.TokenKind.MOD)] = .mod;
    operations[@intFromEnum(lexer.TokenKind.POW)] = .pow;
    operations[@intFromEnum(lexer.TokenKind.EQ)] = .eq;
    operations[@intFromEnum(lexer.TokenKind.NE)] = .ne;
    operations[@intFromEnum(lexer.TokenKind.LT)] = .lt;
    operations[@intFromEnum(lexer.TokenKind.LTEQ)] = .le;
    operations[@intFromEnum(lexer.TokenKind.GT)] = .gt;
    operations[@intFromEnum(lexer.TokenKind.GTEQ)] = .ge;
    operations[@intFromEnum(lexer.TokenKind.AND)] = .and_op;
    operations[@intFromEnum(lexer.TokenKind.OR)] = .or_op;
    operations[@intFromEnum(lexer.TokenKind.IN)] = .in_op;
    break :blk operations;
};

pub const BinaryOp = enum(u4) {
    add,
    sub,
    mul,
    div,
    floor_div,
    mod,
    pow,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_op,
    or_op,
    in_op,

    pub inline fn fromOpcode(opcode: u32) ?BinaryOp {
        if (opcode > @intFromEnum(BinaryOp.in_op)) return null;
        return @enumFromInt(opcode);
    }

    pub fn fromTokenKind(kind: lexer.TokenKind) ?BinaryOp {
        return token_binary_ops[@intFromEnum(kind)];
    }
};

const Value = value_mod.Value;

fn numericPair(left: Value, right: Value) ?struct { left: f64, right: f64 } {
    const left_number = switch (left) {
        .integer => |number| @as(f64, @floatFromInt(number)),
        .float => |number| number,
        else => return null,
    };
    const right_number = switch (right) {
        .integer => |number| @as(f64, @floatFromInt(number)),
        .float => |number| number,
        else => return null,
    };
    return .{ .left = left_number, .right = right_number };
}

fn concatenateLists(allocator: std.mem.Allocator, left: *value_mod.List, right: *value_mod.List) !Value {
    const result = try allocator.create(value_mod.List);
    result.* = value_mod.List.init(allocator);
    errdefer result.deinit(allocator);
    try result.items.ensureUnusedCapacity(allocator, left.items.items.len + right.items.items.len);
    for (left.items.items) |item| result.items.appendAssumeCapacity(try item.deepCopy(allocator));
    for (right.items.items) |item| result.items.appendAssumeCapacity(try item.deepCopy(allocator));
    return .{ .list = result };
}

fn concatenateValues(allocator: std.mem.Allocator, left: Value, right: Value) !Value {
    const left_string = try left.toString(allocator);
    defer allocator.free(left_string);
    const right_string = try right.toString(allocator);
    defer allocator.free(right_string);
    return .{ .string = try std.mem.concat(allocator, u8, &.{ left_string, right_string }) };
}

fn compare(allocator: std.mem.Allocator, left: Value, right: Value) !std.math.Order {
    if (numericPair(left, right)) |numbers| return std.math.order(numbers.left, numbers.right);
    const left_string = try left.toString(allocator);
    defer allocator.free(left_string);
    const right_string = try right.toString(allocator);
    defer allocator.free(right_string);
    return std.mem.order(u8, left_string, right_string);
}

fn contains(allocator: std.mem.Allocator, needle: Value, haystack: Value) !bool {
    return switch (haystack) {
        .list => |list| blk: {
            for (list.items.items) |item| {
                if (try needle.isEqual(item)) break :blk true;
            }
            break :blk false;
        },
        .dict => |dict| blk: {
            const key = try needle.toString(allocator);
            defer allocator.free(key);
            break :blk dict.map.contains(key);
        },
        .string => |string| blk: {
            const substring = try needle.toString(allocator);
            defer allocator.free(substring);
            break :blk std.mem.indexOf(u8, string, substring) != null;
        },
        else => exceptions.TemplateError.TypeError,
    };
}

/// Evaluate one binary expression with identical allocation, coercion, and
/// error behavior for every execution backend.
fn evalAdd(allocator: std.mem.Allocator, left: Value, right: Value) !Value {
    return switch (left) {
        .integer => |number| switch (right) {
            .integer => |other| .{ .integer = number + other },
            .float => |other| .{ .float = @as(f64, @floatFromInt(number)) + other },
            else => concatenateValues(allocator, left, right),
        },
        .float => |number| switch (right) {
            .integer => |other| .{ .float = number + @as(f64, @floatFromInt(other)) },
            .float => |other| .{ .float = number + other },
            else => concatenateValues(allocator, left, right),
        },
        .list => |list| switch (right) {
            .list => |other| concatenateLists(allocator, list, other),
            else => concatenateValues(allocator, left, right),
        },
        else => concatenateValues(allocator, left, right),
    };
}

fn evalSub(left: Value, right: Value) !Value {
    return switch (left) {
        .integer => |number| switch (right) {
            .integer => |other| .{ .integer = number - other },
            .float => |other| .{ .float = @as(f64, @floatFromInt(number)) - other },
            else => exceptions.TemplateError.TypeError,
        },
        .float => |number| switch (right) {
            .integer => |other| .{ .float = number - @as(f64, @floatFromInt(other)) },
            .float => |other| .{ .float = number - other },
            else => exceptions.TemplateError.TypeError,
        },
        else => exceptions.TemplateError.TypeError,
    };
}

fn evalMul(left: Value, right: Value) !Value {
    return switch (left) {
        .integer => |number| switch (right) {
            .integer => |other| .{ .integer = number * other },
            .float => |other| .{ .float = @as(f64, @floatFromInt(number)) * other },
            else => exceptions.TemplateError.TypeError,
        },
        .float => |number| switch (right) {
            .integer => |other| .{ .float = number * @as(f64, @floatFromInt(other)) },
            .float => |other| .{ .float = number * other },
            else => exceptions.TemplateError.TypeError,
        },
        else => exceptions.TemplateError.TypeError,
    };
}

fn evalDiv(left: Value, right: Value) !Value {
    const numbers = numericPair(left, right) orelse return exceptions.TemplateError.TypeError;
    if (numbers.right == 0.0) return exceptions.TemplateError.DivisionByZero;
    return .{ .float = numbers.left / numbers.right };
}

fn evalFloorDiv(left: Value, right: Value) !Value {
    if (left == .integer and right == .integer) {
        if (right.integer == 0) return exceptions.TemplateError.DivisionByZero;
        return .{ .integer = @divFloor(left.integer, right.integer) };
    }
    const numbers = numericPair(left, right) orelse return exceptions.TemplateError.TypeError;
    if (numbers.right == 0.0) return exceptions.TemplateError.DivisionByZero;
    return .{ .float = @floor(numbers.left / numbers.right) };
}

fn evalMod(left: Value, right: Value) !Value {
    if (left != .integer or right != .integer) return exceptions.TemplateError.TypeError;
    if (right.integer == 0) return exceptions.TemplateError.DivisionByZero;
    return .{ .integer = @mod(left.integer, right.integer) };
}

fn evalPow(left: Value, right: Value) !Value {
    if (left == .integer and right == .integer and right.integer >= 0 and right.integer < 64) {
        if (std.math.powi(i64, left.integer, @intCast(right.integer))) |result| {
            return .{ .integer = result };
        } else |_| {}
    }
    const numbers = numericPair(left, right) orelse return exceptions.TemplateError.TypeError;
    return .{ .float = std.math.pow(f64, numbers.left, numbers.right) };
}

fn evalComparison(allocator: std.mem.Allocator, left: Value, right: Value, op: BinaryOp) !Value {
    if (op == .eq) return .{ .boolean = try left.isEqual(right) };
    if (op == .ne) return .{ .boolean = !try left.isEqual(right) };
    const order = try compare(allocator, left, right);
    return .{ .boolean = switch (op) {
        .lt => order == .lt,
        .le => order != .gt,
        .gt => order == .gt,
        .ge => order != .lt,
        else => unreachable,
    } };
}

/// Evaluate one binary expression with identical allocation, coercion, and
/// error behavior for every execution backend.
pub inline fn evalBinary(allocator: std.mem.Allocator, left: Value, right: Value, op: BinaryOp) !Value {
    return switch (op) {
        .add => evalAdd(allocator, left, right),
        .sub => evalSub(left, right),
        .mul => evalMul(left, right),
        .div => evalDiv(left, right),
        .floor_div => evalFloorDiv(left, right),
        .mod => evalMod(left, right),
        .pow => evalPow(left, right),
        .eq, .ne, .lt, .le, .gt, .ge => evalComparison(allocator, left, right, op),
        .and_op => .{ .boolean = (try left.isTruthy()) and (try right.isTruthy()) },
        .or_op => .{ .boolean = (try left.isTruthy()) or (try right.isTruthy()) },
        .in_op => .{ .boolean = try contains(allocator, left, right) },
    };
}

pub fn undefinedValue(allocator: std.mem.Allocator, name: []const u8, behavior: value_mod.UndefinedBehavior, logger: ?*const value_mod.UndefinedLogger) !Value {
    return .{ .undefined = .{
        .name = try allocator.dupe(u8, name),
        .behavior = behavior,
        .logger = logger,
    } };
}

/// Shared Python-style subscript semantics for node, AST, and bytecode paths.
pub fn getItem(allocator: std.mem.Allocator, object: Value, index: Value, default_behavior: value_mod.UndefinedBehavior) !Value {
    if (object == .undefined) {
        const undefined_value = object.undefined;
        undefined_value.logAccess("getItem");
        if (undefined_value.behavior == .strict) return exceptions.TemplateError.UndefinedError;
        return undefinedValue(allocator, "item", undefined_value.behavior, undefined_value.logger);
    }

    return switch (object) {
        .list => |list| blk: {
            const raw_index = index.toInteger() orelse return exceptions.TemplateError.TypeError;
            const length: i64 = @intCast(list.items.items.len);
            const normalized = if (raw_index < 0) length + raw_index else raw_index;
            if (normalized < 0 or normalized >= length) break :blk undefinedValue(allocator, "item", default_behavior, null);
            break :blk list.items.items[@intCast(normalized)].deepCopy(allocator);
        },
        .dict => |dict| blk: {
            const key = try index.toString(allocator);
            defer allocator.free(key);
            const item = dict.get(key) orelse break :blk undefinedValue(allocator, "item", default_behavior, null);
            break :blk item.deepCopy(allocator);
        },
        .string => |string| blk: {
            const raw_index = index.toInteger() orelse return exceptions.TemplateError.TypeError;
            const length: i64 = @intCast(string.len);
            const normalized = if (raw_index < 0) length + raw_index else raw_index;
            if (normalized < 0 or normalized >= length) break :blk undefinedValue(allocator, "item", default_behavior, null);
            break :blk .{ .string = try allocator.dupe(u8, string[@intCast(normalized) .. @as(usize, @intCast(normalized)) + 1]) };
        },
        .custom => |custom| (try custom.getItem(index, allocator)) orelse try undefinedValue(allocator, "item", default_behavior, null),
        else => undefinedValue(allocator, "item", default_behavior, null),
    };
}

/// Materialize Jinja iteration values with identical list, string, and mapping
/// behavior for AST and bytecode execution. Mapping iteration yields keys.
pub fn collectIterationItems(allocator: std.mem.Allocator, iterable: Value) !*value_mod.List {
    const items = try allocator.create(value_mod.List);
    items.* = value_mod.List.init(allocator);
    errdefer items.deinit(allocator);

    switch (iterable) {
        .list => |list| {
            try items.items.ensureTotalCapacity(allocator, list.items.items.len);
            for (list.items.items) |item| items.items.appendAssumeCapacity(try item.deepCopy(allocator));
        },
        .string => |string| {
            try items.items.ensureTotalCapacity(allocator, string.len);
            for (string) |character| {
                items.items.appendAssumeCapacity(.{ .string = try std.fmt.allocPrint(allocator, "{c}", .{character}) });
            }
        },
        .dict => |dict| {
            try items.items.ensureTotalCapacity(allocator, dict.map.count());
            var iterator = dict.map.iterator();
            while (iterator.next()) |entry| {
                items.items.appendAssumeCapacity(.{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
            }
        },
        else => {},
    }
    return items;
}

/// Build the public dictionary representation of a template context.
pub fn contextToValue(allocator: std.mem.Allocator, ctx: anytype) !Value {
    const dictionary = try allocator.create(value_mod.Dict);
    dictionary.* = value_mod.Dict.init(allocator);
    errdefer dictionary.deinit(allocator);

    if (ctx.name) |name| {
        try dictionary.set(name, .{ .string = try allocator.dupe(u8, name) });
    }
    var exported = ctx.exported_vars.iterator();
    while (exported.next()) |entry| {
        const resolved = ctx.resolve(entry.key_ptr.*);
        if (resolved != .undefined) try dictionary.set(entry.key_ptr.*, try resolved.deepCopy(allocator));
    }
    return .{ .dict = dictionary };
}

test "mixed numeric semantics preserve fractions" {
    const result = try evalBinary(std.testing.allocator, .{ .integer = 42 }, .{ .float = 0.5 }, .add);
    try std.testing.expectEqual(@as(f64, 42.5), result.float);
    try std.testing.expect(!(try evalBinary(std.testing.allocator, .{ .integer = 42 }, .{ .float = 42.5 }, .eq)).boolean);
}

test "integer floor division follows Python sign semantics" {
    const result = try evalBinary(std.testing.allocator, .{ .integer = -3 }, .{ .integer = 2 }, .floor_div);
    try std.testing.expectEqual(@as(i64, -2), result.integer);
}

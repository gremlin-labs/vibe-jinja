//! Bounded conversion from Zig's dynamic JSON tree into owned Jinja values.

const std = @import("std");
const value = @import("value.zig");

pub const max_depth: usize = 256;
pub const ConversionError = error{InputTooDeep};

pub fn toValue(allocator: std.mem.Allocator, input: std.json.Value) (std.mem.Allocator.Error || ConversionError)!value.Value {
    return toValueAtDepth(allocator, input, 0);
}

fn toValueAtDepth(
    allocator: std.mem.Allocator,
    input: std.json.Value,
    depth: usize,
) (std.mem.Allocator.Error || ConversionError)!value.Value {
    return switch (input) {
        .null => .{ .null = {} },
        .bool => |item| .{ .boolean = item },
        .integer => |item| .{ .integer = item },
        .float => |item| .{ .float = item },
        .number_string => |item| .{ .string = try allocator.dupe(u8, item) },
        .string => |item| .{ .string = try allocator.dupe(u8, item) },
        .array => |array| blk: {
            if (depth >= max_depth) return ConversionError.InputTooDeep;
            const list = try allocator.create(value.List);
            list.* = value.List.init(allocator);
            errdefer list.deinit(allocator);

            for (array.items) |item| {
                const converted = try toValueAtDepth(allocator, item, depth + 1);
                errdefer converted.deinit(allocator);
                try list.append(converted);
            }
            break :blk .{ .list = list };
        },
        .object => |object| blk: {
            if (depth >= max_depth) return ConversionError.InputTooDeep;
            const dict = try allocator.create(value.Dict);
            dict.* = value.Dict.init(allocator);
            errdefer dict.deinit(allocator);

            var iter = object.iterator();
            while (iter.next()) |entry| {
                const converted = try toValueAtDepth(allocator, entry.value_ptr.*, depth + 1);
                errdefer converted.deinit(allocator);
                try dict.set(entry.key_ptr.*, converted);
            }
            break :blk .{ .dict = dict };
        },
    };
}

fn nestedArrayJson(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    const json = try allocator.alloc(u8, depth * 2 + 1);
    @memset(json[0..depth], '[');
    json[depth] = '0';
    @memset(json[depth + 1 ..], ']');
    return json;
}

test "JSON conversion accepts the exact nesting boundary" {
    const allocator = std.testing.allocator;
    const source = try nestedArrayJson(allocator, max_depth);
    defer allocator.free(source);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();

    const converted = try toValue(allocator, parsed.value);
    defer converted.deinit(allocator);
    try std.testing.expect(converted == .list);
}

test "JSON conversion rejects nesting beyond the boundary without leaks" {
    const allocator = std.testing.allocator;
    const source = try nestedArrayJson(allocator, max_depth + 1);
    defer allocator.free(source);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();

    try std.testing.expectError(ConversionError.InputTooDeep, toValue(allocator, parsed.value));
}

test "JSON conversion preserves shallow arrays and objects" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"items\":[1,true,\"x\"]}", .{});
    defer parsed.deinit();
    const converted = try toValue(allocator, parsed.value);
    defer converted.deinit(allocator);

    try std.testing.expect(converted == .dict);
    const items = converted.dict.get("items").?;
    try std.testing.expectEqual(@as(usize, 3), items.list.items.items.len);
}

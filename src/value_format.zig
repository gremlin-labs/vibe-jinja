//! Bounded writer-based formatting shared by JSON and pretty-print filters.

const std = @import("std");
const exceptions = @import("exceptions.zig");
const value_mod = @import("value.zig");

const max_depth: usize = 64;
pub const FormatError = exceptions.TemplateError || std.mem.Allocator.Error || error{ Overflow, InvalidCharacter };

const Traversal = struct {
    pointers: [max_depth]usize = undefined,
    len: usize = 0,

    fn enter(self: *Traversal, pointer: usize) !void {
        if (self.len >= max_depth) return exceptions.TemplateError.RuntimeError;
        for (self.pointers[0..self.len]) |active| {
            if (active == pointer) return exceptions.TemplateError.RuntimeError;
        }
        self.pointers[self.len] = pointer;
        self.len += 1;
    }

    fn leave(self: *Traversal) void {
        self.len -= 1;
    }
};

fn appendIndent(output: *std.ArrayList(u8), allocator: std.mem.Allocator, count: usize) !void {
    try output.appendNTimes(allocator, ' ', count);
}

fn appendQuoted(output: *std.ArrayList(u8), allocator: std.mem.Allocator, string: []const u8) !void {
    try output.append(allocator, '"');
    for (string) |byte| switch (byte) {
        '"' => try output.appendSlice(allocator, "\\\""),
        '\\' => try output.appendSlice(allocator, "\\\\"),
        '\n' => try output.appendSlice(allocator, "\\n"),
        '\r' => try output.appendSlice(allocator, "\\r"),
        '\t' => try output.appendSlice(allocator, "\\t"),
        0x08 => try output.appendSlice(allocator, "\\b"),
        0x0c => try output.appendSlice(allocator, "\\f"),
        0...7, 11, 14...0x1f => try output.writer(allocator).print("\\u00{x:0>2}", .{byte}),
        else => try output.append(allocator, byte),
    };
    try output.append(allocator, '"');
}

fn appendJsonScalar(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: value_mod.Value) !void {
    switch (value) {
        .string => |string| try appendQuoted(output, allocator, string),
        .markup => |markup| try appendQuoted(output, allocator, markup.content),
        .integer => |integer| try output.writer(allocator).print("{d}", .{integer}),
        .float => |float| {
            if (!std.math.isFinite(float)) return exceptions.TemplateError.TypeError;
            try output.writer(allocator).print("{d}", .{float});
        },
        .boolean => |boolean| try output.appendSlice(allocator, if (boolean) "true" else "false"),
        .null, .undefined => try output.appendSlice(allocator, "null"),
        .callable => try appendQuoted(output, allocator, "<callable>"),
        .custom => |custom| {
            if (custom.toString(allocator) catch null) |string| {
                defer allocator.free(string);
                try appendQuoted(output, allocator, string);
            } else {
                try appendQuoted(output, allocator, custom.typeName());
            }
        },
        .list, .dict, .async_result => unreachable,
    }
}

fn appendJsonList(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    list: *value_mod.List,
    indent: ?usize,
    depth: usize,
    traversal: *Traversal,
) FormatError!void {
    try traversal.enter(@intFromPtr(list));
    defer traversal.leave();
    try output.append(allocator, '[');
    if (list.items.items.len == 0) return output.append(allocator, ']');
    if (indent != null) try output.append(allocator, '\n');
    for (list.items.items, 0..) |item, index| {
        if (indent) |width| try appendIndent(output, allocator, (depth + 1) * width);
        try appendJsonValue(output, allocator, item, indent, depth + 1, traversal);
        if (index + 1 < list.items.items.len) try output.appendSlice(allocator, if (indent == null) ", " else ",");
        if (indent != null) try output.append(allocator, '\n');
    }
    if (indent) |width| try appendIndent(output, allocator, depth * width);
    try output.append(allocator, ']');
}

fn appendJsonDict(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    dict: *value_mod.Dict,
    indent: ?usize,
    depth: usize,
    traversal: *Traversal,
) FormatError!void {
    try traversal.enter(@intFromPtr(dict));
    defer traversal.leave();
    try output.append(allocator, '{');
    if (dict.map.count() == 0) return output.append(allocator, '}');
    if (indent != null) try output.append(allocator, '\n');
    const keys = try allocator.alloc([]const u8, dict.map.count());
    defer allocator.free(keys);
    var iterator = dict.map.keyIterator();
    var key_index: usize = 0;
    while (iterator.next()) |key| : (key_index += 1) keys[key_index] = key.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);

    for (keys, 0..) |key, index| {
        if (indent) |width| try appendIndent(output, allocator, (depth + 1) * width);
        try appendQuoted(output, allocator, key);
        try output.appendSlice(allocator, ": ");
        try appendJsonValue(output, allocator, dict.map.get(key).?, indent, depth + 1, traversal);
        if (index + 1 < keys.len) try output.appendSlice(allocator, if (indent == null) ", " else ",");
        if (indent != null) try output.append(allocator, '\n');
    }
    if (indent) |width| try appendIndent(output, allocator, depth * width);
    try output.append(allocator, '}');
}

fn appendJsonValue(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: value_mod.Value,
    indent: ?usize,
    depth: usize,
    traversal: *Traversal,
) FormatError!void {
    if (depth >= max_depth) return exceptions.TemplateError.RuntimeError;
    switch (value) {
        .list => |list| try appendJsonList(output, allocator, list, indent, depth, traversal),
        .dict => |dict| try appendJsonDict(output, allocator, dict, indent, depth, traversal),
        .async_result => |result| {
            try traversal.enter(@intFromPtr(result));
            defer traversal.leave();
            if (result.value) |resolved| try appendJsonValue(output, allocator, resolved, indent, depth + 1, traversal) else try output.appendSlice(allocator, "null");
        },
        else => try appendJsonScalar(output, allocator, value),
    }
}

pub fn json(allocator: std.mem.Allocator, value: value_mod.Value, indent: ?usize) FormatError![]u8 {
    var output = std.ArrayList(u8){};
    errdefer output.deinit(allocator);
    var traversal = Traversal{};
    try appendJsonValue(&output, allocator, value, indent, 0, &traversal);
    return output.toOwnedSlice(allocator);
}

fn appendPrettyScalar(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: value_mod.Value) !void {
    switch (value) {
        .string => |string| try appendQuoted(output, allocator, string),
        .markup => |markup| try appendQuoted(output, allocator, markup.content),
        .integer => |integer| try output.writer(allocator).print("{d}", .{integer}),
        .float => |float| try output.writer(allocator).print("{d}", .{float}),
        .boolean => |boolean| try output.appendSlice(allocator, if (boolean) "true" else "false"),
        .null => try output.appendSlice(allocator, "null"),
        .undefined => |undefined_value| try output.writer(allocator).print("undefined({s})", .{undefined_value.name}),
        .callable => |callable| try output.writer(allocator).print("<{s} {s}>", .{ @tagName(callable.callable_type), callable.name orelse "<anonymous>" }),
        .custom => |custom| try output.writer(allocator).print("<{s} object>", .{custom.typeName()}),
        .list, .dict, .async_result => unreachable,
    }
}

fn appendPrettyValue(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: value_mod.Value, indent: usize, depth: usize, traversal: *Traversal) FormatError!void {
    if (depth >= max_depth) return exceptions.TemplateError.RuntimeError;
    switch (value) {
        .list => |list| try appendJsonList(output, allocator, list, indent, depth, traversal),
        .dict => |dict| try appendJsonDict(output, allocator, dict, indent, depth, traversal),
        .async_result => |result| {
            try traversal.enter(@intFromPtr(result));
            defer traversal.leave();
            if (result.value) |resolved| try appendPrettyValue(output, allocator, resolved, indent, depth + 1, traversal) else try output.writer(allocator).print("<async pending:{d}>", .{result.id});
        },
        else => try appendPrettyScalar(output, allocator, value),
    }
}

pub fn pretty(allocator: std.mem.Allocator, value: value_mod.Value, indent: usize) FormatError![]u8 {
    var output = std.ArrayList(u8){};
    errdefer output.deinit(allocator);
    var traversal = Traversal{};
    try appendPrettyValue(&output, allocator, value, indent, 0, &traversal);
    return output.toOwnedSlice(allocator);
}

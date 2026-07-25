//! Ownership and capacity helpers shared by built-in filter categories.
const std = @import("std");
const value_mod = @import("value.zig");

pub fn createList(allocator: std.mem.Allocator, capacity: usize) !*value_mod.List {
    const list = try allocator.create(value_mod.List);
    list.* = value_mod.List.init(allocator);
    errdefer list.deinit(allocator);
    if (capacity > 0) try list.items.ensureTotalCapacity(allocator, capacity);
    return list;
}

pub fn createDict(allocator: std.mem.Allocator, capacity: usize) !*value_mod.Dict {
    const dict = try allocator.create(value_mod.Dict);
    dict.* = value_mod.Dict.init(allocator);
    errdefer dict.deinit(allocator);
    if (capacity > 0) {
        const map_capacity = std.math.cast(u32, capacity) orelse std.math.maxInt(u32);
        try dict.map.ensureTotalCapacity(map_capacity);
    }
    return dict;
}

pub fn attributeTruthy(item: value_mod.Value, attr_name: []const u8) bool {
    return switch (item) {
        .dict => |dict| if (dict.get(attr_name)) |attr| attr.isTruthy() catch false else false,
        else => false,
    };
}

pub fn appendOwnedCopy(allocator: std.mem.Allocator, list: *value_mod.List, item: value_mod.Value) !void {
    var item_copy = try item.deepCopy(allocator);
    errdefer item_copy.deinit(allocator);
    try list.append(item_copy);
}

pub fn appendOwnedString(allocator: std.mem.Allocator, list: *value_mod.List, text: []const u8) !void {
    const owned = try allocator.dupe(u8, text);
    errdefer allocator.free(owned);
    try list.append(.{ .string = owned });
}

pub fn deinitGroups(allocator: std.mem.Allocator, groups: *std.StringHashMap(*value_mod.List), own_lists: bool) void {
    var iter = groups.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        if (own_lists) entry.value_ptr.*.deinit(allocator);
    }
    groups.deinit();
}

pub fn urlOutputCapacity(input_len: usize) !usize {
    return std.math.mul(usize, input_len, 5) catch error.OutOfMemory;
}

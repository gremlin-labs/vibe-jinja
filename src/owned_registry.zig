const std = @import("std");

/// Insert an owned named pointer into a registry, replacing the previous
/// key/object pair atomically from the registry's ownership perspective.
pub fn putNamed(
    comptime T: type,
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(*T),
    name: []const u8,
    value: T,
) !void {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    const object = try allocator.create(T);
    errdefer allocator.destroy(object);
    object.* = value;
    object.name = name_copy;

    // Reserve first so replacement cannot lose the old value on allocation failure.
    try map.ensureUnusedCapacity(1);
    if (map.fetchRemove(name)) |old| {
        allocator.free(old.key);
        allocator.destroy(old.value);
    }
    map.putAssumeCapacity(name_copy, object);
}


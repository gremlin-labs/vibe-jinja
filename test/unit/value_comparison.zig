const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const value = vibe_jinja.value;

test "value isEqual same type integers" {
    const val1 = value.Value{ .integer = 42 };
    const val2 = value.Value{ .integer = 42 };
    const val3 = value.Value{ .integer = 43 };
    
    try testing.expect(try val1.isEqual(val2) == true);
    try testing.expect(try val1.isEqual(val3) == false);
}

test "value isEqual same type floats" {
    const val1 = value.Value{ .float = 3.14 };
    const val2 = value.Value{ .float = 3.14 };
    const val3 = value.Value{ .float = 3.15 };
    
    try testing.expect(try val1.isEqual(val2) == true);
    try testing.expect(try val1.isEqual(val3) == false);
}

test "value isEqual same type strings" {
    const val1 = value.Value{ .string = "hello" };
    const val2 = value.Value{ .string = "hello" };
    const val3 = value.Value{ .string = "world" };
    
    try testing.expect(try val1.isEqual(val2) == true);
    try testing.expect(try val1.isEqual(val3) == false);
}

test "value isEqual same type booleans" {
    const val_true1 = value.Value{ .boolean = true };
    const val_true2 = value.Value{ .boolean = true };
    const val_false1 = value.Value{ .boolean = false };
    const val_false2 = value.Value{ .boolean = false };
    const val_true3 = value.Value{ .boolean = true };
    const val_false3 = value.Value{ .boolean = false };
    
    try testing.expect(try val_true1.isEqual(val_true2) == true);
    try testing.expect(try val_false1.isEqual(val_false2) == true);
    try testing.expect(try val_true3.isEqual(val_false3) == false);
}

test "value isEqual cross type int float" {
    const int_val = value.Value{ .integer = 42 };
    const float_val = value.Value{ .float = 42.0 };
    
    try testing.expect(try int_val.isEqual(float_val) == true);
}

test "value isEqual mixed numeric comparison does not truncate" {
    const integer = value.Value{ .integer = 42 };
    const fractional = value.Value{ .float = 42.5 };

    try testing.expect(!try integer.isEqual(fractional));
    try testing.expect(!try fractional.isEqual(integer));
}

test "value isEqual handles non-finite floats exactly" {
    const positive_infinity = value.Value{ .float = std.math.inf(f64) };
    const negative_infinity = value.Value{ .float = -std.math.inf(f64) };
    const not_a_number = value.Value{ .float = std.math.nan(f64) };

    try testing.expect(try positive_infinity.isEqual(positive_infinity));
    try testing.expect(!try positive_infinity.isEqual(negative_infinity));
    try testing.expect(!try not_a_number.isEqual(not_a_number));
}

test "value isEqual terminates for equivalent cyclic lists" {
    const allocator = testing.allocator;
    const left = try allocator.create(value.List);
    left.* = value.List.init(allocator);
    const right = try allocator.create(value.List);
    right.* = value.List.init(allocator);
    try left.append(.{ .list = left });
    try right.append(.{ .list = right });

    try testing.expect(try (value.Value{ .list = left }).isEqual(.{ .list = right }));

    left.items.items[0] = .{ .null = {} };
    right.items.items[0] = .{ .null = {} };
    left.deinit(allocator);
    right.deinit(allocator);
}

test "value isEqual null values" {
    const null_val1 = value.Value{ .null = {} };
    const null_val2 = value.Value{ .null = {} };
    try testing.expect(try null_val1.isEqual(null_val2) == true);
}

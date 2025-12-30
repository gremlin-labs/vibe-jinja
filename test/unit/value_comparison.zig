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

test "value isEqual null values" {
    const null_val1 = value.Value{ .null = {} };
    const null_val2 = value.Value{ .null = {} };
    try testing.expect(try null_val1.isEqual(null_val2) == true);
}

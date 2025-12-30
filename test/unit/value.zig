const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const value = vibe_jinja.value;

test "value toString for string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer val.deinit(allocator);

    const str = try val.toString(allocator);
    defer allocator.free(str);

    try testing.expectEqualStrings("hello", str);
}

test "value toString for integer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const val = value.Value{ .integer = 42 };
    const str = try val.toString(allocator);
    defer allocator.free(str);

    try testing.expectEqualStrings("42", str);
}

test "value toString for float" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const val = value.Value{ .float = 3.14 };
    const str = try val.toString(allocator);
    defer allocator.free(str);

    try testing.expect(std.mem.indexOf(u8, str, "3") != null);
}

test "value toString for boolean" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const val_true = value.Value{ .boolean = true };
    const str_true = try val_true.toString(allocator);
    defer allocator.free(str_true);
    try testing.expectEqualStrings("true", str_true);

    const val_false = value.Value{ .boolean = false };
    const str_false = try val_false.toString(allocator);
    defer allocator.free(str_false);
    try testing.expectEqualStrings("false", str_false);
}

test "value toInteger" {
    const val_int = value.Value{ .integer = 42 };
    try testing.expect(val_int.toInteger() == 42);

    const val_float = value.Value{ .float = 3.14 };
    try testing.expect(val_float.toInteger() == 3);

    const val_string = value.Value{ .string = "123" };
    try testing.expect(val_string.toInteger() == 123);

    const val_bool = value.Value{ .boolean = true };
    try testing.expect(val_bool.toInteger() == 1);
}

test "value toFloat" {
    const val_float = value.Value{ .float = 3.14 };
    try testing.expect(val_float.toFloat() == 3.14);

    const val_int = value.Value{ .integer = 42 };
    try testing.expect(val_int.toFloat() == 42.0);

    const val_string = value.Value{ .string = "3.14" };
    try testing.expect(val_string.toFloat() == 3.14);
}

test "value toBoolean" {
    const val_true = value.Value{ .boolean = true };
    try testing.expect(try val_true.toBoolean() == true);
    const val_false = value.Value{ .boolean = false };
    try testing.expect(try val_false.toBoolean() == false);
    const val_int1 = value.Value{ .integer = 1 };
    try testing.expect(try val_int1.toBoolean() == true);
    const val_int0 = value.Value{ .integer = 0 };
    try testing.expect(try val_int0.toBoolean() == false);
    const val_str_hello = value.Value{ .string = "hello" };
    try testing.expect(try val_str_hello.toBoolean() == true);
    const val_str_empty = value.Value{ .string = "" };
    try testing.expect(try val_str_empty.toBoolean() == false);
}

test "value isTruthy" {
    const val_true = value.Value{ .boolean = true };
    try testing.expect(try val_true.isTruthy() == true);
    const val_false = value.Value{ .boolean = false };
    try testing.expect(try val_false.isTruthy() == false);
    const val_int1 = value.Value{ .integer = 1 };
    try testing.expect(try val_int1.isTruthy() == true);
    const val_int0 = value.Value{ .integer = 0 };
    try testing.expect(try val_int0.isTruthy() == false);
    const val_str_hello = value.Value{ .string = "hello" };
    try testing.expect(try val_str_hello.isTruthy() == true);
    const val_str_empty = value.Value{ .string = "" };
    try testing.expect(try val_str_empty.isTruthy() == false);
}

test "value length" {
    const val_str = value.Value{ .string = "hello" };
    try testing.expect(val_str.length() == 5);
    const val_empty = value.Value{ .string = "" };
    try testing.expect(val_empty.length() == 0);
    const val_int = value.Value{ .integer = 42 };
    try testing.expect(val_int.length() == 0);
}

// ============================================================================
// Custom Object Tests
// ============================================================================

/// Test struct to demonstrate custom object support
const TestUser = struct {
    name: []const u8,
    age: u32,
    active: bool,
    
    // VTable implementation functions
    fn getFieldImpl(ptr: *anyopaque, field_name: []const u8, allocator: std.mem.Allocator) value.CallError!?value.Value {
        const self: *const TestUser = @ptrCast(@alignCast(ptr));
        
        if (std.mem.eql(u8, field_name, "name")) {
            return value.Value{ .string = try allocator.dupe(u8, self.name) };
        } else if (std.mem.eql(u8, field_name, "age")) {
            return value.Value{ .integer = @intCast(self.age) };
        } else if (std.mem.eql(u8, field_name, "active")) {
            return value.Value{ .boolean = self.active };
        }
        return null;
    }
    
    fn getMethodImpl(ptr: *anyopaque, method_name: []const u8, allocator: std.mem.Allocator) value.CallError!?value.FunctionFn {
        _ = ptr;
        _ = allocator;
        
        if (std.mem.eql(u8, method_name, "greet")) {
            return &greetMethod;
        }
        return null;
    }
    
    fn greetMethod(allocator: std.mem.Allocator, args: []value.Value, ctx: ?*anyopaque, env: ?*anyopaque) value.CallError!value.Value {
        _ = ctx;
        _ = env;
        
        // First arg should be the greeting prefix (or default to "Hello")
        const prefix = if (args.len > 0 and args[0] == .string)
            args[0].string
        else
            "Hello";
        
        const result = try std.fmt.allocPrint(allocator, "{s}!", .{prefix});
        return value.Value{ .string = result };
    }
    
    fn toStringImpl(ptr: *anyopaque, allocator: std.mem.Allocator) value.CallError!?[]const u8 {
        const self: *const TestUser = @ptrCast(@alignCast(ptr));
        return try std.fmt.allocPrint(allocator, "User({s}, {d})", .{ self.name, self.age });
    }
    
    fn toBoolImpl(ptr: *anyopaque) ?bool {
        const self: *const TestUser = @ptrCast(@alignCast(ptr));
        return self.active;
    }
    
    fn getLengthImpl(ptr: *anyopaque) ?usize {
        const self: *const TestUser = @ptrCast(@alignCast(ptr));
        return self.name.len;
    }
    
    // VTable for TestUser
    pub const vtable = value.CustomVTable{
        .getField = &getFieldImpl,
        .getMethod = &getMethodImpl,
        .getItem = null,
        .getLength = &getLengthImpl,
        .getIterator = null,
        .toString = &toStringImpl,
        .toBool = &toBoolImpl,
        .deinit = null,
        .type_name = "TestUser",
    };
};

test "custom object - basic creation and type check" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var user = TestUser{ .name = "Alice", .age = 30, .active = true };
    const custom = try value.CustomObject.init(allocator, @ptrCast(&user), &TestUser.vtable, false);
    
    var val = value.Value{ .custom = custom };
    defer val.deinit(allocator);
    
    try testing.expect(val.isCustom());
    try testing.expect(val.getCustom() != null);
    try testing.expect(val.getCustom().? == custom);
}

test "custom object - field access" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var user = TestUser{ .name = "Bob", .age = 25, .active = false };
    const custom = try value.CustomObject.init(allocator, @ptrCast(&user), &TestUser.vtable, false);
    
    var val = value.Value{ .custom = custom };
    defer val.deinit(allocator);
    
    // Test field access through CustomObject
    const name_result = try custom.getField("name", allocator);
    try testing.expect(name_result != null);
    var name_val = name_result.?;
    defer name_val.deinit(allocator);
    try testing.expect(name_val == .string);
    try testing.expectEqualStrings("Bob", name_val.string);
    
    const age_result = try custom.getField("age", allocator);
    try testing.expect(age_result != null);
    const age_val = age_result.?;
    try testing.expect(age_val == .integer);
    try testing.expect(age_val.integer == 25);
    
    const active_result = try custom.getField("active", allocator);
    try testing.expect(active_result != null);
    const active_val = active_result.?;
    try testing.expect(active_val == .boolean);
    try testing.expect(active_val.boolean == false);
    
    // Test non-existent field
    const unknown_result = try custom.getField("unknown", allocator);
    try testing.expect(unknown_result == null);
}

test "custom object - method access" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var user = TestUser{ .name = "Charlie", .age = 35, .active = true };
    const custom = try value.CustomObject.init(allocator, @ptrCast(&user), &TestUser.vtable, false);
    
    var val = value.Value{ .custom = custom };
    defer val.deinit(allocator);
    
    // Test method access
    const greet_result = try custom.getMethod("greet", allocator);
    try testing.expect(greet_result != null);
    
    // Call the method
    var args = [_]value.Value{value.Value{ .string = "Hi there" }};
    const method_result = try greet_result.?(allocator, &args, null, null);
    defer {
        var result_copy = method_result;
        result_copy.deinit(allocator);
    }
    try testing.expect(method_result == .string);
    try testing.expectEqualStrings("Hi there!", method_result.string);
    
    // Test non-existent method
    const unknown_method = try custom.getMethod("unknown", allocator);
    try testing.expect(unknown_method == null);
}

test "custom object - toString" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var user = TestUser{ .name = "Diana", .age = 40, .active = true };
    const custom = try value.CustomObject.init(allocator, @ptrCast(&user), &TestUser.vtable, false);
    
    var val = value.Value{ .custom = custom };
    defer val.deinit(allocator);
    
    const str = try val.toString(allocator);
    defer allocator.free(str);
    
    try testing.expectEqualStrings("User(Diana, 40)", str);
}

test "custom object - toBoolean" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Active user should be truthy
    var active_user = TestUser{ .name = "Active", .age = 20, .active = true };
    const active_custom = try value.CustomObject.init(allocator, @ptrCast(&active_user), &TestUser.vtable, false);
    var active_val = value.Value{ .custom = active_custom };
    defer active_val.deinit(allocator);
    try testing.expect(try active_val.toBoolean() == true);
    
    // Inactive user should be falsy
    var inactive_user = TestUser{ .name = "Inactive", .age = 20, .active = false };
    const inactive_custom = try value.CustomObject.init(allocator, @ptrCast(&inactive_user), &TestUser.vtable, false);
    var inactive_val = value.Value{ .custom = inactive_custom };
    defer inactive_val.deinit(allocator);
    try testing.expect(try inactive_val.toBoolean() == false);
}

test "custom object - length" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var user = TestUser{ .name = "Edward", .age = 45, .active = true };
    const custom = try value.CustomObject.init(allocator, @ptrCast(&user), &TestUser.vtable, false);
    
    const val = value.Value{ .custom = custom };
    defer {
        var v = val;
        v.deinit(allocator);
    }
    
    // Length should return name length based on our implementation
    try testing.expect(val.length() == 6); // "Edward".len
}

test "custom object - equality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var user1 = TestUser{ .name = "Frank", .age = 50, .active = true };
    const custom1 = try value.CustomObject.init(allocator, @ptrCast(&user1), &TestUser.vtable, false);
    var val1 = value.Value{ .custom = custom1 };
    defer val1.deinit(allocator);
    
    // Same object pointer and vtable should be equal
    const custom2 = try value.CustomObject.init(allocator, @ptrCast(&user1), &TestUser.vtable, false);
    var val2 = value.Value{ .custom = custom2 };
    defer val2.deinit(allocator);
    
    try testing.expect(try val1.isEqual(val2));
    
    // Different object pointer should not be equal
    var user2 = TestUser{ .name = "Frank", .age = 50, .active = true };
    const custom3 = try value.CustomObject.init(allocator, @ptrCast(&user2), &TestUser.vtable, false);
    var val3 = value.Value{ .custom = custom3 };
    defer val3.deinit(allocator);
    
    try testing.expect(!(try val1.isEqual(val3)));
}

test "custom object - deepCopy" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var user = TestUser{ .name = "Grace", .age = 55, .active = true };
    const custom = try value.CustomObject.init(allocator, @ptrCast(&user), &TestUser.vtable, false);
    
    var val = value.Value{ .custom = custom };
    defer val.deinit(allocator);
    
    // Deep copy should create a new CustomObject that doesn't own the data
    var copy = try val.deepCopy(allocator);
    defer copy.deinit(allocator);
    
    try testing.expect(copy.isCustom());
    try testing.expect(copy.getCustom().?.ptr == custom.ptr);
    try testing.expect(copy.getCustom().?.vtable == custom.vtable);
    try testing.expect(copy.getCustom().?.owns_data == false);
}

test "custom object - typeName" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var user = TestUser{ .name = "Helen", .age = 60, .active = true };
    const custom = try value.CustomObject.init(allocator, @ptrCast(&user), &TestUser.vtable, false);
    
    var val = value.Value{ .custom = custom };
    defer val.deinit(allocator);
    
    try testing.expectEqualStrings("TestUser", custom.typeName());
}

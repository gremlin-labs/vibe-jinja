const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const utils = vibe_jinja.utils;
const value = vibe_jinja.value;

test "Cycler" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const values = [_]value.Value{
        value.Value{ .string = try allocator.dupe(u8, "red") },
        value.Value{ .string = try allocator.dupe(u8, "green") },
        value.Value{ .string = try allocator.dupe(u8, "blue") },
    };
    defer {
        for (values) |val| {
            var mutable_val = val;
            mutable_val.deinit(allocator);
        }
    }

    var cycler = try utils.Cycler.init(allocator, &values);
    defer cycler.deinit();

    var val1 = cycler.next();
    defer val1.deinit(allocator);
    try testing.expectEqualStrings("red", val1.string);

    var val2 = cycler.next();
    defer val2.deinit(allocator);
    try testing.expectEqualStrings("green", val2.string);

    var val3 = cycler.next();
    defer val3.deinit(allocator);
    try testing.expectEqualStrings("blue", val3.string);

    // Should cycle back
    var val4 = cycler.next();
    defer val4.deinit(allocator);
    try testing.expectEqualStrings("red", val4.string);
}

test "Cycler reset" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const values = [_]value.Value{
        value.Value{ .integer = 1 },
        value.Value{ .integer = 2 },
    };

    var cycler = try utils.Cycler.init(allocator, &values);
    defer cycler.deinit();

    _ = cycler.next();
    _ = cycler.next();
    
    cycler.reset();
    
    var val = cycler.next();
    defer val.deinit(allocator);
    try testing.expectEqual(@as(i64, 1), val.integer);
}

test "Joiner" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var joiner = try utils.Joiner.init(allocator, ", ");
    defer joiner.deinit();

    var values = [_]value.Value{
        value.Value{ .string = try allocator.dupe(u8, "a") },
        value.Value{ .string = try allocator.dupe(u8, "b") },
        value.Value{ .string = try allocator.dupe(u8, "c") },
    };
    defer {
        for (0..values.len) |i| {
            values[i].deinit(allocator);
        }
    }

    const result = try joiner.join(&values);
    defer allocator.free(result);

    try testing.expectEqualStrings("a, b, c", result);
}

test "Joiner empty" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var joiner = try utils.Joiner.init(allocator, ", ");
    defer joiner.deinit();

    const result = try joiner.join(&.{});
    defer allocator.free(result);

    try testing.expectEqualStrings("", result);
}

test "Namespace" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ns = utils.Namespace.init(allocator);
    defer ns.deinit();

    try ns.set("x", value.Value{ .integer = 42 });
    const y_val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    try ns.set("y", y_val);
    // Note: Don't manually deinit y_val - the namespace owns it and will deinit it

    const x_val = ns.get("x").?;
    try testing.expectEqual(@as(i64, 42), x_val.integer);

    const y_val_result = ns.get("y").?;
    try testing.expectEqualStrings("hello", y_val_result.string);

    try testing.expect(ns.get("z") == null);
}

test "Namespace toDict" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ns = utils.Namespace.init(allocator);
    defer ns.deinit();

    try ns.set("x", value.Value{ .integer = 42 });
    try ns.set("y", value.Value{ .string = try allocator.dupe(u8, "hello") });

    var dict_val = try ns.toDict();
    defer dict_val.deinit(allocator);

    try testing.expect(dict_val == .dict);
    
    const x_str = try allocator.dupe(u8, "x");
    defer allocator.free(x_str);
    const x_val = dict_val.dict.get(x_str).?;
    try testing.expectEqual(@as(i64, 42), x_val.integer);
}

test "generateLoremIpsum" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = try utils.generateLoremIpsum(allocator, 5);
    defer allocator.free(text);

    try testing.expect(text.len > 0);
    // Should contain some lorem words
    try testing.expect(std.mem.indexOf(u8, text, "lorem") != null or std.mem.indexOf(u8, text, "ipsum") != null);
}

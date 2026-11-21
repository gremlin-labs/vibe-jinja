const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const utils = vibe_jinja.utils;
const value = vibe_jinja.value;

test "Cycler" {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var joiner = try utils.Joiner.init(allocator, ", ");
    defer joiner.deinit();

    const result = try joiner.join(&.{});
    defer allocator.free(result);

    try testing.expectEqualStrings("", result);
}

test "Namespace" {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text = try utils.generateLoremIpsum(allocator, 5);
    defer allocator.free(text);

    try testing.expect(text.len > 0);
    // Should contain some lorem words
    try testing.expect(std.mem.find(u8, text, "lorem") != null or std.mem.find(u8, text, "ipsum") != null);
}

test "strftimeNow formats the current year with a caller-supplied io" {
    var args = [_]value.Value{.{ .string = "%Y" }};
    const result = try utils.strftimeNow(testing.allocator, std.testing.io, &args);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), result.string.len);
    const year = try std.fmt.parseInt(u32, result.string, 10);
    try testing.expect(year >= 2026);
}

test "strftime_now global callback requires the rendering environment" {
    var args = [_]value.Value{.{ .string = "%Y" }};
    try testing.expectError(error.InvalidArgument, vibe_jinja.strftimeNowGlobal(testing.allocator, &args, null, null));

    var env = vibe_jinja.Environment.init(testing.allocator, std.testing.io);
    defer env.deinit();
    const result = try vibe_jinja.strftimeNowGlobal(testing.allocator, &args, null, @ptrCast(&env));
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), result.string.len);
}

fn writePaddedTemplate(dir: std.Io.Dir, name: []const u8, size: usize) !void {
    // "{#" + padding + "#}ok" renders as "ok".
    const buffer = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(buffer);
    @memset(buffer, 'x');
    @memcpy(buffer[0..2], "{#");
    @memcpy(buffer[size - 4 ..], "#}ok");
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = buffer });
}

test "eval_file accepts templates up to and including the size limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const limit = vibe_jinja.defaults.MAX_TEMPLATE_SIZE_BYTES;

    inline for (.{ .{ "below", limit - 1 }, .{ "at", limit }, .{ "above", limit + 1 } }) |case| {
        try writePaddedTemplate(tmp.dir, case[0], case[1]);
        const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, case[0] });
        defer testing.allocator.free(path);

        if (case[1] <= limit) {
            const output = try vibe_jinja.eval_file(testing.allocator, std.testing.io, path);
            defer testing.allocator.free(output);
            try testing.expectEqualStrings("ok", output);
        } else {
            try testing.expectError(error.StreamTooLong, vibe_jinja.eval_file(testing.allocator, std.testing.io, path));
        }
    }
}

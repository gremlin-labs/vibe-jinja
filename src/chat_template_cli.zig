const std = @import("std");
const jinja = @import("vibe_jinja");

const max_input_bytes = 16 * 1024 * 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.fs.File.stdin().readToEndAlloc(allocator, max_input_bytes);
    defer allocator.free(input);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidInput,
    };

    const template = switch (root.get("template") orelse return error.MissingTemplate) {
        .string => |value| value,
        else => return error.InvalidTemplate,
    };

    var vars = std.StringHashMap(jinja.Value).init(allocator);
    defer deinitVars(allocator, &vars);

    var iter = root.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "template")) continue;
        const value = try jsonToJinjaValue(allocator, entry.value_ptr.*);
        errdefer value.deinit(allocator);
        try vars.put(entry.key_ptr.*, value);
    }

    var env = jinja.Environment.init(allocator);
    defer env.deinit();

    var runtime = jinja.runtime.Runtime.init(&env, allocator);
    defer runtime.deinit();

    const output = try runtime.renderString(template, vars, "chat_template");
    defer allocator.free(output);

    try std.fs.File.stdout().writeAll(output);
}

fn deinitVars(allocator: std.mem.Allocator, vars: *std.StringHashMap(jinja.Value)) void {
    var iter = vars.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    vars.deinit();
}

fn jsonToJinjaValue(allocator: std.mem.Allocator, input: std.json.Value) !jinja.Value {
    return switch (input) {
        .null => jinja.Value{ .null = {} },
        .bool => |value| jinja.Value{ .boolean = value },
        .integer => |value| jinja.Value{ .integer = value },
        .float => |value| jinja.Value{ .float = value },
        .number_string => |value| jinja.Value{ .string = try allocator.dupe(u8, value) },
        .string => |value| jinja.Value{ .string = try allocator.dupe(u8, value) },
        .array => |array| blk: {
            const list = try allocator.create(jinja.value.List);
            list.* = jinja.value.List.init(allocator);
            errdefer list.deinit(allocator);

            for (array.items) |item| {
                const value = try jsonToJinjaValue(allocator, item);
                errdefer value.deinit(allocator);
                try list.append(value);
            }

            break :blk jinja.Value{ .list = list };
        },
        .object => |object| blk: {
            const dict = try allocator.create(jinja.value.Dict);
            dict.* = jinja.value.Dict.init(allocator);
            errdefer dict.deinit(allocator);

            var iter = object.iterator();
            while (iter.next()) |entry| {
                const value = try jsonToJinjaValue(allocator, entry.value_ptr.*);
                errdefer value.deinit(allocator);
                try dict.set(entry.key_ptr.*, value);
            }

            break :blk jinja.Value{ .dict = dict };
        },
    };
}

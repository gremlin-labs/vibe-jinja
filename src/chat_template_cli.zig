const std = @import("std");
const jinja = @import("vibe_jinja");

const max_input_bytes = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const input = try stdin_reader.interface.allocRemaining(allocator, .limited(max_input_bytes));
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
        const value = try jinja.json_value.toValue(allocator, entry.value_ptr.*);
        errdefer value.deinit(allocator);
        try vars.put(entry.key_ptr.*, value);
    }

    var env = jinja.Environment.init(allocator);
    defer env.deinit();

    var runtime = jinja.runtime.Runtime.init(&env, allocator);
    defer runtime.deinit();

    const output = try runtime.renderString(template, vars, "chat_template");
    defer allocator.free(output);

    try std.Io.File.stdout().writeStreamingAll(io, output);
}

fn deinitVars(allocator: std.mem.Allocator, vars: *std.StringHashMap(jinja.Value)) void {
    var iter = vars.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    vars.deinit();
}

const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const runtime = vibe_jinja.runtime;
const environment = vibe_jinja.environment;
const context = vibe_jinja.context;
const value = vibe_jinja.value;

test "runtime context initialization and local resolution" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var env = environment.Environment.init(allocator);
    defer env.deinit();
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var original = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer original.deinit(allocator);
    try vars.put("test", original);

    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();
    const resolved = ctx.resolve("test");

    try testing.expect(ctx.environment == &env);
    try testing.expectEqualStrings("test", ctx.name.?);
    try testing.expect(resolved == .string);
    try testing.expectEqualStrings("hello", resolved.string);
}

test "runtime context set, get, default, and multiple variables" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var env = environment.Environment.init(allocator);
    defer env.deinit();
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    try ctx.set("a", .{ .integer = 1 });
    try ctx.set("b", .{ .integer = 2 });
    try ctx.set("c", .{ .integer = 3 });

    try testing.expectEqual(@as(i64, 1), ctx.resolve("a").integer);
    try testing.expectEqual(@as(i64, 2), ctx.resolve("b").integer);
    try testing.expectEqual(@as(i64, 3), ctx.get("c", null).integer);
    try testing.expectEqual(@as(i64, 9), ctx.get("missing", .{ .integer = 9 }).integer);
}

test "runtime context parent resolution and shadowing" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var env = environment.Environment.init(allocator);
    defer env.deinit();
    var parent_vars = std.StringHashMap(value.Value).init(allocator);
    defer parent_vars.deinit();
    var original = value.Value{ .string = try allocator.dupe(u8, "parent") };
    defer original.deinit(allocator);
    try parent_vars.put("x", original);
    var parent = try context.Context.init(&env, parent_vars, "parent", allocator);
    defer parent.deinit();
    var child_vars = std.StringHashMap(value.Value).init(allocator);
    defer child_vars.deinit();
    var child = try context.Context.initWithParent(&env, child_vars, "child", &parent, allocator);
    defer child.deinit();

    try testing.expectEqualStrings("parent", child.resolve("x").string);
    try child.set("x", .{ .string = try allocator.dupe(u8, "child") });
    try testing.expectEqualStrings("child", child.resolve("x").string);
    try testing.expectEqualStrings("parent", parent.resolve("x").string);
}

test "runtime undefined behavior and environment globals" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var env = environment.Environment.init(allocator);
    defer env.deinit();
    env.undefined_behavior = .debug;
    try env.addGlobal("global_var", .{ .integer = 42 });
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    const missing = ctx.resolve("missing_var");
    try testing.expect(missing == .undefined);
    try testing.expectEqual(value.UndefinedBehavior.debug, missing.undefined.behavior);
    try testing.expectEqual(@as(i64, 42), ctx.resolve("global_var").integer);
}

test "runtime template reference initialization" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var env = environment.Environment.init(allocator);
    defer env.deinit();
    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();
    var compiler_instance = vibe_jinja.compiler.Compiler.init(&env, "test", allocator);
    defer compiler_instance.deinit();
    var template = vibe_jinja.nodes.Template.init(allocator, 1, "test.jinja");
    template.name = try allocator.dupe(u8, "test_template");
    defer template.deinit(allocator);

    var template_ref = runtime.TemplateReference.init(allocator, &template, &ctx, &compiler_instance);
    defer template_ref.deinit();
    try testing.expect(template_ref.ctx == &ctx);
    try testing.expect(template_ref.template == &template);
    try testing.expectEqualStrings("test_template", template_ref.name.?);
}

test "runtime list allocation lifecycle" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(.{ .integer = 10 });
    try list.append(.{ .integer = 20 });
    try list.append(.{ .integer = 30 });
    try testing.expectEqual(@as(usize, 3), list.items.items.len);
}

test "runtime resolves through a deep context chain without stack recursion" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const depth = 4096;
    const contexts = try allocator.alloc(context.Context, depth);
    var initialized: usize = 0;
    defer {
        var index = initialized;
        while (index > 0) {
            index -= 1;
            contexts[index].deinit();
        }
        allocator.free(contexts);
    }

    var root_vars = std.StringHashMap(value.Value).init(allocator);
    try root_vars.put("root_value", .{ .integer = 42 });
    contexts[0] = try context.Context.init(&env, root_vars, "root", allocator);
    root_vars.deinit();
    initialized = 1;

    while (initialized < depth) : (initialized += 1) {
        var empty = std.StringHashMap(value.Value).init(allocator);
        defer empty.deinit();
        contexts[initialized] = try context.Context.initWithParent(
            &env,
            empty,
            "derived",
            &contexts[initialized - 1],
            allocator,
        );
    }

    try testing.expectEqual(@as(i64, 42), contexts[depth - 1].resolve("root_value").integer);
    try testing.expect(contexts[depth - 1].resolve("missing") == .undefined);
}

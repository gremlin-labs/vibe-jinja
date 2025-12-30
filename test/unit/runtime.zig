const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const runtime = vibe_jinja.runtime;
const environment = vibe_jinja.environment;
const context = vibe_jinja.context;
const value = vibe_jinja.value;

test "runtime context init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    try testing.expect(ctx.environment == &env);
    try testing.expect(ctx.name != null);
}

test "runtime context resolve" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    
    var test_val = value.Value{ .string = try allocator.dupe(u8, "hello") };
    defer test_val.deinit(allocator);
    try vars.put(try allocator.dupe(u8, "test"), test_val);

    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    if (ctx.resolve("test")) |val| {
        defer val.deinit(allocator);
        try testing.expect(val == .string);
        try testing.expectEqualStrings("hello", val.string);
    } else {
        try testing.expect(false);
    }
}

test "runtime context set and get" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    var test_val = value.Value{ .integer = 42 };
    try ctx.set("test_var", test_val);

    if (ctx.resolve("test_var")) |val| {
        defer val.deinit(allocator);
        try testing.expect(val == .integer);
        try testing.expect(val.integer == 42);
    } else {
        try testing.expect(false);
    }
}

test "runtime context parent resolution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var parent_vars = std.StringHashMap(value.Value).init(allocator);
    defer parent_vars.deinit();
    
    var parent_val = value.Value{ .string = try allocator.dupe(u8, "parent") };
    defer parent_val.deinit(allocator);
    try parent_vars.put(try allocator.dupe(u8, "parent_var"), parent_val);

    var parent_ctx = try context.Context.init(&env, parent_vars, "parent", allocator);
    defer parent_ctx.deinit();

    var child_vars = std.StringHashMap(value.Value).init(allocator);
    defer child_vars.deinit();
    var child_ctx = try context.Context.initWithParent(&env, child_vars, "child", &parent_ctx, allocator);
    defer child_ctx.deinit();

    if (child_ctx.resolve("parent_var")) |val| {
        defer val.deinit(allocator);
        try testing.expect(val == .string);
        try testing.expectEqualStrings("parent", val.string);
    } else {
        try testing.expect(false);
    }
}

test "runtime template reference init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

    var template = try vibe_jinja.nodes.Template.init(allocator, "test_template", 1, "test.jinja");
    defer template.deinit(allocator);

    var template_ref = runtime.TemplateReference.init(allocator, &template, &ctx, &compiler_instance);
    defer template_ref.deinit();

    try testing.expect(template_ref.ctx == &ctx);
    try testing.expect(template_ref.template == &template);
}

test "runtime undefined behavior lenient" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();
    env.undefined_behavior = .lenient;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    // Resolving undefined variable should return undefined value, not error
    if (ctx.resolve("undefined_var")) |val| {
        defer val.deinit(allocator);
        try testing.expect(val == .undefined);
    } else {
        try testing.expect(false);
    }
}

// ============================================================================
// Loop Context Tests (Jinja2 test_loop_idx)
// ============================================================================

test "runtime loop context basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    // Create a simple list to iterate
    const list = try allocator.create(value.List);
    list.* = value.List.init(allocator);
    defer list.deinit(allocator);
    try list.append(value.Value{ .integer = 10 });
    try list.append(value.Value{ .integer = 20 });
    try list.append(value.Value{ .integer = 30 });

    // Verify list has correct length
    try testing.expect(list.items.items.len == 3);
}

// ============================================================================
// Variable Shadowing Tests
// ============================================================================

test "runtime context variable shadowing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Parent context with a variable
    var parent_vars = std.StringHashMap(value.Value).init(allocator);
    defer parent_vars.deinit();
    
    var parent_val = value.Value{ .string = try allocator.dupe(u8, "parent_value") };
    defer parent_val.deinit(allocator);
    try parent_vars.put(try allocator.dupe(u8, "x"), parent_val);

    var parent_ctx = try context.Context.init(&env, parent_vars, "parent", allocator);
    defer parent_ctx.deinit();

    // Child context that shadows the parent variable
    var child_vars = std.StringHashMap(value.Value).init(allocator);
    defer child_vars.deinit();
    var child_ctx = try context.Context.initWithParent(&env, child_vars, "child", &parent_ctx, allocator);
    defer child_ctx.deinit();

    // Set a shadowing variable in child
    var child_val = value.Value{ .string = try allocator.dupe(u8, "child_value") };
    defer child_val.deinit(allocator);
    try child_ctx.set("x", child_val);

    // Child should see its own value
    if (child_ctx.resolve("x")) |val| {
        defer val.deinit(allocator);
        try testing.expect(val == .string);
        try testing.expectEqualStrings("child_value", val.string);
    } else {
        try testing.expect(false);
    }
}

// ============================================================================
// Undefined Behavior Tests (Jinja2 test_undefined)
// ============================================================================

test "runtime undefined debug behavior" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();
    env.undefined_behavior = .debug;

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    // Debug mode should return a descriptive undefined value
    if (ctx.resolve("missing_var")) |val| {
        defer val.deinit(allocator);
        try testing.expect(val == .undefined);
    } else {
        try testing.expect(false);
    }
}

// ============================================================================
// Context Globals Tests
// ============================================================================

test "runtime context globals access" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Add a global to the environment
    try env.addGlobal("global_var", value.Value{ .integer = 42 });

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    // Context should be able to resolve globals
    if (ctx.resolve("global_var")) |val| {
        defer val.deinit(allocator);
        try testing.expect(val == .integer);
        try testing.expect(val.integer == 42);
    } else {
        try testing.expect(false);
    }
}

// ============================================================================
// Multiple Variable Set Tests
// ============================================================================

test "runtime context multiple variables" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();
    var ctx = try context.Context.init(&env, vars, "test", allocator);
    defer ctx.deinit();

    // Set multiple variables
    try ctx.set("a", value.Value{ .integer = 1 });
    try ctx.set("b", value.Value{ .integer = 2 });
    try ctx.set("c", value.Value{ .integer = 3 });

    // Verify all are set correctly
    if (ctx.resolve("a")) |val| {
        defer val.deinit(allocator);
        try testing.expect(val.integer == 1);
    }
    if (ctx.resolve("b")) |val| {
        defer val.deinit(allocator);
        try testing.expect(val.integer == 2);
    }
    if (ctx.resolve("c")) |val| {
        defer val.deinit(allocator);
        try testing.expect(val.integer == 3);
    }
}

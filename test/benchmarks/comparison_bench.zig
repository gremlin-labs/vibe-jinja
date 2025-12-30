const std = @import("std");
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const context = vibe_jinja.context;
const value_mod = vibe_jinja.value;

/// Fair comparison benchmark - matches Python Jinja2 benchmark methodology exactly
/// Python pre-compiles template, then times only render() calls with pre-built context dict
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     vibe-jinja vs Python Jinja2 - Fair Comparison                 ║\n", .{});
    std.debug.print("║     (Pre-compiled templates, render-only timing)                  ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // === Simple Template ===
    {
        std.debug.print("Simple Template: Hello {{{{ name }}}}!\n", .{});
        var env = environment.Environment.init(allocator);
        defer env.deinit();

        const template = try env.fromString("Hello {{ name }}!", "simple");
        var compiled = try vibe_jinja.compiler.compile(&env, template, "simple", allocator);
        defer compiled.deinit();

        // Pre-build context (not timed - same as Python)
        var vars = std.StringHashMap(context.Value).init(allocator);
        defer vars.deinit();
        const name_str = try allocator.dupe(u8, "World");
        defer allocator.free(name_str);
        try vars.put("name", context.Value{ .string = name_str });

        var ctx = try context.Context.init(&env, vars, "simple", allocator);
        defer ctx.deinit();

        // Warmup
        for (0..10) |_| {
            const result = try compiled.render(&ctx, allocator);
            allocator.free(result);
        }

        // Timed iterations - ONLY render, context already built
        const iterations: usize = 1000;
        var total_ns: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var max_ns: u64 = 0;

        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const result = try compiled.render(&ctx, allocator);
            const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
            allocator.free(result);

            total_ns += elapsed;
            if (elapsed < min_ns) min_ns = elapsed;
            if (elapsed > max_ns) max_ns = elapsed;
        }

        const avg_ns = total_ns / iterations;
        const ops_per_sec = if (avg_ns > 0) 1_000_000_000 / avg_ns else 0;
        std.debug.print("  Zig:    Avg: {d}ns | Min: {d}ns | Max: {d}ns | {d} ops/sec\n", .{ avg_ns, min_ns, max_ns, ops_per_sec });
        std.debug.print("  Python: Avg: 3427ns | Min: 2917ns | Max: 42583ns | 291773 ops/sec\n", .{});
        if (avg_ns > 0) {
            const speedup = @as(f64, 3427.0) / @as(f64, @floatFromInt(avg_ns));
            std.debug.print("  Speedup: {d:.2}x\n", .{speedup});
        }
        std.debug.print("\n", .{});
    }

    // === Loop Template ===
    {
        std.debug.print("Loop Template: {{%% for item in items %}}{{{{ item }}}}{{%% endfor %}}\n", .{});
        var env = environment.Environment.init(allocator);
        defer env.deinit();

        const template = try env.fromString("{% for item in items %}{{ item }}{% endfor %}", "loop");
        var compiled = try vibe_jinja.compiler.compile(&env, template, "loop", allocator);
        defer compiled.deinit();

        // Pre-build context with list
        var vars = std.StringHashMap(context.Value).init(allocator);
        defer vars.deinit();

        const list_ptr = try allocator.create(value_mod.List);
        list_ptr.* = value_mod.List.init(allocator);
        defer list_ptr.deinit(allocator);

        for (0..10) |i| {
            try list_ptr.append(context.Value{ .integer = @intCast(i) });
        }
        try vars.put("items", context.Value{ .list = list_ptr });

        var ctx = try context.Context.init(&env, vars, "loop", allocator);
        defer ctx.deinit();

        // Warmup
        for (0..10) |_| {
            const result = try compiled.render(&ctx, allocator);
            allocator.free(result);
        }

        // Timed iterations
        const iterations: usize = 100;
        var total_ns: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var max_ns: u64 = 0;

        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const result = try compiled.render(&ctx, allocator);
            const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
            allocator.free(result);

            total_ns += elapsed;
            if (elapsed < min_ns) min_ns = elapsed;
            if (elapsed > max_ns) max_ns = elapsed;
        }

        const avg_ns = total_ns / iterations;
        const ops_per_sec = if (avg_ns > 0) 1_000_000_000 / avg_ns else 0;
        std.debug.print("  Zig:    Avg: {d}ns | Min: {d}ns | Max: {d}ns | {d} ops/sec\n", .{ avg_ns, min_ns, max_ns, ops_per_sec });
        std.debug.print("  Python: Avg: 3800ns | Min: 3666ns | Max: 4083ns | 263132 ops/sec\n", .{});
        if (avg_ns > 0) {
            const speedup = @as(f64, 3800.0) / @as(f64, @floatFromInt(avg_ns));
            std.debug.print("  Speedup: {d:.2}x\n", .{speedup});
        }
        std.debug.print("\n", .{});
    }

    // === Conditional Template ===
    {
        std.debug.print("Conditional: {{%% if condition %}}True{{%% else %}}False{{%% endif %}}\n", .{});
        var env = environment.Environment.init(allocator);
        defer env.deinit();

        const template = try env.fromString("{% if condition %}True{% else %}False{% endif %}", "cond");
        var compiled = try vibe_jinja.compiler.compile(&env, template, "cond", allocator);
        defer compiled.deinit();

        var vars = std.StringHashMap(context.Value).init(allocator);
        defer vars.deinit();
        try vars.put("condition", context.Value{ .boolean = true });

        var ctx = try context.Context.init(&env, vars, "cond", allocator);
        defer ctx.deinit();

        // Warmup
        for (0..10) |_| {
            const result = try compiled.render(&ctx, allocator);
            allocator.free(result);
        }

        const iterations: usize = 1000;
        var total_ns: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var max_ns: u64 = 0;

        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const result = try compiled.render(&ctx, allocator);
            const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
            allocator.free(result);

            total_ns += elapsed;
            if (elapsed < min_ns) min_ns = elapsed;
            if (elapsed > max_ns) max_ns = elapsed;
        }

        const avg_ns = total_ns / iterations;
        const ops_per_sec = if (avg_ns > 0) 1_000_000_000 / avg_ns else 0;
        std.debug.print("  Zig:    Avg: {d}ns | Min: {d}ns | Max: {d}ns | {d} ops/sec\n", .{ avg_ns, min_ns, max_ns, ops_per_sec });
        std.debug.print("  Python: Avg: 3211ns | Min: 3000ns | Max: 11375ns | 311420 ops/sec\n", .{});
        if (avg_ns > 0) {
            const speedup = @as(f64, 3211.0) / @as(f64, @floatFromInt(avg_ns));
            std.debug.print("  Speedup: {d:.2}x\n", .{speedup});
        }
        std.debug.print("\n", .{});
    }

    // === Filter Chain ===
    {
        std.debug.print("Filter Chain: {{{{ text|upper|lower|trim|length }}}}\n", .{});
        var env = environment.Environment.init(allocator);
        defer env.deinit();

        const template = try env.fromString("{{ text|upper|lower|trim|length }}", "filter");
        var compiled = try vibe_jinja.compiler.compile(&env, template, "filter", allocator);
        defer compiled.deinit();

        var vars = std.StringHashMap(context.Value).init(allocator);
        defer vars.deinit();
        const text_str = try allocator.dupe(u8, "  Hello World  ");
        defer allocator.free(text_str);
        try vars.put("text", context.Value{ .string = text_str });

        var ctx = try context.Context.init(&env, vars, "filter", allocator);
        defer ctx.deinit();

        // Warmup
        for (0..10) |_| {
            const result = try compiled.render(&ctx, allocator);
            allocator.free(result);
        }

        const iterations: usize = 500;
        var total_ns: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var max_ns: u64 = 0;

        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const result = try compiled.render(&ctx, allocator);
            const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
            allocator.free(result);

            total_ns += elapsed;
            if (elapsed < min_ns) min_ns = elapsed;
            if (elapsed > max_ns) max_ns = elapsed;
        }

        const avg_ns = total_ns / iterations;
        const ops_per_sec = if (avg_ns > 0) 1_000_000_000 / avg_ns else 0;
        std.debug.print("  Zig:    Avg: {d}ns | Min: {d}ns | Max: {d}ns | {d} ops/sec\n", .{ avg_ns, min_ns, max_ns, ops_per_sec });
        std.debug.print("  Python: Avg: 3771ns | Min: 3458ns | Max: 6792ns | 265160 ops/sec\n", .{});
        if (avg_ns > 0) {
            const speedup = @as(f64, 3771.0) / @as(f64, @floatFromInt(avg_ns));
            std.debug.print("  Speedup: {d:.2}x\n", .{speedup});
        }
        std.debug.print("\n", .{});
    }

    // Run filter fast path benchmarks
    try benchmarkFilterFastPaths(allocator);

    std.debug.print("═══════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Note: Python times from benchmark_python.py on same machine\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════════\n", .{});
}

// === Additional Filter Benchmarks ===
fn benchmarkFilterFastPaths(allocator: std.mem.Allocator) !void {
    std.debug.print("\n─── Filter Fast Path Tests ───\n\n", .{});
    
    var env = environment.Environment.init(allocator);
    defer env.deinit();
    
    // Test 1: escape with no special chars (fast path)
    {
        const template = try env.fromString("{{ text|escape }}", "escape_fast");
        var compiled = try vibe_jinja.compiler.compile(&env, template, "escape_fast", allocator);
        defer compiled.deinit();
        
        var vars = std.StringHashMap(context.Value).init(allocator);
        defer vars.deinit();
        const text_str = try allocator.dupe(u8, "Hello World No Special Chars");
        defer allocator.free(text_str);
        try vars.put("text", context.Value{ .string = text_str });
        
        var ctx = try context.Context.init(&env, vars, "test", allocator);
        defer ctx.deinit();
        
        // Warmup
        for (0..10) |_| {
            const result = try compiled.render(&ctx, allocator);
            allocator.free(result);
        }
        
        const iterations: usize = 1000;
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const result = try compiled.render(&ctx, allocator);
            total_ns += @intCast(std.time.nanoTimestamp() - start);
            allocator.free(result);
        }
        
        std.debug.print("escape (no specials - fast path): {d}ns avg\n", .{total_ns / iterations});
    }
    
    // Test 2: escape with special chars (slow path)
    {
        const template = try env.fromString("{{ text|escape }}", "escape_slow");
        var compiled = try vibe_jinja.compiler.compile(&env, template, "escape_slow", allocator);
        defer compiled.deinit();
        
        var vars = std.StringHashMap(context.Value).init(allocator);
        defer vars.deinit();
        const text_str = try allocator.dupe(u8, "<script>alert('xss');</script>");
        defer allocator.free(text_str);
        try vars.put("text", context.Value{ .string = text_str });
        
        var ctx = try context.Context.init(&env, vars, "test", allocator);
        defer ctx.deinit();
        
        for (0..10) |_| {
            const result = try compiled.render(&ctx, allocator);
            allocator.free(result);
        }
        
        const iterations: usize = 1000;
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const result = try compiled.render(&ctx, allocator);
            total_ns += @intCast(std.time.nanoTimestamp() - start);
            allocator.free(result);
        }
        
        std.debug.print("escape (with specials - slow path): {d}ns avg\n", .{total_ns / iterations});
    }
    
    // Test 3: upper on already uppercase (fast path)
    {
        const template = try env.fromString("{{ text|upper }}", "upper_fast");
        var compiled = try vibe_jinja.compiler.compile(&env, template, "upper_fast", allocator);
        defer compiled.deinit();
        
        var vars = std.StringHashMap(context.Value).init(allocator);
        defer vars.deinit();
        const text_str = try allocator.dupe(u8, "ALREADY UPPERCASE");
        defer allocator.free(text_str);
        try vars.put("text", context.Value{ .string = text_str });
        
        var ctx = try context.Context.init(&env, vars, "test", allocator);
        defer ctx.deinit();
        
        for (0..10) |_| {
            const result = try compiled.render(&ctx, allocator);
            allocator.free(result);
        }
        
        const iterations: usize = 1000;
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const result = try compiled.render(&ctx, allocator);
            total_ns += @intCast(std.time.nanoTimestamp() - start);
            allocator.free(result);
        }
        
        std.debug.print("upper (already upper - fast path): {d}ns avg\n", .{total_ns / iterations});
    }
    
    // Test 4: upper on lowercase (slow path)
    {
        const template = try env.fromString("{{ text|upper }}", "upper_slow");
        var compiled = try vibe_jinja.compiler.compile(&env, template, "upper_slow", allocator);
        defer compiled.deinit();
        
        var vars = std.StringHashMap(context.Value).init(allocator);
        defer vars.deinit();
        const text_str = try allocator.dupe(u8, "needs to be uppercased");
        defer allocator.free(text_str);
        try vars.put("text", context.Value{ .string = text_str });
        
        var ctx = try context.Context.init(&env, vars, "test", allocator);
        defer ctx.deinit();
        
        for (0..10) |_| {
            const result = try compiled.render(&ctx, allocator);
            allocator.free(result);
        }
        
        const iterations: usize = 1000;
        var total_ns: u64 = 0;
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const result = try compiled.render(&ctx, allocator);
            total_ns += @intCast(std.time.nanoTimestamp() - start);
            allocator.free(result);
        }
        
        std.debug.print("upper (needs change - slow path): {d}ns avg\n", .{total_ns / iterations});
    }
}

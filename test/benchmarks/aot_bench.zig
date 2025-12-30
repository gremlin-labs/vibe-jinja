//! AOT vs JIT Benchmark
//! Compares ahead-of-time compiled templates vs runtime interpreted templates

const std = @import("std");
const vibe_jinja = @import("vibe_jinja");
const aot = vibe_jinja.aot_compiler;

const Timer = struct {
    start_time: i128,

    pub fn start() Timer {
        return .{ .start_time = std.time.nanoTimestamp() };
    }

    pub fn elapsed_ns(self: Timer) u64 {
        const end = std.time.nanoTimestamp();
        return @intCast(end - self.start_time);
    }

    pub fn elapsed_us(self: Timer) f64 {
        return @as(f64, @floatFromInt(self.elapsed_ns())) / 1000.0;
    }
};

fn runAotBenchmark(allocator: std.mem.Allocator, template: []const u8, name: []const u8, iterations: usize) !f64 {
    // Compile template once
    const code = try aot.compileToZig(allocator, template, name);
    defer allocator.free(code);

    // For now, just measure compile time since we can't dynamically run generated code
    // The real benefit comes when templates are compiled at build time
    var timer = Timer.start();

    for (0..iterations) |_| {
        const result = try aot.compileToZig(allocator, template, name);
        allocator.free(result);
    }

    return timer.elapsed_us() / @as(f64, @floatFromInt(iterations));
}

fn runJitBenchmark(allocator: std.mem.Allocator, template: []const u8, iterations: usize) !f64 {
    // Create environment
    var env = vibe_jinja.Environment.init(allocator);
    defer env.deinit();

    // Parse and compile template once
    const parsed = try env.fromString(template, "benchmark");
    var compiled = try vibe_jinja.compiler.compile(&env, parsed, "benchmark", allocator);
    defer compiled.deinit();

    // Create context once (reuse for all iterations)
    var ctx_vars = std.StringHashMap(vibe_jinja.value.Value).init(allocator);
    defer ctx_vars.deinit();
    try ctx_vars.put("name", vibe_jinja.value.Value{ .string = "World" });
    try ctx_vars.put("show", vibe_jinja.value.Value{ .boolean = true });

    // Add items list for loop templates
    const list_ptr = try allocator.create(vibe_jinja.value.List);
    list_ptr.* = vibe_jinja.value.List.init(allocator);
    defer list_ptr.deinit(allocator);
    for (0..5) |i| {
        try list_ptr.append(vibe_jinja.value.Value{ .integer = @intCast(i) });
    }
    try ctx_vars.put("items", vibe_jinja.value.Value{ .list = list_ptr });

    var ctx = try vibe_jinja.context.Context.init(&env, ctx_vars, "benchmark", allocator);
    defer ctx.deinit();

    // Benchmark render iterations
    var timer = Timer.start();

    for (0..iterations) |_| {
        const result = try compiled.render(&ctx, allocator);
        allocator.free(result);
    }

    return timer.elapsed_us() / @as(f64, @floatFromInt(iterations));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                   AOT vs JIT Benchmark (Phase 7)                       ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════════════════╝\n\n", .{});

    // Test templates
    const templates = [_]struct { name: []const u8, template: []const u8 }{
        .{ .name = "Simple Variable", .template = "Hello {{ name }}!" },
        .{ .name = "Filter (upper)", .template = "{{ name | upper }}" },
        .{ .name = "If Statement", .template = "{% if show %}visible{% else %}hidden{% endif %}" },
        .{ .name = "For Loop", .template = "{% for item in items %}{{ item }}{% endfor %}" },
        .{ .name = "Complex", .template = "{% for item in items %}{{ item | upper }}: {{ loop.index }}{% if not loop.last %}, {% endif %}{% endfor %}" },
    };

    const iterations = 1000;

    std.debug.print("┌──────────────────────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│  Benchmark Results ({d} iterations)                                        │\n", .{iterations});
    std.debug.print("├────────────────────────┬─────────────────┬─────────────────┬─────────────┤\n", .{});
    std.debug.print("│ Template               │ AOT Compile (µs)│ JIT Render (µs) │ AOT/JIT     │\n", .{});
    std.debug.print("├────────────────────────┼─────────────────┼─────────────────┼─────────────┤\n", .{});

    for (templates) |t| {
        const aot_time = runAotBenchmark(allocator, t.template, t.name, iterations) catch |err| {
            std.debug.print("│ {s: <22} │ ERROR: {any}                                    │\n", .{ t.name, err });
            continue;
        };

        const jit_time = runJitBenchmark(allocator, t.template, iterations) catch |err| {
            std.debug.print("│ {s: <22} │ {d: >14.2} │ ERROR: {any}         │\n", .{ t.name, aot_time, err });
            continue;
        };

        const ratio = aot_time / jit_time;

        std.debug.print("│ {s: <22} │ {d: >14.2} │ {d: >14.2} │ {d: >10.2}x │\n", .{ t.name, aot_time, jit_time, ratio });
    }

    std.debug.print("└────────────────────────┴─────────────────┴─────────────────┴─────────────┘\n\n", .{});

    // Show sample generated code
    std.debug.print("┌──────────────────────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│  Sample AOT-Generated Zig Code                                          │\n", .{});
    std.debug.print("└──────────────────────────────────────────────────────────────────────────┘\n\n", .{});

    const sample_template = "Hello {{ name | upper }}!";
    const sample_code = try aot.compileToZig(allocator, sample_template, "hello");
    defer allocator.free(sample_code);

    std.debug.print("Template: Hello {{{{ name | upper }}}}!\n\n", .{});
    std.debug.print("Generated Zig:\n", .{});
    std.debug.print("─────────────────────────────────────────────────────────────────\n", .{});
    std.debug.print("{s}", .{sample_code});
    std.debug.print("─────────────────────────────────────────────────────────────────\n\n", .{});

    std.debug.print("╔════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                           Analysis                                      ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════════════════╝\n\n", .{});
    std.debug.print("AOT compilation eliminates:\n", .{});
    std.debug.print("  • All runtime parsing overhead\n", .{});
    std.debug.print("  • All bytecode interpretation\n", .{});
    std.debug.print("  • Most dynamic allocation\n", .{});
    std.debug.print("  • Type reflection costs\n\n", .{});
    std.debug.print("Note: AOT time above measures *re-compilation*, not render time.\n", .{});
    std.debug.print("Actual AOT render would be MUCH faster (direct function calls).\n", .{});
    std.debug.print("When used at build time, template compilation is a one-time cost.\n\n", .{});

    // SIMD benchmark
    std.debug.print("╔════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                   SIMD String Operations Benchmark                      ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════════════════╝\n\n", .{});

    const simd = vibe_jinja.simd_utils;

    // Create a large template-like string
    var large_template: [8192]u8 = undefined;
    @memset(&large_template, 'x');
    // Add some delimiters
    @memcpy(large_template[1000..1002], "{{");
    @memcpy(large_template[1050..1052], "}}");
    @memcpy(large_template[3000..3002], "{%");
    @memcpy(large_template[3100..3102], "%}");
    @memcpy(large_template[5000..5002], "{#");
    @memcpy(large_template[5100..5102], "#}");

    const simd_iterations = 10000;

    // SIMD findOpenBrace
    {
        var timer = Timer.start();
        for (0..simd_iterations) |_| {
            _ = simd.findOpenBrace(&large_template);
        }
        const simd_time = timer.elapsed_us() / @as(f64, @floatFromInt(simd_iterations));

        // Compare with std.mem.indexOfScalar
        timer = Timer.start();
        for (0..simd_iterations) |_| {
            _ = std.mem.indexOfScalar(u8, &large_template, '{');
        }
        const std_time = timer.elapsed_us() / @as(f64, @floatFromInt(simd_iterations));

        const speedup = std_time / simd_time;
        std.debug.print("findOpenBrace (8KB): SIMD={d:.3}µs, std={d:.3}µs, speedup={d:.1}x\n", .{ simd_time, std_time, speedup });
    }

    // SIMD containsHtmlSpecial
    {
        var timer = Timer.start();
        for (0..simd_iterations) |_| {
            _ = simd.containsHtmlSpecial(&large_template);
        }
        const simd_time = timer.elapsed_us() / @as(f64, @floatFromInt(simd_iterations));

        // Scalar comparison
        timer = Timer.start();
        for (0..simd_iterations) |_| {
            for (large_template) |c| {
                if (c == '<' or c == '>' or c == '&' or c == '"' or c == '\'') break;
            }
        }
        const scalar_time = timer.elapsed_us() / @as(f64, @floatFromInt(simd_iterations));

        const speedup = scalar_time / simd_time;
        std.debug.print("containsHtmlSpecial (8KB): SIMD={d:.3}µs, scalar={d:.3}µs, speedup={d:.1}x\n", .{ simd_time, scalar_time, speedup });
    }

    std.debug.print("\n", .{});
}

const std = @import("std");
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;
const utils = vibe_jinja.utils;
const filters = vibe_jinja.filters;
const tests = vibe_jinja.tests;
const value_mod = vibe_jinja.value;
const compiler = vibe_jinja.compiler;

/// Benchmark result for reporting
pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    avg_ns: f64,
    min_ns: u64,
    max_ns: u64,
    median_ns: u64,
    p95_ns: u64,
    ops_per_sec: f64,
};

/// Collect timing samples and compute statistics
const TimingSamples = struct {
    samples: std.ArrayList(u64),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .samples = std.ArrayList(u64).empty,
            .allocator = allocator,
        };
    }

    pub fn add(self: *Self, ns: u64) !void {
        try self.samples.append(self.allocator, ns);
    }

    pub fn stats(self: *Self, name: []const u8) BenchmarkResult {
        const items = self.samples.items;
        if (items.len == 0) {
            return BenchmarkResult{
                .name = name,
                .iterations = 0,
                .total_ns = 0,
                .avg_ns = 0,
                .min_ns = 0,
                .max_ns = 0,
                .median_ns = 0,
                .p95_ns = 0,
                .ops_per_sec = 0,
            };
        }

        // Sort for percentiles
        std.mem.sort(u64, items, {}, std.sort.asc(u64));

        var total: u64 = 0;
        var min_val: u64 = items[0];
        var max_val: u64 = items[0];
        for (items) |sample| {
            total += sample;
            if (sample < min_val) min_val = sample;
            if (sample > max_val) max_val = sample;
        }

        const median_idx = items.len / 2;
        const p95_idx = (items.len * 95) / 100;

        const avg = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(items.len));
        const ops_per_sec = if (avg > 0) 1_000_000_000.0 / avg else 0;

        return BenchmarkResult{
            .name = name,
            .iterations = items.len,
            .total_ns = total,
            .avg_ns = avg,
            .min_ns = min_val,
            .max_ns = max_val,
            .median_ns = items[median_idx],
            .p95_ns = items[p95_idx],
            .ops_per_sec = ops_per_sec,
        };
    }

    pub fn deinit(self: *Self) void {
        self.samples.deinit(self.allocator);
    }
};

/// Print a benchmark result with enhanced statistics
fn printResult(result: BenchmarkResult) void {
    std.debug.print("  {s}:\n", .{result.name});
    std.debug.print("    Iterations: {d}\n", .{result.iterations});
    std.debug.print("    Total time: {d}ms\n", .{result.total_ns / 1_000_000});
    std.debug.print("    Avg: {d:.0}ns | Min: {d}ns | Max: {d}ns\n", .{ result.avg_ns, result.min_ns, result.max_ns });
    std.debug.print("    Median: {d}ns | P95: {d}ns\n", .{ result.median_ns, result.p95_ns });
    std.debug.print("    Throughput: {d:.0} ops/sec\n\n", .{result.ops_per_sec});
}

/// Simple benchmark runner
pub fn runBenchmark(allocator: std.mem.Allocator) !void {
    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          vibe-jinja Performance Benchmarks                ║\n", .{});
    std.debug.print("╠═══════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Phase 6 optimizations: comptime filter lookup,           ║\n", .{});
    std.debug.print("║  arena allocator for filter chains, value fast paths      ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    // Core benchmarks
    std.debug.print("─── Template Rendering ───\n\n", .{});
    try benchmarkSimpleTemplate(allocator);
    try benchmarkLoopTemplate(allocator);
    try benchmarkConditionalTemplate(allocator);
    try benchmarkNestedTemplates(allocator);

    // Filter benchmarks
    std.debug.print("─── Filter Performance ───\n\n", .{});
    try benchmarkFilters(allocator);
    try benchmarkFilterLookup(allocator);

    // Value benchmarks
    std.debug.print("─── Value Operations ───\n\n", .{});
    try benchmarkValueComparison(allocator);
    try benchmarkValueConversion(allocator);

    // Cache benchmarks
    std.debug.print("─── Caching ───\n\n", .{});
    try benchmarkCache(allocator);

    // Memory benchmarks
    std.debug.print("─── Memory Allocation ───\n\n", .{});
    try benchmarkAllocators(allocator);

    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  Benchmarks complete\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
}

fn benchmarkSimpleTemplate(allocator: std.mem.Allocator) !void {
    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "Hello {{ name }}!";
    const iterations: usize = 1000;

    // === Test 1: Full render (parse + compile + render each time) ===
    {
        var samples = TimingSamples.init(allocator);
        defer samples.deinit();

        for (0..iterations) |_| {
            var timer = try std.time.Timer.start();

            var rt = runtime.Runtime.init(&env, allocator);
            defer rt.deinit();

            var vars = std.StringHashMap(context.Value).init(allocator);
            defer vars.deinit();
            const name_str = try allocator.dupe(u8, "World");
            try vars.put("name", context.Value{ .string = name_str });
            defer allocator.free(name_str);

            const result_str = try rt.renderString(source, vars, "test");
            allocator.free(result_str);

            try samples.add(timer.read());
        }

        const result = samples.stats("Simple Template (full pipeline)");
        printResult(result);
    }

    // === Test 2: Pre-compiled render (compile once, render many) ===
    // This is what Python Jinja2 benchmarks test
    {
        var samples = TimingSamples.init(allocator);
        defer samples.deinit();

        // Pre-compile once
        const template = try env.fromString(source, "precompiled");
        var compiled = try vibe_jinja.compiler.compile(&env, template, "precompiled", allocator);
        defer compiled.deinit();

        for (0..iterations) |_| {
            var timer = try std.time.Timer.start();

            var vars = std.StringHashMap(context.Value).init(allocator);
            defer vars.deinit();
            const name_str = try allocator.dupe(u8, "World");
            try vars.put("name", context.Value{ .string = name_str });
            defer allocator.free(name_str);

            var ctx = try context.Context.init(&env, vars, "test", allocator);
            defer ctx.deinit();

            const result_str = try compiled.render(&ctx, allocator);
            allocator.free(result_str);

            try samples.add(timer.read());
        }

        const result = samples.stats("Simple Template (pre-compiled)");
        printResult(result);
    }
}

fn benchmarkLoopTemplate(allocator: std.mem.Allocator) !void {
    var samples = TimingSamples.init(allocator);
    defer samples.deinit();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% for item in items %}{{ item }}{% endfor %}";
    const iterations: usize = 100;

    for (0..iterations) |_| {
        var timer = try std.time.Timer.start();

        var rt = runtime.Runtime.init(&env, allocator);
        defer rt.deinit();

        var vars = std.StringHashMap(context.Value).init(allocator);
        defer vars.deinit();

        // Create list - note: deinit() already calls destroy() internally
        const list_ptr = try allocator.create(value_mod.List);
        list_ptr.* = value_mod.List.init(allocator);
        defer list_ptr.deinit(allocator);
        for (0..10) |i| {
            const num_str = try std.fmt.allocPrint(allocator, "{}", .{i});
            try list_ptr.append(context.Value{ .string = num_str });
        }

        try vars.put("items", context.Value{ .list = list_ptr });

        const result_str = try rt.renderString(source, vars, "test");
        allocator.free(result_str);

        try samples.add(timer.read());
    }

    const result = samples.stats("Loop Template");
    printResult(result);
}

fn benchmarkConditionalTemplate(allocator: std.mem.Allocator) !void {
    var samples = TimingSamples.init(allocator);
    defer samples.deinit();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{% if condition %}True{% else %}False{% endif %}";
    const iterations: usize = 1000;

    for (0..iterations) |_| {
        var timer = try std.time.Timer.start();

        var rt = runtime.Runtime.init(&env, allocator);
        defer rt.deinit();

        var vars = std.StringHashMap(context.Value).init(allocator);
        defer vars.deinit();
        try vars.put("condition", context.Value{ .boolean = true });

        const result_str = try rt.renderString(source, vars, "test");
        allocator.free(result_str);

        try samples.add(timer.read());
    }

    const result = samples.stats("Conditional Template");
    printResult(result);
}

fn benchmarkNestedTemplates(allocator: std.mem.Allocator) !void {
    var samples = TimingSamples.init(allocator);
    defer samples.deinit();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Simpler nested template without range() which may have issues
    const source = "{% if a %}{% if b %}nested{% endif %}{% endif %}";
    const iterations: usize = 1000;

    for (0..iterations) |_| {
        var timer = try std.time.Timer.start();

        var rt = runtime.Runtime.init(&env, allocator);
        defer rt.deinit();

        var vars = std.StringHashMap(context.Value).init(allocator);
        defer vars.deinit();
        try vars.put("a", context.Value{ .boolean = true });
        try vars.put("b", context.Value{ .boolean = true });

        const result_str = try rt.renderString(source, vars, "test");
        allocator.free(result_str);

        try samples.add(timer.read());
    }

    const result = samples.stats("Nested Conditionals");
    printResult(result);
}

fn benchmarkFilters(allocator: std.mem.Allocator) !void {
    var samples = TimingSamples.init(allocator);
    defer samples.deinit();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "{{ text|upper|lower|trim|length }}";
    const iterations: usize = 500;

    for (0..iterations) |_| {
        var timer = try std.time.Timer.start();

        var rt = runtime.Runtime.init(&env, allocator);
        defer rt.deinit();

        var vars = std.StringHashMap(context.Value).init(allocator);
        defer {
            var iter = vars.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit(allocator);
            }
            vars.deinit();
        }

        const text_str = try allocator.dupe(u8, "  Hello World  ");
        try vars.put("text", context.Value{ .string = text_str });

        const result_str = try rt.renderString(source, vars, "test");
        allocator.free(result_str);

        try samples.add(timer.read());
    }

    const result = samples.stats("Filter Chain");
    printResult(result);
}

/// Benchmark filter lookup performance (comptime vs dynamic)
fn benchmarkFilterLookup(allocator: std.mem.Allocator) !void {
    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const iterations: usize = 100_000;

    // Benchmark comptime-interned filter lookup
    {
        var samples = TimingSamples.init(allocator);
        defer samples.deinit();

        const filter_names = [_][]const u8{ "escape", "upper", "lower", "trim", "default", "length" };

        for (0..iterations) |i| {
            var timer = try std.time.Timer.start();

            // Look up filter using comptime interned map
            const name = filter_names[i % filter_names.len];
            const func = filters.getBuiltinFilter(name);
            std.mem.doNotOptimizeAway(func);

            try samples.add(timer.read());
        }

        const result = samples.stats("Comptime filter lookup");
        printResult(result);
    }

    // Benchmark dynamic filter lookup
    {
        var samples = TimingSamples.init(allocator);
        defer samples.deinit();

        const filter_names = [_][]const u8{ "escape", "upper", "lower", "trim", "default", "length" };

        for (0..iterations) |i| {
            var timer = try std.time.Timer.start();

            // Look up filter using dynamic hashmap
            const name = filter_names[i % filter_names.len];
            const filter = env.getFilter(name);
            std.mem.doNotOptimizeAway(filter);

            try samples.add(timer.read());
        }

        const result = samples.stats("Dynamic filter lookup");
        printResult(result);
    }
}

/// Benchmark value comparison performance
fn benchmarkValueComparison(allocator: std.mem.Allocator) !void {
    const iterations: usize = 100_000;

    // Integer comparison (same type fast path)
    {
        var samples = TimingSamples.init(allocator);
        defer samples.deinit();

        const val1 = context.Value{ .integer = 42 };
        const val2 = context.Value{ .integer = 42 };

        for (0..iterations) |_| {
            var timer = try std.time.Timer.start();

            const result = try val1.isEqual(val2);
            std.mem.doNotOptimizeAway(result);

            try samples.add(timer.read());
        }

        const result = samples.stats("Integer comparison (same type)");
        printResult(result);
    }

    // String comparison
    {
        var samples = TimingSamples.init(allocator);
        defer samples.deinit();

        const str1 = try allocator.dupe(u8, "hello world");
        defer allocator.free(str1);
        const str2 = try allocator.dupe(u8, "hello world");
        defer allocator.free(str2);

        const val1 = context.Value{ .string = str1 };
        const val2 = context.Value{ .string = str2 };

        for (0..iterations) |_| {
            var timer = try std.time.Timer.start();

            const result = try val1.isEqual(val2);
            std.mem.doNotOptimizeAway(result);

            try samples.add(timer.read());
        }

        const result = samples.stats("String comparison");
        printResult(result);
    }

    // Cross-type comparison (int vs float)
    {
        var samples = TimingSamples.init(allocator);
        defer samples.deinit();

        const val1 = context.Value{ .integer = 42 };
        const val2 = context.Value{ .float = 42.0 };

        for (0..iterations) |_| {
            var timer = try std.time.Timer.start();

            const result = try val1.isEqual(val2);
            std.mem.doNotOptimizeAway(result);

            try samples.add(timer.read());
        }

        const result = samples.stats("Cross-type comparison (int/float)");
        printResult(result);
    }
}

/// Benchmark value type conversion
fn benchmarkValueConversion(allocator: std.mem.Allocator) !void {
    const iterations: usize = 50_000;

    // Integer to string
    {
        var samples = TimingSamples.init(allocator);
        defer samples.deinit();

        const val = context.Value{ .integer = 12345 };

        for (0..iterations) |_| {
            var timer = try std.time.Timer.start();

            const str = try val.toString(allocator);
            allocator.free(str);

            try samples.add(timer.read());
        }

        const result = samples.stats("Integer to string");
        printResult(result);
    }

    // String to integer (toInteger)
    {
        var samples = TimingSamples.init(allocator);
        defer samples.deinit();

        const str = try allocator.dupe(u8, "12345");
        defer allocator.free(str);
        const val = context.Value{ .string = str };

        for (0..iterations) |_| {
            var timer = try std.time.Timer.start();

            const int_val = val.toInteger();
            std.mem.doNotOptimizeAway(int_val);

            try samples.add(timer.read());
        }

        const result = samples.stats("String to integer");
        printResult(result);
    }

    // Boolean truthiness check
    {
        var samples = TimingSamples.init(allocator);
        defer samples.deinit();

        const val = context.Value{ .integer = 42 };

        for (0..iterations) |_| {
            var timer = try std.time.Timer.start();

            const truthy = val.isTruthy() catch false;
            std.mem.doNotOptimizeAway(truthy);

            try samples.add(timer.read());
        }

        const result = samples.stats("Truthiness check");
        printResult(result);
    }
}

fn benchmarkCache(allocator: std.mem.Allocator) !void {
    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const source = "Hello {{ name }}!";

    // First render (cache miss)
    var rt1 = runtime.Runtime.init(&env, allocator);
    defer rt1.deinit();

    var vars1 = std.StringHashMap(context.Value).init(allocator);
    defer vars1.deinit();
    const name_str1 = try allocator.dupe(u8, "World");
    try vars1.put("name", context.Value{ .string = name_str1 });
    defer allocator.free(name_str1);

    var timer1 = try std.time.Timer.start();
    const result1 = try rt1.renderString(source, vars1, "test");
    const first_render_time = timer1.read();
    allocator.free(result1);

    // Second render (cache hit)
    var rt2 = runtime.Runtime.init(&env, allocator);
    defer rt2.deinit();

    var vars2 = std.StringHashMap(context.Value).init(allocator);
    defer vars2.deinit();
    const name_str2 = try allocator.dupe(u8, "World");
    try vars2.put("name", context.Value{ .string = name_str2 });
    defer allocator.free(name_str2);

    var timer2 = try std.time.Timer.start();
    const result2 = try rt2.renderString(source, vars2, "test");
    const second_render_time = timer2.read();
    allocator.free(result2);

    const speedup = @as(f64, @floatFromInt(first_render_time)) / @as(f64, @floatFromInt(second_render_time));
    std.debug.print("  Cache Benchmark:\n", .{});
    std.debug.print("    First render (miss): {d}ns\n", .{first_render_time});
    std.debug.print("    Second render (hit): {d}ns\n", .{second_render_time});
    std.debug.print("    Speedup: {d:.2}x\n\n", .{speedup});

    // Print cache stats
    if (env.getCacheStats()) |stats| {
        std.debug.print("    Cache Stats: Size={}, Hits={}, Misses={}, Hit Rate={d:.2}%\n\n", .{ stats.size, stats.hits, stats.misses, stats.hit_rate * 100.0 });
    }
}

fn benchmarkAllocators(allocator: std.mem.Allocator) !void {
    const iterations: usize = 100;
    const source = "Hello {{ name }}!";

    // Test with general purpose allocator
    {
        var samples = TimingSamples.init(allocator);
        defer samples.deinit();

        var env = environment.Environment.init(allocator);
        defer env.deinit();

        for (0..iterations) |_| {
            var timer = try std.time.Timer.start();

            var rt = runtime.Runtime.init(&env, allocator);
            defer rt.deinit();

            var vars = std.StringHashMap(context.Value).init(allocator);
            defer {
                var iter = vars.iterator();
                while (iter.next()) |entry| {
                    entry.value_ptr.*.deinit(allocator);
                }
                vars.deinit();
            }

            const name_str = try allocator.dupe(u8, "World");
            try vars.put("name", context.Value{ .string = name_str });

            const result_str = try rt.renderString(source, vars, "test");
            allocator.free(result_str);

            try samples.add(timer.read());
        }

        const result = samples.stats("General Purpose Allocator");
        printResult(result);
    }

    // Test with arena allocator (simplified - just demonstrates concept)
    // Note: Real arena usage would need careful lifetime management
    std.debug.print("  Arena Allocator:\n", .{});
    std.debug.print("    (Arena provides bulk deallocation - use utils.RenderArena)\n\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try runBenchmark(allocator);
}

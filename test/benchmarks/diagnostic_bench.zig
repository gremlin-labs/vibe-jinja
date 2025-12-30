//! Diagnostic Benchmark Suite
//!
//! This benchmark suite provides detailed diagnostics for performance profiling
//! to identify bottlenecks in the vibe-jinja template engine.
//!
//! # Running the Diagnostics
//!
//! ```bash
//! zig build bench-diagnostic
//! ```
//!
//! # Benchmark Scenarios
//!
//! The suite tests isolated components:
//! - **empty**: Baseline with no content
//! - **single_var**: Single variable lookup and output
//! - **loop_1/10/100**: Loop iteration overhead scaling
//! - **filter_single**: Single filter application
//! - **filter_chain_4**: Multiple filters in chain
//! - **nested_conditionals**: Control flow overhead
//! - **context_derive**: Context derivation cost

const std = @import("std");
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const context = vibe_jinja.context;
const value_mod = vibe_jinja.value;
const compiler = vibe_jinja.compiler;
const diagnostics = vibe_jinja.diagnostics;
const CountingAllocator = vibe_jinja.counting_allocator.CountingAllocator;
const bytecode_mod = vibe_jinja.bytecode;

/// Benchmark scenario configuration
const Scenario = struct {
    name: []const u8,
    template: []const u8,
    description: []const u8,
    warmup_iterations: usize = 10,
    iterations: usize = 100,
    loop_count: ?usize = null, // Expected loop iterations for overhead calculation
};

/// All benchmark scenarios
const scenarios = [_]Scenario{
    // Baseline - minimal template
    .{
        .name = "empty",
        .template = "",
        .description = "Empty template (baseline overhead)",
    },

    // Plaintext only - no template logic
    .{
        .name = "plaintext",
        .template = "Hello, World!",
        .description = "Static text only (no expressions)",
    },

    // Single variable - measures lookup + output
    .{
        .name = "single_var",
        .template = "{{ name }}",
        .description = "Single variable lookup and output",
    },

    // Multiple variables
    .{
        .name = "multi_var",
        .template = "{{ a }} {{ b }} {{ c }} {{ d }} {{ e }}",
        .description = "Five variable lookups",
    },

    // Loop isolation - measures per-iteration overhead
    .{
        .name = "loop_1",
        .template = "{% for i in items %}{{ i }}{% endfor %}",
        .description = "Loop with 1 iteration",
        .loop_count = 1,
    },
    .{
        .name = "loop_10",
        .template = "{% for i in items %}{{ i }}{% endfor %}",
        .description = "Loop with 10 iterations",
        .loop_count = 10,
    },
    .{
        .name = "loop_100",
        .template = "{% for i in items %}{{ i }}{% endfor %}",
        .description = "Loop with 100 iterations",
        .loop_count = 100,
    },

    // Loop with body content
    .{
        .name = "loop_10_body",
        .template = "{% for i in items %}<li>Item {{ i }}</li>{% endfor %}",
        .description = "Loop with 10 iterations and body content",
        .loop_count = 10,
    },

    // Nested loops
    .{
        .name = "nested_loops",
        .template = "{% for i in outer %}{% for j in inner %}{{ i }}-{{ j }}{% endfor %}{% endfor %}",
        .description = "Nested loops (3x3 = 9 iterations)",
        .loop_count = 9,
    },

    // Filter isolation
    .{
        .name = "filter_single",
        .template = "{{ name | upper }}",
        .description = "Single filter application",
    },
    .{
        .name = "filter_chain_4",
        .template = "{{ name | upper | lower | trim | length }}",
        .description = "Chain of 4 filters",
    },

    // Conditional logic
    .{
        .name = "conditional_simple",
        .template = "{% if condition %}yes{% endif %}",
        .description = "Simple if condition",
    },
    .{
        .name = "conditional_else",
        .template = "{% if condition %}yes{% else %}no{% endif %}",
        .description = "If-else condition",
    },
    .{
        .name = "nested_conditionals",
        .template = "{% if a %}{% if b %}ab{% else %}a{% endif %}{% else %}{% if c %}c{% endif %}{% endif %}",
        .description = "Nested conditionals",
    },

    // Attribute access
    .{
        .name = "attr_access",
        .template = "{{ user.name }}",
        .description = "Dict attribute access",
    },

    // Combined template - realistic scenario
    .{
        .name = "realistic_template",
        .template =
        \\<div class="users">
        \\{% for user in users %}
        \\  <div class="user">
        \\    <h2>{{ user.name | upper }}</h2>
        \\    {% if user.active %}<span class="active">Active</span>{% endif %}
        \\  </div>
        \\{% endfor %}
        \\</div>
        ,
        .description = "Realistic template with loops, filters, conditionals",
        .loop_count = 5,
    },
};

/// Build context for a given scenario
fn buildContext(allocator: std.mem.Allocator, scenario: *const Scenario) !std.StringHashMap(context.Value) {
    var vars = std.StringHashMap(context.Value).init(allocator);
    errdefer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
        }
        vars.deinit();
    }

    // Add common variables
    const name_str = try allocator.dupe(u8, "  Test Value  ");
    try vars.put("name", context.Value{ .string = name_str });

    // Add a, b, c, d, e for multi_var test
    const letters = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (letters) |letter| {
        const val_str = try allocator.dupe(u8, letter);
        try vars.put(letter, context.Value{ .string = val_str });
    }

    // Add condition for conditional tests
    try vars.put("condition", context.Value{ .boolean = true });

    // Add user dict for attr_access test
    const user_dict_ptr = try allocator.create(value_mod.Dict);
    user_dict_ptr.* = value_mod.Dict.init(allocator);
    const user_name = try allocator.dupe(u8, "Alice");
    try user_dict_ptr.set("name", context.Value{ .string = user_name });
    try user_dict_ptr.set("active", context.Value{ .boolean = true });
    try vars.put("user", context.Value{ .dict = user_dict_ptr });

    // Add items list for loop tests
    if (scenario.loop_count) |count| {
        const list_ptr = try allocator.create(value_mod.List);
        list_ptr.* = value_mod.List.init(allocator);
        for (0..count) |i| {
            const num_str = try std.fmt.allocPrint(allocator, "{}", .{i + 1});
            try list_ptr.append(context.Value{ .string = num_str });
        }
        try vars.put("items", context.Value{ .list = list_ptr });
    }

    // Add outer/inner for nested loops test
    if (std.mem.eql(u8, scenario.name, "nested_loops")) {
        const outer_list = try allocator.create(value_mod.List);
        outer_list.* = value_mod.List.init(allocator);
        for (0..3) |i| {
            const num_str = try std.fmt.allocPrint(allocator, "{}", .{i + 1});
            try outer_list.append(context.Value{ .string = num_str });
        }
        try vars.put("outer", context.Value{ .list = outer_list });

        const inner_list = try allocator.create(value_mod.List);
        inner_list.* = value_mod.List.init(allocator);
        for (0..3) |i| {
            const num_str = try std.fmt.allocPrint(allocator, "{}", .{i + 1});
            try inner_list.append(context.Value{ .string = num_str });
        }
        try vars.put("inner", context.Value{ .list = inner_list });
    }

    // Add users list for realistic template
    if (std.mem.eql(u8, scenario.name, "realistic_template")) {
        const users_list = try allocator.create(value_mod.List);
        users_list.* = value_mod.List.init(allocator);

        for (0..5) |i| {
            const user_d = try allocator.create(value_mod.Dict);
            user_d.* = value_mod.Dict.init(allocator);

            const uname = try std.fmt.allocPrint(allocator, "User{}", .{i + 1});
            try user_d.set("name", context.Value{ .string = uname });
            try user_d.set("active", context.Value{ .boolean = i % 2 == 0 });

            try users_list.append(context.Value{ .dict = user_d });
        }
        try vars.put("users", context.Value{ .list = users_list });
    }

    return vars;
}

/// Free context variables
fn freeContext(allocator: std.mem.Allocator, vars: *std.StringHashMap(context.Value)) void {
    var iter = vars.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.*.deinit(allocator);
    }
    vars.deinit();
}

/// Run a single scenario with diagnostics
fn runScenario(
    allocator: std.mem.Allocator,
    scenario: *const Scenario,
    diag: *diagnostics.RenderDiagnostics,
) !void {
    var env = environment.Environment.init(allocator);
    defer env.deinit();

    // Build context for this scenario
    var vars = try buildContext(allocator, scenario);
    defer freeContext(allocator, &vars);

    // Warmup iterations (not counted)
    for (0..scenario.warmup_iterations) |_| {
        var rt = runtime.Runtime.init(&env, allocator);
        defer rt.deinit();

        const result = rt.renderString(scenario.template, vars, scenario.name) catch |err| {
            std.debug.print("Warmup error for {s}: {}\n", .{ scenario.name, err });
            return;
        };
        allocator.free(result);
    }

    // Timed iterations
    diag.reset();
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..scenario.iterations) |_| {
        const start = std.time.nanoTimestamp();

        var rt = runtime.Runtime.init(&env, allocator);
        defer rt.deinit();

        const result = rt.renderString(scenario.template, vars, scenario.name) catch |err| {
            std.debug.print("Render error for {s}: {}\n", .{ scenario.name, err });
            return;
        };
        allocator.free(result);

        const elapsed: u64 = @intCast(@max(0, std.time.nanoTimestamp() - start));
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    // Update diagnostics with timing
    diag.render_ns = total_ns / scenario.iterations;
}

/// Check if bytecode is generated for a template
fn checkBytecodeGeneration(allocator: std.mem.Allocator) !bool {
    var env = environment.Environment.init(allocator);
    defer env.deinit();

    const template = try env.fromString("Hello {{ name }}", "bytecode_test");

    var compiled = try compiler.compile(&env, template, "bytecode_test", allocator);
    defer compiled.deinit();

    // Check if bytecode was generated
    if (compiled.bytecode) |bc| {
        std.debug.print("\n✓ Bytecode IS generated\n", .{});
        std.debug.print("  Instructions: {}\n", .{bc.instructions.items.len});
        std.debug.print("  Constants: {}\n", .{bc.constants.items.len});
        std.debug.print("  Strings: {}\n", .{bc.strings.items.len});
        std.debug.print("  Names: {}\n", .{bc.names.items.len});

        // Print first few instructions
        std.debug.print("  First 10 instructions:\n", .{});
        const max_show = @min(10, bc.instructions.items.len);
        for (bc.instructions.items[0..max_show], 0..) |instr, i| {
            // Use formatInt to safely show opcode value
            const opcode_val = @intFromEnum(instr.opcode);
            std.debug.print("    [{d:4}] opcode={d} (operand: {})\n", .{ i, opcode_val, instr.operand });
        }

        return true;
    } else {
        std.debug.print("\n✗ Bytecode NOT generated - using AST interpretation\n", .{});
        return false;
    }
}

/// Main diagnostic benchmark entry point
pub fn runDiagnostics() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const base_allocator = gpa.allocator();

    std.debug.print(
        \\
        \\╔═══════════════════════════════════════════════════════════════════════════╗
        \\║           vibe-jinja Diagnostic Benchmark Suite                            ║
        \\║           Phase 0: Profiling & Diagnosis                                   ║
        \\╚═══════════════════════════════════════════════════════════════════════════╝
        \\
    , .{});

    // First, check if bytecode is being generated
    std.debug.print("\n=== Bytecode Path Verification ===\n", .{});
    const bytecode_used = try checkBytecodeGeneration(base_allocator);

    // Run all scenarios
    std.debug.print("\n=== Scenario Benchmarks ===\n", .{});
    std.debug.print("\n{s:<25} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{
        "Scenario",
        "Avg (µs)",
        "Allocs",
        "Peak (KB)",
        "Per-iter (µs)",
    });
    std.debug.print("{s}─{s}─{s}─{s}─{s}\n", .{
        "─" ** 25,
        "─" ** 12,
        "─" ** 12,
        "─" ** 12,
        "─" ** 12,
    });

    // Track loop scaling for analysis
    const LoopResult = struct { count: usize, time_us: f64 };
    var loop_results = std.ArrayList(LoopResult).empty;
    defer loop_results.deinit(base_allocator);

    for (&scenarios) |*scenario| {
        // Create counting allocator for this scenario
        var counting = CountingAllocator.init(base_allocator);
        const alloc = counting.allocator();

        var diag = diagnostics.RenderDiagnostics{};
        diag.bytecode_generated = bytecode_used;

        // Run scenario
        runScenario(alloc, scenario, &diag) catch |err| {
            std.debug.print("{s:<25} ERROR: {}\n", .{ scenario.name, err });
            continue;
        };

        // Update allocation stats
        diag.updateFromAllocator(counting.allocation_count, counting.total_bytes, counting.peak_bytes);

        // Calculate per-iteration overhead for loop tests
        const per_iter_str: []const u8 = if (scenario.loop_count) |count| blk: {
            const per_iter = @as(f64, @floatFromInt(diag.render_ns)) / @as(f64, @floatFromInt(count)) / 1000.0;

            try loop_results.append(base_allocator, .{
                .count = count,
                .time_us = @as(f64, @floatFromInt(diag.render_ns)) / 1000.0,
            });

            var buf: [32]u8 = undefined;
            const len = (std.fmt.bufPrint(&buf, "{d:.2}", .{per_iter}) catch "?").len;
            break :blk buf[0..len];
        } else "-";

        std.debug.print("{s:<25} {d:>12.2} {d:>12} {d:>12} {s:>12}\n", .{
            scenario.name,
            @as(f64, @floatFromInt(diag.render_ns)) / 1000.0,
            diag.total_allocations / scenario.iterations,
            diag.peak_memory / 1024,
            per_iter_str,
        });
    }

    // Analysis section
    std.debug.print(
        \\
        \\═══════════════════════════════════════════════════════════════════════════
        \\                              ANALYSIS
        \\═══════════════════════════════════════════════════════════════════════════
        \\
    , .{});

    // Analyze loop scaling
    if (loop_results.items.len >= 2) {
        std.debug.print("\nLoop Scaling Analysis:\n", .{});

        // Find loop_1 and loop_10 for comparison
        var loop_1_time: ?f64 = null;
        var loop_10_time: ?f64 = null;
        var loop_100_time: ?f64 = null;

        for (loop_results.items) |r| {
            switch (r.count) {
                1 => loop_1_time = r.time_us,
                10 => loop_10_time = r.time_us,
                100 => loop_100_time = r.time_us,
                else => {},
            }
        }

        if (loop_1_time != null and loop_10_time != null) {
            const overhead_per_iter = (loop_10_time.? - loop_1_time.?) / 9.0;
            std.debug.print("  Estimated per-iteration overhead: {d:.2} µs\n", .{overhead_per_iter});

            if (loop_100_time != null) {
                const overhead_per_iter_100 = (loop_100_time.? - loop_1_time.?) / 99.0;
                std.debug.print("  (100-iteration estimate): {d:.2} µs\n", .{overhead_per_iter_100});
            }

            // Calculate expected vs actual
            if (loop_10_time != null) {
                const expected_10 = loop_1_time.? * 10.0; // Linear scaling
                const actual_10 = loop_10_time.?;
                const overhead_ratio = actual_10 / expected_10;
                std.debug.print("  Loop overhead ratio (10 items): {d:.2}x expected\n", .{overhead_ratio});
            }
        }
    }

    // Recommendations
    std.debug.print(
        \\
        \\Recommendations:
        \\  - If per-iteration overhead > 50µs: Focus on loop optimization (Phase 1)
        \\  - If allocations per render > 50: Focus on memory optimization (Phase 2)
        \\  - If bytecode NOT used: Enable bytecode path (Phase 3)
        \\  - If filter_chain slow: Optimize filter dispatch (Phase 5)
        \\
        \\═══════════════════════════════════════════════════════════════════════════
        \\
    , .{});
}

pub fn main() !void {
    try runDiagnostics();
}

//! Diagnostics module for performance profiling and analysis
//!
//! This module provides diagnostic infrastructure to measure and track:
//! - Timing breakdowns (parse, compile, render phases)
//! - Memory allocation patterns
//! - Operation counts (variable lookups, filter calls, loop iterations)
//! - Bytecode execution statistics
//!
//! # Usage
//!
//! ```zig
//! var diag = RenderDiagnostics{};
//!
//! // Start timing parse phase
//! diag.startParse();
//! // ... parse template ...
//! diag.endParse();
//!
//! // After render, report results
//! diag.report();
//! ```

const std = @import("std");

/// Render diagnostics for performance profiling
///
/// Tracks timing, allocation, and operation counts during template rendering.
/// Use this to identify performance bottlenecks and track optimization progress.
pub const RenderDiagnostics = struct {
    // Timing breakdown (nanoseconds)
    parse_ns: u64 = 0,
    compile_ns: u64 = 0,
    render_ns: u64 = 0,

    // Allocation tracking
    total_allocations: u64 = 0,
    total_bytes_allocated: u64 = 0,
    peak_memory: u64 = 0,
    current_memory: u64 = 0,

    // Operation counts
    variable_lookups: u64 = 0,
    filter_calls: u64 = 0,
    loop_iterations: u64 = 0,
    scope_creations: u64 = 0,
    value_copies: u64 = 0,
    context_derives: u64 = 0,

    // Bytecode stats (if used)
    bytecode_instructions_executed: u64 = 0,
    bytecode_generated: bool = false,

    // Internal timing state
    _parse_start: ?i128 = null,
    _compile_start: ?i128 = null,
    _render_start: ?i128 = null,

    const Self = @This();

    /// Start timing the parse phase
    pub fn startParse(self: *Self) void {
        self._parse_start = std.time.nanoTimestamp();
    }

    /// End timing the parse phase
    pub fn endParse(self: *Self) void {
        if (self._parse_start) |start| {
            const end = std.time.nanoTimestamp();
            self.parse_ns = @intCast(@max(0, end - start));
            self._parse_start = null;
        }
    }

    /// Start timing the compile phase
    pub fn startCompile(self: *Self) void {
        self._compile_start = std.time.nanoTimestamp();
    }

    /// End timing the compile phase
    pub fn endCompile(self: *Self) void {
        if (self._compile_start) |start| {
            const end = std.time.nanoTimestamp();
            self.compile_ns = @intCast(@max(0, end - start));
            self._compile_start = null;
        }
    }

    /// Start timing the render phase
    pub fn startRender(self: *Self) void {
        self._render_start = std.time.nanoTimestamp();
    }

    /// End timing the render phase
    pub fn endRender(self: *Self) void {
        if (self._render_start) |start| {
            const end = std.time.nanoTimestamp();
            self.render_ns = @intCast(@max(0, end - start));
            self._render_start = null;
        }
    }

    /// Record a variable lookup
    pub inline fn recordVariableLookup(self: *Self) void {
        self.variable_lookups += 1;
    }

    /// Record a filter call
    pub inline fn recordFilterCall(self: *Self) void {
        self.filter_calls += 1;
    }

    /// Record a loop iteration
    pub inline fn recordLoopIteration(self: *Self) void {
        self.loop_iterations += 1;
    }

    /// Record a scope creation
    pub inline fn recordScopeCreation(self: *Self) void {
        self.scope_creations += 1;
    }

    /// Record a value copy
    pub inline fn recordValueCopy(self: *Self) void {
        self.value_copies += 1;
    }

    /// Record a context derivation
    pub inline fn recordContextDerive(self: *Self) void {
        self.context_derives += 1;
    }

    /// Record a bytecode instruction execution
    pub inline fn recordBytecodeInstruction(self: *Self) void {
        self.bytecode_instructions_executed += 1;
    }

    /// Record an allocation
    pub fn recordAllocation(self: *Self, bytes: usize) void {
        self.total_allocations += 1;
        self.total_bytes_allocated += bytes;
        self.current_memory += bytes;
        self.peak_memory = @max(self.peak_memory, self.current_memory);
    }

    /// Record a deallocation
    pub fn recordDeallocation(self: *Self, bytes: usize) void {
        if (self.current_memory >= bytes) {
            self.current_memory -= bytes;
        } else {
            self.current_memory = 0;
        }
    }

    /// Update allocation stats from a CountingAllocator
    pub fn updateFromAllocator(self: *Self, alloc_count: u64, total_bytes: u64, peak_bytes: u64) void {
        self.total_allocations = alloc_count;
        self.total_bytes_allocated = total_bytes;
        self.peak_memory = peak_bytes;
    }

    /// Reset all counters
    pub fn reset(self: *Self) void {
        self.* = Self{};
    }

    /// Get total time across all phases
    pub fn totalTimeNs(self: *const Self) u64 {
        return self.parse_ns + self.compile_ns + self.render_ns;
    }

    /// Get total time in microseconds
    pub fn totalTimeUs(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.totalTimeNs())) / 1000.0;
    }

    /// Calculate per-iteration overhead (if loop iterations > 0)
    pub fn perIterationOverheadUs(self: *const Self) ?f64 {
        if (self.loop_iterations == 0) return null;
        return @as(f64, @floatFromInt(self.render_ns)) / @as(f64, @floatFromInt(self.loop_iterations)) / 1000.0;
    }

    /// Print a formatted diagnostic report
    pub fn report(self: *const Self) void {
        std.debug.print(
            \\
            \\╔═══════════════════════════════════════════════════════════╗
            \\║               Render Diagnostics Report                    ║
            \\╠═══════════════════════════════════════════════════════════╣
            \\║ Timing:                                                    ║
            \\║   Parse:    {d:>10.2} µs                                   ║
            \\║   Compile:  {d:>10.2} µs                                   ║
            \\║   Render:   {d:>10.2} µs                                   ║
            \\║   Total:    {d:>10.2} µs                                   ║
            \\╠═══════════════════════════════════════════════════════════╣
            \\║ Memory:                                                    ║
            \\║   Allocations: {d:>8}                                      ║
            \\║   Total bytes: {d:>8} KB                                   ║
            \\║   Peak memory: {d:>8} KB                                   ║
            \\╠═══════════════════════════════════════════════════════════╣
            \\║ Operations:                                                ║
            \\║   Variable lookups:  {d:>8}                                ║
            \\║   Filter calls:      {d:>8}                                ║
            \\║   Loop iterations:   {d:>8}                                ║
            \\║   Scope creations:   {d:>8}                                ║
            \\║   Value copies:      {d:>8}                                ║
            \\║   Context derives:   {d:>8}                                ║
            \\╠═══════════════════════════════════════════════════════════╣
            \\║ Bytecode:                                                  ║
            \\║   Generated:     {s:>8}                                    ║
            \\║   Instructions:  {d:>8}                                    ║
            \\
        , .{
            @as(f64, @floatFromInt(self.parse_ns)) / 1000.0,
            @as(f64, @floatFromInt(self.compile_ns)) / 1000.0,
            @as(f64, @floatFromInt(self.render_ns)) / 1000.0,
            self.totalTimeUs(),
            self.total_allocations,
            self.total_bytes_allocated / 1024,
            self.peak_memory / 1024,
            self.variable_lookups,
            self.filter_calls,
            self.loop_iterations,
            self.scope_creations,
            self.value_copies,
            self.context_derives,
            if (self.bytecode_generated) "yes" else "no",
            self.bytecode_instructions_executed,
        });

        // Print per-iteration overhead if applicable
        if (self.perIterationOverheadUs()) |overhead| {
            std.debug.print(
                \\║ Per-iteration overhead: {d:.2} µs                         ║
                \\
            , .{overhead});
        }

        std.debug.print(
            \\╚═══════════════════════════════════════════════════════════╝
            \\
        , .{});
    }

    /// Print a compact one-line summary
    pub fn reportCompact(self: *const Self, name: []const u8) void {
        std.debug.print(
            "{s}: {d:.2}µs total | {d} allocs | {d} KB peak | loops:{d} vars:{d} filters:{d}\n",
            .{
                name,
                self.totalTimeUs(),
                self.total_allocations,
                self.peak_memory / 1024,
                self.loop_iterations,
                self.variable_lookups,
                self.filter_calls,
            },
        );
    }

    /// Export as JSON-compatible struct for logging
    pub fn toJson(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator,
            \\{{"timing":{{"parse_us":{d:.2},"compile_us":{d:.2},"render_us":{d:.2},"total_us":{d:.2}}},"memory":{{"allocations":{d},"bytes":{d},"peak":{d}}},"operations":{{"var_lookups":{d},"filter_calls":{d},"loop_iters":{d},"scope_creates":{d},"value_copies":{d},"ctx_derives":{d}}},"bytecode":{{"generated":{s},"instructions":{d}}}}}
        , .{
            @as(f64, @floatFromInt(self.parse_ns)) / 1000.0,
            @as(f64, @floatFromInt(self.compile_ns)) / 1000.0,
            @as(f64, @floatFromInt(self.render_ns)) / 1000.0,
            self.totalTimeUs(),
            self.total_allocations,
            self.total_bytes_allocated,
            self.peak_memory,
            self.variable_lookups,
            self.filter_calls,
            self.loop_iterations,
            self.scope_creations,
            self.value_copies,
            self.context_derives,
            if (self.bytecode_generated) "true" else "false",
            self.bytecode_instructions_executed,
        });
    }
};

/// Thread-local diagnostics for concurrent profiling
pub threadlocal var current_diagnostics: ?*RenderDiagnostics = null;

/// Set the current thread-local diagnostics
pub fn setDiagnostics(diag: *RenderDiagnostics) void {
    current_diagnostics = diag;
}

/// Clear the current thread-local diagnostics
pub fn clearDiagnostics() void {
    current_diagnostics = null;
}

/// Get the current thread-local diagnostics (if set)
pub fn getDiagnostics() ?*RenderDiagnostics {
    return current_diagnostics;
}

/// Inline helper to record variable lookup if diagnostics are enabled
pub inline fn recordVariableLookup() void {
    if (current_diagnostics) |diag| {
        diag.recordVariableLookup();
    }
}

/// Inline helper to record filter call if diagnostics are enabled
pub inline fn recordFilterCall() void {
    if (current_diagnostics) |diag| {
        diag.recordFilterCall();
    }
}

/// Inline helper to record loop iteration if diagnostics are enabled
pub inline fn recordLoopIteration() void {
    if (current_diagnostics) |diag| {
        diag.recordLoopIteration();
    }
}

/// Inline helper to record scope creation if diagnostics are enabled
pub inline fn recordScopeCreation() void {
    if (current_diagnostics) |diag| {
        diag.recordScopeCreation();
    }
}

/// Inline helper to record value copy if diagnostics are enabled
pub inline fn recordValueCopy() void {
    if (current_diagnostics) |diag| {
        diag.recordValueCopy();
    }
}

/// Inline helper to record context derivation if diagnostics are enabled
pub inline fn recordContextDerive() void {
    if (current_diagnostics) |diag| {
        diag.recordContextDerive();
    }
}

/// Inline helper to record bytecode instruction if diagnostics are enabled
pub inline fn recordBytecodeInstruction() void {
    if (current_diagnostics) |diag| {
        diag.recordBytecodeInstruction();
    }
}

// Tests
test "RenderDiagnostics basic operations" {
    var diag = RenderDiagnostics{};

    // Test timing
    diag.startParse();
    std.Thread.sleep(1_000_000); // 1ms
    diag.endParse();

    try std.testing.expect(diag.parse_ns > 0);
    try std.testing.expect(diag.parse_ns >= 1_000_000);

    // Test operation counting
    diag.recordVariableLookup();
    diag.recordVariableLookup();
    diag.recordFilterCall();
    diag.recordLoopIteration();

    try std.testing.expectEqual(@as(u64, 2), diag.variable_lookups);
    try std.testing.expectEqual(@as(u64, 1), diag.filter_calls);
    try std.testing.expectEqual(@as(u64, 1), diag.loop_iterations);

    // Test allocation tracking
    diag.recordAllocation(1024);
    diag.recordAllocation(2048);
    try std.testing.expectEqual(@as(u64, 2), diag.total_allocations);
    try std.testing.expectEqual(@as(u64, 3072), diag.total_bytes_allocated);
    try std.testing.expectEqual(@as(u64, 3072), diag.peak_memory);

    diag.recordDeallocation(1024);
    try std.testing.expectEqual(@as(u64, 2048), diag.current_memory);
    try std.testing.expectEqual(@as(u64, 3072), diag.peak_memory); // Peak unchanged
}

test "RenderDiagnostics reset" {
    var diag = RenderDiagnostics{};

    diag.recordVariableLookup();
    diag.recordAllocation(1024);
    diag.parse_ns = 1000;

    diag.reset();

    try std.testing.expectEqual(@as(u64, 0), diag.variable_lookups);
    try std.testing.expectEqual(@as(u64, 0), diag.total_allocations);
    try std.testing.expectEqual(@as(u64, 0), diag.parse_ns);
}

test "thread-local diagnostics" {
    var diag = RenderDiagnostics{};

    // Initially null
    try std.testing.expect(getDiagnostics() == null);

    // Set and verify
    setDiagnostics(&diag);
    try std.testing.expect(getDiagnostics() == &diag);

    // Record via helper
    recordVariableLookup();
    try std.testing.expectEqual(@as(u64, 1), diag.variable_lookups);

    // Clear and verify
    clearDiagnostics();
    try std.testing.expect(getDiagnostics() == null);

    // Recording when cleared does nothing
    recordVariableLookup();
    try std.testing.expectEqual(@as(u64, 1), diag.variable_lookups);
}

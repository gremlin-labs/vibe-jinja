//! Utility Functions and Performance Optimizations
//!
//! This module provides utility functions, data structures, and performance optimizations
//! used throughout the Jinja template engine.
//!
//! # Performance Utilities
//!
//! - `RenderArena` - Arena allocator for temporary rendering allocations
//! - `FixedTempBuffer` - Fixed-size stack buffer for small allocations
//! - `SmallString` - Small string optimization (stack allocation for short strings)
//! - `StringPool` - String interning for deduplication
//! - `fastIntToString` - Optimized integer-to-string conversion
//! - `fastBoolToString` - Zero-allocation boolean-to-string conversion
//!
//! # String Utilities
//!
//! - `escapeString` - Escape special characters in strings
//! - `unescapeString` - Unescape string literals
//! - `normalizeNewlines` - Normalize newline sequences
//!
//! # Helper Types
//!
//! - `PassArg` - What extra argument to pass to filters/tests (context, environment, etc.)
//! - `LRUCache` - Generic LRU (Least Recently Used) cache
//!
//! # Example
//!
//! ```zig
//! // Use arena allocator for temporary allocations
//! var arena = jinja.utils.RenderArena.init(allocator);
//! defer arena.deinit();
//!
//! const temp_str = try arena.allocator().dupe(u8, "temporary");
//! // All arena allocations freed at once in deinit
//! ```

const std = @import("std");
const value_mod = @import("value.zig");
const context = @import("context.zig");
const environment = @import("environment.zig");

/// Re-export Value type for convenience
pub const Value = value_mod.Value;

// ============================================================================
// Performance Optimization Utilities
// ============================================================================

/// Small string buffer size for stack allocation optimization
/// Strings smaller than this can be allocated on the stack
pub const SMALL_STRING_SIZE = 64;

/// Small buffer for stack-allocated strings
pub const SmallString = struct {
    buffer: [SMALL_STRING_SIZE]u8,
    len: usize,
    overflow: ?[]const u8, // Heap allocation for larger strings
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a small string from a slice
    pub fn init(allocator: std.mem.Allocator, str: []const u8) !Self {
        if (str.len <= SMALL_STRING_SIZE) {
            var result = Self{
                .buffer = undefined,
                .len = str.len,
                .overflow = null,
                .allocator = allocator,
            };
            @memcpy(result.buffer[0..str.len], str);
            return result;
        } else {
            return Self{
                .buffer = undefined,
                .len = str.len,
                .overflow = try allocator.dupe(u8, str),
                .allocator = allocator,
            };
        }
    }

    /// Get the string slice
    pub inline fn slice(self: *const Self) []const u8 {
        if (self.overflow) |s| {
            return s;
        }
        return self.buffer[0..self.len];
    }

    /// Free overflow memory if allocated
    pub fn deinit(self: *Self) void {
        if (self.overflow) |s| {
            self.allocator.free(s);
            self.overflow = null;
        }
    }
};

/// Arena allocator wrapper for temporary allocations during rendering
/// Use this for allocations that will all be freed at once after rendering
pub const RenderArena = struct {
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    /// Initialize a new render arena
    pub fn init(backing_allocator: std.mem.Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    /// Get the arena allocator
    pub inline fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reset the arena (free all allocations at once)
    pub fn reset(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Deinitialize the arena
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }
};

/// Fixed buffer allocator for small temporary allocations
/// Use when you know the maximum size needed
pub const FixedTempBuffer = struct {
    buffer: [4096]u8, // 4KB stack buffer
    fba: std.heap.FixedBufferAllocator,

    const Self = @This();

    pub fn init() Self {
        var result = Self{
            .buffer = undefined,
            .fba = undefined,
        };
        result.fba = std.heap.FixedBufferAllocator.init(&result.buffer);
        return result;
    }

    pub inline fn allocator(self: *Self) std.mem.Allocator {
        return self.fba.allocator();
    }

    pub fn reset(self: *Self) void {
        self.fba.reset();
    }
};

/// String interning pool for frequently used strings
/// Reduces memory usage by sharing string instances
pub const StringPool = struct {
    strings: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .strings = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    /// Intern a string - returns existing copy if available
    pub fn intern(self: *Self, str: []const u8) ![]const u8 {
        if (self.strings.get(str)) |existing| {
            return existing;
        }
        const copy = try self.allocator.dupe(u8, str);
        try self.strings.put(copy, copy);
        return copy;
    }

    pub fn deinit(self: *Self) void {
        var iter = self.strings.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.strings.deinit();
    }
};

/// Filter chain executor with arena allocator optimization
/// Uses arena allocator for intermediate values, only cloning final result
/// This significantly reduces allocation overhead for chained filters like:
/// {{ value | upper | trim | escape }}
pub const FilterChainExecutor = struct {
    arena: std.heap.ArenaAllocator,
    backing_allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new filter chain executor
    pub fn init(backing_allocator: std.mem.Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .backing_allocator = backing_allocator,
        };
    }

    /// Execute a chain of filters efficiently using arena allocation
    /// Intermediate results are allocated in the arena and freed all at once
    /// The final result is cloned to the backing allocator for caller ownership
    pub fn execute(
        self: *Self,
        env: *environment.Environment,
        initial_value: Value,
        filter_names: []const []const u8,
        ctx: ?*context.Context,
    ) !Value {
        const arena_alloc = self.arena.allocator();
        var current = try initial_value.deepCopy(arena_alloc);

        // Apply each filter in the chain
        for (filter_names) |name| {
            const filter = env.getFilter(name) orelse {
                return error.FilterNotFound;
            };

            // Check if async should be used
            const use_async = env.enable_async and filter.is_async;

            // Apply filter using arena allocator for intermediates
            const empty_args: []Value = &.{};
            const result = if (use_async) blk: {
                if (filter.async_func) |async_func| {
                    break :blk try async_func(arena_alloc, current, empty_args, ctx, env);
                } else {
                    break :blk try filter.func(arena_alloc, current, empty_args, ctx, env);
                }
            } else try filter.func(arena_alloc, current, empty_args, ctx, env);

            // Don't deinit current - arena will handle it
            current = result;
        }

        // Clone final result to backing allocator for caller ownership
        const final_result = try current.deepCopy(self.backing_allocator);

        // Reset arena for reuse (keeps capacity)
        _ = self.arena.reset(.retain_capacity);

        return final_result;
    }

    /// Execute filter chain with arguments
    /// For filters that take arguments (e.g., truncate(30))
    pub fn executeWithArgs(
        self: *Self,
        env: *environment.Environment,
        initial_value: Value,
        filter_calls: []const FilterCall,
        ctx: ?*context.Context,
    ) !Value {
        const arena_alloc = self.arena.allocator();
        var current = try initial_value.deepCopy(arena_alloc);

        // Apply each filter in the chain
        for (filter_calls) |call| {
            const filter = env.getFilter(call.name) orelse {
                return error.FilterNotFound;
            };

            // Check if async should be used
            const use_async = env.enable_async and filter.is_async;

            // Apply filter using arena allocator for intermediates
            const result = if (use_async) blk: {
                if (filter.async_func) |async_func| {
                    break :blk try async_func(arena_alloc, current, call.args, ctx, env);
                } else {
                    break :blk try filter.func(arena_alloc, current, call.args, ctx, env);
                }
            } else try filter.func(arena_alloc, current, call.args, ctx, env);

            // Don't deinit current - arena will handle it
            current = result;
        }

        // Clone final result to backing allocator for caller ownership
        const final_result = try current.deepCopy(self.backing_allocator);

        // Reset arena for reuse (keeps capacity)
        _ = self.arena.reset(.retain_capacity);

        return final_result;
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }
};

/// Filter call descriptor for filter chain execution
pub const FilterCall = struct {
    name: []const u8,
    args: []Value,
};

// ============================================================================
// Inlined Hot Path Functions
// ============================================================================

/// Fast string equality check (uses memcmp for larger strings)
pub inline fn fastStringEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Fast integer to string conversion for small positive integers
/// Uses a lookup table for common values
pub inline fn fastIntToString(allocator: std.mem.Allocator, n: i64) ![]const u8 {
    // Use lookup table for small positive integers (0-99)
    if (n >= 0 and n < 100) {
        const small_ints = [_][]const u8{
            "0",  "1",  "2",  "3",  "4",  "5",  "6",  "7",  "8",  "9",
            "10", "11", "12", "13", "14", "15", "16", "17", "18", "19",
            "20", "21", "22", "23", "24", "25", "26", "27", "28", "29",
            "30", "31", "32", "33", "34", "35", "36", "37", "38", "39",
            "40", "41", "42", "43", "44", "45", "46", "47", "48", "49",
            "50", "51", "52", "53", "54", "55", "56", "57", "58", "59",
            "60", "61", "62", "63", "64", "65", "66", "67", "68", "69",
            "70", "71", "72", "73", "74", "75", "76", "77", "78", "79",
            "80", "81", "82", "83", "84", "85", "86", "87", "88", "89",
            "90", "91", "92", "93", "94", "95", "96", "97", "98", "99",
        };
        return allocator.dupe(u8, small_ints[@intCast(n)]);
    }
    return std.fmt.allocPrint(allocator, "{d}", .{n});
}

/// Fast boolean to string conversion
pub inline fn fastBoolToString(b: bool) []const u8 {
    return if (b) "True" else "False";
}

/// Pass argument type for decorators
/// Determines what should be passed as the first argument to filters/tests/functions
pub const PassArg = enum {
    none, // No special argument passed
    context, // Pass Context as first argument
    eval_context, // Pass EvalContext as first argument (not yet implemented)
    environment, // Pass Environment as first argument
};

/// Internal code marker
/// Functions marked as internal should not appear in tracebacks
pub const InternalCode = struct {
    /// Mark a function as internal (for traceback filtering)
    pub const mark = struct {
        pub const internal = true;
    };

    /// Check if a function should be considered internal
    pub fn isInternal(comptime T: type) bool {
        _ = T;
        // In Zig, we can't mark functions at runtime like Python decorators
        // Instead, we'll use a naming convention or explicit flag
        return false;
    }
};

/// Cycler - cycles through values
pub const Cycler = struct {
    values: std.ArrayList(Value),
    index: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new cycler with values
    pub fn init(allocator: std.mem.Allocator, values: []const Value) !Self {
        // Use same pattern as bytecode.zig - create ArrayList directly
        var cycler = Self{
            .values = undefined,
            .index = 0,
            .allocator = allocator,
        };
        // Zig 0.15: Initialize as empty, allocator passed to methods
        cycler.values = std.ArrayList(Value).empty;

        for (values) |val| {
            // Deep copy values to avoid ownership issues
            const copied_val = try val.deepCopy(allocator);
            try cycler.values.append(allocator, copied_val);
        }

        return cycler;
    }

    /// Deinitialize the cycler
    pub fn deinit(self: *Self) void {
        for (self.values.items) |*val| {
            val.deinit(self.allocator);
        }
        self.values.deinit(self.allocator);
    }

    /// Get the next value (cycles)
    pub fn next(self: *Self) Value {
        if (self.values.items.len == 0) {
            return Value{ .null = {} };
        }

        const val = self.values.items[self.index];
        self.index = (self.index + 1) % self.values.items.len;

        // Return a deep copy
        return val.deepCopy(self.allocator) catch Value{ .null = {} };
    }

    /// Reset to the beginning
    pub fn reset(self: *Self) void {
        self.index = 0;
    }
};

/// Joiner - joins values with a separator
pub const Joiner = struct {
    separator: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new joiner with separator
    pub fn init(allocator: std.mem.Allocator, separator: []const u8) !Self {
        return Self{
            .separator = try allocator.dupe(u8, separator),
            .allocator = allocator,
        };
    }

    /// Deinitialize the joiner
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.separator);
    }

    /// Join values with the separator
    pub fn join(self: *Self, values: []const Value) ![]const u8 {
        if (values.len == 0) {
            return try self.allocator.dupe(u8, "");
        }

        var result = std.ArrayList(u8){};
        defer result.deinit(self.allocator);

        for (values, 0..) |val, i| {
            if (i > 0) {
                try result.appendSlice(self.allocator, self.separator);
            }

            const str = try val.toString(self.allocator);
            defer self.allocator.free(str);
            try result.appendSlice(self.allocator, str);
        }

        return try result.toOwnedSlice(self.allocator);
    }
};

/// Namespace - provides a namespace for variables
pub const Namespace = struct {
    vars: std.StringHashMap(Value),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new namespace
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .vars = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
        };
    }

    /// Deinitialize the namespace
    pub fn deinit(self: *Self) void {
        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.vars.deinit();
    }

    /// Set a variable in the namespace
    /// Optimized to avoid unnecessary string duplication if key already exists
    pub inline fn set(self: *Self, name: []const u8, value: Value) !void {
        // Check if key already exists to avoid unnecessary duplication
        if (self.vars.getEntry(name)) |entry| {
            // Key already exists, just update value
            entry.value_ptr.*.deinit(self.allocator);
            entry.value_ptr.* = value;
        } else {
            // New key, duplicate it
            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);
            try self.vars.put(name_copy, value);
        }
    }

    /// Get a variable from the namespace
    pub fn get(self: *Self, name: []const u8) ?Value {
        return self.vars.get(name);
    }

    /// Convert namespace to a dict Value
    pub fn toDict(self: *Self) !Value {
        const Dict = value_mod.Dict;
        const dict = try self.allocator.create(Dict);
        errdefer self.allocator.destroy(dict);
        dict.* = Dict.init(self.allocator);
        errdefer dict.deinit(self.allocator);

        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            // dict.set() will duplicate the key, so we don't need to do it here
            // Deep copy the value to avoid ownership issues
            const val_copy = try entry.value_ptr.*.deepCopy(self.allocator);
            try dict.set(entry.key_ptr.*, val_copy);
        }

        return Value{ .dict = dict };
    }
};

// ============================================================================
// Global Functions (Jinja2 parity: range, dict, lipsum, cycler, joiner, namespace)
// ============================================================================

/// Global function error type
pub const GlobalError = std.mem.Allocator.Error || error{
    RuntimeError,
    UndefinedError,
    InvalidArgument,
    TypeError,
    NotCallable,
};

/// range([start,] stop[, step]) -> list of integers
///
/// Returns a list containing an arithmetic progression of integers.
/// - range(stop) returns [0, 1, ..., stop-1]
/// - range(start, stop) returns [start, start+1, ..., stop-1]
/// - range(start, stop, step) returns [start, start+step, start+2*step, ...]
///
/// This is the global function available in Jinja templates as `range()`.
pub fn rangeGlobal(
    allocator: std.mem.Allocator,
    args: []Value,
    ctx: ?*anyopaque,
    env: ?*anyopaque,
) GlobalError!Value {
    _ = ctx;
    _ = env;

    if (args.len == 0 or args.len > 3) {
        return error.InvalidArgument;
    }

    var start: i64 = 0;
    var stop: i64 = 0;
    var step: i64 = 1;

    // Parse arguments based on count
    switch (args.len) {
        1 => {
            // range(stop)
            stop = switch (args[0]) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => return error.TypeError,
            };
        },
        2 => {
            // range(start, stop)
            start = switch (args[0]) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => return error.TypeError,
            };
            stop = switch (args[1]) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => return error.TypeError,
            };
        },
        3 => {
            // range(start, stop, step)
            start = switch (args[0]) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => return error.TypeError,
            };
            stop = switch (args[1]) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => return error.TypeError,
            };
            step = switch (args[2]) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => return error.TypeError,
            };
            // Step cannot be zero
            if (step == 0) {
                return error.InvalidArgument;
            }
        },
        else => return error.InvalidArgument,
    }

    // Create result list
    const list = try allocator.create(value_mod.List);
    errdefer allocator.destroy(list);
    list.* = value_mod.List.init(allocator);
    errdefer list.deinit(allocator);

    // Generate integers
    var current = start;
    if (step > 0) {
        while (current < stop) : (current += step) {
            try list.append(Value{ .integer = current });
        }
    } else {
        // Negative step
        while (current > stop) : (current += step) {
            try list.append(Value{ .integer = current });
        }
    }

    return Value{ .list = list };
}

/// dict(**kwargs) -> dictionary
///
/// Creates a new dictionary from keyword arguments.
/// In templates: dict(foo='bar', baz=123) -> {'foo': 'bar', 'baz': 123}
///
/// Note: In the current implementation, dict() receives positional arguments
/// since keyword arguments are passed as a separate dict. The implementation
/// handles both cases:
/// - Empty args: returns empty dict
/// - Single dict arg: returns a copy of that dict (for dict(existing_dict))
/// - Multiple args: treats as key-value pairs (for programmatic use)
///
/// This is the global function available in Jinja templates as `dict()`.
pub fn dictGlobal(
    allocator: std.mem.Allocator,
    args: []Value,
    ctx: ?*anyopaque,
    env: ?*anyopaque,
) GlobalError!Value {
    _ = ctx;
    _ = env;

    // Create result dictionary
    const dict = try allocator.create(value_mod.Dict);
    errdefer allocator.destroy(dict);
    dict.* = value_mod.Dict.init(allocator);
    errdefer dict.deinit(allocator);

    // If single dict argument, copy it (like dict(existing_dict))
    if (args.len == 1) {
        if (args[0] == .dict) {
            const src_dict = args[0].dict;
            var iter = src_dict.map.iterator();
            while (iter.next()) |entry| {
                const val_copy = try entry.value_ptr.*.deepCopy(allocator);
                errdefer val_copy.deinit(allocator);
                try dict.set(entry.key_ptr.*, val_copy);
            }
        }
        // If it's not a dict, just return empty dict
    }
    // For other cases (empty args, or compiler passes kwargs separately),
    // return the dict as-is (kwargs handling is done by the compiler)

    return Value{ .dict = dict };
}

/// lipsum(n=5, html=True, min=20, max=100) -> text
///
/// Generates lorem ipsum text for layout testing.
/// - n: Number of paragraphs (default: 5)
/// - html: Whether to wrap in HTML paragraphs (default: true)
/// - min: Minimum words per paragraph (default: 20)
/// - max: Maximum words per paragraph (default: 100)
///
/// This is the global function available in Jinja templates as `lipsum()`.
pub fn lipsumGlobal(
    allocator: std.mem.Allocator,
    args: []Value,
    ctx: ?*anyopaque,
    env: ?*anyopaque,
) GlobalError!Value {
    _ = ctx;
    _ = env;

    // Parse arguments with defaults
    var n: usize = 5;
    var html: bool = true;
    var min_words: usize = 20;
    var max_words: usize = 100;

    if (args.len > 0) {
        n = switch (args[0]) {
            .integer => |i| if (i > 0) @intCast(i) else 5,
            else => 5,
        };
    }
    if (args.len > 1) {
        html = switch (args[1]) {
            .boolean => |b| b,
            else => true,
        };
    }
    if (args.len > 2) {
        min_words = switch (args[2]) {
            .integer => |i| if (i > 0) @intCast(i) else 20,
            else => 20,
        };
    }
    if (args.len > 3) {
        max_words = switch (args[3]) {
            .integer => |i| if (i > 0) @intCast(i) else 100,
            else => 100,
        };
    }

    // Generate lorem ipsum text
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    const avg_words = (min_words + max_words) / 2;

    for (0..n) |i| {
        if (html) {
            try result.appendSlice(allocator, "<p>");
        }

        const paragraph = try generateLoremIpsum(allocator, avg_words);
        defer allocator.free(paragraph);
        try result.appendSlice(allocator, paragraph);

        if (html) {
            try result.appendSlice(allocator, "</p>");
        }

        if (i < n - 1) {
            try result.appendSlice(allocator, if (html) "\n" else "\n\n");
        }
    }

    const output = try result.toOwnedSlice(allocator);
    return Value{ .string = output };
}

/// Generate Lorem Ipsum text
pub fn generateLoremIpsum(allocator: std.mem.Allocator, words: usize) ![]const u8 {
    const lorem_words = [_][]const u8{
        "lorem",      "ipsum",        "dolor",   "sit",     "amet",      "consectetur",
        "adipiscing", "elit",         "sed",     "do",      "eiusmod",   "tempor",
        "incididunt", "ut",           "labore",  "et",      "dolore",    "magna",
        "aliqua",     "enim",         "ad",      "minim",   "veniam",    "quis",
        "nostrud",    "exercitation", "ullamco", "laboris", "nisi",      "ut",
        "aliquip",    "ex",           "ea",      "commodo", "consequat",
    };

    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    for (0..words) |i| {
        if (i > 0) {
            try result.append(allocator, ' ');
        }
        const word = lorem_words[i % lorem_words.len];
        try result.appendSlice(allocator, word);
    }

    return try result.toOwnedSlice(allocator);
}

/// raise_exception(message) -> raises TemplateRuntimeError
///
/// Raises a TemplateRuntimeError with the given message.
/// This is commonly used in chat templates to validate template inputs.
///
/// Example:
///   {{ raise_exception("Invalid input: messages must alternate") }}
///
/// This is the global function available in Jinja templates as `raise_exception()`.
/// Note: This is not a standard Jinja2 function, but is commonly used in
/// HuggingFace chat templates for validation.
pub fn raiseExceptionGlobal(
    allocator: std.mem.Allocator,
    args: []Value,
    ctx: ?*anyopaque,
    env: ?*anyopaque,
) GlobalError!Value {
    _ = ctx;
    _ = env;
    _ = allocator;

    // Get error message from first argument
    if (args.len == 0) {
        return error.RuntimeError;
    }

    // The message can be used for debugging, but we always return RuntimeError
    // In a more sophisticated implementation, we could store the message
    // in the error context for better error reporting
    return error.RuntimeError;
}

/// cycler(*items) -> Cycler object
///
/// Creates a cycler object that cycles through the given items.
/// Returns a callable object with .next() and .reset() methods.
///
/// Example:
///   {% set row_class = cycler("odd", "even") %}
///   {{ row_class.next() }}  -> "odd"
///   {{ row_class.next() }}  -> "even"
///   {{ row_class.next() }}  -> "odd"
///
/// This is the global function available in Jinja templates as `cycler()`.
pub fn cyclerGlobal(
    allocator: std.mem.Allocator,
    args: []Value,
    ctx: ?*anyopaque,
    env: ?*anyopaque,
) GlobalError!Value {
    _ = ctx;
    _ = env;

    if (args.len == 0) {
        return error.InvalidArgument;
    }

    // Create a dict to represent the cycler object
    // This will have 'items', 'pos', and methods as attributes
    const dict = try allocator.create(value_mod.Dict);
    errdefer allocator.destroy(dict);
    dict.* = value_mod.Dict.init(allocator);
    errdefer dict.deinit(allocator);

    // Store items as a list
    const items_list = try allocator.create(value_mod.List);
    errdefer allocator.destroy(items_list);
    items_list.* = value_mod.List.init(allocator);
    errdefer items_list.deinit(allocator);

    for (args) |arg| {
        const copied = try arg.deepCopy(allocator);
        try items_list.append(copied);
    }

    try dict.set("_items", Value{ .list = items_list });
    try dict.set("_pos", Value{ .integer = 0 });
    try dict.set("_type", Value{ .string = try allocator.dupe(u8, "cycler") });

    return Value{ .dict = dict };
}

/// joiner(sep=", ") -> Joiner object
///
/// Creates a joiner object that returns empty string on first call
/// and the separator on subsequent calls.
///
/// Example:
///   {% set make_comma = joiner() %}
///   {% for item in items %}{{ make_comma() }}{{ item }}{% endfor %}
///
/// This is the global function available in Jinja templates as `joiner()`.
pub fn joinerGlobal(
    allocator: std.mem.Allocator,
    args: []Value,
    ctx: ?*anyopaque,
    env: ?*anyopaque,
) GlobalError!Value {
    _ = ctx;
    _ = env;

    // Get separator (default ", ")
    var sep: []const u8 = ", ";
    if (args.len > 0) {
        if (args[0] == .string) {
            sep = args[0].string;
        }
    }

    // Create a dict to represent the joiner object
    const dict = try allocator.create(value_mod.Dict);
    errdefer allocator.destroy(dict);
    dict.* = value_mod.Dict.init(allocator);
    errdefer dict.deinit(allocator);

    try dict.set("_sep", Value{ .string = try allocator.dupe(u8, sep) });
    try dict.set("_used", Value{ .boolean = false });
    try dict.set("_type", Value{ .string = try allocator.dupe(u8, "joiner") });

    return Value{ .dict = dict };
}

/// namespace(**kwargs) -> Namespace object
///
/// Creates a namespace object that can hold arbitrary attributes.
/// Variables can be assigned to and read from a namespace.
///
/// Example:
///   {% set ns = namespace(count=0) %}
///   {% for item in items %}
///     {% set ns.count = ns.count + 1 %}
///   {% endfor %}
///   {{ ns.count }}
///
/// This is the global function available in Jinja templates as `namespace()`.
pub fn namespaceGlobal(
    allocator: std.mem.Allocator,
    args: []Value,
    ctx: ?*anyopaque,
    env: ?*anyopaque,
) GlobalError!Value {
    _ = ctx;
    _ = env;

    // Create a dict to represent the namespace object
    const dict = try allocator.create(value_mod.Dict);
    errdefer allocator.destroy(dict);
    dict.* = value_mod.Dict.init(allocator);
    errdefer dict.deinit(allocator);

    // Mark this as a namespace for special handling
    try dict.set("_type", Value{ .string = try allocator.dupe(u8, "namespace") });

    // If single dict argument, copy its contents
    if (args.len == 1 and args[0] == .dict) {
        const src_dict = args[0].dict;
        var iter = src_dict.map.iterator();
        while (iter.next()) |entry| {
            const val_copy = try entry.value_ptr.*.deepCopy(allocator);
            try dict.set(entry.key_ptr.*, val_copy);
        }
    }

    return Value{ .dict = dict };
}

/// strftime_now(format_string) -> formatted current date/time
///
/// Formats the current time according to the provided format string.
/// Uses strftime-compatible format specifiers.
///
/// Supported format specifiers:
/// - %Y - Year with century (e.g., 2026)
/// - %m - Month as zero-padded decimal (01-12)
/// - %d - Day as zero-padded decimal (01-31)
/// - %H - Hour (24-hour) as zero-padded decimal (00-23)
/// - %M - Minute as zero-padded decimal (00-59)
/// - %S - Second as zero-padded decimal (00-59)
/// - %b - Abbreviated month name (Jan, Feb, etc.)
/// - %B - Full month name (January, February, etc.)
/// - %a - Abbreviated weekday name (Sun, Mon, etc.)
/// - %A - Full weekday name (Sunday, Monday, etc.)
/// - %j - Day of year as zero-padded decimal (001-366)
/// - %w - Weekday as decimal (0=Sunday, 6=Saturday)
/// - %% - Literal %
///
/// Example:
///   {{ strftime_now("%d %b %Y") }}  -> "01 Jan 2026"
///   {{ strftime_now("%Y-%m-%d %H:%M:%S") }}  -> "2026-01-01 12:30:45"
///
/// This is for HuggingFace template compatibility.
pub fn strftimeNowGlobal(
    allocator: std.mem.Allocator,
    args: []Value,
    ctx: ?*anyopaque,
    env: ?*anyopaque,
) GlobalError!Value {
    _ = ctx;
    _ = env;

    if (args.len < 1) {
        return error.InvalidArgument;
    }

    // Get format string from first argument
    const format = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeError,
    };

    // Get current timestamp
    const timestamp = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();

    // Format according to strftime spec
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            i += 1;
            switch (format[i]) {
                'd' => {
                    // Day of month (01-31)
                    const md = year_day.calculateMonthDay();
                    const day_str = try std.fmt.allocPrint(allocator, "{d:0>2}", .{md.day_index + 1});
                    defer allocator.free(day_str);
                    try buffer.appendSlice(allocator, day_str);
                },
                'm' => {
                    // Month (01-12)
                    const md = year_day.calculateMonthDay();
                    const month_str = try std.fmt.allocPrint(allocator, "{d:0>2}", .{md.month.numeric()});
                    defer allocator.free(month_str);
                    try buffer.appendSlice(allocator, month_str);
                },
                'Y' => {
                    // Year with century
                    const year_str = try std.fmt.allocPrint(allocator, "{d}", .{year_day.year});
                    defer allocator.free(year_str);
                    try buffer.appendSlice(allocator, year_str);
                },
                'y' => {
                    // Year without century (00-99)
                    const year_short = @mod(year_day.year, 100);
                    const year_str = try std.fmt.allocPrint(allocator, "{d:0>2}", .{year_short});
                    defer allocator.free(year_str);
                    try buffer.appendSlice(allocator, year_str);
                },
                'H' => {
                    // Hour (00-23)
                    const hour_str = try std.fmt.allocPrint(allocator, "{d:0>2}", .{day_seconds.getHoursIntoDay()});
                    defer allocator.free(hour_str);
                    try buffer.appendSlice(allocator, hour_str);
                },
                'I' => {
                    // Hour (01-12)
                    const hours = day_seconds.getHoursIntoDay();
                    const hour12 = if (hours == 0) 12 else if (hours > 12) hours - 12 else hours;
                    const hour_str = try std.fmt.allocPrint(allocator, "{d:0>2}", .{hour12});
                    defer allocator.free(hour_str);
                    try buffer.appendSlice(allocator, hour_str);
                },
                'M' => {
                    // Minute (00-59)
                    const min_str = try std.fmt.allocPrint(allocator, "{d:0>2}", .{day_seconds.getMinutesIntoHour()});
                    defer allocator.free(min_str);
                    try buffer.appendSlice(allocator, min_str);
                },
                'S' => {
                    // Second (00-59)
                    const sec_str = try std.fmt.allocPrint(allocator, "{d:0>2}", .{day_seconds.getSecondsIntoMinute()});
                    defer allocator.free(sec_str);
                    try buffer.appendSlice(allocator, sec_str);
                },
                'p' => {
                    // AM/PM
                    const hours = day_seconds.getHoursIntoDay();
                    try buffer.appendSlice(allocator, if (hours < 12) "AM" else "PM");
                },
                'b', 'h' => {
                    // Abbreviated month name
                    const md = year_day.calculateMonthDay();
                    try buffer.appendSlice(allocator, monthAbbrev(md.month));
                },
                'B' => {
                    // Full month name
                    const md = year_day.calculateMonthDay();
                    try buffer.appendSlice(allocator, monthFull(md.month));
                },
                'a' => {
                    // Abbreviated weekday name
                    // Calculate day of week: (days_since_epoch + 4) % 7, where 0=Sunday
                    // Unix epoch (Jan 1, 1970) was a Thursday (day 4)
                    const days: i32 = @intCast(epoch_day.day);
                    const dow: usize = @intCast(@mod(days + 4, 7));
                    try buffer.appendSlice(allocator, weekday_abbrevs_sunday[dow]);
                },
                'A' => {
                    // Full weekday name
                    const days: i32 = @intCast(epoch_day.day);
                    const dow: usize = @intCast(@mod(days + 4, 7));
                    try buffer.appendSlice(allocator, weekday_full_names_sunday[dow]);
                },
                'w' => {
                    // Weekday as decimal (0=Sunday, 6=Saturday)
                    const days: i32 = @intCast(epoch_day.day);
                    const dow = @mod(days + 4, 7);
                    const weekday_str = try std.fmt.allocPrint(allocator, "{d}", .{dow});
                    defer allocator.free(weekday_str);
                    try buffer.appendSlice(allocator, weekday_str);
                },
                'j' => {
                    // Day of year (001-366)
                    const doy_str = try std.fmt.allocPrint(allocator, "{d:0>3}", .{year_day.day + 1});
                    defer allocator.free(doy_str);
                    try buffer.appendSlice(allocator, doy_str);
                },
                '%' => {
                    // Literal %
                    try buffer.append(allocator, '%');
                },
                'n' => {
                    // Newline
                    try buffer.append(allocator, '\n');
                },
                't' => {
                    // Tab
                    try buffer.append(allocator, '\t');
                },
                else => {
                    // Unknown specifier - output as-is
                    try buffer.append(allocator, '%');
                    try buffer.append(allocator, format[i]);
                },
            }
        } else {
            try buffer.append(allocator, format[i]);
        }
        i += 1;
    }

    return Value{ .string = try buffer.toOwnedSlice(allocator) };
}

const month_abbrevs = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

const month_full_names = [_][]const u8{
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
};

// Sunday-indexed weekday arrays (0=Sunday, 6=Saturday) for strftime compatibility
const weekday_abbrevs_sunday = [_][]const u8{
    "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
};

const weekday_full_names_sunday = [_][]const u8{
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
};

fn monthAbbrev(month: std.time.epoch.Month) []const u8 {
    return month_abbrevs[month.numeric() - 1];
}

fn monthFull(month: std.time.epoch.Month) []const u8 {
    return month_full_names[month.numeric() - 1];
}

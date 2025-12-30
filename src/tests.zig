//! Jinja2-compatible Template Tests
//!
//! This module provides the test system for Jinja templates. Tests are used to check
//! properties of values using the `is` operator in templates.
//!
//! # Test Syntax
//!
//! ```jinja
//! {% if value is test_name %}...{% endif %}
//! {% if value is test_name(arg1, arg2) %}...{% endif %}
//! {% if value is not test_name %}...{% endif %}
//! ```
//!
//! # Built-in Tests
//!
//! ## Type Tests
//! - `string` - Is value a string?
//! - `number` - Is value a number (int or float)?
//! - `integer` - Is value an integer?
//! - `float` - Is value a float?
//! - `boolean` - Is value a boolean?
//! - `mapping` - Is value a dict/mapping?
//! - `sequence` - Is value a list/sequence?
//! - `iterable` - Can value be iterated?
//! - `callable` - Is value callable?
//!
//! ## Value Tests
//! - `defined` - Is value defined (not empty)?
//! - `undefined` - Is value undefined/empty?
//! - `none` - Is value null/none?
//! - `true` / `false` - Is value true/false?
//! - `empty` - Is value empty?
//!
//! ## Comparison Tests
//! - `equalto` / `eq` - Is value equal to argument?
//! - `ne` - Is value not equal to argument?
//! - `lt` / `le` / `gt` / `ge` - Numeric comparisons
//! - `sameas` - Is value same object as argument?
//!
//! ## String Tests
//! - `lower` - Is string all lowercase?
//! - `upper` - Is string all uppercase?
//! - `escaped` - Is string already escaped (Markup)?
//!
//! ## Number Tests
//! - `even` - Is number even?
//! - `odd` - Is number odd?
//! - `divisibleby` - Is number divisible by argument?
//!
//! ## Container Tests
//! - `in` - Is value in container?
//!
//! ## Environment Tests
//! - `filter` - Does filter exist in environment?
//! - `test` - Does test exist in environment?
//!
//! # Custom Tests
//!
//! ```zig
//! fn myTest(
//!     val: jinja.Value,
//!     args: []const jinja.Value,
//!     ctx: ?*jinja.context.Context,
//!     env: ?*jinja.Environment,
//! ) bool {
//!     // Test value and return bool
//!     return true;
//! }
//!
//! try env.addTest("mytest", myTest);
//! ```

const std = @import("std");
const context = @import("context.zig");
const value_mod = @import("value.zig");
const utils = @import("utils.zig");
const environment = @import("environment.zig");

/// Re-export Value type for convenience
pub const Value = value_mod.Value;

/// Test function signature
/// Takes value, args, optional context, optional environment, and returns boolean
///
/// Environment is passed based on `pass_arg` setting in Test definition:
/// - `.none` - No special arguments (default)
/// - `.context` - Pass current template context
/// - `.eval_context` - Pass evaluation context
/// - `.environment` - Pass environment reference
pub const TestFn = *const fn (value: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool;

/// Async test function signature
///
/// Currently uses the same signature as `TestFn` because Zig's async model
/// differs from Python's async/await. See `async_utils.zig` for details.
///
/// ## Python vs Zig Async
///
/// Python Jinja2:
/// ```python
/// @pass_environment
/// async def do_async_test(env, value, *args):
///     result = await some_async_check(value)
///     return result
/// ```
///
/// Zig (callback-based):
/// ```zig
/// // Use async_utils.executeAsyncTest for callback-based execution
/// async_utils.executeAsyncTest(test_fn, val, args, ctx, env, callback);
/// ```
///
/// For true async support, use the callback utilities in `async_utils.zig`.
pub const AsyncTestFn = TestFn;

/// Test definition
pub const Test = struct {
    name: []const u8,
    func: TestFn,
    /// Optional async test function (used when enable_async is true)
    async_func: ?AsyncTestFn = null,
    /// What argument should be passed to this test (context, eval_context, environment)
    pass_arg: utils.PassArg = .none,
    /// Whether this test is marked as internal (shouldn't appear in tracebacks)
    is_internal: bool = false,
    /// Whether this test supports async execution
    is_async: bool = false,

    const Self = @This();

    pub fn init(name: []const u8, func: TestFn) Self {
        return Self{
            .name = name,
            .func = func,
            .async_func = null,
            .pass_arg = .none,
            .is_internal = false,
            .is_async = false,
        };
    }

    /// Create an async test
    pub fn initAsync(name: []const u8, func: TestFn, async_func: AsyncTestFn) Self {
        return Self{
            .name = name,
            .func = func,
            .async_func = async_func,
            .pass_arg = .none,
            .is_internal = false,
            .is_async = true,
        };
    }

    /// Create a test with pass argument decorator
    pub fn withPassArg(name: []const u8, func: TestFn, pass_arg: utils.PassArg) Self {
        return Self{
            .name = name,
            .func = func,
            .async_func = null,
            .pass_arg = pass_arg,
            .is_internal = false,
            .is_async = false,
        };
    }

    /// Create a test marked as internal
    pub fn withInternal(name: []const u8, func: TestFn, is_internal: bool) Self {
        return Self{
            .name = name,
            .func = func,
            .async_func = null,
            .pass_arg = .none,
            .is_internal = is_internal,
            .is_async = false,
        };
    }
};

/// Compile-time interned map for O(1) builtin test lookup
/// This is a performance optimization for the most frequently used tests
pub const BuiltinTestMap = std.StaticStringMap(TestFn).initComptime(.{
    .{ "defined", BuiltinTests.defined },
    .{ "undefined", BuiltinTests.@"undefined" },
    .{ "equalto", BuiltinTests.equalto },
    .{ "eq", BuiltinTests.equalto }, // alias
    .{ "even", BuiltinTests.even },
    .{ "odd", BuiltinTests.odd },
    .{ "divisibleby", BuiltinTests.divisibleby },
    .{ "lower", BuiltinTests.lower },
    .{ "upper", BuiltinTests.upper },
    .{ "string", BuiltinTests.string },
    .{ "number", BuiltinTests.number },
    .{ "empty", BuiltinTests.empty },
    .{ "none", BuiltinTests.none },
    .{ "boolean", BuiltinTests.boolean },
    .{ "false", BuiltinTests.@"false" },
    .{ "true", BuiltinTests.@"true" },
    .{ "integer", BuiltinTests.integer },
    .{ "float", BuiltinTests.float },
    .{ "mapping", BuiltinTests.mapping },
    .{ "sequence", BuiltinTests.sequence },
    .{ "iterable", BuiltinTests.iterable },
    .{ "callable", BuiltinTests.callable },
    .{ "sameas", BuiltinTests.sameas },
    .{ "escaped", BuiltinTests.escaped },
    .{ "in", BuiltinTests.@"in" },
    .{ "ne", BuiltinTests.ne },
    .{ "lt", BuiltinTests.lt },
    .{ "le", BuiltinTests.le },
    .{ "gt", BuiltinTests.gt },
    .{ "ge", BuiltinTests.ge },
    .{ "filter", BuiltinTests.filter },
    .{ "test", BuiltinTests.@"test" },
});

/// Fast path for looking up builtin tests
/// Returns null if the test is not a builtin (requires dynamic lookup)
pub inline fn getBuiltinTest(name: []const u8) ?TestFn {
    return BuiltinTestMap.get(name);
}

/// Built-in tests
pub const BuiltinTests = struct {
    /// Check if value is defined (not empty)
    pub fn defined(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return val.length() > 0 and (val.isTruthy() catch false);
    }

    /// Check if value is undefined (empty)
    pub fn @"undefined"(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return val.length() == 0 or !(val.isTruthy() catch false);
    }

    /// Check if value equals another value
    pub fn equalto(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = ctx;
        _ = env;
        if (args.len == 0) {
            return false;
        }
        // Use proper value comparison
        return val.isEqual(args[0]) catch false;
    }

    /// Check if value is even (for numbers)
    pub fn even(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        const num = val.toInteger() orelse return false;
        return @rem(num, 2) == 0;
    }

    /// Check if value is odd (for numbers)
    pub fn odd(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        const num = val.toInteger() orelse return false;
        return @rem(num, 2) == 1;
    }

    /// Check if value is divisible by a number
    pub fn divisibleby(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = ctx;
        _ = env;
        if (args.len == 0) {
            return false;
        }
        const num = val.toInteger() orelse return false;
        const divisor = args[0].toInteger() orelse return false;
        if (divisor == 0) {
            return false;
        }
        return @rem(num, divisor) == 0;
    }

    /// Check if value is lowercase
    pub fn lower(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        const str = val.toString(std.heap.page_allocator) catch return false;
        defer std.heap.page_allocator.free(str);
        for (str) |c| {
            if (std.ascii.isUpper(c)) {
                return false;
            }
        }
        return true;
    }

    /// Check if value is uppercase
    pub fn upper(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        const str = val.toString(std.heap.page_allocator) catch return false;
        defer std.heap.page_allocator.free(str);
        for (str) |c| {
            if (std.ascii.isLower(c)) {
                return false;
            }
        }
        return true;
    }

    /// Check if value is a string
    pub fn string(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return switch (val) {
            .string => true,
            else => false,
        };
    }

    /// Check if value is a number
    pub fn number(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return switch (val) {
            .integer, .float => true,
            else => false,
        };
    }

    /// Check if value is empty
    pub fn empty(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return val.length() == 0 or !(val.isTruthy() catch false);
    }

    /// Check if value is none/null
    pub fn none(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return switch (val) {
            .null => true,
            .undefined => true,
            else => false,
        };
    }

    /// Check if value is boolean
    pub fn boolean(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return switch (val) {
            .boolean => true,
            else => false,
        };
    }

    /// Check if value is false
    pub fn @"false"(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return switch (val) {
            .boolean => |b| !b,
            else => false,
        };
    }

    /// Check if value is true
    pub fn @"true"(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return switch (val) {
            .boolean => |b| b,
            else => false,
        };
    }

    /// Check if value is integer
    pub fn integer(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return switch (val) {
            .integer => true,
            else => false,
        };
    }

    /// Check if value is float
    pub fn float(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return switch (val) {
            .float => true,
            else => false,
        };
    }

    /// Check if value is a mapping (dict)
    pub fn mapping(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return switch (val) {
            .dict => true,
            else => false,
        };
    }

    /// Check if value is a sequence (list)
    pub fn sequence(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return switch (val) {
            .list => true,
            else => false,
        };
    }

    /// Check if value is iterable (list, dict, or string)
    pub fn iterable(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        return switch (val) {
            .list, .dict, .string => true,
            else => false,
        };
    }

    /// Check if value is callable (function, macro, or callable object)
    pub fn callable(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;

        // Check if value is directly a callable type
        if (val.isCallable()) {
            return true;
        }

        // Check if value is a callable variant
        switch (val) {
            .callable => return true,
            .dict => |d| {
                // Check if dict has __call__ method (callable object pattern)
                if (d.map.get("__call__")) |_| {
                    return true;
                }
                // Check if it's a macro wrapper
                if (d.map.get("_macro")) |_| {
                    return true;
                }
                return false;
            },
            .string => |s| {
                // Check if value represents a macro (from context)
                if (ctx) |c| {
                    if (c.getMacro(s)) |_| {
                        return true;
                    }
                }

                // Check if value represents a callable global function
                if (env) |e| {
                    if (e.getGlobal(s)) |global_val| {
                        // Check if the global is itself callable
                        if (global_val.isCallable()) {
                            return true;
                        }
                        // Check if global is a callable value
                        if (global_val == .callable) {
                            return true;
                        }
                    }
                    // Check if it's a filter name (filters are callable)
                    if (e.getFilter(s)) |_| {
                        return true;
                    }
                    // Check if it's a test name (tests are callable)
                    if (e.getTest(s)) |_| {
                        return true;
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    /// Check if value is same as another (object identity)
    pub fn sameas(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = ctx;
        _ = env;
        if (args.len == 0) {
            return false;
        }
        // For now, use equality comparison
        // In full Jinja, this would check object identity
        return val.isEqual(args[0]) catch false;
    }

    /// Check if value is escaped (marked as safe HTML/XML)
    pub fn escaped(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;
        _ = env;
        // Check if value is Markup type (escaped/safe)
        return switch (val) {
            .markup => true,
            else => false,
        };
    }

    /// Check if value is in a sequence (test version of 'in' operator)
    pub fn in(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = ctx;
        _ = env;
        if (args.len == 0) {
            return false;
        }
        const container = args[0];
        return switch (container) {
            .list => |l| {
                for (l.items.items) |item| {
                    if (val.isEqual(item) catch false) {
                        return true;
                    }
                }
                return false;
            },
            .dict => |d| {
                const val_str = val.toString(std.heap.page_allocator) catch return false;
                defer std.heap.page_allocator.free(val_str);
                return d.map.contains(val_str);
            },
            .string => |s| {
                const val_str = val.toString(std.heap.page_allocator) catch return false;
                defer std.heap.page_allocator.free(val_str);
                return std.mem.indexOf(u8, s, val_str) != null;
            },
            else => false,
        };
    }

    /// Check if a filter exists by name
    /// Requires environment access
    pub fn filter(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;

        if (env == null) {
            return false;
        }

        // Convert value to string (filter name)
        const filter_name = val.toString(std.heap.page_allocator) catch return false;
        defer std.heap.page_allocator.free(filter_name);

        // Check if filter exists in environment
        return env.?.getFilter(filter_name) != null;
    }

    /// Check if a test exists by name
    /// Requires environment access
    pub fn @"test"(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = args;
        _ = ctx;

        if (env == null) {
            return false;
        }

        // Convert value to string (test name)
        const test_name = val.toString(std.heap.page_allocator) catch return false;
        defer std.heap.page_allocator.free(test_name);

        // Check if test exists in environment
        return env.?.getTest(test_name) != null;
    }

    // ============================================================================
    // Comparison Tests (Jinja2 operator aliases)
    // ============================================================================

    /// Less than test (matches Jinja2 operator.lt)
    /// Usage: {{ 1 is lt 2 }} -> True
    /// Usage: {{ 1 is lt(2) }} -> True
    /// Usage: {{ 1 is lessthan 2 }} -> True
    pub fn lt(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = ctx;
        _ = env;
        if (args.len == 0) return false;

        // Try integer comparison first
        const left_int = val.toInteger();
        const right_int = args[0].toInteger();
        if (left_int != null and right_int != null) {
            return left_int.? < right_int.?;
        }

        // Fall back to float comparison (more general)
        const left_float = val.toFloat();
        const right_float = args[0].toFloat();
        if (left_float != null and right_float != null) {
            return left_float.? < right_float.?;
        }

        // String comparison
        switch (val) {
            .string => |left_str| {
                switch (args[0]) {
                    .string => |right_str| {
                        return std.mem.order(u8, left_str, right_str) == .lt;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    /// Less than or equal test (matches Jinja2 operator.le)
    /// Usage: {{ 2 is le 2 }} -> True
    /// Usage: {{ 2 is le(2) }} -> True
    pub fn le(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = ctx;
        _ = env;
        if (args.len == 0) return false;

        // Try integer comparison first
        const left_int = val.toInteger();
        const right_int = args[0].toInteger();
        if (left_int != null and right_int != null) {
            return left_int.? <= right_int.?;
        }

        // Fall back to float comparison
        const left_float = val.toFloat();
        const right_float = args[0].toFloat();
        if (left_float != null and right_float != null) {
            return left_float.? <= right_float.?;
        }

        // String comparison
        switch (val) {
            .string => |left_str| {
                switch (args[0]) {
                    .string => |right_str| {
                        const order = std.mem.order(u8, left_str, right_str);
                        return order == .lt or order == .eq;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    /// Greater than test (matches Jinja2 operator.gt)
    /// Usage: {{ 2 is gt 1 }} -> True
    /// Usage: {{ 2 is gt(1) }} -> True
    /// Usage: {{ 2 is greaterthan 1 }} -> True
    pub fn gt(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = ctx;
        _ = env;
        if (args.len == 0) return false;

        // Try integer comparison first
        const left_int = val.toInteger();
        const right_int = args[0].toInteger();
        if (left_int != null and right_int != null) {
            return left_int.? > right_int.?;
        }

        // Fall back to float comparison
        const left_float = val.toFloat();
        const right_float = args[0].toFloat();
        if (left_float != null and right_float != null) {
            return left_float.? > right_float.?;
        }

        // String comparison
        switch (val) {
            .string => |left_str| {
                switch (args[0]) {
                    .string => |right_str| {
                        return std.mem.order(u8, left_str, right_str) == .gt;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    /// Greater than or equal test (matches Jinja2 operator.ge)
    /// Usage: {{ 2 is ge 2 }} -> True
    /// Usage: {{ 2 is ge(2) }} -> True
    pub fn ge(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = ctx;
        _ = env;
        if (args.len == 0) return false;

        // Try integer comparison first
        const left_int = val.toInteger();
        const right_int = args[0].toInteger();
        if (left_int != null and right_int != null) {
            return left_int.? >= right_int.?;
        }

        // Fall back to float comparison
        const left_float = val.toFloat();
        const right_float = args[0].toFloat();
        if (left_float != null and right_float != null) {
            return left_float.? >= right_float.?;
        }

        // String comparison
        switch (val) {
            .string => |left_str| {
                switch (args[0]) {
                    .string => |right_str| {
                        const order = std.mem.order(u8, left_str, right_str);
                        return order == .gt or order == .eq;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    /// Not equal test (matches Jinja2 operator.ne)
    /// Usage: {{ 1 is ne 2 }} -> True
    /// Usage: {{ 1 is ne(2) }} -> True
    pub fn ne(val: Value, args: []const Value, ctx: ?*context.Context, env: ?*environment.Environment) bool {
        _ = ctx;
        _ = env;
        if (args.len == 0) return false;
        return !(val.isEqual(args[0]) catch false);
    }
};

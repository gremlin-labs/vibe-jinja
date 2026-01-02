//! Jinja2-compatible Template Filters
//!
//! This module provides the filter system for Jinja templates. Filters are functions
//! that transform values in templates using the pipe (`|`) operator.
//!
//! # Filter Syntax
//!
//! ```jinja
//! {{ value | filter_name }}
//! {{ value | filter_name(arg1, arg2) }}
//! {{ value | filter1 | filter2 | filter3 }}
//! ```
//!
//! # Built-in Filters
//!
//! ## String Filters
//! - `capitalize` - Capitalize first character
//! - `lower` - Convert to lowercase
//! - `upper` - Convert to uppercase
//! - `title` - Titlecase string
//! - `trim` / `lstrip` / `rstrip` - Remove whitespace
//! - `escape` - HTML escape
//! - `truncate` - Truncate to length
//! - `wordwrap` - Wrap text at width
//! - `center` - Center in width
//! - `indent` - Add indentation
//! - `replace` - Replace substring
//! - `striptags` - Remove HTML tags
//! - `urlencode` - URL encode
//! - `format` - String formatting
//!
//! ## List/Sequence Filters
//! - `first` / `last` - Get first/last element
//! - `join` - Join with separator
//! - `sort` - Sort items
//! - `reverse` - Reverse order
//! - `unique` - Remove duplicates
//! - `batch` - Group into batches
//! - `slice` - Get slice of items
//! - `map` - Apply function to items
//! - `select` / `reject` - Filter items
//! - `selectattr` / `rejectattr` - Filter by attribute
//!
//! ## Number Filters
//! - `abs` - Absolute value
//! - `int` / `float` - Convert to number
//! - `round` - Round to precision
//! - `min` / `max` - Minimum/maximum
//! - `sum` - Sum of items
//!
//! ## Dict Filters
//! - `dictsort` - Sort dict by key/value
//! - `items` - Get key-value pairs
//!
//! ## Other Filters
//! - `default` - Default if undefined/empty
//! - `length` / `count` - Get length
//! - `safe` - Mark as already escaped
//! - `tojson` - Convert to JSON
//! - `pprint` - Pretty print
//! - `random` - Random element
//! - `filesizeformat` - Format file size
//! - `groupby` - Group items by attribute
//!
//! # Custom Filters
//!
//! ```zig
//! fn myFilter(
//!     allocator: std.mem.Allocator,
//!     val: jinja.Value,
//!     args: []jinja.Value,
//!     ctx: ?*jinja.context.Context,
//!     env: ?*jinja.Environment,
//! ) !jinja.Value {
//!     // Transform value
//!     return jinja.Value{ .string = try allocator.dupe(u8, "result") };
//! }
//!
//! try env.addFilter("myfilter", myFilter);
//! ```

const std = @import("std");
const context = @import("context.zig");
const exceptions = @import("exceptions.zig");
const value_mod = @import("value.zig");
const environment = @import("environment.zig");
const utils = @import("utils.zig");

/// Re-export Value type for convenience
pub const Value = value_mod.Value;

/// Error type for filter functions
pub const FilterError = exceptions.TemplateError || std.mem.Allocator.Error || error{ Overflow, InvalidCharacter };

/// Filter function signature
/// Takes value, args, kwargs, optional context, optional environment, and returns filtered value
///
/// Error set includes:
/// - `TemplateError` - template-level errors (invalid argument, etc.)
/// - `std.mem.Allocator.Error` - memory allocation failures
/// - `error.Overflow` / `error.InvalidCharacter` - numeric conversion errors
///
/// # Arguments
/// - `allocator` - Memory allocator for the filter
/// - `val` - The value being filtered (left side of |)
/// - `args` - Positional arguments passed to the filter
/// - `kwargs` - Keyword arguments passed to the filter (e.g., tojson(indent=4))
/// - `ctx` - Optional template context
/// - `env` - Optional environment
pub const FilterFn = *const fn (
    allocator: std.mem.Allocator,
    val: Value,
    args: []Value,
    kwargs: *const std.StringHashMap(Value),
    ctx: ?*context.Context,
    env: ?*environment.Environment,
) FilterError!Value;

/// Async filter function signature
///
/// Currently uses the same signature as `FilterFn` because Zig's async model
/// differs from Python's async/await. See `async_utils.zig` for details.
///
/// ## Python vs Zig Async
///
/// Python Jinja2:
/// ```python
/// @pass_environment
/// async def do_async_filter(env, value, *args):
///     result = await some_async_operation(value)
///     return result
/// ```
///
/// Zig (callback-based):
/// ```zig
/// // Use async_utils.executeAsyncFilter for callback-based execution
/// async_utils.executeAsyncFilter(filter, allocator, val, args, ctx, env, callback);
/// ```
///
/// For true async support, use the callback utilities in `async_utils.zig`.
pub const AsyncFilterFn = FilterFn;

/// Filter definition
pub const Filter = struct {
    name: []const u8,
    func: FilterFn,
    /// Optional async filter function (used when enable_async is true)
    async_func: ?AsyncFilterFn = null,
    /// What argument should be passed to this filter (context, eval_context, environment)
    pass_arg: utils.PassArg = .none,
    /// Whether this filter is marked as internal (shouldn't appear in tracebacks)
    is_internal: bool = false,
    /// Whether this filter supports async execution
    is_async: bool = false,

    const Self = @This();

    pub fn init(name: []const u8, func: FilterFn) Self {
        return Self{
            .name = name,
            .func = func,
            .async_func = null,
            .pass_arg = .none,
            .is_internal = false,
            .is_async = false,
        };
    }

    /// Create an async filter
    pub fn initAsync(name: []const u8, func: FilterFn, async_func: AsyncFilterFn) Self {
        return Self{
            .name = name,
            .func = func,
            .async_func = async_func,
            .pass_arg = .none,
            .is_internal = false,
            .is_async = true,
        };
    }

    /// Create a filter with pass argument decorator
    pub fn withPassArg(name: []const u8, func: FilterFn, pass_arg: utils.PassArg) Self {
        return Self{
            .name = name,
            .func = func,
            .async_func = null,
            .pass_arg = pass_arg,
            .is_internal = false,
            .is_async = false,
        };
    }

    /// Create a filter marked as internal
    pub fn withInternal(name: []const u8, func: FilterFn, is_internal: bool) Self {
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

/// Compile-time interned map for O(1) builtin filter lookup
/// This is a performance optimization for the most frequently used filters
pub const BuiltinFilterMap = std.StaticStringMap(FilterFn).initComptime(.{
    .{ "abs", BuiltinFilters.abs },
    .{ "capitalize", BuiltinFilters.capitalize },
    .{ "default", BuiltinFilters.default },
    .{ "d", BuiltinFilters.default }, // alias
    .{ "lower", BuiltinFilters.lower },
    .{ "upper", BuiltinFilters.upper },
    .{ "length", BuiltinFilters.length },
    .{ "reverse", BuiltinFilters.reverse },
    .{ "replace", BuiltinFilters.replace },
    .{ "trim", BuiltinFilters.trim },
    .{ "lstrip", BuiltinFilters.lstrip },
    .{ "rstrip", BuiltinFilters.rstrip },
    .{ "attr", BuiltinFilters.attr },
    .{ "center", BuiltinFilters.center },
    .{ "escape", BuiltinFilters.escape },
    .{ "e", BuiltinFilters.escape }, // alias
    .{ "forceescape", BuiltinFilters.forceescape },
    .{ "format", BuiltinFilters.format },
    .{ "indent", BuiltinFilters.indent },
    .{ "join", BuiltinFilters.join },
    .{ "striptags", BuiltinFilters.striptags },
    .{ "title", BuiltinFilters.title },
    .{ "truncate", BuiltinFilters.truncate },
    .{ "urlencode", BuiltinFilters.urlencode },
    .{ "urlize", BuiltinFilters.urlize },
    .{ "wordcount", BuiltinFilters.wordcount },
    .{ "wordwrap", BuiltinFilters.wordwrap },
    .{ "xmlattr", BuiltinFilters.xmlattr },
    .{ "batch", BuiltinFilters.batch },
    .{ "first", BuiltinFilters.first },
    .{ "last", BuiltinFilters.last },
    .{ "list", BuiltinFilters.list },
    .{ "map", BuiltinFilters.map },
    .{ "reject", BuiltinFilters.reject },
    .{ "rejectattr", BuiltinFilters.rejectattr },
    .{ "select", BuiltinFilters.select },
    .{ "selectattr", BuiltinFilters.selectattr },
    .{ "slice", BuiltinFilters.slice },
    .{ "sort", BuiltinFilters.sort },
    .{ "sum", BuiltinFilters.sum },
    .{ "unique", BuiltinFilters.unique },
    .{ "float", BuiltinFilters.float },
    .{ "int", BuiltinFilters.int },
    .{ "round", BuiltinFilters.round },
    .{ "min", BuiltinFilters.min },
    .{ "max", BuiltinFilters.max },
    .{ "dictsort", BuiltinFilters.dictsort },
    .{ "items", BuiltinFilters.items },
    .{ "count", BuiltinFilters.count },
    .{ "filesizeformat", BuiltinFilters.filesizeformat },
    .{ "groupby", BuiltinFilters.groupby },
    .{ "pprint", BuiltinFilters.pprint },
    .{ "random", BuiltinFilters.random },
    .{ "safe", BuiltinFilters.safe },
    .{ "string", BuiltinFilters.string },
    .{ "tojson", BuiltinFilters.tojson },
    .{ "mark_safe", BuiltinFilters.mark_safe },
    .{ "mark_unsafe", BuiltinFilters.mark_unsafe },
});

/// Fast path for looking up builtin filters
/// Returns null if the filter is not a builtin (requires dynamic lookup)
pub inline fn getBuiltinFilter(name: []const u8) ?FilterFn {
    return BuiltinFilterMap.get(name);
}

/// Built-in filters
pub const BuiltinFilters = struct {
    /// Return the absolute value of a number
    pub fn abs(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        // Check if it's a float first to preserve float type
        if (val == .float) {
            const float_val = val.float;
            const abs_val = if (float_val < 0) -float_val else float_val;
            return Value{ .float = abs_val };
        }

        // Check if it's an integer
        if (val == .integer) {
            const num = val.integer;
            const abs_val = if (num < 0) -num else num;
            return Value{ .integer = abs_val };
        }

        // Try to convert to number
        const num = val.toInteger() orelse {
            const float_val = val.toFloat() orelse {
                // If not a number, return as-is
                return val;
            };
            const abs_val = if (float_val < 0) -float_val else float_val;
            return Value{ .float = abs_val };
        };

        const abs_val = if (num < 0) -num else num;
        return Value{ .integer = abs_val };
    }

    /// Capitalize the first character of a string
    pub fn capitalize(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        if (str.len == 0) {
            return Value{ .string = try allocator.dupe(u8, "") };
        }

        var result = try allocator.alloc(u8, str.len);
        errdefer allocator.free(result);

        result[0] = std.ascii.toUpper(str[0]);
        for (str[1..], 1..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }

        return Value{ .string = result };
    }

    /// Return default value if value is empty/undefined
    pub fn default(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        // If value is empty/undefined/null, use default
        if (val.length() == 0 or !(val.isTruthy() catch false)) {
            if (args.len > 0) {
                // Return a deep copy to avoid ownership issues
                return try args[0].deepCopy(allocator);
            }
            return Value{ .string = try allocator.dupe(u8, "") };
        }

        // Return a deep copy of the original value to avoid ownership issues
        return try val.deepCopy(allocator);
    }

    /// Convert string to lowercase - Phase 4 optimized
    pub fn lower(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);

        // FAST PATH: Check if already lowercase
        var needs_change = false;
        for (str) |c| {
            if (std.ascii.isUpper(c)) {
                needs_change = true;
                break;
            }
        }

        if (!needs_change) {
            // Already lowercase - return as-is
            return Value{ .string = str };
        }

        // SLOW PATH: Allocate and convert
        defer allocator.free(str);
        const result = try allocator.alloc(u8, str.len);
        for (str, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }

        return Value{ .string = result };
    }

    /// Convert string to uppercase - Phase 4 optimized
    pub fn upper(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);

        // FAST PATH: Check if already uppercase
        var needs_change = false;
        for (str) |c| {
            if (std.ascii.isLower(c)) {
                needs_change = true;
                break;
            }
        }

        if (!needs_change) {
            // Already uppercase - return as-is
            return Value{ .string = str };
        }

        // SLOW PATH: Allocate and convert
        defer allocator.free(str);
        const result = try allocator.alloc(u8, str.len);
        for (str, 0..) |c, i| {
            result[i] = std.ascii.toUpper(c);
        }

        return Value{ .string = result };
    }

    /// Return length of string or list
    pub fn length(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const len = val.length();
        return Value{ .integer = @intCast(len) };
    }

    /// Reverse a string
    pub fn reverse(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        var result = try allocator.alloc(u8, str.len);
        errdefer allocator.free(result);

        for (str, 0..) |c, i| {
            result[str.len - 1 - i] = c;
        }

        return Value{ .string = result };
    }

    /// Replace occurrences of old with new
    pub fn replace(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        if (args.len < 2) {
            return val;
        }

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const old_str_val = try args[0].toString(allocator);
        defer allocator.free(old_str_val);

        const new_str_val = try args[1].toString(allocator);
        defer allocator.free(new_str_val);

        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        var i: usize = 0;
        while (i < str.len) {
            if (i + old_str_val.len <= str.len and std.mem.eql(u8, str[i .. i + old_str_val.len], old_str_val)) {
                try result.appendSlice(allocator, new_str_val);
                i += old_str_val.len;
            } else {
                try result.append(allocator, str[i]);
                i += 1;
            }
        }

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Strip whitespace from both ends
    pub fn trim(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const trimmed = std.mem.trim(u8, str, " \t\n\r");
        return Value{ .string = try allocator.dupe(u8, trimmed) };
    }

    /// Strip whitespace from left
    pub fn lstrip(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const trimmed = std.mem.trimLeft(u8, str, " \t\n\r");
        return Value{ .string = try allocator.dupe(u8, trimmed) };
    }

    /// Strip whitespace from right
    pub fn rstrip(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const trimmed = std.mem.trimRight(u8, str, " \t\n\r");
        return Value{ .string = try allocator.dupe(u8, trimmed) };
    }

    // ============================================================================
    // String Filters (Additional)
    // ============================================================================

    /// Get attribute from object (for dicts)
    pub fn attr(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        if (args.len == 0) {
            return val;
        }

        const attr_name_val = try args[0].toString(allocator);
        defer allocator.free(attr_name_val);

        return switch (val) {
            .dict => |d| {
                if (d.get(attr_name_val)) |attr_val| {
                    return attr_val;
                }
                return Value{ .null = {} };
            },
            else => Value{ .null = {} },
        };
    }

    /// Center string with padding
    pub fn center(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const width = if (args.len > 0) (args[0].toInteger() orelse @as(i64, @intCast(str.len))) else @as(i64, @intCast(str.len));
        const fillchar = if (args.len > 1) (try args[1].toString(allocator))[0] else ' ';
        if (args.len > 1) allocator.free(try args[1].toString(allocator));

        if (width <= @as(i64, @intCast(str.len))) {
            return Value{ .string = try allocator.dupe(u8, str) };
        }

        const padding = @as(usize, @intCast(@divTrunc(width - @as(i64, @intCast(str.len)), 2)));
        const total_len = @as(usize, @intCast(width));

        var result = try allocator.alloc(u8, total_len);
        errdefer allocator.free(result);

        // Left padding
        for (0..padding) |i| {
            result[i] = fillchar;
        }

        // String content
        for (str, padding..) |c, i| {
            result[i] = c;
        }

        // Right padding
        for (padding + str.len..total_len) |i| {
            result[i] = fillchar;
        }

        return Value{ .string = result };
    }

    /// HTML escape - Phase 4 optimized with fast path
    pub fn escape(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);

        // FAST PATH: Check if any escaping is needed
        // This avoids allocation for strings with no special characters
        var needs_escape = false;
        for (str) |c| {
            if (c == '&' or c == '<' or c == '>' or c == '"' or c == '\'') {
                needs_escape = true;
                break;
            }
        }

        if (!needs_escape) {
            // No escaping needed - return as-is (already allocated by toString)
            return Value{ .string = str };
        }

        // SLOW PATH: Actual escaping needed
        defer allocator.free(str);

        // Pre-allocate with worst-case estimate (each char could become 6 chars)
        var result = try std.ArrayList(u8).initCapacity(allocator, str.len + str.len / 2);
        errdefer result.deinit(allocator);

        for (str) |c| {
            switch (c) {
                '&' => try result.appendSlice(allocator, "&amp;"),
                '<' => try result.appendSlice(allocator, "&lt;"),
                '>' => try result.appendSlice(allocator, "&gt;"),
                '"' => try result.appendSlice(allocator, "&quot;"),
                '\'' => try result.appendSlice(allocator, "&#x27;"),
                else => try result.append(allocator, c),
            }
        }

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Force HTML escape (same as escape for now)
    pub fn forceescape(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        return escape(allocator, val, args, kwargs, ctx, env);
    }

    /// String formatting (simple version - supports {} placeholders)
    pub fn format(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const format_str = try val.toString(allocator);
        defer allocator.free(format_str);

        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        var arg_index: usize = 0;
        var i: usize = 0;

        while (i < format_str.len) {
            if (i + 1 < format_str.len and format_str[i] == '{' and format_str[i + 1] == '}') {
                if (arg_index < args.len) {
                    const arg_str = try args[arg_index].toString(allocator);
                    defer allocator.free(arg_str);
                    try result.appendSlice(allocator, arg_str);
                    arg_index += 1;
                }
                i += 2;
            } else {
                try result.append(allocator, format_str[i]);
                i += 1;
            }
        }

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Indent lines with prefix
    pub fn indent(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const prefix_str = if (args.len > 0) (try args[0].toString(allocator)) else "    ";
        defer if (args.len > 0) allocator.free(prefix_str);
        const prefix = if (args.len > 0) prefix_str else "    ";

        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        var line_start: usize = 0;
        var is_first_line = true;

        for (str, 0..) |c, i| {
            if (c == '\n') {
                if (!is_first_line) {
                    try result.appendSlice(allocator, prefix);
                }
                try result.appendSlice(allocator, str[line_start .. i + 1]);
                line_start = i + 1;
                is_first_line = false;
            }
        }

        // Last line
        if (line_start < str.len) {
            if (!is_first_line) {
                try result.appendSlice(allocator, prefix);
            }
            try result.appendSlice(allocator, str[line_start..]);
        }

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Join list items with separator
    pub fn join(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const separator_str = if (args.len > 0) (try args[0].toString(allocator)) else "";
        defer if (args.len > 0) allocator.free(separator_str);
        const separator = if (args.len > 0) separator_str else "";

        return switch (val) {
            .list => |l| {
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);

                for (l.items.items, 0..) |item, i| {
                    if (i > 0) {
                        try result.appendSlice(allocator, separator);
                    }
                    const item_str = try item.toString(allocator);
                    defer allocator.free(item_str);
                    try result.appendSlice(allocator, item_str);
                }

                return Value{ .string = try result.toOwnedSlice(allocator) };
            },
            else => {
                const str = try val.toString(allocator);
                defer allocator.free(str);
                return Value{ .string = try allocator.dupe(u8, str) };
            },
        };
    }

    /// Strip HTML tags
    pub fn striptags(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        var i: usize = 0;
        while (i < str.len) {
            if (i < str.len and str[i] == '<') {
                // Skip until closing >
                while (i < str.len and str[i] != '>') {
                    i += 1;
                }
                if (i < str.len) i += 1; // Skip the >
            } else {
                try result.append(allocator, str[i]);
                i += 1;
            }
        }

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Title case string
    pub fn title(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        if (str.len == 0) {
            return Value{ .string = try allocator.dupe(u8, "") };
        }

        var result = try allocator.alloc(u8, str.len);
        errdefer allocator.free(result);

        var prev_was_space = true;
        for (str, 0..) |c, i| {
            if (std.ascii.isWhitespace(c)) {
                result[i] = c;
                prev_was_space = true;
            } else if (prev_was_space) {
                result[i] = std.ascii.toUpper(c);
                prev_was_space = false;
            } else {
                result[i] = std.ascii.toLower(c);
            }
        }

        return Value{ .string = result };
    }

    /// Truncate string to length
    pub fn truncate(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const max_length = if (args.len > 0) (args[0].toInteger() orelse @as(i64, @intCast(str.len))) else @as(i64, @intCast(str.len));
        const killwords = if (args.len > 1) (args[1].toBoolean() catch false) else false;
        const end_str_val = if (args.len > 2) (try args[2].toString(allocator)) else "...";
        defer if (args.len > 2) allocator.free(end_str_val);
        const end_str = if (args.len > 2) end_str_val else "...";

        if (@as(i64, @intCast(str.len)) <= max_length) {
            return Value{ .string = try allocator.dupe(u8, str) };
        }

        const trunc_len = @as(usize, @intCast(max_length - @as(i64, @intCast(end_str.len))));

        if (killwords or trunc_len == 0) {
            var result = try allocator.alloc(u8, trunc_len + end_str.len);
            errdefer allocator.free(result);
            @memcpy(result[0..trunc_len], str[0..trunc_len]);
            @memcpy(result[trunc_len..], end_str);
            return Value{ .string = result };
        }

        // Find last space before truncation point
        var last_space: usize = trunc_len;
        while (last_space > 0 and str[last_space - 1] != ' ') {
            last_space -= 1;
        }

        if (last_space == 0) {
            last_space = trunc_len;
        }

        var result = try allocator.alloc(u8, last_space + end_str.len);
        errdefer allocator.free(result);
        @memcpy(result[0..last_space], str[0..last_space]);
        @memcpy(result[last_space..], end_str);

        return Value{ .string = result };
    }

    /// URL encode
    pub fn urlencode(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        for (str) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try result.append(allocator, c);
            } else {
                const hex = try std.fmt.allocPrint(allocator, "%{X:0>2}", .{c});
                defer allocator.free(hex);
                try result.append(allocator, '%');
                try result.appendSlice(allocator, hex);
            }
        }

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Convert URLs to links (simplified)
    pub fn urlize(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        // Simple URL detection - just wrap URLs in <a> tags
        // This is a simplified version
        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        var i: usize = 0;
        while (i < str.len) {
            // Check for http:// or https://
            if (i + 7 < str.len and std.mem.eql(u8, str[i .. i + 7], "http://")) {
                const url_start = i;
                while (i < str.len and !std.ascii.isWhitespace(str[i])) {
                    i += 1;
                }
                const url = str[url_start..i];
                const url_str = try std.fmt.allocPrint(allocator, "<a href=\"{s}\">{s}</a>", .{ url, url });
                defer allocator.free(url_str);
                try result.appendSlice(allocator, url_str);
            } else if (i + 8 < str.len and std.mem.eql(u8, str[i .. i + 8], "https://")) {
                const url_start = i;
                while (i < str.len and !std.ascii.isWhitespace(str[i])) {
                    i += 1;
                }
                const url = str[url_start..i];
                const url_str = try std.fmt.allocPrint(allocator, "<a href=\"{s}\">{s}</a>", .{ url, url });
                defer allocator.free(url_str);
                try result.appendSlice(allocator, url_str);
            } else {
                try result.append(allocator, str[i]);
                i += 1;
            }
        }

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Count words in string
    pub fn wordcount(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(std.heap.page_allocator);
        defer std.heap.page_allocator.free(str);

        var word_count: usize = 0;
        var in_word = false;

        for (str) |c| {
            if (std.ascii.isWhitespace(c)) {
                in_word = false;
            } else {
                if (!in_word) {
                    word_count += 1;
                    in_word = true;
                }
            }
        }

        return Value{ .integer = @intCast(word_count) };
    }

    /// Word wrap text
    pub fn wordwrap(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const width = if (args.len > 0) (args[0].toInteger() orelse 79) else 79;
        _ = if (args.len > 1) (args[1].toBoolean() catch true) else true; // break_long_words - not fully implemented yet

        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        var line_len: usize = 0;
        var word_start: usize = 0;
        var i: usize = 0;

        while (i < str.len) {
            if (str[i] == '\n') {
                if (word_start < i) {
                    try result.appendSlice(allocator, str[word_start..i]);
                }
                try result.append(allocator, '\n');
                line_len = 0;
                word_start = i + 1;
                i += 1;
            } else if (std.ascii.isWhitespace(str[i])) {
                if (word_start < i) {
                    const word = str[word_start..i];
                    if (line_len + word.len > @as(usize, @intCast(width))) {
                        if (line_len > 0) {
                            try result.append(allocator, '\n');
                            line_len = 0;
                        }
                    } else if (line_len > 0) {
                        try result.append(allocator, ' ');
                        line_len += 1;
                    }
                    try result.appendSlice(allocator, word);
                    line_len += word.len;
                }
                word_start = i + 1;
                i += 1;
            } else {
                i += 1;
            }
        }

        // Last word
        if (word_start < str.len) {
            const word = str[word_start..];
            if (line_len + word.len > @as(usize, @intCast(width))) {
                if (line_len > 0) {
                    try result.append(allocator, '\n');
                }
            } else if (line_len > 0) {
                try result.append(allocator, ' ');
            }
            try result.appendSlice(allocator, word);
        }

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Format as XML attributes
    pub fn xmlattr(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .dict => |d| {
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);

                var iter = d.map.iterator();
                var is_first_entry = true;
                while (iter.next()) |entry| {
                    if (!is_first_entry) {
                        try result.append(allocator, ' ');
                    }
                    const key = entry.key_ptr.*;
                    const val_str = try entry.value_ptr.*.toString(allocator);
                    defer allocator.free(val_str);

                    // Escape XML special chars in value
                    var escaped_val = std.ArrayList(u8){};
                    defer escaped_val.deinit(allocator);
                    for (val_str) |c| {
                        switch (c) {
                            '&' => try escaped_val.appendSlice(allocator, "&amp;"),
                            '<' => try escaped_val.appendSlice(allocator, "&lt;"),
                            '>' => try escaped_val.appendSlice(allocator, "&gt;"),
                            '"' => try escaped_val.appendSlice(allocator, "&quot;"),
                            else => try escaped_val.append(allocator, c),
                        }
                    }

                    const attr_str = try std.fmt.allocPrint(allocator, "{s}=\"{s}\"", .{ key, try escaped_val.toOwnedSlice(allocator) });
                    defer allocator.free(attr_str);
                    try result.appendSlice(allocator, attr_str);
                    is_first_entry = false;
                }

                return Value{ .string = try result.toOwnedSlice(allocator) };
            },
            else => Value{ .string = try allocator.dupe(u8, "") },
        };
    }

    // ============================================================================
    // List/Sequence Filters
    // ============================================================================

    /// Batch items into groups
    pub fn batch(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const batch_size = if (args.len > 0) (args[0].toInteger() orelse 1) else 1;
        const fill_with = if (args.len > 1) args[1] else Value{ .null = {} };

        return switch (val) {
            .list => |l| {
                const batch_list = try allocator.create(value_mod.List);
                batch_list.* = value_mod.List.init(allocator);
                errdefer batch_list.deinit(allocator);

                var i: usize = 0;
                while (i < l.items.items.len) {
                    const batch_item_list = try allocator.create(value_mod.List);
                    batch_item_list.* = value_mod.List.init(allocator);

                    const end = @min(i + @as(usize, @intCast(batch_size)), l.items.items.len);
                    for (l.items.items[i..end]) |item| {
                        try batch_item_list.append(item);
                    }

                    // Fill with fill_with if needed
                    while (batch_item_list.items.items.len < @as(usize, @intCast(batch_size))) {
                        try batch_item_list.append(fill_with);
                    }

                    try batch_list.append(Value{ .list = batch_item_list });
                    i += @as(usize, @intCast(batch_size));
                }

                return Value{ .list = batch_list };
            },
            else => {
                // Convert to list first
                const single_list = try allocator.create(value_mod.List);
                single_list.* = value_mod.List.init(allocator);
                try single_list.append(val);
                return Value{ .list = single_list };
            },
        };
    }

    /// Get first item
    pub fn first(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => |l| {
                if (l.items.items.len > 0) {
                    return l.items.items[0];
                }
                return Value{ .null = {} };
            },
            .string => |s| {
                if (s.len > 0) {
                    var result = try std.heap.page_allocator.alloc(u8, 1);
                    result[0] = s[0];
                    return Value{ .string = result };
                }
                return Value{ .null = {} };
            },
            else => Value{ .null = {} },
        };
    }

    /// Get last item
    pub fn last(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => |l| {
                if (l.items.items.len > 0) {
                    return l.items.items[l.items.items.len - 1];
                }
                return Value{ .null = {} };
            },
            .string => |s| {
                if (s.len > 0) {
                    var result = try std.heap.page_allocator.alloc(u8, 1);
                    result[0] = s[s.len - 1];
                    return Value{ .string = result };
                }
                return Value{ .null = {} };
            },
            else => Value{ .null = {} },
        };
    }

    /// Convert to list
    pub fn list(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => val, // Already a list
            .string => |s| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);
                for (s) |c| {
                    var char_str = try allocator.alloc(u8, 1);
                    char_str[0] = c;
                    try result_list.append(Value{ .string = char_str });
                }
                return Value{ .list = result_list };
            },
            else => {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);
                try result_list.append(val);
                return Value{ .list = result_list };
            },
        };
    }

    /// Map function over items (simplified - just converts to string for now)
    pub fn map(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const attr_name = if (args.len > 0) (try args[0].toString(allocator)) else "";
        defer if (args.len > 0) allocator.free(attr_name);

        return switch (val) {
            .list => |l| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                for (l.items.items) |item| {
                    if (args.len > 0) {
                        // Get attribute
                        const mapped_val = switch (item) {
                            .dict => |d| d.get(attr_name) orelse Value{ .null = {} },
                            else => item,
                        };
                        try result_list.append(mapped_val);
                    } else {
                        // Just convert to string
                        const item_str = try item.toString(allocator);
                        defer allocator.free(item_str);
                        try result_list.append(Value{ .string = try allocator.dupe(u8, item_str) });
                    }
                }

                return Value{ .list = result_list };
            },
            else => {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);
                try result_list.append(val);
                return Value{ .list = result_list };
            },
        };
    }

    /// Reject items matching condition
    pub fn reject(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => |l| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                for (l.items.items) |item| {
                    if (!(item.isTruthy() catch false)) {
                        try result_list.append(item);
                    }
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Reject items by attribute
    pub fn rejectattr(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const attr_name = if (args.len > 0) (try args[0].toString(allocator)) else "";
        defer if (args.len > 0) allocator.free(attr_name);

        return switch (val) {
            .list => |l| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                for (l.items.items) |item| {
                    var should_keep = true;
                    if (item == .dict) {
                        if (item.dict.get(attr_name)) |attr_val| {
                            should_keep = attr_val.isTruthy() catch false;
                        } else {
                            should_keep = true;
                        }
                    }
                    if (should_keep) {
                        try result_list.append(item);
                    }
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Select items matching condition
    pub fn select(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => |l| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                for (l.items.items) |item| {
                    if (item.isTruthy() catch false) {
                        try result_list.append(item);
                    }
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Select items by attribute
    pub fn selectattr(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const attr_name = if (args.len > 0) (try args[0].toString(allocator)) else "";
        defer if (args.len > 0) allocator.free(attr_name);

        return switch (val) {
            .list => |l| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                for (l.items.items) |item| {
                    var should_select = false;
                    if (item == .dict) {
                        if (item.dict.get(attr_name)) |attr_val| {
                            should_select = attr_val.isTruthy() catch false;
                        } else {
                            should_select = false;
                        }
                    }
                    if (should_select) {
                        try result_list.append(item);
                    }
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Slice list
    pub fn slice(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const slice_size = if (args.len > 0) (args[0].toInteger() orelse 1) else 1;
        const fill_with = if (args.len > 1) args[1] else Value{ .null = {} };

        return switch (val) {
            .list => |l| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                var i: usize = 0;
                while (i < l.items.items.len) {
                    const slice_list = try allocator.create(value_mod.List);
                    slice_list.* = value_mod.List.init(allocator);

                    const end = @min(i + @as(usize, @intCast(slice_size)), l.items.items.len);
                    for (l.items.items[i..end]) |item| {
                        try slice_list.append(item);
                    }

                    // Fill with fill_with if needed
                    while (slice_list.items.items.len < @as(usize, @intCast(slice_size))) {
                        try slice_list.append(fill_with);
                    }

                    try result_list.append(Value{ .list = slice_list });
                    i += @as(usize, @intCast(slice_size));
                }

                return Value{ .list = result_list };
            },
            .string => |s| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                var i: usize = 0;
                while (i < s.len) {
                    const end = @min(i + @as(usize, @intCast(slice_size)), s.len);
                    const slice_str = try allocator.dupe(u8, s[i..end]);
                    try result_list.append(Value{ .string = slice_str });
                    i += @as(usize, @intCast(slice_size));
                }

                return Value{ .list = result_list };
            },
            else => {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);
                try result_list.append(val);
                return Value{ .list = result_list };
            },
        };
    }

    /// Sort list
    pub fn sort(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;

        // Parse arguments: sort(reverse, case_sensitive, attribute)
        // Args can be positional - we'll parse by type and position
        var reverse_order = false;
        var case_sensitive = false;
        var attribute: ?[]const u8 = null;

        // Parse arguments - check types to determine what they are
        for (args) |arg| {
            switch (arg) {
                .boolean => |b| {
                    if (!reverse_order) {
                        reverse_order = b;
                    } else {
                        case_sensitive = b;
                    }
                },
                .string => |s| {
                    // String argument is the attribute name
                    attribute = s;
                },
                else => {},
            }
        }

        // If no case_sensitive was set, default to false (case-insensitive by default)
        if (args.len == 0) {
            case_sensitive = false;
        }

        return switch (val) {
            .list => |l| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                // Copy items (deep copy)
                for (l.items.items) |item| {
                    const item_copy = try item.deepCopy(allocator);
                    try result_list.append(item_copy);
                }

                // Sort context with attribute support
                const SortContext = struct {
                    allocator: std.mem.Allocator,
                    case_sensitive: bool,
                    attribute: ?[]const u8,
                    env: ?*environment.Environment,

                    pub fn getSortKey(sort_ctx: @This(), item: Value) !Value {
                        // If no attribute specified, use item itself
                        if (sort_ctx.attribute == null) {
                            return try item.deepCopy(sort_ctx.allocator);
                        }

                        // Extract attribute value using dot notation
                        return sort_ctx.getAttribute(item, sort_ctx.attribute.?);
                    }

                    pub fn getAttribute(sort_ctx: @This(), item: Value, attr_path: []const u8) !Value {
                        // Split attribute path by dots
                        var parts = std.ArrayList([]const u8){};
                        defer parts.deinit(sort_ctx.allocator);

                        var iter = std.mem.splitSequence(u8, attr_path, ".");
                        while (iter.next()) |part| {
                            if (part.len > 0) {
                                try parts.append(sort_ctx.allocator, part);
                            }
                        }

                        var current: Value = item;
                        defer current.deinit(sort_ctx.allocator);

                        // Navigate through nested attributes
                        for (parts.items) |part| {
                            // Try to parse as integer for list indexing
                            if (std.fmt.parseInt(usize, part, 10) catch null) |index| {
                                // List access
                                if (current == .list) {
                                    if (index < current.list.items.items.len) {
                                        const next = current.list.items.items[index];
                                        current.deinit(sort_ctx.allocator);
                                        current = try next.deepCopy(sort_ctx.allocator);
                                    } else {
                                        return Value{ .null = {} };
                                    }
                                } else {
                                    return Value{ .null = {} };
                                }
                            } else {
                                // Dict/attribute access
                                if (current == .dict) {
                                    if (current.dict.get(part)) |dict_val| {
                                        current.deinit(sort_ctx.allocator);
                                        current = try dict_val.deepCopy(sort_ctx.allocator);
                                    } else {
                                        return Value{ .null = {} };
                                    }
                                } else {
                                    return Value{ .null = {} };
                                }
                            }
                        }

                        // Return copy of final value
                        return try current.deepCopy(sort_ctx.allocator);
                    }

                    pub fn lessThan(sort_ctx: @This(), a: Value, b: Value) bool {
                        // Get sort keys
                        var a_key = sort_ctx.getSortKey(a) catch return false;
                        defer a_key.deinit(sort_ctx.allocator);

                        var b_key = sort_ctx.getSortKey(b) catch return false;
                        defer b_key.deinit(sort_ctx.allocator);

                        // Compare keys
                        const a_str = a_key.toString(sort_ctx.allocator) catch return false;
                        defer sort_ctx.allocator.free(a_str);
                        const b_str = b_key.toString(sort_ctx.allocator) catch return false;
                        defer sort_ctx.allocator.free(b_str);

                        if (sort_ctx.case_sensitive) {
                            return std.mem.order(u8, a_str, b_str) == .lt;
                        } else {
                            // Case-insensitive comparison
                            var a_lower = std.ArrayList(u8){};
                            defer a_lower.deinit(sort_ctx.allocator);
                            var b_lower = std.ArrayList(u8){};
                            defer b_lower.deinit(sort_ctx.allocator);

                            for (a_str) |c| {
                                a_lower.append(sort_ctx.allocator, std.ascii.toLower(c)) catch return false;
                            }
                            for (b_str) |c| {
                                b_lower.append(sort_ctx.allocator, std.ascii.toLower(c)) catch return false;
                            }

                            return std.mem.order(u8, a_lower.items, b_lower.items) == .lt;
                        }
                    }
                };

                const sort_ctx = SortContext{
                    .allocator = allocator,
                    .case_sensitive = case_sensitive,
                    .attribute = attribute,
                    .env = env,
                };

                // Use insertion sort (stable and simple)
                // Sort in-place
                var i: usize = 1;
                while (i < result_list.items.items.len) : (i += 1) {
                    var j = i;
                    while (j > 0) {
                        const should_swap = if (reverse_order)
                            !sort_ctx.lessThan(result_list.items.items[j - 1], result_list.items.items[j])
                        else
                            sort_ctx.lessThan(result_list.items.items[j], result_list.items.items[j - 1]);

                        if (should_swap) {
                            // Swap items
                            const temp = result_list.items.items[j];
                            result_list.items.items[j] = result_list.items.items[j - 1];
                            result_list.items.items[j - 1] = temp;
                            j -= 1;
                        } else {
                            break;
                        }
                    }
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Sum values
    pub fn sum(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => |l| {
                var total_int: i64 = 0;
                var total_float: f64 = 0.0;
                var has_float = false;

                for (l.items.items) |item| {
                    if (item.toInteger()) |int_val| {
                        if (has_float) {
                            total_float += @as(f64, @floatFromInt(int_val));
                        } else {
                            total_int += int_val;
                        }
                    } else if (item.toFloat()) |float_val| {
                        if (!has_float) {
                            total_float = @as(f64, @floatFromInt(total_int));
                            has_float = true;
                        }
                        total_float += float_val;
                    }
                }

                if (has_float) {
                    return Value{ .float = total_float };
                } else {
                    return Value{ .integer = total_int };
                }
            },
            else => val,
        };
    }

    /// Get unique items
    pub fn unique(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        _ = if (args.len > 0) (try args[0].toBoolean()) else true; // case_sensitive - not used in current implementation

        return switch (val) {
            .list => |l| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                var seen = std.ArrayList(Value){};
                defer seen.deinit(allocator);

                for (l.items.items) |item| {
                    var is_duplicate = false;
                    for (seen.items) |seen_item| {
                        if (try item.isEqual(seen_item)) {
                            is_duplicate = true;
                            break;
                        }
                    }
                    if (!is_duplicate) {
                        try seen.append(allocator, item);
                        try result_list.append(item);
                    }
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    // ============================================================================
    // Number Filters
    // ============================================================================

    /// Convert to float
    pub fn float(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        if (val.toFloat()) |f| {
            return Value{ .float = f };
        }
        if (val.toInteger()) |i| {
            return Value{ .float = @as(f64, @floatFromInt(i)) };
        }
        return Value{ .float = 0.0 };
    }

    /// Convert to integer
    pub fn int(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        if (val.toInteger()) |i| {
            return Value{ .integer = i };
        }
        if (val.toFloat()) |f| {
            return Value{ .integer = @intFromFloat(f) };
        }
        return Value{ .integer = 0 };
    }

    /// Round number
    pub fn round(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const precision = if (args.len > 0) (args[0].toInteger() orelse 0) else 0;

        const float_val = val.toFloat() orelse {
            if (val.toInteger()) |i| {
                return Value{ .integer = i };
            }
            return Value{ .float = 0.0 };
        };

        const multiplier = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(precision)));
        const rounded = @round(float_val * multiplier) / multiplier;

        if (precision == 0) {
            return Value{ .integer = @intFromFloat(rounded) };
        } else {
            return Value{ .float = rounded };
        }
    }

    /// Minimum value
    pub fn min(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => |l| {
                if (l.items.items.len == 0) {
                    return Value{ .null = {} };
                }

                var min_val = l.items.items[0];
                for (l.items.items[1..]) |item| {
                    const min_float = min_val.toFloat();
                    const item_float = item.toFloat();
                    if (min_float != null and item_float != null) {
                        if (item_float.? < min_float.?) {
                            min_val = item;
                        }
                    } else {
                        const min_int = min_val.toInteger();
                        const item_int = item.toInteger();
                        if (min_int != null and item_int != null) {
                            if (item_int.? < min_int.?) {
                                min_val = item;
                            }
                        }
                    }
                }

                return min_val;
            },
            else => val,
        };
    }

    /// Maximum value
    pub fn max(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => |l| {
                if (l.items.items.len == 0) {
                    return Value{ .null = {} };
                }

                var max_val = l.items.items[0];
                for (l.items.items[1..]) |item| {
                    const max_float = max_val.toFloat();
                    const item_float = item.toFloat();
                    if (max_float != null and item_float != null) {
                        if (item_float.? > max_float.?) {
                            max_val = item;
                        }
                    } else {
                        const max_int = max_val.toInteger();
                        const item_int = item.toInteger();
                        if (max_int != null and item_int != null) {
                            if (item_int.? > max_int.?) {
                                max_val = item;
                            }
                        }
                    }
                }

                return max_val;
            },
            else => val,
        };
    }

    // ============================================================================
    // Dict Filters
    // ============================================================================

    /// Sort dictionary
    pub fn dictsort(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const case_sensitive = if (args.len > 0) (try args[0].toBoolean()) else true;
        const by_str = if (args.len > 1) (try args[1].toString(allocator)) else "key";
        defer if (args.len > 1) allocator.free(by_str);
        const by = if (args.len > 1) by_str else "key";

        return switch (val) {
            .dict => |d| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                // Collect entries
                var entries = std.ArrayList(struct { key: []const u8, value: Value }){};
                defer entries.deinit(allocator);

                var iter = d.map.iterator();
                while (iter.next()) |entry| {
                    try entries.append(allocator, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
                }

                // Sort by key or value
                if (std.mem.eql(u8, by, "key")) {
                    // Sort by key
                    var swapped = true;
                    while (swapped) {
                        swapped = false;
                        for (0..entries.items.len - 1) |i| {
                            var should_swap = false;
                            if (case_sensitive) {
                                should_swap = std.mem.order(u8, entries.items[i].key, entries.items[i + 1].key) == .gt;
                            } else {
                                var a_lower = std.ArrayList(u8){};
                                defer a_lower.deinit(allocator);
                                var b_lower = std.ArrayList(u8){};
                                defer b_lower.deinit(allocator);

                                for (entries.items[i].key) |c| {
                                    a_lower.append(allocator, std.ascii.toLower(c)) catch break;
                                }
                                for (entries.items[i + 1].key) |c| {
                                    b_lower.append(allocator, std.ascii.toLower(c)) catch break;
                                }

                                should_swap = std.mem.order(u8, a_lower.items, b_lower.items) == .gt;
                            }

                            if (should_swap) {
                                const temp = entries.items[i];
                                entries.items[i] = entries.items[i + 1];
                                entries.items[i + 1] = temp;
                                swapped = true;
                            }
                        }
                    }
                }

                // Create list of dicts with key/value
                for (entries.items) |entry| {
                    const entry_dict = try allocator.create(value_mod.Dict);
                    entry_dict.* = value_mod.Dict.init(allocator);
                    const key_key = try allocator.dupe(u8, "key");
                    const value_key = try allocator.dupe(u8, "value");
                    try entry_dict.set(key_key, Value{ .string = try allocator.dupe(u8, entry.key) });
                    try entry_dict.set(value_key, entry.value);
                    try result_list.append(Value{ .dict = entry_dict });
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Get items as list of key-value pairs
    pub fn items(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .dict => |d| {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                var iter = d.map.iterator();
                while (iter.next()) |entry| {
                    const entry_list = try allocator.create(value_mod.List);
                    entry_list.* = value_mod.List.init(allocator);
                    try entry_list.append(Value{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
                    try entry_list.append(entry.value_ptr.*);
                    try result_list.append(Value{ .list = entry_list });
                }

                return Value{ .list = result_list };
            },
            else => {
                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);
                try result_list.append(val);
                return Value{ .list = result_list };
            },
        };
    }

    // ============================================================================
    // Other Filters
    // ============================================================================

    /// Count items
    pub fn count(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => |l| Value{ .integer = @intCast(l.items.items.len) },
            .dict => |d| Value{ .integer = @intCast(d.map.count()) },
            .string => |s| Value{ .integer = @intCast(s.len) },
            else => Value{ .integer = 1 },
        };
    }

    /// Format file size
    pub fn filesizeformat(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const bytes_int = val.toInteger();
        const bytes_float = val.toFloat();
        const bytes_f: f64 = if (bytes_int) |b| @as(f64, @floatFromInt(b)) else bytes_float orelse 0.0;

        const kb: f64 = 1024;
        const mb = kb * 1024;
        const gb = mb * 1024;
        const tb = gb * 1024;

        const abs_bytes = if (bytes_f < 0) -bytes_f else bytes_f;

        if (abs_bytes < kb) {
            return Value{ .string = try std.fmt.allocPrint(allocator, "{d} B", .{@as(i64, @intFromFloat(bytes_f))}) };
        } else if (abs_bytes < mb) {
            return Value{ .string = try std.fmt.allocPrint(allocator, "{d:.1} KB", .{bytes_f / kb}) };
        } else if (abs_bytes < gb) {
            return Value{ .string = try std.fmt.allocPrint(allocator, "{d:.1} MB", .{bytes_f / mb}) };
        } else if (abs_bytes < tb) {
            return Value{ .string = try std.fmt.allocPrint(allocator, "{d:.1} GB", .{bytes_f / gb}) };
        } else {
            return Value{ .string = try std.fmt.allocPrint(allocator, "{d:.1} TB", .{bytes_f / tb}) };
        }
    }

    /// Group by attribute (simplified)
    pub fn groupby(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const attr_name = if (args.len > 0) (try args[0].toString(allocator)) else "";
        defer if (args.len > 0) allocator.free(attr_name);

        return switch (val) {
            .list => |l| {
                // Group items by attribute value
                var groups = std.StringHashMap(*value_mod.List).init(allocator);
                defer {
                    var iter = groups.iterator();
                    while (iter.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.*.deinit(allocator);
                        allocator.destroy(entry.value_ptr.*);
                    }
                    groups.deinit();
                }

                for (l.items.items) |item| {
                    const group_key = switch (item) {
                        .dict => |d| d.get(attr_name) orelse Value{ .null = {} },
                        else => Value{ .null = {} },
                    };

                    const group_key_str = try group_key.toString(allocator);
                    defer allocator.free(group_key_str);

                    if (groups.get(group_key_str)) |group_list| {
                        try group_list.append(item);
                    } else {
                        const group_key_copy = try allocator.dupe(u8, group_key_str);
                        const new_group = try allocator.create(value_mod.List);
                        new_group.* = value_mod.List.init(allocator);
                        try new_group.append(item);
                        try groups.put(group_key_copy, new_group);
                    }
                }

                const result_list = try allocator.create(value_mod.List);
                result_list.* = value_mod.List.init(allocator);

                var iter = groups.iterator();
                while (iter.next()) |entry| {
                    try result_list.append(Value{ .list = entry.value_ptr.* });
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Pretty print with indentation and width support
    pub fn pprint(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        // Parse arguments: pprint(width, indent_size)
        var width: usize = 80;
        var indent_size: usize = 2;
        var visited = std.AutoHashMap(*const anyopaque, void).init(allocator);
        defer visited.deinit();

        // Parse arguments
        if (args.len > 0) {
            if (args[0].toInteger()) |w| {
                width = @as(usize, @intCast(w));
            }
        }
        if (args.len > 1) {
            if (args[1].toInteger()) |i| {
                indent_size = @as(usize, @intCast(i));
            }
        }

        // Format value with indentation
        const formatted = try formatPretty(allocator, val, 0, indent_size, width, &visited);
        defer allocator.free(formatted);

        return Value{ .string = try allocator.dupe(u8, formatted) };
    }

    /// Helper function to format values with indentation
    fn formatPretty(
        allocator: std.mem.Allocator,
        val: Value,
        current_indent: usize,
        indent_size: usize,
        width: usize,
        visited: *std.AutoHashMap(*const anyopaque, void),
    ) ![]const u8 {
        return switch (val) {
            .list => |l| {
                // Check for circular references
                const ptr = @as(*const anyopaque, @ptrCast(l));
                if (visited.get(ptr)) |_| {
                    return try allocator.dupe(u8, "[...]");
                }
                try visited.put(ptr, {});
                defer _ = visited.remove(ptr);

                if (l.items.items.len == 0) {
                    return try allocator.dupe(u8, "[]");
                }

                var result = std.ArrayList(u8).empty;
                errdefer result.deinit(allocator);

                try result.appendSlice(allocator, "[\n");

                for (l.items.items, 0..) |item, i| {
                    // Add indentation
                    for (0..current_indent + indent_size) |_| {
                        try result.append(allocator, ' ');
                    }

                    const item_str = try formatPretty(allocator, item, current_indent + indent_size, indent_size, width, visited);
                    defer allocator.free(item_str);
                    try result.appendSlice(allocator, item_str);

                    if (i < l.items.items.len - 1) {
                        try result.appendSlice(allocator, ",\n");
                    } else {
                        try result.append(allocator, '\n');
                    }
                }

                // Add closing indentation
                for (0..current_indent) |_| {
                    try result.append(allocator, ' ');
                }
                try result.append(allocator, ']');

                return try result.toOwnedSlice(allocator);
            },
            .dict => |d| {
                // Check for circular references
                const ptr = @as(*const anyopaque, @ptrCast(d));
                if (visited.get(ptr)) |_| {
                    return try allocator.dupe(u8, "{...}");
                }
                try visited.put(ptr, {});
                defer _ = visited.remove(ptr);

                if (d.map.count() == 0) {
                    return try allocator.dupe(u8, "{}");
                }

                var result = std.ArrayList(u8).empty;
                errdefer result.deinit(allocator);

                try result.appendSlice(allocator, "{\n");

                var iter = d.map.iterator();
                var entry_count: usize = 0;
                const total = d.map.count();

                while (iter.next()) |entry| : (entry_count += 1) {
                    // Add indentation
                    for (0..current_indent + indent_size) |_| {
                        try result.append(allocator, ' ');
                    }

                    // Format key
                    const key_str = try formatPretty(allocator, Value{ .string = entry.key_ptr.* }, current_indent + indent_size, indent_size, width, visited);
                    defer allocator.free(key_str);
                    try result.appendSlice(allocator, key_str);
                    try result.appendSlice(allocator, ": ");

                    // Format value
                    const val_str = try formatPretty(allocator, entry.value_ptr.*, current_indent + indent_size, indent_size, width, visited);
                    defer allocator.free(val_str);
                    try result.appendSlice(allocator, val_str);

                    if (entry_count < total - 1) {
                        try result.appendSlice(allocator, ",\n");
                    } else {
                        try result.append(allocator, '\n');
                    }
                }

                // Add closing indentation
                for (0..current_indent) |_| {
                    try result.append(allocator, ' ');
                }
                try result.append(allocator, '}');

                return try result.toOwnedSlice(allocator);
            },
            .string => |s| {
                // Format string with quotes
                var result = std.ArrayList(u8).empty;
                errdefer result.deinit(allocator);

                try result.append(allocator, '"');
                for (s) |c| {
                    switch (c) {
                        '\n' => try result.appendSlice(allocator, "\\n"),
                        '\r' => try result.appendSlice(allocator, "\\r"),
                        '\t' => try result.appendSlice(allocator, "\\t"),
                        '"' => try result.appendSlice(allocator, "\\\""),
                        '\\' => try result.appendSlice(allocator, "\\\\"),
                        else => try result.append(allocator, c),
                    }
                }
                try result.append(allocator, '"');

                return try result.toOwnedSlice(allocator);
            },
            .integer => |i| {
                return try std.fmt.allocPrint(allocator, "{d}", .{i});
            },
            .float => |f| {
                return try std.fmt.allocPrint(allocator, "{d}", .{f});
            },
            .boolean => |b| {
                return try allocator.dupe(u8, if (b) "true" else "false");
            },
            .null => {
                return try allocator.dupe(u8, "null");
            },
            .undefined => |u| {
                var result = std.ArrayList(u8).empty;
                errdefer result.deinit(allocator);
                try result.appendSlice(allocator, "undefined(");
                try result.appendSlice(allocator, u.name);
                try result.append(allocator, ')');
                return try result.toOwnedSlice(allocator);
            },
            .markup => |m| {
                // Format markup similar to string
                var result = std.ArrayList(u8).empty;
                errdefer result.deinit(allocator);
                try result.append(allocator, '"');
                for (m.content) |c| {
                    switch (c) {
                        '\n' => try result.appendSlice(allocator, "\\n"),
                        '\r' => try result.appendSlice(allocator, "\\r"),
                        '\t' => try result.appendSlice(allocator, "\\t"),
                        '"' => try result.appendSlice(allocator, "\\\""),
                        '\\' => try result.appendSlice(allocator, "\\\\"),
                        else => try result.append(allocator, c),
                    }
                }
                try result.append(allocator, '"');
                return try result.toOwnedSlice(allocator);
            },
            .async_result => |ar| {
                if (ar.completed and ar.value != null) {
                    return try formatPretty(allocator, ar.value.?, current_indent, indent_size, width, visited);
                }
                return try std.fmt.allocPrint(allocator, "<async pending:{d}>", .{ar.id});
            },
            .callable => |c| {
                return try std.fmt.allocPrint(allocator, "<{s} {s}>", .{
                    switch (c.callable_type) {
                        .filter => "filter",
                        .test_fn => "test",
                        .macro => "macro",
                        .function => "function",
                        .method => "method",
                    },
                    c.name orelse "<anonymous>",
                });
            },
            .custom => |custom| {
                // Try custom toString first
                if (custom.toString(allocator)) |maybe_str| {
                    if (maybe_str) |str| {
                        // Wrap in quotes like other values
                        var result = std.ArrayList(u8).empty;
                        errdefer result.deinit(allocator);
                        defer allocator.free(str);
                        try result.append(allocator, '"');
                        try result.appendSlice(allocator, str);
                        try result.append(allocator, '"');
                        return try result.toOwnedSlice(allocator);
                    }
                } else |_| {}
                // Default: return type name representation
                return try std.fmt.allocPrint(allocator, "<{s} object>", .{custom.typeName()});
            },
        };
    }

    /// Random item
    pub fn random(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => |l| {
                if (l.items.items.len == 0) {
                    return Value{ .null = {} };
                }
                // Simple random - use index based on current time
                const index = @as(usize, @intCast(@mod(std.time.timestamp(), @as(i64, @intCast(l.items.items.len)))));
                return l.items.items[index];
            },
            else => val,
        };
    }

    /// Mark as safe (no-op for now, just returns value)
    pub fn safe(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        // If already escaped, return as-is
        if (val.isEscaped()) {
            return val;
        }

        // Convert to string and mark as safe
        const str = try val.toString(allocator);

        const markup = try allocator.create(value_mod.Markup);
        markup.* = value_mod.Markup{ .content = str };

        return Value{ .markup = markup };
    }

    /// Mark value as safe (alias for safe) - matches Jinja2's do_mark_safe
    /// Usage: {{ "<b>bold</b>"|mark_safe }}
    pub fn mark_safe(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        // Simply delegate to safe filter
        return BuiltinFilters.safe(allocator, val, args, kwargs, ctx, env);
    }

    /// Mark value as unsafe (remove safe marking) - matches Jinja2's do_mark_unsafe
    /// Converts Markup back to plain string, removing safe marking
    /// Usage: {{ markup_value|mark_unsafe }}
    pub fn mark_unsafe(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        // If value is Markup, extract content as plain string
        return switch (val) {
            .markup => |m| Value{ .string = try allocator.dupe(u8, m.content) },
            .string => |s| Value{ .string = try allocator.dupe(u8, s) },
            else => {
                // Convert non-string values to string
                const str = try val.toString(allocator);
                return Value{ .string = str };
            },
        };
    }

    /// Convert to string
    pub fn string(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);
        return Value{ .string = try allocator.dupe(u8, str) };
    }

    /// Convert to JSON with optional indentation
    /// Usage: {{ data | tojson }} or {{ data | tojson(indent=4) }}
    pub fn tojson(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        // Get indent_size from kwargs or args
        var indent_size: ?usize = null;
        if (kwargs.get("indent")) |indent_val| {
            if (indent_val.toInteger()) |i| {
                indent_size = if (i > 0) @intCast(i) else null;
            }
        } else if (args.len > 0) {
            if (args[0].toInteger()) |i| {
                indent_size = if (i > 0) @intCast(i) else null;
            }
        }

        // If indent_size is specified, use pretty printing
        if (indent_size) |ind| {
            return tojsonPretty(allocator, val, ind, 0, kwargs, ctx, env);
        }

        // Compact JSON (no indentation)
        return tojsonCompact(allocator, val, kwargs, ctx, env);
    }

    /// Compact JSON serialization (no whitespace)
    fn tojsonCompact(allocator: std.mem.Allocator, val: Value, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        return switch (val) {
            .string => |s| {
                // Escape JSON special characters
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);
                try result.append(allocator, '"');
                for (s) |c| {
                    switch (c) {
                        '"' => try result.appendSlice(allocator, "\\\""),
                        '\\' => try result.appendSlice(allocator, "\\\\"),
                        '\n' => try result.appendSlice(allocator, "\\n"),
                        '\r' => try result.appendSlice(allocator, "\\r"),
                        '\t' => try result.appendSlice(allocator, "\\t"),
                        else => try result.append(allocator, c),
                    }
                }
                try result.append(allocator, '"');
                return Value{ .string = try result.toOwnedSlice(allocator) };
            },
            .integer => |i| {
                const str = try std.fmt.allocPrint(allocator, "{}", .{i});
                return Value{ .string = str };
            },
            .float => |f| {
                const str = try std.fmt.allocPrint(allocator, "{}", .{f});
                return Value{ .string = str };
            },
            .boolean => |b| {
                const str = if (b) "true" else "false";
                return Value{ .string = try allocator.dupe(u8, str) };
            },
            .null => {
                return Value{ .string = try allocator.dupe(u8, "null") };
            },
            .list => |l| {
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);
                try result.append(allocator, '[');
                for (l.items.items, 0..) |item, i| {
                    if (i > 0) {
                        try result.appendSlice(allocator, ", ");
                    }
                    var item_json = try tojsonCompact(allocator, item, kwargs, ctx, env);
                    defer item_json.deinit(allocator);
                    const item_str = try item_json.toString(allocator);
                    defer allocator.free(item_str);
                    try result.appendSlice(allocator, item_str);
                }
                try result.append(allocator, ']');
                return Value{ .string = try result.toOwnedSlice(allocator) };
            },
            .dict => |d| {
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);
                try result.append(allocator, '{');
                var iter = d.map.iterator();
                var is_first_json = true;
                while (iter.next()) |entry| {
                    if (!is_first_json) {
                        try result.appendSlice(allocator, ", ");
                    }
                    var key_json = try tojsonCompact(allocator, Value{ .string = entry.key_ptr.* }, kwargs, ctx, env);
                    defer key_json.deinit(allocator);
                    const key_str = try key_json.toString(allocator);
                    defer allocator.free(key_str);
                    try result.appendSlice(allocator, key_str);
                    try result.appendSlice(allocator, ": ");
                    var val_json = try tojsonCompact(allocator, entry.value_ptr.*, kwargs, ctx, env);
                    defer val_json.deinit(allocator);
                    const val_str = try val_json.toString(allocator);
                    defer allocator.free(val_str);
                    try result.appendSlice(allocator, val_str);
                    is_first_json = false;
                }
                try result.append(allocator, '}');
                return Value{ .string = try result.toOwnedSlice(allocator) };
            },
            .undefined => {
                return Value{ .string = try allocator.dupe(u8, "null") };
            },
            .markup => |m| {
                // Treat markup as string for JSON purposes
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);
                try result.append(allocator, '"');
                for (m.content) |c| {
                    switch (c) {
                        '"' => try result.appendSlice(allocator, "\\\""),
                        '\\' => try result.appendSlice(allocator, "\\\\"),
                        '\n' => try result.appendSlice(allocator, "\\n"),
                        '\r' => try result.appendSlice(allocator, "\\r"),
                        '\t' => try result.appendSlice(allocator, "\\t"),
                        else => try result.append(allocator, c),
                    }
                }
                try result.append(allocator, '"');
                return Value{ .string = try result.toOwnedSlice(allocator) };
            },
            .async_result => |ar| {
                // Serialize the resolved result if available
                if (ar.value) |v| {
                    return tojsonCompact(allocator, v, kwargs, ctx, env);
                }
                return Value{ .string = try allocator.dupe(u8, "null") };
            },
            .callable => {
                return Value{ .string = try allocator.dupe(u8, "\"<callable>\"") };
            },
            .custom => |custom| {
                // Try to convert custom object to string first, then wrap in quotes
                if (custom.toString(allocator)) |maybe_str| {
                    if (maybe_str) |str| {
                        defer allocator.free(str);
                        // Escape and wrap in quotes
                        var result = std.ArrayList(u8){};
                        defer result.deinit(allocator);
                        try result.append(allocator, '"');
                        for (str) |c| {
                            switch (c) {
                                '"' => try result.appendSlice(allocator, "\\\""),
                                '\\' => try result.appendSlice(allocator, "\\\\"),
                                '\n' => try result.appendSlice(allocator, "\\n"),
                                '\r' => try result.appendSlice(allocator, "\\r"),
                                '\t' => try result.appendSlice(allocator, "\\t"),
                                else => try result.append(allocator, c),
                            }
                        }
                        try result.append(allocator, '"');
                        return Value{ .string = try result.toOwnedSlice(allocator) };
                    }
                } else |_| {}
                // Default: return as quoted type name
                return Value{ .string = try std.fmt.allocPrint(allocator, "\"<{s}>\"", .{custom.typeName()}) };
            },
        };
    }

    /// Pretty JSON serialization with indentation
    fn tojsonPretty(allocator: std.mem.Allocator, val: Value, indent_size: usize, depth: usize, kwargs: *const std.StringHashMap(Value), ctx: ?*context.Context, env: ?*environment.Environment) !Value {
        return switch (val) {
            .string => |s| {
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);
                try result.append(allocator, '"');
                for (s) |c| {
                    switch (c) {
                        '"' => try result.appendSlice(allocator, "\\\""),
                        '\\' => try result.appendSlice(allocator, "\\\\"),
                        '\n' => try result.appendSlice(allocator, "\\n"),
                        '\r' => try result.appendSlice(allocator, "\\r"),
                        '\t' => try result.appendSlice(allocator, "\\t"),
                        else => try result.append(allocator, c),
                    }
                }
                try result.append(allocator, '"');
                return Value{ .string = try result.toOwnedSlice(allocator) };
            },
            .integer => |i| {
                return Value{ .string = try std.fmt.allocPrint(allocator, "{}", .{i}) };
            },
            .float => |f| {
                return Value{ .string = try std.fmt.allocPrint(allocator, "{}", .{f}) };
            },
            .boolean => |b| {
                return Value{ .string = try allocator.dupe(u8, if (b) "true" else "false") };
            },
            .null => {
                return Value{ .string = try allocator.dupe(u8, "null") };
            },
            .list => |l| {
                if (l.items.items.len == 0) {
                    return Value{ .string = try allocator.dupe(u8, "[]") };
                }
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);
                try result.appendSlice(allocator, "[\n");
                const inner_indent = depth + 1;
                for (l.items.items, 0..) |item, i| {
                    // Add indentation
                    try result.appendNTimes(allocator, ' ', inner_indent * indent_size);
                    var item_json = try tojsonPretty(allocator, item, indent_size, inner_indent, kwargs, ctx, env);
                    defer item_json.deinit(allocator);
                    const item_str = try item_json.toString(allocator);
                    defer allocator.free(item_str);
                    try result.appendSlice(allocator, item_str);
                    if (i < l.items.items.len - 1) {
                        try result.append(allocator, ',');
                    }
                    try result.append(allocator, '\n');
                }
                try result.appendNTimes(allocator, ' ', depth * indent_size);
                try result.append(allocator, ']');
                return Value{ .string = try result.toOwnedSlice(allocator) };
            },
            .dict => |d| {
                if (d.map.count() == 0) {
                    return Value{ .string = try allocator.dupe(u8, "{}") };
                }
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);
                try result.appendSlice(allocator, "{\n");
                const inner_indent = depth + 1;
                var iter = d.map.iterator();
                var entry_count: usize = 0;
                const total = d.map.count();
                while (iter.next()) |entry| {
                    // Add indentation
                    try result.appendNTimes(allocator, ' ', inner_indent * indent_size);
                    // Key (always a string in JSON)
                    try result.append(allocator, '"');
                    for (entry.key_ptr.*) |c| {
                        switch (c) {
                            '"' => try result.appendSlice(allocator, "\\\""),
                            '\\' => try result.appendSlice(allocator, "\\\\"),
                            else => try result.append(allocator, c),
                        }
                    }
                    try result.appendSlice(allocator, "\": ");
                    // Value
                    var val_json = try tojsonPretty(allocator, entry.value_ptr.*, indent_size, inner_indent, kwargs, ctx, env);
                    defer val_json.deinit(allocator);
                    const val_str = try val_json.toString(allocator);
                    defer allocator.free(val_str);
                    try result.appendSlice(allocator, val_str);
                    entry_count += 1;
                    if (entry_count < total) {
                        try result.append(allocator, ',');
                    }
                    try result.append(allocator, '\n');
                }
                try result.appendNTimes(allocator, ' ', depth * indent_size);
                try result.append(allocator, '}');
                return Value{ .string = try result.toOwnedSlice(allocator) };
            },
            .undefined => {
                return Value{ .string = try allocator.dupe(u8, "null") };
            },
            .markup => |m| {
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);
                try result.append(allocator, '"');
                for (m.content) |c| {
                    switch (c) {
                        '"' => try result.appendSlice(allocator, "\\\""),
                        '\\' => try result.appendSlice(allocator, "\\\\"),
                        '\n' => try result.appendSlice(allocator, "\\n"),
                        '\r' => try result.appendSlice(allocator, "\\r"),
                        '\t' => try result.appendSlice(allocator, "\\t"),
                        else => try result.append(allocator, c),
                    }
                }
                try result.append(allocator, '"');
                return Value{ .string = try result.toOwnedSlice(allocator) };
            },
            .async_result => |ar| {
                if (ar.value) |v| {
                    return tojsonPretty(allocator, v, indent_size, depth, kwargs, ctx, env);
                }
                return Value{ .string = try allocator.dupe(u8, "null") };
            },
            .callable => {
                return Value{ .string = try allocator.dupe(u8, "\"<callable>\"") };
            },
            .custom => |custom| {
                if (custom.toString(allocator)) |maybe_str| {
                    if (maybe_str) |str| {
                        defer allocator.free(str);
                        var result = std.ArrayList(u8){};
                        defer result.deinit(allocator);
                        try result.append(allocator, '"');
                        for (str) |c| {
                            switch (c) {
                                '"' => try result.appendSlice(allocator, "\\\""),
                                '\\' => try result.appendSlice(allocator, "\\\\"),
                                '\n' => try result.appendSlice(allocator, "\\n"),
                                '\r' => try result.appendSlice(allocator, "\\r"),
                                '\t' => try result.appendSlice(allocator, "\\t"),
                                else => try result.append(allocator, c),
                            }
                        }
                        try result.append(allocator, '"');
                        return Value{ .string = try result.toOwnedSlice(allocator) };
                    }
                } else |_| {}
                return Value{ .string = try std.fmt.allocPrint(allocator, "\"<{s}>\"", .{custom.typeName()}) };
            },
        };
    }
};

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
const exceptions = @import("exceptions.zig");
const value_mod = @import("value.zig");
const PassArg = @import("pass_arg.zig").PassArg;
const value_format = @import("value_format.zig");
const support = @import("filter_support.zig");
const html_escape = @import("html_escape.zig");

/// Re-export Value type for convenience
pub const Value = value_mod.Value;

/// Error type for filter functions
pub const FilterError = exceptions.TemplateError || std.mem.Allocator.Error || error{ Overflow, InvalidCharacter };

const createList = support.createList;
const createDict = support.createDict;
const attributeTruthy = support.attributeTruthy;
const appendOwnedCopy = support.appendOwnedCopy;
const deinitGroups = support.deinitGroups;

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
    ctx: ?*anyopaque,
    env: ?*anyopaque,
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
    pass_arg: PassArg = .none,
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
    pub fn withPassArg(name: []const u8, func: FilterFn, pass_arg: PassArg) Self {
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
    .{ "split", BuiltinFilters.split },
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
    pub fn abs(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn capitalize(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn default(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn lower(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn upper(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn length(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const len = val.length();
        return Value{ .integer = @intCast(len) };
    }

    /// Reverse a string
    pub fn reverse(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn replace(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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

        if (old_str_val.len > 0) {
            return Value{ .string = try std.mem.replaceOwned(u8, allocator, str, old_str_val, new_str_val) };
        }

        // Python/Jinja inserts the replacement at every boundary for an empty needle.
        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, str.len + (str.len + 1) * new_str_val.len);
        result.appendSliceAssumeCapacity(new_str_val);
        for (str) |byte| {
            result.appendAssumeCapacity(byte);
            result.appendSliceAssumeCapacity(new_str_val);
        }
        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Split a string into a list, following Python str.split semantics:
    /// with a separator, split on every occurrence and keep empty segments;
    /// with no separator (or none), split on whitespace runs and drop empties.
    /// Optional second argument is maxsplit (negative means unlimited).
    pub fn split(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const maxsplit: i64 = if (args.len >= 2) (args[1].toInteger() orelse -1) else -1;

        const has_sep = args.len >= 1 and args[0] != .null and args[0] != .undefined;
        if (has_sep) {
            const sep = try args[0].toString(allocator);
            defer allocator.free(sep);

            if (sep.len == 0) return exceptions.TemplateError.TypeError;

            const result_list = try createList(allocator, std.mem.count(u8, str, sep) + 1);
            errdefer {
                result_list.deinit(allocator);
                allocator.destroy(result_list);
            }

            var splits: i64 = 0;
            var start: usize = 0;
            while (std.mem.indexOfPos(u8, str, start, sep)) |idx| {
                if (maxsplit >= 0 and splits >= maxsplit) break;
                try result_list.items.append(allocator, Value{ .string = try allocator.dupe(u8, str[start..idx]) });
                start = idx + sep.len;
                splits += 1;
            }
            try result_list.items.append(allocator, Value{ .string = try allocator.dupe(u8, str[start..]) });
            return Value{ .list = result_list };
        }

        // No separator: split on runs of whitespace, dropping empty segments
        const result_list = try createList(allocator, 0);
        errdefer {
            result_list.deinit(allocator);
            allocator.destroy(result_list);
        }

        var splits: i64 = 0;
        var iter = std.mem.tokenizeAny(u8, str, " \t\n\r");
        while (iter.next()) |token| {
            if (maxsplit >= 0 and splits >= maxsplit) {
                const rest = std.mem.trimLeft(u8, str[iter.index - token.len ..], " \t\n\r");
                const trimmed = std.mem.trimRight(u8, rest, " \t\n\r");
                try result_list.items.append(allocator, Value{ .string = try allocator.dupe(u8, trimmed) });
                break;
            }
            try result_list.items.append(allocator, Value{ .string = try allocator.dupe(u8, token) });
            splits += 1;
        }
        return Value{ .list = result_list };
    }

    /// Strip whitespace from both ends
    pub fn trim(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn lstrip(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn rstrip(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn attr(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn center(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const raw_width = if (args.len > 0) (args[0].toInteger() orelse @as(i64, @intCast(str.len))) else @as(i64, @intCast(str.len));
        const width = std.math.clamp(raw_width, 0, max_filter_width);
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
    pub fn escape(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);

        // FAST PATH: Check if any escaping is needed
        // This avoids allocation for strings with no special characters
        if (!html_escape.needsEscaping(str, false)) {
            // No escaping needed - return as-is (already allocated by toString)
            return Value{ .string = str };
        }

        // SLOW PATH: Actual escaping needed
        defer allocator.free(str);

        return Value{ .string = try html_escape.escapeOwned(allocator, str, false) };
    }

    /// Force HTML escape (same as escape for now)
    pub fn forceescape(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        return escape(allocator, val, args, kwargs, ctx, env);
    }

    /// String formatting (simple version - supports {} placeholders)
    pub fn format(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const format_str = try val.toString(allocator);
        defer allocator.free(format_str);

        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, format_str.len);

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
    pub fn indent(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn join(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn striptags(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, str.len);

        var i: usize = 0;
        while (i < str.len) {
            if (i < str.len and str[i] == '<') {
                // Skip until closing >
                while (i < str.len and str[i] != '>') {
                    i += 1;
                }
                if (i < str.len) i += 1; // Skip the >
            } else {
                result.appendAssumeCapacity(str[i]);
                i += 1;
            }
        }

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Title case string
    pub fn title(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn truncate(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const raw_max_length = if (args.len > 0) (args[0].toInteger() orelse @as(i64, @intCast(str.len))) else @as(i64, @intCast(str.len));
        const killwords = if (args.len > 1) (args[1].toBoolean() catch false) else false;
        const end_str_val = if (args.len > 2) (try args[2].toString(allocator)) else "...";
        defer if (args.len > 2) allocator.free(end_str_val);
        const end_str = if (args.len > 2) end_str_val else "...";
        // Clamp below by the suffix length (a smaller value would underflow the
        // truncation width) and above by the shared filter-argument cap.
        const max_length = std.math.clamp(raw_max_length, @as(i64, @intCast(end_str.len)), max_filter_width);

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
    pub fn urlencode(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, str.len * 3);

        for (str) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                result.appendAssumeCapacity(c);
            } else {
                try result.writer(allocator).print("%{X:0>2}", .{c});
            }
        }

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Convert URLs to links (simplified)
    pub fn urlize(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
        const result_capacity = try support.urlOutputCapacity(str.len);
        try result.ensureTotalCapacity(allocator, result_capacity);

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
                result.appendAssumeCapacity(str[i]);
                i += 1;
            }
        }

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Count words in string
    pub fn wordcount(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

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

    fn appendWrappedWord(allocator: std.mem.Allocator, output: *std.ArrayList(u8), word: []const u8, width: usize, line_length: *usize) !void {
        if (word.len == 0) return;
        if (line_length.* > 0 and line_length.* + 1 + word.len > width) {
            try output.append(allocator, '\n');
            line_length.* = 0;
        } else if (line_length.* > 0) {
            try output.append(allocator, ' ');
            line_length.* += 1;
        }
        try output.appendSlice(allocator, word);
        line_length.* += word.len;
    }

    /// Word wrap text
    pub fn wordwrap(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const str = try val.toString(allocator);
        defer allocator.free(str);

        const raw_wrap_width = if (args.len > 0) (args[0].toInteger() orelse 79) else 79;
        const width: usize = @intCast(std.math.clamp(raw_wrap_width, 1, max_filter_width));
        _ = if (args.len > 1) (args[1].toBoolean() catch true) else true; // break_long_words - not fully implemented yet

        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);
        // Wrapping replaces or drops whitespace, so output never exceeds input length.
        try result.ensureTotalCapacity(allocator, str.len);

        var line_len: usize = 0;
        var word_start: usize = 0;
        var i: usize = 0;

        while (i < str.len) {
            if (str[i] == '\n') {
                try appendWrappedWord(allocator, &result, str[word_start..i], width, &line_len);
                try result.append(allocator, '\n');
                line_len = 0;
                word_start = i + 1;
                i += 1;
            } else if (std.ascii.isWhitespace(str[i])) {
                try appendWrappedWord(allocator, &result, str[word_start..i], width, &line_len);
                word_start = i + 1;
                i += 1;
            } else {
                i += 1;
            }
        }

        // Last word
        try appendWrappedWord(allocator, &result, str[word_start..], width, &line_len);

        return Value{ .string = try result.toOwnedSlice(allocator) };
    }

    /// Format as XML attributes
    pub fn xmlattr(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .dict => |d| {
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);
                try result.ensureTotalCapacity(allocator, d.map.count());

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
                    const escaped_capacity = std.math.mul(usize, val_str.len, 6) catch return error.OutOfMemory;
                    try escaped_val.ensureTotalCapacity(allocator, escaped_capacity);
                    for (val_str) |c| {
                        switch (c) {
                            '&' => escaped_val.appendSliceAssumeCapacity("&amp;"),
                            '<' => escaped_val.appendSliceAssumeCapacity("&lt;"),
                            '>' => escaped_val.appendSliceAssumeCapacity("&gt;"),
                            '"' => escaped_val.appendSliceAssumeCapacity("&quot;"),
                            else => escaped_val.appendAssumeCapacity(c),
                        }
                    }

                    const escaped = try escaped_val.toOwnedSlice(allocator);
                    defer allocator.free(escaped);
                    const attr_str = try std.fmt.allocPrint(allocator, "{s}=\"{s}\"", .{ key, escaped });
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
    pub fn batch(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const raw_batch_size = if (args.len > 0) (args[0].toInteger() orelse 1) else 1;
        const batch_size: usize = @intCast(std.math.clamp(raw_batch_size, 1, max_filter_width));
        const fill_with = if (args.len > 1) args[1] else Value{ .null = {} };

        return switch (val) {
            .list => |l| {
                const batch_count = (l.items.items.len + batch_size - 1) / batch_size;
                const batch_list = try createList(allocator, batch_count);
                errdefer batch_list.deinit(allocator);

                var i: usize = 0;
                while (i < l.items.items.len) {
                    const batch_item_list = try createList(allocator, batch_size);
                    errdefer batch_item_list.deinit(allocator);

                    const end = @min(i + batch_size, l.items.items.len);
                    for (l.items.items[i..end]) |item| {
                        batch_item_list.items.appendAssumeCapacity(try item.deepCopy(allocator));
                    }

                    // Fill with fill_with if needed
                    while (batch_item_list.items.items.len < batch_size) {
                        batch_item_list.items.appendAssumeCapacity(try fill_with.deepCopy(allocator));
                    }

                    batch_list.items.appendAssumeCapacity(Value{ .list = batch_item_list });
                    i += batch_size;
                }

                return Value{ .list = batch_list };
            },
            else => {
                // Convert to list first
                const single_list = try createList(allocator, 1);
                single_list.items.appendAssumeCapacity(try val.deepCopy(allocator));
                return Value{ .list = single_list };
            },
        };
    }

    /// Get first item
    pub fn first(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
                    var result = try allocator.alloc(u8, 1);
                    result[0] = s[0];
                    return Value{ .string = result };
                }
                return Value{ .null = {} };
            },
            else => Value{ .null = {} },
        };
    }

    /// Get last item
    pub fn last(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
                    var result = try allocator.alloc(u8, 1);
                    result[0] = s[s.len - 1];
                    return Value{ .string = result };
                }
                return Value{ .null = {} };
            },
            else => Value{ .null = {} },
        };
    }

    /// Convert to list
    pub fn list(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => val, // Already a list
            .string => |s| {
                const result_list = try createList(allocator, s.len);
                for (s) |c| {
                    // fallow-zig-ignore-next-line zig-alloc-inside-token-loop: list filter returns owned one-byte strings; Value has no borrowed-string variant.
                    var char_str = try allocator.alloc(u8, 1);
                    char_str[0] = c;
                    result_list.items.appendAssumeCapacity(Value{ .string = char_str });
                }
                return Value{ .list = result_list };
            },
            else => {
                const result_list = try createList(allocator, 1);
                result_list.items.appendAssumeCapacity(try val.deepCopy(allocator));
                return Value{ .list = result_list };
            },
        };
    }

    /// Map function over items (simplified - just converts to string for now)
    pub fn map(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const attr_name = if (args.len > 0) (try args[0].toString(allocator)) else "";
        defer if (args.len > 0) allocator.free(attr_name);

        return switch (val) {
            .list => |l| {
                const result_list = try createList(allocator, l.items.items.len);

                for (l.items.items) |item| {
                    if (args.len > 0) {
                        // Get attribute
                        const mapped_val = switch (item) {
                            .dict => |d| d.get(attr_name) orelse Value{ .null = {} },
                            else => item,
                        };
                        result_list.items.appendAssumeCapacity(try mapped_val.deepCopy(allocator));
                    } else {
                        // Just convert to string
                        const item_str = try item.toString(allocator);
                        result_list.items.appendAssumeCapacity(Value{ .string = item_str });
                    }
                }

                return Value{ .list = result_list };
            },
            else => {
                const result_list = try createList(allocator, 1);
                result_list.items.appendAssumeCapacity(try val.deepCopy(allocator));
                return Value{ .list = result_list };
            },
        };
    }

    /// Reject items matching condition
    pub fn reject(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => |l| {
                const result_list = try createList(allocator, l.items.items.len);

                for (l.items.items) |item| {
                    if (!(item.isTruthy() catch false)) {
                        try appendOwnedCopy(allocator, result_list, item);
                    }
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Reject items by attribute
    pub fn rejectattr(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const attr_name = if (args.len > 0) (try args[0].toString(allocator)) else "";
        defer if (args.len > 0) allocator.free(attr_name);

        return switch (val) {
            .list => |l| {
                const result_list = try createList(allocator, l.items.items.len);

                for (l.items.items) |item| {
                    if (!attributeTruthy(item, attr_name)) try appendOwnedCopy(allocator, result_list, item);
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Select items matching condition
    pub fn select(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .list => |l| {
                const result_list = try createList(allocator, l.items.items.len);

                for (l.items.items) |item| {
                    if (item.isTruthy() catch false) {
                        try appendOwnedCopy(allocator, result_list, item);
                    }
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Select items by attribute
    pub fn selectattr(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const attr_name = if (args.len > 0) (try args[0].toString(allocator)) else "";
        defer if (args.len > 0) allocator.free(attr_name);

        return switch (val) {
            .list => |l| {
                const result_list = try createList(allocator, l.items.items.len);

                for (l.items.items) |item| {
                    if (attributeTruthy(item, attr_name)) try appendOwnedCopy(allocator, result_list, item);
                }

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Slice list
    pub fn slice(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const raw_slice_size = if (args.len > 0) (args[0].toInteger() orelse 1) else 1;
        const slice_size: usize = @intCast(std.math.clamp(raw_slice_size, 1, max_filter_width));
        const fill_with = if (args.len > 1) args[1] else Value{ .null = {} };

        return switch (val) {
            .list => |l| {
                const slice_count = (l.items.items.len + slice_size - 1) / slice_size;
                const result_list = try createList(allocator, slice_count);

                var i: usize = 0;
                while (i < l.items.items.len) {
                    const slice_list = try createList(allocator, slice_size);
                    errdefer slice_list.deinit(allocator);

                    const end = @min(i + slice_size, l.items.items.len);
                    for (l.items.items[i..end]) |item| {
                        slice_list.items.appendAssumeCapacity(try item.deepCopy(allocator));
                    }

                    // Fill with fill_with if needed
                    while (slice_list.items.items.len < slice_size) {
                        slice_list.items.appendAssumeCapacity(try fill_with.deepCopy(allocator));
                    }

                    result_list.items.appendAssumeCapacity(Value{ .list = slice_list });
                    i += slice_size;
                }

                return Value{ .list = result_list };
            },
            .string => |s| {
                const slice_count = (s.len + slice_size - 1) / slice_size;
                const result_list = try createList(allocator, slice_count);

                var i: usize = 0;
                while (i < s.len) {
                    const end = @min(i + slice_size, s.len);
                    // fallow-zig-ignore-next-line zig-alloc-inside-token-loop: slice filter returns owned string slices; borrowing source storage would outlive the input Value.
                    const slice_str = try allocator.dupe(u8, s[i..end]);
                    result_list.items.appendAssumeCapacity(Value{ .string = slice_str });
                    i += slice_size;
                }

                return Value{ .list = result_list };
            },
            else => {
                const result_list = try createList(allocator, 1);
                result_list.items.appendAssumeCapacity(try val.deepCopy(allocator));
                return Value{ .list = result_list };
            },
        };
    }

    /// Upper bound for template-supplied width/size filter arguments (center,
    /// truncate, wordwrap, batch, slice). Prevents a template from requesting
    /// gigabyte-scale padding or batch capacity; generous for any real template.
    const max_filter_width: i64 = 1_000_000;

    /// Sort list
    fn sortAttributeValue(item: Value, attribute: ?[]const u8) Value {
        const path = attribute orelse return item;
        var current = item;
        var parts = std.mem.splitScalar(u8, path, '.');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            current = switch (current) {
                .dict => |dict| dict.get(part) orelse return .{ .null = {} },
                .list => |sequence| blk: {
                    const index = std.fmt.parseInt(usize, part, 10) catch return .{ .null = {} };
                    if (index >= sequence.items.items.len) return .{ .null = {} };
                    break :blk sequence.items.items[index];
                },
                else => return .{ .null = {} },
            };
        }
        return current;
    }

    fn ownedSortKey(allocator: std.mem.Allocator, item: Value, attribute: ?[]const u8, case_sensitive: bool) ![]u8 {
        const key_value = sortAttributeValue(item, attribute);
        const key = @constCast(try key_value.toString(allocator));
        if (!case_sensitive) {
            for (key) |*byte| byte.* = std.ascii.toLower(byte.*);
        }
        return key;
    }

    /// Stable O(n log n) sequence sort with keys computed once per item.
    pub fn sort(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        var reverse_order = false;
        var case_sensitive = false;
        var attribute: ?[]const u8 = null;
        if (args.len > 0 and args[0] == .boolean) reverse_order = args[0].boolean;
        if (args.len > 1 and args[1] == .boolean) case_sensitive = args[1].boolean;
        if (args.len > 2 and args[2] == .string) attribute = args[2].string;
        // Preserve the prior convenience form where a lone string is the attribute.
        for (args) |arg| if (arg == .string) {
            attribute = arg.string;
        };

        if (val != .list) return val;

        const Entry = struct {
            value: Value,
            key: []u8,
        };
        var entries = std.ArrayList(Entry){};
        defer entries.deinit(allocator);
        try entries.ensureTotalCapacity(allocator, val.list.items.items.len);
        errdefer {
            for (entries.items) |*entry| {
                entry.value.deinit(allocator);
                allocator.free(entry.key);
            }
        }

        for (val.list.items.items) |item| {
            var item_copy = try item.deepCopy(allocator);
            errdefer item_copy.deinit(allocator);
            const key = try ownedSortKey(allocator, item, attribute, case_sensitive);
            entries.appendAssumeCapacity(.{ .value = item_copy, .key = key });
        }

        const SortContext = struct {
            reverse: bool,

            fn lessThan(sort_context: @This(), left: Entry, right: Entry) bool {
                const order = std.mem.order(u8, left.key, right.key);
                return if (sort_context.reverse) order == .gt else order == .lt;
            }
        };
        std.sort.block(Entry, entries.items, SortContext{ .reverse = reverse_order }, SortContext.lessThan);

        const result = try allocator.create(value_mod.List);
        result.* = value_mod.List.init(allocator);
        errdefer result.deinit(allocator);
        try result.items.ensureTotalCapacity(allocator, entries.items.len);
        for (entries.items) |entry| result.items.appendAssumeCapacity(entry.value);
        for (entries.items) |entry| allocator.free(entry.key);
        return .{ .list = result };
    }

    /// Sum values
    pub fn sum(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
                    // fallow-zig-ignore-next-line jinja-filter-arg-loop-bound: sum converts list ITEMS to integers for totalling; no template argument reaches a loop bound
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
    pub fn unique(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        _ = if (args.len > 0) (try args[0].toBoolean()) else true; // case_sensitive - not used in current implementation

        return switch (val) {
            .list => |l| {
                const result_list = try createList(allocator, l.items.items.len);

                var seen = std.ArrayList(Value){};
                defer seen.deinit(allocator);
                try seen.ensureTotalCapacity(allocator, l.items.items.len);

                for (l.items.items) |item| {
                    var is_duplicate = false;
                    for (seen.items) |seen_item| {
                        if (try item.isEqual(seen_item)) {
                            is_duplicate = true;
                            break;
                        }
                    }
                    if (!is_duplicate) {
                        seen.appendAssumeCapacity(item);
                        result_list.items.appendAssumeCapacity(try item.deepCopy(allocator));
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
    pub fn float(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn int(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn round(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    fn extreme(val: Value, find_minimum: bool) Value {
        if (val != .list or val.list.items.items.len == 0) return if (val == .list) .{ .null = {} } else val;
        var selected = val.list.items.items[0];
        for (val.list.items.items[1..]) |item| {
            const selected_number = selected.toFloat() orelse continue;
            const item_number = item.toFloat() orelse continue;
            if ((find_minimum and item_number < selected_number) or (!find_minimum and item_number > selected_number)) {
                selected = item;
            }
        }
        return selected;
    }

    /// Minimum value
    pub fn min(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;
        return extreme(val, true);
    }

    /// Maximum value
    pub fn max(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;
        return extreme(val, false);
    }

    // ============================================================================
    // Dict Filters
    // ============================================================================

    /// Sort dictionary
    /// Stable dictionary sort supporting key/value and case modes.
    pub fn dictsort(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        if (val != .dict) return val;
        const case_sensitive = args.len > 0 and try args[0].toBoolean();
        const by = if (args.len > 1 and args[1] == .string) args[1].string else "key";
        if (!std.mem.eql(u8, by, "key") and !std.mem.eql(u8, by, "value")) {
            return exceptions.TemplateError.TypeError;
        }

        const Entry = struct {
            key: []const u8,
            value: Value,
            sort_key: []u8,
        };
        var entries = std.ArrayList(Entry){};
        defer entries.deinit(allocator);
        try entries.ensureTotalCapacity(allocator, val.dict.map.count());
        defer for (entries.items) |entry| allocator.free(entry.sort_key);

        var iterator = val.dict.map.iterator();
        while (iterator.next()) |map_entry| {
            const sort_value = if (std.mem.eql(u8, by, "key"))
                Value{ .string = map_entry.key_ptr.* }
            else
                map_entry.value_ptr.*;
            const sort_key = @constCast(try sort_value.toString(allocator));
            if (!case_sensitive) {
                for (sort_key) |*byte| byte.* = std.ascii.toLower(byte.*);
            }
            entries.appendAssumeCapacity(.{
                .key = map_entry.key_ptr.*,
                .value = map_entry.value_ptr.*,
                .sort_key = sort_key,
            });
        }

        const SortContext = struct {
            fn lessThan(_: @This(), left: Entry, right: Entry) bool {
                return std.mem.order(u8, left.sort_key, right.sort_key) == .lt;
            }
        };
        std.sort.block(Entry, entries.items, SortContext{}, SortContext.lessThan);

        const result = try allocator.create(value_mod.List);
        result.* = value_mod.List.init(allocator);
        errdefer result.deinit(allocator);
        try result.items.ensureTotalCapacity(allocator, entries.items.len);

        for (entries.items) |entry| {
            // fallow-zig-ignore-next-line zig-alloc-inside-token-loop: dictsort's public result owns one key/value dictionary per source entry.
            const pair = try createDict(allocator, 2);
            errdefer pair.deinit(allocator);
            // fallow-zig-ignore-next-line zig-alloc-inside-token-loop: each returned pair must own its key and value independently of the source mapping.
            try pair.set("key", .{ .string = try allocator.dupe(u8, entry.key) });
            try pair.set("value", try entry.value.deepCopy(allocator));
            result.items.appendAssumeCapacity(.{ .dict = pair });
        }
        return .{ .list = result };
    }

    /// Get items as list of key-value pairs
    pub fn items(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = args;
        _ = kwargs;
        _ = ctx;
        _ = env;

        return switch (val) {
            .dict => |d| {
                const result_list = try createList(allocator, d.map.count());

                var iter = d.map.iterator();
                while (iter.next()) |entry| {
                    // fallow-zig-ignore-next-line zig-alloc-inside-token-loop: items returns owned key/value pair lists; nested list values must own their containers.
                    const entry_list = try createList(allocator, 2);
                    errdefer entry_list.deinit(allocator);
                    // fallow-zig-ignore-next-line zig-alloc-inside-token-loop: items result owns the copied key string in each returned pair.
                    entry_list.items.appendAssumeCapacity(Value{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
                    entry_list.items.appendAssumeCapacity(try entry.value_ptr.*.deepCopy(allocator));
                    result_list.items.appendAssumeCapacity(Value{ .list = entry_list });
                }

                return Value{ .list = result_list };
            },
            else => {
                const result_list = try createList(allocator, 1);
                result_list.items.appendAssumeCapacity(try val.deepCopy(allocator));
                return Value{ .list = result_list };
            },
        };
    }

    // ============================================================================
    // Other Filters
    // ============================================================================

    /// Count items
    pub fn count(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn filesizeformat(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn groupby(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;

        const attr_name = if (args.len > 0) (try args[0].toString(allocator)) else "";
        defer if (args.len > 0) allocator.free(attr_name);

        return switch (val) {
            .list => |l| {
                // Group items by attribute value
                var groups = std.StringHashMap(*value_mod.List).init(allocator);
                var groups_own_lists = true;
                defer deinitGroups(allocator, &groups, groups_own_lists);
                try groups.ensureTotalCapacity(@intCast(l.items.items.len));

                for (l.items.items) |item| {
                    const group_key = switch (item) {
                        .dict => |d| d.get(attr_name) orelse Value{ .null = {} },
                        else => Value{ .null = {} },
                    };

                    const group_key_str = try group_key.toString(allocator);

                    if (groups.get(group_key_str)) |group_list| {
                        allocator.free(group_key_str);
                        try appendOwnedCopy(allocator, group_list, item);
                    } else {
                        const new_group = try createList(allocator, 1);
                        errdefer new_group.deinit(allocator);
                        try appendOwnedCopy(allocator, new_group, item);
                        groups.putAssumeCapacity(group_key_str, new_group);
                    }
                }

                const result_list = try createList(allocator, groups.count());

                var iter = groups.iterator();
                while (iter.next()) |entry| {
                    result_list.items.appendAssumeCapacity(Value{ .list = entry.value_ptr.* });
                }
                groups_own_lists = false;

                return Value{ .list = result_list };
            },
            else => val,
        };
    }

    /// Pretty print with indentation and width support
    pub fn pprint(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = kwargs;
        _ = ctx;
        _ = env;
        var indent_size: usize = 2;
        if (args.len > 1) {
            if (args[1].toInteger()) |size| indent_size = @intCast(@max(0, size));
        }
        return .{ .string = try value_format.pretty(allocator, val, indent_size) };
    }

    /// Random item
    pub fn random(_: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn safe(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn mark_safe(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        // Simply delegate to safe filter
        return BuiltinFilters.safe(allocator, val, args, kwargs, ctx, env);
    }

    /// Mark value as unsafe (remove safe marking) - matches Jinja2's do_mark_unsafe
    /// Converts Markup back to plain string, removing safe marking
    /// Usage: {{ markup_value|mark_unsafe }}
    pub fn mark_unsafe(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn string(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
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
    pub fn tojson(allocator: std.mem.Allocator, val: Value, args: []Value, kwargs: *const std.StringHashMap(Value), ctx: ?*anyopaque, env: ?*anyopaque) !Value {
        _ = ctx;
        _ = env;
        var indent_size: ?usize = null;
        if (kwargs.get("indent")) |indent_value| {
            if (indent_value.toInteger()) |size| {
                if (size > 0) indent_size = @intCast(size);
            }
        } else if (args.len > 0) {
            if (args[0].toInteger()) |size| {
                if (size > 0) indent_size = @intCast(size);
            }
        }
        return .{ .string = try value_format.json(allocator, val, indent_size) };
    }
};

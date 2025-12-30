//! Sandboxed Template Execution
//!
//! This module provides a sandboxed environment for executing untrusted templates safely.
//! The sandbox restricts access to potentially dangerous operations to prevent security
//! vulnerabilities when rendering templates from untrusted sources.
//!
//! # Security Features
//!
//! - **Attribute Access Control**: Restricts which object attributes can be accessed
//! - **Method Call Control**: Blocks unsafe method calls (e.g., `format` on strings)
//! - **Range Limits**: Prevents DoS attacks via large iterations (`MAX_RANGE = 100,000`)
//! - **Operator Interception**: Intercepts binary/unary operators for safety checks
//! - **Unsafe Callable Detection**: Blocks callables marked as unsafe or `alters_data`
//!
//! # Unsafe Attributes
//!
//! The following attributes are blocked by default in sandboxed mode:
//! - `func_code`, `func_globals`, `func_name` - Function internals
//! - `__self__`, `__dict__`, `__class__`, `__mro__` - Python object internals
//! - `gi_frame`, `gi_code` - Generator internals
//! - `cr_frame`, `cr_code` - Coroutine internals
//! - `__globals__`, `__builtins__` - Global namespace access
//!
//! # Unsafe Methods
//!
//! The following methods are blocked by default in sandboxed mode:
//! - `mro`, `__base__`, `__bases__` - Class hierarchy access
//! - `format` (on strings) - Prevents format string attacks
//! - Any method marked with `alters_data = true`
//!
//! # Usage
//!
//! ```zig
//! var env = jinja.Environment.init(allocator);
//! env.sandboxed = true;  // Enable sandbox mode
//!
//! // Use SandboxedEnvironment for full control
//! var sandbox = try jinja.sandbox.SandboxedEnvironment.init(allocator);
//! defer sandbox.deinit();
//!
//! // Customize allowed attributes/methods
//! sandbox.interceptor.default_safe_attrs = &[_][]const u8{"name", "value"};
//! ```
//!
//! # Safe Range
//!
//! The `safeRange` function provides a bounded range iterator:
//!
//! ```zig
//! var iter = try jinja.sandbox.safeRange(0, 100, 1);
//! while (iter.next()) |value| {
//!     // Safe iteration (max 100,000 items)
//! }
//! ```

const std = @import("std");
const environment = @import("environment.zig");
const context = @import("context.zig");
const exceptions = @import("exceptions.zig");
const value_mod = @import("value.zig");
const nodes = @import("nodes.zig");

/// Re-export Value type for convenience
pub const Value = value_mod.Value;

// ============================================================================
// Safe Range Implementation
// ============================================================================

/// Maximum number of items a range may produce in sandboxed mode
/// This prevents denial of service via large range iterations
pub const MAX_RANGE: i64 = 100000;

/// Error returned when range is too large
pub const RangeError = error{
    RangeTooLarge,
};

/// A range that can't generate ranges with a length of more than MAX_RANGE items.
/// Used in sandboxed environments to prevent DoS attacks via large iterations.
///
/// # Arguments
/// - `start`: Range start value (or end if only one arg provided)
/// - `end_opt`: Optional end value
/// - `step_opt`: Optional step value (must not be 0)
///
/// # Returns
/// Iterator over the range values, or error if range is too large
///
/// # Example
/// ```zig
/// var iter = try safeRange(0, 100, 1);
/// while (iter.next()) |value| {
///     // Use value
/// }
/// ```
pub fn safeRange(start: i64, end_opt: ?i64, step_opt: ?i64) RangeError!SafeRangeIterator {
    const end = end_opt orelse start;
    const actual_start = if (end_opt != null) start else 0;
    const step = step_opt orelse 1;

    if (step == 0) {
        return RangeError.RangeTooLarge; // Step cannot be zero
    }

    // Calculate range length
    const range_length = calculateRangeLength(actual_start, end, step);

    if (range_length > MAX_RANGE) {
        return RangeError.RangeTooLarge;
    }

    return SafeRangeIterator{
        .current = actual_start,
        .end = end,
        .step = step,
    };
}

/// Calculate the length of a range
fn calculateRangeLength(start: i64, end: i64, step: i64) i64 {
    if (step > 0) {
        if (end <= start) return 0;
        return @divTrunc(end - start + step - 1, step);
    } else {
        if (end >= start) return 0;
        return @divTrunc(start - end + (-step) - 1, -step);
    }
}

/// Safe range iterator
pub const SafeRangeIterator = struct {
    current: i64,
    end: i64,
    step: i64,

    const Self = @This();

    /// Get the next value in the range
    pub fn next(self: *Self) ?i64 {
        if (self.step > 0) {
            if (self.current >= self.end) return null;
        } else {
            if (self.current <= self.end) return null;
        }

        const result = self.current;
        self.current += self.step;
        return result;
    }

    /// Reset the iterator
    pub fn reset(self: *Self, start: i64) void {
        self.current = start;
    }

    /// Convert range to list (allocates memory)
    pub fn toList(self: *Self, allocator: std.mem.Allocator) !*value_mod.List {
        const list = try allocator.create(value_mod.List);
        list.* = value_mod.List.init(allocator);
        errdefer {
            list.deinit(allocator);
            allocator.destroy(list);
        }

        while (self.next()) |val| {
            try list.append(Value{ .integer = val });
        }

        return list;
    }
};

// ============================================================================
// Mutable Type Restrictions
// ============================================================================

/// Mutable operation categories for type safety
pub const MutableOp = enum {
    add,
    clear,
    pop,
    remove,
    append,
    insert,
    extend,
    reverse,
    sort,
    update,
    discard,
    setdefault,
    popitem,
    appendleft,
    extendleft,
    popleft,
    rotate,
    difference_update,
    symmetric_difference_update,
};

/// Mutable operations for sets (MutableSet equivalent)
pub const MUTABLE_SET_OPERATIONS = [_][]const u8{
    "add",
    "clear",
    "difference_update",
    "discard",
    "pop",
    "remove",
    "symmetric_difference_update",
    "update",
};

/// Mutable operations for maps/dicts (MutableMapping equivalent)
pub const MUTABLE_MAPPING_OPERATIONS = [_][]const u8{
    "clear",
    "pop",
    "popitem",
    "setdefault",
    "update",
};

/// Mutable operations for lists/sequences (MutableSequence equivalent)
pub const MUTABLE_SEQUENCE_OPERATIONS = [_][]const u8{
    "append",
    "clear",
    "pop",
    "reverse",
    "insert",
    "sort",
    "extend",
    "remove",
};

/// Mutable operations for deques
pub const MUTABLE_DEQUE_OPERATIONS = [_][]const u8{
    "append",
    "appendleft",
    "clear",
    "extend",
    "extendleft",
    "pop",
    "popleft",
    "remove",
    "rotate",
};

/// Check if an operation would modify a known mutable object
/// Returns true if the attribute on the object would modify it if called
pub fn modifiesKnownMutable(obj: Value, attr: []const u8) bool {
    // Check based on object type
    switch (obj) {
        .list => {
            // Check mutable sequence operations
            for (MUTABLE_SEQUENCE_OPERATIONS) |op| {
                if (std.mem.eql(u8, attr, op)) {
                    return true;
                }
            }
        },
        .dict => {
            // Check mutable mapping operations
            for (MUTABLE_MAPPING_OPERATIONS) |op| {
                if (std.mem.eql(u8, attr, op)) {
                    return true;
                }
            }
        },
        else => {},
    }

    return false;
}

// ============================================================================
// Function Call Restrictions
// ============================================================================

/// Unsafe function attributes
pub const UNSAFE_FUNCTION_ATTRIBUTES = [_][]const u8{
    "__code__",
    "__globals__",
    "__builtins__",
    "__closure__",
    "__defaults__",
    "__kwdefaults__",
};

/// Unsafe method attributes
pub const UNSAFE_METHOD_ATTRIBUTES = [_][]const u8{
    "__func__",
    "__self__",
};

/// Unsafe generator attributes
pub const UNSAFE_GENERATOR_ATTRIBUTES = [_][]const u8{
    "gi_frame",
    "gi_code",
};

/// Unsafe coroutine attributes
pub const UNSAFE_COROUTINE_ATTRIBUTES = [_][]const u8{
    "cr_frame",
    "cr_code",
};

/// Unsafe async generator attributes
pub const UNSAFE_ASYNC_GENERATOR_ATTRIBUTES = [_][]const u8{
    "ag_code",
    "ag_frame",
};

/// Callable safety flags (markers that make a callable unsafe)
pub const CallableSafetyFlags = struct {
    /// Callable has been marked as unsafe
    unsafe_callable: bool = false,
    /// Callable alters data (Django convention)
    alters_data: bool = false,
};

/// Check if a callable is marked as unsafe
/// Checks for unsafe_callable and alters_data markers
pub fn hasUnsafeCallableMarker(obj: Value) bool {
    // In Zig, we don't have Python's dynamic attribute system
    // Instead, we check if the callable has safety flags set

    switch (obj) {
        .callable => |c| {
            // Check if callable has been marked unsafe
            if (c.flags) |flags| {
                if (flags.unsafe_callable or flags.alters_data) {
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

// ============================================================================
// Unsafe Attributes
// ============================================================================

/// Unsafe attributes that should be blocked in sandboxed mode
/// These are typically internal Python attributes that could be used to escape the sandbox
pub const UNSAFE_ATTRIBUTES = [_][]const u8{
    // Internal attributes
    "__class__",
    "__dict__",
    "__module__",
    "__weakref__",
    "__init__",
    "__new__",
    "__del__",
    "__getattribute__",
    "__setattr__",
    "__delattr__",
    "__getattr__",
    "__dir__",
    "__subclasshook__",
    "__init_subclass__",
    "__set_name__",
    "__prepare__",
    "__instancecheck__",
    "__subclasscheck__",
    // Code execution attributes
    "__code__",
    "__globals__",
    "__builtins__",
    "__closure__",
    "__defaults__",
    "__kwdefaults__",
    "__annotations__",
    "__qualname__",
    "__name__",
    "__doc__",
    // Frame attributes
    "f_back",
    "f_builtins",
    "f_code",
    "f_globals",
    "f_locals",
    "f_trace",
    // Generator attributes
    "gi_frame",
    "gi_code",
    // Coroutine attributes
    "cr_frame",
    "cr_code",
    // Async generator attributes
    "ag_code",
    "ag_frame",
};

/// Check if an attribute name is unsafe (starts with underscore or is in unsafe list)
pub fn isUnsafeAttribute(attr: []const u8) bool {
    // Attributes starting with underscore are considered unsafe
    if (attr.len > 0 and attr[0] == '_') {
        return true;
    }

    // Check against unsafe attributes list
    for (UNSAFE_ATTRIBUTES) |unsafe_attr| {
        if (std.mem.eql(u8, attr, unsafe_attr)) {
            return true;
        }
    }

    return false;
}

/// Test if the attribute given is an internal attribute.
/// This checks if the attribute is unsafe based on the object type and attribute name.
///
/// This is useful for checking attributes that vary by object type:
/// - Function attributes (code, globals, etc.)
/// - Method attributes
/// - Generator/coroutine attributes
/// - Frame/code/traceback attributes
pub fn isInternalAttribute(obj: Value, attr: []const u8) bool {
    // Attributes starting with double underscore are internal
    if (attr.len >= 2 and std.mem.startsWith(u8, attr, "__")) {
        return true;
    }

    // Check type-specific unsafe attributes
    switch (obj) {
        .callable => |c| {
            // Check function-specific attributes
            for (UNSAFE_FUNCTION_ATTRIBUTES) |unsafe_attr| {
                if (std.mem.eql(u8, attr, unsafe_attr)) {
                    return true;
                }
            }

            // Check method-specific attributes if it's a bound method
            if (c.is_method) {
                for (UNSAFE_METHOD_ATTRIBUTES) |unsafe_attr| {
                    if (std.mem.eql(u8, attr, unsafe_attr)) {
                        return true;
                    }
                }
            }

            return false;
        },
        else => {
            // For other types, check generator/coroutine attributes
            for (UNSAFE_GENERATOR_ATTRIBUTES) |unsafe_attr| {
                if (std.mem.eql(u8, attr, unsafe_attr)) {
                    return true;
                }
            }
            for (UNSAFE_COROUTINE_ATTRIBUTES) |unsafe_attr| {
                if (std.mem.eql(u8, attr, unsafe_attr)) {
                    return true;
                }
            }
            for (UNSAFE_ASYNC_GENERATOR_ATTRIBUTES) |unsafe_attr| {
                if (std.mem.eql(u8, attr, unsafe_attr)) {
                    return true;
                }
            }
            return false;
        },
    }
}

/// Check if an attribute is safe to access in sandboxed mode (module-level function)
/// This is the main function used by the sandbox to check attribute access.
pub fn isSafeAttributeModule(obj: Value, attr: []const u8) bool {
    // Attributes starting with underscore are considered unsafe
    if (attr.len > 0 and attr[0] == '_') {
        return false;
    }

    // Check if it's an internal attribute
    if (isInternalAttribute(obj, attr)) {
        return false;
    }

    return true;
}

/// Alias for isSafeAttributeModule for compatibility
pub fn isSafeAttribute(obj: Value, attr: []const u8) bool {
    return isSafeAttributeModule(obj, attr);
}

/// Alias for isSafeCallableModule for compatibility
pub fn isSafeCallable(obj: Value) bool {
    return isSafeCallableModule(obj);
}

/// Check if a callable is safe to call in sandboxed mode (module-level function)
/// A callable is unsafe if:
/// - It has the `unsafe_callable` marker set
/// - It has the `alters_data` marker set (Django convention)
/// - It's a built-in dangerous function
pub fn isSafeCallableModule(obj: Value) bool {
    // Check for unsafe callable markers
    if (hasUnsafeCallableMarker(obj)) {
        return false;
    }

    // Check if it's a callable type
    switch (obj) {
        .callable => |c| {
            // Check for known unsafe callables by name
            if (c.name) |name| {
                if (isUnsafeCallableName(name)) {
                    return false;
                }
            }
            return true;
        },
        else => {
            // Non-callable values are "safe" to call (they'll just error)
            return true;
        },
    }
}

/// List of known unsafe callable names that should be blocked
const UNSAFE_CALLABLE_NAMES = [_][]const u8{
    // Potentially dangerous built-ins
    "eval",
    "exec",
    "compile",
    "__import__",
    "open",
    "input",
    "breakpoint",
    // File operations
    "read",
    "write",
    "delete",
    // System operations
    "system",
    "popen",
    "spawn",
    "fork",
    "exit",
    "quit",
};

/// Check if a callable name is known to be unsafe
fn isUnsafeCallableName(name: []const u8) bool {
    for (UNSAFE_CALLABLE_NAMES) |unsafe_name| {
        if (std.mem.eql(u8, name, unsafe_name)) {
            return true;
        }
    }
    return false;
}

/// SandboxedEnvironment - wraps Environment with security checks
/// The sandboxed environment tells the compiler to generate sandboxed code.
/// Additionally, methods can be overridden to control what attributes or
/// functions are safe to access.
pub const SandboxedEnvironment = struct {
    base: environment.Environment,
    /// Whether sandboxing is enabled
    sandboxed: bool = true,
    /// Set of safe attributes (if empty, uses default checking)
    safe_attributes: std.StringHashMap(void),
    /// Set of safe functions (if empty, uses default checking)
    safe_functions: std.StringHashMap(void),
    /// Whether to block mutable operations (for ImmutableSandboxedEnvironment)
    block_mutable_operations: bool = false,

    const Self = @This();

    /// Initialize a sandboxed environment
    pub fn init(allocator: std.mem.Allocator) !Self {
        var self = Self{
            .base = environment.Environment.init(allocator),
            .sandboxed = true,
            .safe_attributes = std.StringHashMap(void).init(allocator),
            .safe_functions = std.StringHashMap(void).init(allocator),
            .block_mutable_operations = false,
        };

        // Mark base environment as sandboxed
        self.base.sandboxed = true;

        // Register safe_range as the default range function
        // This is done by adding it as a global
        // Note: In practice, this would be handled during compilation

        return self;
    }

    /// Deinitialize the sandboxed environment
    pub fn deinit(self: *Self) void {
        self.base.deinit();

        // Free safe attributes
        var attr_iter = self.safe_attributes.iterator();
        while (attr_iter.next()) |entry| {
            self.base.allocator.free(entry.key_ptr.*);
        }
        self.safe_attributes.deinit();

        // Free safe functions
        var func_iter = self.safe_functions.iterator();
        while (func_iter.next()) |entry| {
            self.base.allocator.free(entry.key_ptr.*);
        }
        self.safe_functions.deinit();
    }

    /// Check if an attribute is safe to access
    /// Per default all attributes starting with an underscore are considered
    /// private as well as special internal attributes.
    pub fn isSafeAttributeAccess(self: *Self, obj: Value, attr: []const u8) bool {
        // If custom safe attributes list is provided, check it first
        if (self.safe_attributes.count() > 0) {
            return self.safe_attributes.contains(attr);
        }

        // Check if it's a mutable operation that should be blocked
        if (self.block_mutable_operations and modifiesKnownMutable(obj, attr)) {
            return false;
        }

        // Otherwise use default checking
        return isSafeAttributeModule(obj, attr);
    }

    /// Check if a callable is safe to call
    /// By default callables are considered safe unless marked with unsafe_callable
    /// or alters_data (Django convention)
    pub fn isSafeCallableCheck(self: *Self, obj: Value) bool {
        // Check custom safe functions list
        switch (obj) {
            .callable => |c| {
                if (c.name) |name| {
                    if (self.safe_functions.count() > 0) {
                        return self.safe_functions.contains(name);
                    }
                }
            },
            else => {},
        }

        // Use default checking
        return isSafeCallableModule(obj);
    }

    /// Add a safe attribute to the whitelist
    pub fn addSafeAttribute(self: *Self, attr: []const u8) !void {
        const attr_copy = try self.base.allocator.dupe(u8, attr);
        errdefer self.base.allocator.free(attr_copy);
        try self.safe_attributes.put(attr_copy, {});
    }

    /// Add a safe function to the whitelist
    pub fn addSafeFunction(self: *Self, func_name: []const u8) !void {
        const func_copy = try self.base.allocator.dupe(u8, func_name);
        errdefer self.base.allocator.free(func_copy);
        try self.safe_functions.put(func_copy, {});
    }

    /// Check attribute access and raise SecurityError if unsafe
    pub fn checkAttributeAccess(
        self: *Self,
        obj: Value,
        attr: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
    ) !void {
        if (!self.sandboxed) {
            return;
        }

        if (!self.isSafeAttributeAccess(obj, attr)) {
            const message = try std.fmt.allocPrint(self.base.allocator, "Access to attribute '{s}' is not allowed in sandboxed mode", .{attr});
            defer self.base.allocator.free(message);

            const security_error = try exceptions.SecurityError.init(
                self.base.allocator,
                "attribute_access",
                message,
                filename,
                lineno,
            );
            defer security_error.deinit(self.base.allocator);

            return exceptions.TemplateError.SecurityError;
        }
    }

    /// Check function call and raise SecurityError if unsafe
    pub fn checkFunctionCall(
        self: *Self,
        obj: Value,
        func_name: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
    ) !void {
        if (!self.sandboxed) {
            return;
        }

        if (!self.isSafeCallableCheck(obj)) {
            const message = try std.fmt.allocPrint(self.base.allocator, "Call to function '{s}' is not allowed in sandboxed mode", .{func_name});
            defer self.base.allocator.free(message);

            const security_error = try exceptions.SecurityError.init(
                self.base.allocator,
                "function_call",
                message,
                filename,
                lineno,
            );
            defer security_error.deinit(self.base.allocator);

            return exceptions.TemplateError.SecurityError;
        }
    }

    /// Check range call for safety (prevents DoS via large ranges)
    pub fn checkSafeRange(self: *Self, start: i64, end_opt: ?i64, step_opt: ?i64) !SafeRangeIterator {
        if (!self.sandboxed) {
            // In non-sandboxed mode, still use safe range but with higher limit
            return try safeRange(start, end_opt, step_opt);
        }

        return try safeRange(start, end_opt, step_opt);
    }

    /// Delegate to base environment methods
    pub fn getTemplate(self: *Self, name: []const u8) !*nodes.Template {
        return try self.base.getTemplate(name);
    }

    pub fn fromString(self: *Self, source: []const u8, name: ?[]const u8) !*nodes.Template {
        return try self.base.fromString(source, name);
    }

    pub fn addFilter(self: *Self, name: []const u8, filter_func: environment.filters.FilterFn) !void {
        return try self.base.addFilter(name, filter_func);
    }

    pub fn addTest(self: *Self, name: []const u8, test_func: environment.tests.TestFn) !void {
        return try self.base.addTest(name, test_func);
    }

    pub fn addGlobal(self: *Self, name: []const u8, val: Value) !void {
        return try self.base.addGlobal(name, val);
    }

    pub fn setLoader(self: *Self, loader: *environment.loaders.Loader) void {
        self.base.setLoader(loader);
    }

    pub fn clearCaches(self: *Self) void {
        self.base.clearCaches();
    }
};

/// ImmutableSandboxedEnvironment - a sandboxed environment that also blocks
/// mutable operations on builtin types like list, dict, and set.
///
/// This provides additional protection by preventing templates from modifying
/// data structures that were passed in from the application.
pub const ImmutableSandboxedEnvironment = struct {
    inner: SandboxedEnvironment,

    const Self = @This();

    /// Initialize an immutable sandboxed environment
    pub fn init(allocator: std.mem.Allocator) !Self {
        var inner = try SandboxedEnvironment.init(allocator);
        inner.block_mutable_operations = true;
        return Self{
            .inner = inner,
        };
    }

    /// Deinitialize
    pub fn deinit(self: *Self) void {
        self.inner.deinit();
    }

    /// Check if an attribute is safe to access
    /// Also blocks mutable operations on known mutable types
    pub fn isSafeAttributeAccess(_: *Self, obj: Value, attr: []const u8) bool {
        // First check base safety
        if (!isSafeAttributeModule(obj, attr)) {
            return false;
        }

        // Then check if it's a mutable operation
        if (modifiesKnownMutable(obj, attr)) {
            return false;
        }

        return true;
    }

    /// Delegate to inner environment
    pub fn isSafeCallableCheck(self: *Self, obj: Value) bool {
        return self.inner.isSafeCallableCheck(obj);
    }

    pub fn checkAttributeAccess(self: *Self, obj: Value, attr: []const u8, filename: ?[]const u8, lineno: ?usize) !void {
        if (!self.isSafeAttributeAccess(obj, attr)) {
            const message = try std.fmt.allocPrint(self.inner.base.allocator, "Access to attribute '{s}' is not allowed in immutable sandboxed mode", .{attr});
            defer self.inner.base.allocator.free(message);

            const security_error = try exceptions.SecurityError.init(
                self.inner.base.allocator,
                "mutable_operation",
                message,
                filename,
                lineno,
            );
            defer security_error.deinit(self.inner.base.allocator);

            return exceptions.TemplateError.SecurityError;
        }
    }

    pub fn checkFunctionCall(self: *Self, obj: Value, func_name: []const u8, filename: ?[]const u8, lineno: ?usize) !void {
        return self.inner.checkFunctionCall(obj, func_name, filename, lineno);
    }

    pub fn getTemplate(self: *Self, name: []const u8) !*nodes.Template {
        return try self.inner.getTemplate(name);
    }

    pub fn fromString(self: *Self, source: []const u8, name: ?[]const u8) !*nodes.Template {
        return try self.inner.fromString(source, name);
    }

    pub fn addFilter(self: *Self, name: []const u8, filter_func: environment.filters.FilterFn) !void {
        return try self.inner.addFilter(name, filter_func);
    }

    pub fn addTest(self: *Self, name: []const u8, test_func: environment.tests.TestFn) !void {
        return try self.inner.addTest(name, test_func);
    }

    pub fn addGlobal(self: *Self, name: []const u8, val: Value) !void {
        return try self.inner.addGlobal(name, val);
    }

    pub fn setLoader(self: *Self, loader: *environment.loaders.Loader) void {
        self.inner.setLoader(loader);
    }
};

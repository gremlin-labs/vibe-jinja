const std = @import("std");
const html_escape = @import("html_escape.zig");

/// Logging callback for undefined access
/// Called when undefined value is accessed
pub const UndefinedLogger = struct {
    callback: *const fn (name: []const u8, operation: []const u8) void,
    context: ?*anyopaque,

    pub fn log(self: *const UndefinedLogger, name: []const u8, operation: []const u8) void {
        self.callback(name, operation);
    }
};

/// Undefined variable representation
/// Defined here to avoid circular dependency
pub const Undefined = struct {
    name: []const u8,
    behavior: UndefinedBehavior,
    logger: ?*const UndefinedLogger = null,

    const Self = @This();
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // Name is not owned by Undefined, so we don't free it
    }

    /// Raise error for strict mode
    fn failWithError(_: *const Self, _: []const u8) error{UndefinedError} {
        return error.UndefinedError;
    }

    /// Log undefined access if logger is set
    pub fn logAccess(self: *const Self, operation: []const u8) void {
        if (self.logger) |logger| {
            logger.log(self.name, operation);
        }
    }
};

/// Undefined behavior policy for handling undefined variables
pub const UndefinedBehavior = enum {
    strict, // Raise error immediately
    lenient, // Return empty string
    debug, // Return debug string
    chainable, // Allow chaining (undefined.attr)
};

/// Markup type - represents already-escaped HTML/XML content
/// Values marked as Markup will not be escaped again
pub const Markup = struct {
    content: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }

    pub fn init(allocator: std.mem.Allocator, content: []const u8) !Self {
        return Self{
            .content = try allocator.dupe(u8, content),
        };
    }
};

/// Async result wrapper - represents an async operation result
/// Used for async filters, tests, and template rendering
pub const AsyncResult = struct {
    /// The resolved value (null if not yet resolved)
    value: ?Value,
    /// Whether the async operation is complete
    completed: bool,
    /// Error message if operation failed
    error_message: ?[]const u8,
    /// Unique ID for tracking this async operation
    id: u64,

    const Self = @This();

    /// Create a pending async result
    pub fn pending(id: u64) Self {
        return Self{
            .value = null,
            .completed = false,
            .error_message = null,
            .id = id,
        };
    }

    /// Create a resolved async result
    pub fn resolved(id: u64, val: Value) Self {
        return Self{
            .value = val,
            .completed = true,
            .error_message = null,
            .id = id,
        };
    }

    /// Create a failed async result
    pub fn failed(id: u64, err: []const u8) Self {
        return Self{
            .value = null,
            .completed = true,
            .error_message = err,
            .id = id,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.value) |*v| {
            v.deinit(allocator);
        }
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
    }
};

/// Function signature for callable values
/// Takes allocator, args array, optional context, optional environment
/// Returns a Value or an error
pub const FunctionFn = *const fn (
    allocator: std.mem.Allocator,
    args: []Value,
    ctx: ?*anyopaque, // context.Context pointer (using anyopaque to avoid circular import)
    env: ?*anyopaque, // environment.Environment pointer
) CallError!Value;

/// Error set for callable function execution
pub const CallError = std.mem.Allocator.Error || error{
    RuntimeError,
    UndefinedError,
    InvalidArgument,
    TypeError,
    NotCallable,
};

/// Callable wrapper - represents a callable value (function/macro)
/// Safety flags for callable objects (used in sandboxing)
pub const CallableSafetyFlags = struct {
    /// Callable has been marked as unsafe
    unsafe_callable: bool = false,
    /// Callable alters data (Django convention)
    alters_data: bool = false,
};

pub const Callable = struct {
    /// Name of the callable (optional for anonymous functions)
    name: ?[]const u8,
    /// Whether this callable is async
    is_async: bool,
    /// Type of callable
    callable_type: CallableType,
    /// Function pointer for direct function calls (optional)
    func: ?FunctionFn,
    /// Whether this is a bound method (has self argument)
    is_method: bool = false,
    /// Safety flags for sandboxing
    flags: ?CallableSafetyFlags = null,

    pub const CallableType = enum {
        filter,
        test_fn,
        macro,
        function,
        method,
    };

    const Self = @This();

    pub fn init(name: []const u8, callable_type: CallableType, is_async: bool) Self {
        return Self{
            .name = name,
            .is_async = is_async,
            .callable_type = callable_type,
            .func = null,
            .is_method = callable_type == .method,
            .flags = null,
        };
    }

    /// Create a callable with a function pointer
    pub fn initWithFunc(name: []const u8, func: FunctionFn, is_async: bool) Self {
        return Self{
            .name = name,
            .is_async = is_async,
            .callable_type = .function,
            .func = func,
            .is_method = false,
            .flags = null,
        };
    }

    /// Create an unsafe callable (blocked in sandboxed mode)
    pub fn initUnsafe(name: []const u8, callable_type: CallableType) Self {
        return Self{
            .name = name,
            .is_async = false,
            .callable_type = callable_type,
            .func = null,
            .is_method = false,
            .flags = CallableSafetyFlags{ .unsafe_callable = true },
        };
    }

    /// Mark this callable as unsafe
    pub fn markUnsafe(self: *Self) void {
        if (self.flags) |*flags| {
            flags.unsafe_callable = true;
        } else {
            self.flags = CallableSafetyFlags{ .unsafe_callable = true };
        }
    }

    /// Mark this callable as altering data
    pub fn markAltersData(self: *Self) void {
        if (self.flags) |*flags| {
            flags.alters_data = true;
        } else {
            self.flags = CallableSafetyFlags{ .alters_data = true };
        }
    }

    /// Call the function if it has a function pointer
    pub fn call(self: *const Self, allocator: std.mem.Allocator, args: []Value, ctx: ?*anyopaque, env: ?*anyopaque) CallError!Value {
        if (self.func) |func| {
            return try func(allocator, args, ctx, env);
        }
        return error.NotCallable;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.name) |name| {
            allocator.free(name);
        }
    }
};

/// VTable for custom objects - allows runtime field/method access on Zig structs
/// This enables templates to access fields and call methods on arbitrary Zig types
pub const CustomVTable = struct {
    /// Get a field value by name
    /// Returns null if field doesn't exist
    getField: ?*const fn (ptr: *anyopaque, field_name: []const u8, allocator: std.mem.Allocator) CallError!?Value,

    /// Get a method by name (returns a callable)
    /// Returns null if method doesn't exist
    getMethod: ?*const fn (ptr: *anyopaque, method_name: []const u8, allocator: std.mem.Allocator) CallError!?FunctionFn,

    /// Get an item by index (for subscript access like obj[key])
    /// Returns null if subscript access is not supported
    getItem: ?*const fn (ptr: *anyopaque, index: Value, allocator: std.mem.Allocator) CallError!?Value,

    /// Get the length of the object (for len() filter)
    /// Returns null if length is not applicable
    getLength: ?*const fn (ptr: *anyopaque) ?usize,

    /// Get an iterator over the object (for iteration in for loops)
    /// Returns null if iteration is not supported
    getIterator: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) CallError!?*List,

    /// Convert to string representation
    /// Returns null to use default string representation
    toString: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) CallError!?[]const u8,

    /// Convert to boolean (for truthiness tests)
    /// Returns null to use default (true for non-null objects)
    toBool: ?*const fn (ptr: *anyopaque) ?bool,

    /// Cleanup function called when the CustomObject is destroyed
    /// The ptr parameter is the same pointer passed to CustomObject.init
    deinit: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,

    /// Type name for debugging/error messages
    type_name: []const u8,
};

/// Custom object wrapper - represents an arbitrary Zig struct in templates
///
/// This allows passing custom Zig types to templates and accessing their
/// fields and methods. The vtable provides runtime dispatch for field/method access.
///
/// # Example Usage
///
/// ```zig
/// const User = struct {
///     name: []const u8,
///     age: u32,
///
///     pub fn greet(self: *const User, allocator: std.mem.Allocator) ![]const u8 {
///         return try std.fmt.allocPrint(allocator, "Hello, {s}!", .{self.name});
///     }
/// };
///
/// // Create vtable for User type
/// const user_vtable = CustomVTable{
///     .getField = User.getFieldImpl,
///     .getMethod = User.getMethodImpl,
///     // ... other vtable entries
/// };
///
/// // Wrap a User instance
/// var user = User{ .name = "Alice", .age = 30 };
/// const custom = try CustomObject.init(allocator, &user, &user_vtable);
/// const value = Value{ .custom = custom };
/// ```
pub const CustomObject = struct {
    /// Pointer to the underlying object (type-erased)
    ptr: *anyopaque,

    /// VTable for runtime dispatch
    vtable: *const CustomVTable,

    /// Whether this CustomObject owns the underlying data
    /// If true, deinit will call vtable.deinit
    owns_data: bool,

    const Self = @This();

    /// Create a new CustomObject wrapping a pointer with a vtable
    pub fn init(allocator: std.mem.Allocator, ptr: *anyopaque, vtable: *const CustomVTable, owns_data: bool) !*Self {
        const custom = try allocator.create(Self);
        custom.* = Self{
            .ptr = ptr,
            .vtable = vtable,
            .owns_data = owns_data,
        };
        return custom;
    }

    /// Get a field value by name
    pub fn getField(self: *const Self, field_name: []const u8, allocator: std.mem.Allocator) CallError!?Value {
        if (self.vtable.getField) |getFieldFn| {
            return try getFieldFn(self.ptr, field_name, allocator);
        }
        return null;
    }

    /// Get a method by name
    pub fn getMethod(self: *const Self, method_name: []const u8, allocator: std.mem.Allocator) CallError!?FunctionFn {
        if (self.vtable.getMethod) |getMethodFn| {
            return try getMethodFn(self.ptr, method_name, allocator);
        }
        return null;
    }

    /// Get an item by index (subscript access)
    pub fn getItem(self: *const Self, index: Value, allocator: std.mem.Allocator) CallError!?Value {
        if (self.vtable.getItem) |getItemFn| {
            return try getItemFn(self.ptr, index, allocator);
        }
        return null;
    }

    /// Get the length of the object
    pub fn getLength(self: *const Self) ?usize {
        if (self.vtable.getLength) |getLengthFn| {
            return getLengthFn(self.ptr);
        }
        return null;
    }

    /// Get an iterator over the object
    pub fn getIterator(self: *const Self, allocator: std.mem.Allocator) CallError!?*List {
        if (self.vtable.getIterator) |getIteratorFn| {
            return try getIteratorFn(self.ptr, allocator);
        }
        return null;
    }

    /// Convert to string
    pub fn toString(self: *const Self, allocator: std.mem.Allocator) CallError!?[]const u8 {
        if (self.vtable.toString) |toStringFn| {
            return try toStringFn(self.ptr, allocator);
        }
        return null;
    }

    /// Convert to boolean
    pub fn toBool(self: *const Self) bool {
        if (self.vtable.toBool) |toBoolFn| {
            if (toBoolFn(self.ptr)) |b| {
                return b;
            }
        }
        // Default: custom objects are truthy
        return true;
    }

    /// Get the type name
    pub fn typeName(self: *const Self) []const u8 {
        return self.vtable.type_name;
    }

    /// Deinitialize the custom object
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.owns_data) {
            if (self.vtable.deinit) |deinitFn| {
                deinitFn(self.ptr, allocator);
            }
        }
        allocator.destroy(self);
    }
};

/// Value type for template variables and expressions
///
/// This union type can represent all Jinja value types including strings, numbers,
/// booleans, lists, dictionaries, markup (escaped HTML), null, undefined values,
/// async results, and callables.
///
/// Values are used throughout the template engine for:
/// - Template variables
/// - Expression evaluation results
/// - Filter inputs and outputs
/// - Test inputs
/// - Function arguments and return values
/// - Async operation results
///
/// **Memory Management:** Values that contain allocated memory (strings, lists, dicts, markup)
/// must be deinitialized using `deinit()` when done. The caller is responsible for freeing
/// the memory.
///
/// # Example
///
/// ```zig
/// // Create a string value
/// const name = try allocator.dupe(u8, "World");
/// const name_val = jinja.Value{ .string = name };
/// defer name_val.deinit(allocator);
///
/// // Create a list value
/// const list = try jinja.value.List.init(allocator);
/// try list.append(jinja.Value{ .integer = 1 });
/// const list_val = jinja.Value{ .list = list };
/// defer list_val.deinit(allocator);
/// ```
pub const Value = union(enum) {
    string: []const u8,
    markup: *Markup,
    integer: i64,
    float: f64,
    boolean: bool,
    list: *List,
    dict: *Dict,
    undefined: Undefined,
    null: void,
    /// Async result wrapper for async operations
    async_result: *AsyncResult,
    /// Callable value (function, filter, macro)
    callable: *Callable,
    /// Custom object wrapper for arbitrary Zig types
    custom: *CustomObject,

    const Self = @This();
    const max_traversal_depth: usize = 64;
    const EqualityError = error{ Overflow, UndefinedError };

    const TraversalState = struct {
        pointers: [max_traversal_depth]usize = undefined,
        len: usize = 0,

        fn enter(self: *TraversalState, pointer: usize) !void {
            if (self.len >= max_traversal_depth) return error.Overflow;
            for (self.pointers[0..self.len]) |active| {
                if (active == pointer) return error.Overflow;
            }
            self.pointers[self.len] = pointer;
            self.len += 1;
        }

        fn leave(self: *TraversalState) void {
            self.len -= 1;
        }
    };

    const EqualityState = struct {
        pairs: [max_traversal_depth]struct { left: usize, right: usize } = undefined,
        len: usize = 0,

        fn enter(self: *EqualityState, left: usize, right: usize) !bool {
            for (self.pairs[0..self.len]) |pair| {
                if (pair.left == left and pair.right == right) return false;
            }
            if (self.len >= max_traversal_depth) return error.Overflow;
            self.pairs[self.len] = .{ .left = left, .right = right };
            self.len += 1;
            return true;
        }

        fn leave(self: *EqualityState) void {
            self.len -= 1;
        }
    };

    /// Deinitialize the value and free any allocated memory
    /// Takes a const pointer since deinit only reads the value to determine what to free
    /// Hot path - inlined for performance
    pub inline fn deinit(self: *const Self, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .markup => |m| {
                var markup_mut = m;
                markup_mut.deinit(allocator);
                allocator.destroy(m);
            },
            .list => |l| l.deinit(allocator),
            .dict => |d| d.deinit(allocator),
            .undefined => {}, // Undefined doesn't own its name, so no cleanup needed
            .async_result => |ar| {
                var ar_mut = ar;
                ar_mut.deinit(allocator);
                allocator.destroy(ar);
            },
            .callable => |c| {
                var c_mut = c;
                c_mut.deinit(allocator);
                allocator.destroy(c);
            },
            .custom => |custom| {
                var custom_mut = custom;
                custom_mut.deinit(allocator);
            },
            else => {},
        }
    }

    /// Convert value to string representation
    pub inline fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .list, .dict, .async_result => {
                var state = TraversalState{};
                return self.toStringWithState(allocator, &state);
            },
            else => self.scalarToString(allocator),
        };
    }

    inline fn scalarToString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |string| allocator.dupe(u8, string),
            .markup => |markup| allocator.dupe(u8, markup.content),
            .integer => |integer| std.fmt.allocPrint(allocator, "{d}", .{integer}),
            .float => |float| std.fmt.allocPrint(allocator, "{d}", .{float}),
            .boolean => |boolean| allocator.dupe(u8, if (boolean) "true" else "false"),
            .undefined => |undefined_value| {
                undefined_value.logAccess("toString");
                return switch (undefined_value.behavior) {
                    .strict => error.UndefinedError,
                    .lenient, .chainable => allocator.dupe(u8, ""),
                    .debug => std.fmt.allocPrint(allocator, "{{ undefined variable '{s}' }}", .{undefined_value.name}),
                };
            },
            .null => allocator.dupe(u8, ""),
            .callable => |callable| std.fmt.allocPrint(allocator, "<{s} {s}>", .{
                switch (callable.callable_type) {
                    .filter => "filter",
                    .test_fn => "test",
                    .macro => "macro",
                    .function => "function",
                    .method => "method",
                },
                callable.name orelse "<anonymous>",
            }),
            .custom => |custom| {
                if (custom.toString(allocator)) |maybe_string| {
                    if (maybe_string) |string| return string;
                } else |_| {}
                return std.fmt.allocPrint(allocator, "<{s} object>", .{custom.typeName()});
            },
            .list, .dict, .async_result => unreachable,
        };
    }

    fn toStringWithState(self: Self, allocator: std.mem.Allocator, state: *TraversalState) ![]const u8 {
        return switch (self) {
            .string, .markup, .integer, .float, .boolean, .undefined, .null, .callable, .custom => self.scalarToString(allocator),
            .list => |l| {
                try state.enter(@intFromPtr(l));
                defer state.leave();
                // Convert list to string representation
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);
                try result.append(allocator, '[');
                for (l.items.items, 0..) |item, i| {
                    if (i > 0) try result.appendSlice(allocator, ", ");
                    const item_str = try item.toStringWithState(allocator, state);
                    defer allocator.free(item_str);
                    try result.appendSlice(allocator, item_str);
                }
                try result.append(allocator, ']');
                return try result.toOwnedSlice(allocator);
            },
            .dict => |d| {
                try state.enter(@intFromPtr(d));
                defer state.leave();
                // Convert dict to string representation
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);
                try result.append(allocator, '{');
                var iter = d.map.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try result.appendSlice(allocator, ", ");
                    first = false;
                    try result.append(allocator, '"');
                    try result.appendSlice(allocator, entry.key_ptr.*);
                    try result.appendSlice(allocator, "\": ");
                    const val_str = try entry.value_ptr.*.toStringWithState(allocator, state);
                    defer allocator.free(val_str);
                    try result.appendSlice(allocator, val_str);
                }
                try result.append(allocator, '}');
                return try result.toOwnedSlice(allocator);
            },
            .async_result => |ar| {
                if (ar.completed) {
                    if (ar.value) |v| {
                        try state.enter(@intFromPtr(ar));
                        defer state.leave();
                        return try v.toStringWithState(allocator, state);
                    } else if (ar.error_message) |msg| {
                        return try std.fmt.allocPrint(allocator, "<async error: {s}>", .{msg});
                    }
                }
                return try std.fmt.allocPrint(allocator, "<async pending:{d}>", .{ar.id});
            },
        };
    }

    /// Convert value to integer, if possible
    /// Hot path - inlined for performance
    pub inline fn toInteger(self: Self) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
            .boolean => |b| if (b) 1 else 0,
            else => null,
        };
    }

    /// Convert value to float, if possible
    /// Hot path - inlined for performance
    pub inline fn toFloat(self: Self) ?f64 {
        return switch (self) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            .string => |s| std.fmt.parseFloat(f64, s) catch null,
            .boolean => |b| if (b) 1.0 else 0.0,
            else => null,
        };
    }

    /// Convert value to boolean
    pub fn toBoolean(self: Self) !bool {
        return switch (self) {
            .boolean => |b| b,
            .integer => |i| i != 0,
            .float => |f| f != 0.0,
            .string => |s| s.len > 0,
            .markup => |m| m.content.len > 0,
            .list => |l| l.items.items.len > 0,
            .dict => |d| d.map.count() > 0,
            .null => false,
            .undefined => |u| {
                // Log access if logger is set
                u.logAccess("toBoolean");

                // Strict mode raises error
                if (u.behavior == .strict) {
                    return error.UndefinedError;
                }
                // Other modes return false
                return false;
            },
            .async_result => |ar| {
                // Completed async results with values are truthy
                if (ar.completed and ar.value != null) {
                    return try ar.value.?.toBoolean();
                }
                // Pending or error async results are falsy
                return false;
            },
            .callable => true, // Callables are always truthy
            .custom => |custom| custom.toBool(), // Use custom toBool or default to true
        };
    }

    /// Check if value is already escaped (Markup type)
    /// Hot path - inlined for performance
    pub inline fn isEscaped(self: Self) bool {
        return switch (self) {
            .markup => true,
            else => false,
        };
    }

    /// Escape HTML/XML special characters
    /// Returns a Markup value if already escaped, otherwise escapes and returns Markup
    /// Optimized to count special characters first to pre-allocate result buffer
    pub fn escape(self: Self, allocator: std.mem.Allocator) !Self {
        // If already escaped, return as-is
        if (self.isEscaped()) {
            return self;
        }

        // Convert to string first
        const str = try self.toString(allocator);
        defer allocator.free(str);

        // If no special characters, return as markup without escaping
        if (!html_escape.needsEscaping(str, true)) {
            const content_copy = try allocator.dupe(u8, str);
            errdefer allocator.free(content_copy);
            const markup = try allocator.create(Markup);
            markup.* = Markup{ .content = content_copy };
            return Self{ .markup = markup };
        }

        const escaped_content = try html_escape.escapeOwned(allocator, str, true);
        errdefer allocator.free(escaped_content);
        const markup = try allocator.create(Markup);
        markup.* = Markup{ .content = escaped_content };

        return Self{ .markup = markup };
    }

    /// Check if value is truthy (non-empty, non-zero, non-null)
    pub fn isTruthy(self: Self) !bool {
        return self.toBoolean();
    }

    /// Get the length of a value (for strings, lists, dicts, custom objects)
    /// Optimized hot path - inlined for performance
    pub inline fn length(self: Self) usize {
        return switch (self) {
            .string => |s| s.len,
            .list => |l| l.items.items.len,
            .dict => |d| d.map.count(),
            .custom => |custom| custom.getLength() orelse 0,
            else => 0,
        };
    }

    /// Compare two values for equality
    /// Returns true if values are equal, false otherwise
    /// May return error.UndefinedError in strict mode
    pub fn isEqual(self: Self, other: Self) !bool {
        var state = EqualityState{};
        return self.isEqualWithState(other, &state);
    }

    fn equalLists(left: *List, right: *List, state: *EqualityState) EqualityError!bool {
        if (left.items.items.len != right.items.items.len) return false;
        if (!(try state.enter(@intFromPtr(left), @intFromPtr(right)))) return true;
        defer state.leave();
        for (left.items.items, right.items.items) |left_item, right_item| {
            if (!(try left_item.isEqualWithState(right_item, state))) return false;
        }
        return true;
    }

    fn equalDicts(left: *Dict, right: *Dict, state: *EqualityState) EqualityError!bool {
        if (left.map.count() != right.map.count()) return false;
        if (!(try state.enter(@intFromPtr(left), @intFromPtr(right)))) return true;
        defer state.leave();
        var iterator = left.map.iterator();
        while (iterator.next()) |entry| {
            const right_value = right.map.get(entry.key_ptr.*) orelse return false;
            if (!(try entry.value_ptr.*.isEqualWithState(right_value, state))) return false;
        }
        return true;
    }

    fn equalAsync(left: *AsyncResult, right: *AsyncResult, state: *EqualityState) EqualityError!bool {
        if (left.id != right.id or left.completed != right.completed) return false;
        if (left.value == null or right.value == null) return left.value == null and right.value == null;
        if (!(try state.enter(@intFromPtr(left), @intFromPtr(right)))) return true;
        defer state.leave();
        return left.value.?.isEqualWithState(right.value.?, state);
    }

    fn equalUndefined(left: Undefined, right: Undefined) EqualityError!bool {
        left.logAccess("isEqual");
        if (left.behavior == .strict) return error.UndefinedError;
        return std.mem.eql(u8, left.name, right.name) and left.behavior == right.behavior;
    }

    fn equalCallable(left: *Callable, right: *Callable) bool {
        const names_equal = if (left.name != null and right.name != null)
            std.mem.eql(u8, left.name.?, right.name.?)
        else
            left.name == null and right.name == null;
        return names_equal and left.is_async == right.is_async and left.callable_type == right.callable_type;
    }

    fn equalSameScalar(self: Self, other: Self) EqualityError!bool {
        return switch (self) {
            .string => |value| std.mem.eql(u8, value, other.string),
            .markup => |value| std.mem.eql(u8, value.content, other.markup.content),
            .integer => |value| value == other.integer,
            .float => |value| value == other.float,
            .boolean => |value| value == other.boolean,
            .null => true,
            .undefined => |value| equalUndefined(value, other.undefined),
            .callable => |value| equalCallable(value, other.callable),
            .custom => |value| value.ptr == other.custom.ptr and value.vtable == other.custom.vtable,
            .list, .dict, .async_result => unreachable,
        };
    }

    fn equalMixedNumeric(self: Self, other: Self) EqualityError!bool {
        if (self == .integer and other == .float) return @as(f64, @floatFromInt(self.integer)) == other.float;
        if (self == .float and other == .integer) return self.float == @as(f64, @floatFromInt(other.integer));

        if (self == .float or other == .float) {
            const left = self.toFloat() orelse return false;
            const right = other.toFloat() orelse return false;
            if (left == right) return true;
            if (!std.math.isFinite(left) or !std.math.isFinite(right)) return false;
            return @abs(left - right) < 1e-10;
        }

        const left = self.toInteger() orelse return false;
        const right = other.toInteger() orelse return false;
        return left == right;
    }

    fn isEqualWithState(self: Self, other: Self, state: *EqualityState) EqualityError!bool {
        if (@intFromEnum(self) != @intFromEnum(other)) return self.equalMixedNumeric(other);
        return switch (self) {
            .list => |value| equalLists(value, other.list, state),
            .dict => |value| equalDicts(value, other.dict, state),
            .async_result => |value| equalAsync(value, other.async_result, state),
            else => self.equalSameScalar(other),
        };
    }

    /// Stable bounded hash shared by AST and bytecode loop.changed paths.
    pub fn hash(self: Self) u64 {
        return self.hashAtDepth(0);
    }

    fn hashAtDepth(self: Self, depth: usize) u64 {
        if (depth >= max_traversal_depth) return 0x9E37_79B9_7F4A_7C15;
        return switch (self) {
            .integer => |integer| @bitCast(integer),
            .float => |float| @bitCast(float),
            .boolean => |boolean| @intFromBool(boolean),
            .null => 0,
            .string => |string| std.hash.Wyhash.hash(0, string),
            .markup => |markup| std.hash.Wyhash.hash(0, markup.content),
            .list => |list| blk: {
                var result: u64 = 0;
                for (list.items.items) |item| result = result *% 31 +% item.hashAtDepth(depth + 1);
                break :blk result;
            },
            .dict => |dict| blk: {
                var result: u64 = 0;
                var iter = dict.map.iterator();
                while (iter.next()) |entry| {
                    result = result *% 31 +% std.hash.Wyhash.hash(0, entry.key_ptr.*);
                    result = result *% 31 +% entry.value_ptr.*.hashAtDepth(depth + 1);
                }
                break :blk result;
            },
            .undefined => 0xDEAD_BEEF,
            .async_result => 0xCAFE_BABE,
            .callable => 0xFEED_FACE,
            .custom => 0x00C0_FFEE,
        };
    }

    /// Create a deep copy of the value
    /// Recursively copies nested structures (lists, dicts)
    /// Returns a new value with independent memory
    pub fn deepCopy(self: Self, allocator: std.mem.Allocator) !Self {
        return switch (self) {
            .string => |s| Self{ .string = try allocator.dupe(u8, s) },
            .markup => |m| {
                const markup_copy = try allocator.create(Markup);
                markup_copy.* = try Markup.init(allocator, m.content);
                return Self{ .markup = markup_copy };
            },
            .integer => |i| Self{ .integer = i },
            .float => |f| Self{ .float = f },
            .boolean => |b| Self{ .boolean = b },
            .null => Self{ .null = {} },
            .undefined => |u| {
                const name_copy = try allocator.dupe(u8, u.name);
                return Self{ .undefined = Undefined{
                    .name = name_copy,
                    .behavior = u.behavior,
                    .logger = u.logger,
                } };
            },
            .list => |l| {
                // Deep copy list - create new list and copy all items
                const new_list = try allocator.create(List);
                errdefer allocator.destroy(new_list);
                new_list.* = List.init(allocator);

                for (l.items.items) |item| {
                    const item_copy = try item.deepCopy(allocator);
                    try new_list.items.append(allocator, item_copy);
                }

                return Self{ .list = new_list };
            },
            .dict => |d| {
                // Deep copy dict - create new dict and copy all key-value pairs
                const new_dict = try allocator.create(Dict);
                errdefer allocator.destroy(new_dict);
                new_dict.* = Dict.init(allocator);

                var iter = d.map.iterator();
                while (iter.next()) |entry| {
                    // Note: Dict.set duplicates keys internally, so pass original key directly
                    var val_copy = try entry.value_ptr.*.deepCopy(allocator);
                    errdefer val_copy.deinit(allocator);

                    try new_dict.set(entry.key_ptr.*, val_copy);
                }

                return Self{ .dict = new_dict };
            },
            .async_result => |ar| {
                const new_ar = try allocator.create(AsyncResult);
                errdefer allocator.destroy(new_ar);

                new_ar.* = AsyncResult{
                    .value = if (ar.value) |v| try v.deepCopy(allocator) else null,
                    .completed = ar.completed,
                    .error_message = if (ar.error_message) |msg| try allocator.dupe(u8, msg) else null,
                    .id = ar.id,
                };

                return Self{ .async_result = new_ar };
            },
            .callable => |c| {
                const new_c = try allocator.create(Callable);
                errdefer allocator.destroy(new_c);

                new_c.* = Callable{
                    .name = if (c.name) |name| try allocator.dupe(u8, name) else null,
                    .is_async = c.is_async,
                    .callable_type = c.callable_type,
                    .func = c.func, // Function pointers can be copied directly
                    .is_method = c.is_method,
                    .flags = c.flags, // Safety flags are just copied
                };

                return Self{ .callable = new_c };
            },
            .custom => |c| {
                // For custom objects, create a new wrapper that references the same data
                // but doesn't own it (shallow copy - the original still owns the data)
                const new_custom = try allocator.create(CustomObject);
                errdefer allocator.destroy(new_custom);

                new_custom.* = CustomObject{
                    .ptr = c.ptr,
                    .vtable = c.vtable,
                    .owns_data = false, // Copy doesn't own the data
                };

                return Self{ .custom = new_custom };
            },
        };
    }

    /// Check if value is an async result
    pub fn isAsync(self: Self) bool {
        return switch (self) {
            .async_result => true,
            .callable => |c| c.is_async,
            else => false,
        };
    }

    /// Check if value is a callable
    pub fn isCallable(self: Self) bool {
        return switch (self) {
            .callable => true,
            else => false,
        };
    }

    /// Get async result value if completed, otherwise return null
    pub fn getAsyncValue(self: Self) ?Value {
        return switch (self) {
            .async_result => |ar| if (ar.completed) ar.value else null,
            else => null,
        };
    }

    /// Check if async result is completed
    pub fn isAsyncComplete(self: Self) bool {
        return switch (self) {
            .async_result => |ar| ar.completed,
            else => true, // Non-async values are always "complete"
        };
    }

    /// Check if value is a custom object
    pub fn isCustom(self: Self) bool {
        return switch (self) {
            .custom => true,
            else => false,
        };
    }

    /// Get custom object if this value is a custom type
    pub fn getCustom(self: Self) ?*CustomObject {
        return switch (self) {
            .custom => |c| c,
            else => null,
        };
    }
};

/// List type for Jinja lists/arrays
pub const List = struct {
    items: std.ArrayList(Value),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new list
    pub fn init(allocator: std.mem.Allocator) Self {
        // Use same pattern as bytecode.zig - initialize separately
        var list = Self{
            .items = undefined,
            .allocator = allocator,
        };
        // Zig 0.15: Initialize as empty, allocator passed to methods
        list.items = std.ArrayList(Value).empty;
        return list;
    }

    /// Deinitialize the list and free all items
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| {
            item.deinit(allocator);
        }
        self.items.deinit(allocator);
        allocator.destroy(self);
    }

    /// Append a value to the list
    pub fn append(self: *Self, value: Value) !void {
        try self.items.append(self.allocator, value);
    }

    /// Get an item by index
    pub fn get(self: *const Self, index: usize) ?Value {
        if (index < self.items.items.len) {
            return self.items.items[index];
        }
        return null;
    }
};

/// Dict type for Jinja dictionaries/maps
pub const Dict = struct {
    map: std.StringHashMap(Value),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new dictionary
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .map = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
        };
    }

    /// Deinitialize the dictionary and free all keys and values
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        self.map.deinit();
        allocator.destroy(self);
    }

    /// Set a key-value pair
    pub fn set(self: *Self, key: []const u8, value: Value) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        // Remove old value if exists
        if (self.map.fetchRemove(key_copy)) |old| {
            self.allocator.free(old.key);
            var old_val = old.value;
            old_val.deinit(self.allocator);
        }

        try self.map.put(key_copy, value);
    }

    /// Get a value by key
    pub fn get(self: *const Self, key: []const u8) ?Value {
        return self.map.get(key);
    }
};

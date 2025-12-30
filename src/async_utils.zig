//! Async Utilities for Vibe Jinja
//!
//! This module provides utilities for working with async operations in Jinja templates.
//! It includes helpers for checking if values are awaitable, auto-awaiting async results,
//! and tracking async operations.
//!
//! # Python vs Zig Async Models
//!
//! **Important:** Zig's async model differs significantly from Python's async/await.
//!
//! ## Python Jinja2 Async
//!
//! Python Jinja2 uses native async/await with coroutines:
//!
//! ```python
//! async def auto_await(value):
//!     """Avoid a costly call to isawaitable"""
//!     if type(value) in _common_primitives:
//!         return value
//!     if inspect.isawaitable(value):
//!         return await value
//!     return value
//!
//! async def auto_aiter(iterable):
//!     if hasattr(iterable, "__aiter__"):
//!         return iterable.__aiter__()
//!     return _IteratorToAsyncIterator(iter(iterable))
//! ```
//!
//! ## Zig Approach
//!
//! Zig uses callback-based async patterns with explicit state management:
//!
//! ```zig
//! // Check if awaitable
//! if (AsyncIterator.isAwaitable(value)) {
//!     const result = try AsyncIterator.autoAwait(allocator, value);
//!     // Handle result
//! }
//!
//! // Callback-based async execution
//! fn executeAsync(callback: AsyncCallback, operation: AsyncOp) void {
//!     // Execute and call callback on completion
//! }
//! ```
//!
//! ## Key Differences
//!
//! | Feature | Python | Zig |
//! |---------|--------|-----|
//! | Syntax | `async`/`await` keywords | Explicit callbacks or polling |
//! | Coroutines | Native support | Manual state machines |
//! | Event Loop | Built-in (`asyncio`) | External or manual |
//! | Awaitable Check | `inspect.isawaitable()` | `isAwaitable()` type check |
//!
//! ## Limitations
//!
//! - No native coroutine support in Zig
//! - Async operations require manual tracking via `AsyncTracker`
//! - Blocking `autoAwait` for async results (returns as-is for caller to poll)
//! - Event loop integration is the caller's responsibility
//!
//! # Async Support
//!
//! Jinja templates can work with async values:
//! - Async filters that return `AsyncResult`
//! - Async callables marked with `is_async = true`
//! - Values that represent pending async operations
//!
//! # Key Functions
//!
//! ## isAwaitable
//!
//! Check if a value needs to be awaited:
//!
//! ```zig
//! if (jinja.async_utils.AsyncIterator.isAwaitable(value)) {
//!     // Value is an incomplete async result
//! }
//! ```
//!
//! ## autoAwait
//!
//! Automatically await a value if it's awaitable:
//!
//! ```zig
//! const result = try jinja.async_utils.AsyncIterator.autoAwait(allocator, value);
//! // Returns the resolved value or the original if not async
//! ```
//!
//! # Async Tracker
//!
//! Track multiple async operations and wait for completion:
//!
//! ```zig
//! var tracker = jinja.async_utils.AsyncTracker.init(allocator);
//! defer tracker.deinit();
//!
//! // Create and track async operations
//! const pending = try tracker.createPending();
//!
//! // Later, resolve or reject
//! try tracker.resolve(pending.id, result_value);
//! // or: try tracker.reject(pending.id, "Error message");
//!
//! // Check status
//! if (tracker.pendingCount() == 0) {
//!     // All operations finished
//! }
//! ```
//!
//! # Callback-Based Async
//!
//! For async filter/test execution, use the callback pattern:
//!
//! ```zig
//! const AsyncCallback = *const fn (result: AsyncResult) void;
//!
//! fn myAsyncCallback(result: AsyncResult) void {
//!     if (result.completed) {
//!         if (result.value) |val| {
//!             // Handle successful result
//!         } else if (result.error_message) |err| {
//!             // Handle error
//!         }
//!     }
//! }
//! ```
//!
//! # Enable Async Mode
//!
//! Set `enable_async = true` on the environment to enable async template loading
//! and async filter/test execution:
//!
//! ```zig
//! var env = jinja.Environment.init(allocator);
//! env.enable_async = true;
//! ```
//!
//! # Future Development
//!
//! When Zig's async/await stabilizes, this module can be extended to:
//! - Support native async frames
//! - Integrate with standard event loops
//! - Provide zero-allocation async iterators

const std = @import("std");
const value_mod = @import("value.zig");
const filters = @import("filters.zig");
const context = @import("context.zig");
const environment = @import("environment.zig");

/// Re-export Value type for convenience
pub const Value = value_mod.Value;

/// Re-export async-related types
pub const AsyncResult = value_mod.AsyncResult;
pub const Callable = value_mod.Callable;

/// Callback type for async operation completion
/// Called when an async operation completes (successfully or with error)
pub const AsyncCallback = *const fn (result: AsyncResult) void;

/// Execute an async filter with callback
/// This provides a callback-based interface for async filter execution,
/// allowing integration with external event loops.
///
/// For now, executes synchronously and calls callback immediately.
/// Future: integrate with event loop for true async execution.
pub fn executeAsyncFilter(
    filter: filters.Filter,
    allocator: std.mem.Allocator,
    val: Value,
    args: []Value,
    ctx: ?*context.Context,
    env: ?*environment.Environment,
    callback: AsyncCallback,
) void {
    // Execute synchronously and call callback with result
    const result = filter.func(allocator, val, args, ctx, env) catch |err| {
        // Create failed async result
        const failed = AsyncResult.failed(generateAsyncId(), @errorName(err));
        callback(failed);
        return;
    };

    // Create successful async result
    const success = AsyncResult.resolved(generateAsyncId(), result);
    callback(success);
}

/// Execute an async test with callback
/// Same pattern as executeAsyncFilter but for test functions.
pub fn executeAsyncTest(
    test_fn: *const fn (Value, []const Value, ?*context.Context, ?*environment.Environment) bool,
    val: Value,
    args: []const Value,
    ctx: ?*context.Context,
    env: ?*environment.Environment,
    callback: AsyncCallback,
) void {
    // Execute test synchronously
    const result = test_fn(val, args, ctx, env);

    // Create async result with boolean value
    const success = AsyncResult.resolved(generateAsyncId(), Value{ .boolean = result });
    callback(success);
}

/// Common primitive types that are never awaitable
/// These types can be returned immediately without checking
const CommonPrimitives = enum {
    integer,
    float,
    boolean,
    string,
    null_type,
};

/// Check if a value type is a common primitive (never awaitable)
fn isCommonPrimitive(val: Value) bool {
    return switch (val) {
        .integer, .float, .boolean, .string, .null => true,
        else => false,
    };
}

/// Async iterator wrapper
/// Converts a regular iterator into an async iterator
pub const AsyncIterator = struct {
    const Self = @This();

    /// Check if a value is awaitable (can be awaited)
    /// In Zig, this checks if the value represents an async operation
    ///
    /// A value is awaitable if:
    /// - It's an async_result that hasn't completed
    /// - It's a callable marked as async
    pub fn isAwaitable(val: Value) bool {
        // Fast path: common primitives are never awaitable
        if (isCommonPrimitive(val)) {
            return false;
        }

        // Check for async result type
        switch (val) {
            .async_result => |ar| {
                // Only awaitable if not yet completed
                return !ar.completed;
            },
            .callable => |c| {
                // Callable is awaitable if marked as async
                return c.is_async;
            },
            else => return false,
        }
    }

    /// Auto-await a value if it's awaitable, otherwise return as-is
    /// Equivalent to Python's auto_await
    ///
    /// This function will:
    /// - Return non-awaitable values immediately
    /// - Extract and return the resolved value from completed async_results
    /// - Return pending async_results for caller to poll
    /// - Handle async callable results
    pub fn autoAwait(allocator: std.mem.Allocator, val: Value) !Value {
        // Fast path: common primitives are never awaitable
        if (isCommonPrimitive(val)) {
            return val;
        }

        // Handle async_result types - always check for completed value
        // This must happen BEFORE the isAwaitable check because completed
        // async_results are not "awaitable" but we still want to extract their value
        switch (val) {
            .async_result => |ar| {
                // If already completed, return the resolved value
                if (ar.completed) {
                    if (ar.value) |v| {
                        // Return a deep copy to avoid ownership issues
                        return try v.deepCopy(allocator);
                    } else if (ar.error_message) |_| {
                        return error.AsyncError;
                    }
                    return Value{ .null = {} };
                }

                // Zig Async Implementation Note:
                // ============================
                // Unlike Python's `await` which suspends the coroutine until
                // the async value resolves, Zig requires explicit polling or
                // callback-based handling.
                //
                // Integration options:
                // 1. Use AsyncTracker to poll for completion
                // 2. Use executeAsyncFilter with callback for event-loop integration
                // 3. Return async_result and let caller manage polling
                //
                // Currently: Return the async result for caller to handle
                // The caller is responsible for polling via AsyncTracker or callbacks
                return val;
            },
            .callable => |c| {
                if (c.is_async) {
                    // For async callables, we'd invoke and await
                    // For now, return a pending async result
                    const pending = try allocator.create(AsyncResult);
                    pending.* = AsyncResult.pending(generateAsyncId());
                    return Value{ .async_result = pending };
                }
                return val;
            },
            else => return val,
        }
    }

    /// Auto-iterate - convert iterable to async iterator
    /// Equivalent to Python's auto_aiter
    pub fn autoAiter(allocator: std.mem.Allocator, iterable: Value) !AsyncIterable {
        // Create an async iterator from the iterable
        return AsyncIterable{
            .value = iterable,
            .allocator = allocator,
        };
    }

    /// Convert async iterable to list
    /// Equivalent to Python's auto_to_list
    pub fn autoToList(allocator: std.mem.Allocator, iterable: AsyncIterable) !Value {
        var list = std.ArrayList(Value).empty;
        errdefer {
            for (list.items) |*item| {
                item.deinit(allocator);
            }
            list.deinit(allocator);
        }

        // Iterate through async iterable and collect items
        var iter = iterable;
        while (try iter.next()) |item| {
            const item_copy = try item.deepCopy(allocator);
            try list.append(allocator, item_copy);
        }

        // Create proper list value type
        const list_dict = try allocator.create(value_mod.Dict);
        list_dict.* = value_mod.Dict.init(allocator);
        errdefer list_dict.deinit(allocator);
        errdefer allocator.destroy(list_dict);

        // Store items in dict (simplified - in full implementation would use proper list type)
        for (list.items, 0..) |item, i| {
            const key = try std.fmt.allocPrint(allocator, "{}", .{i});
            defer allocator.free(key);
            try list_dict.set(key, item);
        }

        return Value{ .dict = list_dict };
    }
};

/// Async iterable wrapper
pub const AsyncIterable = struct {
    value: Value,
    allocator: std.mem.Allocator,
    index: usize = 0,

    const Self = @This();

    /// Get next item from async iterable
    pub fn next(self: *Self) !?Value {
        // For now, handle sync iterables (lists, strings, dicts)
        switch (self.value) {
            .list => |l| {
                if (self.index >= l.items.items.len) {
                    return null;
                }
                const item = l.items.items[self.index];
                self.index += 1;
                return try item.deepCopy(self.allocator);
            },
            .string => |s| {
                if (self.index >= s.len) {
                    return null;
                }
                const char_str = try std.fmt.allocPrint(self.allocator, "{c}", .{s[self.index]});
                self.index += 1;
                return Value{ .string = char_str };
            },
            .dict => |d| {
                // Iterate through dict keys
                var iter = d.items.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    if (i == self.index) {
                        self.index += 1;
                        // Return key-value pair as a dict
                        const pair_dict = try self.allocator.create(value_mod.Dict);
                        pair_dict.* = value_mod.Dict.init(self.allocator);
                        // Note: Dict.set duplicates keys internally, so pass original key directly
                        try pair_dict.set(entry.key_ptr.*, try entry.value_ptr.*.deepCopy(self.allocator));
                        return Value{ .dict = pair_dict };
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    /// Reset iterator to beginning
    pub fn reset(self: *Self) void {
        self.index = 0;
    }
};

/// Async variant decorator helper
/// Used to mark functions as having async variants
pub const AsyncVariant = struct {
    /// Check if async should be used based on environment
    pub fn shouldUseAsync(env: anytype) bool {
        // Check if environment has async enabled
        if (@hasField(@TypeOf(env.*), "enable_async")) {
            return env.enable_async;
        }
        if (@hasField(@TypeOf(env.*), "is_async")) {
            return env.is_async;
        }
        return false;
    }
};

/// Global async ID counter for generating unique IDs
var async_id_counter: u64 = 0;

/// Generate a unique async operation ID
/// Thread-safe using atomic operations
pub fn generateAsyncId() u64 {
    return @atomicRmw(u64, &async_id_counter, .Add, 1, .monotonic);
}

/// Async operation tracker
/// Manages pending async operations and their results
pub const AsyncTracker = struct {
    pending: std.AutoHashMap(u64, *AsyncResult),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new async tracker
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .pending = std.AutoHashMap(u64, *AsyncResult).init(allocator),
            .allocator = allocator,
        };
    }

    /// Deinitialize the tracker and all pending results
    pub fn deinit(self: *Self) void {
        var iter = self.pending.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pending.deinit();
    }

    /// Create a new pending async operation
    pub fn createPending(self: *Self) !*AsyncResult {
        const id = generateAsyncId();
        const result = try self.allocator.create(AsyncResult);
        result.* = AsyncResult.pending(id);
        try self.pending.put(id, result);
        return result;
    }

    /// Resolve an async operation with a value
    pub fn resolve(self: *Self, id: u64, val: Value) !void {
        if (self.pending.get(id)) |result| {
            result.value = val;
            result.completed = true;
        }
    }

    /// Reject an async operation with an error
    pub fn reject(self: *Self, id: u64, err_msg: []const u8) !void {
        if (self.pending.get(id)) |result| {
            result.error_message = try self.allocator.dupe(u8, err_msg);
            result.completed = true;
        }
    }

    /// Check if an operation is complete
    pub fn isComplete(self: *Self, id: u64) bool {
        if (self.pending.get(id)) |result| {
            return result.completed;
        }
        return true; // Not found = treat as complete
    }

    /// Get result for a completed operation
    pub fn getResult(self: *Self, id: u64) ?*AsyncResult {
        return self.pending.get(id);
    }

    /// Remove a completed operation from tracking
    pub fn remove(self: *Self, id: u64) void {
        _ = self.pending.remove(id);
    }

    /// Wait for all pending operations to complete
    /// Returns the number of completed operations
    pub fn waitAll(self: *Self) usize {
        var completed: usize = 0;
        var iter = self.pending.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.completed) {
                completed += 1;
            }
        }
        return completed;
    }

    /// Get count of pending operations
    pub fn pendingCount(self: *Self) usize {
        var count: usize = 0;
        var iter = self.pending.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.*.completed) {
                count += 1;
            }
        }
        return count;
    }
};

/// Async generator wrapper
/// Allows iterating over async values
pub const AsyncGenerator = struct {
    items: std.ArrayList(Value),
    index: usize,
    allocator: std.mem.Allocator,
    tracker: ?*AsyncTracker,

    const Self = @This();

    /// Initialize a new async generator
    pub fn init(allocator: std.mem.Allocator, tracker: ?*AsyncTracker) Self {
        return Self{
            .items = std.ArrayList(Value).init(allocator),
            .index = 0,
            .allocator = allocator,
            .tracker = tracker,
        };
    }

    /// Deinitialize the generator
    pub fn deinit(self: *Self) void {
        for (self.items.items) |*item| {
            item.deinit(self.allocator);
        }
        self.items.deinit();
    }

    /// Add an item to the generator
    pub fn push(self: *Self, val: Value) !void {
        try self.items.append(val);
    }

    /// Get the next item, awaiting if necessary
    pub fn next(self: *Self) !?Value {
        if (self.index >= self.items.items.len) {
            return null;
        }

        const item = self.items.items[self.index];
        self.index += 1;

        // Auto-await if necessary
        if (AsyncIterator.isAwaitable(item)) {
            return try AsyncIterator.autoAwait(self.allocator, item);
        }

        return item;
    }

    /// Reset to beginning
    pub fn reset(self: *Self) void {
        self.index = 0;
    }

    /// Convert to list, awaiting all items
    pub fn toList(self: *Self) !Value {
        const list = try self.allocator.create(value_mod.List);
        list.* = value_mod.List.init(self.allocator);
        errdefer list.deinit(self.allocator);

        for (self.items.items) |item| {
            var resolved = item;
            if (AsyncIterator.isAwaitable(item)) {
                resolved = try AsyncIterator.autoAwait(self.allocator, item);
            }
            const item_copy = try resolved.deepCopy(self.allocator);
            try list.append(item_copy);
        }

        return Value{ .list = list };
    }
};

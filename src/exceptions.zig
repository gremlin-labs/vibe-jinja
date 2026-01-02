//! Exception Types and Error Handling
//!
//! This module provides comprehensive error handling for Jinja templates, including
//! detailed error contexts, template stack traces, and helper functions for creating
//! informative error messages.
//!
//! # Error Types
//!
//! | Error | Description |
//! |-------|-------------|
//! | `SyntaxError` | Invalid template syntax |
//! | `RuntimeError` | Error during template execution |
//! | `TemplateNotFound` | Template file not found |
//! | `UndefinedError` | Undefined variable accessed (strict mode) |
//! | `SecurityError` | Sandbox violation |
//! | `TypeError` | Type mismatch in operation |
//! | `DivisionByZero` | Division by zero |
//! | `AttributeError` | Attribute doesn't exist |
//! | `IndexError` | Index out of bounds |
//!
//! # Error Context
//!
//! All errors include an `ErrorContext` with:
//! - Error message
//! - Filename and line number
//! - Source code snippet (optional)
//! - Column number (optional)
//! - Template call stack (for nested templates)
//! - Cause chain (for wrapped errors)
//!
//! # Usage
//!
//! ```zig
//! // Create syntax error with context
//! var err = try jinja.exceptions.SyntaxError.initWithSource(
//!     allocator,
//!     "unexpected token 'end'",
//!     "template.jinja",
//!     42,
//!     "{% end %}",
//!     4,
//! );
//! defer err.deinit(allocator);
//!
//! // Format error for display
//! std.debug.print("{}\n", .{err.context});
//! ```
//!
//! # Error Formatting
//!
//! Errors format with full context:
//!
//! ```
//! template.jinja:42:4: unexpected token 'end'
//!   {% end %}
//!
//! Template call stack:
//!   1. base.jinja:10: in template 'base.jinja' (block 'content')
//!   2. index.jinja:5: in template 'index.jinja'
//! ```

const std = @import("std");

/// Base error type for all template-related errors
///
/// This error union contains all possible errors that can occur during template
/// parsing, compilation, or rendering. Use pattern matching to handle specific errors.
///
/// # Example
///
/// ```zig
/// const result = env.getTemplate("missing.jinja") catch |err| {
///     switch (err) {
///         error.TemplateNotFound => {
///             std.debug.print("Template not found\n");
///             return;
///         },
///         error.SyntaxError => {
///             std.debug.print("Syntax error in template\n");
///             return;
///         },
///         else => return err,
///     }
/// };
/// ```
pub const TemplateError = error{
    /// Syntax error in template
    SyntaxError,
    /// Runtime error during template execution
    RuntimeError,
    /// Template file not found
    TemplateNotFound,
    /// Undefined variable or value accessed
    UndefinedError,
    /// Template assertion failed
    TemplateAssertionError,
    /// Security violation (sandbox violation)
    SecurityError,
    /// Multiple templates not found
    TemplatesNotFound,
    /// Type error (wrong type for operation)
    TypeError,
    /// Division by zero
    DivisionByZero,
    /// Attribute access error (attribute doesn't exist)
    AttributeError,
    /// Index error (index out of bounds)
    IndexError,
    /// Continue statement (internal use)
    ContinueError,
    /// Break statement (internal use)
    BreakError,
    /// Execution timeout exceeded
    TimeoutError,
};

/// Template stack entry for tracking template call chain
pub const TemplateStackEntry = struct {
    /// Template name
    name: []const u8,
    /// Filename where the template was called from
    filename: ?[]const u8,
    /// Line number where the template was called from
    lineno: ?usize,
    /// Block name if called from within a block
    block_name: ?[]const u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.filename) |f| {
            allocator.free(f);
        }
        if (self.block_name) |b| {
            allocator.free(b);
        }
    }
};

/// Error context providing detailed information about where an error occurred
///
/// Provides comprehensive error information including:
/// - Error message
/// - File location (filename, line number, column)
/// - Source code snippet around the error
/// - Template call stack (for nested templates)
/// - Chained errors (cause chain)
///
/// This enables detailed error reporting and debugging of template issues.
pub const ErrorContext = struct {
    /// Error message describing what went wrong
    message: []const u8,
    /// Filename where the error occurred (if available)
    filename: ?[]const u8,
    /// Line number where the error occurred (if available)
    lineno: ?usize,
    /// Source code snippet around the error (if available)
    source: ?[]const u8,
    /// Column number where the error occurred (if available)
    column: ?usize,
    /// Template stack (call chain) leading to this error
    template_stack: std.ArrayList(TemplateStackEntry),
    /// Chained error (cause of this error)
    cause: ?*ErrorContext = null,

    const Self = @This();

    /// Initialize a new error context
    pub fn init(
        allocator: std.mem.Allocator,
        message: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
    ) !Self {
        return Self{
            .message = try allocator.dupe(u8, message),
            .filename = if (filename) |f| try allocator.dupe(u8, f) else null,
            .lineno = lineno,
            .source = null,
            .column = null,
            .template_stack = std.ArrayList(TemplateStackEntry).empty,
            .cause = null,
        };
    }

    /// Initialize with source snippet
    pub fn initWithSource(
        allocator: std.mem.Allocator,
        message: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
        source: []const u8,
        column: ?usize,
    ) !Self {
        return Self{
            .message = try allocator.dupe(u8, message),
            .filename = if (filename) |f| try allocator.dupe(u8, f) else null,
            .lineno = lineno,
            .source = try allocator.dupe(u8, source),
            .column = column,
            .template_stack = std.ArrayList(TemplateStackEntry).empty,
            .cause = null,
        };
    }

    /// Initialize with template stack
    pub fn initWithStack(
        allocator: std.mem.Allocator,
        message: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
        template_stack: std.ArrayList(TemplateStackEntry),
    ) !Self {
        return Self{
            .message = try allocator.dupe(u8, message),
            .filename = if (filename) |f| try allocator.dupe(u8, f) else null,
            .lineno = lineno,
            .source = null,
            .column = null,
            .template_stack = template_stack,
            .cause = null,
        };
    }

    /// Chain this error with a cause
    pub fn withCause(self: *Self, cause: *ErrorContext) void {
        self.cause = cause;
    }

    /// Add a template stack entry
    pub fn addStackEntry(self: *Self, allocator: std.mem.Allocator, name: []const u8, filename: ?[]const u8, lineno: ?usize, block_name: ?[]const u8) !void {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        const filename_copy = if (filename) |f| try allocator.dupe(u8, f) else null;
        errdefer if (filename_copy) |fc| allocator.free(fc);

        const block_name_copy = if (block_name) |b| try allocator.dupe(u8, b) else null;
        errdefer if (block_name_copy) |bc| allocator.free(bc);

        try self.template_stack.append(allocator, TemplateStackEntry{
            .name = name_copy,
            .filename = filename_copy,
            .lineno = lineno,
            .block_name = block_name_copy,
        });
    }

    /// Deinitialize and free allocated memory
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.filename) |f| {
            allocator.free(f);
        }
        if (self.source) |s| {
            allocator.free(s);
        }

        // Free template stack entries
        for (self.template_stack.items) |*entry| {
            entry.deinit(allocator);
        }
        self.template_stack.deinit();

        // Note: cause is not freed here as it may be owned elsewhere
    }

    /// Format the error context as a string
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        // Print template stack (call chain) if present
        if (self.template_stack.items.len > 0) {
            try writer.print("Template call stack:\n", .{});
            for (self.template_stack.items, 0..) |entry, i| {
                try writer.print("  {d}. ", .{i + 1});
                if (entry.filename) |f| {
                    try writer.print("{s}", .{f});
                    if (entry.lineno) |ln| {
                        try writer.print(":{d}", .{ln});
                    }
                    try writer.print(": ", .{});
                }
                try writer.print("in template '{s}'", .{entry.name});
                if (entry.block_name) |b| {
                    try writer.print(" (block '{s}')", .{b});
                }
                try writer.print("\n", .{});
            }
            try writer.print("\n", .{});
        }

        // Print error location
        if (self.filename) |f| {
            try writer.print("{s}", .{f});
            if (self.lineno) |ln| {
                try writer.print(":{d}", .{ln});
                if (self.column) |col| {
                    try writer.print(":{d}", .{col});
                }
            }
            try writer.print(": ", .{});
        } else if (self.lineno) |ln| {
            try writer.print("line {d}: ", .{ln});
        }

        try writer.print("{s}", .{self.message});

        if (self.source) |s| {
            try writer.print("\n  {s}", .{s});
        }

        // Print chained error (cause) if present
        if (self.cause) |cause| {
            try writer.print("\n\nCaused by:\n", .{});
            try cause.format("", .{}, writer);
        }
    }

    /// Format error as a full traceback string
    pub fn formatTraceback(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        const writer = buf.writer();

        try self.format("", .{}, writer);

        return try buf.toOwnedSlice();
    }
};

/// Syntax error with context
pub const SyntaxError = struct {
    context: ErrorContext,

    pub fn init(
        allocator: std.mem.Allocator,
        message: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
    ) !SyntaxError {
        return SyntaxError{
            .context = try ErrorContext.init(allocator, message, filename, lineno),
        };
    }

    pub fn initWithSource(
        allocator: std.mem.Allocator,
        message: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
        source: []const u8,
        column: ?usize,
    ) !SyntaxError {
        return SyntaxError{
            .context = try ErrorContext.initWithSource(allocator, message, filename, lineno, source, column),
        };
    }

    pub fn deinit(self: *SyntaxError, allocator: std.mem.Allocator) void {
        self.context.deinit(allocator);
    }
};

/// Runtime error with context
pub const RuntimeError = struct {
    context: ErrorContext,

    pub fn init(
        allocator: std.mem.Allocator,
        message: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
    ) !RuntimeError {
        return RuntimeError{
            .context = try ErrorContext.init(allocator, message, filename, lineno),
        };
    }

    pub fn deinit(self: *RuntimeError, allocator: std.mem.Allocator) void {
        self.context.deinit(allocator);
    }
};

/// Template not found error
pub const TemplateNotFoundError = struct {
    context: ErrorContext,

    pub fn init(
        allocator: std.mem.Allocator,
        template_name: []const u8,
    ) !TemplateNotFoundError {
        const message = try std.fmt.allocPrint(allocator, "Template '{s}' not found", .{template_name});
        errdefer allocator.free(message);
        return TemplateNotFoundError{
            .context = try ErrorContext.init(allocator, message, null, null),
        };
    }

    pub fn deinit(self: *TemplateNotFoundError, allocator: std.mem.Allocator) void {
        self.context.deinit(allocator);
    }
};

/// Undefined variable error
pub const UndefinedError = struct {
    context: ErrorContext,
    variable_name: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        variable_name: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
    ) !UndefinedError {
        const message = try std.fmt.allocPrint(allocator, "Undefined variable: '{s}'", .{variable_name});
        errdefer allocator.free(message);
        return UndefinedError{
            .context = try ErrorContext.init(allocator, message, filename, lineno),
            .variable_name = try allocator.dupe(u8, variable_name),
        };
    }

    pub fn deinit(self: *UndefinedError, allocator: std.mem.Allocator) void {
        self.context.deinit(allocator);
        allocator.free(self.variable_name);
    }
};

/// Security error (sandbox violation)
pub const SecurityError = struct {
    context: ErrorContext,
    violation_type: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        violation_type: []const u8,
        message: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
    ) !SecurityError {
        const full_message = try std.fmt.allocPrint(allocator, "Security violation ({s}): {s}", .{ violation_type, message });
        errdefer allocator.free(full_message);
        return SecurityError{
            .context = try ErrorContext.init(allocator, full_message, filename, lineno),
            .violation_type = try allocator.dupe(u8, violation_type),
        };
    }

    pub fn initWithSource(
        allocator: std.mem.Allocator,
        violation_type: []const u8,
        message: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
        source: []const u8,
        column: ?usize,
    ) !SecurityError {
        const full_message = try std.fmt.allocPrint(allocator, "Security violation ({s}): {s}", .{ violation_type, message });
        errdefer allocator.free(full_message);
        return SecurityError{
            .context = try ErrorContext.initWithSource(allocator, full_message, filename, lineno, source, column),
            .violation_type = try allocator.dupe(u8, violation_type),
        };
    }

    pub fn deinit(self: *SecurityError, allocator: std.mem.Allocator) void {
        self.context.deinit(allocator);
        allocator.free(self.violation_type);
    }
};

/// Template assertion error
pub const TemplateAssertionError = struct {
    context: ErrorContext,
    assertion_message: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        assertion_message: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
    ) !TemplateAssertionError {
        const message = try std.fmt.allocPrint(allocator, "Template assertion failed: {s}", .{assertion_message});
        errdefer allocator.free(message);
        return TemplateAssertionError{
            .context = try ErrorContext.init(allocator, message, filename, lineno),
            .assertion_message = try allocator.dupe(u8, assertion_message),
        };
    }

    pub fn initWithSource(
        allocator: std.mem.Allocator,
        assertion_message: []const u8,
        filename: ?[]const u8,
        lineno: ?usize,
        source: []const u8,
        column: ?usize,
    ) !TemplateAssertionError {
        const message = try std.fmt.allocPrint(allocator, "Template assertion failed: {s}", .{assertion_message});
        errdefer allocator.free(message);
        return TemplateAssertionError{
            .context = try ErrorContext.initWithSource(allocator, message, filename, lineno, source, column),
            .assertion_message = try allocator.dupe(u8, assertion_message),
        };
    }

    pub fn deinit(self: *TemplateAssertionError, allocator: std.mem.Allocator) void {
        self.context.deinit(allocator);
        allocator.free(self.assertion_message);
    }
};

/// Helper function to extract a source snippet around a line
pub fn extractSourceSnippet(
    allocator: std.mem.Allocator,
    source: []const u8,
    lineno: usize,
    context_lines: usize,
) ![]const u8 {
    var lines = std.ArrayList([]const u8){};
    defer lines.deinit(allocator);

    var line_start: usize = 0;
    var current_line: usize = 1;

    for (source, 0..) |c, i| {
        if (c == '\n') {
            if (current_line >= lineno - context_lines and current_line <= lineno + context_lines) {
                const line = source[line_start..i];
                try lines.append(allocator, line);
            }
            line_start = i + 1;
            current_line += 1;
            if (current_line > lineno + context_lines) break;
        }
    }

    // Handle last line if needed
    if (current_line <= lineno + context_lines and line_start < source.len) {
        const line = source[line_start..];
        if (current_line >= lineno - context_lines) {
            try lines.append(allocator, line);
        }
    }

    return try std.mem.join(allocator, "\n", lines.items);
}

/// Helper function to find column number in a line
pub fn findColumn(source: []const u8, position: usize) usize {
    var col: usize = 1;
    var i: usize = 0;
    while (i < position and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            col = 1;
        } else {
            col += 1;
        }
    }
    return col;
}

/// Helper function to find line number from position
pub fn findLineNumber(source: []const u8, position: usize) usize {
    var line: usize = 1;
    var i: usize = 0;
    while (i < position and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
        }
    }
    return line;
}

// ============================================================================
// Common Error Message Helpers
// ============================================================================

/// Create a "unexpected token" error message
pub fn unexpectedTokenMessage(allocator: std.mem.Allocator, expected: []const u8, got: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "Expected {s}, got '{s}'", .{ expected, got });
}

/// Create an "undefined variable" error message
pub fn undefinedVariableMessage(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "'{s}' is undefined", .{name});
}

/// Create a "filter not found" error message
pub fn filterNotFoundMessage(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "No filter named '{s}'", .{name});
}

/// Create a "test not found" error message
pub fn testNotFoundMessage(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "No test named '{s}'", .{name});
}

/// Create a "type error" error message
pub fn typeErrorMessage(allocator: std.mem.Allocator, operation: []const u8, expected: []const u8, got: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s} requires {s}, got {s}", .{ operation, expected, got });
}

/// Create a "block not found" error message
pub fn blockNotFoundMessage(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "Block '{s}' not found", .{name});
}

/// Create a "macro not found" error message
pub fn macroNotFoundMessage(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "Macro '{s}' not found", .{name});
}

/// Create a "wrong argument count" error message
pub fn wrongArgumentCountMessage(allocator: std.mem.Allocator, name: []const u8, expected: usize, got: usize) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}() takes {d} argument(s), {d} given", .{ name, expected, got });
}

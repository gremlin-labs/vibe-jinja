//! Vibe Jinja - A high-performance Jinja2-compatible templating engine for Zig
//!
//! This module provides the main entry point and exports all public APIs for the Jinja template engine.
//! It includes convenience functions for quick template evaluation and exports all sub-modules.
//!
//! # Quick Start
//!
//! ```zig
//! const std = @import("std");
//! const jinja = @import("vibe_jinja");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     // Quick evaluation from file
//!     const output = try jinja.eval_file(allocator, "template.jinja");
//!     defer allocator.free(output);
//!     std.debug.print("{s}\n", .{output});
//! }
//! ```
//!
//! # Module Structure
//!
//! - `environment` - Core environment configuration and template loading
//! - `context` - Template variable resolution and scoping
//! - `value` - Value types for template variables
//! - `compiler` - Template compilation and rendering
//! - `parser` - Template parsing and AST generation
//! - `lexer` - Template tokenization
//! - `filters` - Built-in and custom filters
//! - `tests` - Built-in and custom tests
//! - `loaders` - Template loaders for various sources
//! - `exceptions` - Error types and error handling
//! - `extensions` - Extension system for custom functionality
//! - `cache` - Template caching system
//! - `bytecode` - Bytecode compilation and VM
//! - `optimizer` - AST optimization passes

const std = @import("std");
const testing = std.testing;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const parse = @import("parser.zig").parse;
const Token = @import("lexer.zig").Token;
const environment_mod = @import("environment.zig");
const nodes_mod = @import("nodes.zig");

/// Lexer module - tokenizes template source code
pub const lexer = @import("lexer.zig");
/// Parser module - parses tokens into AST
pub const parser = @import("parser.zig");
/// Compiler module - compiles AST to executable code
pub const compiler = @import("compiler.zig");
/// Runtime module - runtime utilities and helpers
pub const runtime = @import("runtime.zig");
/// Environment module - core environment configuration
pub const environment = environment_mod;
/// Nodes module - AST node definitions
pub const nodes = nodes_mod;

// Re-export commonly used environment types and functions
/// The main Environment struct for configuring template rendering
pub const Environment = environment_mod.Environment;
/// Value type used for template variables and expressions
pub const Value = environment_mod.Value;
/// Finalize callback type for processing variable output
pub const FinalizeFn = environment_mod.FinalizeFn;
/// Autoescape configuration type - can be bool or function
pub const AutoescapeConfig = environment_mod.AutoescapeConfig;
/// Get or create a cached spontaneous environment
pub const getSpontaneousEnvironment = environment_mod.getSpontaneousEnvironment;
/// Clear the spontaneous environment cache
pub const clearSpontaneousCache = environment_mod.clearSpontaneousCache;
/// Context module - template variable resolution and scoping
pub const context = @import("context.zig");
/// Value module - value types for template variables
pub const value = @import("value.zig");
/// Filters module - filter function definitions
pub const filters = @import("filters.zig");
/// Tests module - test function definitions
pub const tests = @import("tests.zig");
/// Loaders module - template loaders for various sources
pub const loaders = @import("loaders.zig");
/// Exceptions module - error types and error handling
pub const exceptions = @import("exceptions.zig");
/// Defaults module - default configuration constants
pub const defaults = @import("defaults.zig");
/// Utils module - utility functions and helpers
pub const utils = @import("utils.zig");
/// Errors module - syntax error definitions
pub const errors = @import("errors.zig");
/// Visitor module - AST visitor pattern implementation
pub const visitor = @import("visitor.zig");
/// Extensions module - extension system for custom functionality
pub const extensions = @import("extensions.zig");
/// Cache module - template caching system
pub const cache = @import("cache.zig");
/// Optimizer module - AST optimization passes
pub const optimizer = @import("optimizer.zig");
/// Bytecode module - bytecode compilation and VM
pub const bytecode = @import("bytecode.zig");
/// Async utils module - async utilities and helpers
pub const async_utils = @import("async_utils.zig");
/// Diagnostics module - performance profiling and analysis
pub const diagnostics = @import("diagnostics.zig");
/// Counting allocator - allocation tracking for profiling
pub const counting_allocator = @import("counting_allocator.zig");
/// Optimized loop context - zero-allocation loop iteration
pub const loop_context = @import("loop_context.zig");
/// Render arena - bulk memory allocation for rendering
pub const render_arena = @import("render_arena.zig");
/// Value pool - flyweight values for common cases
pub const value_pool = @import("value_pool.zig");

/// String pool module - for interning template literals (Phase 4)
pub const string_pool = @import("string_pool.zig");

/// Buffered output module - for efficient string concatenation (Phase 4)
pub const buffered_output = @import("buffered_output.zig");

/// AOT compiler module - compile templates to native Zig code (Phase 7)
pub const aot_compiler = @import("aot_compiler.zig");

/// SIMD utilities module - SIMD-accelerated string operations (Phase 7)
pub const simd_utils = @import("simd_utils.zig");

/// Evaluate a template file and return the rendered output
///
/// This is a convenience function that creates a default environment, loads the template
/// from the file system, and renders it with an empty context.
///
/// **Note:** This function uses a default environment with no variables. For more control,
/// use `Environment` directly.
///
/// # Arguments
/// - `allocator`: Memory allocator to use
/// - `path`: Path to the template file
///
/// # Returns
/// Rendered template output as a string. The caller is responsible for freeing the memory.
///
/// # Errors
/// - `error.FileNotFound` - Template file not found
/// - `error.OutOfMemory` - Memory allocation failed
/// - Template parsing or rendering errors
///
/// # Example
/// ```zig
/// const output = try jinja.eval_file(allocator, "templates/index.jinja");
/// defer allocator.free(output);
/// ```
pub fn eval_file(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return _eval_file(allocator, path, false);
}

/// Evaluate a template string and return the rendered output
///
/// This is a convenience function that creates a default environment, parses the template
/// string, and renders it with an empty context.
///
/// **Note:** This function uses a default environment with no variables. For more control,
/// use `Environment` directly.
///
/// # Arguments
/// - `allocator`: Memory allocator to use
/// - `content`: Template source code as a string
///
/// # Returns
/// Rendered template output as a string. The caller is responsible for freeing the memory.
///
/// # Errors
/// - `error.OutOfMemory` - Memory allocation failed
/// - Template parsing or rendering errors
///
/// # Example
/// ```zig
/// const output = try jinja.eval(allocator, "Hello, {{ name }}!");
/// defer allocator.free(output);
/// ```
pub fn eval(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    return _eval(allocator, content, false);
}

fn _eval_file(allocator: std.mem.Allocator, path: []const u8, debug: bool) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    return try _eval(allocator, content, debug);
}

fn _eval(allocator: std.mem.Allocator, content: []const u8, debug: bool) ![]const u8 {
    // Create a default environment
    var env = environment_mod.Environment.init(allocator);
    defer env.deinit();

    // Tokenize
    var lex = Lexer.init(&env, content, "none");
    var stream = try lex.tokenize(allocator);
    defer allocator.free(stream.tokens);

    if (debug) {
        std.debug.print("\n==== Tokens ====\n", .{});
        var debug_stream = stream;
        while (debug_stream.hasNext()) {
            if (debug_stream.current()) |token| {
                token.log();
                _ = debug_stream.next();
            }
        }
        std.debug.print("=========\n", .{});
    }

    // Reset stream for parsing
    stream.cursor = 0;

    // Parse into AST
    var p = Parser.init(&env, stream, "none", allocator);
    const template = try p.parse();
    defer {
        template.deinit(allocator);
        allocator.destroy(template);
    }

    // Evaluate template
    return try evalTemplate(template, allocator);
}

/// Evaluate a template node
fn evalTemplate(template: *nodes_mod.Template, allocator: std.mem.Allocator) ![]const u8 {
    // Get environment from template
    const env = template.base.environment orelse {
        // Create default environment if none
        var default_env = environment_mod.Environment.init(allocator);
        defer default_env.deinit();
        var empty_vars = std.StringHashMap(context.Value).init(allocator);
        defer empty_vars.deinit();
        var ctx = try context.Context.init(&default_env, empty_vars, null, allocator);
        defer ctx.deinit();

        var out = std.ArrayList(u8){};
        defer out.deinit(allocator);

        for (template.body.items) |stmt| {
            const stmt_result = try evalStmt(stmt, &ctx, allocator);
            defer allocator.free(stmt_result);
            try out.appendSlice(allocator, stmt_result);
        }

        return try out.toOwnedSlice(allocator);
    };

    // Create context with environment
    var empty_vars = std.StringHashMap(context.Value).init(allocator);
    defer empty_vars.deinit();
    var ctx = try context.Context.init(env, empty_vars, null, allocator);
    defer ctx.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    for (template.body.items) |stmt| {
        const stmt_result = try evalStmt(stmt, &ctx, allocator);
        defer allocator.free(stmt_result);
        try out.appendSlice(allocator, stmt_result);
    }

    return try out.toOwnedSlice(allocator);
}

/// Evaluate a statement
/// Uses type-safe dispatch based on statement tag
fn evalStmt(stmt: *nodes_mod.Stmt, ctx: *context.Context, allocator: std.mem.Allocator) ![]const u8 {
    // Use switch statement for type-safe dispatch
    return switch (stmt.tag) {
        .output => {
            const output = @as(*nodes_mod.Output, @ptrCast(@alignCast(stmt)));
            return try output.eval(ctx, allocator);
        },
        .comment => {
            // Comments produce no output
            return try allocator.dupe(u8, "");
        },
        else => {
            // All statement types should be handled above
            // If we reach here, it's an unhandled statement type
            return try allocator.dupe(u8, "");
        },
    };
}

fn test_eval(allocator: std.mem.Allocator, path: []const u8, debug: bool) !void {
    const source_path = try std.mem.concat(allocator, u8, &[_][]const u8{ path, "/test.jinja" });
    defer allocator.free(source_path);

    const source_file = try std.fs.cwd().openFile(source_path, .{});
    defer source_file.close();

    const source = try source_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(source);

    const expected_path = try std.mem.concat(allocator, u8, &[_][]const u8{ path, "/test.html" });
    defer allocator.free(expected_path);

    const expected_file = try std.fs.cwd().openFile(expected_path, .{});
    defer expected_file.close();

    const expected = try expected_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(expected);

    const actual = try _eval(allocator, source, debug);
    defer allocator.free(actual);

    try testing.expectEqualStrings(expected, actual);
}

test "comment_muli_line" {
    try test_eval(std.testing.allocator, "test/comment_multi_line", false);
}

test "comment_single_line" {
    try test_eval(std.testing.allocator, "test/comment_single_line", false);
}

test "expression_literal_boolean" {
    try test_eval(std.testing.allocator, "test/expression_literal_boolean", false);
}

test "expresssion_literal_integer" {
    try test_eval(std.testing.allocator, "test/expression_literal_integer", false);
}

test "expresssion_literal_string_double_quote" {
    try test_eval(std.testing.allocator, "test/expression_literal_string_double_quote", false);
}

test "expresssion_literal_string_quote" {
    try test_eval(std.testing.allocator, "test/expression_literal_string_quote", false);
}

test "plaintext" {
    try test_eval(std.testing.allocator, "test/plaintext", false);
}

// test {
//     const allocator = std.testing.page_allocator;

//     var lexer = Lexer.init("<html>{# 'my comment' #}hello {{ 'world' }}</html>", "none");

//     var tokens = std.ArrayList(Token).init(allocator);
//     while (lexer.has_next()) {
//         try tokens.append(lexer.next());
//     }

//     const ast = try Ast.parse(allocator, tokens);
//     std.debug.print("{s}\n", .{try ast.eval()});
//     @panic("");
// }

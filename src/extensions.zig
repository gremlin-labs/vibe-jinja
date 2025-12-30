//! Extension System
//!
//! This module provides the extension system for adding custom tags, filters, and tests
//! to Jinja templates. Extensions allow you to extend the template engine's functionality
//! without modifying the core implementation.
//!
//! # Built-in Extensions
//!
//! | Extension | Tag | Description |
//! |-----------|-----|-------------|
//! | `DoExtension` | `{% do %}` | Execute expression without output |
//! | `DebugExtension` | `{% debug %}` | Output debugging information |
//! | `LoopControlExtension` | `{% break %}`, `{% continue %}` | Loop control statements |
//!
//! # Creating Custom Extensions
//!
//! Extensions can provide:
//! - **Custom Tags**: New template tags (e.g., `{% mytag %}`)
//! - **Custom Filters**: New filters (e.g., `{{ value | myfilter }}`)
//! - **Custom Tests**: New tests (e.g., `{% if value is mytest %}`)
//!
//! ```zig
//! var ext = try jinja.extensions.Extension.init(allocator, "myextension");
//! defer ext.deinit();
//!
//! // Add custom tag
//! try ext.addTag("mytag");
//!
//! // Add custom filter
//! try ext.addFilter("myfilter", myFilterFn);
//!
//! // Add custom test
//! try ext.addTest("mytest", myTestFn);
//!
//! // Register with environment
//! try env.addExtension(&ext);
//! ```
//!
//! # Extension Priority
//!
//! Extensions are processed in order of priority (lower number = higher priority).
//! Default priority is 100. Use lower values for extensions that should run first:
//!
//! ```zig
//! ext.priority = 50; // Higher priority than default
//! ```
//!
//! # Extension Registry
//!
//! The `ExtensionRegistry` manages all registered extensions and provides:
//! - Tag lookup by name
//! - Filter/test lookup from all extensions
//! - Template source preprocessing
//! - Token stream filtering
//!
//! # Built-in Extension Usage
//!
//! ```jinja
//! {# DoExtension - execute expression without output #}
//! {% do items.append(new_item) %}
//!
//! {# DebugExtension - output debug info #}
//! {% debug %}
//!
//! {# LoopControlExtension - loop control #}
//! {% for item in items %}
//!     {% if item.skip %}{% continue %}{% endif %}
//!     {% if item.done %}{% break %}{% endif %}
//!     {{ item.name }}
//! {% endfor %}
//! ```

const std = @import("std");
const nodes = @import("nodes.zig");
const parser = @import("parser.zig");
const filters = @import("filters.zig");
const tests = @import("tests.zig");
const lexer = @import("lexer.zig");
const environment = @import("environment.zig");

/// Extension interface for custom tags, filters, and tests
pub const Extension = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    environment: ?*environment.Environment,

    // Tags that this extension handles
    tags: std.ArrayList([]const u8),

    // Custom filters provided by this extension
    filters: std.StringHashMap(*filters.Filter),

    // Custom tests provided by this extension
    tests: std.StringHashMap(*tests.Test),

    // Extension priority (lower = higher priority, default 100)
    priority: u32,

    const Self = @This();

    /// Initialize a new extension
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .environment = null,
            .tags = std.ArrayList([]const u8).empty,
            .filters = std.StringHashMap(*filters.Filter).init(allocator),
            .tests = std.StringHashMap(*tests.Test).init(allocator),
            .priority = 100, // Default priority
        };
    }

    /// Bind extension to an environment
    pub fn bind(self: *Self, env: *environment.Environment) !Self {
        var bound = try Self.init(self.allocator, self.name);
        bound.environment = env;
        bound.priority = self.priority;

        // Copy tags
        for (self.tags.items) |tag| {
            try bound.tags.append(self.allocator, try self.allocator.dupe(u8, tag));
        }

        // Copy filters
        var filter_iter = self.filters.iterator();
        while (filter_iter.next()) |entry| {
            const name_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            try bound.filters.put(name_copy, entry.value_ptr.*);
        }

        // Copy tests
        var test_iter = self.tests.iterator();
        while (test_iter.next()) |entry| {
            const name_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            try bound.tests.put(name_copy, entry.value_ptr.*);
        }

        return bound;
    }

    /// Preprocess source before lexing
    /// Extensions can override this to modify source code
    pub fn preprocess(self: *Self, source: []const u8, name: ?[]const u8, filename: ?[]const u8) ![]const u8 {
        _ = name;
        _ = filename;
        // Default implementation - return source unchanged
        return try self.allocator.dupe(u8, source);
    }

    /// Filter token stream after lexing
    /// Extensions can override this to modify, insert, or remove tokens
    pub fn filterStream(self: *Self, stream: *lexer.TokenStream) !lexer.TokenStream {
        _ = self;
        // Default implementation - return stream unchanged
        // Create a new stream with the same tokens
        return lexer.TokenStream.init(stream.tokens);
    }

    /// Deinitialize the extension
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);

        for (self.tags.items) |tag| {
            self.allocator.free(tag);
        }
        self.tags.deinit(self.allocator);

        var filter_iter = self.filters.iterator();
        while (filter_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.filters.deinit();

        var test_iter = self.tests.iterator();
        while (test_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.tests.deinit();
    }

    /// Add a tag that this extension handles
    pub fn addTag(self: *Self, tag: []const u8) !void {
        const tag_copy = try self.allocator.dupe(u8, tag);
        try self.tags.append(self.allocator, tag_copy);
    }

    /// Add a custom filter
    pub fn addFilter(self: *Self, name: []const u8, filter_func: filters.FilterFn) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const filter = try self.allocator.create(filters.Filter);
        errdefer self.allocator.destroy(filter);

        filter.* = filters.Filter.init(name_copy, filter_func);

        // Remove old filter if exists
        if (self.filters.fetchRemove(name_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.destroy(old.value);
        }

        try self.filters.put(name_copy, filter);
    }

    /// Add a custom test
    pub fn addTest(self: *Self, name: []const u8, test_func: tests.TestFn) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const test_obj = try self.allocator.create(tests.Test);
        errdefer self.allocator.destroy(test_obj);

        test_obj.* = tests.Test.init(name_copy, test_func);

        // Remove old test if exists
        if (self.tests.fetchRemove(name_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.destroy(old.value);
        }

        try self.tests.put(name_copy, test_obj);
    }

    /// Parse a custom tag (to be implemented by extensions)
    /// Returns a statement node or null if this extension doesn't handle the tag
    pub fn parseTag(self: *Self, pars: *parser.Parser, tag: []const u8) !?*nodes.Stmt {
        _ = self;
        _ = pars;
        _ = tag;
        // Default implementation - extensions should override
        return null;
    }

    /// Return an attribute node for the current extension
    /// This is useful to pass constants on extensions to generated template code
    /// Matches Python's Extension.attr() method
    pub fn attr(self: *const Self, attr_name: []const u8, lineno: ?usize) !*nodes.ExtensionAttribute {
        const ext_attr = try self.allocator.create(nodes.ExtensionAttribute);
        ext_attr.* = nodes.ExtensionAttribute{
            .base = nodes.Node{
                .lineno = lineno orelse 0,
                .filename = null,
                .environment = self.environment,
            },
            .identifier = self.name,
            .name = try self.allocator.dupe(u8, attr_name),
        };
        return ext_attr;
    }

    /// Call a method of the extension
    /// This is a shortcut for attr() + Call node
    /// Matches Python's Extension.call_method() method
    pub fn callMethod(
        self: *const Self,
        method_name: []const u8,
        args: ?std.ArrayList(nodes.Expression),
        lineno: ?usize,
    ) !nodes.Expression {
        // Create extension attribute reference
        const ext_attr = try self.attr(method_name, lineno);

        // Create call expression
        const call_expr = try self.allocator.create(nodes.CallExpr);
        call_expr.* = nodes.CallExpr{
            .base = nodes.Node{
                .lineno = lineno orelse 0,
                .filename = null,
                .environment = self.environment,
            },
            .func = nodes.Expression{ .extension_attribute = ext_attr },
            .args = args orelse std.ArrayList(nodes.Expression).empty,
            .kwargs = std.StringHashMap(nodes.Expression).init(self.allocator),
            .dyn_args = null,
            .dyn_kwargs = null,
        };

        return nodes.Expression{ .call_expr = call_expr };
    }
};

/// Extension registry for managing extensions
pub const ExtensionRegistry = struct {
    extensions: std.ArrayList(*Extension),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new extension registry
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .extensions = std.ArrayList(*Extension).empty,
            .allocator = allocator,
        };
    }

    /// Deinitialize the registry
    pub fn deinit(self: *Self) void {
        for (self.extensions.items) |ext| {
            ext.deinit();
            self.allocator.destroy(ext);
        }
        self.extensions.deinit(self.allocator);
    }

    /// Register an extension
    pub fn register(self: *Self, extension: *Extension) !void {
        try self.extensions.append(self.allocator, extension);
        // Sort by priority (lower priority = higher priority)
        std.mem.sort(*Extension, self.extensions.items, {}, comparePriority);
    }

    /// Compare extensions by priority
    fn comparePriority(_: void, a: *Extension, b: *Extension) bool {
        return a.priority < b.priority;
    }

    /// Get an extension by name
    pub fn get(self: *Self, name: []const u8) ?*Extension {
        for (self.extensions.items) |ext| {
            if (std.mem.eql(u8, ext.name, name)) {
                return ext;
            }
        }
        return null;
    }

    /// Get all extensions sorted by priority
    pub fn iterExtensions(self: *const Self) []*Extension {
        return self.extensions.items;
    }

    /// Preprocess source with all extensions (in priority order)
    pub fn preprocess(self: *Self, source: []const u8, name: ?[]const u8, filename: ?[]const u8) ![]const u8 {
        var current_source = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(current_source);

        // Apply preprocessing from each extension in priority order
        for (self.extensions.items) |ext| {
            const new_source_const = try ext.preprocess(current_source, name, filename);
            if (!std.mem.eql(u8, current_source, source)) {
                // Free previous source if it was modified
                self.allocator.free(current_source);
            }
            // Duplicate the const slice to get a mutable one
            current_source = try self.allocator.dupe(u8, new_source_const);
        }

        return current_source;
    }

    /// Filter token stream with all extensions (in priority order)
    pub fn filterStream(self: *Self, stream: *lexer.TokenStream) !lexer.TokenStream {
        var current_stream = stream.*;

        // Apply filter_stream from each extension in priority order
        for (self.extensions.items) |ext| {
            current_stream = try ext.filterStream(&current_stream);
        }

        return current_stream;
    }

    /// Check if a tag is handled by any extension
    pub fn handlesTag(self: *Self, tag: []const u8) bool {
        for (self.extensions.items) |ext| {
            for (ext.tags.items) |ext_tag| {
                if (std.mem.eql(u8, ext_tag, tag)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Parse a tag using extensions (check in priority order)
    pub fn parseTag(self: *Self, pars: *parser.Parser, tag: []const u8) !?*nodes.Stmt {
        for (self.extensions.items) |ext| {
            for (ext.tags.items) |ext_tag| {
                if (std.mem.eql(u8, ext_tag, tag)) {
                    if (try ext.parseTag(pars, tag)) |stmt| {
                        return stmt;
                    }
                }
            }
        }
        return null;
    }
};

// ============================================================================
// Built-in Extensions
// ============================================================================

/// Expression Statement Extension (do extension)
/// Adds a `do` tag to Jinja that evaluates an expression without outputting the result.
/// This is useful for calling functions/methods for their side effects.
///
/// Example:
///   {% do items.append('item') %}
///   {% do counter.increment() %}
///
/// Matches Python's jinja2.ext.ExprStmtExtension (aliased as `do`)
pub const DoExtension = struct {
    extension: Extension,

    const Self = @This();

    /// Initialize the do extension
    pub fn init(allocator: std.mem.Allocator) !Self {
        var ext = try Extension.init(allocator, "jinja2.ext.do");
        try ext.addTag("do");

        return Self{
            .extension = ext,
        };
    }

    /// Get the underlying extension
    pub fn getExtension(self: *Self) *Extension {
        return &self.extension;
    }

    /// Deinitialize the extension
    pub fn deinit(self: *Self) void {
        self.extension.deinit();
    }
};

/// Debug Extension
/// A `{% debug %}` tag that dumps the available variables, filters, and tests.
///
/// Example:
///   <pre>{% debug %}</pre>
///
/// Output format:
///   {'context': {...}, 'filters': [...], 'tests': [...]}
///
/// Matches Python's jinja2.ext.DebugExtension (aliased as `debug`)
pub const DebugExtension = struct {
    extension: Extension,

    const Self = @This();

    /// Initialize the debug extension
    pub fn init(allocator: std.mem.Allocator) !Self {
        var ext = try Extension.init(allocator, "jinja2.ext.debug");
        try ext.addTag("debug");

        return Self{
            .extension = ext,
        };
    }

    /// Get the underlying extension
    pub fn getExtension(self: *Self) *Extension {
        return &self.extension;
    }

    /// Deinitialize the extension
    pub fn deinit(self: *Self) void {
        self.extension.deinit();
    }
};

/// Loop Control Extension
/// Adds break and continue support to template loops.
/// Note: Break and continue are built into the parser, this extension is for compatibility
///
/// Example:
///   {% for item in items %}
///     {% if item.skip %}{% continue %}{% endif %}
///     {% if item.stop %}{% break %}{% endif %}
///     {{ item }}
///   {% endfor %}
///
/// Matches Python's jinja2.ext.LoopControlExtension (aliased as `loopcontrols`)
pub const LoopControlExtension = struct {
    extension: Extension,

    const Self = @This();

    /// Initialize the loop control extension
    pub fn init(allocator: std.mem.Allocator) !Self {
        var ext = try Extension.init(allocator, "jinja2.ext.loopcontrols");
        // break and continue are handled by the parser directly
        // but we register the tags for compatibility
        try ext.addTag("break");
        try ext.addTag("continue");

        return Self{
            .extension = ext,
        };
    }

    /// Get the underlying extension
    pub fn getExtension(self: *Self) *Extension {
        return &self.extension;
    }

    /// Deinitialize the extension
    pub fn deinit(self: *Self) void {
        self.extension.deinit();
    }
};

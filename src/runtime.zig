//! Runtime Support
//!
//! This module provides runtime support structures and utilities for template execution.
//! It includes template references, module management, and undefined value handling.
//!
//! # Key Components
//!
//! ## TemplateReference
//!
//! Represents `self` in templates, allowing access to blocks:
//!
//! ```jinja
//! {{ self.header() }}
//! ```
//!
//! ```zig
//! var ref = jinja.runtime.TemplateReference.init(allocator, template, ctx, compiler);
//! ctx.setTemplateRef(&ref);
//! ```
//!
//! ## TemplateModule
//!
//! Represents an imported template module with exported variables and macros:
//!
//! ```jinja
//! {% import 'macros.html' as macros %}
//! {{ macros.button("Click me") }}
//! ```
//!
//! ## Undefined Handling
//!
//! The `UndefinedBehavior` enum controls how undefined variables are handled:
//!
//! | Behavior | Description |
//! |----------|-------------|
//! | `strict` | Raise error immediately |
//! | `lenient` | Return empty string (default) |
//! | `debug` | Return debug string `{{ var_name }}` |
//! | `chainable` | Allow chaining (undefined.attr returns undefined) |
//!
//! ```zig
//! env.undefined_behavior = .strict; // Raise errors for undefined vars
//! ```
//!
//! # Loop Context
//!
//! The `LoopContext` provides the `loop` variable in for loops:
//!
//! ```jinja
//! {% for item in items %}
//!     {{ loop.index }}      {# 1-based index #}
//!     {{ loop.index0 }}     {# 0-based index #}
//!     {{ loop.first }}      {# true for first item #}
//!     {{ loop.last }}       {# true for last item #}
//!     {{ loop.length }}     {# total items #}
//!     {{ loop.cycle('a', 'b') }}  {# alternating values #}
//! {% endfor %}
//! ```

const std = @import("std");
const environment = @import("environment.zig");
const context = @import("context.zig");
const compiler = @import("compiler.zig");
const nodes = @import("nodes.zig");
const exceptions = @import("exceptions.zig");
const value = @import("value.zig");

/// Re-export UndefinedBehavior and Undefined for convenience
pub const UndefinedBehavior = value.UndefinedBehavior;
pub const Undefined = value.Undefined;

/// TemplateReference - represents the current template (self)
/// Allows accessing blocks via self.block_name syntax
pub const TemplateReference = struct {
    allocator: std.mem.Allocator,
    /// Template name
    name: ?[]const u8,
    /// Context containing blocks
    ctx: *context.Context,
    /// Compiler instance for rendering blocks
    compiler_instance: *compiler.Compiler,
    /// Template node
    template: *nodes.Template,

    const Self = @This();

    /// Initialize a template reference
    pub fn init(allocator: std.mem.Allocator, template: *nodes.Template, ctx: *context.Context, compiler_instance: *compiler.Compiler) Self {
        const name_copy = if (template.name) |n| allocator.dupe(u8, n) catch null else null;
        return Self{
            .allocator = allocator,
            .name = name_copy,
            .ctx = ctx,
            .compiler_instance = compiler_instance,
            .template = template,
        };
    }

    /// Deinitialize the template reference
    pub fn deinit(self: *Self) void {
        if (self.name) |name| {
            self.allocator.free(name);
        }
    }

    /// Get a block by name (for self.block_name syntax)
    pub fn getBlock(self: *Self, name: []const u8) ?*nodes.Block {
        return self.ctx.getBlock(name);
    }

    /// Render a block by name (for self.block_name() syntax)
    pub fn renderBlock(self: *Self, name: []const u8, frame: *compiler.Frame) ![]const u8 {
        if (self.ctx.getBlock(name)) |block| {
            return try self.compiler_instance.visitBlock(block, frame, self.ctx);
        }
        return error.BlockNotFound;
    }

    /// Get block as a callable (for self.block_name() syntax)
    /// Returns a dict-like value that can be called
    pub fn getBlockAsValue(self: *Self, name: []const u8, allocator: std.mem.Allocator) !context.Value {
        if (self.ctx.getBlock(name)) |_| {
            // Create a dict-like value that represents the block
            // In Jinja2, blocks can be called like functions
            const block_dict_ptr = try allocator.create(value.Dict);
            errdefer allocator.destroy(block_dict_ptr);
            block_dict_ptr.* = value.Dict.init(allocator);

            // Store block reference (simplified - in full implementation would be callable)
            // Note: Dict.set duplicates keys internally, so pass name directly
            const block_ref_val = context.Value{ .string = try std.fmt.allocPrint(allocator, "<block {s}>", .{name}) };
            try block_dict_ptr.set(name, block_ref_val);

            return context.Value{ .dict = block_dict_ptr };
        }

        // Return undefined if block not found
        return context.Value{ .undefined = value.Undefined{
            .name = name,
            .behavior = .lenient,
        } };
    }
};

/// TemplateModule - represents an imported template
/// Exports template variables and macros, and provides access to rendered body
pub const TemplateModule = struct {
    allocator: std.mem.Allocator,
    /// Template name
    name: ?[]const u8,
    /// Rendered body stream
    body_stream: []const u8,
    /// Exported variables (macros and variables marked for export)
    exports: std.StringHashMap(context.Value),

    const Self = @This();

    /// Initialize a template module from a template
    pub fn init(allocator: std.mem.Allocator, template: *nodes.Template, ctx: *context.Context) !Self {
        // Render the template to get body stream
        var compiler_instance = compiler.Compiler.init(ctx.environment, template.base.filename, allocator);
        defer compiler_instance.deinit();

        var frame = compiler.Frame.init("module", null, allocator);
        defer frame.deinit();

        const body = try compiler_instance.visitTemplate(template, &frame, ctx);

        // Get exported variables from context
        var exports = std.StringHashMap(context.Value).init(allocator);
        errdefer {
            var iter = exports.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(allocator);
            }
            exports.deinit();
        }

        // Copy exported variables from context
        var exported_iter = ctx.exported_vars.iterator();
        while (exported_iter.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);

            // Get value from context
            const val = ctx.resolve(entry.key_ptr.*);
            if (val != .undefined) {
                // Copy value (simplified - may need deep copy for complex types)
                const val_copy = try copyValue(allocator, val);
                errdefer val_copy.deinit(allocator);

                try exports.put(key_copy, val_copy);
            }
        }

        // Also export macros
        var macro_iter = ctx.macros.iterator();
        while (macro_iter.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);

            // Store macro as a value (we'll need a way to represent macros as values)
            // For now, we'll store a reference - this is a simplification
            // In a full implementation, macros would be callable values
            const macro_val = context.Value{ .string = try std.fmt.allocPrint(allocator, "<macro {s}>", .{entry.key_ptr.*}) };
            try exports.put(key_copy, macro_val);
        }

        const name_copy = if (template.name) |n| try allocator.dupe(u8, n) else null;
        errdefer if (name_copy) |nc| allocator.free(nc);

        return Self{
            .allocator = allocator,
            .name = name_copy,
            .body_stream = body,
            .exports = exports,
        };
    }

    /// Deinitialize the module
    pub fn deinit(self: *Self) void {
        if (self.name) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.body_stream);

        var iter = self.exports.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.exports.deinit();
    }

    /// Get an exported value by name
    pub fn get(self: *Self, name: []const u8) ?context.Value {
        return self.exports.get(name);
    }

    /// Convert module to string (renders body)
    pub fn toString(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        _ = allocator;
        return try self.allocator.dupe(u8, self.body_stream);
    }

    /// Helper to copy a value (uses deepCopy)
    fn copyValue(allocator: std.mem.Allocator, val: context.Value) !context.Value {
        return try val.deepCopy(allocator);
    }
};

/// Runtime system for executing compiled templates
pub const Runtime = struct {
    environment: *environment.Environment,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new runtime
    pub fn init(env: *environment.Environment, allocator: std.mem.Allocator) Self {
        return Self{
            .environment = env,
            .allocator = allocator,
        };
    }

    /// Deinitialize the runtime
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Render a compiled template with the given context
    pub fn render(self: *Self, compiled_template: *const compiler.CompiledTemplate, ctx: *context.Context) ![]const u8 {
        return try compiled_template.render(ctx, self.allocator);
    }

    /// Render a compiled template asynchronously
    /// Returns an async frame that must be awaited
    /// Note: In Zig, async functions return async frames
    /// This method properly handles async filters and tests when enable_async is true
    pub fn renderAsync(self: *Self, compiled_template: *const compiler.CompiledTemplate, ctx: *context.Context) ![]const u8 {
        if (!self.environment.enable_async) {
            return error.AsyncNotEnabled;
        }
        // Use async rendering which handles async filters/tests
        return try compiled_template.renderAsync(ctx, self.allocator);
    }

    /// Render a template from string with variables
    pub fn renderString(self: *Self, source: []const u8, vars: std.StringHashMap(context.Value), name: ?[]const u8) ![]const u8 {
        // Create template from string
        const template = try self.environment.fromString(source, name);
        // Only free template if caching is disabled - otherwise cache owns it
        defer if (self.environment.template_cache == null) {
            template.deinit(self.allocator);
            self.allocator.destroy(template);
        };

        // Compile template
        var compiled = try compiler.compile(self.environment, template, name, self.allocator);
        defer compiled.deinit();

        // Create context
        var ctx = try context.Context.init(self.environment, vars, name, self.allocator);
        defer ctx.deinit();

        // Render
        return try compiled.render(&ctx, self.allocator);
    }

    /// Render a template from string asynchronously
    pub fn renderStringAsync(self: *Self, source: []const u8, vars: std.StringHashMap(context.Value), name: ?[]const u8) ![]const u8 {
        if (!self.environment.enable_async) {
            return error.AsyncNotEnabled;
        }

        // Create template from string
        const template = try self.environment.fromString(source, name);
        // Only free template if caching is disabled - otherwise cache owns it
        defer if (self.environment.template_cache == null) {
            template.deinit(self.allocator);
            self.allocator.destroy(template);
        };

        // Compile template
        var compiled = try compiler.compile(self.environment, template, name, self.allocator);
        defer compiled.deinit();

        // Create context
        var ctx = try context.Context.init(self.environment, vars, name, self.allocator);
        defer ctx.deinit();

        // Render asynchronously
        return try compiled.renderAsync(&ctx, self.allocator);
    }

    /// Render a template with a simple variable map
    pub fn renderWithVars(self: *Self, compiled_template: *compiler.CompiledTemplate, vars: std.StringHashMap(context.Value)) ![]const u8 {
        var ctx = try context.Context.init(self.environment, vars, null, self.allocator);
        defer ctx.deinit();
        return try self.render(compiled_template, &ctx);
    }

    /// Render a template with a simple variable map asynchronously
    pub fn renderWithVarsAsync(self: *Self, compiled_template: *compiler.CompiledTemplate, vars: std.StringHashMap(context.Value)) ![]const u8 {
        if (!self.environment.enable_async) {
            return error.AsyncNotEnabled;
        }
        return try self.renderWithVars(compiled_template, vars);
    }
};

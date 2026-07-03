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
const runtime_types = @import("runtime_types.zig");
const value = @import("value.zig");

/// Re-export UndefinedBehavior and Undefined for convenience
pub const UndefinedBehavior = value.UndefinedBehavior;
pub const Undefined = value.Undefined;
pub const TemplateReference = runtime_types.TemplateReference;
pub const TemplateModule = runtime_types.TemplateModule;

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

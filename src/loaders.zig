//! Template Loading System
//!
//! This module provides loaders for loading templates from various sources. Loaders are
//! responsible for finding, reading, and managing template source code.
//!
//! # Available Loaders
//!
//! | Loader | Description |
//! |--------|-------------|
//! | `FileSystemLoader` | Load templates from the filesystem |
//! | `DictLoader` | Load templates from an in-memory dictionary |
//! | `FunctionLoader` | Load templates using a custom function |
//! | `PackageLoader` | Load templates from a package/module path |
//! | `PrefixLoader` | Route loading to sub-loaders based on prefix |
//! | `ChoiceLoader` | Try multiple loaders in order |
//! | `ModuleLoader` | Load precompiled template modules |
//!
//! # FileSystemLoader
//!
//! The most common loader, loads templates from filesystem directories:
//!
//! ```zig
//! var loader = try jinja.loaders.FileSystemLoader.init(allocator, &[_][]const u8{
//!     "templates",
//!     "/usr/share/templates",
//! });
//! env.setLoader(loader.getLoader());
//!
//! // Load template from one of the search paths
//! const template = try env.getTemplate("index.html");
//! ```
//!
//! # DictLoader
//!
//! Load templates from an in-memory map (useful for testing):
//!
//! ```zig
//! var templates = std.StringHashMap([]const u8).init(allocator);
//! try templates.put("hello.html", "Hello, {{ name }}!");
//!
//! var loader = try jinja.loaders.DictLoader.init(allocator, templates);
//! env.setLoader(loader.getLoader());
//! ```
//!
//! # FunctionLoader
//!
//! Load templates using a custom function:
//!
//! ```zig
//! fn loadTemplate(name: []const u8) !?jinja.loaders.FunctionLoaderResult {
//!     // Custom template loading logic
//!     return jinja.loaders.FunctionLoaderResult{
//!         .source = "template source...",
//!         .filename = name,
//!         .uptodate_func = null,
//!     };
//! }
//!
//! var loader = try jinja.loaders.FunctionLoader.init(allocator, loadTemplate);
//! ```
//!
//! # PrefixLoader
//!
//! Route template loading based on prefix:
//!
//! ```zig
//! var mapping = std.StringHashMap(*jinja.loaders.Loader).init(allocator);
//! try mapping.put("admin", admin_loader);
//! try mapping.put("public", public_loader);
//!
//! var loader = try jinja.loaders.PrefixLoader.init(allocator, mapping, "/");
//! // {% include "admin/users.html" %} loads from admin_loader
//! ```
//!
//! # Loader Interface
//!
//! All loaders implement the `Loader` interface with these methods:
//! - `load(name)` - Load template source by name
//! - `loadAsync(name)` - Async load (if supported)
//! - `listTemplates()` - List all available template names
//! - `uptodate(name, last_modified)` - Check if cached template is up-to-date
//!
//! # Cache and Auto-Reload Behavior
//!
//! Template caching is controlled at the Environment level:
//! - `auto_reload = true` (default): Templates are reloaded when source files change
//! - `auto_reload = false`: Templates are cached indefinitely
//!
//! The `uptodate()` method is called by the cache to check if a template needs reloading.
//! Different loaders implement this differently:
//! - `FileSystemLoader`: Compares file modification times
//! - `DictLoader`: Always returns true (in-memory data doesn't change)
//! - `FunctionLoader`: Uses optional uptodate_func if provided
//!
//! # Known Limitations
//!
//! ## ModuleLoader Template Listing
//!
//! The `ModuleLoader.listTemplates()` cannot list templates loaded from hashed
//! filenames because the hash is one-way. Only explicitly registered templates
//! are listed. This matches Python Jinja2's behavior.
//!
//! ## Filename Tracking
//!
//! Some loaders (like `FunctionLoader`) may return source without filename
//! information. In these cases, error tracebacks will show `<unknown>` as the
//! filename. Provide explicit filenames when possible for better debugging.

const std = @import("std");
const exceptions = @import("exceptions.zig");
const crypto = std.crypto;

/// Error type for loader operations
pub const LoaderError = exceptions.TemplateError || std.mem.Allocator.Error;

/// Result type for FunctionLoader's load function
/// Matches Python's FunctionLoader which can return:
/// - Just a string (source only)
/// - A tuple (source, filename, uptodate_func)
/// - None (template not found)
pub const FunctionLoaderResult = struct {
    /// Template source content
    source: []const u8,
    /// Optional filename for tracebacks (null means unknown)
    filename: ?[]const u8 = null,
    /// Optional uptodate function - if null, template is always considered up-to-date
    uptodate_func: ?*const fn () bool = null,
};

/// Base loader interface
pub const Loader = struct {
    pub const VTable = struct {
        load: *const fn (self: *Loader, name: []const u8, allocator: std.mem.Allocator) LoaderError![]const u8,
        /// Async load method - loads template asynchronously
        /// In Zig, async functions return async frames that must be awaited
        loadAsync: ?*const fn (self: *Loader, name: []const u8, allocator: std.mem.Allocator) LoaderError![]const u8 = null,
        listTemplates: ?*const fn (self: *Loader, allocator: std.mem.Allocator) LoaderError![][]const u8,
        uptodate: ?*const fn (self: *Loader, name: []const u8, last_modified: i64) bool,
        deinit: *const fn (self: *Loader, allocator: std.mem.Allocator) void,
    };

    vtable: *const VTable,
    allocator: std.mem.Allocator,
    /// Pointer to the concrete loader implementation
    impl: *anyopaque,

    const Self = @This();

    /// Load a template by name
    pub fn load(self: *Self, name: []const u8) ![]const u8 {
        return self.vtable.load(self, name, self.allocator);
    }

    /// Load a template asynchronously by name
    /// Falls back to sync load if async not available
    pub fn loadAsync(self: *Self, name: []const u8) ![]const u8 {
        if (self.vtable.loadAsync) |async_load| {
            // In Zig, async functions return async frames that must be awaited
            // For now, we'll call the async function directly
            // In a full async implementation, this would be awaited
            return try async_load(self, name, self.allocator);
        } else {
            // Fall back to sync load
            return try self.load(name);
        }
    }

    /// List all available templates
    pub fn listTemplates(self: *Self) ![][]const u8 {
        if (self.vtable.listTemplates) |func| {
            return func(self, self.allocator);
        }
        return error.NotImplemented;
    }

    /// Check if template is up-to-date (hasn't changed since last_modified)
    /// Returns true if template is up-to-date, false if it has changed
    pub fn uptodate(self: *Self, name: []const u8, last_modified: i64) bool {
        if (self.vtable.uptodate) |func| {
            return func(self, name, last_modified);
        }
        // Default: assume up-to-date if loader doesn't support checking
        return true;
    }

    /// Deinitialize the loader
    pub fn deinit(self: *Self) void {
        self.vtable.deinit(self, self.allocator);
    }
};

/// File system loader - loads templates from the file system
pub const FileSystemLoader = struct {
    loader: Loader,
    allocator: std.mem.Allocator,
    searchpath: []const []const u8,

    const Self = @This();

    /// VTable for FileSystemLoader
    const vtable = Loader.VTable{
        .load = loadImpl,
        .listTemplates = listTemplatesImpl,
        .uptodate = uptodateImpl,
        .deinit = deinitImpl,
    };

    /// Uptodate implementation - check file modification time
    fn uptodateImpl(loader_ptr: *Loader, name: []const u8, last_modified: i64) bool {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        // Split template path (simple split without allocation)
        var path_parts = std.ArrayList([]const u8){};
        defer path_parts.deinit(self.allocator);

        var iter = std.mem.splitSequence(u8, name, "/");
        while (iter.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) {
                continue;
            }
            if (std.mem.eql(u8, part, "..") or std.mem.indexOf(u8, part, std.fs.path.sep_str) != null) {
                return false; // Invalid path
            }
            // Store reference to part (no allocation needed)
            path_parts.append(self.allocator, part) catch return false;
        }

        // Try each search path
        for (self.searchpath) |search_path| {
            var full_path = std.ArrayList(u8){};
            defer full_path.deinit(self.allocator);

            full_path.appendSlice(self.allocator, search_path) catch return false;
            if (!std.mem.endsWith(u8, search_path, std.fs.path.sep_str)) {
                full_path.appendSlice(self.allocator, std.fs.path.sep_str) catch return false;
            }

            for (path_parts.items) |part| {
                full_path.appendSlice(self.allocator, part) catch return false;
                full_path.appendSlice(self.allocator, std.fs.path.sep_str) catch return false;
            }

            // Remove trailing separator
            if (full_path.items.len > 0) {
                _ = full_path.pop();
            }

            const path_str = full_path.toOwnedSlice(self.allocator) catch return false;
            defer self.allocator.free(path_str);

            // Check file modification time
            const file = std.fs.cwd().openFile(path_str, .{}) catch continue;
            defer file.close();

            const stat = file.stat() catch return false;
            const file_mtime = @as(i64, @intCast(stat.mtime));

            // File is up-to-date if modification time hasn't changed
            return file_mtime <= last_modified;
        }

        // File not found - assume changed
        return false;
    }

    /// Load implementation
    fn loadImpl(loader_ptr: *Loader, name: []const u8, allocator: std.mem.Allocator) LoaderError![]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        // Split template path and check for security issues
        // Store slices of the original name (no allocation needed)
        var path_parts = std.ArrayList([]const u8){};
        defer path_parts.deinit(allocator);

        var iter = std.mem.splitSequence(u8, name, "/");
        while (iter.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) {
                continue;
            }
            // Check for path traversal attempts
            if (std.mem.eql(u8, part, "..") or std.mem.indexOf(u8, part, std.fs.path.sep_str) != null) {
                return exceptions.TemplateError.TemplateNotFound;
            }
            // Store reference to part (no allocation needed since it's a slice of name)
            try path_parts.append(allocator, part);
        }

        // Try each search path
        for (self.searchpath) |search_path| {
            var full_path = std.ArrayList(u8){};
            defer full_path.deinit(allocator);

            try full_path.appendSlice(allocator, search_path);
            if (!std.mem.endsWith(u8, search_path, std.fs.path.sep_str)) {
                try full_path.appendSlice(allocator, std.fs.path.sep_str);
            }

            for (path_parts.items) |part| {
                try full_path.appendSlice(allocator, part);
                try full_path.appendSlice(allocator, std.fs.path.sep_str);
            }

            // Remove trailing separator
            if (full_path.items.len > 0) {
                _ = full_path.pop();
            }

            const path_str = try full_path.toOwnedSlice(allocator);
            defer allocator.free(path_str);

            // Try to open the file - convert file errors to TemplateNotFound
            const file = std.fs.cwd().openFile(path_str, .{}) catch {
                continue; // Try next search path
            };
            defer file.close();

            // Read file contents - convert read errors to RuntimeError
            const contents = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch {
                return exceptions.TemplateError.RuntimeError;
            };
            return contents;
        }

        return exceptions.TemplateError.TemplateNotFound;
    }

    /// List templates implementation
    fn listTemplatesImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) LoaderError![][]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        var templates = std.ArrayList([]const u8){};
        errdefer {
            for (templates.items) |template| {
                allocator.free(template);
            }
            templates.deinit(allocator);
        }

        // List templates from all search paths
        for (self.searchpath) |search_path| {
            var dir = std.fs.cwd().openDir(search_path, .{ .iterate = true }) catch continue;
            defer dir.close();

            var walker = dir.walk(allocator) catch continue;
            defer walker.deinit();

            while (walker.next() catch continue) |entry| {
                if (entry.kind == .file) {
                    // Check if it's a template file (simple check - could be enhanced)
                    const template_name = try std.fs.path.join(allocator, &[_][]const u8{ search_path, entry.path });
                    try templates.append(allocator, template_name);
                }
            }
        }

        return try templates.toOwnedSlice(allocator);
    }

    /// Deinit implementation
    fn deinitImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) void {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        // Free search paths
        for (self.searchpath) |path| {
            allocator.free(path);
        }
        allocator.free(self.searchpath);
    }

    /// Initialize a file system loader with search paths
    ///
    /// **Important:** After calling init, you must set the impl pointer. This is
    /// handled automatically when using `getLoader()` or `initAndGetLoader()`.
    ///
    /// ```zig
    /// // Option 1: Manual setup (advanced)
    /// var loader = try FileSystemLoader.init(allocator, searchpath);
    /// loader.loader.impl = @ptrCast(&loader);
    ///
    /// // Option 2: Recommended - use initAndGetLoader (handles impl automatically)
    /// const loader = try FileSystemLoader.initAndGetLoader(allocator, searchpath);
    /// ```
    pub fn init(allocator: std.mem.Allocator, searchpath: []const []const u8) !Self {
        // Copy search paths
        const paths_copy = try allocator.alloc([]const u8, searchpath.len);
        errdefer allocator.free(paths_copy);

        for (searchpath, 0..) |path, i| {
            paths_copy[i] = try allocator.dupe(u8, path);
        }

        return Self{
            .loader = Loader{
                .vtable = &vtable,
                .allocator = allocator,
                .impl = undefined, // Must be set by caller after init returns
            },
            .allocator = allocator,
            .searchpath = paths_copy,
        };
    }

    /// Initialize and return a pointer to the loader interface
    /// This correctly sets up the impl pointer. Use this method through the Loader interface.
    pub fn getLoader(self: *Self) *Loader {
        self.loader.impl = @ptrCast(self);
        return &self.loader;
    }

    /// Deinitialize the loader
    pub fn deinit(self: *Self) void {
        self.loader.impl = @ptrCast(self);
        self.loader.deinit();
    }
};

/// Dictionary loader - loads templates from an in-memory dictionary
pub const DictLoader = struct {
    loader: Loader,
    allocator: std.mem.Allocator,
    templates: std.StringHashMap([]const u8),

    const Self = @This();

    /// VTable for DictLoader
    const vtable = Loader.VTable{
        .load = loadImpl,
        .listTemplates = listTemplatesImpl,
        .uptodate = uptodateImpl,
        .deinit = deinitImpl,
    };

    /// Uptodate implementation - DictLoader templates never change
    fn uptodateImpl(loader_ptr: *Loader, name: []const u8, last_modified: i64) bool {
        _ = loader_ptr;
        _ = name;
        _ = last_modified;
        // DictLoader templates are in-memory and don't change
        // Always return true (up-to-date)
        return true;
    }

    /// Load implementation
    fn loadImpl(loader_ptr: *Loader, name: []const u8, allocator: std.mem.Allocator) LoaderError![]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        if (self.templates.get(name)) |content| {
            return try allocator.dupe(u8, content);
        }

        return exceptions.TemplateError.TemplateNotFound;
    }

    /// List templates implementation
    fn listTemplatesImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) LoaderError![][]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        var templates = std.ArrayList([]const u8){};
        errdefer {
            for (templates.items) |template| {
                allocator.free(template);
            }
            templates.deinit(allocator);
        }

        var iter = self.templates.iterator();
        while (iter.next()) |entry| {
            const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
            try templates.append(allocator, name_copy);
        }

        return try templates.toOwnedSlice(allocator);
    }

    /// Deinit implementation
    fn deinitImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) void {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        // Free template names and values
        var iter = self.templates.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.templates.deinit();
    }

    /// Initialize a dictionary loader with templates
    pub fn init(allocator: std.mem.Allocator, templates: std.StringHashMap([]const u8)) Self {
        return Self{
            .loader = Loader{
                .vtable = &vtable,
                .allocator = allocator,
                .impl = undefined, // Must be set by caller or via getLoader
            },
            .allocator = allocator,
            .templates = templates,
        };
    }

    /// Initialize and return a pointer to the loader interface
    pub fn getLoader(self: *Self) *Loader {
        self.loader.impl = @ptrCast(self);
        return &self.loader;
    }

    /// Deinitialize the loader
    pub fn deinit(self: *Self) void {
        self.loader.impl = @ptrCast(self);
        self.loader.deinit();
    }
};

/// Function loader - loads templates via a function pointer
/// Matches Python's FunctionLoader which accepts a function that can return:
/// - Just a string (source only)
/// - A tuple (source, filename, uptodate_func)
/// - None (template not found)
pub const FunctionLoader = struct {
    loader: Loader,
    allocator: std.mem.Allocator,
    /// Load function that returns FunctionLoaderResult or null if not found
    /// This matches Python's behavior where the function can return:
    /// - str: just the source
    /// - tuple: (source, filename, uptodate_func)
    /// - None: template not found
    load_func: *const fn (name: []const u8, allocator: std.mem.Allocator) anyerror!?FunctionLoaderResult,
    /// Cached uptodate functions returned from load_func, keyed by template name
    uptodate_cache: std.StringHashMap(*const fn () bool),
    /// Legacy uptodate function for backwards compatibility
    /// If provided, this is used when load_func doesn't return an uptodate function
    legacy_uptodate_func: ?*const fn (name: []const u8, last_modified: i64) bool,

    const Self = @This();

    /// VTable for FunctionLoader
    const vtable = Loader.VTable{
        .load = loadImpl,
        .listTemplates = null, // FunctionLoader doesn't support listing (same as Python)
        .uptodate = uptodateImpl,
        .deinit = deinitImpl,
    };

    /// Uptodate implementation
    /// Checks if template is still up to date using the uptodate function
    /// returned by the load function, or falls back to legacy uptodate func
    fn uptodateImpl(loader_ptr: *Loader, name: []const u8, last_modified: i64) bool {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        // First check if we have a cached uptodate function from load_func
        if (self.uptodate_cache.get(name)) |uptodate_fn| {
            return uptodate_fn();
        }

        // Fall back to legacy uptodate function if provided
        if (self.legacy_uptodate_func) |func| {
            return func(name, last_modified);
        }

        // Default: assume up-to-date if no uptodate function provided
        // This matches Python's behavior when uptodate is None
        return true;
    }

    /// Load implementation
    fn loadImpl(loader_ptr: *Loader, name: []const u8, allocator: std.mem.Allocator) LoaderError![]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        const result = self.load_func(name, allocator) catch return exceptions.TemplateError.RuntimeError;

        if (result) |r| {
            // Cache the uptodate function if provided
            if (r.uptodate_func) |uptodate_fn| {
                // Store in cache (we need to dupe the name for the key)
                const name_copy = self.allocator.dupe(u8, name) catch return exceptions.TemplateError.RuntimeError;
                self.uptodate_cache.put(name_copy, uptodate_fn) catch {
                    self.allocator.free(name_copy);
                    return exceptions.TemplateError.RuntimeError;
                };
            }

            // Free filename if allocated
            // (FunctionLoader returns optional filename for traceback support,
            // but the source is the primary data - filename is freed here as
            // the template name serves as the identifier)
            if (r.filename) |filename| {
                allocator.free(filename);
            }

            return r.source;
        }

        return exceptions.TemplateError.TemplateNotFound;
    }

    /// Deinit implementation
    fn deinitImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) void {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));
        _ = allocator;

        // Free cached uptodate keys
        var iter = self.uptodate_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.uptodate_cache.deinit();
    }

    /// Initialize a function loader with a function that returns FunctionLoaderResult
    /// This is the preferred initialization method matching Python's FunctionLoader
    pub fn init(
        allocator: std.mem.Allocator,
        load_func: *const fn (name: []const u8, allocator: std.mem.Allocator) anyerror!?FunctionLoaderResult,
    ) Self {
        return Self{
            .loader = Loader{
                .vtable = &vtable,
                .allocator = allocator,
                .impl = undefined, // Must be set by caller or via getLoader
            },
            .allocator = allocator,
            .load_func = load_func,
            .uptodate_cache = std.StringHashMap(*const fn () bool).init(allocator),
            .legacy_uptodate_func = null,
        };
    }

    /// Initialize a function loader with legacy uptodate function
    /// For backwards compatibility with code that uses separate uptodate functions
    pub fn initWithLegacyUptodate(
        allocator: std.mem.Allocator,
        load_func: *const fn (name: []const u8, allocator: std.mem.Allocator) anyerror!?FunctionLoaderResult,
        uptodate_func: ?*const fn (name: []const u8, last_modified: i64) bool,
    ) Self {
        return Self{
            .loader = Loader{
                .vtable = &vtable,
                .allocator = allocator,
                .impl = undefined, // Must be set by caller or via getLoader
            },
            .allocator = allocator,
            .load_func = load_func,
            .uptodate_cache = std.StringHashMap(*const fn () bool).init(allocator),
            .legacy_uptodate_func = uptodate_func,
        };
    }

    /// Initialize and return a pointer to the loader interface
    pub fn getLoader(self: *Self) *Loader {
        self.loader.impl = @ptrCast(self);
        return &self.loader;
    }

    /// Deinitialize the loader
    pub fn deinit(self: *Self) void {
        self.loader.impl = @ptrCast(self);
        self.loader.deinit();
    }
};

/// Prefix loader - routes to different loaders based on prefix
pub const PrefixLoader = struct {
    loader: Loader,
    allocator: std.mem.Allocator,
    mapping: std.StringHashMap(*Loader),
    delimiter: []const u8,

    const Self = @This();

    /// VTable for PrefixLoader
    const vtable = Loader.VTable{
        .load = loadImpl,
        .listTemplates = listTemplatesImpl,
        .uptodate = uptodateImpl,
        .deinit = deinitImpl,
    };

    /// Uptodate implementation
    fn uptodateImpl(loader_ptr: *Loader, name: []const u8, last_modified: i64) bool {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        // Split name by delimiter
        if (std.mem.indexOf(u8, name, self.delimiter)) |delim_pos| {
            const prefix = name[0..delim_pos];
            const remaining = name[delim_pos + self.delimiter.len ..];

            if (self.mapping.get(prefix)) |sub_loader| {
                return sub_loader.uptodate(remaining, last_modified);
            }
        }

        return false;
    }

    /// Load implementation
    fn loadImpl(loader_ptr: *Loader, name: []const u8, allocator: std.mem.Allocator) LoaderError![]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));
        _ = allocator; // Suppress unused warning

        // Split name by delimiter
        if (std.mem.indexOf(u8, name, self.delimiter)) |delim_pos| {
            const prefix = name[0..delim_pos];
            const remaining = name[delim_pos + self.delimiter.len ..];

            if (self.mapping.get(prefix)) |sub_loader| {
                return sub_loader.load(remaining);
            }
        }

        return exceptions.TemplateError.TemplateNotFound;
    }

    /// List templates implementation
    fn listTemplatesImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) LoaderError![][]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        var templates = std.ArrayList([]const u8){};
        errdefer {
            for (templates.items) |template| {
                allocator.free(template);
            }
            templates.deinit(allocator);
        }

        // List templates from all sub-loaders
        var iter = self.mapping.iterator();
        while (iter.next()) |entry| {
            const prefix = entry.key_ptr.*;
            const sub_loader = entry.value_ptr.*;

            // Try to list templates from sub-loader
            if (sub_loader.listTemplates()) |sub_templates| {
                defer {
                    for (sub_templates) |t| {
                        allocator.free(t);
                    }
                    allocator.free(sub_templates);
                }

                for (sub_templates) |template| {
                    // Prepend prefix
                    const prefixed_name = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, self.delimiter, template });
                    try templates.append(allocator, prefixed_name);
                }
            } else |_| {
                // Sub-loader doesn't support listing, skip
            }
        }

        return try templates.toOwnedSlice(allocator);
    }

    /// Deinit implementation
    fn deinitImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) void {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        // Free prefix strings
        var iter = self.mapping.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.mapping.deinit();

        // Free delimiter
        allocator.free(self.delimiter);
    }

    /// Initialize a prefix loader
    pub fn init(
        allocator: std.mem.Allocator,
        mapping: std.StringHashMap(*Loader),
        delimiter: []const u8,
    ) !Self {
        // Copy delimiter
        const delimiter_copy = try allocator.dupe(u8, delimiter);
        errdefer allocator.free(delimiter_copy);

        // Copy mapping keys
        var mapping_copy = std.StringHashMap(*Loader).init(allocator);
        errdefer {
            var iter = mapping_copy.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            mapping_copy.deinit();
        }

        var iter = mapping.iterator();
        while (iter.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);
            try mapping_copy.put(key_copy, entry.value_ptr.*);
        }

        return Self{
            .loader = Loader{
                .vtable = &vtable,
                .allocator = allocator,
                .impl = undefined, // Must be set by caller or via getLoader
            },
            .allocator = allocator,
            .mapping = mapping_copy,
            .delimiter = delimiter_copy,
        };
    }

    /// Initialize and return a pointer to the loader interface
    pub fn getLoader(self: *Self) *Loader {
        self.loader.impl = @ptrCast(self);
        return &self.loader;
    }

    /// Deinitialize the loader
    pub fn deinit(self: *Self) void {
        self.loader.impl = @ptrCast(self);
        self.loader.deinit();
    }
};

/// Choice loader - tries multiple loaders in order until one succeeds
pub const ChoiceLoader = struct {
    loader: Loader,
    allocator: std.mem.Allocator,
    loaders: std.ArrayList(*Loader),

    const Self = @This();

    /// VTable for ChoiceLoader
    const vtable = Loader.VTable{
        .load = loadImpl,
        .listTemplates = listTemplatesImpl,
        .uptodate = uptodateImpl,
        .deinit = deinitImpl,
    };

    /// Uptodate implementation
    fn uptodateImpl(loader_ptr: *Loader, name: []const u8, last_modified: i64) bool {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        // Try each loader until one succeeds
        for (self.loaders.items) |sub_loader| {
            if (sub_loader.uptodate(name, last_modified)) {
                return true;
            }
        }

        return false;
    }

    /// Load implementation
    fn loadImpl(loader_ptr: *Loader, name: []const u8, allocator: std.mem.Allocator) LoaderError![]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));
        _ = allocator; // Suppress unused warning

        // Try each loader until one succeeds
        for (self.loaders.items) |sub_loader| {
            if (sub_loader.load(name)) |content| {
                return content;
            } else |err| {
                if (err == exceptions.TemplateError.TemplateNotFound) {
                    continue; // Try next loader
                }
                return err; // Propagate other errors
            }
        }

        return exceptions.TemplateError.TemplateNotFound;
    }

    /// List templates implementation
    fn listTemplatesImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) LoaderError![][]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        var templates = std.ArrayList([]const u8){};
        errdefer {
            for (templates.items) |template| {
                allocator.free(template);
            }
            templates.deinit(allocator);
        }

        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        // Collect templates from all loaders, avoiding duplicates
        for (self.loaders.items) |sub_loader| {
            if (sub_loader.listTemplates()) |sub_templates| {
                defer {
                    for (sub_templates) |t| {
                        allocator.free(t);
                    }
                    allocator.free(sub_templates);
                }

                for (sub_templates) |template| {
                    if (!seen.contains(template)) {
                        const template_copy = try allocator.dupe(u8, template);
                        try templates.append(allocator, template_copy);
                        try seen.put(template_copy, {});
                    }
                }
            } else |_| {
                // Sub-loader doesn't support listing, skip
            }
        }

        return try templates.toOwnedSlice(allocator);
    }

    /// Deinit implementation
    fn deinitImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) void {
        _ = loader_ptr;
        _ = allocator;
        // ChoiceLoader doesn't own the sub-loaders - nothing to clean up
    }

    /// Initialize a choice loader
    pub fn init(allocator: std.mem.Allocator, loaders: []*Loader) !Self {
        // Copy loaders list
        const loaders_copy = try allocator.alloc(*Loader, loaders.len);
        @memcpy(loaders_copy, loaders);

        return Self{
            .loader = Loader{
                .vtable = &vtable,
                .allocator = allocator,
                .impl = undefined, // Must be set by caller or via getLoader
            },
            .allocator = allocator,
            .loaders = std.ArrayList(*Loader).fromOwnedSlice(loaders_copy),
        };
    }

    /// Initialize and return a pointer to the loader interface
    pub fn getLoader(self: *Self) *Loader {
        self.loader.impl = @ptrCast(self);
        return &self.loader;
    }

    /// Deinitialize the loader
    pub fn deinit(self: *Self) void {
        self.loaders.deinit(self.allocator);
        self.loader.impl = @ptrCast(self);
        self.loader.deinit();
    }
};

/// Package loader - loads templates from Zig packages
pub const PackageLoader = struct {
    loader: Loader,
    allocator: std.mem.Allocator,
    package_path: []const u8,
    package_name: []const u8,
    resource_path: []const u8,

    const Self = @This();

    /// VTable for PackageLoader
    const vtable = Loader.VTable{
        .load = loadImpl,
        .listTemplates = listTemplatesImpl,
        .uptodate = uptodateImpl,
        .deinit = deinitImpl,
    };

    /// Uptodate implementation - check file modification time
    fn uptodateImpl(loader_ptr: *Loader, name: []const u8, last_modified: i64) bool {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        // Build full path
        var full_path = std.ArrayList(u8){};
        defer full_path.deinit(self.allocator);

        full_path.appendSlice(self.allocator, self.package_path) catch return false;
        if (!std.mem.endsWith(u8, self.package_path, std.fs.path.sep_str)) {
            full_path.appendSlice(self.allocator, std.fs.path.sep_str) catch return false;
        }
        full_path.appendSlice(self.allocator, self.resource_path) catch return false;
        if (!std.mem.endsWith(u8, self.resource_path, std.fs.path.sep_str)) {
            full_path.appendSlice(self.allocator, std.fs.path.sep_str) catch return false;
        }
        full_path.appendSlice(self.allocator, name) catch return false;

        const path_str = full_path.toOwnedSlice(self.allocator) catch return false;
        defer self.allocator.free(path_str);

        // Check file modification time
        const file = std.fs.cwd().openFile(path_str, .{}) catch return false;
        defer file.close();

        const stat = file.stat() catch return false;
        const file_mtime = @as(i64, @intCast(stat.mtime));

        return file_mtime <= last_modified;
    }

    /// Load implementation
    fn loadImpl(loader_ptr: *Loader, name: []const u8, allocator: std.mem.Allocator) LoaderError![]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        // Build full path
        var full_path = std.ArrayList(u8){};
        defer full_path.deinit(allocator);

        try full_path.appendSlice(allocator, self.package_path);
        if (!std.mem.endsWith(u8, self.package_path, std.fs.path.sep_str)) {
            try full_path.appendSlice(allocator, std.fs.path.sep_str);
        }
        try full_path.appendSlice(allocator, self.resource_path);
        if (!std.mem.endsWith(u8, self.resource_path, std.fs.path.sep_str)) {
            try full_path.appendSlice(allocator, std.fs.path.sep_str);
        }
        try full_path.appendSlice(allocator, name);

        const path_str = try full_path.toOwnedSlice(allocator);
        defer allocator.free(path_str);

        // Try to open the file - convert file errors to template errors
        const file = std.fs.cwd().openFile(path_str, .{}) catch {
            return exceptions.TemplateError.TemplateNotFound;
        };
        defer file.close();

        // Read file contents - convert read errors to runtime errors
        const contents = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch {
            return exceptions.TemplateError.RuntimeError;
        };
        return contents;
    }

    /// List templates implementation
    fn listTemplatesImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) LoaderError![][]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        var templates = std.ArrayList([]const u8){};
        errdefer {
            for (templates.items) |template| {
                allocator.free(template);
            }
            templates.deinit(allocator);
        }

        // Build resource directory path
        var resource_dir = std.ArrayList(u8){};
        defer resource_dir.deinit(allocator);

        try resource_dir.appendSlice(allocator, self.package_path);
        if (!std.mem.endsWith(u8, self.package_path, std.fs.path.sep_str)) {
            try resource_dir.appendSlice(allocator, std.fs.path.sep_str);
        }
        try resource_dir.appendSlice(allocator, self.resource_path);

        const dir_path = try resource_dir.toOwnedSlice(allocator);
        defer allocator.free(dir_path);

        // List templates from resource directory
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return templates.toOwnedSlice(allocator);
        defer dir.close();

        var walker = dir.walk(allocator) catch return templates.toOwnedSlice(allocator);
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind == .file) {
                const template_name = try allocator.dupe(u8, entry.path);
                try templates.append(allocator, template_name);
            }
        }

        return try templates.toOwnedSlice(allocator);
    }

    /// Deinit implementation
    fn deinitImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) void {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        allocator.free(self.package_path);
        allocator.free(self.package_name);
        allocator.free(self.resource_path);
    }

    /// Initialize a package loader
    pub fn init(
        allocator: std.mem.Allocator,
        package_path: []const u8,
        package_name: []const u8,
        resource_path: []const u8,
    ) !Self {
        const package_path_copy = try allocator.dupe(u8, package_path);
        errdefer allocator.free(package_path_copy);

        const package_name_copy = try allocator.dupe(u8, package_name);
        errdefer {
            allocator.free(package_path_copy);
            allocator.free(package_name_copy);
        }

        const resource_path_copy = try allocator.dupe(u8, resource_path);
        errdefer {
            allocator.free(package_path_copy);
            allocator.free(package_name_copy);
            allocator.free(resource_path_copy);
        }

        return Self{
            .loader = Loader{
                .vtable = &vtable,
                .allocator = allocator,
                .impl = undefined, // Must be set by caller or via getLoader
            },
            .allocator = allocator,
            .package_path = package_path_copy,
            .package_name = package_name_copy,
            .resource_path = resource_path_copy,
        };
    }

    /// Initialize and return a pointer to the loader interface
    pub fn getLoader(self: *Self) *Loader {
        self.loader.impl = @ptrCast(self);
        return &self.loader;
    }

    /// Deinitialize the loader
    pub fn deinit(self: *Self) void {
        self.loader.impl = @ptrCast(self);
        self.loader.deinit();
    }
};

/// Module loader - loads precompiled templates from modules
/// This loader loads templates from precompiled template files, matching Python's ModuleLoader.
///
/// Example usage:
/// ```zig
/// var loader = try ModuleLoader.init(allocator, &[_][]const u8{"/path/to/compiled/templates"});
/// defer loader.deinit();
/// ```
///
/// Templates can be precompiled and stored with filenames generated by `getModuleFilename()`.
/// The loader uses SHA1 hashing to generate consistent template keys, matching Python's behavior.
pub const ModuleLoader = struct {
    loader: Loader,
    allocator: std.mem.Allocator,
    /// Search paths for precompiled templates (supports multiple paths like Python)
    paths: []const []const u8,
    /// Registered templates mapping (template name -> precompiled content)
    /// This is an alternative to file-based loading for embedded templates
    registered_templates: std.StringHashMap([]const u8),

    /// Whether this loader can provide access to template source
    /// ModuleLoader loads precompiled templates, so this is false (matches Python)
    pub const has_source_access = false;

    const Self = @This();

    /// VTable for ModuleLoader
    const vtable = Loader.VTable{
        .load = loadImpl,
        .listTemplates = listTemplatesImpl,
        .uptodate = uptodateImpl,
        .deinit = deinitImpl,
    };

    /// Get the template key for a given template name
    /// Returns "tmpl_<sha1_hex>" matching Python's ModuleLoader.get_template_key()
    pub fn getTemplateKey(name: []const u8) [45]u8 {
        var hasher = crypto.hash.Sha1.init(.{});
        hasher.update(name);
        const hash = hasher.finalResult();

        var result: [45]u8 = undefined;
        @memcpy(result[0..5], "tmpl_");
        // Format each byte as 2 hex characters
        const hex_chars = "0123456789abcdef";
        for (hash, 0..) |byte, i| {
            result[5 + i * 2] = hex_chars[byte >> 4];
            result[5 + i * 2 + 1] = hex_chars[byte & 0x0f];
        }

        return result;
    }

    /// Get the module filename for a given template name
    /// Returns "tmpl_<sha1_hex>.zig" (using .zig extension for Zig, Python uses .py)
    pub fn getModuleFilename(name: []const u8) [49]u8 {
        const key = getTemplateKey(name);
        var result: [49]u8 = undefined;
        @memcpy(result[0..45], &key);
        @memcpy(result[45..49], ".zig");
        return result;
    }

    /// Uptodate implementation - ModuleLoader templates are precompiled and don't change
    fn uptodateImpl(loader_ptr: *Loader, name: []const u8, last_modified: i64) bool {
        _ = loader_ptr;
        _ = name;
        _ = last_modified;
        // ModuleLoader templates are precompiled and considered always up-to-date
        // This matches Python's behavior where precompiled templates don't have an uptodate function
        return true;
    }

    /// Load implementation
    fn loadImpl(loader_ptr: *Loader, name: []const u8, allocator: std.mem.Allocator) LoaderError![]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        // First check registered templates
        if (self.registered_templates.get(name)) |content| {
            return try allocator.dupe(u8, content);
        }

        // Get the module filename for this template
        const module_filename = getModuleFilename(name);

        // Try each search path
        for (self.paths) |search_path| {
            var full_path = std.ArrayList(u8){};
            defer full_path.deinit(allocator);

            try full_path.appendSlice(allocator, search_path);
            if (!std.mem.endsWith(u8, search_path, std.fs.path.sep_str)) {
                try full_path.appendSlice(allocator, std.fs.path.sep_str);
            }
            try full_path.appendSlice(allocator, &module_filename);

            const path_str = try full_path.toOwnedSlice(allocator);
            defer allocator.free(path_str);

            // Try to open the module file
            const file = std.fs.cwd().openFile(path_str, .{}) catch continue;
            defer file.close();

            // Read file contents
            const contents = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch {
                return exceptions.TemplateError.RuntimeError;
            };
            return contents;
        }

        return exceptions.TemplateError.TemplateNotFound;
    }

    /// List templates implementation
    fn listTemplatesImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) LoaderError![][]const u8 {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));

        var templates = std.ArrayList([]const u8){};
        errdefer {
            for (templates.items) |template| {
                allocator.free(template);
            }
            templates.deinit(allocator);
        }

        // Add registered templates
        var iter = self.registered_templates.iterator();
        while (iter.next()) |entry| {
            const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
            try templates.append(allocator, name_copy);
        }

        // Limitation: Cannot list templates loaded from hashed filenames
        // Hash functions are one-way, so we can only list explicitly registered templates.
        // This matches Python Jinja2's ModuleLoader behavior - see module documentation.

        // Sort results
        std.mem.sort([]const u8, templates.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        return try templates.toOwnedSlice(allocator);
    }

    /// Deinit implementation
    fn deinitImpl(loader_ptr: *Loader, allocator: std.mem.Allocator) void {
        const self = @as(*Self, @ptrCast(@alignCast(loader_ptr.impl)));
        _ = allocator;

        // Free paths
        for (self.paths) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.paths);

        // Free registered templates
        var iter = self.registered_templates.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.registered_templates.deinit();
    }

    /// Initialize a module loader with search paths
    /// Supports multiple paths, matching Python's ModuleLoader behavior
    pub fn init(
        allocator: std.mem.Allocator,
        paths: []const []const u8,
    ) !Self {
        // Copy paths
        const paths_copy = try allocator.alloc([]const u8, paths.len);
        errdefer allocator.free(paths_copy);

        for (paths, 0..) |path, i| {
            paths_copy[i] = try allocator.dupe(u8, path);
        }

        return Self{
            .loader = Loader{
                .vtable = &vtable,
                .allocator = allocator,
                .impl = undefined, // Must be set by caller or via getLoader
            },
            .allocator = allocator,
            .paths = paths_copy,
            .registered_templates = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Initialize with a single path (convenience method)
    pub fn initSinglePath(allocator: std.mem.Allocator, path: []const u8) !Self {
        const paths = [_][]const u8{path};
        return try init(allocator, &paths);
    }

    /// Initialize and return a pointer to the loader interface
    pub fn getLoader(self: *Self) *Loader {
        self.loader.impl = @ptrCast(self);
        return &self.loader;
    }

    /// Register a precompiled template directly (alternative to file-based loading)
    /// This is useful for embedding templates at compile time
    pub fn registerTemplate(self: *Self, name: []const u8, content: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const content_copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(content_copy);

        // Remove old entry if exists
        if (self.registered_templates.fetchRemove(name_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.registered_templates.put(name_copy, content_copy);
    }

    /// Deinitialize the loader
    pub fn deinit(self: *Self) void {
        self.loader.impl = @ptrCast(self);
        self.loader.deinit();
    }
};

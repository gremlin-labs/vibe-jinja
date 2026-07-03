//! Runtime support types shared by the compiler and high-level runtime API.

const std = @import("std");
const context = @import("context.zig");
const nodes = @import("nodes.zig");
const value = @import("value.zig");

/// TemplateReference - represents the current template (self).
/// Allows accessing blocks via self.block_name syntax.
pub const TemplateReference = struct {
    allocator: std.mem.Allocator,
    /// Template name
    name: ?[]const u8,
    /// Context containing blocks
    ctx: *context.Context,
    /// Template node
    template: *nodes.Template,

    const Self = @This();

    /// Initialize a template reference.
    pub fn init(allocator: std.mem.Allocator, template: *nodes.Template, ctx: *context.Context, compiler_instance: anytype) Self {
        _ = compiler_instance;
        const name_copy = if (template.name) |n| allocator.dupe(u8, n) catch null else null;
        return Self{
            .allocator = allocator,
            .name = name_copy,
            .ctx = ctx,
            .template = template,
        };
    }

    /// Deinitialize the template reference.
    pub fn deinit(self: *Self) void {
        if (self.name) |name| {
            self.allocator.free(name);
        }
    }

    /// Get a block by name (for self.block_name syntax).
    pub fn getBlock(self: *Self, name: []const u8) ?*nodes.Block {
        const block = self.ctx.getBlock(name) orelse return null;
        return @as(*nodes.Block, @ptrCast(@alignCast(block)));
    }

    /// Render a block by name (for self.block_name() syntax).
    ///
    /// Direct block rendering is owned by compiler.zig. Keeping this method as an
    /// explicit unsupported operation prevents this shared type from depending on
    /// compiler internals and reintroducing an import cycle.
    pub fn renderBlock(self: *Self, name: []const u8, frame: anytype) ![]const u8 {
        _ = self;
        _ = name;
        _ = frame;
        return error.UnsupportedBlockRender;
    }

    /// Get block as a callable (for self.block_name() syntax).
    /// Returns a dict-like value that can be called.
    pub fn getBlockAsValue(self: *Self, name: []const u8, allocator: std.mem.Allocator) !context.Value {
        if (self.ctx.getBlock(name)) |_| {
            const block_dict_ptr = try allocator.create(value.Dict);
            errdefer allocator.destroy(block_dict_ptr);
            block_dict_ptr.* = value.Dict.init(allocator);

            const block_ref_val = context.Value{ .string = try std.fmt.allocPrint(allocator, "<block {s}>", .{name}) };
            try block_dict_ptr.set(name, block_ref_val);

            return context.Value{ .dict = block_dict_ptr };
        }

        return context.Value{ .undefined = value.Undefined{
            .name = name,
            .behavior = .lenient,
        } };
    }
};

/// TemplateModule - represents an imported template.
/// Exports template variables and macros, and provides access to rendered body.
pub const TemplateModule = struct {
    allocator: std.mem.Allocator,
    /// Template name
    name: ?[]const u8,
    /// Rendered body stream
    body_stream: []const u8,
    /// Exported variables (macros and variables marked for export)
    exports: std.StringHashMap(context.Value),

    const Self = @This();

    /// Initialize a template module from a rendered template body.
    pub fn initFromRenderedBody(allocator: std.mem.Allocator, template: *nodes.Template, ctx: *context.Context, body: []const u8) !Self {
        var exports = std.StringHashMap(context.Value).init(allocator);
        errdefer {
            var iter = exports.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(allocator);
            }
            exports.deinit();
        }

        var exported_iter = ctx.exported_vars.iterator();
        while (exported_iter.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);

            const val = ctx.resolve(entry.key_ptr.*);
            if (val != .undefined) {
                const val_copy = try copyValue(allocator, val);
                errdefer val_copy.deinit(allocator);

                try exports.put(key_copy, val_copy);
            }
        }

        var macro_iter = ctx.macros.iterator();
        while (macro_iter.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);

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

    /// Deinitialize the module.
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

    /// Get an exported value by name.
    pub fn get(self: *Self, name: []const u8) ?context.Value {
        return self.exports.get(name);
    }

    /// Convert module to string (renders body).
    pub fn toString(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        _ = allocator;
        return try self.allocator.dupe(u8, self.body_stream);
    }

    fn copyValue(allocator: std.mem.Allocator, val: context.Value) !context.Value {
        return try val.deepCopy(allocator);
    }
};

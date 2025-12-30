const std = @import("std");
const environment = @import("environment.zig");
const nodes = @import("nodes.zig");
const value_mod = @import("value.zig");
const runtime = @import("runtime.zig");

/// Re-export Value type for convenience
pub const Value = value_mod.Value;

/// Context system for template variable resolution and scoping
///
/// The `Context` manages variable resolution, scoping, and template inheritance features.
/// It provides:
/// - Variable resolution with parent context support
/// - Block management for template inheritance
/// - Macro storage and resolution
/// - Imported module management
/// - Template reference (self) support
///
/// Contexts form a hierarchy where child contexts can access parent context variables.
/// This enables features like template inheritance, includes, and scoped variables.
///
/// # Example
///
/// ```zig
/// var vars = std.StringHashMap(jinja.Value).init(allocator);
/// defer vars.deinit();
/// try vars.put("name", jinja.Value{ .string = try allocator.dupe(u8, "World") });
///
/// var ctx = try jinja.context.Context.init(&env, vars, "template.jinja", allocator);
/// defer ctx.deinit();
///
/// // Resolve variables
/// const name = ctx.resolve("name");
/// ```
pub const Context = struct {
    environment: *environment.Environment,
    allocator: std.mem.Allocator,
    /// Parent context (for inheritance)
    parent: ?*Context,
    /// Variables in this context
    vars: std.StringHashMap(Value),
    /// Blocks available in this context (for template inheritance)
    /// Maps block name to a list of blocks (stack for super() support)
    blocks: std.StringHashMap(std.ArrayList(*nodes.Block)),
    /// Macros available in this context
    macros: std.StringHashMap(*nodes.Macro),
    /// Exported variable names
    exported_vars: std.StringHashMap(void),
    /// Imported modules (for import statements)
    imported_modules: std.StringHashMap(*runtime.TemplateModule),
    /// Template reference (self) - allows accessing blocks via self.block_name
    template_ref: ?*runtime.TemplateReference,
    /// Whether this context owns the template_ref (only the context that setTemplateRef was called on)
    owns_template_ref: bool,
    /// Template name
    name: ?[]const u8,
    /// Whether this context owns its name string (needs to free it on deinit)
    owns_name: bool,
    /// Whether this context owns its vars map (created by derived() vs passed to init())
    owns_vars: bool,
    /// Keys that this context allocated (via set()) and needs to free
    owned_keys: std.StringHashMap(void),

    const Self = @This();

    /// Initialize a new context
    ///
    /// Creates a new root context with no parent. Variables are resolved from:
    /// 1. Local variables (`vars`)
    /// 2. Environment globals
    ///
    /// # Arguments
    /// - `env`: Environment to use for global variable resolution
    /// - `vars`: Map of local variables (keys are owned by the context)
    /// - `name`: Optional template name (for error messages)
    /// - `allocator`: Memory allocator to use
    ///
    /// # Returns
    /// A new root context
    ///
    /// # Note
    /// The context makes a deep copy of the vars map and takes ownership.
    /// The caller is still responsible for cleaning up the original vars map.
    pub fn init(env: *environment.Environment, vars: std.StringHashMap(Value), name: ?[]const u8, allocator: std.mem.Allocator) !Self {
        // Create a copy of vars so Context owns its own map
        // This avoids memory issues when Context.set() grows the map
        var new_vars = std.StringHashMap(Value).init(allocator);
        errdefer {
            var iter = new_vars.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(allocator);
            }
            new_vars.deinit();
        }

        var iter = vars.iterator();
        while (iter.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);
            const val_copy = try entry.value_ptr.*.deepCopy(allocator);
            errdefer val_copy.deinit(allocator);
            try new_vars.put(key_copy, val_copy);
        }

        // Track all keys as owned
        var owned_keys = std.StringHashMap(void).init(allocator);
        var keys_iter = new_vars.keyIterator();
        while (keys_iter.next()) |key| {
            try owned_keys.put(key.*, {});
        }

        return Self{
            .environment = env,
            .allocator = allocator,
            .parent = null,
            .vars = new_vars,
            .blocks = std.StringHashMap(std.ArrayList(*nodes.Block)).init(allocator),
            .macros = std.StringHashMap(*nodes.Macro).init(allocator),
            .exported_vars = std.StringHashMap(void).init(allocator),
            .imported_modules = std.StringHashMap(*runtime.TemplateModule).init(allocator),
            .template_ref = null,
            .owns_template_ref = false,
            .name = name,
            .owns_name = false, // Name is borrowed, not owned
            .owns_vars = true, // Context now owns its vars map (copied from input)
            .owned_keys = owned_keys,
        };
    }

    /// Initialize a context with a parent
    ///
    /// Creates a new context with a parent context. Variables are resolved from:
    /// 1. Local variables (`vars`)
    /// 2. Parent context variables
    /// 3. Environment globals
    ///
    /// This is used for template inheritance, includes, and scoped blocks.
    ///
    /// # Arguments
    /// - `env`: Environment to use for global variable resolution
    /// - `vars`: Map of local variables (keys are owned by the context)
    /// - `name`: Optional template name (for error messages)
    /// - `parent`: Parent context to inherit variables from
    /// - `allocator`: Memory allocator to use
    ///
    /// # Returns
    /// A new context with the specified parent
    pub fn initWithParent(env: *environment.Environment, vars: std.StringHashMap(Value), name: ?[]const u8, parent: *Context, allocator: std.mem.Allocator) !Self {
        // Create a copy of vars so Context owns its own map
        var new_vars = std.StringHashMap(Value).init(allocator);
        errdefer {
            var iter = new_vars.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(allocator);
            }
            new_vars.deinit();
        }

        var iter = vars.iterator();
        while (iter.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);
            const val_copy = try entry.value_ptr.*.deepCopy(allocator);
            errdefer val_copy.deinit(allocator);
            try new_vars.put(key_copy, val_copy);
        }

        // Track all keys as owned
        var owned_keys = std.StringHashMap(void).init(allocator);
        var keys_iter = new_vars.keyIterator();
        while (keys_iter.next()) |key| {
            try owned_keys.put(key.*, {});
        }

        return Self{
            .environment = env,
            .allocator = allocator,
            .parent = parent,
            .vars = new_vars,
            .blocks = std.StringHashMap(std.ArrayList(*nodes.Block)).init(allocator),
            .macros = std.StringHashMap(*nodes.Macro).init(allocator),
            .exported_vars = std.StringHashMap(void).init(allocator),
            .imported_modules = std.StringHashMap(*runtime.TemplateModule).init(allocator),
            .template_ref = null,
            .owns_template_ref = false,
            .name = name,
            .owns_name = false, // Name is borrowed, not owned
            .owns_vars = true, // Context now owns its vars map (copied from input)
            .owned_keys = owned_keys,
        };
    }

    /// Create a derived context (independent context with same environment)
    ///
    /// Creates a new context that inherits all variables from this context but is
    /// independent (modifications don't affect the parent). Optionally overrides with
    /// local variables.
    ///
    /// This is used for creating new scopes (e.g., in `with` blocks, includes, etc.)
    /// while preserving the parent context.
    ///
    /// # Arguments
    /// - `locals`: Optional map of local variables to override parent variables
    ///
    /// # Returns
    /// A new derived context with copied variables
    ///
    /// # Errors
    /// - `error.OutOfMemory` - Memory allocation failed
    pub fn derived(self: *Self, locals: ?std.StringHashMap(Value)) !Self {
        // Create new vars map
        var new_vars = std.StringHashMap(Value).init(self.allocator);
        errdefer {
            var iter = new_vars.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(self.allocator);
            }
            new_vars.deinit();
        }

        // Copy all variables from parent context
        var all_vars = self.getAll();
        defer {
            var iter = all_vars.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            all_vars.deinit();
        }

        var iter = all_vars.iterator();
        while (iter.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key_copy);
            const val_copy = try entry.value_ptr.*.deepCopy(self.allocator);
            errdefer val_copy.deinit(self.allocator);
            try new_vars.put(key_copy, val_copy);
        }

        // Override with local variables if provided
        if (locals) |local_vars| {
            var local_iter = local_vars.iterator();
            while (local_iter.next()) |entry| {
                // Remove old value if exists
                if (new_vars.fetchRemove(entry.key_ptr.*)) |old| {
                    self.allocator.free(old.key);
                    old.value.deinit(self.allocator);
                }

                const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                errdefer self.allocator.free(key_copy);
                const val_copy = try entry.value_ptr.*.deepCopy(self.allocator);
                errdefer val_copy.deinit(self.allocator);
                try new_vars.put(key_copy, val_copy);
            }
        }

        // Create owned_keys set with all keys from new_vars (all are owned by derived context)
        var owned_keys = std.StringHashMap(void).init(self.allocator);
        var keys_iter = new_vars.keyIterator();
        while (keys_iter.next()) |key| {
            try owned_keys.put(key.*, {});
        }

        // Create derived context
        var derived_ctx = Self{
            .environment = self.environment,
            .allocator = self.allocator,
            .parent = self,
            .vars = new_vars,
            .blocks = std.StringHashMap(std.ArrayList(*nodes.Block)).init(self.allocator),
            .macros = std.StringHashMap(*nodes.Macro).init(self.allocator),
            .exported_vars = std.StringHashMap(void).init(self.allocator),
            .imported_modules = std.StringHashMap(*runtime.TemplateModule).init(self.allocator),
            .template_ref = self.template_ref,
            .owns_template_ref = false, // Derived context borrows template_ref from parent
            .name = if (self.name) |n| try self.allocator.dupe(u8, n) else null,
            .owns_name = self.name != null, // Name is owned if we duplicated it
            .owns_vars = true, // Derived context owns its vars map
            .owned_keys = owned_keys,
        };

        // Copy blocks from parent
        var block_iter = self.blocks.iterator();
        while (block_iter.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key_copy);

            // Copy block stack
            var stack_copy = std.ArrayList(*nodes.Block).empty;
            for (entry.value_ptr.*.items) |block| {
                try stack_copy.append(self.allocator, block);
            }
            try derived_ctx.blocks.put(key_copy, stack_copy);
        }

        return derived_ctx;
    }

    /// Set template reference (self)
    pub fn setTemplateRef(self: *Self, template_ref: *runtime.TemplateReference) void {
        self.template_ref = template_ref;
        self.owns_template_ref = true; // This context now owns the template_ref

        // Also add 'self' as a variable (dict-like access to blocks)
        // Create a dict that maps block names to block references
        const self_dict_ptr = self.allocator.create(value_mod.Dict) catch return;
        self_dict_ptr.* = value_mod.Dict.init(self.allocator);

        // Add all blocks to the dict
        var block_iter = self.blocks.iterator();
        while (block_iter.next()) |entry| {
            if (entry.value_ptr.*.items.len > 0) {
                // Store block reference as a string (simplified)
                // Note: Dict.set duplicates keys internally, so pass entry.key_ptr.* directly
                // Only duplicate the value (block_name_copy) since Dict.set doesn't duplicate values
                const block_name_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                const block_val = Value{ .string = block_name_copy };
                self_dict_ptr.set(entry.key_ptr.*, block_val) catch {
                    self.allocator.free(block_name_copy);
                    continue;
                };
            }
        }

        const self_value = Value{ .dict = self_dict_ptr };
        // Duplicate the "self" key since deinit() will free all keys
        const self_key = self.allocator.dupe(u8, "self") catch return;
        self.vars.put(self_key, self_value) catch {
            self.allocator.free(self_key);
            return;
        };
        // Track this key as owned so it gets freed in deinit
        self.owned_keys.put(self_key, {}) catch {};
    }

    /// Deinitialize the context and free allocated memory
    /// All keys and values in vars are freed since Context owns its copy of the vars map.
    pub fn deinit(self: *Self) void {
        // Context always owns its vars map (init makes a copy, derived creates new)
        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.vars.deinit();
        self.owned_keys.deinit();

        // Blocks are owned by template, don't free them
        // But we need to free the ArrayList wrappers
        var block_iter = self.blocks.iterator();
        while (block_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.blocks.deinit();

        // Macros are owned by template, don't free them
        // But we DO own the hashmap keys (allocated in setMacro)
        var macro_key_iter = self.macros.iterator();
        while (macro_key_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.macros.deinit();

        // Free exported variable names
        var exported_iter = self.exported_vars.iterator();
        while (exported_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.exported_vars.deinit();

        // Free imported modules (modules are owned by context)
        var module_iter = self.imported_modules.iterator();
        while (module_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.imported_modules.deinit();

        // Free template reference only if we own it
        // (Only the context that received it via setTemplateRef owns it)
        if (self.owns_template_ref) {
            if (self.template_ref) |ref| {
                self.allocator.destroy(ref);
            }
        }

        // Free name only if we own it (was allocated by this context)
        if (self.owns_name) {
            if (self.name) |name| {
                self.allocator.free(name);
            }
        }
    }

    /// Resolve a variable name, checking parent contexts and globals
    /// Returns undefined value if variable is not found, based on environment policy
    /// Note: Not inline due to recursion
    pub fn resolve(self: *Self, name: []const u8) Value {
        // Check local variables first
        if (self.vars.get(name)) |val| {
            return val;
        }

        // Check template reference (self) for block access
        if (self.template_ref) |ref| {
            // Check if accessing a block via self.block_name
            if (ref.getBlock(name)) |_| {
                // Return block reference as a dict-like value
                // In a full implementation, this would be callable
                const block_dict_ptr = self.allocator.create(value_mod.Dict) catch return Value{ .undefined = value_mod.Undefined{
                    .name = name,
                    .behavior = self.environment.undefined_behavior,
                } };
                block_dict_ptr.* = value_mod.Dict.init(self.allocator);
                const block_name_copy = self.allocator.dupe(u8, name) catch {
                    self.allocator.destroy(block_dict_ptr);
                    return Value{ .undefined = value_mod.Undefined{
                        .name = name,
                        .behavior = self.environment.undefined_behavior,
                    } };
                };
                const block_val = Value{ .string = block_name_copy };
                block_dict_ptr.set(block_name_copy, block_val) catch {
                    self.allocator.free(block_name_copy);
                    self.allocator.destroy(block_dict_ptr);
                    return Value{ .undefined = value_mod.Undefined{
                        .name = name,
                        .behavior = self.environment.undefined_behavior,
                    } };
                };
                return Value{ .dict = block_dict_ptr };
            }
        }

        // Check environment globals
        if (self.environment.getGlobal(name)) |val| {
            return val;
        }

        // Check parent context
        if (self.parent) |parent| {
            return parent.resolve(name);
        }

        // Return undefined based on environment policy
        const undefined_policy = self.environment.undefined_behavior;
        return Value{ .undefined = value_mod.Undefined{
            .name = name,
            .behavior = undefined_policy,
        } };
    }

    /// Get a variable with a default value
    pub fn get(self: *Self, name: []const u8, default_value: ?Value) Value {
        if (self.resolve(name)) |val| {
            return val;
        }
        return default_value orelse Value{ .string = "" };
    }

    /// Set a variable in this context
    /// Optimized to avoid unnecessary string duplication if key already exists
    pub inline fn set(self: *Self, name: []const u8, val: Value) !void {
        // Check if key already exists to avoid unnecessary duplication
        if (self.vars.getEntry(name)) |entry| {
            // Key already exists, just update value
            entry.value_ptr.*.deinit(self.allocator);
            entry.value_ptr.* = val;
        } else {
            // New key, duplicate it and track as owned
            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);
            try self.vars.put(name_copy, val);
            // Track this key as owned by this context
            try self.owned_keys.put(name_copy, {});
        }
    }

    /// Export a variable name (makes it available to parent templates)
    pub fn exportVar(self: *Self, name: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.exported_vars.put(name_copy, {});
    }

    /// Check if a variable is exported
    pub fn isExported(self: *Self, name: []const u8) bool {
        return self.exported_vars.contains(name);
    }

    /// Get a block stack by name, checking parent contexts
    /// Returns the list of blocks (stack) for this name
    pub fn getBlockStack(self: *Self, name: []const u8) ?std.ArrayList(*nodes.Block) {
        if (self.blocks.get(name)) |*stack| {
            return stack.*;
        }
        if (self.parent) |parent| {
            return parent.getBlockStack(name);
        }
        return null;
    }

    /// Get the first (current) block by name
    pub fn getBlock(self: *Self, name: []const u8) ?*nodes.Block {
        if (self.getBlockStack(name)) |stack| {
            if (stack.items.len > 0) {
                return stack.items[0];
            }
        }
        return null;
    }

    /// Add a block to the stack (for template inheritance)
    /// Creates a new stack if one doesn't exist, or appends to existing stack
    pub fn addBlock(self: *Self, name: []const u8, block: *nodes.Block) !void {
        // Check if key already exists using the original name (not a copy)
        if (self.blocks.getPtr(name)) |stack_ptr| {
            // Append to existing stack - no need to allocate a new key
            try stack_ptr.append(self.allocator, block);
        } else {
            // Key doesn't exist - allocate a new key and create stack
            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);

            var stack = std.ArrayList(*nodes.Block).empty;
            try stack.append(self.allocator, block);
            try self.blocks.put(name_copy, stack);
        }
    }

    /// Set a block in this context (replaces existing stack)
    pub fn setBlock(self: *Self, name: []const u8, block: *nodes.Block) !void {
        // Remove old stack if exists, using the original name for lookup
        if (self.blocks.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            old.value.deinit(self.allocator);
        }

        // Allocate new key and create new stack
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        var stack = std.ArrayList(*nodes.Block).empty;
        try stack.append(self.allocator, block);
        try self.blocks.put(name_copy, stack);
    }

    /// Get super block (parent block in the stack)
    /// Returns the next block in the stack for the given name, or null if none
    pub fn getSuperBlock(self: *Self, name: []const u8, current_block: *nodes.Block) ?*nodes.Block {
        if (self.blocks.get(name)) |stack| {
            // Find current block index
            for (stack.items, 0..) |block, i| {
                if (block == current_block) {
                    // Return next block in stack (parent)
                    if (i + 1 < stack.items.len) {
                        return stack.items[i + 1];
                    }
                    break;
                }
            }
        }
        return null;
    }

    /// Get a macro by name, checking parent contexts
    pub fn getMacro(self: *Self, name: []const u8) ?*nodes.Macro {
        if (self.macros.get(name)) |macro| {
            return macro;
        }
        if (self.parent) |parent| {
            return parent.getMacro(name);
        }
        return null;
    }

    /// Set a macro in this context
    pub fn setMacro(self: *Self, name: []const u8, macro: *nodes.Macro) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        // Remove old macro if exists
        if (self.macros.fetchRemove(name_copy)) |old| {
            self.allocator.free(old.key);
        }

        try self.macros.put(name_copy, macro);
    }

    /// Set an imported module in this context
    pub fn setImportedModule(self: *Self, name: []const u8, module: *runtime.TemplateModule) !void {
        // Create separate key copies for vars and imported_modules to avoid double-free
        const vars_key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(vars_key);

        const modules_key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(modules_key);

        // Remove old module if exists
        if (self.imported_modules.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            old.value.deinit();
            self.allocator.destroy(old.value);
        }

        // Remove old var if exists (to avoid key leak)
        if (self.vars.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            old.value.deinit(self.allocator);
        }

        // Also add module as a variable (for access via name)
        // Store module reference as a dict-like value
        // Create a dict with the module's exports
        const module_dict_ptr = try self.allocator.create(value_mod.Dict);
        errdefer self.allocator.destroy(module_dict_ptr);
        module_dict_ptr.* = value_mod.Dict.init(self.allocator);

        // Note: Dict.set duplicates keys internally, so pass original key directly
        var module_iter = module.exports.iterator();
        while (module_iter.next()) |entry| {
            // Copy the value (simplified - may need deep copy)
            const val_copy = try copyValueForModule(self.allocator, entry.value_ptr.*);
            errdefer val_copy.deinit(self.allocator);

            try module_dict_ptr.set(entry.key_ptr.*, val_copy);
        }

        const module_value = Value{ .dict = module_dict_ptr };
        try self.vars.put(vars_key, module_value);

        try self.imported_modules.put(modules_key, module);
    }

    /// Helper to copy a value for module storage (uses deepCopy)
    fn copyValueForModule(allocator: std.mem.Allocator, val: Value) !Value {
        return try val.deepCopy(allocator);
    }

    /// Get an imported module by name
    pub fn getImportedModule(self: *Self, name: []const u8) ?*runtime.TemplateModule {
        if (self.imported_modules.get(name)) |module| {
            return module;
        }
        if (self.parent) |parent| {
            return parent.getImportedModule(name);
        }
        return null;
    }

    /// Get all variables (including from parent contexts)
    pub fn getAll(self: *Self) std.StringHashMap(Value) {
        var all = std.StringHashMap(Value).init(self.allocator);

        // Add parent variables first
        if (self.parent) |parent| {
            var parent_iter = parent.vars.iterator();
            while (parent_iter.next()) |entry| {
                const key_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                all.put(key_copy, entry.value_ptr.*) catch {
                    self.allocator.free(key_copy);
                    continue;
                };
            }
        }

        // Add environment globals
        var global_iter = self.environment.globals_map.iterator();
        while (global_iter.next()) |entry| {
            if (!all.contains(entry.key_ptr.*)) {
                const key_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                all.put(key_copy, entry.value_ptr.*) catch {
                    self.allocator.free(key_copy);
                    continue;
                };
            }
        }

        // Add local variables (override parent/globals)
        var local_iter = self.vars.iterator();
        while (local_iter.next()) |entry| {
            if (all.fetchRemove(entry.key_ptr.*)) |old| {
                self.allocator.free(old.key);
            }
            const key_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
            all.put(key_copy, entry.value_ptr.*) catch {
                self.allocator.free(key_copy);
                continue;
            };
        }

        return all;
    }
};

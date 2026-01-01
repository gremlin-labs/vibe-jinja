const std = @import("std");
const environment = @import("environment.zig");
const nodes = @import("nodes.zig");
const context = @import("context.zig");
const exceptions = @import("exceptions.zig");
const value_mod = @import("value.zig");
const runtime = @import("runtime.zig");
const bytecode_mod = @import("bytecode.zig");
const loop_context_mod = @import("loop_context.zig");
const value_pool = @import("value_pool.zig");
const render_arena = @import("render_arena.zig");

/// Re-export optimized loop context
pub const OptimizedLoopContext = loop_context_mod.OptimizedLoopContext;

/// Re-export Value type for convenience
pub const Value = value_mod.Value;

/// Normalize a slice index (Python-style)
/// Handles negative indices: -1 means last element, -2 means second-to-last, etc.
fn normalizeIndex(idx: i64, len: i64) i64 {
    if (idx < 0) {
        return idx + len;
    }
    return idx;
}

/// Compute a simple hash for a value (used by loop.changed())
fn computeValueHash(val: value_mod.Value) u64 {
    return switch (val) {
        .integer => |i| @as(u64, @bitCast(i)),
        .float => |f| @as(u64, @bitCast(f)),
        .boolean => |b| if (b) 1 else 0,
        .null => 0,
        .string => |s| blk: {
            var h: u64 = 0;
            for (s) |c| {
                h = h *% 31 +% c;
            }
            break :blk h;
        },
        .list => |l| blk: {
            var h: u64 = 0;
            for (l.items.items) |item| {
                h = h *% 31 +% computeValueHash(item);
            }
            break :blk h;
        },
        .dict => |d| blk: {
            var h: u64 = 0;
            var iter = d.map.iterator();
            while (iter.next()) |entry| {
                for (entry.key_ptr.*) |c| {
                    h = h *% 31 +% c;
                }
                h = h *% 31 +% computeValueHash(entry.value_ptr.*);
            }
            break :blk h;
        },
        .undefined => 0xDEADBEEF,
        .markup => |m| blk: {
            var h: u64 = 0;
            for (m.content) |c| {
                h = h *% 31 +% c;
            }
            break :blk h;
        },
        .async_result => 0xCAFEBABE,
        .callable => 0xFEEDFACE,
        .custom => 0xC0FFEE,
    };
}

/// Loop context for tracking loop state (for loops)
pub const LoopContext = struct {
    index: usize,
    index0: usize,
    revindex: usize,
    revindex0: usize,
    first: bool,
    last: bool,
    length: usize,
    previtem: ?Value,
    nextitem: ?Value,

    const Self = @This();

    pub fn init(length: usize) Self {
        return Self{
            .index = 1,
            .index0 = 0,
            .revindex = length,
            .revindex0 = if (length > 0) length - 1 else 0,
            .first = true,
            .last = length <= 1,
            .length = length,
            .previtem = null,
            .nextitem = null,
        };
    }

    pub fn update(self: *Self, current_index: usize) void {
        self.index = current_index + 1;
        self.index0 = current_index;
        self.revindex = if (self.length > current_index) self.length - current_index else 0;
        self.revindex0 = if (self.length > current_index + 1) self.length - current_index - 1 else 0;
        self.first = current_index == 0;
        self.last = current_index + 1 >= self.length;
    }
};

/// Frame structure for tracking scope and variables during compilation
pub const Frame = struct {
    name: []const u8,
    parent: ?*Frame,
    variables: std.StringHashMap(Value),
    loop: ?*LoopContext,
    /// Optimized loop context (Phase 1 optimization - zero-allocation loops)
    opt_loop: ?*OptimizedLoopContext = null,
    /// Current block being executed (for super() support)
    current_block: ?*nodes.Block,
    /// Autoescape setting for this frame (inherits from parent if null)
    autoescape: ?bool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(name: []const u8, parent: ?*Frame, allocator: std.mem.Allocator) Self {
        return Self{
            .name = name,
            .parent = parent,
            .variables = std.StringHashMap(Value).init(allocator),
            .loop = null,
            .opt_loop = null,
            .current_block = null,
            .autoescape = null,
            .allocator = allocator,
        };
    }

    /// Get autoescape setting, checking parent frames
    pub fn getAutoescape(self: *Self, env: *environment.Environment, template_name: ?[]const u8) bool {
        if (self.autoescape) |ae| {
            return ae;
        }
        if (self.parent) |parent| {
            return parent.getAutoescape(env, template_name);
        }
        return env.shouldAutoescape(template_name);
    }

    pub fn deinit(self: *Self) void {
        // Free variable keys AND values (both are owned by the frame)
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.variables.deinit();

        // Free loop context if present
        if (self.loop) |loop| {
            self.allocator.destroy(loop);
        }
    }

    /// Resolve a variable, checking parent frames
    /// Returns null if not found (caller should check context/environment)
    /// Note: Not inline due to recursion
    pub fn resolve(self: *Self, name: []const u8) ?Value {
        if (self.variables.get(name)) |value| {
            return value;
        }
        if (self.parent) |parent| {
            return parent.resolve(name);
        }
        return null;
    }

    /// Resolve a loop attribute (e.g., loop.index) using optimized loop context
    /// Returns null if not in a loop or attribute not found
    pub fn resolveLoopAttr(self: *Self, attr: []const u8) ?Value {
        if (self.opt_loop) |opt| {
            return opt.resolveLoopAttr(attr);
        }
        if (self.parent) |parent| {
            return parent.resolveLoopAttr(attr);
        }
        return null;
    }

    /// Get the optimized loop context from this frame or parent
    pub fn getOptLoop(self: *Self) ?*OptimizedLoopContext {
        if (self.opt_loop) |opt| {
            return opt;
        }
        if (self.parent) |parent| {
            return parent.getOptLoop();
        }
        return null;
    }

    /// Set a variable in this frame
    /// Optimized to avoid unnecessary string duplication if key already exists
    pub inline fn set(self: *Self, name: []const u8, value: Value) !void {
        // Check if key already exists to avoid unnecessary duplication
        if (self.variables.getEntry(name)) |entry| {
            // Key already exists, just update value
            entry.value_ptr.*.deinit(self.allocator);
            entry.value_ptr.* = value;
        } else {
            // New key, duplicate it
            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);
            try self.variables.put(name_copy, value);
        }
    }
};

/// Compiled template - result of compilation
/// For now, we'll use direct AST execution rather than code generation
/// since Zig doesn't have eval capabilities
pub const CompiledTemplate = struct {
    template: *nodes.Template,
    environment: *environment.Environment,
    bytecode: ?bytecode_mod.Bytecode, // Optional bytecode for faster execution
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Render the template with given context
    /// Uses arena allocation for all intermediate memory, only final result uses caller's allocator
    pub fn render(self: *Self, ctx: *context.Context, allocator: std.mem.Allocator) ![]const u8 {
        // Phase 2 optimization: Use arena for all intermediate allocations
        // Estimate output size (conservative: 4KB default)
        const estimated_size: usize = 4096;
        var arena = render_arena.RenderArena.init(allocator, estimated_size);
        defer arena.deinit();

        const arena_alloc = arena.allocator();

        // Use bytecode if available, otherwise use AST interpretation
        const result = if (self.bytecode) |*bc| blk: {
            var vm = bytecode_mod.BytecodeVM.init(arena_alloc, bc, ctx);
            defer vm.deinit();
            break :blk try vm.execute();
        } else blk: {
            // Fall back to AST interpretation
            var compiler_inst = Compiler.init(self.environment, self.template.base.filename, arena_alloc);
            defer compiler_inst.deinit();

            var frame = Frame.init("root", null, arena_alloc);
            defer frame.deinit();

            break :blk try compiler_inst.visitTemplate(self.template, &frame, ctx);
        };

        // Copy result to caller's allocator (only allocation that escapes arena)
        return try allocator.dupe(u8, result);
    }

    /// Render the template asynchronously with given context
    ///
    /// Executes the compiled template asynchronously, allowing async filters and tests.
    /// Requires `enable_async` to be set to `true` on the environment.
    ///
    /// **Note:** In Zig, async functions return async frames that must be awaited.
    /// This method properly handles async filters and tests when `enable_async` is true.
    ///
    /// # Arguments
    /// - `ctx`: Context containing variables and template state
    /// - `allocator`: Memory allocator for rendering
    ///
    /// # Returns
    /// Rendered template output as a string. The caller is responsible for freeing the memory.
    ///
    /// # Errors
    /// - `error.AsyncNotEnabled` - Async mode is not enabled
    /// - Template rendering errors
    /// - `error.OutOfMemory` - Memory allocation failed
    pub fn renderAsync(self: *Self, ctx: *context.Context, allocator: std.mem.Allocator) ![]const u8 {
        if (!self.environment.enable_async) {
            return error.AsyncNotEnabled;
        }

        // Phase 2 optimization: Use arena for all intermediate allocations
        const estimated_size: usize = 4096;
        var arena = render_arena.RenderArena.init(allocator, estimated_size);
        defer arena.deinit();

        const arena_alloc = arena.allocator();

        // Always use AST interpretation for async - bytecode async executor is incomplete
        // (doesn't support filters, complex expressions, etc.)
        var compiler_inst = Compiler.init(self.environment, self.template.base.filename, arena_alloc);
        defer compiler_inst.deinit();

        var frame = Frame.init("root", null, arena_alloc);
        defer frame.deinit();

        // visitTemplate will automatically handle async filters/tests
        // when enable_async is true and filters/tests have is_async flag set
        const result = try compiler_inst.visitTemplate(self.template, &frame, ctx);

        // Copy result to caller's allocator (only allocation that escapes arena)
        return try allocator.dupe(u8, result);
    }

    /// Deinitialize the compiled template
    pub fn deinit(self: *Self) void {
        if (self.bytecode) |*bc| {
            bc.deinit();
        }
        // Template is owned by environment cache, don't free it
    }
};

/// Compiler - compiles and executes template AST
///
/// The Compiler transforms parsed template ASTs into executable code and provides
/// methods for rendering templates. It handles variable scoping, block inheritance,
/// filter and test application, and async execution.
pub const Compiler = struct {
    environment: *environment.Environment,
    filename: ?[]const u8,
    allocator: std.mem.Allocator,

    // Frame stack for tracking scopes
    frames: std.ArrayList(*Frame),
    current_frame: ?*Frame,

    const Self = @This();

    /// Initialize a new compiler
    pub fn init(env: *environment.Environment, filename: ?[]const u8, allocator: std.mem.Allocator) Self {
        return Self{
            .environment = env,
            .filename = filename,
            .allocator = allocator,
            .frames = std.ArrayList(*Frame){},
            .current_frame = null,
        };
    }

    /// Deinitialize the compiler
    pub fn deinit(self: *Self) void {
        // Frames are managed by caller
        self.frames.deinit(self.allocator);
    }

    /// Compile a template AST
    pub fn compile(self: *Self, template: *nodes.Template, use_bytecode: bool) !CompiledTemplate {
        var bytecode: ?bytecode_mod.Bytecode = null;

        if (use_bytecode) {
            // Generate bytecode
            var generator = bytecode_mod.BytecodeGenerator.init(self.allocator);
            // NOTE: Don't defer deinit - ownership of bytecode transfers to CompiledTemplate
            // The bytecode will be freed when CompiledTemplate.deinit() is called

            const generated = try generator.generate(template);
            bytecode = generated;
        }

        return CompiledTemplate{
            .template = template,
            .environment = self.environment,
            .bytecode = bytecode,
            .allocator = self.allocator,
        };
    }

    /// Visit Template node
    pub fn visitTemplate(self: *Self, node: *nodes.Template, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Create template reference (self) and add to context
        // Use context's allocator since context owns and frees the template_ref
        const template_ref = try ctx.allocator.create(runtime.TemplateReference);
        errdefer ctx.allocator.destroy(template_ref);
        template_ref.* = runtime.TemplateReference.init(ctx.allocator, node, ctx, self);
        ctx.setTemplateRef(template_ref);

        // First, handle extends statements (must be at top level)
        // Process extends before other statements to set up block inheritance
        var extends_processed = false;
        var body_start_idx: usize = 0;

        for (node.body.items, 0..) |stmt, i| {
            if (stmt.tag == .extends) {
                if (extends_processed) {
                    // Multiple extends - error (Jinja2 allows only one at top level)
                    return exceptions.TemplateError.RuntimeError;
                }
                const extends_stmt = @as(*nodes.Extends, @ptrCast(@alignCast(stmt)));
                try self.visitExtends(extends_stmt, frame, ctx, node);
                extends_processed = true;
                body_start_idx = i + 1;
            }
        }

        // Register blocks from this template (child blocks override parent blocks)
        // Child blocks go at the front of the stack (index 0), parent blocks follow
        for (node.body.items[body_start_idx..]) |stmt| {
            if (stmt.tag == .block) {
                const block_stmt = @as(*nodes.Block, @ptrCast(@alignCast(stmt)));
                // Prepend child block to existing stack (or create new stack)
                const name_copy = try self.allocator.dupe(u8, block_stmt.name);
                errdefer self.allocator.free(name_copy);

                if (ctx.blocks.getPtr(block_stmt.name)) |existing_stack_ptr| {
                    // Prepend child block to existing stack
                    // Insert at index 0, shifting parent blocks to the right
                    try existing_stack_ptr.insert(self.allocator, 0, block_stmt);
                } else {
                    // Create new stack with just this block
                    var new_stack = std.ArrayList(*nodes.Block){};
                    try new_stack.append(self.allocator, block_stmt);
                    try ctx.blocks.put(name_copy, new_stack);
                }
            }
        }

        // Now process the template body
        // In Jinja2, when a template extends:
        // - Parent template's body (non-block statements) are NOT rendered
        // - Only blocks are inherited from parent
        // - Child template's body IS rendered
        // - Blocks in child override parent blocks
        // - If child doesn't define a block, parent's block is used when referenced
        var output = std.ArrayList(u8){};
        defer output.deinit(self.allocator);

        // Render child template's body (excluding extends which was already processed)
        for (node.body.items[body_start_idx..]) |stmt| {
            // Blocks are executed when encountered in body
            const stmt_output = try self.visitStatement(stmt, frame, ctx);
            defer self.allocator.free(stmt_output);
            try output.appendSlice(self.allocator, stmt_output);
        }

        return try output.toOwnedSlice(self.allocator);
    }

    /// Error set for visitor methods
    pub const VisitError = std.mem.Allocator.Error || exceptions.TemplateError || value_mod.CallError || error{ Overflow, InvalidCharacter, UndefinedError };

    /// Visit Statement node
    /// Uses type-safe dispatch based on statement tag
    pub fn visitStatement(self: *Self, stmt: *nodes.Stmt, frame: *Frame, ctx: *context.Context) VisitError![]const u8 {
        // Use switch statement for type-safe dispatch
        return switch (stmt.tag) {
            .output => {
                const output = @as(*nodes.Output, @ptrCast(@alignCast(stmt)));
                return try self.visitOutput(output, frame, ctx);
            },
            .comment => {
                // Comments produce no output
                return try self.allocator.dupe(u8, "");
            },
            .for_loop => {
                const for_stmt = @as(*nodes.For, @ptrCast(@alignCast(stmt)));
                return try self.visitFor(for_stmt, frame, ctx);
            },
            .if_stmt => {
                const if_stmt = @as(*nodes.If, @ptrCast(@alignCast(stmt)));
                return try self.visitIf(if_stmt, frame, ctx);
            },
            .continue_stmt => {
                const continue_stmt = @as(*nodes.ContinueStmt, @ptrCast(@alignCast(stmt)));
                return try self.visitContinue(continue_stmt, frame, ctx);
            },
            .break_stmt => {
                const break_stmt = @as(*nodes.BreakStmt, @ptrCast(@alignCast(stmt)));
                return try self.visitBreak(break_stmt, frame, ctx);
            },
            .macro => {
                const macro_stmt = @as(*nodes.Macro, @ptrCast(@alignCast(stmt)));
                return try self.visitMacro(macro_stmt, frame, ctx);
            },
            .call => {
                const call_stmt = @as(*nodes.Call, @ptrCast(@alignCast(stmt)));
                return try self.visitCall(call_stmt, frame, ctx);
            },
            .call_block => {
                const call_block_stmt = @as(*nodes.CallBlock, @ptrCast(@alignCast(stmt)));
                return try self.visitCallBlock(call_block_stmt, frame, ctx);
            },
            .set => {
                const set_stmt = @as(*nodes.Set, @ptrCast(@alignCast(stmt)));
                return try self.visitSet(set_stmt, frame, ctx);
            },
            .with => {
                const with_stmt = @as(*nodes.With, @ptrCast(@alignCast(stmt)));
                return try self.visitWith(with_stmt, frame, ctx);
            },
            .filter_block => {
                const filter_block_stmt = @as(*nodes.FilterBlock, @ptrCast(@alignCast(stmt)));
                return try self.visitFilterBlock(filter_block_stmt, frame, ctx);
            },
            .autoescape => {
                const autoescape_stmt = @as(*nodes.Autoescape, @ptrCast(@alignCast(stmt)));
                return try self.visitAutoescape(autoescape_stmt, frame, ctx);
            },
            .block => {
                const block_stmt = @as(*nodes.Block, @ptrCast(@alignCast(stmt)));
                return try self.visitBlock(block_stmt, frame, ctx);
            },
            .extends => {
                // Extends should be handled in visitTemplate, but handle here as fallback
                return try self.allocator.dupe(u8, "");
            },
            .include => {
                const include_stmt = @as(*nodes.Include, @ptrCast(@alignCast(stmt)));
                return try self.visitInclude(include_stmt, frame, ctx);
            },
            .import => {
                const import_stmt = @as(*nodes.Import, @ptrCast(@alignCast(stmt)));
                return try self.visitImport(import_stmt, frame, ctx);
            },
            .from_import => {
                const from_import_stmt = @as(*nodes.FromImport, @ptrCast(@alignCast(stmt)));
                return try self.visitFromImport(from_import_stmt, frame, ctx);
            },
            .expr_stmt => {
                const expr_stmt = @as(*nodes.ExprStmt, @ptrCast(@alignCast(stmt)));
                return try self.visitExprStmt(expr_stmt, frame, ctx);
            },
            .debug_stmt => {
                const debug_stmt = @as(*nodes.DebugStmt, @ptrCast(@alignCast(stmt)));
                return try self.visitDebugStmt(debug_stmt, frame, ctx);
            },
        };
    }

    /// Visit Output node
    pub fn visitOutput(self: *Self, node: *nodes.Output, frame: *Frame, ctx: *context.Context) ![]const u8 {
        var output = std.ArrayList(u8){};
        defer output.deinit(self.allocator);

        // Check if autoescaping is enabled for this frame
        const template_name = if (node.base.base.filename) |f| f else null;
        const should_escape = frame.getAutoescape(self.environment, template_name);

        // Handle content first (plain text)
        if (node.content.len > 0) {
            try output.appendSlice(self.allocator, node.content);
        }

        // Then evaluate expressions and convert to string
        // Note: After optimization, an Output node can have both content AND expressions
        for (node.nodes.items) |*expr| {
            var expr_value = try self.visitExpression(expr, frame, ctx);
            defer expr_value.deinit(self.allocator);

            // Apply finalize callback if set - this allows transforming the value
            // before output (e.g., converting null to empty string)
            // Note: finalize returns a potentially new Value that we need to use
            const value_to_output = self.environment.applyFinalize(expr_value);

            // Apply autoescaping if enabled and value is not already escaped
            if (should_escape and !value_to_output.isEscaped()) {
                var escaped_value = try value_to_output.escape(self.allocator);
                defer escaped_value.deinit(self.allocator);
                const expr_str = try escaped_value.toString(self.allocator);
                defer self.allocator.free(expr_str);
                try output.appendSlice(self.allocator, expr_str);
            } else {
                const expr_str = try value_to_output.toString(self.allocator);
                defer self.allocator.free(expr_str);
                try output.appendSlice(self.allocator, expr_str);
            }
        }

        return try output.toOwnedSlice(self.allocator);
    }

    /// Visit Expression node
    /// Returns Value type
    pub fn visitExpression(self: *Self, expr: *nodes.Expression, frame: *Frame, ctx: *context.Context) (exceptions.TemplateError || std.mem.Allocator.Error || value_mod.CallError || error{ Overflow, InvalidCharacter })!value_mod.Value {
        return switch (expr.*) {
            .string_literal => |lit| try self.visitStringLiteral(lit, frame, ctx),
            .integer_literal => |lit| try self.visitIntegerLiteral(lit, frame, ctx),
            .float_literal => |lit| try self.visitFloatLiteral(lit, frame, ctx),
            .boolean_literal => |lit| try self.visitBooleanLiteral(lit, frame, ctx),
            .null_literal => |lit| try self.visitNullLiteral(lit, frame, ctx),
            .list_literal => |lit| try self.visitListLiteral(lit, frame, ctx),
            .name => |name| try self.visitName(name, frame, ctx),
            .bin_expr => |bin| try self.visitBinExpr(bin, frame, ctx),
            .unary_expr => |unary| try self.visitUnaryExpr(unary, frame, ctx),
            .filter => |filter| try self.visitFilter(filter, frame, ctx),
            .getattr => |getattr| try self.visitGetattr(getattr, frame, ctx),
            .getitem => |getitem| try self.visitGetitem(getitem, frame, ctx),
            .test_expr => |test_node| try self.visitTest(test_node, frame, ctx),
            .cond_expr => |cond| try self.visitCondExpr(cond, frame, ctx),
            .call_expr => |call| try self.visitCallExpr(call, frame, ctx),
            .nsref => |nsref| try self.visitNSRef(nsref, frame, ctx),
            .slice => |slice| try self.visitSlice(slice, frame, ctx),
            .concat => |concat| try self.visitConcat(concat, frame, ctx),
            .environment_attribute => |env_attr| try self.visitEnvironmentAttribute(env_attr, frame, ctx),
            .extension_attribute => |ext_attr| try self.visitExtensionAttribute(ext_attr, frame, ctx),
            .imported_name => |imported| try self.visitImportedName(imported, frame, ctx),
            .internal_name => |internal| try self.visitInternalName(internal, frame, ctx),
            .context_reference => |ctx_ref| try self.visitContextReference(ctx_ref, frame, ctx),
            .derived_context_reference => |derived_ctx_ref| try self.visitDerivedContextReference(derived_ctx_ref, frame, ctx),
        };
    }

    /// Visit Filter node - apply filter to expression
    /// Optimized hot path for filter execution
    pub fn visitFilter(self: *Self, node: *nodes.FilterExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // Evaluate base expression
        var base_val = try self.visitExpression(&node.node, frame, ctx);
        defer base_val.deinit(self.allocator);

        // Optimize: use stack-allocated array for small argument counts
        // For larger counts, fall back to ArrayList
        const max_stack_args = 8;
        var stack_args: [max_stack_args]value_mod.Value = undefined;
        var args: []value_mod.Value = undefined;
        var args_allocated = false;

        if (node.args.items.len <= max_stack_args) {
            // Use stack-allocated array
            args = stack_args[0..node.args.items.len];
            for (node.args.items, 0..) |*arg_expr, i| {
                args[i] = try self.visitExpression(arg_expr, frame, ctx);
            }
        } else {
            // Use ArrayList for larger argument lists
            var args_list = std.ArrayList(value_mod.Value).empty;
            defer {
                for (args_list.items) |*arg| {
                    arg.deinit(self.allocator);
                }
                args_list.deinit(self.allocator);
            }
            for (node.args.items) |*arg_expr| {
                const arg_val = try self.visitExpression(arg_expr, frame, ctx);
                try args_list.append(self.allocator, arg_val);
            }
            args = args_list.items;
            args_allocated = true;
        }

        // Get filter from environment
        const filter = self.environment.getFilter(node.name) orelse {
            // Clean up stack-allocated args if used
            if (!args_allocated) {
                for (args) |*arg| {
                    arg.deinit(self.allocator);
                }
            }
            return exceptions.TemplateError.RuntimeError;
        };

        // Check if async should be used
        const use_async = self.environment.enable_async and filter.is_async;

        // Apply filter (async or sync)
        const result = if (use_async) blk: {
            // Use async filter function if available
            if (filter.async_func) |async_func| {
                break :blk try async_func(
                    self.allocator,
                    base_val,
                    args,
                    ctx,
                    self.environment,
                );
            } else {
                // Fall back to sync function if async not available
                break :blk try filter.func(
                    self.allocator,
                    base_val,
                    args,
                    ctx,
                    self.environment,
                );
            }
        } else blk: {
            // Use sync filter function
            break :blk try filter.func(
                self.allocator,
                base_val,
                args,
                ctx,
                self.environment,
            );
        };

        // Clean up stack-allocated args if used
        if (!args_allocated) {
            for (args) |*arg| {
                arg.deinit(self.allocator);
            }
        }

        return result;
    }

    /// Visit Name node - resolve variable from context
    /// Returns a DEEP COPY of the value - caller owns the returned value
    /// Optimized hot path for variable resolution
    pub inline fn visitName(self: *Self, node: *nodes.Name, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // Resolve variable from frame first
        if (frame.resolve(node.name)) |val| {
            // Return deep copy - caller owns it
            return try val.deepCopy(self.allocator);
        }

        // Then check context (this now returns undefined if not found)
        const val = ctx.resolve(node.name);

        // Handle undefined based on behavior
        if (val == .undefined) {
            return switch (val.undefined.behavior) {
                .strict => exceptions.TemplateError.UndefinedError,
                .lenient => value_mod.Value{ .string = try self.allocator.dupe(u8, "") },
                .debug => value_mod.Value{ .string = try std.fmt.allocPrint(self.allocator, "{{ undefined variable '{s}' }}", .{node.name}) },
                .chainable => try val.deepCopy(self.allocator), // Return copy of undefined for chaining
            };
        }

        // Return deep copy - caller owns it
        return try val.deepCopy(self.allocator);
    }

    /// Visit Getattr node - access object attribute (obj.attr)
    pub fn visitGetattr(self: *Self, node: *nodes.Getattr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // OPTIMIZATION: Fast path for loop.* attribute access
        // When accessing loop.index, loop.first, etc., resolve directly from OptimizedLoopContext
        // without creating a Dict or evaluating the object expression
        if (node.node == .name) {
            if (std.mem.eql(u8, node.node.name.name, "loop")) {
                if (frame.resolveLoopAttr(node.attr)) |val| {
                    // Loop attributes are simple values (int/bool), no need to copy
                    return val;
                }
            }
        }

        // Evaluate the object expression
        var obj_val = try self.visitExpression(&node.node, frame, ctx);
        defer obj_val.deinit(self.allocator);

        // Check sandbox security if enabled
        if (self.environment.sandboxed) {
            const sandbox_mod = @import("sandbox.zig");
            if (!sandbox_mod.isSafeAttribute(obj_val, node.attr)) {
                return exceptions.TemplateError.SecurityError;
            }
        }

        // Handle undefined objects with chainable behavior
        if (obj_val == .undefined) {
            const u = obj_val.undefined;
            // Log access if logger is set
            u.logAccess("getAttribute");

            // Chainable mode returns undefined for chained access
            if (u.behavior == .chainable) {
                const name_copy = try self.allocator.dupe(u8, node.attr);
                return value_mod.Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = .chainable,
                    .logger = u.logger,
                } };
            }
            // Strict mode raises error
            if (u.behavior == .strict) {
                return exceptions.TemplateError.UndefinedError;
            }
            // Other modes return undefined
            const name_copy = try self.allocator.dupe(u8, node.attr);
            return value_mod.Value{ .undefined = value_mod.Undefined{
                .name = name_copy,
                .behavior = u.behavior,
                .logger = u.logger,
            } };
        }

        // Access attribute based on object type
        return switch (obj_val) {
            .dict => |d| {
                // For dicts, access by key
                if (d.get(node.attr)) |val| {
                    // Return a deep copy of the value
                    return try val.deepCopy(self.allocator);
                }
                // Key not found - return undefined based on policy
                const undefined_policy = self.environment.undefined_behavior;
                const name_copy = try self.allocator.dupe(u8, node.attr);
                return value_mod.Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = undefined_policy,
                } };
            },
            .list => {
                // Lists don't have attributes
                return exceptions.TemplateError.AttributeError;
            },
            .string, .integer, .float, .boolean, .null => {
                // Primitive types don't have attributes
                return exceptions.TemplateError.AttributeError;
            },
            .undefined => |u| {
                // Log access if logger is set
                u.logAccess("getAttribute");

                // Chainable mode returns undefined for chained access
                if (u.behavior == .chainable) {
                    const name_copy = try self.allocator.dupe(u8, node.attr);
                    return value_mod.Value{ .undefined = value_mod.Undefined{
                        .name = name_copy,
                        .behavior = .chainable,
                        .logger = u.logger,
                    } };
                }
                // Strict mode raises error
                if (u.behavior == .strict) {
                    return exceptions.TemplateError.UndefinedError;
                }
                // Other modes return undefined
                const name_copy = try self.allocator.dupe(u8, node.attr);
                return value_mod.Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = u.behavior,
                    .logger = u.logger,
                } };
            },
            .markup => {
                // Markup type doesn't have user-accessible attributes
                return exceptions.TemplateError.AttributeError;
            },
            .async_result => {
                // Async results don't expose attributes directly
                return exceptions.TemplateError.AttributeError;
            },
            .callable => {
                // Callable doesn't have attributes
                return exceptions.TemplateError.AttributeError;
            },
            .custom => |custom| {
                // Access field on custom object
                if (try custom.getField(node.attr, self.allocator)) |field_val| {
                    return field_val;
                }
                // Try to get method as a callable
                if (try custom.getMethod(node.attr, self.allocator)) |method_fn| {
                    const callable = try self.allocator.create(value_mod.Callable);
                    callable.* = value_mod.Callable{
                        .name = try self.allocator.dupe(u8, node.attr),
                        .is_async = false,
                        .callable_type = .function,
                        .func = method_fn,
                    };
                    return value_mod.Value{ .callable = callable };
                }
                // Field/method not found - return undefined based on policy
                const undefined_policy = self.environment.undefined_behavior;
                const name_copy = try self.allocator.dupe(u8, node.attr);
                return value_mod.Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = undefined_policy,
                } };
            },
        };
    }

    /// Visit Getitem node - access list/dict item (obj[index]) or slice (obj[start:stop:step])
    pub fn visitGetitem(self: *Self, node: *nodes.Getitem, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // Evaluate the object expression
        var obj_val = try self.visitExpression(&node.node, frame, ctx);
        defer obj_val.deinit(self.allocator);

        // Check if this is a slice expression
        if (node.arg == .slice) {
            return try self.evaluateSlice(obj_val, node.arg.slice, frame, ctx);
        }

        // Evaluate the index/key expression
        var index_val = try self.visitExpression(&node.arg, frame, ctx);
        defer index_val.deinit(self.allocator);

        // Handle undefined objects with chainable behavior
        if (obj_val == .undefined) {
            const u = obj_val.undefined;
            // Log access if logger is set
            u.logAccess("getItem");

            // Chainable mode returns undefined for chained access
            if (u.behavior == .chainable) {
                const name_copy = try self.allocator.dupe(u8, "item");
                return value_mod.Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = .chainable,
                    .logger = u.logger,
                } };
            }
            // Strict mode raises error
            if (u.behavior == .strict) {
                return exceptions.TemplateError.UndefinedError;
            }
            // Other modes return undefined
            const name_copy = try self.allocator.dupe(u8, "item");
            return value_mod.Value{ .undefined = value_mod.Undefined{
                .name = name_copy,
                .behavior = u.behavior,
                .logger = u.logger,
            } };
        }

        // Access item based on object type
        return switch (obj_val) {
            .list => |l| {
                // For lists, index must be integer
                const index_int = index_val.toInteger() orelse return exceptions.TemplateError.TypeError;
                const len: i64 = @intCast(l.items.items.len);
                // Handle negative indices (Python-style)
                var actual_idx = index_int;
                if (actual_idx < 0) {
                    actual_idx = len + actual_idx;
                }
                if (actual_idx < 0 or actual_idx >= len) {
                    return exceptions.TemplateError.IndexError;
                }
                const item = l.items.items[@intCast(actual_idx)];
                // Return a deep copy of the value
                return try item.deepCopy(self.allocator);
            },
            .dict => |d| {
                // For dicts, index must be string
                const index_str = index_val.toString(self.allocator) catch return exceptions.TemplateError.TypeError;
                defer self.allocator.free(index_str);

                if (d.get(index_str)) |val| {
                    // Return a deep copy of the value
                    return try val.deepCopy(self.allocator);
                }
                // Key not found - return undefined based on policy
                const undefined_policy = self.environment.undefined_behavior;
                const name_copy = try self.allocator.dupe(u8, index_str);
                return value_mod.Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = undefined_policy,
                } };
            },
            .string => |s| {
                // For strings, index must be integer
                const index_int = index_val.toInteger() orelse return exceptions.TemplateError.TypeError;
                const len: i64 = @intCast(s.len);
                // Handle negative indices (Python-style)
                var actual_idx = index_int;
                if (actual_idx < 0) {
                    actual_idx = len + actual_idx;
                }
                if (actual_idx < 0 or actual_idx >= len) {
                    return exceptions.TemplateError.IndexError;
                }
                const char = s[@intCast(actual_idx)];
                const char_str = try std.fmt.allocPrint(self.allocator, "{c}", .{char});
                return value_mod.Value{ .string = char_str };
            },
            .integer, .float, .boolean, .null, .undefined => {
                // Primitive types don't support indexing
                return exceptions.TemplateError.TypeError;
            },
            .markup => {
                // Markup types don't support indexing
                return exceptions.TemplateError.TypeError;
            },
            .async_result => {
                // Async results don't support direct indexing
                return exceptions.TemplateError.TypeError;
            },
            .callable => {
                // Callables don't support indexing
                return exceptions.TemplateError.TypeError;
            },
            .custom => |custom| {
                // Custom objects can implement subscript access via getItem
                if (try custom.getItem(index_val, self.allocator)) |item_val| {
                    return item_val;
                }
                // getItem returned null - item not found or not supported
                const undefined_policy = self.environment.undefined_behavior;
                const name_copy = try self.allocator.dupe(u8, "item");
                return value_mod.Value{ .undefined = value_mod.Undefined{
                    .name = name_copy,
                    .behavior = undefined_policy,
                } };
            },
        };
    }

    /// Evaluate slice expression on a value
    /// Handles [start:stop:step] syntax like Python
    fn evaluateSlice(self: *Self, obj: value_mod.Value, slice: *nodes.Slice, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // Get start, stop, step values (evaluate if present)
        var start_val: ?i64 = null;
        var stop_val: ?i64 = null;
        var step_val: i64 = 1;

        if (slice.start) |start_expr| {
            var start_copy = start_expr;
            const val = try self.visitExpression(&start_copy, frame, ctx);
            defer val.deinit(self.allocator);
            start_val = val.toInteger();
        }

        if (slice.stop) |stop_expr| {
            var stop_copy = stop_expr;
            const val = try self.visitExpression(&stop_copy, frame, ctx);
            defer val.deinit(self.allocator);
            stop_val = val.toInteger();
        }

        if (slice.step) |step_expr| {
            var step_copy = step_expr;
            const val = try self.visitExpression(&step_copy, frame, ctx);
            defer val.deinit(self.allocator);
            step_val = val.toInteger() orelse 1;
            if (step_val == 0) {
                return exceptions.TemplateError.RuntimeError; // step cannot be zero
            }
        }

        // Apply slice based on object type
        return switch (obj) {
            .list => |l| try self.sliceList(l, start_val, stop_val, step_val),
            .string => |s| try self.sliceString(s, start_val, stop_val, step_val),
            else => exceptions.TemplateError.TypeError,
        };
    }

    /// Slice a list value
    fn sliceList(self: *Self, list: *value_mod.List, start: ?i64, stop: ?i64, step: i64) !value_mod.Value {
        const len: i64 = @intCast(list.items.items.len);

        // Resolve slice bounds (Python-style)
        var actual_start: i64 = undefined;
        var actual_stop: i64 = undefined;

        if (step > 0) {
            // Forward slice
            actual_start = if (start) |s| normalizeIndex(s, len) else 0;
            actual_stop = if (stop) |s| normalizeIndex(s, len) else len;
            // Clamp values
            actual_start = @max(0, @min(actual_start, len));
            actual_stop = @max(0, @min(actual_stop, len));
        } else {
            // Backward slice
            actual_start = if (start) |s| normalizeIndex(s, len) else len - 1;
            actual_stop = if (stop) |s| normalizeIndex(s, len) else -1;
            // For negative step, start defaults to len-1, stop defaults to -1 (meaning beginning)
            actual_start = @max(-1, @min(actual_start, len - 1));
            actual_stop = @max(-1, @min(actual_stop, len));
        }

        // Create result list
        const result_list = try self.allocator.create(value_mod.List);
        result_list.* = value_mod.List.init(self.allocator);
        errdefer {
            result_list.deinit(self.allocator);
            self.allocator.destroy(result_list);
        }

        // Collect items according to slice
        var i = actual_start;
        if (step > 0) {
            while (i < actual_stop) : (i += step) {
                if (i >= 0 and i < len) {
                    const item = list.items.items[@intCast(i)];
                    const copied = try item.deepCopy(self.allocator);
                    try result_list.append(copied);
                }
            }
        } else {
            while (i > actual_stop) : (i += step) {
                if (i >= 0 and i < len) {
                    const item = list.items.items[@intCast(i)];
                    const copied = try item.deepCopy(self.allocator);
                    try result_list.append(copied);
                }
            }
        }

        return value_mod.Value{ .list = result_list };
    }

    /// Slice a string value
    fn sliceString(self: *Self, str: []const u8, start: ?i64, stop: ?i64, step: i64) !value_mod.Value {
        const len: i64 = @intCast(str.len);

        // Resolve slice bounds (Python-style)
        var actual_start: i64 = undefined;
        var actual_stop: i64 = undefined;

        if (step > 0) {
            actual_start = if (start) |s| normalizeIndex(s, len) else 0;
            actual_stop = if (stop) |s| normalizeIndex(s, len) else len;
            actual_start = @max(0, @min(actual_start, len));
            actual_stop = @max(0, @min(actual_stop, len));
        } else {
            actual_start = if (start) |s| normalizeIndex(s, len) else len - 1;
            actual_stop = if (stop) |s| normalizeIndex(s, len) else -1;
            actual_start = @max(-1, @min(actual_start, len - 1));
            actual_stop = @max(-1, @min(actual_stop, len));
        }

        // Build result string
        var result = std.ArrayList(u8){};
        errdefer result.deinit(self.allocator);

        var i = actual_start;
        if (step > 0) {
            while (i < actual_stop) : (i += step) {
                if (i >= 0 and i < len) {
                    try result.append(self.allocator, str[@intCast(i)]);
                }
            }
        } else {
            while (i > actual_stop) : (i += step) {
                if (i >= 0 and i < len) {
                    try result.append(self.allocator, str[@intCast(i)]);
                }
            }
        }

        return value_mod.Value{ .string = try result.toOwnedSlice(self.allocator) };
    }

    /// Visit BinExpr node - evaluate binary expression
    pub fn visitBinExpr(self: *Self, node: *nodes.BinExpr, frame: *Frame, ctx: *context.Context) (exceptions.TemplateError || std.mem.Allocator.Error || value_mod.CallError || error{ Overflow, InvalidCharacter })!value_mod.Value {
        var left_val = try self.visitExpression(&node.left, frame, ctx);
        defer left_val.deinit(self.allocator);

        var right_val = try self.visitExpression(&node.right, frame, ctx);
        defer right_val.deinit(self.allocator);
        // Check for 'not in' - if left is a unary NOT with IN, handle specially
        // Actually, we handle 'not in' by checking if the left expression is a unary NOT
        // For now, we'll handle IN and check for negation in a different way
        // The parser creates a BinExpr with IN, and we need to check if it was negated
        // Let's handle it in the parser by creating a special marker, or handle it here

        return switch (node.op) {
            .ADD => try self.evalAdd(left_val, right_val),
            .SUB => try self.evalSub(left_val, right_val),
            .MUL => try self.evalMul(left_val, right_val),
            .DIV => try self.evalDiv(left_val, right_val),
            .MOD => try self.evalMod(left_val, right_val),
            .FLOORDIV => try self.evalFloorDiv(left_val, right_val),
            .POW => try self.evalPow(left_val, right_val),
            .EQ => try self.evalEq(left_val, right_val),
            .NE => try self.evalNe(left_val, right_val),
            .LT => try self.evalLt(left_val, right_val),
            .LTEQ => try self.evalLte(left_val, right_val),
            .GT => try self.evalGt(left_val, right_val),
            .GTEQ => try self.evalGte(left_val, right_val),
            .AND => try self.evalAnd(left_val, right_val),
            .OR => try self.evalOr(left_val, right_val),
            .IN => {
                const in_result = try self.evalIn(left_val, right_val);
                // Check if this was 'not in' - we need a better way to track this
                // For now, we'll handle 'not in' by checking the left expression
                // Actually, let's handle 'not in' properly in the parser
                return in_result;
            },
            else => {
                // Unknown operator - return empty string
                return value_mod.Value{ .string = try self.allocator.dupe(u8, "") };
            },
        };
    }

    /// Visit TestExpr node - evaluate test expression (value is test)
    pub fn visitTest(self: *Self, node: *nodes.TestExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // Evaluate the expression to test
        var val = try self.visitExpression(&node.node, frame, ctx);
        defer val.deinit(self.allocator);

        // Evaluate test arguments
        var args = std.ArrayList(value_mod.Value){};
        defer {
            for (args.items) |*arg| {
                arg.deinit(self.allocator);
            }
            args.deinit(self.allocator);
        }

        for (node.args.items) |*arg_expr| {
            const arg_val = try self.visitExpression(arg_expr, frame, ctx);
            try args.append(self.allocator, arg_val);
        }

        // Look up test function from environment
        const test_func = self.environment.getTest(node.name) orelse {
            return exceptions.TemplateError.RuntimeError;
        };

        // Check if async should be used
        const use_async = self.environment.enable_async and test_func.is_async;

        // Determine which arguments to pass based on pass_arg setting
        const env_to_pass = switch (test_func.pass_arg) {
            .environment => self.environment,
            else => null,
        };
        const ctx_to_pass = switch (test_func.pass_arg) {
            .context => ctx,
            else => ctx, // Always pass context for now
        };

        // Call test function (async or sync)
        const result = if (use_async) blk: {
            // Use async test function if available
            if (test_func.async_func) |async_func| {
                // In Zig, async functions return async frames that must be awaited
                // For now, we'll call the async function directly
                // In a full async implementation, this would be awaited
                break :blk async_func(val, args.items, ctx_to_pass, env_to_pass);
            } else {
                // Fall back to sync function if async not available
                break :blk test_func.func(val, args.items, ctx_to_pass, env_to_pass);
            }
        } else test_func.func(val, args.items, ctx_to_pass, env_to_pass);

        return value_pool.getBool(result);
    }

    /// Visit CondExpr node - evaluate conditional expression (x if y else z)
    pub fn visitCondExpr(self: *Self, node: *nodes.CondExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // Evaluate condition
        var condition_val = try self.visitExpression(&node.condition, frame, ctx);
        defer condition_val.deinit(self.allocator);

        // Return true branch if condition is truthy, else false branch
        if (try condition_val.isTruthy()) {
            return try self.visitExpression(&node.true_expr, frame, ctx);
        } else {
            return try self.visitExpression(&node.false_expr, frame, ctx);
        }
    }

    /// Visit ContinueStmt node - continue loop iteration
    pub fn visitContinue(_: *Self, node: *nodes.ContinueStmt, frame: *Frame, ctx: *context.Context) ![]const u8 {
        _ = node;
        _ = ctx;

        // Check if we're in a loop (either old-style or optimized)
        if (frame.loop == null and frame.getOptLoop() == null) {
            return exceptions.TemplateError.RuntimeError;
        }

        // Throw continue error to be caught by loop handler
        return exceptions.TemplateError.ContinueError;
    }

    /// Visit BreakStmt node - break out of loop
    pub fn visitBreak(_: *Self, node: *nodes.BreakStmt, frame: *Frame, ctx: *context.Context) ![]const u8 {
        _ = node;
        _ = ctx;

        // Check if we're in a loop (either old-style or optimized)
        if (frame.loop == null and frame.getOptLoop() == null) {
            return exceptions.TemplateError.RuntimeError;
        }

        // Throw break error to be caught by loop handler
        return exceptions.TemplateError.BreakError;
    }

    /// Evaluate 'in' operator
    fn evalIn(self: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        // Check if left value is in right value (list, dict, or string)
        return switch (right) {
            .list => |l| {
                // Check if left is in list
                for (l.items.items) |item| {
                    if (try left.isEqual(item)) {
                        return value_pool.getTrue();
                    }
                }
                return value_pool.getFalse();
            },
            .dict => |d| {
                // For dicts, check if left is a key
                const left_str = left.toString(self.allocator) catch return exceptions.TemplateError.TypeError;
                defer self.allocator.free(left_str);
                return value_pool.getBool(d.map.contains(left_str));
            },
            .string => |s| {
                // Check if left string is substring of right string
                const left_str = left.toString(self.allocator) catch return exceptions.TemplateError.TypeError;
                defer self.allocator.free(left_str);
                return value_pool.getBool(std.mem.indexOf(u8, s, left_str) != null);
            },
            else => {
                return exceptions.TemplateError.TypeError;
            },
        };
    }

    /// Visit UnaryExpr node - evaluate unary expression
    pub fn visitUnaryExpr(self: *Self, node: *nodes.UnaryExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // Create a mutable copy to avoid const issues
        var node_expr = node.node;
        var expr_val = try self.visitExpression(&node_expr, frame, ctx);
        defer expr_val.deinit(self.allocator);
        return switch (node.op) {
            .ADD => expr_val, // Unary plus - no change
            .SUB => try self.evalUnarySub(expr_val),
            .TILDE => try self.evalUnaryTilde(expr_val),
            .NOT => try self.evalUnaryNot(expr_val),
            else => expr_val,
        };
    }

    /// Visit StringLiteral node
    pub fn visitStringLiteral(self: *Self, node: *nodes.StringLiteral, _: *Frame, _: *context.Context) !value_mod.Value {
        return value_mod.Value{ .string = try self.allocator.dupe(u8, node.value) };
    }

    /// Visit IntegerLiteral node
    pub fn visitIntegerLiteral(_: *Self, node: *nodes.IntegerLiteral, _: *Frame, _: *context.Context) !value_mod.Value {
        return value_mod.Value{ .integer = node.value };
    }

    /// Visit FloatLiteral node
    pub fn visitFloatLiteral(_: *Self, node: *nodes.FloatLiteral, _: *Frame, _: *context.Context) !value_mod.Value {
        return value_mod.Value{ .float = node.value };
    }

    /// Visit BooleanLiteral node
    pub fn visitBooleanLiteral(_: *Self, node: *nodes.BooleanLiteral, _: *Frame, _: *context.Context) !value_mod.Value {
        return value_pool.getBool(node.value);
    }

    /// Visit NullLiteral node
    pub fn visitNullLiteral(_: *Self, _: *nodes.NullLiteral, _: *Frame, _: *context.Context) !value_mod.Value {
        return value_mod.Value{ .null = {} };
    }

    /// Visit ListLiteral node
    pub fn visitListLiteral(self: *Self, node: *nodes.ListLiteral, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        const list_ptr = try self.allocator.create(value_mod.List);
        list_ptr.* = value_mod.List.init(self.allocator);
        errdefer {
            list_ptr.deinit(self.allocator);
            self.allocator.destroy(list_ptr);
        }

        for (node.elements.items) |*elem| {
            const val = try self.visitExpression(elem, frame, ctx);
            try list_ptr.append(val);
        }

        return value_mod.Value{ .list = list_ptr };
    }

    /// Push a new frame onto the stack
    pub fn pushFrame(self: *Self, frame: *Frame) !void {
        try self.frames.append(self.allocator, frame);
        self.current_frame = frame;
    }

    /// Pop a frame from the stack
    pub fn popFrame(self: *Self) void {
        _ = self.frames.popOrNull();
        self.current_frame = if (self.frames.items.len > 0) self.frames.items[self.frames.items.len - 1] else null;
    }

    // Binary expression evaluation methods
    fn evalAdd(self: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        // Check actual types to preserve float vs integer distinction
        // If either operand is a float, the result should be a float
        const left_is_float = left == .float;
        const right_is_float = right == .float;
        const left_is_int = left == .integer;
        const right_is_int = right == .integer;

        // Both integers -> integer result
        if (left_is_int and right_is_int) {
            return value_mod.Value{ .integer = left.integer + right.integer };
        }

        // Any float involved -> float result
        if (left_is_float or right_is_float or left_is_int or right_is_int) {
            const left_float = left.toFloat();
            const right_float = right.toFloat();
            if (left_float != null and right_float != null) {
                return value_mod.Value{ .float = left_float.? + right_float.? };
            }
        }

        // String concatenation (handles string + number, number + string, string + string)
        const left_str = try left.toString(self.allocator);
        defer self.allocator.free(left_str);
        const right_str = try right.toString(self.allocator);
        defer self.allocator.free(right_str);
        var result = std.ArrayList(u8){};
        defer result.deinit(self.allocator);
        try result.appendSlice(self.allocator, left_str);
        try result.appendSlice(self.allocator, right_str);
        return value_mod.Value{ .string = try result.toOwnedSlice(self.allocator) };
    }

    fn evalSub(_: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        // Check actual types to preserve float vs integer distinction
        const left_is_float = left == .float;
        const right_is_float = right == .float;
        const left_is_int = left == .integer;
        const right_is_int = right == .integer;

        // Both integers -> integer result
        if (left_is_int and right_is_int) {
            return value_mod.Value{ .integer = left.integer - right.integer };
        }

        // Any float involved -> float result
        if (left_is_float or right_is_float or left_is_int or right_is_int) {
            const left_float = left.toFloat();
            const right_float = right.toFloat();
            if (left_float != null and right_float != null) {
                return value_mod.Value{ .float = left_float.? - right_float.? };
            }
        }

        return exceptions.TemplateError.TypeError;
    }

    fn evalMul(_: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        // Check actual types to preserve float vs integer distinction
        const left_is_float = left == .float;
        const right_is_float = right == .float;
        const left_is_int = left == .integer;
        const right_is_int = right == .integer;

        // Both integers -> integer result
        if (left_is_int and right_is_int) {
            return value_mod.Value{ .integer = left.integer * right.integer };
        }

        // Any float involved -> float result
        if (left_is_float or right_is_float or left_is_int or right_is_int) {
            const left_float = left.toFloat();
            const right_float = right.toFloat();
            if (left_float != null and right_float != null) {
                return value_mod.Value{ .float = left_float.? * right_float.? };
            }
        }

        return exceptions.TemplateError.TypeError;
    }

    fn evalDiv(_: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        const left_float = left.toFloat();
        const right_float = right.toFloat();
        if (left_float != null and right_float != null) {
            if (right_float.? == 0.0) {
                return exceptions.TemplateError.DivisionByZero;
            }
            return value_mod.Value{ .float = left_float.? / right_float.? };
        }
        const left_int = left.toInteger();
        const right_int = right.toInteger();
        if (left_int != null and right_int != null) {
            if (right_int.? == 0) {
                return exceptions.TemplateError.DivisionByZero;
            }
            return value_mod.Value{ .float = @as(f64, @floatFromInt(left_int.?)) / @as(f64, @floatFromInt(right_int.?)) };
        }
        return exceptions.TemplateError.TypeError;
    }

    fn evalMod(_: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        const left_int = left.toInteger();
        const right_int = right.toInteger();
        if (left_int != null and right_int != null) {
            if (right_int.? == 0) {
                return exceptions.TemplateError.DivisionByZero;
            }
            return value_mod.Value{ .integer = @rem(left_int.?, right_int.?) };
        }
        return exceptions.TemplateError.TypeError;
    }

    fn evalFloorDiv(_: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        const left_int = left.toInteger();
        const right_int = right.toInteger();
        if (left_int != null and right_int != null) {
            if (right_int.? == 0) {
                return exceptions.TemplateError.DivisionByZero;
            }
            return value_mod.Value{ .integer = @divTrunc(left_int.?, right_int.?) };
        }
        const left_float = left.toFloat();
        const right_float = right.toFloat();
        if (left_float != null and right_float != null) {
            if (right_float.? == 0.0) {
                return exceptions.TemplateError.DivisionByZero;
            }
            return value_mod.Value{ .integer = @intFromFloat(@floor(left_float.? / right_float.?)) };
        }
        return exceptions.TemplateError.TypeError;
    }

    fn evalPow(_: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        // Power operation always uses float for precision
        const left_float = left.toFloat();
        const right_float = right.toFloat();
        if (left_float != null and right_float != null) {
            return value_mod.Value{ .float = std.math.pow(f64, left_float.?, right_float.?) };
        }
        // Convert integers to floats for power operation
        const left_int = left.toInteger();
        const right_int = right.toInteger();
        if (left_int != null and right_int != null) {
            // For integer power with integer exponent, try integer result first
            if (right_int.? >= 0 and right_int.? < 64) {
                // std.math.powi can overflow, catch and use float instead
                if (std.math.powi(i64, left_int.?, @intCast(right_int.?))) |result| {
                    return value_mod.Value{ .integer = result };
                } else |_| {
                    // Overflow - use float
                    return value_mod.Value{ .float = std.math.pow(f64, @as(f64, @floatFromInt(left_int.?)), @as(f64, @floatFromInt(right_int.?))) };
                }
            }
            // Otherwise use float
            return value_mod.Value{ .float = std.math.pow(f64, @as(f64, @floatFromInt(left_int.?)), @as(f64, @floatFromInt(right_int.?))) };
        }
        // Mixed int/float
        const left_val = if (left_float) |f| f else if (left_int) |i| @as(f64, @floatFromInt(i)) else return exceptions.TemplateError.TypeError;
        const right_val = if (right_float) |f| f else if (right_int) |i| @as(f64, @floatFromInt(i)) else return exceptions.TemplateError.TypeError;
        return value_mod.Value{ .float = std.math.pow(f64, left_val, right_val) };
    }

    fn evalEq(self: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        _ = self;
        // Use proper value comparison
        return value_pool.getBool(try left.isEqual(right));
    }

    fn evalNe(self: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        const eq_result = try self.evalEq(left, right);
        return value_pool.getBool(!(try eq_result.toBoolean()));
    }

    fn evalLt(self: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        const left_int = left.toInteger();
        const right_int = right.toInteger();
        if (left_int != null and right_int != null) {
            return value_pool.getBool(left_int.? < right_int.?);
        }
        const left_float = left.toFloat();
        const right_float = right.toFloat();
        if (left_float != null and right_float != null) {
            return value_pool.getBool(left_float.? < right_float.?);
        }
        // Mixed int/float comparison
        if (left_int != null and right_float != null) {
            return value_pool.getBool(@as(f64, @floatFromInt(left_int.?)) < right_float.?);
        }
        if (left_float != null and right_int != null) {
            return value_pool.getBool(left_float.? < @as(f64, @floatFromInt(right_int.?)));
        }
        // String comparison
        const left_str = try left.toString(self.allocator);
        defer self.allocator.free(left_str);
        const right_str = try right.toString(self.allocator);
        defer self.allocator.free(right_str);
        return value_pool.getBool(std.mem.order(u8, left_str, right_str) == .lt);
    }

    fn evalLte(self: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        const lt_result = try self.evalLt(left, right);
        const eq_result = try self.evalEq(left, right);
        return value_pool.getBool((try lt_result.toBoolean()) or (try eq_result.toBoolean()));
    }

    fn evalGt(self: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        const lt_result = try self.evalLt(left, right);
        const eq_result = try self.evalEq(left, right);
        return value_pool.getBool(!(try lt_result.toBoolean()) and !(try eq_result.toBoolean()));
    }

    fn evalGte(self: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        const lt_result = try self.evalLt(left, right);
        return value_pool.getBool(!(try lt_result.toBoolean()));
    }

    fn evalAnd(_: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        return value_pool.getBool((try left.isTruthy()) and (try right.isTruthy()));
    }

    fn evalOr(_: *Self, left: value_mod.Value, right: value_mod.Value) !value_mod.Value {
        return value_pool.getBool((try left.isTruthy()) or (try right.isTruthy()));
    }

    // Unary expression evaluation methods
    fn evalUnarySub(_: *Self, val: value_mod.Value) !value_mod.Value {
        // Check actual type to preserve float vs integer distinction
        // This must be done before calling toInteger/toFloat since those
        // methods will convert between types (float->int truncates)
        return switch (val) {
            .float => |f| value_mod.Value{ .float = -f },
            .integer => |i| value_mod.Value{ .integer = -i },
            else => {
                // Try to convert string or boolean to number
                const float_val = val.toFloat();
                if (float_val) |f| {
                    return value_mod.Value{ .float = -f };
                }
                return exceptions.TemplateError.TypeError;
            },
        };
    }

    fn evalUnaryTilde(_: *Self, val: value_mod.Value) !value_mod.Value {
        const int_val = val.toInteger();
        if (int_val) |i| {
            return value_mod.Value{ .integer = ~i };
        }
        return exceptions.TemplateError.TypeError;
    }

    fn evalUnaryNot(_: *Self, val: value_mod.Value) !value_mod.Value {
        return value_pool.getBool(!(try val.isTruthy()));
    }

    /// Visit For node - execute for loop
    /// OPTIMIZED: Phase 1 - Zero-allocation per iteration
    /// - Uses OptimizedLoopContext instead of Dict per iteration
    /// - References items directly instead of deep copying per iteration
    /// - No derived context creation
    pub fn visitFor(self: *Self, node: *nodes.For, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Evaluate iterable expression
        var iter_val = try self.visitExpression(&node.iter, frame, ctx);
        defer iter_val.deinit(self.allocator);

        // Convert iter_val to iterable (list or string)
        // NOTE: We still need to copy items here because iter_val will be freed
        // But this is O(n) once at the start, not O(n) per iteration
        var items = std.ArrayList(value_mod.Value){};
        defer {
            for (items.items) |*item| {
                item.deinit(self.allocator);
            }
            items.deinit(self.allocator);
        }

        switch (iter_val) {
            .list => |l| {
                // Deep copy list items - iter_val will be deinit'd later, we need our own copies
                for (l.items.items) |item| {
                    const item_copy = try item.deepCopy(self.allocator);
                    try items.append(self.allocator, item_copy);
                }
            },
            .string => |s| {
                // Convert string to list of characters (as strings)
                for (s) |c| {
                    const char_str = try std.fmt.allocPrint(self.allocator, "{c}", .{c});
                    try items.append(self.allocator, value_mod.Value{ .string = char_str });
                }
            },
            else => {
                // Not iterable - return empty
                return try self.allocator.dupe(u8, "");
            },
        }

        // Handle empty iterable - execute else clause
        if (items.items.len == 0) {
            var output = std.ArrayList(u8){};
            defer output.deinit(self.allocator);

            for (node.else_body.items) |stmt| {
                const stmt_output = try self.visitStatement(stmt, frame, ctx);
                defer self.allocator.free(stmt_output);
                try output.appendSlice(self.allocator, stmt_output);
            }
            return try output.toOwnedSlice(self.allocator);
        }

        // Extract target variable name from Expression
        const target_name = switch (node.target) {
            .name => |n| n.name,
            else => {
                // Invalid target - return empty
                return try self.allocator.dupe(u8, "");
            },
        };

        // OPTIMIZATION: Create OptimizedLoopContext ONCE (stack-allocated)
        // This replaces the per-iteration Dict creation
        var opt_loop = OptimizedLoopContext.init(
            items.items,
            target_name,
            frame.getOptLoop(), // Parent loop for depth tracking
        );

        // Create new frame for loop (minimal - just for scoping)
        var loop_frame = Frame.init("for_loop", frame, self.allocator);
        defer loop_frame.deinit();

        // OPTIMIZATION: Set opt_loop pointer instead of creating Dict per iteration
        loop_frame.opt_loop = &opt_loop;

        var output = std.ArrayList(u8){};
        defer output.deinit(self.allocator);

        // Execute loop body
        // NOTE: We still deep copy the loop variable per iteration for now
        // The main optimization is avoiding Dict creation for loop.index etc.
        while (opt_loop.hasMore()) {
            // Set loop variable (deep copy - still needed for proper ownership)
            const current_item = opt_loop.getCurrentItem();
            const item_copy = try current_item.deepCopy(self.allocator);
            try loop_frame.set(target_name, item_copy);

            // Execute body statements
            var should_break = false;
            var should_continue = false;

            for (node.body.items) |stmt| {
                // Pass original ctx - no derived context needed
                // loop.* attributes are resolved via frame.opt_loop in visitGetattr
                const stmt_output = self.visitStatement(stmt, &loop_frame, ctx) catch |err| {
                    if (err == exceptions.TemplateError.ContinueError) {
                        should_continue = true;
                        break;
                    } else if (err == exceptions.TemplateError.BreakError) {
                        should_break = true;
                        break;
                    } else {
                        return err;
                    }
                };
                defer self.allocator.free(stmt_output);

                try output.appendSlice(self.allocator, stmt_output);
            }

            if (should_break) {
                break; // Break out of loop
            }

            // Advance to next iteration - O(1), no allocation
            opt_loop.advance();

            if (should_continue) {
                continue; // Continue to next iteration
            }
        }

        // Note: else clause is handled at the start (early return for empty iterable)
        // Note: No cleanup needed - OptimizedLoopContext is stack-allocated and doesn't
        // allocate previtem/nextitem (it references items array directly)

        return try output.toOwnedSlice(self.allocator);
    }

    /// Visit If node - execute conditional statement
    pub fn visitIf(self: *Self, node: *nodes.If, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Evaluate condition
        var condition_val = try self.visitExpression(&node.condition, frame, ctx);
        defer condition_val.deinit(self.allocator);

        var output = std.ArrayList(u8){};
        defer output.deinit(self.allocator);

        // Check if condition is truthy
        if (try condition_val.isTruthy()) {
            // Execute if body
            for (node.body.items) |stmt| {
                const stmt_output = try self.visitStatement(stmt, frame, ctx);
                defer self.allocator.free(stmt_output);
                try output.appendSlice(self.allocator, stmt_output);
            }
            return try output.toOwnedSlice(self.allocator);
        }

        // Check elif conditions
        for (node.elif_conditions.items, 0..) |elif_condition, i| {
            var elif_val = try self.visitExpression(@constCast(&elif_condition), frame, ctx);
            defer elif_val.deinit(self.allocator);

            if (try elif_val.isTruthy()) {
                // Execute elif body
                if (i < node.elif_bodies.items.len) {
                    for (node.elif_bodies.items[i].items) |stmt| {
                        const stmt_output = try self.visitStatement(stmt, frame, ctx);
                        defer self.allocator.free(stmt_output);
                        try output.appendSlice(self.allocator, stmt_output);
                    }
                }
                return try output.toOwnedSlice(self.allocator);
            }
        }

        // Execute else body if present
        for (node.else_body.items) |stmt| {
            const stmt_output = try self.visitStatement(stmt, frame, ctx);
            defer self.allocator.free(stmt_output);
            try output.appendSlice(self.allocator, stmt_output);
        }

        return try output.toOwnedSlice(self.allocator);
    }

    /// Visit CallExpr node - evaluate function call expression
    pub fn visitCallExpr(self: *Self, node: *nodes.CallExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // SPECIAL CASE: Handle loop.cycle() and loop.changed() methods
        if (node.func == .getattr) {
            const attr = node.func.getattr;
            if (attr.node == .name and std.mem.eql(u8, attr.node.name.name, "loop")) {
                // Check for loop.cycle(...) method
                if (std.mem.eql(u8, attr.attr, "cycle")) {
                    return try self.evaluateLoopCycle(node, frame, ctx);
                }
                // Check for loop.changed(...) method
                if (std.mem.eql(u8, attr.attr, "changed")) {
                    return try self.evaluateLoopChanged(node, frame, ctx);
                }
            }
        }

        // Extract function name from expression
        var func_name: []const u8 = undefined;
        var func_name_owned: ?[]u8 = null;
        defer if (func_name_owned) |owned| self.allocator.free(owned);

        // Evaluate function expression (needed for both name extraction and sandbox checking)
        var func_val = try self.visitExpression(&node.func, frame, ctx);
        defer func_val.deinit(self.allocator);

        // Check sandbox security if enabled (for function calls)
        if (self.environment.sandboxed) {
            const sandbox_mod = @import("sandbox.zig");
            if (!sandbox_mod.isSafeCallable(func_val)) {
                return exceptions.TemplateError.SecurityError;
            }
        }

        switch (node.func) {
            .name => |n| {
                func_name = n.name;
            },
            else => {
                // Convert function value to string for name
                const name_str = try func_val.toString(self.allocator);
                defer self.allocator.free(name_str);
                func_name_owned = try self.allocator.dupe(u8, name_str);
                func_name = func_name_owned.?;
            },
        }

        // Check if it's super() - special function for block inheritance
        if (std.mem.eql(u8, func_name, "super")) {
            // super() can only be called within a block
            if (frame.current_block) |current_block| {
                // Render the super block (parent block)
                const super_output = try self.renderBlock(current_block.name, current_block, frame, ctx);
                return value_mod.Value{ .string = super_output };
            } else {
                // super() called outside of block - error
                return exceptions.TemplateError.RuntimeError;
            }
        }

        // Check if it's caller() - special function for call blocks
        // caller() returns the pre-rendered body passed from {% call %} block
        if (std.mem.eql(u8, func_name, "caller")) {
            if (frame.resolve("caller")) |caller_val| {
                // Return a deep copy of the caller value
                return try caller_val.deepCopy(self.allocator);
            } else {
                // caller() called outside of call block context - error
                return exceptions.TemplateError.RuntimeError;
            }
        }

        // Check if it's a macro
        if (ctx.getMacro(func_name)) |macro| {
            // Convert to Expression list for callMacro
            var expr_args = std.ArrayList(nodes.Expression){};
            defer expr_args.deinit(self.allocator);
            for (node.args.items) |arg| {
                try expr_args.append(self.allocator, arg);
            }

            // Call macro and return result as string value
            const result_str = try self.callMacro(macro, expr_args.items, node.kwargs, frame, ctx, null);
            return value_mod.Value{ .string = result_str };
        }

        // Check if it's a filter (filters can be called as functions)
        if (self.environment.getFilter(func_name)) |filter| {
            // Evaluate arguments
            var filter_args = std.ArrayList(value_mod.Value){};
            defer {
                for (filter_args.items) |*arg| {
                    arg.deinit(self.allocator);
                }
                filter_args.deinit(self.allocator);
            }

            // First argument is the value (empty for function-style calls)
            // Then add positional arguments
            for (node.args.items) |*arg_expr| {
                const arg_val = try self.visitExpression(arg_expr, frame, ctx);
                try filter_args.append(self.allocator, arg_val);
            }

            // Apply filter with empty value (function-style call)
            var empty_val = value_mod.Value{ .string = try self.allocator.dupe(u8, "") };
            defer empty_val.deinit(self.allocator);

            // Call the filter function directly
            const result = try filter.func(self.allocator, empty_val, filter_args.items, ctx, self.environment);
            return result;
        }

        // Check if it's a global function
        if (self.environment.getGlobal(func_name)) |global_val| {
            // Check if the global is a callable value with a function pointer
            if (global_val == .callable) {
                const callable_obj = global_val.callable;

                // Evaluate arguments
                var call_args = std.ArrayList(value_mod.Value){};
                defer {
                    for (call_args.items) |*arg| {
                        arg.deinit(self.allocator);
                    }
                    call_args.deinit(self.allocator);
                }

                for (node.args.items) |arg| {
                    const arg_val = try self.visitExpression(@constCast(&arg), frame, ctx);
                    try call_args.append(self.allocator, arg_val);
                }

                // Call the function if it has a function pointer
                if (callable_obj.func) |func| {
                    const result = func(self.allocator, call_args.items, ctx, self.environment) catch |err| {
                        return switch (err) {
                            error.RuntimeError, error.UndefinedError, error.InvalidArgument, error.TypeError, error.NotCallable => exceptions.TemplateError.RuntimeError,
                            error.OutOfMemory => error.OutOfMemory,
                        };
                    };
                    return result;
                } else {
                    // Callable without function pointer - return undefined
                    const name_copy = if (callable_obj.name) |n|
                        try self.allocator.dupe(u8, n)
                    else
                        try self.allocator.dupe(u8, "<anonymous>");
                    return value_mod.Value{ .undefined = value_mod.Undefined{
                        .name = name_copy,
                        .behavior = ctx.environment.undefined_behavior,
                    } };
                }
            }

            // Non-callable global - return as-is
            return try global_val.deepCopy(self.allocator);
        }

        // Function not found
        return exceptions.TemplateError.RuntimeError;
    }

    /// Evaluate loop.cycle(args) - return item based on current loop index
    /// Example: loop.cycle('odd', 'even') returns 'odd' for index0=0, 'even' for index0=1, etc.
    fn evaluateLoopCycle(self: *Self, node: *nodes.CallExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // Get the loop context
        const opt_loop = frame.getOptLoop() orelse {
            return exceptions.TemplateError.RuntimeError; // Not in a loop
        };

        // Need at least one argument
        if (node.args.items.len == 0) {
            return exceptions.TemplateError.TypeError; // No items for cycling given
        }

        // Calculate which item to return based on current loop index
        const idx: usize = @intCast(@mod(opt_loop.index0, @as(i64, @intCast(node.args.items.len))));

        // Evaluate the argument at that index
        var arg_expr = node.args.items[idx];
        return try self.visitExpression(&arg_expr, frame, ctx);
    }

    /// Evaluate loop.changed(value) - return true if value differs from last call
    /// Example: {% if loop.changed(item.category) %}new category{% endif %}
    fn evaluateLoopChanged(self: *Self, node: *nodes.CallExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // Get the loop context (need mutable access)
        const opt_loop = frame.getOptLoop() orelse {
            return exceptions.TemplateError.RuntimeError; // Not in a loop
        };

        // Evaluate all arguments and compute a hash
        var hash: u64 = 0;
        for (node.args.items) |*arg_expr| {
            var arg_val = try self.visitExpression(arg_expr, frame, ctx);
            defer arg_val.deinit(self.allocator);

            // Simple hash computation based on value
            const val_hash = computeValueHash(arg_val);
            hash = hash *% 31 +% val_hash;
        }

        // Check if changed from last call
        const changed = if (opt_loop.last_changed_hash) |last_hash|
            hash != last_hash
        else
            true; // First call always returns true

        // Update the last changed hash
        opt_loop.last_changed_hash = hash;

        return value_mod.Value{ .boolean = changed };
    }

    /// Visit Macro node - register macro in context
    pub fn visitMacro(self: *Self, node: *nodes.Macro, _: *Frame, ctx: *context.Context) ![]const u8 {
        // Register macro in context for later use
        try ctx.setMacro(node.name, node);
        // Macros don't produce output when defined
        return try self.allocator.dupe(u8, "");
    }

    /// Visit Call node - call a macro
    pub fn visitCall(self: *Self, node: *nodes.Call, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Extract macro name from expression (should be a name)
        const macro_name = switch (node.macro_expr) {
            .name => |n| n.name,
            else => {
                // Try to evaluate and convert to string
                const macro_expr_val = try self.visitExpression(&node.macro_expr, frame, ctx);
                defer macro_expr_val.deinit(self.allocator);
                const name_str = try macro_expr_val.toString(self.allocator);
                defer self.allocator.free(name_str);
                // Look up macro by name
                const macro = ctx.getMacro(name_str) orelse {
                    return exceptions.TemplateError.RuntimeError;
                };
                return try self.callMacro(macro, node.args.items, node.kwargs, frame, ctx, null);
            },
        };

        // Look up macro by name
        const macro = ctx.getMacro(macro_name) orelse {
            return exceptions.TemplateError.RuntimeError;
        };

        return try self.callMacro(macro, node.args.items, node.kwargs, frame, ctx, null);
    }

    /// Visit NSRef node - namespace reference (namespace.attr)
    pub fn visitNSRef(self: *Self, node: *nodes.NSRef, _: *Frame, ctx: *context.Context) !value_mod.Value {
        // Resolve namespace from context
        const namespace_val = ctx.resolve(node.name);
        if (namespace_val == .undefined) {
            return exceptions.TemplateError.UndefinedError;
        }
        defer namespace_val.deinit(self.allocator);

        // Get attribute from namespace
        // Namespaces are typically dict-like objects
        if (namespace_val == .dict) {
            if (namespace_val.dict.get(node.attr)) |attr_val| {
                return try attr_val.deepCopy(self.allocator);
            }
        }

        // Return undefined if attribute not found
        const attr_name_copy = try self.allocator.dupe(u8, node.attr);
        return value_mod.Value{ .undefined = value_mod.Undefined{
            .name = attr_name_copy,
            .behavior = ctx.environment.undefined_behavior,
        } };
    }

    /// Visit Slice node - slicing syntax [start:end:step]
    /// Note: Slices are handled in visitGetitem through evaluateSlice.
    /// This function is called when a slice appears standalone, which is invalid.
    pub fn visitSlice(_: *Self, _: *nodes.Slice, _: *Frame, _: *context.Context) !value_mod.Value {
        // Slice expressions should only appear as part of Getitem (obj[start:stop])
        // A standalone slice expression is not valid in Jinja2
        return exceptions.TemplateError.RuntimeError;
    }

    /// Visit Concat node - concatenate expressions as strings
    pub fn visitConcat(self: *Self, node: *nodes.Concat, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        var result = std.ArrayList(u8){};
        defer result.deinit(self.allocator);

        // Evaluate and concatenate all expressions
        for (node.nodes.items) |*expr| {
            const val = try self.visitExpression(expr, frame, ctx);
            defer val.deinit(self.allocator);

            const str = try val.toString(self.allocator);
            defer self.allocator.free(str);
            try result.appendSlice(self.allocator, str);
        }

        const result_str = try result.toOwnedSlice(self.allocator);
        return value_mod.Value{ .string = result_str };
    }

    /// Visit EnvironmentAttribute node - get attribute from environment
    pub fn visitEnvironmentAttribute(self: *Self, node: *nodes.EnvironmentAttribute, _: *Frame, _: *context.Context) !value_mod.Value {

        // Get attribute from environment
        // This is typically used by extensions to access environment callbacks
        // For now, return undefined - extensions would handle this
        const name_copy = try self.allocator.dupe(u8, node.name);
        return value_mod.Value{ .undefined = value_mod.Undefined{
            .name = name_copy,
            .behavior = .lenient,
        } };
    }

    /// Visit ExtensionAttribute node - get attribute from extension
    pub fn visitExtensionAttribute(self: *Self, node: *nodes.ExtensionAttribute, _: *Frame, _: *context.Context) !value_mod.Value {

        // Get attribute from extension bound to environment
        // Extensions would handle this through their own mechanisms
        const name_copy = try self.allocator.dupe(u8, node.name);
        return value_mod.Value{ .undefined = value_mod.Undefined{
            .name = name_copy,
            .behavior = .lenient,
        } };
    }

    /// Visit ImportedName node - get imported name value
    pub fn visitImportedName(self: *Self, node: *nodes.ImportedName, _: *Frame, ctx: *context.Context) !value_mod.Value {

        // Imported names are resolved from context (from import statements)
        // The importname is like "cgi.escape" - we'd resolve it from imports
        // For now, try to resolve from context
        const val = ctx.resolve(node.importname);
        if (val == .undefined) {
            return exceptions.TemplateError.UndefinedError;
        }
        return try val.deepCopy(self.allocator);
    }

    /// Visit InternalName node - get internal compiler name
    pub fn visitInternalName(self: *Self, node: *nodes.InternalName, _: *Frame, _: *context.Context) !value_mod.Value {

        // Internal names are compiler-generated and not accessible from templates
        // They're used internally for code generation
        // Return undefined as they shouldn't be evaluated in templates
        const name_copy = try self.allocator.dupe(u8, node.name);
        return value_mod.Value{ .undefined = value_mod.Undefined{
            .name = name_copy,
            .behavior = .strict,
        } };
    }

    /// Visit ContextReference node - get current template context
    pub fn visitContextReference(self: *Self, _: *nodes.ContextReference, _: *Frame, ctx: *context.Context) !value_mod.Value {

        // Return a reference to the current context
        // In Jinja2, this returns the Context object itself
        // For Zig, we'll return a dict representation of the context
        const ctx_dict = try self.allocator.create(value_mod.Dict);
        ctx_dict.* = value_mod.Dict.init(self.allocator);
        errdefer ctx_dict.deinit(self.allocator);
        errdefer self.allocator.destroy(ctx_dict);

        // Add context properties
        if (ctx.name) |name| {
            // Note: name_copy is used for the value - Dict.set will duplicate for key
            const name_copy = try self.allocator.dupe(u8, name);
            try ctx_dict.set(name, value_mod.Value{ .string = name_copy });
        }

        // Add exported vars
        // Note: Dict.set duplicates keys internally, so pass original key directly
        var exported_iter = ctx.exported_vars.iterator();
        while (exported_iter.next()) |entry| {
            const val = ctx.resolve(entry.key_ptr.*);
            if (val != .undefined) {
                const val_copy = try val.deepCopy(self.allocator);
                try ctx_dict.set(entry.key_ptr.*, val_copy);
            }
        }

        return value_mod.Value{ .dict = ctx_dict };
    }

    /// Visit DerivedContextReference node - get current context including locals
    pub fn visitDerivedContextReference(self: *Self, node: *nodes.DerivedContextReference, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        _ = node;

        // Similar to ContextReference but includes local variables from frame
        const ctx_dict = try self.allocator.create(value_mod.Dict);
        ctx_dict.* = value_mod.Dict.init(self.allocator);
        errdefer ctx_dict.deinit(self.allocator);
        errdefer self.allocator.destroy(ctx_dict);

        // Add context properties
        if (ctx.name) |name| {
            // Note: name_copy is used for both key AND value - Dict.set will duplicate for key
            const name_copy = try self.allocator.dupe(u8, name);
            try ctx_dict.set(name, value_mod.Value{ .string = name_copy });
        }

        // Add frame variables (locals)
        // Note: Dict.set duplicates keys internally, so pass original key directly
        var frame_vars_iter = frame.variables.iterator();
        while (frame_vars_iter.next()) |entry| {
            const val_copy = try entry.value_ptr.*.deepCopy(self.allocator);
            try ctx_dict.set(entry.key_ptr.*, val_copy);
        }

        // Add exported vars from context
        // Note: Dict.set duplicates keys internally, so pass original key directly
        var exported_iter = ctx.exported_vars.iterator();
        while (exported_iter.next()) |entry| {
            const val = ctx.resolve(entry.key_ptr.*);
            if (val != .undefined) {
                const val_copy = try val.deepCopy(self.allocator);
                try ctx_dict.set(entry.key_ptr.*, val_copy);
            }
        }

        return value_mod.Value{ .dict = ctx_dict };
    }

    /// Visit CallBlock node - call macro with body
    pub fn visitCallBlock(self: *Self, node: *nodes.CallBlock, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Extract macro name and arguments from call expression
        const macro_name = switch (node.call_expr) {
            .name => |n| n.name,
            .call_expr => |call| blk: {
                // Extract function name from call expression
                break :blk switch (call.func) {
                    .name => |n| n.name,
                    else => return exceptions.TemplateError.RuntimeError,
                };
            },
            else => return exceptions.TemplateError.RuntimeError,
        };

        // Look up macro
        const macro = ctx.getMacro(macro_name) orelse {
            return exceptions.TemplateError.RuntimeError;
        };

        // Render call block body to pass as caller
        var caller_body = std.ArrayList(u8){};
        defer caller_body.deinit(self.allocator);

        for (node.body.items) |stmt| {
            const stmt_output = try self.visitStatement(stmt, frame, ctx);
            defer self.allocator.free(stmt_output);
            try caller_body.appendSlice(self.allocator, stmt_output);
        }

        const caller_str = try caller_body.toOwnedSlice(self.allocator);
        defer self.allocator.free(caller_str);

        // Create caller value
        const caller_value = value_mod.Value{ .string = caller_str };

        // Extract args from call_expr if it's a CallExpr
        var args = std.ArrayList(nodes.Expression){};
        defer args.deinit(self.allocator);
        var kwargs = std.StringHashMap(nodes.Expression).init(self.allocator);
        defer {
            var kw_iter = kwargs.iterator();
            while (kw_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(self.allocator);
            }
            kwargs.deinit();
        }

        if (node.call_expr == .call_expr) {
            const call = node.call_expr.call_expr;
            for (call.args.items) |arg| {
                try args.append(self.allocator, arg);
            }
            var kw_iter = call.kwargs.iterator();
            while (kw_iter.next()) |entry| {
                const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                try kwargs.put(key, entry.value_ptr.*);
            }
        }

        return try self.callMacro(macro, args.items, kwargs, frame, ctx, caller_value);
    }

    /// Helper function to call a macro with arguments
    fn callMacro(
        self: *Self,
        macro: *nodes.Macro,
        args: []nodes.Expression,
        kwargs: std.StringHashMap(nodes.Expression),
        frame: *Frame,
        ctx: *context.Context,
        caller: ?value_mod.Value,
    ) ![]const u8 {
        // Create new frame for macro execution
        var macro_frame = Frame.init("macro", frame, self.allocator);
        defer macro_frame.deinit();

        // Track which kwargs have been used
        var used_kwargs = std.StringHashMap(void).init(self.allocator);
        defer used_kwargs.deinit();

        // Set macro arguments
        var arg_index: usize = 0;
        for (macro.args.items) |macro_arg| {
            var arg_value: ?value_mod.Value = null;

            // Check if provided as positional argument
            if (arg_index < args.len) {
                arg_value = try self.visitExpression(&args[arg_index], frame, ctx);
            }

            // Check if provided as keyword argument
            if (kwargs.get(macro_arg.name)) |kw_expr| {
                if (arg_value) |val| {
                    val.deinit(self.allocator);
                }
                arg_value = try self.visitExpression(@constCast(&kw_expr), frame, ctx);
                try used_kwargs.put(macro_arg.name, {});
            }

            // Use default value if not provided
            if (arg_value == null) {
                if (macro_arg.default_value) |default_expr| {
                    arg_value = try self.visitExpression(@constCast(&default_expr), frame, ctx);
                } else {
                    return exceptions.TemplateError.RuntimeError;
                }
            }

            // Set argument in macro frame (deep copy)
            const arg_copy = try arg_value.?.deepCopy(self.allocator);
            try macro_frame.set(macro_arg.name, arg_copy);
            arg_value.?.deinit(self.allocator);
            arg_index += 1;
        }

        // Handle varargs - collect extra positional arguments
        if (macro.catch_varargs) {
            const varargs_list = try self.allocator.create(value_mod.List);
            varargs_list.* = value_mod.List.init(self.allocator);

            // Add extra positional arguments to varargs
            const expected_args = macro.args.items.len;
            if (args.len > expected_args) {
                for (args[expected_args..]) |*extra_arg| {
                    const extra_val = try self.visitExpression(extra_arg, frame, ctx);
                    try varargs_list.append(extra_val);
                }
            }

            try macro_frame.set("varargs", value_mod.Value{ .list = varargs_list });
        } else if (args.len > macro.args.items.len) {
            // Too many positional arguments and macro doesn't catch varargs
            return exceptions.TemplateError.RuntimeError;
        }

        // Handle kwargs - collect extra keyword arguments
        if (macro.catch_kwargs) {
            const kwargs_dict = try self.allocator.create(value_mod.Dict);
            kwargs_dict.* = value_mod.Dict.init(self.allocator);

            // Add unused keyword arguments to kwargs dict
            var kw_iter = kwargs.iterator();
            while (kw_iter.next()) |entry| {
                if (!used_kwargs.contains(entry.key_ptr.*)) {
                    const kw_val = try self.visitExpression(@constCast(entry.value_ptr), frame, ctx);
                    try kwargs_dict.set(entry.key_ptr.*, kw_val);
                }
            }

            try macro_frame.set("kwargs", value_mod.Value{ .dict = kwargs_dict });
        } else {
            // Check for unused kwargs when macro doesn't catch them
            var kw_iter = kwargs.iterator();
            while (kw_iter.next()) |entry| {
                if (!used_kwargs.contains(entry.key_ptr.*)) {
                    // Unknown keyword argument
                    return exceptions.TemplateError.RuntimeError;
                }
            }
        }

        // Set caller if provided (for call blocks) - deep copy
        if (caller) |caller_val| {
            const caller_copy = try caller_val.deepCopy(self.allocator);
            try macro_frame.set("caller", caller_copy);
        }

        // Execute macro body
        var output = std.ArrayList(u8){};
        defer output.deinit(self.allocator);

        for (macro.body.items) |stmt| {
            const stmt_output = try self.visitStatement(stmt, &macro_frame, ctx);
            defer self.allocator.free(stmt_output);
            try output.appendSlice(self.allocator, stmt_output);
        }

        return try output.toOwnedSlice(self.allocator);
    }

    /// Visit Set node - assign variable
    pub fn visitSet(self: *Self, node: *nodes.Set, frame: *Frame, ctx: *context.Context) ![]const u8 {
        var value: value_mod.Value = undefined;

        if (node.body) |*body| {
            // Set block variant - render body to get value
            var body_output = std.ArrayList(u8){};
            defer body_output.deinit(self.allocator);

            for (body.items) |stmt| {
                const stmt_output = try self.visitStatement(stmt, frame, ctx);
                defer self.allocator.free(stmt_output);
                try body_output.appendSlice(self.allocator, stmt_output);
            }

            const body_str = try body_output.toOwnedSlice(self.allocator);
            value = value_mod.Value{ .string = body_str };
        } else {
            // Regular set - evaluate expression
            value = try self.visitExpression(&node.value, frame, ctx);
        }

        // Set variable in frame (deep copy)
        const value_copy = try value.deepCopy(self.allocator);
        defer value.deinit(self.allocator);
        try frame.set(node.name, value_copy);

        // Set statements don't produce output
        return try self.allocator.dupe(u8, "");
    }

    /// Visit With node - create scoped variables
    pub fn visitWith(self: *Self, node: *nodes.With, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Create new frame for with block
        var with_frame = Frame.init("with", frame, self.allocator);
        defer with_frame.deinit();

        // Set variables in with frame (deep copy)
        for (node.targets.items, 0..) |target, i| {
            if (i < node.values.items.len) {
                const value_expr = &node.values.items[i];
                const value_val = try self.visitExpression(value_expr, frame, ctx);
                const value_copy = try value_val.deepCopy(self.allocator);
                defer value_val.deinit(self.allocator);
                try with_frame.set(target, value_copy);
            }
        }

        // Execute body with new frame
        var output = std.ArrayList(u8){};
        defer output.deinit(self.allocator);

        for (node.body.items) |stmt| {
            const stmt_output = try self.visitStatement(stmt, &with_frame, ctx);
            defer self.allocator.free(stmt_output);
            try output.appendSlice(self.allocator, stmt_output);
        }

        return try output.toOwnedSlice(self.allocator);
    }

    /// Visit FilterBlock node - apply filter to block
    pub fn visitFilterBlock(self: *Self, node: *nodes.FilterBlock, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Render block body first
        var body_output = std.ArrayList(u8){};
        defer body_output.deinit(self.allocator);

        for (node.body.items) |stmt| {
            const stmt_output = try self.visitStatement(stmt, frame, ctx);
            defer self.allocator.free(stmt_output);
            try body_output.appendSlice(self.allocator, stmt_output);
        }

        const body_str = try body_output.toOwnedSlice(self.allocator);
        defer self.allocator.free(body_str);

        // Extract filter name from filter expression
        // The filter_expr should be a FilterExpr or Name
        const filter_name = switch (node.filter_expr) {
            .name => |n| n.name,
            .filter => |f| f.name,
            else => return exceptions.TemplateError.RuntimeError,
        };

        // Get filter from environment
        const filter = self.environment.getFilter(filter_name) orelse {
            return exceptions.TemplateError.RuntimeError;
        };

        // Apply filter to body
        const body_value = value_mod.Value{ .string = body_str };
        var filter_args = std.ArrayList(value_mod.Value){};
        defer {
            for (filter_args.items) |*arg| {
                arg.deinit(self.allocator);
            }
            filter_args.deinit(self.allocator);
        }

        // Extract filter arguments if filter_expr is a FilterExpr
        if (node.filter_expr == .filter) {
            const filter_expr = node.filter_expr.filter;
            for (filter_expr.args.items) |*arg_expr| {
                const arg_val = try self.visitExpression(arg_expr, frame, ctx);
                try filter_args.append(self.allocator, arg_val);
            }
        }

        const filtered_value = try filter.func(
            self.allocator,
            body_value,
            filter_args.items,
            ctx,
            self.environment,
        );
        defer filtered_value.deinit(self.allocator);

        const filtered_str = try filtered_value.toString(self.allocator);
        defer self.allocator.free(filtered_str);

        return try self.allocator.dupe(u8, filtered_str);
    }

    /// Visit Autoescape node - set autoescape in block scope
    pub fn visitAutoescape(self: *Self, node: *nodes.Autoescape, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Evaluate enabled expression
        const enabled_val = try self.visitExpression(&node.enabled, frame, ctx);
        defer enabled_val.deinit(self.allocator);

        const enabled = try enabled_val.toBoolean();

        // Create new frame with autoescape setting
        var autoescape_frame = Frame.init("autoescape", frame, self.allocator);
        defer autoescape_frame.deinit();
        autoescape_frame.autoescape = enabled;

        // Execute body with autoescape setting
        var output = std.ArrayList(u8){};
        defer output.deinit(self.allocator);

        for (node.body.items) |stmt| {
            const stmt_output = try self.visitStatement(stmt, &autoescape_frame, ctx);
            defer self.allocator.free(stmt_output);
            try output.appendSlice(self.allocator, stmt_output);
        }

        return try output.toOwnedSlice(self.allocator);
    }

    /// Visit Extends node - load parent template and merge blocks
    pub fn visitExtends(self: *Self, node: *nodes.Extends, frame: *Frame, ctx: *context.Context, current_template: *nodes.Template) !void {
        // Evaluate template name expression
        const template_expr_val = try self.visitExpression(&node.template, frame, ctx);
        defer template_expr_val.deinit(self.allocator);

        // Convert to string
        const template_name_str = try template_expr_val.toString(self.allocator);
        defer self.allocator.free(template_name_str);

        // Load parent template
        const parent_template = try self.environment.getTemplate(template_name_str);

        // Set parent on current template
        current_template.parent = parent_template;

        // Recursively process parent template's inheritance chain
        // This ensures all ancestor blocks are registered
        try self.processParentBlocks(parent_template, ctx);
    }

    /// Recursively process parent template blocks
    /// This handles multi-level inheritance (grandparent -> parent -> child)
    fn processParentBlocks(self: *Self, parent_template: *nodes.Template, ctx: *context.Context) !void {
        // First process grandparent if parent extends another template
        // Find extends statement in parent template
        for (parent_template.body.items) |stmt| {
            if (stmt.tag == .extends) {
                const extends_stmt = @as(*nodes.Extends, @ptrCast(@alignCast(stmt)));
                // Evaluate template name
                var temp_frame = Frame.init("temp", null, self.allocator);
                defer temp_frame.deinit();
                var temp_ctx = try context.Context.init(self.environment, std.StringHashMap(context.Value).init(self.allocator), null, self.allocator);
                defer temp_ctx.deinit();

                const template_expr_val = try self.visitExpression(&extends_stmt.template, &temp_frame, &temp_ctx);
                defer template_expr_val.deinit(self.allocator);

                const template_name_str = try template_expr_val.toString(self.allocator);
                defer self.allocator.free(template_name_str);

                const grandparent_template = try self.environment.getTemplate(template_name_str);
                parent_template.parent = grandparent_template;

                // Recursively process grandparent
                try self.processParentBlocks(grandparent_template, ctx);
                break;
            }
        }

        // Now process parent template's blocks
        // Blocks from parent template body
        for (parent_template.body.items) |stmt| {
            if (stmt.tag == .block) {
                const block_stmt = @as(*nodes.Block, @ptrCast(@alignCast(stmt)));
                // Add parent block to context (will be after child blocks in stack)
                try ctx.addBlock(block_stmt.name, block_stmt);
            }
        }

        // Also process blocks from parent template's blocks map (if any)
        var parent_iter = parent_template.blocks.iterator();
        while (parent_iter.next()) |entry| {
            // Add parent block to context
            try ctx.addBlock(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// Visit Block node - execute block content
    /// Blocks can be executed directly or referenced via super()
    pub fn visitBlock(self: *Self, node: *nodes.Block, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Check if block is required but not overridden
        if (node.required) {
            // Required blocks must be overridden by child templates.
            // A required block that only contains whitespace/comments is OK,
            // but if it has actual content (not overridden), it's an error.
            // Check if this is the topmost block in the stack (meaning no child override)
            if (ctx.blocks.get(node.name)) |block_stack| {
                if (block_stack.items.len > 0 and block_stack.items[0] == node) {
                    // This required block is at the top of the stack = not overridden
                    // Check if it has actual content (non-whitespace)
                    if (try self.blockHasContent(node)) {
                        // Required block has content but wasn't overridden - this is an error
                        return exceptions.TemplateError.SyntaxError;
                    }
                }
            }
        }

        // Set current block in frame for super() support
        const previous_block = frame.current_block;
        frame.current_block = node;
        defer frame.current_block = previous_block;

        // Execute block body
        var output = std.ArrayList(u8){};
        defer output.deinit(self.allocator);

        for (node.body.items) |stmt| {
            const stmt_output = try self.visitStatement(stmt, frame, ctx);
            defer self.allocator.free(stmt_output);
            try output.appendSlice(self.allocator, stmt_output);
        }

        return try output.toOwnedSlice(self.allocator);
    }

    /// Helper to check if a block has actual content (non-whitespace/comment)
    /// Required blocks should only contain whitespace/comments when not overridden
    fn blockHasContent(self: *Self, block: *nodes.Block) !bool {
        _ = self;
        for (block.body.items) |stmt| {
            switch (stmt.tag) {
                .comment => {
                    // Comments are OK in required blocks
                    continue;
                },
                .output => {
                    // Check if output is just whitespace
                    const output = @as(*nodes.Output, @ptrCast(@alignCast(stmt)));
                    // If it has expression nodes, it's content
                    if (output.nodes.items.len > 0) {
                        return true;
                    }
                    // If plain text is non-whitespace, it's content
                    for (output.content) |c| {
                        if (!std.ascii.isWhitespace(c)) {
                            return true;
                        }
                    }
                },
                else => {
                    // Any other statement type is considered content
                    return true;
                },
            }
        }
        return false;
    }

    /// Render a block by name (used for super() calls)
    /// Returns the rendered content of the next block in the stack
    pub fn renderBlock(self: *Self, block_name: []const u8, current_block: *nodes.Block, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Get the super block (parent block in stack)
        if (ctx.getSuperBlock(block_name, current_block)) |super_block| {
            // Render the super block
            return try self.visitBlock(super_block, frame, ctx);
        }

        // No super block found - return empty string
        // In Jinja2, this would return Undefined, but for now we return empty
        return try self.allocator.dupe(u8, "");
    }

    /// Visit Include node - include another template
    pub fn visitInclude(self: *Self, node: *nodes.Include, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Evaluate template name expression
        const template_expr_val = try self.visitExpression(&node.template, frame, ctx);
        defer template_expr_val.deinit(self.allocator);

        // Convert to string
        const template_name_str = try template_expr_val.toString(self.allocator);
        defer self.allocator.free(template_name_str);

        // Load included template
        const included_template = self.environment.getTemplate(template_name_str) catch |err| {
            if (err == exceptions.TemplateError.TemplateNotFound) {
                if (node.ignore_missing) {
                    // Ignore missing template - return empty string
                    return try self.allocator.dupe(u8, "");
                }
                // Re-raise error if ignore_missing is false
                return err;
            }
            return err;
        };

        // Create context for included template
        var include_ctx: context.Context = undefined;
        if (node.with_context) {
            // Create new context with current context as parent
            // This gives included template access to all variables from current context
            // Use an empty vars map - variables will be resolved from parent context
            const empty_vars = std.StringHashMap(context.Value).init(self.allocator);
            include_ctx = try context.Context.initWithParent(self.environment, empty_vars, template_name_str, ctx, self.allocator);
        } else {
            // Create empty context (no variables passed, no parent)
            const empty_vars = std.StringHashMap(context.Value).init(self.allocator);
            include_ctx = try context.Context.init(self.environment, empty_vars, template_name_str, self.allocator);
        }
        defer include_ctx.deinit();

        // Render the included template
        var include_frame = Frame.init("include", frame, self.allocator);
        defer include_frame.deinit();

        return try self.visitTemplate(included_template, &include_frame, &include_ctx);
    }

    /// Visit Import node - import a template as a module
    pub fn visitImport(self: *Self, node: *nodes.Import, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Evaluate template name expression
        const template_expr_val = try self.visitExpression(&node.template, frame, ctx);
        defer template_expr_val.deinit(self.allocator);

        // Convert to string
        const template_name_str = try template_expr_val.toString(self.allocator);
        defer self.allocator.free(template_name_str);

        // Load imported template
        const imported_template = try self.environment.getTemplate(template_name_str);

        // Create context for imported template
        var import_ctx: context.Context = undefined;
        if (node.with_context) {
            // Create new context with current context as parent
            const empty_vars = std.StringHashMap(context.Value).init(self.allocator);
            import_ctx = try context.Context.initWithParent(self.environment, empty_vars, template_name_str, ctx, self.allocator);
        } else {
            // Create empty context (no variables passed)
            const empty_vars = std.StringHashMap(context.Value).init(self.allocator);
            import_ctx = try context.Context.init(self.environment, empty_vars, template_name_str, self.allocator);
        }
        defer import_ctx.deinit();

        // Create template module
        const module = try self.allocator.create(runtime.TemplateModule);
        errdefer self.allocator.destroy(module);
        module.* = try runtime.TemplateModule.init(self.allocator, imported_template, &import_ctx);

        // Store module in context with target name
        try ctx.setImportedModule(node.target, module);

        // Imports don't produce output
        return try self.allocator.dupe(u8, "");
    }

    /// Visit FromImport node - import specific names from a template
    pub fn visitFromImport(self: *Self, node: *nodes.FromImport, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Evaluate template name expression
        const template_expr_val = try self.visitExpression(&node.template, frame, ctx);
        defer template_expr_val.deinit(self.allocator);

        // Convert to string
        const template_name_str = try template_expr_val.toString(self.allocator);
        defer self.allocator.free(template_name_str);

        // Load imported template
        const imported_template = try self.environment.getTemplate(template_name_str);

        // Create context for imported template
        var import_ctx: context.Context = undefined;
        if (node.with_context) {
            // Create new context with current context as parent
            const empty_vars = std.StringHashMap(context.Value).init(self.allocator);
            import_ctx = try context.Context.initWithParent(self.environment, empty_vars, template_name_str, ctx, self.allocator);
        } else {
            // Create empty context (no variables passed)
            const empty_vars = std.StringHashMap(context.Value).init(self.allocator);
            import_ctx = try context.Context.init(self.environment, empty_vars, template_name_str, self.allocator);
        }
        defer import_ctx.deinit();

        // Create template module
        const module = try self.allocator.create(runtime.TemplateModule);
        errdefer self.allocator.destroy(module);
        module.* = try runtime.TemplateModule.init(self.allocator, imported_template, &import_ctx);

        // Import specific names from module
        for (node.imports.items) |import_name| {
            // The parser stores import names as "name" or "name as alias"
            // Split on " as " to get original name and alias
            var name_parts = std.mem.splitSequence(u8, import_name, " as ");
            const original_name = name_parts.first();
            const alias_name = name_parts.next();
            const final_name = if (alias_name) |a| a else original_name;

            // Get value from module
            if (module.get(original_name)) |val| {
                // Copy value and store in context with final name (alias or original)
                const val_copy = try copyValueForImport(self.allocator, val);
                errdefer val_copy.deinit(self.allocator);

                const name_copy = try self.allocator.dupe(u8, final_name);
                errdefer self.allocator.free(name_copy);

                try ctx.set(name_copy, val_copy);
            } else {
                // Name not found in module - create undefined value
                const name_copy = try self.allocator.dupe(u8, final_name);
                errdefer self.allocator.free(name_copy);

                const original_name_copy = try self.allocator.dupe(u8, original_name);
                errdefer self.allocator.free(original_name_copy);

                const undefined_val = context.Value{ .undefined = value_mod.Undefined{
                    .name = original_name_copy,
                    .behavior = self.environment.undefined_behavior,
                } };

                try ctx.set(name_copy, undefined_val);
            }
        }

        // From imports don't produce output
        return try self.allocator.dupe(u8, "");
    }

    /// Helper to copy a value for import (uses deepCopy)
    fn copyValueForImport(allocator: std.mem.Allocator, val: context.Value) !context.Value {
        return try val.deepCopy(allocator);
    }

    /// Visit ExprStmt node - evaluate expression without producing output
    /// This is used by the `do` extension: {% do expr %}
    /// The expression is evaluated for its side effects (e.g., calling functions)
    pub fn visitExprStmt(self: *Self, node: *nodes.ExprStmt, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Evaluate the expression for its side effects
        var value = try self.visitExpression(@constCast(&node.node), frame, ctx);
        defer value.deinit(self.allocator);

        // Return empty string - do statements don't produce output
        return try self.allocator.dupe(u8, "");
    }

    /// Visit DebugStmt node - output debug information about context, filters, and tests
    /// This is used by the `debug` extension: {% debug %}
    pub fn visitDebugStmt(self: *Self, node: *nodes.DebugStmt, frame: *Frame, ctx: *context.Context) ![]const u8 {
        _ = node;
        _ = frame;

        var output = std.ArrayList(u8){};
        defer output.deinit(self.allocator);

        // Start output
        try output.appendSlice(self.allocator, "{'context': {");

        // Output context variables
        var first = true;
        var ctx_iter = ctx.vars.iterator();
        while (ctx_iter.next()) |entry| {
            if (!first) {
                try output.appendSlice(self.allocator, ", ");
            }
            first = false;

            try output.appendSlice(self.allocator, "'");
            try output.appendSlice(self.allocator, entry.key_ptr.*);
            try output.appendSlice(self.allocator, "': ");

            // Convert value to string representation
            const val_str = try entry.value_ptr.*.toString(self.allocator);
            defer self.allocator.free(val_str);
            try output.appendSlice(self.allocator, val_str);
        }

        try output.appendSlice(self.allocator, "}, 'filters': [");

        // Output filter names
        first = true;
        var filter_iter = self.environment.filters_map.iterator();
        while (filter_iter.next()) |entry| {
            if (!first) {
                try output.appendSlice(self.allocator, ", ");
            }
            first = false;

            try output.appendSlice(self.allocator, "'");
            try output.appendSlice(self.allocator, entry.key_ptr.*);
            try output.appendSlice(self.allocator, "'");
        }

        try output.appendSlice(self.allocator, "], 'tests': [");

        // Output test names
        first = true;
        var test_iter = self.environment.tests_map.iterator();
        while (test_iter.next()) |entry| {
            if (!first) {
                try output.appendSlice(self.allocator, ", ");
            }
            first = false;

            try output.appendSlice(self.allocator, "'");
            try output.appendSlice(self.allocator, entry.key_ptr.*);
            try output.appendSlice(self.allocator, "'");
        }

        try output.appendSlice(self.allocator, "]}");

        return try output.toOwnedSlice(self.allocator);
    }
};

/// Convenience function to compile a template
/// Note: Bytecode disabled for templates with macros/call blocks until bytecode supports them
pub fn compile(env: *environment.Environment, template: *nodes.Template, filename: ?[]const u8, allocator: std.mem.Allocator) !CompiledTemplate {
    var compiler = Compiler.init(env, filename, allocator);
    defer compiler.deinit();
    // Check if template uses features not supported by bytecode
    const use_bytecode = !templateHasUnsupportedFeatures(template);
    return try compiler.compile(template, use_bytecode);
}

/// Check if a template uses features not supported by bytecode
fn templateHasUnsupportedFeatures(template: *nodes.Template) bool {
    for (template.body.items) |stmt| {
        if (stmtHasUnsupportedFeatures(stmt)) return true;
    }
    return false;
}

fn stmtHasUnsupportedFeatures(stmt: *nodes.Stmt) bool {
    switch (stmt.tag) {
        .macro, .call, .call_block, .import, .from_import, .include, .extends => return true,
        .for_loop => {
            const for_stmt: *nodes.For = @ptrCast(@alignCast(stmt));
            for (for_stmt.body.items) |s| {
                if (stmtHasUnsupportedFeatures(s)) return true;
            }
            for (for_stmt.else_body.items) |s| {
                if (stmtHasUnsupportedFeatures(s)) return true;
            }
            return false;
        },
        .if_stmt => {
            const if_stmt: *nodes.If = @ptrCast(@alignCast(stmt));
            for (if_stmt.body.items) |s| {
                if (stmtHasUnsupportedFeatures(s)) return true;
            }
            for (if_stmt.else_body.items) |s| {
                if (stmtHasUnsupportedFeatures(s)) return true;
            }
            for (if_stmt.elif_bodies.items) |body| {
                for (body.items) |s| {
                    if (stmtHasUnsupportedFeatures(s)) return true;
                }
            }
            return false;
        },
        .block => {
            const block_stmt: *nodes.Block = @ptrCast(@alignCast(stmt));
            for (block_stmt.body.items) |s| {
                if (stmtHasUnsupportedFeatures(s)) return true;
            }
            return false;
        },
        .with => {
            const with_stmt: *nodes.With = @ptrCast(@alignCast(stmt));
            for (with_stmt.body.items) |s| {
                if (stmtHasUnsupportedFeatures(s)) return true;
            }
            return false;
        },
        .filter_block => {
            // Filter blocks are not supported by bytecode
            return true;
        },
        .set => {
            const set_stmt: *nodes.Set = @ptrCast(@alignCast(stmt));
            // Set blocks ({% set x %}...{% endset %}) are not supported by bytecode
            if (set_stmt.body != null) return true;
            return false;
        },
        else => return false,
    }
}

/// Compile a template with bytecode generation
pub fn compileWithBytecode(env: *environment.Environment, template: *nodes.Template, filename: ?[]const u8, allocator: std.mem.Allocator) !CompiledTemplate {
    var compiler = Compiler.init(env, filename, allocator);
    defer compiler.deinit();
    return try compiler.compile(template, true);
}

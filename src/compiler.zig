const std = @import("std");
const environment = @import("environment.zig");
const nodes = @import("nodes.zig");
const context = @import("context.zig");
const exceptions = @import("exceptions.zig");
const value_mod = @import("value.zig");
const runtime_types = @import("runtime_types.zig");
const bytecode_mod = @import("bytecode.zig");
const loop_context_mod = @import("loop_context.zig");
const value_pool = @import("value_pool.zig");
const render_arena = @import("render_arena.zig");
const semantics = @import("semantics.zig");
const filters_mod = @import("filters.zig");
const time = @import("time.zig");

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

    /// Get autoescape setting, checking parent frames (iterative walk — the
    /// chain depth is template-driven, so no recursion here)
    pub fn getAutoescape(self: *Self, env: *environment.Environment, template_name: ?[]const u8) bool {
        var frame: ?*Self = self;
        while (frame) |f| : (frame = f.parent) {
            if (f.autoescape) |ae| {
                return ae;
            }
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

    /// Resolve a variable, checking parent frames (iterative walk)
    /// Returns null if not found (caller should check context/environment)
    pub fn resolve(self: *Self, name: []const u8) ?Value {
        var frame: ?*Self = self;
        while (frame) |f| : (frame = f.parent) {
            if (f.variables.get(name)) |value| {
                return value;
            }
        }
        return null;
    }

    /// Resolve a loop attribute (e.g., loop.index) using the optimized loop
    /// context from this frame or the nearest parent (iterative walk)
    /// Returns null if not in a loop or attribute not found
    pub fn resolveLoopAttr(self: *Self, attr: []const u8) ?Value {
        var frame: ?*Self = self;
        while (frame) |f| : (frame = f.parent) {
            if (f.opt_loop) |opt| {
                return opt.resolveLoopAttr(attr);
            }
        }
        return null;
    }

    /// Get the optimized loop context from this frame or the nearest parent
    /// (iterative walk)
    pub fn getOptLoop(self: *Self) ?*OptimizedLoopContext {
        var frame: ?*Self = self;
        while (frame) |f| : (frame = f.parent) {
            if (f.opt_loop) |opt| {
                return opt;
            }
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
            errdefer value.deinit(self.allocator);
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
        // Reuse the thread-local arena across renders: steady-state renders
        // touch the backing allocator only for the returned result string.
        var scoped = try render_arena.acquire(allocator);
        defer scoped.release();

        const arena_alloc = scoped.allocator();

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

        // Reuse the thread-local arena across renders (see render()).
        var scoped = try render_arena.acquire(allocator);
        defer scoped.release();

        const arena_alloc = scoped.allocator();

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

    /// Render the template with options (timeout and debug tracing support)
    ///
    /// This method provides enhanced rendering with:
    /// - **Timeout enforcement**: Fails fast with TimeoutError if rendering exceeds timeout_ms
    /// - **Debug tracing**: Logs filter/test execution with timing when debug_trace is enabled
    ///
    /// Use this for debugging hangs and performance issues.
    ///
    /// # Arguments
    /// - `ctx`: Context containing variables and template state
    /// - `allocator`: Memory allocator for rendering
    /// - `options`: RenderOptions with timeout_ms and debug_trace settings
    ///
    /// # Returns
    /// Rendered template output as a string. The caller is responsible for freeing the memory.
    ///
    /// # Errors
    /// - `error.TimeoutError` - Rendering exceeded timeout_ms
    /// - Template rendering errors
    /// - `error.OutOfMemory` - Memory allocation failed
    ///
    /// # Example
    /// ```zig
    /// const result = try compiled.renderWithOptions(ctx, allocator, .{
    ///     .timeout_ms = 5000,  // 5 second timeout
    ///     .debug_trace = true, // Enable filter tracing
    /// });
    /// ```
    pub fn renderWithOptions(
        self: *Self,
        ctx: *context.Context,
        allocator: std.mem.Allocator,
        options: environment.RenderOptions,
    ) ![]const u8 {
        // Record start time for timeout checking
        const render_timer = time.Timer.start();

        // Store options in context for access during rendering
        ctx.render_options = options;

        // Log render start if tracing
        if (options.debug_trace) {
            std.debug.print("[RENDER] START template={s}\n", .{self.template.base.filename orelse "<string>"});
        }

        // Reuse the thread-local arena across renders (see render()).
        var scoped = try render_arena.acquire(allocator);
        defer scoped.release();

        const arena_alloc = scoped.allocator();

        // Check timeout before starting
        if (options.timeout_ms) |timeout| {
            const elapsed = render_timer.elapsed_ms();
            if (elapsed > timeout) {
                if (options.debug_trace) {
                    std.debug.print("[RENDER] TIMEOUT before start (elapsed={d}ms, limit={d}ms)\n", .{ elapsed, timeout });
                }
                return exceptions.TemplateError.TimeoutError;
            }
        }

        // Use bytecode if available, otherwise use AST interpretation
        const result = if (self.bytecode) |*bc| blk: {
            var vm = bytecode_mod.BytecodeVM.init(arena_alloc, bc, ctx);
            defer vm.deinit();
            break :blk try vm.execute();
        } else blk: {
            // Fall back to AST interpretation with timeout checking
            var compiler_inst = Compiler.init(self.environment, self.template.base.filename, arena_alloc);
            defer compiler_inst.deinit();

            // Store start time and timeout in compiler for periodic checking
            compiler_inst.render_timer = render_timer;
            compiler_inst.render_timeout_ms = options.timeout_ms;
            compiler_inst.debug_trace = options.debug_trace;

            var frame = Frame.init("root", null, arena_alloc);
            defer frame.deinit();

            break :blk try compiler_inst.visitTemplate(self.template, &frame, ctx);
        };

        // Final timeout check
        if (options.timeout_ms) |timeout| {
            const elapsed = render_timer.elapsed_ms();
            if (elapsed > timeout) {
                if (options.debug_trace) {
                    std.debug.print("[RENDER] TIMEOUT after completion (elapsed={d}ms, limit={d}ms)\n", .{ elapsed, timeout });
                }
                return exceptions.TemplateError.TimeoutError;
            }
        }

        if (options.debug_trace) {
            const elapsed = render_timer.elapsed_ms();
            std.debug.print("[RENDER] COMPLETE template={s} elapsed={d}ms\n", .{ self.template.base.filename orelse "<string>", elapsed });
        }

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

    // Debug/timeout fields (set by renderWithOptions)
    render_timer: ?time.Timer = null,
    render_timeout_ms: ?u64 = null,
    debug_trace: bool = false,

    const Self = @This();

    /// Initialize a new compiler
    pub fn init(env: *environment.Environment, filename: ?[]const u8, allocator: std.mem.Allocator) Self {
        return Self{
            .environment = env,
            .filename = filename,
            .allocator = allocator,
            .frames = std.ArrayList(*Frame).empty,
            .current_frame = null,
            .render_timer = null,
            .render_timeout_ms = null,
            .debug_trace = false,
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
        const template_ref = try ctx.allocator.create(runtime_types.TemplateReference);
        template_ref.* = runtime_types.TemplateReference.init(ctx.allocator, node, ctx, self);
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

        // Child blocks go at the front of the stack (index 0), including
        // overrides nested inside parent control-flow or block bodies.
        try self.registerBlocks(ctx, node.body.items[body_start_idx..], true, 0);

        // Now process the template body
        // In Jinja2, when a template extends:
        // - Parent template's body (non-block statements) are NOT rendered
        // - Only blocks are inherited from parent
        // - Child template's body IS rendered
        // - Blocks in child override parent blocks
        // - If child doesn't define a block, parent's block is used when referenced
        var output = std.ArrayList(u8).empty;
        defer output.deinit(self.allocator);

        // Extending templates render the root ancestor's layout. Block dispatch
        // below selects the most-derived registered override in that layout.
        var render_template = node;
        if (extends_processed) {
            while (render_template.parent) |parent| render_template = parent;
        }

        for (render_template.body.items) |stmt| {
            if (stmt.tag == .extends) continue;
            // Blocks are executed when encountered in body
            const stmt_output = try self.visitStatement(stmt, frame, ctx);
            defer self.allocator.free(stmt_output);
            try output.appendSlice(self.allocator, stmt_output);
        }

        return try output.toOwnedSlice(self.allocator);
    }

    fn registerBlocks(self: *Self, ctx: *context.Context, statements: []const *nodes.Stmt, prepend: bool, depth: usize) !void {
        if (depth >= 256) return exceptions.TemplateError.RuntimeError;
        for (statements) |stmt| {
            switch (stmt.tag) {
                .block => {
                    const block = @as(*nodes.Block, @ptrCast(@alignCast(stmt)));
                    if (prepend) try ctx.prependBlock(block.name, block) else try ctx.addBlock(block.name, block);
                    try self.registerBlocks(ctx, block.body.items, prepend, depth + 1);
                },
                .for_loop => {
                    const for_loop = @as(*nodes.For, @ptrCast(@alignCast(stmt)));
                    try self.registerBlocks(ctx, for_loop.body.items, prepend, depth + 1);
                    try self.registerBlocks(ctx, for_loop.else_body.items, prepend, depth + 1);
                },
                .if_stmt => {
                    const if_stmt = @as(*nodes.If, @ptrCast(@alignCast(stmt)));
                    try self.registerBlocks(ctx, if_stmt.body.items, prepend, depth + 1);
                    for (if_stmt.elif_bodies.items) |body| try self.registerBlocks(ctx, body.items, prepend, depth + 1);
                    try self.registerBlocks(ctx, if_stmt.else_body.items, prepend, depth + 1);
                },
                .with => try self.registerBlocks(ctx, @as(*nodes.With, @ptrCast(@alignCast(stmt))).body.items, prepend, depth + 1),
                .filter_block => try self.registerBlocks(ctx, @as(*nodes.FilterBlock, @ptrCast(@alignCast(stmt))).body.items, prepend, depth + 1),
                .call_block => try self.registerBlocks(ctx, @as(*nodes.CallBlock, @ptrCast(@alignCast(stmt))).body.items, prepend, depth + 1),
                else => {},
            }
        }
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
        var output = std.ArrayList(u8).empty;
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

    /// Check if timeout has been exceeded (for renderWithOptions)
    /// Returns TimeoutError if timeout exceeded, otherwise null
    fn checkTimeout(self: *Self) !void {
        if (self.render_timeout_ms) |timeout| {
            const timer = self.render_timer orelse return;
            const elapsed = timer.elapsed_ms();
            if (elapsed > timeout) {
                if (self.debug_trace) {
                    std.debug.print("[TIMEOUT] Execution timeout exceeded (elapsed={d}ms, limit={d}ms)\n", .{ elapsed, timeout });
                }
                return exceptions.TemplateError.TimeoutError;
            }
        }
    }

    /// Visit Filter node - apply filter to expression
    /// Optimized hot path for filter execution
    /// Includes debug tracing and timeout checking when enabled via renderWithOptions
    pub fn visitFilter(self: *Self, node: *nodes.FilterExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // Check timeout before filter execution
        try self.checkTimeout();

        // Debug trace: log filter entry
        const filter_timer: ?time.Timer = if (self.debug_trace) .start() else null;
        if (self.debug_trace) {
            std.debug.print("[FILTER] {s} args={d} kwargs={d} ENTER\n", .{ node.name, node.args.items.len, node.kwargs.count() });
        }

        // Evaluate base expression
        var base_val = try self.visitExpression(&node.node, frame, ctx);
        defer base_val.deinit(self.allocator);

        // Optimize: use stack-allocated array for small argument counts
        // For larger counts, fall back to ArrayList
        const max_stack_args = 8;
        var stack_args: [max_stack_args]value_mod.Value = undefined;
        var args: []value_mod.Value = undefined;
        var args_allocated = false;
        var args_list = std.ArrayList(value_mod.Value).empty;
        var initialized_args: usize = 0;
        defer {
            if (args_allocated) {
                for (args_list.items[0..initialized_args]) |*arg| arg.deinit(self.allocator);
                args_list.deinit(self.allocator);
            } else {
                for (stack_args[0..initialized_args]) |*arg| arg.deinit(self.allocator);
            }
        }

        if (node.args.items.len <= max_stack_args) {
            // Use stack-allocated array
            args = stack_args[0..node.args.items.len];
            for (node.args.items, 0..) |*arg_expr, i| {
                args[i] = try self.visitExpression(arg_expr, frame, ctx);
                initialized_args += 1;
            }
        } else {
            // Use ArrayList for larger argument lists
            args_allocated = true;
            try args_list.ensureTotalCapacity(self.allocator, node.args.items.len);
            for (node.args.items) |*arg_expr| {
                const arg_val = try self.visitExpression(arg_expr, frame, ctx);
                args_list.appendAssumeCapacity(arg_val);
                initialized_args += 1;
            }
            args = args_list.items;
        }

        // Evaluate kwargs
        var kwargs = std.StringHashMap(value_mod.Value).init(self.allocator);
        defer {
            var iter = kwargs.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit(self.allocator);
            }
            kwargs.deinit();
        }
        var kwarg_iter = node.kwargs.iterator();
        while (kwarg_iter.next()) |entry| {
            var kwarg_expr = entry.value_ptr.*;
            const kwarg_val = try self.visitExpression(&kwarg_expr, frame, ctx);
            try kwargs.put(entry.key_ptr.*, kwarg_val);
        }

        // Get filter from environment
        const filter = self.environment.getFilter(node.name) orelse {
            if (self.debug_trace) {
                std.debug.print("[FILTER] {s} ERROR: filter not found\n", .{node.name});
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
                    &kwargs,
                    ctx,
                    self.environment,
                );
            } else {
                // Fall back to sync function if async not available
                break :blk try filter.func(
                    self.allocator,
                    base_val,
                    args,
                    &kwargs,
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
                &kwargs,
                ctx,
                self.environment,
            );
        };

        // Debug trace: log filter exit with timing
        if (self.debug_trace) {
            const filter_elapsed = filter_timer.?.elapsed_ms();
            std.debug.print("[FILTER] {s} EXIT ({d}ms)\n", .{ node.name, filter_elapsed });
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

    fn attributeFromUndefined(self: *Self, undefined_value: value_mod.Undefined, name: []const u8) !value_mod.Value {
        undefined_value.logAccess("getAttribute");
        if (undefined_value.behavior == .strict) return exceptions.TemplateError.UndefinedError;
        return semantics.undefinedValue(self.allocator, name, undefined_value.behavior, undefined_value.logger);
    }

    fn attributeFromDict(self: *Self, dict: *value_mod.Dict, name: []const u8) !value_mod.Value {
        if (dict.get(name)) |value| return value.deepCopy(self.allocator);
        return semantics.undefinedValue(self.allocator, name, self.environment.undefined_behavior, null);
    }

    fn attributeFromCustom(self: *Self, custom: *value_mod.CustomObject, name: []const u8) !value_mod.Value {
        if (try custom.getField(name, self.allocator)) |field| return field;
        if (try custom.getMethod(name, self.allocator)) |method| {
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const callable = try self.allocator.create(value_mod.Callable);
            callable.* = .{
                .name = owned_name,
                .is_async = false,
                .callable_type = .function,
                .func = method,
            };
            return .{ .callable = callable };
        }
        return semantics.undefinedValue(self.allocator, name, self.environment.undefined_behavior, null);
    }

    fn attributeFromValue(self: *Self, object: value_mod.Value, name: []const u8) !value_mod.Value {
        return switch (object) {
            .dict => |dict| self.attributeFromDict(dict, name),
            .undefined => |undefined_value| self.attributeFromUndefined(undefined_value, name),
            .custom => |custom| self.attributeFromCustom(custom, name),
            .list,
            .string,
            .integer,
            .float,
            .boolean,
            .null,
            .markup,
            .async_result,
            .callable,
            => exceptions.TemplateError.AttributeError,
        };
    }

    /// Visit Getattr node - access object attribute (obj.attr)
    pub fn visitGetattr(self: *Self, node: *nodes.Getattr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        if (node.node == .name and std.mem.eql(u8, node.node.name.name, "loop")) {
            if (frame.resolveLoopAttr(node.attr)) |value| return value;
        }

        var object = try self.visitExpression(&node.node, frame, ctx);
        defer object.deinit(self.allocator);
        if (self.environment.sandboxed) {
            const sandbox_mod = @import("sandbox.zig");
            if (!sandbox_mod.isSafeAttribute(object, node.attr)) return exceptions.TemplateError.SecurityError;
        }
        return self.attributeFromValue(object, node.attr);
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

        return semantics.getItem(self.allocator, obj_val, index_val, self.environment.undefined_behavior);
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
        errdefer result_list.deinit(self.allocator);
        try result_list.items.ensureTotalCapacity(self.allocator, list.items.items.len);

        // Collect items according to slice
        var i = actual_start;
        if (step > 0) {
            while (i < actual_stop) : (i += step) {
                if (i >= 0 and i < len) {
                    const item = list.items.items[@intCast(i)];
                    const copied = try item.deepCopy(self.allocator);
                    result_list.items.appendAssumeCapacity(copied);
                }
            }
        } else {
            while (i > actual_stop) : (i += step) {
                if (i >= 0 and i < len) {
                    const item = list.items.items[@intCast(i)];
                    const copied = try item.deepCopy(self.allocator);
                    result_list.items.appendAssumeCapacity(copied);
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
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);
        try result.ensureTotalCapacity(self.allocator, str.len);

        var i = actual_start;
        if (step > 0) {
            while (i < actual_stop) : (i += step) {
                if (i >= 0 and i < len) {
                    result.appendAssumeCapacity(str[@intCast(i)]);
                }
            }
        } else {
            while (i > actual_stop) : (i += step) {
                if (i >= 0 and i < len) {
                    result.appendAssumeCapacity(str[@intCast(i)]);
                }
            }
        }

        return value_mod.Value{ .string = try result.toOwnedSlice(self.allocator) };
    }

    /// Visit BinExpr node - evaluate binary expression
    pub fn visitBinExpr(self: *Self, node: *nodes.BinExpr, frame: *Frame, ctx: *context.Context) (exceptions.TemplateError || std.mem.Allocator.Error || value_mod.CallError || error{ Overflow, InvalidCharacter })!value_mod.Value {
        var left_val = try self.visitExpression(&node.left, frame, ctx);
        defer left_val.deinit(self.allocator);

        // Jinja boolean operators return booleans in this implementation, but
        // must still short-circuit so guarded StrictUndefined names and helper
        // calls are never evaluated eagerly.
        if (node.op == .AND and !(try left_val.isTruthy())) return .{ .boolean = false };
        if (node.op == .OR and try left_val.isTruthy()) return .{ .boolean = true };

        var right_val = try self.visitExpression(&node.right, frame, ctx);
        defer right_val.deinit(self.allocator);
        // Check for 'not in' - if left is a unary NOT with IN, handle specially
        // Actually, we handle 'not in' by checking if the left expression is a unary NOT
        // For now, we'll handle IN and check for negation in a different way
        // The parser creates a BinExpr with IN, and we need to check if it was negated
        // Let's handle it in the parser by creating a special marker, or handle it here

        const op = semantics.BinaryOp.fromTokenKind(node.op) orelse
            return value_mod.Value{ .string = try self.allocator.dupe(u8, "") };
        return semantics.evalBinary(self.allocator, left_val, right_val, op);
    }

    fn visitTestSubject(self: *Self, node: *nodes.TestExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        const inspects_definition = std.mem.eql(u8, node.name, "defined") or std.mem.eql(u8, node.name, "undefined");
        if (!inspects_definition or node.node != .name) return self.visitExpression(&node.node, frame, ctx);

        const name = node.node.name.name;
        if (frame.resolve(name)) |resolved| return resolved.deepCopy(self.allocator);
        return ctx.resolve(name).deepCopy(self.allocator);
    }

    /// Visit TestExpr node - evaluate test expression (value is test)
    /// Includes debug tracing when enabled via renderWithOptions
    pub fn visitTest(self: *Self, node: *nodes.TestExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        // Check timeout before test execution
        try self.checkTimeout();

        // Debug trace: log test entry
        const test_timer: ?time.Timer = if (self.debug_trace) .start() else null;
        if (self.debug_trace) {
            std.debug.print("[TEST] {s} args={d} ENTER\n", .{ node.name, node.args.items.len });
        }

        // `is defined` and `is undefined` must be able to inspect a missing
        // name even under StrictUndefined; normal name evaluation raises.
        var val = try self.visitTestSubject(node, frame, ctx);
        defer val.deinit(self.allocator);

        // Evaluate test arguments
        var args = std.ArrayList(value_mod.Value).empty;
        defer {
            for (args.items) |*arg| {
                arg.deinit(self.allocator);
            }
            args.deinit(self.allocator);
        }
        try args.ensureTotalCapacity(self.allocator, node.args.items.len);

        for (node.args.items) |*arg_expr| {
            const arg_val = try self.visitExpression(arg_expr, frame, ctx);
            args.appendAssumeCapacity(arg_val);
        }

        // Look up test function from environment
        const test_func = self.environment.getTest(node.name) orelse {
            if (self.debug_trace) {
                std.debug.print("[TEST] {s} ERROR: test not found\n", .{node.name});
            }
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

        // Debug trace: log test exit with timing
        if (self.debug_trace) {
            const test_elapsed = test_timer.?.elapsed_ms();
            std.debug.print("[TEST] {s} result={} EXIT ({d}ms)\n", .{ node.name, result, test_elapsed });
        }

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
        errdefer list_ptr.deinit(self.allocator);
        try list_ptr.items.ensureTotalCapacity(self.allocator, node.elements.items.len);

        for (node.elements.items) |*elem| {
            const val = try self.visitExpression(elem, frame, ctx);
            list_ptr.items.appendAssumeCapacity(val);
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

    // Binary expression semantics live in semantics.zig so AST, bytecode, and
    // optimizer paths cannot drift.
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

    fn primaryLoopTargetName(target: nodes.Expression) ?[]const u8 {
        return switch (target) {
            .name => |name| name.name,
            .list_literal => |targets| if (targets.elements.items.len > 0 and targets.elements.items[0] == .name)
                targets.elements.items[0].name.name
            else
                null,
            else => null,
        };
    }

    fn bindLoopTarget(self: *Self, target: nodes.Expression, item: value_mod.Value, frame: *Frame) !void {
        switch (target) {
            .name => |name| try frame.set(name.name, try item.deepCopy(self.allocator)),
            .list_literal => |targets| {
                if (item != .list or item.list.items.items.len != targets.elements.items.len) {
                    return exceptions.TemplateError.RuntimeError;
                }
                for (targets.elements.items, item.list.items.items) |target_expr, target_value| {
                    if (target_expr != .name) return exceptions.TemplateError.RuntimeError;
                    try frame.set(target_expr.name.name, try target_value.deepCopy(self.allocator));
                }
            },
            else => return exceptions.TemplateError.RuntimeError,
        }
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

        const source_items = try semantics.collectIterationItems(self.allocator, iter_val);
        defer source_items.deinit(self.allocator);

        const items = if (node.test_expr) |*test_expr| filtered: {
            const filtered_items = try self.allocator.create(value_mod.List);
            filtered_items.* = value_mod.List.init(self.allocator);
            errdefer filtered_items.deinit(self.allocator);
            try filtered_items.items.ensureTotalCapacity(self.allocator, source_items.items.items.len);

            var filter_frame = Frame.init("for_filter", frame, self.allocator);
            defer filter_frame.deinit();
            for (source_items.items.items) |item| {
                try self.bindLoopTarget(node.target, item, &filter_frame);
                var keep = try self.visitExpression(test_expr, &filter_frame, ctx);
                defer keep.deinit(self.allocator);
                if (try keep.isTruthy()) filtered_items.items.appendAssumeCapacity(try item.deepCopy(self.allocator));
            }
            break :filtered filtered_items;
        } else source_items;
        defer if (items != source_items) items.deinit(self.allocator);

        // Handle empty iterable - execute else clause
        if (items.items.items.len == 0) {
            var output = std.ArrayList(u8).empty;
            defer output.deinit(self.allocator);

            for (node.else_body.items) |stmt| {
                const stmt_output = try self.visitStatement(stmt, frame, ctx);
                defer self.allocator.free(stmt_output);
                try output.appendSlice(self.allocator, stmt_output);
            }
            return try output.toOwnedSlice(self.allocator);
        }

        // Extract target variable name from Expression
        const target_name = primaryLoopTargetName(node.target) orelse return exceptions.TemplateError.RuntimeError;

        // OPTIMIZATION: Create OptimizedLoopContext ONCE (stack-allocated)
        // This replaces the per-iteration Dict creation
        var opt_loop = OptimizedLoopContext.init(
            items.items.items,
            target_name,
            frame.getOptLoop(), // Parent loop for depth tracking
        );

        // Create new frame for loop (minimal - just for scoping)
        var loop_frame = Frame.init("for_loop", frame, self.allocator);
        defer loop_frame.deinit();

        // OPTIMIZATION: Set opt_loop pointer instead of creating Dict per iteration
        loop_frame.opt_loop = &opt_loop;

        var output = std.ArrayList(u8).empty;
        defer output.deinit(self.allocator);

        // Execute loop body
        // NOTE: We still deep copy the loop variable per iteration for now
        // The main optimization is avoiding Dict creation for loop.index etc.
        while (opt_loop.hasMore()) {
            // Check timeout at each iteration to detect infinite loops
            try self.checkTimeout();

            // Set loop variable (deep copy - still needed for proper ownership)
            const current_item = opt_loop.getCurrentItem();
            try self.bindLoopTarget(node.target, current_item, &loop_frame);

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

        var output = std.ArrayList(u8).empty;
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
    fn callAttributeSpecial(self: *Self, node: *nodes.CallExpr, frame: *Frame, ctx: *context.Context) !?value_mod.Value {
        if (node.func != .getattr) return null;
        const attribute = node.func.getattr;
        if (attribute.node == .name and std.mem.eql(u8, attribute.node.name.name, "loop")) {
            if (std.mem.eql(u8, attribute.attr, "cycle")) return try self.evaluateLoopCycle(node, frame, ctx);
            if (std.mem.eql(u8, attribute.attr, "changed")) return try self.evaluateLoopChanged(node, frame, ctx);
        }
        if (attribute.node == .name) {
            if (ctx.getImportedModule(attribute.node.name.name)) |module_handle| {
                const module = @as(*runtime_types.TemplateModule, @ptrCast(@alignCast(module_handle)));
                if (module.getMacro(attribute.attr)) |macro_handle| {
                    const macro = @as(*nodes.Macro, @ptrCast(@alignCast(macro_handle)));
                    return .{ .string = try self.callMacro(macro, node.args.items, node.kwargs, frame, ctx, null) };
                }
            }
        }

        return try self.callMethodAsFilter(node, attribute, frame, ctx);
    }

    /// Method calls on plain values behave like filter application:
    /// 'a,b'.split(',') is 'a,b'|split(','). This mirrors the bytecode VM,
    /// which compiles attribute calls to APPLY_FILTER. Dicts and custom
    /// custom objects are excluded because they may carry real callable
    /// attributes. Dicts use the fallback only for their standard items().
    fn callMethodAsFilter(self: *Self, node: *nodes.CallExpr, attribute: *nodes.Getattr, frame: *Frame, ctx: *context.Context) !?value_mod.Value {
        const filter = self.environment.getFilter(attribute.attr) orelse return null;

        var object = try self.visitExpression(&attribute.node, frame, ctx);
        defer object.deinit(self.allocator);
        if (object == .custom) return null;
        if (object == .dict and !std.mem.eql(u8, attribute.attr, "items")) return null;

        var args = std.ArrayList(value_mod.Value).empty;
        defer {
            for (args.items) |*argument| argument.deinit(self.allocator);
            args.deinit(self.allocator);
        }
        try args.ensureTotalCapacity(self.allocator, node.args.items.len);
        for (node.args.items) |*argument| {
            args.appendAssumeCapacity(try self.visitExpression(argument, frame, ctx));
        }

        var kwargs = std.StringHashMap(value_mod.Value).init(self.allocator);
        defer {
            var iterator = kwargs.iterator();
            while (iterator.next()) |entry| entry.value_ptr.*.deinit(self.allocator);
            kwargs.deinit();
        }
        try kwargs.ensureTotalCapacity(@intCast(node.kwargs.count()));
        var iterator = node.kwargs.iterator();
        while (iterator.next()) |entry| {
            var expression = entry.value_ptr.*;
            kwargs.putAssumeCapacity(entry.key_ptr.*, try self.visitExpression(&expression, frame, ctx));
        }

        return try filter.func(self.allocator, object, args.items, &kwargs, ctx, self.environment);
    }

    fn callNamedSpecial(self: *Self, name: []const u8, node: *nodes.CallExpr, frame: *Frame, ctx: *context.Context) !?value_mod.Value {
        if (std.mem.eql(u8, name, "super")) {
            const block = frame.current_block orelse return exceptions.TemplateError.RuntimeError;
            return .{ .string = try self.renderBlock(block.name, block, frame, ctx) };
        }
        if (std.mem.eql(u8, name, "caller")) {
            const caller = frame.resolve("caller") orelse return exceptions.TemplateError.RuntimeError;
            return try caller.deepCopy(self.allocator);
        }
        const macro_handle = ctx.getMacro(name) orelse return null;
        const macro = @as(*nodes.Macro, @ptrCast(@alignCast(macro_handle)));
        return .{ .string = try self.callMacro(macro, node.args.items, node.kwargs, frame, ctx, null) };
    }

    fn callFilterAsFunction(self: *Self, filter: *filters_mod.Filter, node: *nodes.CallExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        var args = std.ArrayList(value_mod.Value).empty;
        defer {
            for (args.items) |*argument| argument.deinit(self.allocator);
            args.deinit(self.allocator);
        }
        try args.ensureTotalCapacity(self.allocator, node.args.items.len);
        for (node.args.items) |*argument| {
            args.appendAssumeCapacity(try self.visitExpression(argument, frame, ctx));
        }

        var kwargs = std.StringHashMap(value_mod.Value).init(self.allocator);
        defer {
            var iterator = kwargs.iterator();
            while (iterator.next()) |entry| entry.value_ptr.*.deinit(self.allocator);
            kwargs.deinit();
        }
        try kwargs.ensureTotalCapacity(@intCast(node.kwargs.count()));
        var iterator = node.kwargs.iterator();
        while (iterator.next()) |entry| {
            var expression = entry.value_ptr.*;
            kwargs.putAssumeCapacity(entry.key_ptr.*, try self.visitExpression(&expression, frame, ctx));
        }

        var empty = value_mod.Value{ .string = try self.allocator.dupe(u8, "") };
        defer empty.deinit(self.allocator);
        return filter.func(self.allocator, empty, args.items, &kwargs, ctx, self.environment);
    }

    fn callGlobal(self: *Self, global: value_mod.Value, node: *nodes.CallExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        if (global != .callable) return try global.deepCopy(self.allocator);
        const callable = global.callable;

        var args = std.ArrayList(value_mod.Value).empty;
        defer {
            for (args.items) |*argument| argument.deinit(self.allocator);
            args.deinit(self.allocator);
        }
        try args.ensureTotalCapacity(self.allocator, node.args.items.len + @intFromBool(node.kwargs.count() > 0));
        for (node.args.items) |*argument| {
            args.appendAssumeCapacity(try self.visitExpression(argument, frame, ctx));
        }

        if (node.kwargs.count() > 0) {
            const kwargs = try self.allocator.create(value_mod.Dict);
            kwargs.* = value_mod.Dict.init(self.allocator);
            errdefer kwargs.deinit(self.allocator);
            try kwargs.map.ensureTotalCapacity(@intCast(node.kwargs.count()));

            var iterator = node.kwargs.iterator();
            while (iterator.next()) |entry| {
                var expression = entry.value_ptr.*;
                try kwargs.set(entry.key_ptr.*, try self.visitExpression(&expression, frame, ctx));
            }
            args.appendAssumeCapacity(.{ .dict = kwargs });
        }

        const function = callable.func orelse {
            const callable_name = callable.name orelse "<anonymous>";
            return .{ .undefined = .{
                .name = try self.allocator.dupe(u8, callable_name),
                .behavior = ctx.environment.undefined_behavior,
            } };
        };
        return function(self.allocator, args.items, ctx, self.environment) catch |err| switch (err) {
            error.RuntimeError, error.UndefinedError, error.InvalidArgument, error.TypeError, error.NotCallable => exceptions.TemplateError.RuntimeError,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    /// Visit CallExpr node - evaluate function call expression
    pub fn visitCallExpr(self: *Self, node: *nodes.CallExpr, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        if (try self.callAttributeSpecial(node, frame, ctx)) |result| return result;
        // Macro names live in the context macro table rather than as ordinary
        // variables. Resolve them before evaluating the callee so strict
        // undefined mode does not reject a valid macro invocation.
        if (node.func == .name) {
            if (try self.callNamedSpecial(node.func.name.name, node, frame, ctx)) |result| return result;
        }

        var function_value = try self.visitExpression(&node.func, frame, ctx);
        defer function_value.deinit(self.allocator);
        if (self.environment.sandboxed) {
            const sandbox_mod = @import("sandbox.zig");
            if (!sandbox_mod.isSafeCallable(function_value)) return exceptions.TemplateError.SecurityError;
        }

        var owned_name: ?[]const u8 = null;
        defer if (owned_name) |name| self.allocator.free(name);
        const name = switch (node.func) {
            .name => |function_name| function_name.name,
            else => blk: {
                owned_name = try function_value.toString(self.allocator);
                break :blk owned_name.?;
            },
        };

        if (try self.callNamedSpecial(name, node, frame, ctx)) |result| return result;
        if (self.environment.getFilter(name)) |filter| {
            return try self.callFilterAsFunction(filter, node, frame, ctx);
        }
        if (self.environment.getGlobal(name)) |global| {
            return try self.callGlobal(global, node, frame, ctx);
        }
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
            const val_hash = arg_val.hash();
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
                const macro_handle = ctx.getMacro(name_str) orelse {
                    return exceptions.TemplateError.RuntimeError;
                };
                const macro = @as(*nodes.Macro, @ptrCast(@alignCast(macro_handle)));
                return try self.callMacro(macro, node.args.items, node.kwargs, frame, ctx, null);
            },
        };

        // Look up macro by name
        const macro_handle = ctx.getMacro(macro_name) orelse {
            return exceptions.TemplateError.RuntimeError;
        };
        const macro = @as(*nodes.Macro, @ptrCast(@alignCast(macro_handle)));

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
        var result = std.ArrayList(u8).empty;
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
        return semantics.contextToValue(self.allocator, ctx);
    }

    /// Visit DerivedContextReference node - get current context including locals
    pub fn visitDerivedContextReference(self: *Self, node: *nodes.DerivedContextReference, frame: *Frame, ctx: *context.Context) !value_mod.Value {
        _ = node;
        var result = try semantics.contextToValue(self.allocator, ctx);
        errdefer result.deinit(self.allocator);
        var frame_variables = frame.variables.iterator();
        while (frame_variables.next()) |entry| {
            try result.dict.set(entry.key_ptr.*, try entry.value_ptr.*.deepCopy(self.allocator));
        }
        return result;
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
        const macro_handle = ctx.getMacro(macro_name) orelse {
            return exceptions.TemplateError.RuntimeError;
        };
        const macro = @as(*nodes.Macro, @ptrCast(@alignCast(macro_handle)));

        // Render call block body to pass as caller
        var caller_body = std.ArrayList(u8).empty;
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
        var args = std.ArrayList(nodes.Expression).empty;
        defer args.deinit(self.allocator);
        var kwargs = std.StringHashMap(nodes.Expression).init(self.allocator);
        defer kwargs.deinit();

        if (node.call_expr == .call_expr) {
            const call = node.call_expr.call_expr;
            try args.ensureTotalCapacity(self.allocator, call.args.items.len);
            for (call.args.items) |arg| {
                args.appendAssumeCapacity(arg);
            }
            var kw_iter = call.kwargs.iterator();
            while (kw_iter.next()) |entry| {
                try kwargs.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        return try self.callMacro(macro, args.items, kwargs, frame, ctx, caller_value);
    }

    fn bindMacroParameters(
        self: *Self,
        macro: *nodes.Macro,
        args: []nodes.Expression,
        kwargs: std.StringHashMap(nodes.Expression),
        source_frame: *Frame,
        macro_frame: *Frame,
        ctx: *context.Context,
        used_kwargs: *std.StringHashMap(void),
    ) !void {
        try used_kwargs.ensureTotalCapacity(@intCast(macro.args.items.len));
        for (macro.args.items, 0..) |macro_arg, index| {
            var argument: ?value_mod.Value = null;
            errdefer if (argument) |value| value.deinit(self.allocator);

            if (index < args.len) argument = try self.visitExpression(&args[index], source_frame, ctx);
            if (kwargs.get(macro_arg.name)) |keyword_expression| {
                if (argument) |value| value.deinit(self.allocator);
                var expression = keyword_expression;
                argument = try self.visitExpression(&expression, source_frame, ctx);
                used_kwargs.putAssumeCapacity(macro_arg.name, {});
            }
            if (argument == null) {
                const default_expression = macro_arg.default_value orelse return exceptions.TemplateError.RuntimeError;
                var expression = default_expression;
                argument = try self.visitExpression(&expression, source_frame, ctx);
            }

            try macro_frame.set(macro_arg.name, argument.?);
            argument = null;
        }
    }

    fn bindMacroVarargs(
        self: *Self,
        macro: *nodes.Macro,
        args: []nodes.Expression,
        source_frame: *Frame,
        macro_frame: *Frame,
        ctx: *context.Context,
    ) !void {
        const expected = macro.args.items.len;
        if (!macro.catch_varargs) {
            if (args.len > expected) return exceptions.TemplateError.RuntimeError;
            return;
        }

        const extra_count = if (args.len > expected) args.len - expected else 0;
        const varargs = try self.allocator.create(value_mod.List);
        varargs.* = value_mod.List.init(self.allocator);
        errdefer varargs.deinit(self.allocator);
        try varargs.items.ensureTotalCapacity(self.allocator, extra_count);
        if (args.len > expected) {
            for (args[expected..]) |*expression| {
                varargs.items.appendAssumeCapacity(try self.visitExpression(expression, source_frame, ctx));
            }
        }
        try macro_frame.set("varargs", .{ .list = varargs });
    }

    fn bindMacroKwargs(
        self: *Self,
        macro: *nodes.Macro,
        kwargs: std.StringHashMap(nodes.Expression),
        used_kwargs: *const std.StringHashMap(void),
        source_frame: *Frame,
        macro_frame: *Frame,
        ctx: *context.Context,
    ) !void {
        if (!macro.catch_kwargs) {
            var iterator = kwargs.iterator();
            while (iterator.next()) |entry| {
                if (!used_kwargs.contains(entry.key_ptr.*)) return exceptions.TemplateError.RuntimeError;
            }
            return;
        }

        const extras = try self.allocator.create(value_mod.Dict);
        extras.* = value_mod.Dict.init(self.allocator);
        errdefer extras.deinit(self.allocator);
        try extras.map.ensureTotalCapacity(@intCast(kwargs.count()));
        var iterator = kwargs.iterator();
        while (iterator.next()) |entry| {
            if (used_kwargs.contains(entry.key_ptr.*)) continue;
            try extras.set(entry.key_ptr.*, try self.visitExpression(@constCast(entry.value_ptr), source_frame, ctx));
        }
        try macro_frame.set("kwargs", .{ .dict = extras });
    }

    fn renderStatements(self: *Self, statements: []*nodes.Stmt, frame: *Frame, ctx: *context.Context) ![]const u8 {
        var output = std.ArrayList(u8).empty;
        defer output.deinit(self.allocator);
        for (statements) |statement| {
            const statement_output = try self.visitStatement(statement, frame, ctx);
            defer self.allocator.free(statement_output);
            try output.appendSlice(self.allocator, statement_output);
        }
        return output.toOwnedSlice(self.allocator);
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
        var macro_frame = Frame.init("macro", frame, self.allocator);
        defer macro_frame.deinit();
        var used_kwargs = std.StringHashMap(void).init(self.allocator);
        defer used_kwargs.deinit();

        try self.bindMacroParameters(macro, args, kwargs, frame, &macro_frame, ctx, &used_kwargs);
        try self.bindMacroVarargs(macro, args, frame, &macro_frame, ctx);
        try self.bindMacroKwargs(macro, kwargs, &used_kwargs, frame, &macro_frame, ctx);
        if (caller) |caller_value| {
            try macro_frame.set("caller", try caller_value.deepCopy(self.allocator));
        }
        return self.renderStatements(macro.body.items, &macro_frame, ctx);
    }

    /// Visit Set node - assign variable
    /// Supports both simple assignment and namespace attribute assignment ({% set ns.attr = val %})
    pub fn visitSet(self: *Self, node: *nodes.Set, frame: *Frame, ctx: *context.Context) ![]const u8 {
        var value: value_mod.Value = undefined;

        if (node.body) |*body| {
            // Set block variant - render body to get value
            var body_output = std.ArrayList(u8).empty;
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

        // Check if this is namespace attribute assignment ({% set ns.attr = val %})
        if (node.target_attr) |attr| {
            // Namespace attribute assignment
            // 1. Get the namespace dict - walk up frame hierarchy first
            var ns_value: ?Value = null;
            var current_frame: ?*Frame = frame;
            while (current_frame) |f| {
                if (f.variables.get(node.name)) |v| {
                    ns_value = v;
                    break;
                }
                current_frame = f.parent;
            }

            // If not in any frame, try context (for globals)
            if (ns_value == null) {
                const ctx_val = ctx.resolve(node.name);
                if (ctx_val != .undefined) {
                    ns_value = ctx_val;
                }
            }

            if (ns_value) |nv| {
                if (nv == .dict) {
                    // 2. Set the attribute on the namespace dict
                    // The dict is stored by pointer, so modifications affect the original
                    try nv.dict.set(attr, value);
                    // Note: value is moved into the dict, don't deinit it
                } else {
                    // Not a dict/namespace - error
                    value.deinit(self.allocator);
                    return exceptions.TemplateError.RuntimeError;
                }
            } else {
                // Namespace variable not found - error
                value.deinit(self.allocator);
                return exceptions.TemplateError.UndefinedError;
            }
        } else {
            // Simple variable assignment
            // Set variable in frame (deep copy)
            const value_copy = try value.deepCopy(self.allocator);
            defer value.deinit(self.allocator);
            try frame.set(node.name, value_copy);
        }

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
        var output = std.ArrayList(u8).empty;
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
        var body_output = std.ArrayList(u8).empty;
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
        var filter_args = std.ArrayList(value_mod.Value).empty;
        defer {
            for (filter_args.items) |*arg| {
                arg.deinit(self.allocator);
            }
            filter_args.deinit(self.allocator);
        }

        // Evaluate kwargs
        var filter_kwargs = std.StringHashMap(value_mod.Value).init(self.allocator);
        defer {
            var iter = filter_kwargs.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit(self.allocator);
            }
            filter_kwargs.deinit();
        }

        // Extract filter arguments and kwargs if filter_expr is a FilterExpr
        if (node.filter_expr == .filter) {
            const filter_expr = node.filter_expr.filter;
            try filter_args.ensureTotalCapacity(self.allocator, filter_expr.args.items.len);
            for (filter_expr.args.items) |*arg_expr| {
                const arg_val = try self.visitExpression(arg_expr, frame, ctx);
                filter_args.appendAssumeCapacity(arg_val);
            }
            // Extract kwargs
            try filter_kwargs.ensureTotalCapacity(@intCast(filter_expr.kwargs.count()));
            var kwarg_iter = filter_expr.kwargs.iterator();
            while (kwarg_iter.next()) |entry| {
                var kwarg_expr = entry.value_ptr.*;
                const kwarg_val = try self.visitExpression(&kwarg_expr, frame, ctx);
                filter_kwargs.putAssumeCapacity(entry.key_ptr.*, kwarg_val);
            }
        }

        const filtered_value = try filter.func(
            self.allocator,
            body_value,
            filter_args.items,
            &filter_kwargs,
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
        var output = std.ArrayList(u8).empty;
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
        var cycle_guard = try self.environment.enterTemplateLoad(template_name_str);
        defer cycle_guard.deinit();
        const parent_template = try self.environment.getTemplate(template_name_str);

        // Set parent on current template
        current_template.parent = parent_template;

        // Recursively process parent template's inheritance chain
        // This ensures all ancestor blocks are registered
        try self.processParentBlocks(parent_template, ctx, 0);
    }

    /// Inheritance chains deeper than this are treated as template errors — the
    /// per-name cycle guard cannot bound depth across distinct template names.
    const max_inheritance_depth: usize = 32;

    /// Recursively process parent template blocks
    /// This handles multi-level inheritance (grandparent -> parent -> child)
    fn processParentBlocks(self: *Self, parent_template: *nodes.Template, ctx: *context.Context, depth: usize) !void {
        if (depth >= max_inheritance_depth) {
            return exceptions.TemplateError.RuntimeError;
        }
        // Register the immediate parent first so super() walks child -> parent
        // -> grandparent rather than skipping a generation.
        try self.registerBlocks(ctx, parent_template.body.items, false, 0);

        // Then process the grandparent inheritance chain.
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

                var cycle_guard = try self.environment.enterTemplateLoad(template_name_str);
                defer cycle_guard.deinit();
                const grandparent_template = try self.environment.getTemplate(template_name_str);
                parent_template.parent = grandparent_template;

                // Recursively process grandparent
                try self.processParentBlocks(grandparent_template, ctx, depth + 1);
                break;
            }
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
                const node_handle: *anyopaque = @ptrCast(node);
                if (block_stack.items.len > 0 and block_stack.items[0] == node_handle) {
                    // This required block is at the top of the stack = not overridden
                    // Check if it has actual content (non-whitespace)
                    if (try self.blockHasContent(node)) {
                        // Required block has content but wasn't overridden - this is an error
                        return exceptions.TemplateError.SyntaxError;
                    }
                }
            }
        }

        const selected = if (ctx.getBlock(node.name)) |handle|
            @as(*nodes.Block, @ptrCast(@alignCast(handle)))
        else
            node;

        return try self.renderSelectedBlock(selected, frame, ctx);
    }

    fn renderSelectedBlock(self: *Self, selected: *nodes.Block, frame: *Frame, ctx: *context.Context) ![]const u8 {
        // Set current block in frame for super() support
        const previous_block = frame.current_block;
        frame.current_block = selected;
        defer frame.current_block = previous_block;

        // Execute block body
        var output = std.ArrayList(u8).empty;
        defer output.deinit(self.allocator);

        for (selected.body.items) |stmt| {
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
        if (ctx.getSuperBlock(block_name, current_block)) |super_block_handle| {
            const super_block = @as(*nodes.Block, @ptrCast(@alignCast(super_block_handle)));
            // Render this exact parent block; ordinary visitBlock dispatch would
            // select the child override again and recurse forever.
            return try self.renderSelectedBlock(super_block, frame, ctx);
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
        var cycle_guard = try self.environment.enterTemplateLoad(template_name_str);
        defer cycle_guard.deinit();
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

    fn createTemplateModule(
        self: *Self,
        template: *nodes.Template,
        ctx: *context.Context,
        owner_allocator: std.mem.Allocator,
    ) !runtime_types.TemplateModule {
        var module_frame = Frame.init("module", null, self.allocator);
        defer module_frame.deinit();

        const body = try self.visitTemplate(template, &module_frame, ctx);
        defer self.allocator.free(body);
        const owned_body = try owner_allocator.dupe(u8, body);
        errdefer owner_allocator.free(owned_body);

        return try runtime_types.TemplateModule.initFromRenderedBody(owner_allocator, template, ctx, owned_body);
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
        var cycle_guard = try self.environment.enterTemplateLoad(template_name_str);
        defer cycle_guard.deinit();
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
        // The module escapes the render arena through the caller's Context, so it
        // must use the Context allocator and live until Context.deinit().
        const module = try ctx.allocator.create(runtime_types.TemplateModule);
        errdefer ctx.allocator.destroy(module);
        module.* = try self.createTemplateModule(imported_template, &import_ctx, ctx.allocator);

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
        var cycle_guard = try self.environment.enterTemplateLoad(template_name_str);
        defer cycle_guard.deinit();
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
        const module = try self.allocator.create(runtime_types.TemplateModule);
        errdefer self.allocator.destroy(module);
        module.* = try self.createTemplateModule(imported_template, &import_ctx, self.allocator);
        defer {
            module.deinit();
            self.allocator.destroy(module);
        }

        // Import specific names from module
        for (node.imports.items) |import_name| {
            // The parser stores import names as "name" or "name as alias"
            // Split on " as " to get original name and alias
            var name_parts = std.mem.splitSequence(u8, import_name, " as ");
            const original_name = name_parts.first();
            const alias_name = name_parts.next();
            const final_name = if (alias_name) |a| a else original_name;

            if (module.getMacro(original_name)) |macro_handle| {
                try ctx.setMacro(final_name, macro_handle);
            } else if (module.get(original_name)) |val| {
                // Copy value and store in context with final name (alias or original)
                const val_copy = try copyValueForImport(ctx.allocator, val);
                errdefer val_copy.deinit(ctx.allocator);

                try ctx.set(final_name, val_copy);
            } else {
                // Name not found in module - create undefined value
                const undefined_val = context.Value{ .undefined = value_mod.Undefined{
                    .name = original_name,
                    .behavior = self.environment.undefined_behavior,
                } };

                try ctx.set(final_name, undefined_val);
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

        var output = std.ArrayList(u8).empty;
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
/// Note: Bytecode now supports macros and call blocks (Phase 5)
pub fn compile(env: *environment.Environment, template: *nodes.Template, filename: ?[]const u8, allocator: std.mem.Allocator) !CompiledTemplate {
    var compiler = Compiler.init(env, filename, allocator);
    defer compiler.deinit();
    // Check if template uses features not supported by bytecode
    const use_bytecode = !templateHasUnsupportedFeatures(template);
    return try compiler.compile(template, use_bytecode);
}

/// Check if a template uses features not supported by bytecode
fn templateHasUnsupportedFeatures(template: *nodes.Template) bool {
    return statementsHaveUnsupportedFeatures(template.body.items, 0);
}

fn statementsHaveUnsupportedFeatures(statements: []*nodes.Stmt, depth: usize) bool {
    for (statements) |statement| {
        if (stmtHasUnsupportedFeatures(statement, depth)) return true;
    }
    return false;
}

fn ifHasUnsupportedFeatures(statement: *nodes.If, depth: usize) bool {
    if (statementsHaveUnsupportedFeatures(statement.body.items, depth)) return true;
    if (statementsHaveUnsupportedFeatures(statement.else_body.items, depth)) return true;
    for (statement.elif_bodies.items) |body| {
        if (statementsHaveUnsupportedFeatures(body.items, depth)) return true;
    }
    return false;
}

fn stmtHasUnsupportedFeatures(stmt: *nodes.Stmt, depth: usize) bool {
    if (depth >= 256) return true;
    const child_depth = depth + 1;
    return switch (stmt.tag) {
        .import, .from_import, .include, .extends, .filter_block => true,
        .for_loop => blk: {
            const statement: *nodes.For = @ptrCast(@alignCast(stmt));
            break :blk statement.target != .name or statement.test_expr != null or
                statementsHaveUnsupportedFeatures(statement.body.items, child_depth) or
                statementsHaveUnsupportedFeatures(statement.else_body.items, child_depth);
        },
        .if_stmt => ifHasUnsupportedFeatures(@ptrCast(@alignCast(stmt)), child_depth),
        .block => statementsHaveUnsupportedFeatures(
            @as(*nodes.Block, @ptrCast(@alignCast(stmt))).body.items,
            child_depth,
        ),
        .with => statementsHaveUnsupportedFeatures(
            @as(*nodes.With, @ptrCast(@alignCast(stmt))).body.items,
            child_depth,
        ),
        .macro => statementsHaveUnsupportedFeatures(
            @as(*nodes.Macro, @ptrCast(@alignCast(stmt))).body.items,
            child_depth,
        ),
        .set => blk: {
            const statement: *nodes.Set = @ptrCast(@alignCast(stmt));
            break :blk statement.body != null or statement.target_attr != null;
        },
        else => false,
    };
}

/// Compile a template with bytecode generation
pub fn compileWithBytecode(env: *environment.Environment, template: *nodes.Template, filename: ?[]const u8, allocator: std.mem.Allocator) !CompiledTemplate {
    var compiler = Compiler.init(env, filename, allocator);
    defer compiler.deinit();
    return try compiler.compile(template, true);
}

const std = @import("std");
const defaults = @import("defaults.zig");
const owned_registry = @import("owned_registry.zig");
const exceptions = @import("exceptions.zig");
const filters = @import("filters.zig");
const tests = @import("tests.zig");
const loaders = @import("loaders.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const nodes = @import("nodes.zig");
const value_mod = @import("value.zig");
const cache_mod = @import("template_cache.zig");
const optimizer_mod = @import("optimizer.zig");
const extensions = @import("extensions.zig");
const utils = @import("utils.zig");
const time = @import("time.zig");

/// Re-export Value type for convenience
pub const Value = value_mod.Value;

/// Render options for template execution with debugging support
/// Used by renderWithOptions() for timeout enforcement and debug tracing
pub const RenderOptions = struct {
    /// Execution timeout in milliseconds (null = no timeout)
    /// If set, rendering will fail with TimeoutError if it exceeds this duration
    timeout_ms: ?u64 = null,
    /// Enable debug tracing for filter/test execution
    /// When true, logs entry/exit and timing for each filter/test call
    debug_trace: bool = false,
};

/// Re-export cache types for convenience
pub const TemplateCacheEntry = cache_mod.TemplateCacheEntry;
pub const LRUCache = cache_mod.LRUCache;
pub const CacheStats = cache_mod.CacheStats;

/// Finalize callback type for processing variable expression results
/// The callback receives the value to be output and can transform it
/// (e.g., converting null to empty string)
pub const FinalizeFn = *const fn (allocator: std.mem.Allocator, val: Value) Value;

/// Autoescape configuration type - can be a boolean or a function
pub const AutoescapeConfig = union(enum) {
    bool: bool,
    function: *const fn (name: ?[]const u8) bool,
};

/// Environment system - the core component of Jinja
///
/// The `Environment` is the central configuration object for Jinja templates. It manages:
/// - Template syntax configuration (delimiters, prefixes, etc.)
/// - Filters and tests (built-in and custom)
/// - Global variables available to all templates
/// - Template loaders for loading templates from various sources
/// - Template caching for performance
/// - Extension system for custom functionality
/// - Autoescaping configuration
/// - Undefined variable handling behavior
///
/// # Example
///
/// ```zig
/// var env = jinja.Environment.init(allocator);
/// defer env.deinit();
///
/// // Configure environment
/// env.autoescape = .{ .bool = true };
/// env.trim_blocks = true;
///
/// // Add custom filter
/// try env.addFilter("myfilter", myFilterFunction);
///
/// // Set loader
/// var loader = try jinja.loaders.FileSystemLoader.init(allocator, &[_][]const u8{"templates"});
/// env.setLoader(&loader.loader);
///
/// // Load and render template
/// const template = try env.getTemplate("index.jinja");
/// defer template.deinit(allocator);
/// defer allocator.destroy(template);
/// ```
pub const Environment = struct {
    allocator: std.mem.Allocator,

    // Configuration
    block_start_string: []const u8,
    block_end_string: []const u8,
    variable_start_string: []const u8,
    variable_end_string: []const u8,
    comment_start_string: []const u8,
    comment_end_string: []const u8,
    line_statement_prefix: ?[]const u8,
    line_comment_prefix: ?[]const u8,
    trim_blocks: bool,
    lstrip_blocks: bool,
    newline_sequence: []const u8,
    keep_trailing_newline: bool,
    autoescape: AutoescapeConfig,
    optimized: bool,
    undefined_behavior: value_mod.UndefinedBehavior,
    /// Whether sandboxing is enabled (restricts unsafe operations)
    sandboxed: bool = false,
    /// Whether async mode is enabled (allows async filters, tests, and rendering)
    enable_async: bool = false,
    /// Finalize callback for processing variable expression results before output
    /// If set, this function is called on every variable expression value before it's output
    /// Can be used to convert null to empty string, apply global transformations, etc.
    finalize: ?FinalizeFn = null,
    /// Whether this environment is an overlay of another environment
    /// Overlay environments share data with their parent but have their own cache
    overlayed: bool = false,
    /// Reference to the parent environment if this is an overlay
    linked_to: ?*Environment = null,
    /// Whether this environment is shared (used by spontaneous environments)
    shared: bool = false,
    /// Overlay loaders inherited from a parent are borrowed; root or explicitly
    /// overridden loaders are owned by this environment.
    owns_loader: bool = true,
    /// Configuration strings duplicated for overlays/spontaneous environments.
    owned_config_strings: std.ArrayList([]const u8) = .empty,

    // Systems
    loader: ?*loaders.Loader,
    filters_map: std.StringHashMap(*filters.Filter),
    tests_map: std.StringHashMap(*tests.Test),
    globals_map: std.StringHashMap(Value),
    extension_registry: ?*extensions.ExtensionRegistry,
    active_template_loads: std.StringHashMap(usize),

    // Cache
    template_cache: ?*LRUCache,
    cache_size: usize,
    auto_reload: bool,

    const Self = @This();

    /// Initialize a new environment with default settings
    ///
    /// Creates a new `Environment` with all default configuration values:
    /// - Block delimiters: `{%` and `%}`
    /// - Variable delimiters: `{{` and `}}`
    /// - Comment delimiters: `{#` and `#}`
    /// - No line statement prefix
    /// - Autoescaping disabled
    /// - Optimization enabled
    /// - LRU cache with size 400 (if cache_size > 0)
    /// - All built-in filters and tests registered
    ///
    /// # Arguments
    /// - `allocator`: Memory allocator to use for the environment
    ///
    /// # Returns
    /// A new `Environment` instance with default settings
    ///
    /// # Example
    /// ```zig
    /// var env = jinja.Environment.init(allocator);
    /// defer env.deinit();
    /// ```
    pub fn init(allocator: std.mem.Allocator) Self {
        var env = Self{
            .allocator = allocator,
            .block_start_string = defaults.BLOCK_START_STRING,
            .block_end_string = defaults.BLOCK_END_STRING,
            .variable_start_string = defaults.VARIABLE_START_STRING,
            .variable_end_string = defaults.VARIABLE_END_STRING,
            .comment_start_string = defaults.COMMENT_START_STRING,
            .comment_end_string = defaults.COMMENT_END_STRING,
            .line_statement_prefix = defaults.LINE_STATEMENT_PREFIX,
            .line_comment_prefix = defaults.LINE_COMMENT_PREFIX,
            .trim_blocks = defaults.TRIM_BLOCKS,
            .lstrip_blocks = defaults.LSTRIP_BLOCKS,
            .newline_sequence = defaults.NEWLINE_SEQUENCE,
            .keep_trailing_newline = defaults.KEEP_TRAILING_NEWLINE,
            .autoescape = .{ .bool = defaults.AUTOESCAPE },
            .optimized = defaults.OPTIMIZED,
            .undefined_behavior = defaults.UNDEFINED_BEHAVIOR,
            .sandboxed = false,
            .enable_async = false,
            .loader = null,
            .filters_map = std.StringHashMap(*filters.Filter).init(allocator),
            .tests_map = std.StringHashMap(*tests.Test).init(allocator),
            .globals_map = std.StringHashMap(Value).init(allocator),
            .extension_registry = null,
            .active_template_loads = std.StringHashMap(usize).init(allocator),
            .template_cache = if (defaults.CACHE_SIZE > 0) blk: {
                const lru_cache = allocator.create(LRUCache) catch return Self{
                    .allocator = allocator,
                    .block_start_string = defaults.BLOCK_START_STRING,
                    .block_end_string = defaults.BLOCK_END_STRING,
                    .variable_start_string = defaults.VARIABLE_START_STRING,
                    .variable_end_string = defaults.VARIABLE_END_STRING,
                    .comment_start_string = defaults.COMMENT_START_STRING,
                    .comment_end_string = defaults.COMMENT_END_STRING,
                    .line_statement_prefix = defaults.LINE_STATEMENT_PREFIX,
                    .line_comment_prefix = defaults.LINE_COMMENT_PREFIX,
                    .trim_blocks = defaults.TRIM_BLOCKS,
                    .lstrip_blocks = defaults.LSTRIP_BLOCKS,
                    .newline_sequence = defaults.NEWLINE_SEQUENCE,
                    .keep_trailing_newline = defaults.KEEP_TRAILING_NEWLINE,
                    .autoescape = .{ .bool = defaults.AUTOESCAPE },
                    .optimized = defaults.OPTIMIZED,
                    .undefined_behavior = defaults.UNDEFINED_BEHAVIOR,
                    .loader = null,
                    .filters_map = std.StringHashMap(*filters.Filter).init(allocator),
                    .tests_map = std.StringHashMap(*tests.Test).init(allocator),
                    .globals_map = std.StringHashMap(Value).init(allocator),
                    .extension_registry = null,
                    .active_template_loads = std.StringHashMap(usize).init(allocator),
                    .template_cache = null,
                    .cache_size = defaults.CACHE_SIZE,
                    .auto_reload = defaults.AUTO_RELOAD,
                };
                lru_cache.* = LRUCache.init(allocator, defaults.CACHE_SIZE);
                break :blk lru_cache;
            } else null,
            .cache_size = defaults.CACHE_SIZE,
            .auto_reload = defaults.AUTO_RELOAD,
        };

        // Registration can only fail on allocation; init() cannot return an error
        // without breaking every caller, so log loudly instead of failing silently —
        // an environment missing builtins produces baffling template errors later.
        env.registerBuiltinFilters() catch |err| {
            std.log.err("vibe-jinja: failed to register builtin filters: {s}", .{@errorName(err)});
        };
        env.registerBuiltinTests() catch |err| {
            std.log.err("vibe-jinja: failed to register builtin tests: {s}", .{@errorName(err)});
        };
        env.registerBuiltinGlobals() catch |err| {
            std.log.err("vibe-jinja: failed to register builtin globals: {s}", .{@errorName(err)});
        };

        return env;
    }

    /// Register all builtin filters
    fn registerBuiltinFilters(self: *Self) !void {
        try self.addFilter("abs", filters.BuiltinFilters.abs);
        try self.addFilter("capitalize", filters.BuiltinFilters.capitalize);
        try self.addFilter("default", filters.BuiltinFilters.default);
        try self.addFilter("lower", filters.BuiltinFilters.lower);
        try self.addFilter("upper", filters.BuiltinFilters.upper);
        try self.addFilter("length", filters.BuiltinFilters.length);
        try self.addFilter("reverse", filters.BuiltinFilters.reverse);
        try self.addFilter("replace", filters.BuiltinFilters.replace);
        try self.addFilter("split", filters.BuiltinFilters.split);
        try self.addFilter("startswith", filters.BuiltinFilters.startswith);
        try self.addFilter("endswith", filters.BuiltinFilters.endswith);
        try self.addFilter("trim", filters.BuiltinFilters.trim);
        try self.addFilter("lstrip", filters.BuiltinFilters.lstrip);
        try self.addFilter("rstrip", filters.BuiltinFilters.rstrip);

        // String filters
        try self.addFilter("attr", filters.BuiltinFilters.attr);
        try self.addFilter("center", filters.BuiltinFilters.center);
        try self.addFilter("escape", filters.BuiltinFilters.escape);
        try self.addFilter("forceescape", filters.BuiltinFilters.forceescape);
        try self.addFilter("format", filters.BuiltinFilters.format);
        try self.addFilter("indent", filters.BuiltinFilters.indent);
        try self.addFilter("join", filters.BuiltinFilters.join);
        try self.addFilter("striptags", filters.BuiltinFilters.striptags);
        try self.addFilter("title", filters.BuiltinFilters.title);
        try self.addFilter("truncate", filters.BuiltinFilters.truncate);
        try self.addFilter("urlencode", filters.BuiltinFilters.urlencode);
        try self.addFilter("urlize", filters.BuiltinFilters.urlize);
        try self.addFilter("wordcount", filters.BuiltinFilters.wordcount);
        try self.addFilter("wordwrap", filters.BuiltinFilters.wordwrap);
        try self.addFilter("xmlattr", filters.BuiltinFilters.xmlattr);

        // List/Sequence filters
        try self.addFilter("batch", filters.BuiltinFilters.batch);
        try self.addFilter("first", filters.BuiltinFilters.first);
        try self.addFilter("last", filters.BuiltinFilters.last);
        try self.addFilter("list", filters.BuiltinFilters.list);
        try self.addFilter("map", filters.BuiltinFilters.map);
        try self.addFilter("reject", filters.BuiltinFilters.reject);
        try self.addFilter("rejectattr", filters.BuiltinFilters.rejectattr);
        try self.addFilter("select", filters.BuiltinFilters.select);
        try self.addFilter("selectattr", filters.BuiltinFilters.selectattr);
        try self.addFilter("slice", filters.BuiltinFilters.slice);
        try self.addFilter("sort", filters.BuiltinFilters.sort);
        try self.addFilter("sum", filters.BuiltinFilters.sum);
        try self.addFilter("unique", filters.BuiltinFilters.unique);

        // Number filters
        try self.addFilter("float", filters.BuiltinFilters.float);
        try self.addFilter("int", filters.BuiltinFilters.int);
        try self.addFilter("round", filters.BuiltinFilters.round);
        try self.addFilter("min", filters.BuiltinFilters.min);
        try self.addFilter("max", filters.BuiltinFilters.max);

        // Dict filters
        try self.addFilter("dictsort", filters.BuiltinFilters.dictsort);
        try self.addFilter("items", filters.BuiltinFilters.items);

        // Other filters
        try self.addFilter("count", filters.BuiltinFilters.count);
        try self.addFilter("filesizeformat", filters.BuiltinFilters.filesizeformat);
        try self.addFilter("groupby", filters.BuiltinFilters.groupby);
        try self.addFilter("pprint", filters.BuiltinFilters.pprint);
        try self.addFilter("random", filters.BuiltinFilters.random);
        try self.addFilter("safe", filters.BuiltinFilters.safe);
        try self.addFilter("string", filters.BuiltinFilters.string);
        try self.addFilter("tojson", filters.BuiltinFilters.tojson);

        // Markup/Safe filters (Jinja2 parity)
        try self.addFilter("mark_safe", filters.BuiltinFilters.mark_safe);
        try self.addFilter("mark_unsafe", filters.BuiltinFilters.mark_unsafe);

        // Filter aliases (Jinja2 parity)
        try self.addFilter("d", filters.BuiltinFilters.default); // Alias for default
        try self.addFilter("e", filters.BuiltinFilters.escape); // Alias for escape
    }

    fn filterExistsTest(val: Value, args: []const Value, ctx: ?*anyopaque, env: ?*anyopaque) bool {
        _ = args;
        _ = ctx;

        const env_ptr = env orelse return false;
        const self = @as(*Self, @ptrCast(@alignCast(env_ptr)));

        return switch (val) {
            .string => |filter_name| self.getFilter(filter_name) != null,
            else => false,
        };
    }

    fn testExistsTest(val: Value, args: []const Value, ctx: ?*anyopaque, env: ?*anyopaque) bool {
        _ = args;
        _ = ctx;

        const env_ptr = env orelse return false;
        const self = @as(*Self, @ptrCast(@alignCast(env_ptr)));

        return switch (val) {
            .string => |test_name| self.getTest(test_name) != null,
            else => false,
        };
    }

    // fallow-zig-ignore-next-line complexity-hot-function: callable lookup intentionally checks the three public registries after the intrinsic Value callable test; splitting would duplicate environment access without reducing decisions.
    fn callableTest(val: Value, args: []const Value, ctx: ?*anyopaque, env: ?*anyopaque) bool {
        _ = args;
        _ = ctx;

        if (tests.BuiltinTests.callable(val, &.{}, null, null)) {
            return true;
        }

        const env_ptr = env orelse return false;
        const self = @as(*Self, @ptrCast(@alignCast(env_ptr)));

        return switch (val) {
            .string => |name| blk: {
                if (self.getGlobal(name)) |global_val| {
                    if (global_val.isCallable() or global_val == .callable) {
                        break :blk true;
                    }
                }
                if (self.getFilter(name) != null) break :blk true;
                if (self.getTest(name) != null) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    /// Register all builtin tests
    fn registerBuiltinTests(self: *Self) !void {
        try self.addTest("defined", tests.BuiltinTests.defined);
        try self.addTest("undefined", tests.BuiltinTests.undefined);
        try self.addTest("equalto", tests.BuiltinTests.equalto);
        try self.addTest("even", tests.BuiltinTests.even);
        try self.addTest("odd", tests.BuiltinTests.odd);
        try self.addTest("divisibleby", tests.BuiltinTests.divisibleby);
        try self.addTest("lower", tests.BuiltinTests.lower);
        try self.addTest("upper", tests.BuiltinTests.upper);
        try self.addTest("string", tests.BuiltinTests.string);
        try self.addTest("number", tests.BuiltinTests.number);
        try self.addTest("empty", tests.BuiltinTests.empty);
        try self.addTest("none", tests.BuiltinTests.none);
        try self.addTest("boolean", tests.BuiltinTests.boolean);
        try self.addTest("false", tests.BuiltinTests.false);
        try self.addTest("true", tests.BuiltinTests.true);
        try self.addTest("integer", tests.BuiltinTests.integer);
        try self.addTest("float", tests.BuiltinTests.float);
        try self.addTest("mapping", tests.BuiltinTests.mapping);
        try self.addTest("sequence", tests.BuiltinTests.sequence);
        try self.addTest("iterable", tests.BuiltinTests.iterable);
        try self.addTest("callable", callableTest);
        try self.addTest("sameas", tests.BuiltinTests.sameas);
        try self.addTest("escaped", tests.BuiltinTests.escaped);
        try self.addTest("in", tests.BuiltinTests.in);
        try self.addTest("filter", filterExistsTest);
        try self.addTest("test", testExistsTest);

        // Comparison operator tests (Jinja2 parity)
        try self.addTest("lt", tests.BuiltinTests.lt);
        try self.addTest("le", tests.BuiltinTests.le);
        try self.addTest("gt", tests.BuiltinTests.gt);
        try self.addTest("ge", tests.BuiltinTests.ge);
        try self.addTest("ne", tests.BuiltinTests.ne);
        try self.addTest("eq", tests.BuiltinTests.equalto); // Alias for equalto

        // Operator symbol aliases (Jinja2 parity)
        try self.addTest("==", tests.BuiltinTests.equalto);
        try self.addTest("!=", tests.BuiltinTests.ne);
        try self.addTest("<", tests.BuiltinTests.lt);
        try self.addTest("<=", tests.BuiltinTests.le);
        try self.addTest(">", tests.BuiltinTests.gt);
        try self.addTest(">=", tests.BuiltinTests.ge);

        // Name aliases (Jinja2 parity)
        try self.addTest("lessthan", tests.BuiltinTests.lt);
        try self.addTest("greaterthan", tests.BuiltinTests.gt);

        // Set pass_arg for tests that need environment access
        if (self.getTest("filter")) |filter_test| {
            filter_test.pass_arg = .environment;
        }
        if (self.getTest("test")) |test_test| {
            test_test.pass_arg = .environment;
        }
    }

    /// Register all builtin global functions
    /// Provides Jinja2 parity for: range, dict, lipsum, cycler, joiner, namespace
    fn registerBuiltinGlobals(self: *Self) !void {
        // range([start,] stop[, step]) - Generate integer sequence
        const range_name = try self.allocator.dupe(u8, "range");
        errdefer self.allocator.free(range_name);
        const range_callable = try self.allocator.create(value_mod.Callable);
        range_callable.* = value_mod.Callable.initWithFunc(range_name, utils.rangeGlobal, false);
        try self.addGlobal("range", Value{ .callable = range_callable });

        // dict(**kwargs) - Create dictionary
        const dict_name = try self.allocator.dupe(u8, "dict");
        errdefer self.allocator.free(dict_name);
        const dict_callable = try self.allocator.create(value_mod.Callable);
        dict_callable.* = value_mod.Callable.initWithFunc(dict_name, utils.dictGlobal, false);
        try self.addGlobal("dict", Value{ .callable = dict_callable });

        // lipsum(n=5, html=True, min=20, max=100) - Generate lorem ipsum
        const lipsum_name = try self.allocator.dupe(u8, "lipsum");
        errdefer self.allocator.free(lipsum_name);
        const lipsum_callable = try self.allocator.create(value_mod.Callable);
        lipsum_callable.* = value_mod.Callable.initWithFunc(lipsum_name, utils.lipsumGlobal, false);
        try self.addGlobal("lipsum", Value{ .callable = lipsum_callable });

        // cycler(*items) - Cycle through values
        const cycler_name = try self.allocator.dupe(u8, "cycler");
        errdefer self.allocator.free(cycler_name);
        const cycler_callable = try self.allocator.create(value_mod.Callable);
        cycler_callable.* = value_mod.Callable.initWithFunc(cycler_name, utils.cyclerGlobal, false);
        try self.addGlobal("cycler", Value{ .callable = cycler_callable });

        // joiner(sep=", ") - Join values with separator
        const joiner_name = try self.allocator.dupe(u8, "joiner");
        errdefer self.allocator.free(joiner_name);
        const joiner_callable = try self.allocator.create(value_mod.Callable);
        joiner_callable.* = value_mod.Callable.initWithFunc(joiner_name, utils.joinerGlobal, false);
        try self.addGlobal("joiner", Value{ .callable = joiner_callable });

        // namespace(**kwargs) - Create namespace for scoped variables
        const namespace_name = try self.allocator.dupe(u8, "namespace");
        errdefer self.allocator.free(namespace_name);
        const namespace_callable = try self.allocator.create(value_mod.Callable);
        namespace_callable.* = value_mod.Callable.initWithFunc(namespace_name, utils.namespaceGlobal, false);
        try self.addGlobal("namespace", Value{ .callable = namespace_callable });

        // raise_exception(message) - Raise template runtime error (HuggingFace chat template support)
        const raise_name = try self.allocator.dupe(u8, "raise_exception");
        errdefer self.allocator.free(raise_name);
        const raise_callable = try self.allocator.create(value_mod.Callable);
        raise_callable.* = value_mod.Callable.initWithFunc(raise_name, utils.raiseExceptionGlobal, false);
        try self.addGlobal("raise_exception", Value{ .callable = raise_callable });

        // strftime_now(format_string) - Format current date/time (HuggingFace template compatibility)
        const strftime_name = try self.allocator.dupe(u8, "strftime_now");
        errdefer self.allocator.free(strftime_name);
        const strftime_callable = try self.allocator.create(value_mod.Callable);
        strftime_callable.* = value_mod.Callable.initWithFunc(strftime_name, utils.strftimeNowGlobal, false);
        try self.addGlobal("strftime_now", Value{ .callable = strftime_callable });
    }

    /// Deinitialize the environment and free allocated memory
    ///
    /// Frees all allocated resources including:
    /// - All registered filters and tests
    /// - All global variables
    /// - Template cache
    /// - Template loader
    /// - Extension registry
    ///
    /// **Note:** Templates created from this environment should be deinitialized separately
    /// if they are not managed by the cache.
    ///
    /// # Example
    /// ```zig
    /// var env = jinja.Environment.init(allocator);
    /// defer env.deinit(); // Automatically cleans up all resources
    /// ```
    pub fn deinit(self: *Self) void {
        // Free filters
        var filter_iter = self.filters_map.iterator();
        while (filter_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.filters_map.deinit();

        // Free tests
        var test_iter = self.tests_map.iterator();
        while (test_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.tests_map.deinit();

        // Free globals (free keys and values)
        var global_iter = self.globals_map.iterator();
        while (global_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.globals_map.deinit();

        // Free template cache
        if (self.template_cache) |cache| {
            cache.deinit();
            self.allocator.destroy(cache);
        }

        var active_iter = self.active_template_loads.iterator();
        while (active_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.active_template_loads.deinit();

        // Free loader if present and owned by this environment.
        if (self.owns_loader) if (self.loader) |loader| {
            loader.deinit();
        };

        // Free extension registry if present
        if (self.extension_registry) |registry| {
            registry.deinit();
            self.allocator.destroy(registry);
        }

        for (self.owned_config_strings.items) |string| self.allocator.free(string);
        self.owned_config_strings.deinit(self.allocator);
    }

    fn appendOwnedConfigCopy(self: *Self, owned: *std.ArrayList([]const u8), string: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, string);
        errdefer self.allocator.free(copy);
        try owned.append(self.allocator, copy);
        return copy;
    }

    fn ownConfigurationStrings(self: *Self) !void {
        std.debug.assert(self.owned_config_strings.items.len == 0);
        var owned = std.ArrayList([]const u8).empty;
        errdefer {
            for (owned.items) |string| self.allocator.free(string);
            owned.deinit(self.allocator);
        }

        const block_start = try self.appendOwnedConfigCopy(&owned, self.block_start_string);
        const block_end = try self.appendOwnedConfigCopy(&owned, self.block_end_string);
        const variable_start = try self.appendOwnedConfigCopy(&owned, self.variable_start_string);
        const variable_end = try self.appendOwnedConfigCopy(&owned, self.variable_end_string);
        const comment_start = try self.appendOwnedConfigCopy(&owned, self.comment_start_string);
        const comment_end = try self.appendOwnedConfigCopy(&owned, self.comment_end_string);
        const newline = try self.appendOwnedConfigCopy(&owned, self.newline_sequence);
        const line_statement = if (self.line_statement_prefix) |prefix|
            try self.appendOwnedConfigCopy(&owned, prefix)
        else
            null;
        const line_comment = if (self.line_comment_prefix) |prefix|
            try self.appendOwnedConfigCopy(&owned, prefix)
        else
            null;

        self.block_start_string = block_start;
        self.block_end_string = block_end;
        self.variable_start_string = variable_start;
        self.variable_end_string = variable_end;
        self.comment_start_string = comment_start;
        self.comment_end_string = comment_end;
        self.newline_sequence = newline;
        self.line_statement_prefix = line_statement;
        self.line_comment_prefix = line_comment;
        self.owned_config_strings = owned;
    }

    fn cloneRegistriesFrom(self: *Self, parent: *Self) !void {
        var filter_iter = parent.filters_map.iterator();
        while (filter_iter.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const filter = self.allocator.create(filters.Filter) catch |err| {
                self.allocator.free(key);
                return err;
            };
            filter.* = entry.value_ptr.*.*;
            filter.name = key;
            self.filters_map.put(key, filter) catch |err| {
                self.allocator.destroy(filter);
                self.allocator.free(key);
                return err;
            };
        }

        var test_iter = parent.tests_map.iterator();
        while (test_iter.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const test_obj = self.allocator.create(tests.Test) catch |err| {
                self.allocator.free(key);
                return err;
            };
            test_obj.* = entry.value_ptr.*.*;
            test_obj.name = key;
            self.tests_map.put(key, test_obj) catch |err| {
                self.allocator.destroy(test_obj);
                self.allocator.free(key);
                return err;
            };
        }

        var global_iter = parent.globals_map.iterator();
        while (global_iter.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const global = entry.value_ptr.*.deepCopy(self.allocator) catch |err| {
                self.allocator.free(key);
                return err;
            };
            self.globals_map.put(key, global) catch |err| {
                global.deinit(self.allocator);
                self.allocator.free(key);
                return err;
            };
        }
    }

    /// Add an extension to the environment
    ///
    /// Extensions provide custom tags, filters, and tests. When an extension is added:
    /// - The extension is bound to this environment
    /// - All filters from the extension are registered
    /// - All tests from the extension are registered
    /// - The extension can preprocess templates and filter token streams
    ///
    /// # Arguments
    /// - `extension`: Pointer to the extension to add
    ///
    /// # Errors
    /// - `error.OutOfMemory` - Memory allocation failed
    ///
    /// # Example
    /// ```zig
    /// var my_ext = MyExtension.init(allocator);
    /// try env.addExtension(&my_ext);
    /// ```
    pub fn addExtension(self: *Self, extension: *extensions.Extension) !void {
        // Bind extension to this environment
        const bound = try extension.bind(self);
        const bound_ptr = try self.allocator.create(extensions.Extension);
        bound_ptr.* = bound;

        // Create or get extension registry
        if (self.extension_registry == null) {
            const registry = try self.allocator.create(extensions.ExtensionRegistry);
            registry.* = extensions.ExtensionRegistry.init(self.allocator);
            self.extension_registry = registry;
        }

        // Register extension
        try self.extension_registry.?.register(bound_ptr);

        // Register extension's filters and tests
        var filter_iter = bound_ptr.filters.iterator();
        while (filter_iter.next()) |entry| {
            try self.addFilter(entry.key_ptr.*, entry.value_ptr.*.func);
        }

        var test_iter = bound_ptr.tests.iterator();
        while (test_iter.next()) |entry| {
            try self.addTest(entry.key_ptr.*, entry.value_ptr.*.func);
        }
    }

    /// Get extension registry
    ///
    /// Returns the extension registry if any extensions have been added, null otherwise.
    ///
    /// # Returns
    /// Pointer to the extension registry, or null if no extensions are registered
    pub fn getExtensionRegistry(self: *Self) ?*extensions.ExtensionRegistry {
        return self.extension_registry;
    }

    fn registryHandlesTag(registry_ptr: *anyopaque, tag: []const u8) bool {
        const registry = @as(*extensions.ExtensionRegistry, @ptrCast(@alignCast(registry_ptr)));
        return registry.handlesTag(tag);
    }

    fn registryParseTag(registry_ptr: *anyopaque, pars: *parser.Parser, tag: []const u8) parser.ParseError!?*nodes.Stmt {
        const registry = @as(*extensions.ExtensionRegistry, @ptrCast(@alignCast(registry_ptr)));
        return registry.parseTag(pars, tag) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => exceptions.TemplateError.RuntimeError,
        };
    }

    pub fn parserExtensionRegistry(self: *Self) ?parser.ExtensionRegistryHandle {
        const registry = self.extension_registry orelse return null;
        return .{
            .ptr = @ptrCast(registry),
            .handlesTagFn = registryHandlesTag,
            .parseTagFn = registryParseTag,
        };
    }

    pub const TemplateLoadGuard = struct {
        env: *Self,
        name: []const u8,
        active: bool = true,

        pub fn deinit(self: *TemplateLoadGuard) void {
            if (self.active) {
                self.env.leaveTemplateLoad(self.name);
                self.active = false;
            }
        }
    };

    pub fn enterTemplateLoad(self: *Self, name: []const u8) !TemplateLoadGuard {
        if (self.active_template_loads.contains(name)) {
            return exceptions.TemplateError.RuntimeError;
        }

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.active_template_loads.put(name_copy, 1);

        return TemplateLoadGuard{
            .env = self,
            .name = name,
        };
    }

    fn leaveTemplateLoad(self: *Self, name: []const u8) void {
        if (self.active_template_loads.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    fn cachedTemplateForSource(self: *Self, source: []const u8, name: []const u8) ?*nodes.Template {
        const cache = self.template_cache orelse return null;
        const entry = cache.get(name) orelse return null;
        if (!self.auto_reload or entry.source_checksum == TemplateCacheEntry.calculateChecksum(source)) {
            return entry.template;
        }
        _ = cache.remove(name);
        return null;
    }

    fn cacheParsedTemplate(self: *Self, source: []const u8, name: []const u8, template: *nodes.Template) !void {
        const cache = self.template_cache orelse return;
        const entry = try self.allocator.create(TemplateCacheEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .template = template,
            .last_modified = time.timestamp(),
            .access_count = 0,
            .source_checksum = TemplateCacheEntry.calculateChecksum(source),
        };
        try cache.put(name, entry);
    }

    /// Create a template from a string
    ///
    /// Parses the template source code and returns a compiled template AST.
    /// The template is cached if caching is enabled.
    ///
    /// **Note:** The returned template is owned by the cache if caching is enabled,
    /// or by the caller if caching is disabled. Use `template.deinit(allocator)` and
    /// `allocator.destroy(template)` to free it when done.
    ///
    /// # Arguments
    /// - `source`: Template source code as a string
    /// - `name`: Optional template name (used for caching and error messages)
    ///
    /// # Returns
    /// A pointer to the parsed template AST
    ///
    /// # Errors
    /// - `error.OutOfMemory` - Memory allocation failed
    /// - Template parsing errors (syntax errors, etc.)
    ///
    /// # Example
    /// ```zig
    /// const template = try env.fromString("Hello, {{ name }}!", "greeting");
    /// defer template.deinit(allocator);
    /// defer allocator.destroy(template);
    /// ```
    pub fn fromString(self: *Self, source: []const u8, name: ?[]const u8) !*nodes.Template {
        const template_name = name orelse "<string>";

        if (self.cachedTemplateForSource(source, template_name)) |template| return template;

        // Preprocess source with extensions
        var processed_source = source;
        var needs_free = false;
        if (self.extension_registry) |registry| {
            processed_source = try registry.preprocess(source, template_name, template_name);
            needs_free = true;
        }
        defer if (needs_free) self.allocator.free(processed_source);

        // Jinja drops one trailing newline by default. Preserve it only when
        // the environment explicitly opts into keep_trailing_newline.
        const lex_source = sourceWithTrailingNewlinePolicy(processed_source, self.keep_trailing_newline);

        // Tokenize
        var lex = lexer.Lexer.init(self, lex_source, template_name);
        const token_stream = try lex.tokenize(self.allocator);
        defer self.allocator.free(token_stream.tokens);

        // Filter token stream with extensions
        if (self.extension_registry) |registry| {
            var stream_obj = lexer.TokenStream.init(token_stream.tokens);
            const filtered_stream = try registry.filterStream(&stream_obj);
            // Note: filtered stream may have different tokens, but we'll use the original for now
            // Full implementation would need to handle token modification
            _ = filtered_stream; // Use original stream for now
        }

        // Parse
        var pars = parser.Parser.init(self, token_stream, template_name, self.allocator);
        const template = try pars.parse();

        // Optimize if enabled
        if (self.optimized) {
            var opt = optimizer_mod.Optimizer.init(self.allocator);
            try opt.optimize(template);
        }

        try self.cacheParsedTemplate(source, template_name, template);

        return template;
    }

    /// Get a template by name (from loader)
    ///
    /// Loads a template from the configured loader. The template is cached if caching
    /// is enabled. If `auto_reload` is enabled, the template will be reloaded if it has
    /// changed since it was last loaded.
    ///
    /// **Note:** A loader must be configured using `setLoader()` before calling this method.
    ///
    /// # Arguments
    /// - `name`: Template name/path (format depends on the loader)
    ///
    /// # Returns
    /// A pointer to the loaded template AST
    ///
    /// # Errors
    /// - `exceptions.TemplateError.TemplateNotFound` - Template not found or no loader configured
    /// - `error.OutOfMemory` - Memory allocation failed
    /// - Template parsing errors
    ///
    /// # Example
    /// ```zig
    /// var loader = try jinja.loaders.FileSystemLoader.init(allocator, &[_][]const u8{"templates"});
    /// env.setLoader(&loader.loader);
    /// const template = try env.getTemplate("index.jinja");
    /// defer template.deinit(allocator);
    /// defer allocator.destroy(template);
    /// ```
    pub fn getTemplate(self: *Self, name: []const u8) !*nodes.Template {
        if (self.loader == null) {
            return exceptions.TemplateError.TemplateNotFound;
        }

        const loader = self.loader.?;

        // Check cache if enabled
        if (self.template_cache) |cache| {
            if (cache.get(name)) |entry| {
                if (!self.auto_reload) {
                    return entry.template;
                }
                // Check if template changed (for auto_reload)
                // Use loader's uptodate callback if available
                if (loader.uptodate(name, entry.last_modified)) {
                    // Template is up-to-date - return cached template
                    return entry.template;
                }
                // Template changed - remove from cache and reload
                _ = cache.remove(name);
            }
        }

        // Load template source (sync or async based on enable_async)
        const source = if (self.enable_async)
            try loader.loadAsync(name)
        else
            try loader.load(name);
        defer self.allocator.free(source);

        // Create template from source (this will cache it with current timestamp)
        // The cache entry's last_modified will be used by uptodate() to check for changes
        const template = try self.fromString(source, name);

        return template;
    }

    /// Get a template asynchronously by name (from loader)
    ///
    /// Loads a template asynchronously from the configured loader. This requires:
    /// - `enable_async` to be set to `true`
    /// - The loader to support async loading
    ///
    /// The template is cached if caching is enabled. If `auto_reload` is enabled, the
    /// template will be reloaded if it has changed since it was last loaded.
    ///
    /// **Note:** A loader must be configured using `setLoader()` before calling this method.
    ///
    /// # Arguments
    /// - `name`: Template name/path (format depends on the loader)
    ///
    /// # Returns
    /// A pointer to the loaded template AST
    ///
    /// # Errors
    /// - `error.AsyncNotEnabled` - Async mode is not enabled
    /// - `exceptions.TemplateError.TemplateNotFound` - Template not found or no loader configured
    /// - `error.OutOfMemory` - Memory allocation failed
    /// - Template parsing errors
    pub fn getTemplateAsync(self: *Self, name: []const u8) !*nodes.Template {
        if (!self.enable_async) {
            return error.AsyncNotEnabled;
        }

        if (self.loader == null) {
            return exceptions.TemplateError.TemplateNotFound;
        }

        const loader = self.loader.?;

        // Check cache if enabled
        if (self.template_cache) |cache| {
            if (cache.get(name)) |entry| {
                if (!self.auto_reload) {
                    return entry.template;
                }
                // Check if template changed (for auto_reload)
                // Use loader's uptodate callback if available
                if (loader.uptodate(name, entry.last_modified)) {
                    // Template is up-to-date - return cached template
                    return entry.template;
                }
                // Template changed - remove from cache and reload
                _ = cache.remove(name);
            }
        }

        // Load template source asynchronously
        const source = try loader.loadAsync(name);
        defer self.allocator.free(source);

        // Create template from source (this will cache it with current timestamp)
        const template = try self.fromString(source, name);

        return template;
    }

    /// Add a filter to the environment
    ///
    /// Registers a custom filter function that can be used in templates with the `|` operator.
    /// If a filter with the same name already exists, it will be replaced.
    ///
    /// # Arguments
    /// - `name`: Filter name (used in templates as `{{ value | filtername }}`)
    /// - `filter_func`: Filter function that takes a value and optional arguments
    ///
    /// # Errors
    /// - `error.OutOfMemory` - Memory allocation failed
    ///
    /// # Example
    /// ```zig
    /// fn myFilter(value: jinja.Value, args: []jinja.Value, ctx: ?*jinja.context.Context, env: ?*jinja.Environment) !jinja.Value {
    ///     // Filter implementation
    ///     return value;
    /// }
    /// try env.addFilter("myfilter", myFilter);
    /// ```
    pub fn addFilter(self: *Self, name: []const u8, filter_func: filters.FilterFn) !void {
        try owned_registry.putNamed(filters.Filter, self.allocator, &self.filters_map, name, filters.Filter.init("", filter_func));
    }

    /// Add an async filter to the environment
    ///
    /// Registers a custom async filter function that can be used in templates with the `|` operator.
    /// Async filters are executed asynchronously when `enable_async` is true.
    /// If a filter with the same name already exists, it will be replaced.
    ///
    /// # Arguments
    /// - `name`: Filter name (used in templates as `{{ value | filtername }}`)
    /// - `sync_func`: Synchronous fallback filter function
    /// - `async_func`: Async filter function (used when enable_async is true)
    ///
    /// # Errors
    /// - `error.OutOfMemory` - Memory allocation failed
    ///
    /// # Example
    /// ```zig
    /// fn myAsyncFilter(value: jinja.Value, args: []jinja.Value, ctx: ?*jinja.context.Context, env: ?*jinja.Environment) !jinja.Value {
    ///     // Async filter implementation
    ///     return value;
    /// }
    /// try env.addAsyncFilter("myfilter", mySyncFilter, myAsyncFilter);
    /// ```
    pub fn addAsyncFilter(self: *Self, name: []const u8, sync_func: filters.FilterFn, async_func: filters.AsyncFilterFn) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const filter = try self.allocator.create(filters.Filter);
        errdefer self.allocator.destroy(filter);

        filter.* = filters.Filter.initAsync(name_copy, sync_func, async_func);

        // Remove old filter if exists
        if (self.filters_map.fetchRemove(name_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.destroy(old.value);
        }

        try self.filters_map.put(name_copy, filter);
    }

    /// Get a filter by name
    ///
    /// Returns the filter with the given name, or null if not found.
    /// This is an optimized hot path function that is inlined for performance.
    /// Uses comptime-interned builtin filter lookup for O(1) access to common filters.
    ///
    /// # Arguments
    /// - `name`: Filter name to look up
    ///
    /// # Returns
    /// Pointer to the filter, or null if not found
    pub inline fn getFilter(self: *Self, name: []const u8) ?*filters.Filter {
        // Dynamic lookup in registered filters map
        // Builtin filters are registered at init, so this covers both
        return self.filters_map.get(name);
    }

    /// Fast path for filter lookup that returns just the function
    /// Uses comptime-interned builtin map for O(1) lookup of common filters
    /// Falls back to dynamic lookup if not found in builtins
    pub inline fn getFilterFn(self: *Self, name: []const u8) ?filters.FilterFn {
        // Fast path: check comptime-interned builtins first (O(1) lookup)
        if (filters.getBuiltinFilter(name)) |func| {
            return func;
        }
        // Slow path: dynamic lookup for custom filters
        if (self.filters_map.get(name)) |filter| {
            return filter.func;
        }
        return null;
    }

    /// Add a test to the environment
    ///
    /// Registers a custom test function that can be used in templates with the `is` operator.
    /// If a test with the same name already exists, it will be replaced.
    ///
    /// # Arguments
    /// - `name`: Test name (used in templates as `{% if value is testname %}`)
    /// - `test_func`: Test function that takes a value and optional arguments, returns bool
    ///
    /// # Errors
    /// - `error.OutOfMemory` - Memory allocation failed
    ///
    /// # Example
    /// ```zig
    /// fn myTest(value: jinja.Value, args: []jinja.Value, ctx: ?*jinja.context.Context, env: ?*jinja.Environment) bool {
    ///     // Test implementation
    ///     return true;
    /// }
    /// try env.addTest("mytest", myTest);
    /// ```
    pub fn addTest(self: *Self, name: []const u8, test_func: tests.TestFn) !void {
        try owned_registry.putNamed(tests.Test, self.allocator, &self.tests_map, name, tests.Test.init("", test_func));
    }

    /// Add an async test to the environment
    ///
    /// Registers a custom async test function that can be used in templates with the `is` operator.
    /// Async tests are executed asynchronously when `enable_async` is true.
    /// If a test with the same name already exists, it will be replaced.
    ///
    /// # Arguments
    /// - `name`: Test name (used in templates as `{% if value is testname %}`)
    /// - `sync_func`: Synchronous fallback test function
    /// - `async_func`: Async test function (used when enable_async is true)
    ///
    /// # Errors
    /// - `error.OutOfMemory` - Memory allocation failed
    ///
    /// # Example
    /// ```zig
    /// fn myAsyncTest(value: jinja.Value, args: []jinja.Value, ctx: ?*jinja.context.Context, env: ?*jinja.Environment) bool {
    ///     // Async test implementation
    ///     return true;
    /// }
    /// try env.addAsyncTest("mytest", mySyncTest, myAsyncTest);
    /// ```
    pub fn addAsyncTest(self: *Self, name: []const u8, sync_func: tests.TestFn, async_func: tests.AsyncTestFn) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const test_obj = try self.allocator.create(tests.Test);
        errdefer self.allocator.destroy(test_obj);

        test_obj.* = tests.Test.initAsync(name_copy, sync_func, async_func);

        // Remove old test if exists
        if (self.tests_map.fetchRemove(name_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.destroy(old.value);
        }

        try self.tests_map.put(name_copy, test_obj);
    }

    /// Get a test by name
    ///
    /// Returns the test with the given name, or null if not found.
    /// This is an optimized hot path function that is inlined for performance.
    /// Uses comptime-interned builtin test lookup for O(1) access to common tests.
    ///
    /// # Arguments
    /// - `name`: Test name to look up
    ///
    /// # Returns
    /// Pointer to the test, or null if not found
    pub inline fn getTest(self: *Self, name: []const u8) ?*tests.Test {
        // Dynamic lookup in registered tests map
        // Builtin tests are registered at init, so this covers both
        return self.tests_map.get(name);
    }

    /// Fast path for test lookup that returns just the function
    /// Uses comptime-interned builtin map for O(1) lookup of common tests
    /// Falls back to dynamic lookup if not found in builtins
    pub inline fn getTestFn(self: *Self, name: []const u8) ?tests.TestFn {
        // Fast path: check comptime-interned builtins first (O(1) lookup)
        if (tests.getBuiltinTest(name)) |func| {
            return func;
        }
        // Slow path: dynamic lookup for custom tests
        if (self.tests_map.get(name)) |test_obj| {
            return test_obj.func;
        }
        return null;
    }

    /// Add a global variable to the environment
    ///
    /// Registers a global variable that is available to all templates rendered with this
    /// environment. If a global with the same name already exists, it will be replaced.
    ///
    /// **Note:** The value is copied and owned by the environment. It will be freed when
    /// the environment is deinitialized.
    ///
    /// # Arguments
    /// - `name`: Global variable name
    /// - `val`: Value to assign to the global variable
    ///
    /// # Errors
    /// - `error.OutOfMemory` - Memory allocation failed
    ///
    /// # Example
    /// ```zig
    /// const site_name = try allocator.dupe(u8, "My Site");
    /// try env.addGlobal("site_name", jinja.Value{ .string = site_name });
    /// ```
    pub fn addGlobal(self: *Self, name: []const u8, val: Value) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        // Remove old global if exists
        if (self.globals_map.fetchRemove(name_copy)) |old| {
            self.allocator.free(old.key);
            var old_val = old.value;
            old_val.deinit(self.allocator);
        }

        try self.globals_map.put(name_copy, val);
    }

    /// Get a global variable by name
    ///
    /// Returns the global variable with the given name, or null if not found.
    /// This is an optimized hot path function that is inlined for performance.
    ///
    /// **Note:** The returned value is a copy. Modifying it will not affect the global.
    ///
    /// # Arguments
    /// - `name`: Global variable name to look up
    ///
    /// # Returns
    /// The global value, or null if not found
    pub inline fn getGlobal(self: *Self, name: []const u8) ?Value {
        return self.globals_map.get(name);
    }

    /// Get cache statistics
    ///
    /// Returns cache statistics including hit rate, misses, and evictions.
    /// Returns null if caching is not enabled.
    ///
    /// # Returns
    /// Cache statistics, or null if caching is disabled
    pub fn getCacheStats(self: *Self) ?CacheStats {
        if (self.template_cache) |cache| {
            return cache.getStats();
        }
        return null;
    }

    /// Clear template cache
    ///
    /// Removes all templates from the cache. This is useful when you want to force
    /// reloading of all templates or free memory.
    pub fn clearTemplateCache(self: *Self) void {
        if (self.template_cache) |cache| {
            cache.clear();
        }
    }

    /// Clear all caches (template cache)
    ///
    /// Convenience method that clears all caches. Currently only clears the template cache.
    pub fn clearCaches(self: *Self) void {
        self.clearTemplateCache();
    }

    /// Set the template loader
    ///
    /// Sets the loader used to load templates by name. The old loader (if any) is
    /// automatically deinitialized.
    ///
    /// **Note:** The loader must remain valid for the lifetime of the environment.
    ///
    /// # Arguments
    /// - `loader`: Pointer to the loader to use
    ///
    /// # Example
    /// ```zig
    /// var loader = try jinja.loaders.FileSystemLoader.init(allocator, &[_][]const u8{"templates"});
    /// env.setLoader(&loader.loader);
    /// ```
    pub fn setLoader(self: *Self, loader: *loaders.Loader) void {
        // Free old loader if present
        if (self.loader) |old_loader| {
            old_loader.deinit();
        }
        self.loader = loader;
    }

    /// Evaluate autoescape setting for a template
    ///
    /// Determines whether autoescaping should be enabled for a template based on the
    /// environment's autoescape configuration. If autoescape is a function, it will be
    /// called with the template name.
    ///
    /// # Arguments
    /// - `template_name`: Optional template name (used if autoescape is a function)
    ///
    /// # Returns
    /// `true` if autoescaping should be enabled, `false` otherwise
    pub fn shouldAutoescape(self: *const Self, template_name: ?[]const u8) bool {
        return switch (self.autoescape) {
            .bool => |b| b,
            .function => |func| func(template_name),
        };
    }

    /// Overlay configuration options for creating overlay environments
    pub const OverlayOptions = struct {
        block_start_string: ?[]const u8 = null,
        block_end_string: ?[]const u8 = null,
        variable_start_string: ?[]const u8 = null,
        variable_end_string: ?[]const u8 = null,
        comment_start_string: ?[]const u8 = null,
        comment_end_string: ?[]const u8 = null,
        line_statement_prefix: ??[]const u8 = null,
        line_comment_prefix: ??[]const u8 = null,
        trim_blocks: ?bool = null,
        lstrip_blocks: ?bool = null,
        newline_sequence: ?[]const u8 = null,
        keep_trailing_newline: ?bool = null,
        optimized: ?bool = null,
        autoescape: ?AutoescapeConfig = null,
        loader: ?*loaders.Loader = null,
        cache_size: ?usize = null,
        auto_reload: ?bool = null,
        enable_async: ?bool = null,
        finalize: ??FinalizeFn = null,
    };

    fn initializeOverlayCache(self: *Self) !void {
        if (self.cache_size == 0) return;
        const cache = try self.allocator.create(LRUCache);
        cache.* = LRUCache.init(self.allocator, self.cache_size);
        self.template_cache = cache;
    }

    fn cloneOverlayExtensions(self: *Self, parent: *Self) !void {
        const parent_registry = parent.extension_registry orelse return;
        const registry = try self.allocator.create(extensions.ExtensionRegistry);
        registry.* = extensions.ExtensionRegistry.init(self.allocator);
        self.extension_registry = registry;
        try registry.extensions.ensureTotalCapacity(self.allocator, parent_registry.extensions.items.len);

        for (parent_registry.extensions.items) |extension| {
            const bound = try extension.bind(self);
            const bound_pointer = try self.allocator.create(extensions.Extension);
            bound_pointer.* = bound;
            // Parent extensions are already priority-sorted; binding preserves priority.
            registry.extensions.appendAssumeCapacity(bound_pointer);
        }
    }

    fn applyOverlayDelimiterOptions(self: *Self, options: OverlayOptions) void {
        if (options.block_start_string) |value| self.block_start_string = value;
        if (options.block_end_string) |value| self.block_end_string = value;
        if (options.variable_start_string) |value| self.variable_start_string = value;
        if (options.variable_end_string) |value| self.variable_end_string = value;
        if (options.comment_start_string) |value| self.comment_start_string = value;
        if (options.comment_end_string) |value| self.comment_end_string = value;
    }

    fn applyOverlayLayoutOptions(self: *Self, options: OverlayOptions) void {
        if (options.line_statement_prefix) |value| self.line_statement_prefix = value;
        if (options.line_comment_prefix) |value| self.line_comment_prefix = value;
        if (options.trim_blocks) |value| self.trim_blocks = value;
        if (options.lstrip_blocks) |value| self.lstrip_blocks = value;
        if (options.newline_sequence) |value| self.newline_sequence = value;
        if (options.keep_trailing_newline) |value| self.keep_trailing_newline = value;
    }

    fn applyOverlayBehaviorOptions(self: *Self, options: OverlayOptions) void {
        if (options.autoescape) |value| self.autoescape = value;
        if (options.optimized) |value| self.optimized = value;
        if (options.enable_async) |value| self.enable_async = value;
        if (options.finalize) |value| self.finalize = value;
        if (options.cache_size) |value| self.cache_size = value;
        if (options.auto_reload) |value| self.auto_reload = value;
    }

    fn initializeOverlayState(self: *Self, overlay_environment: *Self, options: OverlayOptions) void {
        overlay_environment.* = self.*;
        overlay_environment.owned_config_strings = .empty;
        overlay_environment.overlayed = true;
        overlay_environment.linked_to = self;
        overlay_environment.shared = false;
        overlay_environment.owns_loader = options.loader != null;
        overlay_environment.loader = options.loader orelse self.loader;
        overlay_environment.filters_map = std.StringHashMap(*filters.Filter).init(self.allocator);
        overlay_environment.tests_map = std.StringHashMap(*tests.Test).init(self.allocator);
        overlay_environment.globals_map = std.StringHashMap(Value).init(self.allocator);
        overlay_environment.extension_registry = null;
        overlay_environment.active_template_loads = std.StringHashMap(usize).init(self.allocator);
        overlay_environment.template_cache = null;
        overlay_environment.applyOverlayDelimiterOptions(options);
        overlay_environment.applyOverlayLayoutOptions(options);
        overlay_environment.applyOverlayBehaviorOptions(options);
    }

    /// Create a new overlay environment that shares all the data with the
    /// current environment except for cache and the overridden attributes.
    ///
    /// Extensions cannot be removed for an overlayed environment. An overlayed
    /// environment automatically gets all the extensions of the environment it
    /// is linked to plus optional extra extensions.
    ///
    /// Creating overlays should happen after the initial environment was set
    /// up completely. Not all attributes are truly linked, some are just
    /// copied over so modifications on the original environment may not shine
    /// through.
    ///
    /// # Arguments
    /// - `options`: Optional overrides for environment settings
    ///
    /// # Returns
    /// A new overlay environment that shares data with this environment
    ///
    /// # Errors
    /// - `error.OutOfMemory` - Memory allocation failed
    ///
    /// # Example
    /// ```zig
    /// var overlay_env = try env.overlay(.{
    ///     .autoescape = .{ .bool = true },
    ///     .trim_blocks = true,
    /// });
    /// defer overlay_env.deinit();
    /// ```
    pub fn overlay(self: *Self, options: OverlayOptions) !*Self {
        const rv = try self.allocator.create(Self);
        errdefer self.allocator.destroy(rv);

        self.initializeOverlayState(rv, options);
        errdefer rv.deinit();

        try rv.cloneRegistriesFrom(self);
        try rv.ownConfigurationStrings();

        try rv.initializeOverlayCache();
        try rv.cloneOverlayExtensions(self);

        return rv;
    }

    /// Apply the finalize callback to a value if set
    ///
    /// This is called by the compiler/runtime on variable expression results
    /// before they are output.
    ///
    /// # Arguments
    /// - `val`: The value to potentially transform
    ///
    /// # Returns
    /// The transformed value if finalize is set, or the original value
    pub fn applyFinalize(self: *const Self, val: Value) Value {
        if (self.finalize) |finalize_fn| {
            return finalize_fn(self.allocator, val);
        }
        return val;
    }
};

// ============================================================================
// Spontaneous Environments
// ============================================================================

/// Cache for spontaneous environments
/// Spontaneous environments are used for templates created directly without an existing environment
const SpontaneousEntry = struct {
    environment: *Environment,
    allocator: std.mem.Allocator,
};

var spontaneous_cache: ?std.StringHashMap(SpontaneousEntry) = null;
var spontaneous_cache_allocator: ?std.mem.Allocator = null;
var spontaneous_cache_mutex: std.Io.Mutex = .init;
const SPONTANEOUS_CACHE_SIZE: usize = 10;

fn appendSpontaneousKeyPart(allocator: std.mem.Allocator, key: *std.ArrayList(u8), value: []const u8) !void {
    try key.print(allocator, "{d}:{s}|", .{ value.len, value });
}

fn appendOptionalSpontaneousKeyPart(allocator: std.mem.Allocator, key: *std.ArrayList(u8), value: ?[]const u8) !void {
    if (value) |string| {
        try key.append(allocator, 'S');
        try appendSpontaneousKeyPart(allocator, key, string);
    } else {
        try key.appendSlice(allocator, "N|");
    }
}

fn appendSpontaneousSyntaxKey(allocator: std.mem.Allocator, key: *std.ArrayList(u8), options: Environment.OverlayOptions) !void {
    try appendSpontaneousKeyPart(allocator, key, options.block_start_string orelse defaults.BLOCK_START_STRING);
    try appendSpontaneousKeyPart(allocator, key, options.block_end_string orelse defaults.BLOCK_END_STRING);
    try appendSpontaneousKeyPart(allocator, key, options.variable_start_string orelse defaults.VARIABLE_START_STRING);
    try appendSpontaneousKeyPart(allocator, key, options.variable_end_string orelse defaults.VARIABLE_END_STRING);
    try appendSpontaneousKeyPart(allocator, key, options.comment_start_string orelse defaults.COMMENT_START_STRING);
    try appendSpontaneousKeyPart(allocator, key, options.comment_end_string orelse defaults.COMMENT_END_STRING);
    try appendOptionalSpontaneousKeyPart(allocator, key, if (options.line_statement_prefix) |value| value else defaults.LINE_STATEMENT_PREFIX);
    try appendOptionalSpontaneousKeyPart(allocator, key, if (options.line_comment_prefix) |value| value else defaults.LINE_COMMENT_PREFIX);
    try appendSpontaneousKeyPart(allocator, key, options.newline_sequence orelse defaults.NEWLINE_SEQUENCE);
}

fn appendSpontaneousBehaviorKey(allocator: std.mem.Allocator, key: *std.ArrayList(u8), options: Environment.OverlayOptions) !void {
    const autoescape = if (options.autoescape) |value| value.bool else defaults.AUTOESCAPE;
    try key.print(allocator, "{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|", .{
        @intFromBool(options.trim_blocks orelse defaults.TRIM_BLOCKS),
        @intFromBool(options.lstrip_blocks orelse defaults.LSTRIP_BLOCKS),
        @intFromBool(options.keep_trailing_newline orelse defaults.KEEP_TRAILING_NEWLINE),
        @intFromBool(options.optimized orelse defaults.OPTIMIZED),
        @intFromBool(autoescape),
        options.cache_size orelse defaults.CACHE_SIZE,
        @intFromBool(options.auto_reload orelse defaults.AUTO_RELOAD),
        @intFromBool(options.enable_async orelse false),
    });
}

fn buildSpontaneousKey(allocator: std.mem.Allocator, options: Environment.OverlayOptions) ![]const u8 {
    var key = std.ArrayList(u8).empty;
    errdefer key.deinit(allocator);
    try appendSpontaneousSyntaxKey(allocator, &key, options);
    try appendSpontaneousBehaviorKey(allocator, &key, options);
    return try key.toOwnedSlice(allocator);
}

fn spontaneousOptionsAreCacheable(options: Environment.OverlayOptions) bool {
    if (options.loader != null) return false;
    if (options.autoescape) |value| if (value == .function) return false;
    if (options.finalize) |value| if (value != null) return false;
    return true;
}

fn applySpontaneousDelimiterOptions(env: *Environment, options: Environment.OverlayOptions) void {
    if (options.block_start_string) |value| env.block_start_string = value;
    if (options.block_end_string) |value| env.block_end_string = value;
    if (options.variable_start_string) |value| env.variable_start_string = value;
    if (options.variable_end_string) |value| env.variable_end_string = value;
    if (options.comment_start_string) |value| env.comment_start_string = value;
    if (options.comment_end_string) |value| env.comment_end_string = value;
}

fn applySpontaneousLayoutOptions(env: *Environment, options: Environment.OverlayOptions) void {
    if (options.line_statement_prefix) |value| env.line_statement_prefix = value;
    if (options.line_comment_prefix) |value| env.line_comment_prefix = value;
    if (options.trim_blocks) |value| env.trim_blocks = value;
    if (options.lstrip_blocks) |value| env.lstrip_blocks = value;
    if (options.newline_sequence) |value| env.newline_sequence = value;
}

fn applySpontaneousBehaviorOptions(env: *Environment, options: Environment.OverlayOptions) void {
    if (options.keep_trailing_newline) |value| env.keep_trailing_newline = value;
    if (options.optimized) |value| env.optimized = value;
    if (options.autoescape) |value| env.autoescape = value;
    if (options.loader) |value| env.loader = value;
    if (options.auto_reload) |value| env.auto_reload = value;
    if (options.enable_async) |value| env.enable_async = value;
    if (options.finalize) |value| env.finalize = value;
}

fn applySpontaneousCacheOptions(env: *Environment, options: Environment.OverlayOptions) !void {
    const cache_size = options.cache_size orelse defaults.CACHE_SIZE;
    if (cache_size != env.cache_size) {
        if (env.template_cache) |cache| {
            cache.deinit();
            env.allocator.destroy(cache);
            env.template_cache = null;
        }
        env.cache_size = cache_size;
        if (cache_size > 0) {
            const cache = try env.allocator.create(LRUCache);
            cache.* = LRUCache.init(env.allocator, cache_size);
            env.template_cache = cache;
        }
    }
}

fn applySpontaneousOptions(env: *Environment, options: Environment.OverlayOptions) !void {
    applySpontaneousDelimiterOptions(env, options);
    applySpontaneousLayoutOptions(env, options);
    applySpontaneousBehaviorOptions(env, options);
    try applySpontaneousCacheOptions(env, options);
}

fn createSpontaneousEnvironment(allocator: std.mem.Allocator, options: Environment.OverlayOptions, shared: bool) !*Environment {
    const environment = try allocator.create(Environment);
    environment.* = Environment.init(allocator);
    errdefer {
        environment.deinit();
        allocator.destroy(environment);
    }
    try applySpontaneousOptions(environment, options);
    try environment.ownConfigurationStrings();
    environment.shared = shared;
    return environment;
}

fn clearSpontaneousEntries(cache_allocator: std.mem.Allocator, cache: *std.StringHashMap(SpontaneousEntry)) void {
    var iter = cache.iterator();
    while (iter.next()) |entry| {
        const cached = entry.value_ptr.*;
        cached.environment.deinit();
        cached.allocator.destroy(cached.environment);
        cache_allocator.free(entry.key_ptr.*);
    }
    cache.clearRetainingCapacity();
}

/// Get or create a spontaneous environment with the given configuration
///
/// Spontaneous environments are cached and shared for templates created directly
/// rather than through an existing environment. This matches Python's behavior
/// where `Template("...")` uses a shared environment.
///
/// # Arguments
/// - `allocator`: Memory allocator
/// - `options`: Environment configuration options
///
/// # Returns
/// A shared spontaneous environment with the given configuration
///
/// # Errors
/// - `error.OutOfMemory` - Memory allocation failed
pub fn getSpontaneousEnvironment(allocator: std.mem.Allocator, options: Environment.OverlayOptions) !*Environment {
    if (!spontaneousOptionsAreCacheable(options)) {
        return try createSpontaneousEnvironment(allocator, options, false);
    }

    const mutex_io = std.Io.Threaded.global_single_threaded.io();
    spontaneous_cache_mutex.lockUncancelable(mutex_io);
    defer spontaneous_cache_mutex.unlock(mutex_io);

    // Initialize cache if needed
    if (spontaneous_cache == null) {
        spontaneous_cache_allocator = allocator;
        spontaneous_cache = std.StringHashMap(SpontaneousEntry).init(allocator);
    }
    const cache_allocator = spontaneous_cache_allocator.?;
    const key = try buildSpontaneousKey(cache_allocator, options);
    errdefer cache_allocator.free(key);

    if (spontaneous_cache.?.get(key)) |entry| {
        cache_allocator.free(key);
        return entry.environment;
    }

    const environment = try createSpontaneousEnvironment(allocator, options, true);
    errdefer {
        environment.deinit();
        allocator.destroy(environment);
    }

    if (spontaneous_cache.?.count() >= SPONTANEOUS_CACHE_SIZE) {
        clearSpontaneousEntries(cache_allocator, &spontaneous_cache.?);
    }

    try spontaneous_cache.?.put(key, .{ .environment = environment, .allocator = allocator });

    return environment;
}

/// Clear the spontaneous environment cache
/// This should be called during application shutdown or when you want to reclaim memory
pub fn clearSpontaneousCache(allocator: std.mem.Allocator) void {
    _ = allocator; // Entries remember the allocator that owns each environment.
    const mutex_io = std.Io.Threaded.global_single_threaded.io();
    spontaneous_cache_mutex.lockUncancelable(mutex_io);
    defer spontaneous_cache_mutex.unlock(mutex_io);

    if (spontaneous_cache) |*cache| {
        clearSpontaneousEntries(spontaneous_cache_allocator.?, cache);
        cache.deinit();
        spontaneous_cache = null;
        spontaneous_cache_allocator = null;
    }
}
fn sourceWithTrailingNewlinePolicy(source: []const u8, keep_trailing_newline: bool) []const u8 {
    if (keep_trailing_newline) return source;
    if (std.mem.endsWith(u8, source, "\r\n")) return source[0 .. source.len - 2];
    if (std.mem.endsWith(u8, source, "\n")) return source[0 .. source.len - 1];
    return source;
}

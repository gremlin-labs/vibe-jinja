const std = @import("std");
const defaults = @import("defaults.zig");
const exceptions = @import("exceptions.zig");
const filters = @import("filters.zig");
const tests = @import("tests.zig");
const loaders = @import("loaders.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const nodes = @import("nodes.zig");
const value_mod = @import("value.zig");
const runtime = @import("runtime.zig");
const cache_mod = @import("cache.zig");
const optimizer_mod = @import("optimizer.zig");
const extensions = @import("extensions.zig");
const utils = @import("utils.zig");

/// Re-export Value type for convenience
pub const Value = value_mod.Value;

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
    undefined_behavior: runtime.UndefinedBehavior,
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

    // Systems
    loader: ?*loaders.Loader,
    filters_map: std.StringHashMap(*filters.Filter),
    tests_map: std.StringHashMap(*tests.Test),
    globals_map: std.StringHashMap(Value),
    extension_registry: ?*extensions.ExtensionRegistry,

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

        // Register builtin filters
        env.registerBuiltinFilters() catch {};
        // Register builtin tests
        env.registerBuiltinTests() catch {};
        // Register builtin globals (range, dict, lipsum, cycler, joiner, namespace)
        env.registerBuiltinGlobals() catch {};

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
        try self.addTest("callable", tests.BuiltinTests.callable);
        try self.addTest("sameas", tests.BuiltinTests.sameas);
        try self.addTest("escaped", tests.BuiltinTests.escaped);
        try self.addTest("in", tests.BuiltinTests.in);
        try self.addTest("filter", tests.BuiltinTests.filter);
        try self.addTest("test", tests.BuiltinTests.@"test");

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

        // Note: cycler, joiner, and namespace are class-like constructors in Jinja2.
        // They are available through the utils module as Cycler, Joiner, Namespace
        // For full parity, users can construct them programmatically.
        // The most commonly used global functions (range, dict, lipsum) are registered above.
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

        // Free loader if present
        if (self.loader) |loader| {
            loader.deinit();
        }

        // Free extension registry if present
        if (self.extension_registry) |registry| {
            registry.deinit();
            self.allocator.destroy(registry);
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

        // Check cache if enabled
        if (self.template_cache) |cache| {
            if (cache.get(template_name)) |entry| {
                if (!self.auto_reload) {
                    return entry.template;
                }
                // Check if source changed (for auto_reload)
                const source_checksum = TemplateCacheEntry.calculateChecksum(source);
                if (entry.source_checksum == source_checksum) {
                    // Source hasn't changed - return cached template
                    return entry.template;
                }
                // Source changed - remove from cache and reload
                _ = cache.remove(template_name);
            }
        }

        // Preprocess source with extensions
        var processed_source = source;
        var needs_free = false;
        if (self.extension_registry) |registry| {
            processed_source = try registry.preprocess(source, template_name, template_name);
            needs_free = true;
        }
        defer if (needs_free) self.allocator.free(processed_source);

        // Tokenize
        var lex = lexer.Lexer.init(self, processed_source, template_name);
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

        // Cache if enabled
        if (self.template_cache) |cache| {
            // Add to cache (LRU cache handles eviction automatically)
            const entry = try self.allocator.create(TemplateCacheEntry);
            entry.* = TemplateCacheEntry{
                .template = template,
                .last_modified = std.time.timestamp(),
                .access_count = 0,
                .source_checksum = TemplateCacheEntry.calculateChecksum(source),
            };
            try cache.put(template_name, entry);
        }

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
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const filter = try self.allocator.create(filters.Filter);
        errdefer self.allocator.destroy(filter);

        filter.* = filters.Filter.init(name_copy, filter_func);

        // Remove old filter if exists
        if (self.filters_map.fetchRemove(name_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.destroy(old.value);
        }

        try self.filters_map.put(name_copy, filter);
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
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const test_obj = try self.allocator.create(tests.Test);
        errdefer self.allocator.destroy(test_obj);

        test_obj.* = tests.Test.init(name_copy, test_func);

        // Remove old test if exists
        if (self.tests_map.fetchRemove(name_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.destroy(old.value);
        }

        try self.tests_map.put(name_copy, test_obj);
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

        // Copy all fields from parent
        rv.* = Self{
            .allocator = self.allocator,
            .block_start_string = options.block_start_string orelse self.block_start_string,
            .block_end_string = options.block_end_string orelse self.block_end_string,
            .variable_start_string = options.variable_start_string orelse self.variable_start_string,
            .variable_end_string = options.variable_end_string orelse self.variable_end_string,
            .comment_start_string = options.comment_start_string orelse self.comment_start_string,
            .comment_end_string = options.comment_end_string orelse self.comment_end_string,
            .line_statement_prefix = if (options.line_statement_prefix) |prefix| prefix else self.line_statement_prefix,
            .line_comment_prefix = if (options.line_comment_prefix) |prefix| prefix else self.line_comment_prefix,
            .trim_blocks = options.trim_blocks orelse self.trim_blocks,
            .lstrip_blocks = options.lstrip_blocks orelse self.lstrip_blocks,
            .newline_sequence = options.newline_sequence orelse self.newline_sequence,
            .keep_trailing_newline = options.keep_trailing_newline orelse self.keep_trailing_newline,
            .autoescape = if (options.autoescape) |ae| ae else self.autoescape,
            .optimized = options.optimized orelse self.optimized,
            .undefined_behavior = self.undefined_behavior,
            .sandboxed = self.sandboxed,
            .enable_async = options.enable_async orelse self.enable_async,
            .finalize = if (options.finalize) |f| f else self.finalize,
            .overlayed = true,
            .linked_to = self,
            .shared = false,
            // Systems - share parent's maps (don't copy, just reference)
            .loader = options.loader orelse self.loader,
            .filters_map = self.filters_map, // Share reference
            .tests_map = self.tests_map, // Share reference
            .globals_map = self.globals_map, // Share reference
            .extension_registry = null, // Will be set up below
            // Create new cache
            .template_cache = null,
            .cache_size = options.cache_size orelse self.cache_size,
            .auto_reload = options.auto_reload orelse self.auto_reload,
        };

        // Create new cache for overlay
        if (rv.cache_size > 0) {
            const lru_cache = try self.allocator.create(LRUCache);
            lru_cache.* = LRUCache.init(self.allocator, rv.cache_size);
            rv.template_cache = lru_cache;
        }

        // Copy and rebind extensions to the new environment
        if (self.extension_registry) |parent_registry| {
            const registry = try self.allocator.create(extensions.ExtensionRegistry);
            registry.* = extensions.ExtensionRegistry.init(self.allocator);
            rv.extension_registry = registry;

            // Rebind all parent extensions to the new overlay environment
            for (parent_registry.extensions.items) |ext| {
                const bound = try ext.bind(rv);
                const bound_ptr = try self.allocator.create(extensions.Extension);
                bound_ptr.* = bound;
                try registry.register(bound_ptr);
            }
        }

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

/// Configuration key for spontaneous environment caching
/// Uses a hash of configuration values to identify equivalent environments
const SpontaneousKey = struct {
    block_start_string: []const u8,
    block_end_string: []const u8,
    variable_start_string: []const u8,
    variable_end_string: []const u8,
    comment_start_string: []const u8,
    comment_end_string: []const u8,
    trim_blocks: bool,
    lstrip_blocks: bool,
    keep_trailing_newline: bool,
    optimized: bool,
    autoescape_bool: bool,

    fn hash(self: SpontaneousKey) u64 {
        var h: u64 = 0;
        h = h *% 31 +% hashString(self.block_start_string);
        h = h *% 31 +% hashString(self.block_end_string);
        h = h *% 31 +% hashString(self.variable_start_string);
        h = h *% 31 +% hashString(self.variable_end_string);
        h = h *% 31 +% hashString(self.comment_start_string);
        h = h *% 31 +% hashString(self.comment_end_string);
        h = h *% 31 +% @intFromBool(self.trim_blocks);
        h = h *% 31 +% @intFromBool(self.lstrip_blocks);
        h = h *% 31 +% @intFromBool(self.keep_trailing_newline);
        h = h *% 31 +% @intFromBool(self.optimized);
        h = h *% 31 +% @intFromBool(self.autoescape_bool);
        return h;
    }

    fn hashString(s: []const u8) u64 {
        var h: u64 = 0;
        for (s) |c| {
            h = h *% 31 +% c;
        }
        return h;
    }
};

/// Cache for spontaneous environments
/// Spontaneous environments are used for templates created directly without an existing environment
var spontaneous_cache: ?std.AutoHashMap(u64, *Environment) = null;
var spontaneous_cache_mutex: std.Thread.Mutex = .{};
const SPONTANEOUS_CACHE_SIZE: usize = 10;

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
    const key = SpontaneousKey{
        .block_start_string = options.block_start_string orelse defaults.BLOCK_START_STRING,
        .block_end_string = options.block_end_string orelse defaults.BLOCK_END_STRING,
        .variable_start_string = options.variable_start_string orelse defaults.VARIABLE_START_STRING,
        .variable_end_string = options.variable_end_string orelse defaults.VARIABLE_END_STRING,
        .comment_start_string = options.comment_start_string orelse defaults.COMMENT_START_STRING,
        .comment_end_string = options.comment_end_string orelse defaults.COMMENT_END_STRING,
        .trim_blocks = options.trim_blocks orelse defaults.TRIM_BLOCKS,
        .lstrip_blocks = options.lstrip_blocks orelse defaults.LSTRIP_BLOCKS,
        .keep_trailing_newline = options.keep_trailing_newline orelse defaults.KEEP_TRAILING_NEWLINE,
        .optimized = options.optimized orelse defaults.OPTIMIZED,
        .autoescape_bool = if (options.autoescape) |ae| switch (ae) {
            .bool => |b| b,
            .function => false,
        } else defaults.AUTOESCAPE,
    };

    const key_hash = key.hash();

    spontaneous_cache_mutex.lock();
    defer spontaneous_cache_mutex.unlock();

    // Initialize cache if needed
    if (spontaneous_cache == null) {
        spontaneous_cache = std.AutoHashMap(u64, *Environment).init(allocator);
    }

    // Check cache
    if (spontaneous_cache.?.get(key_hash)) |env| {
        return env;
    }

    // Create new environment
    var env = Environment.init(allocator);

    // Apply options
    if (options.block_start_string) |v| env.block_start_string = v;
    if (options.block_end_string) |v| env.block_end_string = v;
    if (options.variable_start_string) |v| env.variable_start_string = v;
    if (options.variable_end_string) |v| env.variable_end_string = v;
    if (options.comment_start_string) |v| env.comment_start_string = v;
    if (options.comment_end_string) |v| env.comment_end_string = v;
    if (options.line_statement_prefix) |v| env.line_statement_prefix = v;
    if (options.line_comment_prefix) |v| env.line_comment_prefix = v;
    if (options.trim_blocks) |v| env.trim_blocks = v;
    if (options.lstrip_blocks) |v| env.lstrip_blocks = v;
    if (options.newline_sequence) |v| env.newline_sequence = v;
    if (options.keep_trailing_newline) |v| env.keep_trailing_newline = v;
    if (options.optimized) |v| env.optimized = v;
    if (options.autoescape) |v| env.autoescape = v;
    if (options.loader) |v| env.loader = v;
    if (options.cache_size) |v| env.cache_size = v;
    if (options.auto_reload) |v| env.auto_reload = v;
    if (options.enable_async) |v| env.enable_async = v;
    if (options.finalize) |v| env.finalize = v;

    env.shared = true;

    // Store in cache (evict old entries if needed)
    const env_ptr = try allocator.create(Environment);
    env_ptr.* = env;

    // Simple eviction: if cache is full, clear it
    if (spontaneous_cache.?.count() >= SPONTANEOUS_CACHE_SIZE) {
        // Clear old environments
        var iter = spontaneous_cache.?.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            allocator.destroy(entry.value_ptr.*);
        }
        spontaneous_cache.?.clearRetainingCapacity();
    }

    try spontaneous_cache.?.put(key_hash, env_ptr);

    return env_ptr;
}

/// Clear the spontaneous environment cache
/// This should be called during application shutdown or when you want to reclaim memory
pub fn clearSpontaneousCache(allocator: std.mem.Allocator) void {
    spontaneous_cache_mutex.lock();
    defer spontaneous_cache_mutex.unlock();

    if (spontaneous_cache) |*cache| {
        var iter = cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            allocator.destroy(entry.value_ptr.*);
        }
        cache.deinit();
        spontaneous_cache = null;
    }
}

const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const loaders = vibe_jinja.loaders;
const exceptions = vibe_jinja.exceptions;

test "loader filesystem loader init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var searchpath = [_][]const u8{"test/templates"};
    var loader = try loaders.FileSystemLoader.init(allocator, &searchpath);
    defer loader.deinit();

    try testing.expect(loader.searchpath.len == 1);
    try testing.expectEqualStrings("test/templates", loader.searchpath[0]);
}

test "loader filesystem loader load existing file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a temporary test file
    const test_dir = "test/templates";
    try std.fs.cwd().makePath(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const test_file = "test/templates/test.jinja";
    const file = try std.fs.cwd().createFile(test_file, .{});
    try file.writeAll("Hello {{ name }}!");
    file.close();

    const searchpath = [_][]const u8{"test/templates"};
    var loader = try loaders.FileSystemLoader.init(allocator, &searchpath);
    defer loader.deinit();

    const content = try loader.getLoader().load("test.jinja");
    defer allocator.free(content);

    try testing.expectEqualStrings("Hello {{ name }}!", content);
}

test "loader filesystem loader load non-existent file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const searchpath = [_][]const u8{"test/templates"};
    var loader = try loaders.FileSystemLoader.init(allocator, &searchpath);
    defer loader.deinit();

    const result = loader.getLoader().load("nonexistent.jinja");
    try testing.expectError(exceptions.TemplateError.TemplateNotFound, result);
}

test "loader dict loader init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mapping = std.StringHashMap([]const u8).init(allocator);
    // Note: DictLoader takes ownership of the mapping, so we don't defer cleanup here

    try mapping.put(try allocator.dupe(u8, "test.jinja"), try allocator.dupe(u8, "Hello {{ name }}!"));

    var loader = loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();

    const content = try loader.getLoader().load("test.jinja");
    defer allocator.free(content);

    try testing.expectEqualStrings("Hello {{ name }}!", content);
}

test "loader dict loader load non-existent" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const mapping = std.StringHashMap([]const u8).init(allocator);
    // DictLoader takes ownership, no need to defer deinit here

    var loader = loaders.DictLoader.init(allocator, mapping);
    defer loader.deinit();

    const result = loader.getLoader().load("nonexistent.jinja");
    try testing.expectError(exceptions.TemplateError.TemplateNotFound, result);
}

test "loader function loader" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const loadFn = struct {
        fn load(name: []const u8, alloc: std.mem.Allocator) anyerror!?loaders.FunctionLoaderResult {
            if (std.mem.eql(u8, name, "test.jinja")) {
                return loaders.FunctionLoaderResult{
                    .source = try alloc.dupe(u8, "Hello {{ name }}!"),
                    .filename = null,
                    .uptodate_func = null,
                };
            }
            return null;
        }
    }.load;

    var loader = loaders.FunctionLoader.init(allocator, loadFn);
    defer loader.deinit();

    const content = try loader.getLoader().load("test.jinja");
    defer allocator.free(content);

    try testing.expectEqualStrings("Hello {{ name }}!", content);
}

test "loader function loader not found" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const loadFn = struct {
        fn load(name: []const u8, alloc: std.mem.Allocator) anyerror!?loaders.FunctionLoaderResult {
            _ = name;
            _ = alloc;
            return null; // Template not found
        }
    }.load;

    var loader = loaders.FunctionLoader.init(allocator, loadFn);
    defer loader.deinit();

    const result = loader.getLoader().load("nonexistent.jinja");
    try testing.expectError(exceptions.TemplateError.TemplateNotFound, result);
}

test "loader function loader with uptodate from result" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test uptodate function returned by load function (matches Python's tuple return)
    const TestUptodate = struct {
        fn isUptodate() bool {
            return true; // Always up-to-date
        }
    };

    const loadFn = struct {
        fn load(name: []const u8, alloc: std.mem.Allocator) anyerror!?loaders.FunctionLoaderResult {
            if (std.mem.eql(u8, name, "test.jinja")) {
                return loaders.FunctionLoaderResult{
                    .source = try alloc.dupe(u8, "Hello!"),
                    .filename = null,
                    .uptodate_func = TestUptodate.isUptodate,
                };
            }
            return null;
        }
    }.load;

    var loader = loaders.FunctionLoader.init(allocator, loadFn);
    defer loader.deinit();

    // Load the template first to cache the uptodate function
    const content = try loader.getLoader().load("test.jinja");
    defer allocator.free(content);

    // Now check uptodate - should use the cached function
    try testing.expect(loader.getLoader().uptodate("test.jinja", 0));
}

test "loader function loader with legacy uptodate" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const loadFn = struct {
        fn load(name: []const u8, alloc: std.mem.Allocator) anyerror!?loaders.FunctionLoaderResult {
            if (std.mem.eql(u8, name, "test.jinja")) {
                return loaders.FunctionLoaderResult{
                    .source = try alloc.dupe(u8, "Hello!"),
                    .filename = null,
                    .uptodate_func = null, // No uptodate in result
                };
            }
            return null;
        }
    }.load;

    const legacyUptodateFn = struct {
        fn uptodate(name: []const u8, last_modified: i64) bool {
            _ = name;
            _ = last_modified;
            return true; // Always up-to-date
        }
    }.uptodate;

    var loader = loaders.FunctionLoader.initWithLegacyUptodate(allocator, loadFn, legacyUptodateFn);
    defer loader.deinit();

    try testing.expect(loader.getLoader().uptodate("test.jinja", 0));
}

test "loader function loader with filename" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test returning filename (matches Python's tuple return with filename)
    const loadFn = struct {
        fn load(name: []const u8, alloc: std.mem.Allocator) anyerror!?loaders.FunctionLoaderResult {
            if (std.mem.eql(u8, name, "test.jinja")) {
                return loaders.FunctionLoaderResult{
                    .source = try alloc.dupe(u8, "Hello {{ name }}!"),
                    .filename = try alloc.dupe(u8, "/path/to/test.jinja"),
                    .uptodate_func = null,
                };
            }
            return null;
        }
    }.load;

    var loader = loaders.FunctionLoader.init(allocator, loadFn);
    defer loader.deinit();

    const content = try loader.getLoader().load("test.jinja");
    defer allocator.free(content);

    try testing.expectEqualStrings("Hello {{ name }}!", content);
}

test "loader package loader" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test directory structure
    const test_dir = "test/pkg_templates";
    try std.fs.cwd().makePath(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const test_file = "test/pkg_templates/hello.jinja";
    const test_file_handle = try std.fs.cwd().createFile(test_file, .{});
    try test_file_handle.writeAll("Hello from package!");
    test_file_handle.close();

    // Package loader requires package_path, package_name, and resource_path
    var loader = try loaders.PackageLoader.init(allocator, "test", "test_package", "pkg_templates");
    defer loader.deinit();

    try testing.expectEqualStrings("test_package", loader.package_name);
    try testing.expectEqualStrings("test", loader.package_path);
    try testing.expectEqualStrings("pkg_templates", loader.resource_path);

    // Test loading a template
    const content = try loader.getLoader().load("hello.jinja");
    defer allocator.free(content);
    try testing.expectEqualStrings("Hello from package!", content);
}

test "loader package loader list templates" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test directory structure
    const test_dir = "test/pkg_list_templates";
    try std.fs.cwd().makePath(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create multiple test files
    const files = [_][]const u8{ "index.jinja", "about.jinja" };
    for (files) |filename| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ test_dir, filename });
        defer allocator.free(full_path);
        const file = try std.fs.cwd().createFile(full_path, .{});
        try file.writeAll("Template content");
        file.close();
    }

    var loader = try loaders.PackageLoader.init(allocator, "test", "mypackage", "pkg_list_templates");
    defer loader.deinit();

    const templates = try loader.getLoader().listTemplates();
    defer {
        for (templates) |t| {
            allocator.free(t);
        }
        allocator.free(templates);
    }

    try testing.expect(templates.len == 2);
}

test "loader module loader" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test module directory
    const test_dir = "test/modules";
    try std.fs.cwd().makePath(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Get the expected module filename using SHA1 hash (matches Python's behavior)
    const module_filename = loaders.ModuleLoader.getModuleFilename("index.html");
    
    // Create the module file with the hashed name
    var full_path_buf: [256]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ test_dir, module_filename });
    
    const file = try std.fs.cwd().createFile(full_path, .{});
    try file.writeAll("Precompiled template content");
    file.close();

    // Initialize loader with search paths
    const paths = [_][]const u8{test_dir};
    var loader = try loaders.ModuleLoader.init(allocator, &paths);
    defer loader.deinit();

    try testing.expect(loader.paths.len == 1);
    try testing.expectEqualStrings(test_dir, loader.paths[0]);

    // Test loading a template by name (loader uses SHA1 hash internally)
    const content = try loader.getLoader().load("index.html");
    defer allocator.free(content);
    try testing.expectEqualStrings("Precompiled template content", content);
}

test "loader module loader get_template_key" {
    // Test that getTemplateKey produces consistent SHA1-based keys
    const key1 = loaders.ModuleLoader.getTemplateKey("index.html");
    const key2 = loaders.ModuleLoader.getTemplateKey("index.html");
    
    // Same input should produce same key
    try testing.expectEqualStrings(&key1, &key2);
    
    // Key should start with "tmpl_"
    try testing.expect(std.mem.startsWith(u8, &key1, "tmpl_"));
    
    // Key should be 45 chars: "tmpl_" (5) + 40 hex chars (SHA1)
    try testing.expect(key1.len == 45);
    
    // Different inputs should produce different keys
    const key3 = loaders.ModuleLoader.getTemplateKey("about.html");
    try testing.expect(!std.mem.eql(u8, &key1, &key3));
}

test "loader module loader get_module_filename" {
    // Test that getModuleFilename produces .zig files
    const filename = loaders.ModuleLoader.getModuleFilename("index.html");
    
    // Filename should end with .zig
    try testing.expect(std.mem.endsWith(u8, &filename, ".zig"));
    
    // Filename should be 49 chars: "tmpl_" (5) + 40 hex + ".zig" (4)
    try testing.expect(filename.len == 49);
}

test "loader module loader register template" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test registering templates directly (alternative to file-based loading)
    const paths = [_][]const u8{};
    var loader = try loaders.ModuleLoader.init(allocator, &paths);
    defer loader.deinit();

    // Register a template
    try loader.registerTemplate("greeting.html", "Hello, World!");
    
    // Load the registered template
    const content = try loader.getLoader().load("greeting.html");
    defer allocator.free(content);
    try testing.expectEqualStrings("Hello, World!", content);
}

test "loader module loader has_source_access" {
    // ModuleLoader should indicate it cannot provide source access
    // (it loads precompiled templates)
    try testing.expect(loaders.ModuleLoader.has_source_access == false);
}

test "loader choice loader" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a dict loader with a template
    var mapping = std.StringHashMap([]const u8).init(allocator);
    try mapping.put(try allocator.dupe(u8, "test.jinja"), try allocator.dupe(u8, "Hello from dict!"));

    var loader1 = loaders.DictLoader.init(allocator, mapping);
    defer loader1.deinit();

    // Create another dict loader
    var mapping2 = std.StringHashMap([]const u8).init(allocator);
    try mapping2.put(try allocator.dupe(u8, "other.jinja"), try allocator.dupe(u8, "Other template"));

    var loader2 = loaders.DictLoader.init(allocator, mapping2);
    defer loader2.deinit();

    var loaders_list = [_]*loaders.Loader{ loader1.getLoader(), loader2.getLoader() };
    var choice_loader = try loaders.ChoiceLoader.init(allocator, &loaders_list);
    defer choice_loader.deinit();

    // Should find template in first loader (dict)
    const content = try choice_loader.getLoader().load("test.jinja");
    defer allocator.free(content);

    try testing.expectEqualStrings("Hello from dict!", content);
}

test "loader choice loader fallback" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // First loader is empty
    const mapping1 = std.StringHashMap([]const u8).init(allocator);

    var loader1 = loaders.DictLoader.init(allocator, mapping1);
    defer loader1.deinit();

    // Second loader has the template
    var mapping2 = std.StringHashMap([]const u8).init(allocator);
    try mapping2.put(try allocator.dupe(u8, "fallback.jinja"), try allocator.dupe(u8, "Fallback content"));

    var loader2 = loaders.DictLoader.init(allocator, mapping2);
    defer loader2.deinit();

    var loaders_list = [_]*loaders.Loader{ loader1.getLoader(), loader2.getLoader() };
    var choice_loader = try loaders.ChoiceLoader.init(allocator, &loaders_list);
    defer choice_loader.deinit();

    // Should fall back to second loader
    const content = try choice_loader.getLoader().load("fallback.jinja");
    defer allocator.free(content);

    try testing.expectEqualStrings("Fallback content", content);
}

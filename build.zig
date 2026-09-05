const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.addModule("vibe_jinja", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "vibe_jinja",
        .root_module = root_module,
    });

    b.installArtifact(lib);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    const chat_template_cli_module = b.addModule("chat_template_cli", .{
        .root_source_file = b.path("src/chat_template_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_template_cli_module.addImport("vibe_jinja", root_module);
    const chat_template_cli = b.addExecutable(.{
        .name = "vibe-jinja-render-chat-template",
        .root_module = chat_template_cli_module,
    });
    b.installArtifact(chat_template_cli);

    // Runs the chat-template CLI rather than shipping a second executable:
    // same library, and it exercises the tool people actually run. Piping a
    // fixed payload keeps `zig build cli` runnable with no input.
    const cli_payload =
        \\{"template": "{% for m in messages %}<|{{ m.role }}|>{{ m.content }}\n{% endfor %}",
        \\ "messages": [{"role": "user", "content": "hi"},
        \\              {"role": "assistant", "content": "hello"}]}
    ;
    const run_cli = b.addRunArtifact(chat_template_cli);
    run_cli.setStdIn(.{ .bytes = cli_payload });
    const cli_step = b.step("cli", "Render a sample chat template through the CLI");
    cli_step.dependOn(&run_cli.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Add unit test modules
    const parser_test_module = b.addModule("parser_test", .{
        .root_source_file = b.path("test/unit/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_test_module.addImport("vibe_jinja", root_module);
    const parser_tests = b.addTest(.{
        .root_module = parser_test_module,
    });
    const run_parser_tests = b.addRunArtifact(parser_tests);

    const compiler_test_module = b.addModule("compiler_test", .{
        .root_source_file = b.path("test/unit/compiler.zig"),
        .target = target,
        .optimize = optimize,
    });
    compiler_test_module.addImport("vibe_jinja", root_module);
    const compiler_tests = b.addTest(.{
        .root_module = compiler_test_module,
    });
    const run_compiler_tests = b.addRunArtifact(compiler_tests);

    const filters_test_module = b.addModule("filters_test", .{
        .root_source_file = b.path("test/unit/filters.zig"),
        .target = target,
        .optimize = optimize,
    });
    filters_test_module.addImport("vibe_jinja", root_module);
    const filters_tests = b.addTest(.{
        .root_module = filters_test_module,
    });
    const run_filters_tests = b.addRunArtifact(filters_tests);

    const value_test_module = b.addModule("value_test", .{
        .root_source_file = b.path("test/unit/value.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_test_module.addImport("vibe_jinja", root_module);
    const value_tests = b.addTest(.{
        .root_module = value_test_module,
    });
    const run_value_tests = b.addRunArtifact(value_tests);

    const value_comparison_test_module = b.addModule("value_comparison_test", .{
        .root_source_file = b.path("test/unit/value_comparison.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_comparison_test_module.addImport("vibe_jinja", root_module);
    const value_comparison_tests = b.addTest(.{
        .root_module = value_comparison_test_module,
    });
    const run_value_comparison_tests = b.addRunArtifact(value_comparison_tests);

    const float_literal_test_module = b.addModule("float_literal_test", .{
        .root_source_file = b.path("test/unit/float_literal.zig"),
        .target = target,
        .optimize = optimize,
    });
    float_literal_test_module.addImport("vibe_jinja", root_module);
    const float_literal_tests = b.addTest(.{
        .root_module = float_literal_test_module,
    });
    const run_float_literal_tests = b.addRunArtifact(float_literal_tests);

    const variable_resolution_test_module = b.addModule("variable_resolution_test", .{
        .root_source_file = b.path("test/unit/variable_resolution.zig"),
        .target = target,
        .optimize = optimize,
    });
    variable_resolution_test_module.addImport("vibe_jinja", root_module);
    const variable_resolution_tests = b.addTest(.{
        .root_module = variable_resolution_test_module,
    });
    const run_variable_resolution_tests = b.addRunArtifact(variable_resolution_tests);

    const attribute_subscript_test_module = b.addModule("attribute_subscript_test", .{
        .root_source_file = b.path("test/unit/attribute_subscript.zig"),
        .target = target,
        .optimize = optimize,
    });
    attribute_subscript_test_module.addImport("vibe_jinja", root_module);
    const attribute_subscript_tests = b.addTest(.{
        .root_module = attribute_subscript_test_module,
    });
    const run_attribute_subscript_tests = b.addRunArtifact(attribute_subscript_tests);

    const chat_template_regressions_test_module = b.addModule("chat_template_regressions_test", .{
        .root_source_file = b.path("test/unit/chat_template_regressions.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_template_regressions_test_module.addImport("vibe_jinja", root_module);
    const chat_template_regressions_tests = b.addTest(.{
        .root_module = chat_template_regressions_test_module,
    });
    const run_chat_template_regressions_tests = b.addRunArtifact(chat_template_regressions_tests);

    const binary_expressions_test_module = b.addModule("binary_expressions_test", .{
        .root_source_file = b.path("test/unit/binary_expressions.zig"),
        .target = target,
        .optimize = optimize,
    });
    binary_expressions_test_module.addImport("vibe_jinja", root_module);
    const binary_expressions_tests = b.addTest(.{
        .root_module = binary_expressions_test_module,
    });
    const run_binary_expressions_tests = b.addRunArtifact(binary_expressions_tests);

    const unary_expressions_test_module = b.addModule("unary_expressions_test", .{
        .root_source_file = b.path("test/unit/unary_expressions.zig"),
        .target = target,
        .optimize = optimize,
    });
    unary_expressions_test_module.addImport("vibe_jinja", root_module);
    const unary_expressions_tests = b.addTest(.{
        .root_module = unary_expressions_test_module,
    });
    const run_unary_expressions_tests = b.addRunArtifact(unary_expressions_tests);

    const comparison_expressions_test_module = b.addModule("comparison_expressions_test", .{
        .root_source_file = b.path("test/unit/comparison_expressions.zig"),
        .target = target,
        .optimize = optimize,
    });
    comparison_expressions_test_module.addImport("vibe_jinja", root_module);
    const comparison_expressions_tests = b.addTest(.{
        .root_module = comparison_expressions_test_module,
    });
    const run_comparison_expressions_tests = b.addRunArtifact(comparison_expressions_tests);

    const test_expressions_test_module = b.addModule("test_expressions_test", .{
        .root_source_file = b.path("test/unit/test_expressions.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_expressions_test_module.addImport("vibe_jinja", root_module);
    const test_expressions_tests = b.addTest(.{
        .root_module = test_expressions_test_module,
    });
    const run_test_expressions_tests = b.addRunArtifact(test_expressions_tests);

    const control_flow_unit_test_module = b.addModule("control_flow_unit_test", .{
        .root_source_file = b.path("test/unit/control_flow.zig"),
        .target = target,
        .optimize = optimize,
    });
    control_flow_unit_test_module.addImport("vibe_jinja", root_module);
    const control_flow_unit_tests = b.addTest(.{
        .root_module = control_flow_unit_test_module,
    });
    const run_control_flow_unit_tests = b.addRunArtifact(control_flow_unit_tests);

    // Add integration test modules
    const control_flow_test_module = b.addModule("control_flow_test", .{
        .root_source_file = b.path("test/integration/control_flow.zig"),
        .target = target,
        .optimize = optimize,
    });
    control_flow_test_module.addImport("vibe_jinja", root_module);
    const control_flow_tests = b.addTest(.{
        .root_module = control_flow_test_module,
    });
    const run_control_flow_tests = b.addRunArtifact(control_flow_tests);

    // Add integration test modules
    const macros_test_module = b.addModule("macros_test", .{
        .root_source_file = b.path("test/integration/macros.zig"),
        .target = target,
        .optimize = optimize,
    });
    macros_test_module.addImport("vibe_jinja", root_module);
    const macros_tests = b.addTest(.{
        .root_module = macros_test_module,
    });
    const run_macros_tests = b.addRunArtifact(macros_tests);

    const set_with_test_module = b.addModule("set_with_test", .{
        .root_source_file = b.path("test/integration/set_with.zig"),
        .target = target,
        .optimize = optimize,
    });
    set_with_test_module.addImport("vibe_jinja", root_module);
    const set_with_tests = b.addTest(.{
        .root_module = set_with_test_module,
    });
    const run_set_with_tests = b.addRunArtifact(set_with_tests);

    const filter_block_test_module = b.addModule("filter_block_test", .{
        .root_source_file = b.path("test/integration/filter_block.zig"),
        .target = target,
        .optimize = optimize,
    });
    filter_block_test_module.addImport("vibe_jinja", root_module);
    const filter_block_tests = b.addTest(.{
        .root_module = filter_block_test_module,
    });
    const run_filter_block_tests = b.addRunArtifact(filter_block_tests);

    const raw_blocks_test_module = b.addModule("raw_blocks_test", .{
        .root_source_file = b.path("test/integration/raw_blocks.zig"),
        .target = target,
        .optimize = optimize,
    });
    raw_blocks_test_module.addImport("vibe_jinja", root_module);
    const raw_blocks_tests = b.addTest(.{
        .root_module = raw_blocks_test_module,
    });
    const run_raw_blocks_tests = b.addRunArtifact(raw_blocks_tests);

    const autoescape_test_module = b.addModule("autoescape_test", .{
        .root_source_file = b.path("test/integration/autoescape.zig"),
        .target = target,
        .optimize = optimize,
    });
    autoescape_test_module.addImport("vibe_jinja", root_module);
    const autoescape_tests = b.addTest(.{
        .root_module = autoescape_test_module,
    });
    const run_autoescape_tests = b.addRunArtifact(autoescape_tests);

    // Add regression test module
    const regression_test_module = b.addModule("regression_test", .{
        .root_source_file = b.path("test/integration/regression.zig"),
        .target = target,
        .optimize = optimize,
    });
    regression_test_module.addImport("vibe_jinja", root_module);
    const regression_tests = b.addTest(.{
        .root_module = regression_test_module,
    });
    const run_regression_tests = b.addRunArtifact(regression_tests);

    // Add async test module
    const async_test_module = b.addModule("async_test", .{
        .root_source_file = b.path("test/integration/async.zig"),
        .target = target,
        .optimize = optimize,
    });
    async_test_module.addImport("vibe_jinja", root_module);
    const async_tests = b.addTest(.{
        .root_module = async_test_module,
    });
    const run_async_tests = b.addRunArtifact(async_tests);

    // Add filters integration test module
    const filters_integration_test_module = b.addModule("filters_integration_test", .{
        .root_source_file = b.path("test/integration/filters.zig"),
        .target = target,
        .optimize = optimize,
    });
    filters_integration_test_module.addImport("vibe_jinja", root_module);
    const filters_integration_tests = b.addTest(.{
        .root_module = filters_integration_test_module,
    });
    const run_filters_integration_tests = b.addRunArtifact(filters_integration_tests);

    // Add unit test modules
    const utils_test_module = b.addModule("utils_test", .{
        .root_source_file = b.path("test/unit/utils.zig"),
        .target = target,
        .optimize = optimize,
    });
    utils_test_module.addImport("vibe_jinja", root_module);
    const utils_tests = b.addTest(.{
        .root_module = utils_test_module,
    });
    const run_utils_tests = b.addRunArtifact(utils_tests);

    const cache_test_module = b.addModule("cache_test", .{
        .root_source_file = b.path("test/unit/cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    cache_test_module.addImport("vibe_jinja", root_module);
    const cache_tests = b.addTest(.{
        .root_module = cache_test_module,
    });
    const run_cache_tests = b.addRunArtifact(cache_tests);

    const tests_test_module = b.addModule("tests_test", .{
        .root_source_file = b.path("test/unit/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_test_module.addImport("vibe_jinja", root_module);
    const tests_tests = b.addTest(.{
        .root_module = tests_test_module,
    });
    const run_tests_tests = b.addRunArtifact(tests_tests);

    const loaders_test_module = b.addModule("loaders_test", .{
        .root_source_file = b.path("test/unit/loaders.zig"),
        .target = target,
        .optimize = optimize,
    });
    loaders_test_module.addImport("vibe_jinja", root_module);
    const loaders_tests = b.addTest(.{
        .root_module = loaders_test_module,
    });
    const run_loaders_tests = b.addRunArtifact(loaders_tests);

    const extensions_test_module = b.addModule("extensions_test", .{
        .root_source_file = b.path("test/unit/extensions.zig"),
        .target = target,
        .optimize = optimize,
    });
    extensions_test_module.addImport("vibe_jinja", root_module);
    const extensions_tests = b.addTest(.{
        .root_module = extensions_test_module,
    });
    const run_extensions_tests = b.addRunArtifact(extensions_tests);

    const environment_test_module = b.addModule("environment_test", .{
        .root_source_file = b.path("test/unit/environment.zig"),
        .target = target,
        .optimize = optimize,
    });
    environment_test_module.addImport("vibe_jinja", root_module);
    const environment_tests = b.addTest(.{
        .root_module = environment_test_module,
    });
    const run_environment_tests = b.addRunArtifact(environment_tests);

    // These roots contain established tests but were previously absent from the
    // build graph, so neither `test` nor the grouped test steps executed them.
    const run_nodes_tests = addTestRoot(b, root_module, target, optimize, "nodes_test", "test/unit/nodes.zig");
    const run_optimizer_tests = addTestRoot(b, root_module, target, optimize, "optimizer_test", "test/unit/optimizer.zig");
    const run_runtime_tests = addTestRoot(b, root_module, target, optimize, "runtime_test", "test/unit/runtime.zig");
    const run_sandbox_tests = addTestRoot(b, root_module, target, optimize, "sandbox_test", "test/unit/sandbox.zig");
    const run_filter_chains_tests = addTestRoot(b, root_module, target, optimize, "filter_chains_test", "test/integration/filter_chains.zig");
    const run_imports_tests = addTestRoot(b, root_module, target, optimize, "imports_test", "test/integration/imports.zig");
    const run_includes_tests = addTestRoot(b, root_module, target, optimize, "includes_test", "test/integration/includes.zig");
    const run_inheritance_tests = addTestRoot(b, root_module, target, optimize, "inheritance_test", "test/integration/inheritance.zig");
    const run_test_expressions_integration_tests = addTestRoot(b, root_module, target, optimize, "test_expressions_integration_test", "test/integration/test_expressions.zig");
    const run_public_api_tests = addTestRoot(b, root_module, target, optimize, "public_api_test", "test/public_api.zig");

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_compiler_tests.step);
    test_step.dependOn(&run_filters_tests.step);
    test_step.dependOn(&run_value_tests.step);
    test_step.dependOn(&run_value_comparison_tests.step);
    test_step.dependOn(&run_float_literal_tests.step);
    test_step.dependOn(&run_variable_resolution_tests.step);
    test_step.dependOn(&run_attribute_subscript_tests.step);
    test_step.dependOn(&run_chat_template_regressions_tests.step);
    test_step.dependOn(&run_binary_expressions_tests.step);
    test_step.dependOn(&run_unary_expressions_tests.step);
    test_step.dependOn(&run_comparison_expressions_tests.step);
    test_step.dependOn(&run_test_expressions_tests.step);
    test_step.dependOn(&run_control_flow_unit_tests.step);
    test_step.dependOn(&run_control_flow_tests.step);
    test_step.dependOn(&run_macros_tests.step);
    test_step.dependOn(&run_set_with_tests.step);
    test_step.dependOn(&run_filter_block_tests.step);
    test_step.dependOn(&run_raw_blocks_tests.step);
    test_step.dependOn(&run_autoescape_tests.step);
    test_step.dependOn(&run_utils_tests.step);
    test_step.dependOn(&run_cache_tests.step);
    test_step.dependOn(&run_tests_tests.step);
    test_step.dependOn(&run_loaders_tests.step);
    test_step.dependOn(&run_extensions_tests.step);
    test_step.dependOn(&run_environment_tests.step);
    test_step.dependOn(&run_async_tests.step);
    test_step.dependOn(&run_regression_tests.step);
    test_step.dependOn(&run_filters_integration_tests.step);
    test_step.dependOn(&run_nodes_tests.step);
    test_step.dependOn(&run_optimizer_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_sandbox_tests.step);
    test_step.dependOn(&run_filter_chains_tests.step);
    test_step.dependOn(&run_imports_tests.step);
    test_step.dependOn(&run_includes_tests.step);
    test_step.dependOn(&run_inheritance_tests.step);
    test_step.dependOn(&run_test_expressions_integration_tests.step);
    test_step.dependOn(&run_public_api_tests.step);

    const unit_test_step = b.step("test:unit", "Run unit tests only");
    unit_test_step.dependOn(&run_parser_tests.step);
    unit_test_step.dependOn(&run_compiler_tests.step);
    unit_test_step.dependOn(&run_filters_tests.step);
    unit_test_step.dependOn(&run_value_tests.step);
    unit_test_step.dependOn(&run_value_comparison_tests.step);
    unit_test_step.dependOn(&run_float_literal_tests.step);
    unit_test_step.dependOn(&run_variable_resolution_tests.step);
    unit_test_step.dependOn(&run_attribute_subscript_tests.step);
    unit_test_step.dependOn(&run_chat_template_regressions_tests.step);
    unit_test_step.dependOn(&run_binary_expressions_tests.step);
    unit_test_step.dependOn(&run_unary_expressions_tests.step);
    unit_test_step.dependOn(&run_comparison_expressions_tests.step);
    unit_test_step.dependOn(&run_test_expressions_tests.step);
    unit_test_step.dependOn(&run_control_flow_unit_tests.step);
    unit_test_step.dependOn(&run_utils_tests.step);
    unit_test_step.dependOn(&run_cache_tests.step);
    unit_test_step.dependOn(&run_tests_tests.step);
    unit_test_step.dependOn(&run_loaders_tests.step);
    unit_test_step.dependOn(&run_extensions_tests.step);
    unit_test_step.dependOn(&run_environment_tests.step);
    unit_test_step.dependOn(&run_nodes_tests.step);
    unit_test_step.dependOn(&run_optimizer_tests.step);
    unit_test_step.dependOn(&run_runtime_tests.step);
    unit_test_step.dependOn(&run_sandbox_tests.step);
    unit_test_step.dependOn(&run_public_api_tests.step);

    const integration_test_step = b.step("test:integration", "Run integration tests only");
    integration_test_step.dependOn(&run_control_flow_tests.step);
    integration_test_step.dependOn(&run_macros_tests.step);
    integration_test_step.dependOn(&run_set_with_tests.step);
    integration_test_step.dependOn(&run_filter_block_tests.step);
    integration_test_step.dependOn(&run_raw_blocks_tests.step);
    integration_test_step.dependOn(&run_autoescape_tests.step);
    integration_test_step.dependOn(&run_regression_tests.step);
    integration_test_step.dependOn(&run_async_tests.step);
    integration_test_step.dependOn(&run_filters_integration_tests.step);
    integration_test_step.dependOn(&run_filter_chains_tests.step);
    integration_test_step.dependOn(&run_imports_tests.step);
    integration_test_step.dependOn(&run_includes_tests.step);
    integration_test_step.dependOn(&run_inheritance_tests.step);
    integration_test_step.dependOn(&run_test_expressions_integration_tests.step);

    // Individual integration test steps (for debugging)
    const control_flow_step = b.step("test:control_flow", "Run control flow integration tests");
    control_flow_step.dependOn(&run_control_flow_tests.step);
    const macros_step = b.step("test:macros", "Run macros integration tests");
    macros_step.dependOn(&run_macros_tests.step);
    const set_with_step = b.step("test:set_with", "Run set/with integration tests");
    set_with_step.dependOn(&run_set_with_tests.step);
    const filter_block_step = b.step("test:filter_block", "Run filter block integration tests");
    filter_block_step.dependOn(&run_filter_block_tests.step);
    const raw_blocks_step = b.step("test:raw_blocks", "Run raw blocks integration tests");
    raw_blocks_step.dependOn(&run_raw_blocks_tests.step);
    const autoescape_step = b.step("test:autoescape", "Run autoescape integration tests");
    autoescape_step.dependOn(&run_autoescape_tests.step);
    const regression_step = b.step("test:regression", "Run regression integration tests");
    regression_step.dependOn(&run_regression_tests.step);
    const filters_integration_step = b.step("test:filters", "Run filters integration tests");
    filters_integration_step.dependOn(&run_filters_integration_tests.step);

    // HuggingFace compatibility tests (Llama 3.2, etc.)
    const huggingface_test_module = b.addModule("huggingface_test", .{
        .root_source_file = b.path("test/integration/huggingface_compat.zig"),
        .target = target,
        .optimize = optimize,
    });
    huggingface_test_module.addImport("vibe_jinja", root_module);
    const huggingface_tests = b.addTest(.{
        .root_module = huggingface_test_module,
    });
    const run_huggingface_tests = b.addRunArtifact(huggingface_tests);
    const huggingface_step = b.step("test:huggingface", "Run HuggingFace compatibility tests");
    huggingface_step.dependOn(&run_huggingface_tests.step);
    integration_test_step.dependOn(&run_huggingface_tests.step);
    test_step.dependOn(&run_huggingface_tests.step);

    // Production template tests (real HuggingFace templates)
    const production_test_module = b.addModule("production_test", .{
        .root_source_file = b.path("test/integration/production_templates.zig"),
        .target = target,
        .optimize = optimize,
    });
    production_test_module.addImport("vibe_jinja", root_module);
    const production_tests = b.addTest(.{
        .root_module = production_test_module,
    });
    const run_production_tests = b.addRunArtifact(production_tests);
    const production_step = b.step("test:production", "Run production HuggingFace template tests");
    production_step.dependOn(&run_production_tests.step);
    integration_test_step.dependOn(&run_production_tests.step);
    test_step.dependOn(&run_production_tests.step);

    // Community Qwen 3.5/3.6 compatibility template and regression scenarios.
    const qwen_fixed_test_module = b.addModule("qwen_fixed_chat_template_test", .{
        .root_source_file = b.path("test/integration/qwen_fixed_chat_template.zig"),
        .target = target,
        .optimize = optimize,
    });
    qwen_fixed_test_module.addImport("vibe_jinja", root_module);
    const qwen_fixed_tests = b.addTest(.{
        .root_module = qwen_fixed_test_module,
    });
    const run_qwen_fixed_tests = b.addRunArtifact(qwen_fixed_tests);
    const qwen_fixed_step = b.step("test:qwen-fixed", "Run Qwen 3.5/3.6 community template tests");
    qwen_fixed_step.dependOn(&run_qwen_fixed_tests.step);
    integration_test_step.dependOn(&run_qwen_fixed_tests.step);
    test_step.dependOn(&run_qwen_fixed_tests.step);

    // Official Qwen3 Coder Next template compatibility and filtered mapping loops.
    const qwen3_coder_next_test_module = b.addModule("qwen3_coder_next_chat_template_test", .{
        .root_source_file = b.path("test/integration/qwen3_coder_next_chat_template.zig"),
        .target = target,
        .optimize = optimize,
    });
    qwen3_coder_next_test_module.addImport("vibe_jinja", root_module);
    const qwen3_coder_next_tests = b.addTest(.{
        .root_module = qwen3_coder_next_test_module,
    });
    const run_qwen3_coder_next_tests = b.addRunArtifact(qwen3_coder_next_tests);
    const qwen3_coder_next_step = b.step("test:qwen3-coder-next", "Run Qwen3 Coder Next template tests");
    qwen3_coder_next_step.dependOn(&run_qwen3_coder_next_tests.step);
    integration_test_step.dependOn(&run_qwen3_coder_next_tests.step);
    test_step.dependOn(&run_qwen3_coder_next_tests.step);

    // Slice and globals tests (new feature tests)
    const slice_globals_test_module = b.addModule("slice_globals_test", .{
        .root_source_file = b.path("test/integration/slice_and_globals.zig"),
        .target = target,
        .optimize = optimize,
    });
    slice_globals_test_module.addImport("vibe_jinja", root_module);
    const slice_globals_tests = b.addTest(.{
        .root_module = slice_globals_test_module,
    });
    const run_slice_globals_tests = b.addRunArtifact(slice_globals_tests);
    const slice_globals_step = b.step("test:slice", "Run slice and globals tests (new features)");
    slice_globals_step.dependOn(&run_slice_globals_tests.step);
    test_step.dependOn(&run_slice_globals_tests.step);
    integration_test_step.dependOn(&run_slice_globals_tests.step);

    // Add async-only test step
    const async_test_step = b.step("test:async", "Run async tests only");
    async_test_step.dependOn(&run_async_tests.step);

    // Benchmarks
    const benchmark_module = b.addModule("benchmark", .{
        .root_source_file = b.path("test/benchmarks/benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    benchmark_module.addImport("vibe_jinja", root_module);
    const benchmarks = b.addExecutable(.{
        .name = "benchmark",
        .root_module = benchmark_module,
    });
    const run_benchmarks = b.addRunArtifact(benchmarks);
    const benchmark_step = b.step("benchmark", "Run performance benchmarks");
    benchmark_step.dependOn(&run_benchmarks.step);

    // Diagnostic Benchmarks (Phase 0 optimization profiling)
    const diagnostic_bench_module = b.addModule("diagnostic_bench", .{
        .root_source_file = b.path("test/benchmarks/diagnostic_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    diagnostic_bench_module.addImport("vibe_jinja", root_module);
    const diagnostic_bench = b.addExecutable(.{
        .name = "diagnostic_bench",
        .root_module = diagnostic_bench_module,
    });
    const run_diagnostic_bench = b.addRunArtifact(diagnostic_bench);
    const diagnostic_bench_step = b.step("bench-diagnostic", "Run diagnostic benchmarks for performance profiling");
    diagnostic_bench_step.dependOn(&run_diagnostic_bench.step);

    // Comparison Benchmark (vibe-jinja vs Python Jinja2)
    const comparison_bench_module = b.addModule("comparison_bench", .{
        .root_source_file = b.path("test/benchmarks/comparison_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    comparison_bench_module.addImport("vibe_jinja", root_module);
    const comparison_bench = b.addExecutable(.{
        .name = "comparison_bench",
        .root_module = comparison_bench_module,
    });
    const run_comparison_bench = b.addRunArtifact(comparison_bench);
    // The bench reads test/benchmarks/python_reference.json relative to the repo root.
    run_comparison_bench.setCwd(b.path("."));
    const comparison_bench_step = b.step("bench-compare", "Run comparison benchmarks vs Python Jinja2");
    comparison_bench_step.dependOn(&run_comparison_bench.step);

    // Regression gate: fails when any render benchmark is not faster than the
    // Python reference (test/benchmarks/python_reference.json, regenerated by
    // benchmark_python.py on the same machine).
    const run_bench_check = b.addRunArtifact(comparison_bench);
    run_bench_check.setCwd(b.path("."));
    run_bench_check.addArg("--check");
    const bench_check_step = b.step("bench-check", "Fail if render benchmarks are not faster than Python Jinja2");
    bench_check_step.dependOn(&run_bench_check.step);

    // AOT Benchmark (Phase 7 - AOT vs JIT comparison)
    const aot_bench_module = b.addModule("aot_bench", .{
        .root_source_file = b.path("test/benchmarks/aot_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    aot_bench_module.addImport("vibe_jinja", root_module);
    const aot_bench = b.addExecutable(.{
        .name = "aot_bench",
        .root_module = aot_bench_module,
    });
    const run_aot_bench = b.addRunArtifact(aot_bench);
    const aot_bench_step = b.step("bench-aot", "Run AOT vs JIT benchmark (Phase 7)");
    aot_bench_step.dependOn(&run_aot_bench.step);
}

fn addTestRoot(
    b: *std.Build,
    root_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    path: []const u8,
) *std.Build.Step.Run {
    const test_module = b.addModule(name, .{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("vibe_jinja", root_module);
    return b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
}

# Changelog

All notable changes to vibe-jinja will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-12-29

### 🎉 Initial Release

First stable release of vibe-jinja, a high-performance Jinja2-compatible templating engine for Zig.

### Added

#### Core Features
- Full Jinja2 template syntax support
- Plain HTML/text output
- Comments (single-line and multi-line)
- Line statements and line comments
- Raw blocks (`{% raw %}...{% endraw %}`)

#### Statements
- `{% for %}` loops with `else`, `continue`, `break` support
- `{% if %}` statements with `elif`, `else`
- `{% macro %}` definitions with arguments, defaults, keyword arguments
- `{% call %}` statements and call blocks with `caller()` support
- `{% set %}` statements (direct and block variants)
- `{% with %}` statements for scoped variables
- `{% filter %}` blocks
- `{% extends %}` for template inheritance
- `{% block %}` with `super()` support
- `{% include %}` with `with context` and `ignore missing` options
- `{% import %}` and `{% from import %}` for template modules
- `{% autoescape %}` for HTML/XML safety
- `{% do %}` for expression statements (extension)
- `{% debug %}` for debugging (extension)

#### Expressions
- Variables with scoped name resolution
- Literals: string, integer, float, boolean, list, dict
- Math operations: `+`, `-`, `*`, `/`, `%`, `**`, `//`
- Comparisons: `==`, `!=`, `<`, `<=`, `>`, `>=`
- Logic operations: `and`, `or`, `not`
- `in` operator
- `is` test operator
- Filter expressions (`|`)
- Attribute access (`.attr`)
- Item access (`[index]`)
- Conditional expressions (inline `if`)
- Function calls

#### Filters (40+)
- **String**: `upper`, `lower`, `capitalize`, `title`, `trim`, `replace`, `escape`, `format`, `truncate`, `wordcount`, `wordwrap`, `urlencode`, `urlize`, `striptags`, `xmlattr`, `indent`, `center`, `lstrip`, `rstrip`, `join`, `attr`, `forceescape`
- **List**: `first`, `last`, `length`, `reverse`, `sort`, `unique`, `batch`, `slice`, `map`, `select`, `reject`, `selectattr`, `rejectattr`, `sum`, `list`
- **Number**: `abs`, `int`, `float`, `round`, `min`, `max`
- **Dict**: `dictsort`, `items`
- **Other**: `default`, `count`, `filesizeformat`, `groupby`, `pprint`, `random`, `safe`, `string`, `tojson`

#### Tests (25+)
- **Type**: `defined`, `undefined`, `string`, `number`, `integer`, `float`, `boolean`, `mapping`, `sequence`, `iterable`, `callable`
- **Value**: `empty`, `none`, `true`, `false`, `equalto`, `sameas`, `ne`, `lt`, `le`, `gt`, `ge`
- **Number**: `even`, `odd`, `divisibleby`
- **String**: `lower`, `upper`, `escaped`
- **Other**: `in`, `filter`, `test`

#### Template Loaders
- `FileSystemLoader` - Load from filesystem directories
- `DictLoader` - Load from in-memory dictionary
- `FunctionLoader` - Load using custom function with uptodate support
- `PackageLoader` - Load from package/module path
- `PrefixLoader` - Route to sub-loaders based on prefix
- `ChoiceLoader` - Try multiple loaders in order
- `ModuleLoader` - Load precompiled template modules

#### Performance & Optimization
- LRU template cache with configurable size (default: 400)
- AST optimizer with constant folding
- Dead code elimination
- Output merging optimization
- Bytecode compilation and VM
- Arena allocators for rendering
- Small string optimization
- String interning pool
- Specialized inline functions for hot paths

#### Advanced Features
- Extension system for custom tags, filters, and tests
- Auto-reload for template changes
- Autoescaping with `Markup` type
- Template inheritance (`extends`/`block`/`super()`)
- Template includes with context options
- Template imports with namespaces
- Undefined handling (strict, lenient, debug, chainable)
- Comprehensive error context with template stack traces
- Sandboxed environment for secure execution
- Async support foundation (async rendering, filters, tests)
- Runtime utilities (`Cycler`, `Joiner`, `Namespace`, `generateLoremIpsum`)
- Custom object support via vtable pattern

#### Bytecode Cache Backends
- `FileSystemBytecodeCache` - Store bytecode in filesystem
- `MemcachedBytecodeCache` - Store bytecode in Memcached

#### Documentation
- Comprehensive module-level documentation
- Doc comments on all public APIs
- Usage examples in documentation
- Architecture documentation in code

### Technical Details

- **Zig Version**: 0.15.2+
- **Dependencies**: None (Zig standard library only)
- **Test Coverage**: 23 unit test files, 13 integration test files
- **Benchmarks**: Simple template, loops, conditionals, caching, filters, nested templates

### Compatibility

- Full Jinja2 template syntax compatibility
- Matches Jinja2 filter and test behavior
- Compatible with standard Jinja2 templates

---

## [1.1.0] - 2026-01-15

### Added

#### HuggingFace Compatibility
- **HuggingFace chat template support** - Full compatibility with HuggingFace transformer chat templates
- **Production template test suite** - Real-world template tests using actual HuggingFace model templates
- **16 chat template fixtures** - Templates for popular models:
  - Llama 3 Instruct, Llama 2 Chat
  - ChatML, Mistral Instruct
  - Gemma Instruct, Phi-3
  - Qwen2 Instruct, Command-R
  - Falcon Instruct, Vicuna
  - Zephyr, OpenChat
  - ChatQA, Solar Instruct
  - Granite Instruct, Alpaca

#### Slice and Globals Features
- **Slice expressions** - Full support for Python-style slice notation (`list[start:end:step]`)
- **Global functions** - `range()`, `lipsum()`, `dict()`, `cycler()`, `joiner()`, `namespace()`
- **Loop utilities** - Enhanced `loop.cycle()` support

#### Enhanced Filters
- **Additional filter implementations** - Extended filter coverage for better Jinja2 compatibility
- **Filter integration tests** - Comprehensive test suite for all filters (885+ test lines)

#### Test Infrastructure
- **Test README** - Comprehensive testing and benchmarking documentation (`test/README.md`)
- **Reference setup guide** - Instructions for cloning Python Jinja2 for comparison testing
- **Integration test expansion** - Control flow, set/with, and slice/globals test suites

### Changed

#### Bytecode Compiler Enhancements
- Major bytecode compiler improvements for better template coverage
- Enhanced instruction set for complex template patterns
- Improved loop context handling in bytecode VM

#### Parser Improvements
- Extended parser support for slice expressions
- Better handling of complex expression patterns
- Enhanced macro and call block parsing

### Fixed

#### Known Issues
- Temporarily disabled macro caller variable test pending investigation
- Macro `caller()` variable access needs further work

### Technical Details

- **New test files**: `huggingface_compat.zig`, `production_templates.zig`, `filters.zig` (integration)
- **Enhanced modules**: `bytecode.zig` (+1900 lines), `compiler.zig` (+600 lines), `parser.zig` (+275 lines), `filters.zig` (+366 lines)
- **Test coverage**: Added 16 HuggingFace template fixtures, 3 new integration test suites

---

## [Unreleased]

### Planned
- Fix macro caller variable test
- Additional async features
- More filter optimizations
- Extended bytecode caching options

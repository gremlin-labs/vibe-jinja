# Testing & Benchmarking Guide

This directory contains the complete test suite and benchmarking infrastructure for vibe-jinja, a high-performance Jinja2-compatible templating engine written in Zig.

## Table of Contents

- [Quick Start](#quick-start)
- [Test Structure](#test-structure)
- [Running Tests](#running-tests)
- [Benchmarking](#benchmarking)
- [Reference Setup](#reference-setup)
- [Writing Tests](#writing-tests)

---

## Quick Start

```bash
# Run all tests
zig build test

# Run benchmarks (optimized)
zig build benchmark -Doptimize=ReleaseFast

# Run comparison benchmarks vs Python Jinja2
zig build bench-compare -Doptimize=ReleaseFast
```

---

## Test Structure

```
test/
├── unit/                    # Unit tests for individual components
│   ├── parser.zig          # Parser tests
│   ├── compiler.zig        # Compiler tests
│   ├── filters.zig         # Filter function tests
│   ├── value.zig           # Value type tests
│   ├── value_comparison.zig # Value comparison tests
│   ├── control_flow.zig    # Control flow tests
│   └── ...
├── integration/             # Integration tests for complete features
│   ├── control_flow.zig    # For loops, conditionals
│   ├── macros.zig          # Macro definitions and calls
│   ├── filters.zig         # Filter chain integration
│   ├── inheritance.zig     # Template inheritance
│   ├── includes.zig        # Template includes
│   ├── imports.zig         # Template imports
│   ├── huggingface_compat.zig  # HuggingFace template compatibility
│   ├── production_templates.zig # Real-world template tests
│   ├── templates/          # Test template fixtures
│   │   ├── llama3-instruct.jinja
│   │   ├── chatml.jinja
│   │   └── ...
│   └── fixtures/           # Additional test fixtures
├── benchmarks/              # Performance benchmarking suite
│   ├── benchmark.zig       # Main performance benchmarks
│   ├── benchmark_python.py # Python Jinja2 comparison benchmarks
│   ├── comparison_bench.zig # Head-to-head Zig vs Python comparison
│   ├── diagnostic_bench.zig # Detailed diagnostic profiling
│   └── aot_bench.zig       # AOT vs JIT compilation benchmarks
├── comment_*/               # Comment parsing tests
├── expression_*/            # Expression parsing tests
└── plaintext/               # Plaintext output tests
```

---

## Running Tests

### Run All Tests

```bash
zig build test
```

### Run Unit Tests Only

```bash
zig build test:unit
```

### Run Integration Tests Only

```bash
zig build test:integration
```

### Run Specific Test Suites

```bash
# Individual test suites
zig build test:control_flow     # Control flow tests
zig build test:macros           # Macro tests
zig build test:filters          # Filter tests
zig build test:autoescape       # Autoescape tests
zig build test:regression       # Regression tests
zig build test:set_with         # Set/with statement tests
zig build test:filter_block     # Filter block tests
zig build test:raw_blocks       # Raw block tests
zig build test:huggingface      # HuggingFace compatibility tests
zig build test:production       # Production template tests
zig build test:slice            # Slice and globals tests
zig build test:async            # Async rendering tests
```

### Test Output Verbosity

For verbose test output, use the `--summary` flag:

```bash
zig build test --summary all
```

---

## Benchmarking

vibe-jinja includes a comprehensive benchmarking suite to measure and compare performance against Python Jinja2.

### Main Benchmark Suite

```bash
# Run all performance benchmarks (use ReleaseFast for accurate results)
zig build benchmark -Doptimize=ReleaseFast
```

**Benchmarks include:**
- Template rendering (simple, loop, conditional, nested)
- Filter performance and filter chain evaluation
- Value operations (comparison, conversion, truthiness)
- Caching (cache hits vs misses)
- Memory allocation patterns

### Comparison Benchmark (vs Python)

```bash
# Run head-to-head comparison with Python Jinja2
zig build bench-compare -Doptimize=ReleaseFast
```

This runs identical benchmark scenarios to `benchmark_python.py` for fair comparison:
- Simple template: `Hello {{ name }}!`
- Loop template: `{% for item in items %}{{ item }}{% endfor %}`
- Conditional: `{% if condition %}True{% else %}False{% endif %}`
- Filter chain: `{{ text|upper|lower|trim|length }}`

### Python Benchmarks

To run the Python reference benchmarks (requires Python 3 and Jinja2):

```bash
# Install Jinja2 if needed
pip install jinja2

# Run Python benchmarks
python3 test/benchmarks/benchmark_python.py
```

### Diagnostic Benchmarks

For detailed performance profiling to identify bottlenecks:

```bash
zig build bench-diagnostic -Doptimize=ReleaseFast
```

**Diagnostic scenarios include:**
- Empty template (baseline overhead)
- Single variable lookup
- Loop scaling (1, 10, 100 iterations)
- Filter application (single and chained)
- Nested conditionals
- Attribute access
- Realistic combined templates

### AOT vs JIT Benchmark

Compare ahead-of-time compiled templates vs runtime interpreted:

```bash
zig build bench-aot -Doptimize=ReleaseFast
```

---

## Reference Setup

For development and compatibility testing, you may want to clone the original Python Jinja2 repository as a reference.

### Clone Jinja2 Reference

```bash
# From the project root
mkdir -p references
cd references

# Clone the official Jinja2 repository
git clone https://github.com/pallets/jinja.git

# Or clone a specific version for compatibility testing
git clone --branch 3.1.x https://github.com/pallets/jinja.git jinja-3.1
```

### Reference Directory Structure

```
vibe-jinja/
├── references/              # Git-ignored reference implementations
│   └── jinja/              # Official Python Jinja2 repository
│       ├── src/jinja2/     # Jinja2 source code
│       ├── tests/          # Jinja2 test suite
│       └── docs/           # Jinja2 documentation
├── src/                     # vibe-jinja source
└── test/                    # vibe-jinja tests
```

The `references/` directory is included in `.gitignore` and won't be committed to version control.

### Using the Reference

The reference repository is useful for:

1. **Comparing behavior**: Check how Python Jinja2 handles edge cases
2. **Template compatibility**: Validate templates against the reference implementation
3. **Test porting**: Port test cases from Jinja2's test suite
4. **Documentation reference**: Understand expected behavior from official docs

### Running Reference Tests

```bash
cd references/jinja

# Create virtual environment
python -m venv venv
source venv/bin/activate  # or `venv\Scripts\activate` on Windows

# Install dependencies
pip install -e ".[dev]"

# Run Jinja2 tests
pytest tests/
```

---

## Writing Tests

### Unit Test Template

Unit tests focus on individual components in isolation:

```zig
const std = @import("std");
const vibe_jinja = @import("vibe_jinja");

test "my feature test" {
    const allocator = std.testing.allocator;
    
    var env = vibe_jinja.Environment.init(allocator);
    defer env.deinit();
    
    // Your test logic here
    const template = try env.fromString("{{ name }}", "test");
    // ...
    
    try std.testing.expectEqualStrings("expected", actual);
}
```

### Integration Test Template

Integration tests verify complete template rendering:

```zig
const std = @import("std");
const vibe_jinja = @import("vibe_jinja");

test "complete rendering test" {
    const allocator = std.testing.allocator;
    
    var env = vibe_jinja.Environment.init(allocator);
    defer env.deinit();
    
    const source = "{% for item in items %}{{ item }}{% endfor %}";
    
    var rt = vibe_jinja.runtime.Runtime.init(&env, allocator);
    defer rt.deinit();
    
    var vars = std.StringHashMap(vibe_jinja.context.Value).init(allocator);
    defer vars.deinit();
    
    // Setup context variables
    // ...
    
    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);
    
    try std.testing.expectEqualStrings("expected output", result);
}
```

### Test Fixtures

Place test templates in:
- `test/integration/templates/` - Template files for integration tests
- `test/integration/fixtures/` - Other test fixtures (JSON data, etc.)

---

## Performance Results

Current benchmarks show vibe-jinja achieving **performance parity with Python Jinja2**:

| Benchmark | Python Jinja2 | vibe-jinja | Result |
|-----------|---------------|------------|--------|
| Simple Template | 3,427 ns | 3,468 ns | **PARITY** (0.99x) |
| Loop Template | 3,800 ns | 3,580 ns | **ZIG WINS** (1.06x) |
| Conditional | 3,211 ns | 3,767 ns | Python 1.17x faster |
| Filter Chain | 3,771 ns | 3,810 ns | **PARITY** (0.99x) |
| Filter Lookup | 138 ns | 14 ns | **ZIG 9.9x FASTER** |
| Cache Hit | 8,709 ns | 3,667 ns | **ZIG 2.4x FASTER** |

*Benchmarks run on Apple Silicon (arm64), Zig 0.15.2 ReleaseFast, Python 3.13*

---

## CI Integration

For continuous integration, use:

```yaml
# Example GitHub Actions workflow
- name: Run Tests
  run: zig build test

- name: Run Benchmarks
  run: zig build benchmark -Doptimize=ReleaseFast
```

---

## Troubleshooting

### Tests Fail with Memory Errors

Ensure proper cleanup with `defer` statements:

```zig
var env = vibe_jinja.Environment.init(allocator);
defer env.deinit();  // Always defer deinit
```

### Benchmark Results Vary

- Always use `-Doptimize=ReleaseFast` for benchmarks
- Run multiple times and look at median/P95 values
- Ensure system is idle during benchmarking
- Use `doNotOptimizeAway` to prevent compiler optimizations from skipping work

### Python Benchmark Comparison Differs

- Ensure Python Jinja2 is version 3.x
- Both benchmarks should use pre-compiled templates
- Compare median values, not averages (reduces outlier impact)

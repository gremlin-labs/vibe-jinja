# Testing and benchmarking

This directory contains Vibe Jinja's unit, integration, public-API, fixture, and benchmark coverage.

## Quick start

```sh
zig build test
zig build benchmark -Doptimize=ReleaseFast
```

## Test layout

```text
test/
├── unit/                     component-level tests
├── integration/              end-to-end template behavior
├── benchmarks/               Zig and Python benchmark harnesses
├── public_api.zig            retained package-root declarations
├── comment_*/                source-to-output fixtures
├── expression_*/             literal-expression fixtures
└── plaintext/                plain-text fixture
```

The current build graph registers 24 files under `test/unit/`, 17 files under `test/integration/`, the public-API test, and the source-to-output fixtures. `zig build test` is the authoritative complete test command; file counts are descriptive and may change.

## Test commands

```sh
# Complete graph
zig build test

# Broad groups
zig build test:unit
zig build test:integration

# Focused integration suites
zig build test:control_flow
zig build test:macros
zig build test:set_with
zig build test:filter_block
zig build test:raw_blocks
zig build test:autoescape
zig build test:regression
zig build test:filters
zig build test:huggingface
zig build test:production
zig build test:slice
zig build test:async

# Show every executed/cached step
zig build test --summary all
```

The exact available step list comes from `zig build --help` and `build.zig`.

## Benchmark commands

Always use `ReleaseFast` for performance measurements:

```sh
# General engine benchmarks
zig build benchmark -Doptimize=ReleaseFast

# Detailed scenario diagnostics
zig build bench-diagnostic -Doptimize=ReleaseFast

# AOT versus runtime compilation
zig build bench-aot -Doptimize=ReleaseFast
```

The general suite covers full-pipeline and precompiled rendering, loops, conditionals, nested templates, filters, value operations, caching, and allocation behavior.

## Python comparison

`benchmark_python.py` measures the four render scenarios shared with `comparison_bench.zig` and writes their timing metadata to `python_reference.json`. Run it before the Zig comparison so both engines are measured on the same machine under similar load.

With Jinja2 installed in the active Python environment:

```sh
python3 test/benchmarks/benchmark_python.py
zig build bench-compare -Doptimize=ReleaseFast
zig build bench-check -Doptimize=ReleaseFast
```

In the Vibe Workspace, the canonical Jinja checkout lives at workspace-root `references/jinja`, not inside this child repository:

```sh
PYTHONPATH=../references/jinja/src python3 test/benchmarks/benchmark_python.py
zig build bench-compare -Doptimize=ReleaseFast
zig build bench-check -Doptimize=ReleaseFast
```

The steps must run sequentially because the Python command rewrites `test/benchmarks/python_reference.json`.

`bench-compare` reports averages, medians, p95 values, minimums, throughput, and backing allocations. `bench-check` additionally requires all four Python reference records and fails unless Vibe Jinja's average and median are both strictly faster for every scenario.

The checked-in JSON is a reproducibility aid, not a universal performance guarantee. Refresh it when publishing benchmark claims or evaluating performance-sensitive changes.

## Current comparison snapshot

Measured on 2026-07-14 on Apple Silicon with Zig 0.15.2 ReleaseFast, Python 3.13.3, and Jinja2 3.1.6:

| Benchmark | Python avg | Vibe Jinja avg | Speedup |
| --- | ---: | ---: | ---: |
| Simple template | 3,450 ns | 877 ns | 3.93x |
| Loop template | 4,485 ns | 652 ns | 6.88x |
| Conditional | 3,414 ns | 139 ns | 24.56x |
| Filter chain | 4,006 ns | 222 ns | 18.05x |

All four scenarios passed `bench-check`, and each Vibe Jinja render made one backing-allocator allocation for its returned string.

## Updating benchmarks safely

When changing a render hot path:

1. Regenerate the Python reference and run `bench-compare` before the change.
2. Record the average, median, p95, and allocation count for all four scenarios.
3. Apply the change without altering the scenarios or iteration counts.
4. Rerun the same commands under similar machine load.
5. Run `bench-check` and the complete test suite.

Do not compare a new Zig run with a Python JSON file produced on another machine or by a materially different environment.

## Adding tests

- Put isolated parser, compiler, value, filter, cache, and environment behavior in `test/unit/`.
- Put complete render flows and cross-component behavior in `test/integration/`.
- Put real templates or source-to-output pairs in the relevant fixture directory.
- Register every new Zig test root in both the appropriate grouped step and the complete `test` step in `build.zig`.
- Prefer `std.testing.allocator` unless a test specifically exercises allocator behavior.

Minimal render shape:

```zig
var env = vibe_jinja.Environment.init(allocator);
defer env.deinit();

const template = try env.fromString("Hello, {{ name }}!", "test");
// With the default cache enabled, Environment owns the template.

var vars = std.StringHashMap(vibe_jinja.Value).init(allocator);
defer vars.deinit();
try vars.put("name", .{ .string = "World" });

var ctx = try vibe_jinja.context.Context.init(&env, vars, "test", allocator);
defer ctx.deinit();

var compiled = try vibe_jinja.compiler.compile(&env, template, "test", allocator);
defer compiled.deinit();

const output = try compiled.render(&ctx, allocator);
defer allocator.free(output);
try std.testing.expectEqualStrings("Hello, World!", output);
```

## CI guidance

The deterministic default gate is:

```sh
zig build test
```

Run `bench-check` only on a controlled performance runner after regenerating the Python reference. Shared CI hosts are usually too noisy for a strict cross-language timing gate.

## Troubleshooting

- If comparison numbers look stale, inspect `_meta` in `python_reference.json` and regenerate it.
- If `bench-check` reports missing references, rerun `benchmark_python.py` and wait for it to finish before starting Zig.
- If timings vary, close competing workloads and compare medians and p95 values as well as averages.
- If a new test file does not run, verify that `build.zig` adds its run artifact to the expected grouped and complete steps.

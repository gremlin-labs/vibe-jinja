# Changelog

All notable changes to Vibe Jinja are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0] - 2026-07-14

### Added

- Add a Python-compatible `split` filter and method-style filter calls such as `'a,b'.split(',')`.
- Support postfix attribute, item, slice, and call trailers after literals, parenthesized expressions, and call results.
- Support negated tests such as `value is not none`.
- Add chat-template regressions for method calls, indexing call results, negated tests, and malformed-template parser progress.
- Add retained public-API coverage for the 1.1 package surface.
- Add `zig build bench-check`, which requires all four Python render references and fails on average or median regressions.

### Changed

- Split bytecode types, generation, synchronous execution, and async-specialized execution into focused modules behind the existing public facade.
- Use a reusable thread-local render arena, retained up to 1 MiB, with a fresh arena for reentrant renders.
- Switch the comparison harness to nanosecond-resolution timers, median/p95 reporting, backing-allocation counts, and a generated Python reference file.
- Make the default test graph run every registered unit, integration, fixture, and public-API test root.
- Bound CLI JSON conversion to 256 nested containers and return `InputTooDeep` for deeper input.

### Fixed

- Guarantee parser progress for stray delimiters, unknown block statements, and malformed templates instead of repeatedly visiting the same token.
- Correct overlay and spontaneous-environment cache ownership across allocators and option sets.
- Align AST, bytecode, optimizer, macro/caller, attribute, item, hashing, and formatting semantics.
- Make `sort` and `dictsort` stable; correct `rejectattr`, list-producing filter ownership, recursive JSON formatting, and mixed numeric equality.
- Remove the unused eager 4 KiB render-arena output buffer.

### Performance

- The 2026-07-14 Apple Silicon comparison passed all four cross-language gates: 3.93x simple-template, 6.88x loop, 24.56x conditional, and 18.05x filter-chain average speedups over Python 3.13.3 with Jinja2 3.1.6.
- Steady-state comparison renders make one backing-allocator allocation for the returned string.

## [1.1.0] - 2026-01-15

### Added

- Add production-oriented Hugging Face chat-template support and 16 representative model fixtures, including Llama, ChatML, Mistral, Gemma, Phi, Qwen, Command-R, Falcon, Vicuna, Zephyr, OpenChat, ChatQA, Solar, Granite, and Alpaca formats.
- Add Python-style slice expressions and the `range`, `lipsum`, `dict`, `cycler`, `joiner`, and `namespace` globals.
- Add broader filter integration coverage and the testing/benchmarking guide.

### Changed

- Expand bytecode instructions and compiler handling for complex template patterns.
- Improve loop-context, parser, macro, call-block, and slice handling.

### Known limitations

- Python-style async execution remains a foundation rather than equivalent `async`/`await` behavior.
- Compatibility is validated by the included suites and production fixtures, not claimed for every Jinja2 extension or edge case.

## [1.0.0] - 2025-12-29

### Added

- Add core Jinja syntax: text, comments, raw blocks, expressions, loops, conditionals, macros, calls, assignments, scoped `with` blocks, filter blocks, inheritance, includes, imports, autoescape blocks, and loop-control extensions.
- Add variables, scalar/list/dictionary literals, arithmetic, comparisons, boolean logic, membership and test operators, filters, attribute/item access, inline conditionals, and function calls.
- Add built-in string, sequence, numeric, dictionary, escaping, formatting, selection, grouping, serialization, and utility filters.
- Add built-in type, value, numeric, string, comparison, membership, filter, and test predicates.
- Add filesystem, dictionary, function, package, prefix, choice, and module loaders.
- Add template caching, AST optimization, bytecode compilation, arena-backed rendering, string interning, and buffered output utilities.
- Add custom extension, filter, test, global, loader, undefined-behavior, sandbox, and runtime utility APIs.
- Add filesystem and memcached bytecode-cache backends.

### Technical baseline

- Minimum Zig version: 0.15.2.
- Runtime dependencies: Zig standard library only.
- License: MIT.

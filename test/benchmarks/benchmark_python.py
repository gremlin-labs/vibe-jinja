#!/usr/bin/env python3
"""
Python Jinja2 Benchmark Suite
Compare against vibe-jinja (Zig) implementation

Run: python3 test/benchmarks/benchmark_python.py
"""

import time
import statistics
from jinja2 import Environment, DictLoader

def benchmark(name, func, iterations=1000, warmup=10):
    """Run a benchmark and collect timing statistics."""
    # Warmup
    for _ in range(warmup):
        func()
    
    # Collect samples
    samples = []
    for _ in range(iterations):
        start = time.perf_counter_ns()
        func()
        elapsed = time.perf_counter_ns() - start
        samples.append(elapsed)
    
    samples.sort()
    total = sum(samples)
    avg = total / len(samples)
    min_val = min(samples)
    max_val = max(samples)
    median = samples[len(samples) // 2]
    p95 = samples[int(len(samples) * 0.95)]
    ops_per_sec = 1_000_000_000 / avg if avg > 0 else 0
    
    print(f"  {name}:")
    print(f"    Iterations: {iterations}")
    print(f"    Total time: {total // 1_000_000}ms")
    print(f"    Avg: {avg:.0f}ns | Min: {min_val}ns | Max: {max_val}ns")
    print(f"    Median: {median}ns | P95: {p95}ns")
    print(f"    Throughput: {ops_per_sec:.0f} ops/sec")
    print()
    
    return avg

def main():
    print("╔═══════════════════════════════════════════════════════════╗")
    print("║          Python Jinja2 Performance Benchmarks             ║")
    print("╠═══════════════════════════════════════════════════════════╣")
    print("║  Reference implementation for comparison with vibe-jinja  ║")
    print("╚═══════════════════════════════════════════════════════════╝")
    print()
    
    # Create environment
    env = Environment()
    
    print("─── Template Rendering ───")
    print()
    
    # Simple Template
    simple_template = env.from_string("Hello {{ name }}!")
    def bench_simple():
        return simple_template.render(name="World")
    benchmark("Simple Template", bench_simple, iterations=1000)
    
    # Loop Template
    loop_template = env.from_string("{% for item in items %}{{ item }}{% endfor %}")
    items = list(range(10))
    def bench_loop():
        return loop_template.render(items=items)
    benchmark("Loop Template", bench_loop, iterations=100)
    
    # Conditional Template
    cond_template = env.from_string("{% if condition %}True{% else %}False{% endif %}")
    def bench_conditional():
        return cond_template.render(condition=True)
    benchmark("Conditional Template", bench_conditional, iterations=1000)
    
    # Nested Conditionals
    nested_template = env.from_string("{% if a %}{% if b %}nested{% endif %}{% endif %}")
    def bench_nested():
        return nested_template.render(a=True, b=True)
    benchmark("Nested Conditionals", bench_nested, iterations=1000)
    
    print("─── Filter Performance ───")
    print()
    
    # Filter Chain
    filter_template = env.from_string("{{ text|upper|lower|trim|length }}")
    def bench_filters():
        return filter_template.render(text="  Hello World  ")
    benchmark("Filter Chain", bench_filters, iterations=500)
    
    # Individual filter lookup (approximate - Python doesn't expose this directly)
    def bench_filter_lookup():
        # Access filter from environment
        _ = env.filters.get("escape")
        _ = env.filters.get("upper")
        _ = env.filters.get("lower")
        _ = env.filters.get("trim")
        _ = env.filters.get("default")
        _ = env.filters.get("length")
    benchmark("Filter lookup (6 filters)", bench_filter_lookup, iterations=100000)
    
    print("─── Value Operations ───")
    print()
    
    # Integer comparison (via template)
    int_cmp_template = env.from_string("{% if a == b %}eq{% endif %}")
    def bench_int_compare():
        return int_cmp_template.render(a=42, b=42)
    benchmark("Integer comparison (via template)", bench_int_compare, iterations=10000)
    
    # String comparison (via template)
    str_cmp_template = env.from_string("{% if a == b %}eq{% endif %}")
    def bench_str_compare():
        return str_cmp_template.render(a="hello world", b="hello world")
    benchmark("String comparison (via template)", bench_str_compare, iterations=10000)
    
    # Integer to string
    int_str_template = env.from_string("{{ num }}")
    def bench_int_to_str():
        return int_str_template.render(num=12345)
    benchmark("Integer to string", bench_int_to_str, iterations=50000)
    
    # Truthiness check (via template)
    truthy_template = env.from_string("{% if val %}yes{% endif %}")
    def bench_truthiness():
        return truthy_template.render(val=42)
    benchmark("Truthiness check (via template)", bench_truthiness, iterations=50000)
    
    print("─── Caching ───")
    print()
    
    # Cache test (using DictLoader for fair comparison)
    loader = DictLoader({"test.html": "Hello {{ name }}!"})
    cached_env = Environment(loader=loader)
    
    # First render (compile)
    start1 = time.perf_counter_ns()
    template1 = cached_env.get_template("test.html")
    _ = template1.render(name="World")
    first_render = time.perf_counter_ns() - start1
    
    # Second render (cached)
    start2 = time.perf_counter_ns()
    template2 = cached_env.get_template("test.html")
    _ = template2.render(name="World")
    second_render = time.perf_counter_ns() - start2
    
    speedup = first_render / second_render if second_render > 0 else 0
    print(f"  Cache Benchmark:")
    print(f"    First render (miss): {first_render}ns")
    print(f"    Second render (hit): {second_render}ns")
    print(f"    Speedup: {speedup:.2f}x")
    print()
    
    print("═══════════════════════════════════════════════════════════")
    print("  Benchmarks complete")
    print("═══════════════════════════════════════════════════════════")

if __name__ == "__main__":
    main()

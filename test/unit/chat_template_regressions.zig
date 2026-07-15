//! Regression tests for parser and runtime bugs surfaced by real-world LLM
//! chat templates (DeepSeek-R1 in particular):
//! - parser infinite loop on {% set x = <postfix-on-literal> %} inside a block
//! - postfix trailers (.attr / [index] / (call)) after literals and call results
//! - negative indexing on strings and lists
//! - `is not <test>` negation
//! - split() string method / filter
const std = @import("std");
const testing = std.testing;
const vibe_jinja = @import("vibe_jinja");
const environment = vibe_jinja.environment;
const runtime = vibe_jinja.runtime;
const value = vibe_jinja.value;

/// Render a template with no variables and compare against expected output
fn expectRender(expected: []const u8, source: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = environment.Environment.init(allocator);
    defer env.deinit();

    var rt = runtime.Runtime.init(&env, allocator);
    defer rt.deinit();

    var vars = std.StringHashMap(value.Value).init(allocator);
    defer vars.deinit();

    const result = try rt.renderString(source, vars, "test");
    defer allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "set with subscript on literal inside if does not hang" {
    // Regression: this template spun forever in Parser.parse() because
    // parseStatement returned null without consuming tokens
    try expectRender("ok", "{% if true %}{% set c = [1,2][0] %}{% endif %}ok");
    try expectRender("ok", "{% if false %}{% set c = [1,2][0] %}{% endif %}ok");
    try expectRender("1", "{% if true %}{% set c = [1,2][0] %}{{ c }}{% endif %}");
    try expectRender("1", "{% for i in [1] %}{% set c = [1,2][0] %}{{ c }}{% endfor %}");
}

test "orphaned end tag is skipped instead of hanging" {
    try expectRender("ok", "{% endif %}ok");
    try expectRender("ok", "{% endfor %}ok");
}

test "negative indexing on strings and lists" {
    try expectRender("c", "{{ 'abc'[-1] }}");
    try expectRender("y", "{{ ['x','y'][-1] }}");
    try expectRender("y", "{% set l = ['x','y'] %}{{ l[-1] }}");
}

test "postfix trailers on literals and call results" {
    try expectRender("bcd", "{{ 'abcdef'[1:4] }}");
    try expectRender("2", "{{ range(3)[-1] }}");
    try expectRender("a", "{{ ('a,b').split(',')[0] }}");
    try expectRender("B", "{{ 'a b c'.split(' ')[1].upper() }}");
}

test "split filter follows Python str.split semantics" {
    try expectRender("b", "{{ 'a</think>b'.split('</think>')[-1] }}");
    try expectRender("b", "{{ ('a,b'|split(','))[-1] }}");
    // explicit separator keeps empty segments
    try expectRender("3", "{{ 'a,,b'.split(',')|length }}");
    // no separator splits on whitespace runs and drops empties
    try expectRender("2", "{{ '  a   b '.split()|length }}");
    // maxsplit limits the number of splits
    try expectRender("b,c", "{{ 'a,b,c'.split(',', 1)[-1] }}");
}

test "is not negates a test" {
    try expectRender("T", "{% if 'x' is not none %}T{% else %}F{% endif %}");
    try expectRender("F", "{% if none is not none %}T{% else %}F{% endif %}");
    try expectRender("T", "{% set l = ['v'] %}{% if l[0] is not none %}T{% else %}F{% endif %}");
    try expectRender("T", "{% if 'x' is not defined %}F{% else %}T{% endif %}");
}

test "deepseek r1 assistant content shape renders" {
    // The exact statement shape from the DeepSeek-R1 chat template that
    // previously hung the parser and then failed with AttributeError in the
    // tree interpreter (namespace attr set disables the bytecode VM)
    try expectRender(
        "<A>y<E>",
        "{% set ns = namespace(is_tool=false) %}" ++
            "{% set content = 'x</think>y' %}" ++
            "{%- if ns.is_tool %}TOOL{%- set ns.is_tool = false -%}{%- else %}" ++
            "{% if '</think>' in content %}{% set content = content.split('</think>')[-1] %}{% endif %}" ++
            "{{ '<A>' + content + '<E>' }}" ++
            "{%- endif %}",
    );
}

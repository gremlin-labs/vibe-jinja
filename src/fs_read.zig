//! Bounded whole-file reads with an inclusive byte cap.
//!
//! Zig 0.17's `std.Io.Dir.readFileAlloc` returns `error.StreamTooLong` once the
//! file *reaches* the limit, so `.limited(n)` rejects an n-byte file. The 0.15
//! API accepted files of exactly `max_bytes`. These helpers keep that inclusive
//! contract: files of up to `max_bytes` bytes are read, larger files fail.

const std = @import("std");

/// Read `sub_path` relative to `dir`, accepting files of at most `max_bytes` bytes.
/// Returns `error.StreamTooLong` for larger files. Caller owns the result.
pub fn readFileAllocAtMost(
    dir: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
    allocator: std.mem.Allocator,
    max_bytes: usize,
) std.Io.Dir.ReadFileAllocError![]u8 {
    return dir.readFileAlloc(io, sub_path, allocator, inclusiveLimit(max_bytes));
}

/// `std.Io.Limit` that admits exactly `max_bytes` bytes under "reached or exceeded" semantics.
pub fn inclusiveLimit(max_bytes: usize) std.Io.Limit {
    return if (max_bytes == std.math.maxInt(usize)) .unlimited else .limited(max_bytes + 1);
}

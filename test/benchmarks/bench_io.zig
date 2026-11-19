//! Shared I/O for the benchmark programs: the `std.Io` from `main(init)` and a
//! monotonic timer on `std.Io.Clock.awake`.
const std = @import("std");

/// Set by each benchmark's `main` from `init.io` before any benchmark runs.
pub var io: std.Io = undefined;

/// Nanoseconds on the monotonic clock.
pub fn nanoTimestamp() i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

pub const Timer = struct {
    started: std.Io.Timestamp,

    pub fn start() !Timer {
        return .{ .started = std.Io.Clock.awake.now(io) };
    }

    /// Nanoseconds since `start` or the last `reset`.
    pub fn read(timer: *Timer) u64 {
        const elapsed = timer.started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        return @intCast(@max(0, elapsed));
    }

    pub fn reset(timer: *Timer) void {
        timer.started = std.Io.Clock.awake.now(io);
    }
};

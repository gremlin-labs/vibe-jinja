//! Process clock access and elapsed-time measurement.
//!
//! Zig 0.16 requires an `std.Io` for every clock read, but this library's
//! public surface — `Environment.init(allocator)`, the filter and test callback
//! ABIs — carries only an allocator. Threading `Io` down to them would change
//! the published API rather than migrate it, so the functions here borrow the
//! runtime's process-global single-threaded instance instead. That is safe from
//! any thread: `Io.Threaded`'s `now` discards its userdata and is a plain
//! syscall.
//!
//! Accepting an `Io` from the caller would be strictly better. It is a breaking
//! change to every constructor, so it stays an open decision rather than a
//! refactor made in passing.
//!
//! The wall-clock readers deliberately keep the semantics of the `std.time`
//! functions they replaced, so the 0.16 migration changed no behavior.
//! `Timer` is what to use when measuring a duration: it reads the monotonic
//! clock, which does not step.

const std = @import("std");

/// Wall-clock seconds since the Unix epoch.
///
/// Return: the value the pre-0.16 `std.time.timestamp()` returned.
pub fn timestamp() i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, std.time.ns_per_s));
}

/// Wall-clock milliseconds since the Unix epoch.
///
/// Return: the value the pre-0.16 `std.time.milliTimestamp()` returned.
pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, std.time.ns_per_ms));
}

/// Wall-clock nanoseconds since the Unix epoch.
///
/// Subject to clock steps, so a difference of two readings can be negative.
/// Prefer `Timer` when measuring elapsed time.
///
/// Return: the value the pre-0.16 `std.time.nanoTimestamp()` returned.
pub fn nanoTimestamp() i128 {
    return @intCast(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds);
}

/// Elapsed-time measurement from a fixed starting point.
///
/// Carries the API of the `std.time.Timer` that 0.16 removed, over the same
/// monotonic clock that type used. Resolution matters to its callers:
/// `comparison_bench.zig` records why it never times with the realtime clock,
/// which quantizes to roughly a microsecond on macOS — the same order as the
/// renders being measured. The `.awake` clock reads `CLOCK_UPTIME_RAW` and
/// measures ~41.67ns on Apple Silicon.
pub const Timer = struct {
    start_time: i128,

    /// Begin measuring.
    ///
    /// Return: a timer whose `elapsed_ns` counts from this moment.
    pub fn start() Timer {
        return .{ .start_time = monotonic() };
    }

    /// Nanoseconds elapsed since `start` or the last `reset`.
    ///
    /// Return: the elapsed count, saturating at zero.
    pub inline fn elapsed_ns(self: Timer) u64 {
        return @intCast(@max(0, monotonic() - self.start_time));
    }

    /// Milliseconds elapsed since `start` or the last `reset`.
    ///
    /// Truncates rather than rounds, so anything under a millisecond reads as
    /// zero — most per-filter debug traces do.
    ///
    /// Return: the elapsed count, saturating at zero.
    pub inline fn elapsed_ms(self: Timer) u64 {
        return self.elapsed_ns() / std.time.ns_per_ms;
    }

    /// Microseconds elapsed since `start` or the last `reset`.
    ///
    /// Goes through `elapsed_ns` on purpose: `start_time` comes from the
    /// monotonic clock, so reading the wall clock here would subtract two
    /// different epochs and report the time since 1970.
    ///
    /// Return: the elapsed count as a fraction of a microsecond.
    pub fn elapsed_us(self: Timer) f64 {
        return @as(f64, @floatFromInt(self.elapsed_ns())) / 1000.0;
    }

    /// Restart measurement from now.
    pub fn reset(self: *Timer) void {
        self.start_time = monotonic();
    }

    /// A monotonic reading in nanoseconds, counted from an unspecified origin
    /// (boot, on this platform).
    ///
    /// This is the one place the Timer's clock is chosen, and the choice is
    /// load-bearing. `.real` is settable — NTP steps and frequency adjustments
    /// move it — so timing against it can report a wrong duration, or a
    /// backwards one that the `@max(0, ...)` above would silently clamp to
    /// zero. `.awake` never goes backwards, and excludes time the system spent
    /// suspended, so a machine sleeping mid-run is not billed to a render.
    ///
    /// Every reader must go through here. Mixing this with a wall-clock read
    /// subtracts two different epochs and yields the time since 1970.
    ///
    /// Return: a value meaningful only as a difference against another reading.
    inline fn monotonic() i128 {
        return @intCast(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds);
    }
};

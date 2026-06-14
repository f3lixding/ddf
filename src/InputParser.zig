const std = @import("std");

const util = @import("util.zig");
const c = util.c;
// TODO: replace this stub with a real type
const Msg = enum {};
const Sender = util.LockFreeSpsc(Msg).Sender;

const Self = @This();

alloc: std.mem.Allocator,
sender: Sender,
sampling_interval: std.Io.Duration,
future: ?std.Io.Future(anyerror!void) = null,

pub const Options = struct {
    /// Hz
    sampling_rate: i64 = 60,
};

pub fn init(alloc: std.mem.Allocator, sender: Sender, opts: Options) !Self {
    if (opts.sampling_rate <= 0) {
        return error.IncorrectOption;
    }

    // We set a hard floor of 60 hz
    const interval_ms: i64 = @max(@divTrunc(std.time.ms_per_s, opts.sampling_rate), 16);
    const sampling_interval = std.Io.Duration.fromMilliseconds(interval_ms);
    return .{
        .alloc = alloc,
        .sender = sender,
        .sampling_interval = sampling_interval,
    };
}

pub fn listenAndParse(self: *Self, io: std.Io) !void {
    self.future = try io.concurrent(coreLoop, .{ self, io });
}

pub fn deinit(self: *Self, io: std.Io) void {
    if (self.future) |*fut| {
        fut.cancel(io) catch {
            // TODO: log it here
        };
    }
}

/// This is the core loop of the input parsing routine
/// This is also made public so it can be used in other contextj
/// Note that this loop does _not_ block indefinitely for an input
/// This is because we need to accommodate for a cancellation point
pub fn coreLoop(self: *Self, io: std.Io) anyerror!void {
    while (true) {
        try io.checkCancel();

        try io.sleep(self.sampling_interval, .awake);
    }
}

test "init and run" {
    const alloc = std.testing.allocator;
    const channel = try util.LockFreeSpsc(Msg).init(alloc, 2);
    defer channel.deinit();

    const tx = channel.tx;
    var parser = try init(alloc, tx, .{});
    const io = std.testing.io;

    try parser.listenAndParse(io);
    parser.deinit(io);
}

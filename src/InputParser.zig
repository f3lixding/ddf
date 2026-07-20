const std = @import("std");

const util = @import("util.zig");
const c = util.c;

const InputEvent = @import("protocol.zig").InputEvent;

/// This is mainly for testability
/// We don't want to actually init notcurses in tests as it would take over
/// stdout and stdin for zig's test environment
pub const InputSource = struct {
    get_input_nblock: *const fn (*c.notcurses, *c.ncinput) u32,
};

const Sender = util.Spsc(InputEvent).Sender;

const Self = @This();

alloc: std.mem.Allocator,
sender: Sender,
nc_ctx: *c.notcurses,
sampling_interval: std.Io.Duration,
future: ?std.Io.Future(anyerror!void) = null,
input_source: InputSource,

pub const Options = struct {
    /// Hz
    sampling_rate: i64 = 60,
    /// abstraction over input
    input_source: InputSource = .{
        .get_input_nblock = struct {
            fn getInputNblock(nc_ctx: *c.notcurses, input: *c.ncinput) u32 {
                _ = nc_ctx;
                _ = input;
                return 0;
            }
        }.getInputNblock,
    },
};

pub fn init(
    alloc: std.mem.Allocator,
    nc_ctx: *c.notcurses,
    sender: Sender,
    opts: Options,
) !Self {
    if (opts.sampling_rate <= 0) {
        return error.IncorrectOption;
    }

    // We set a hard ceiling of 60 hz
    const interval_ms: i64 = @max(@divTrunc(std.time.ms_per_s, opts.sampling_rate), 16);
    const sampling_interval = std.Io.Duration.fromMilliseconds(interval_ms);
    return .{
        .alloc = alloc,
        .sender = sender,
        .nc_ctx = nc_ctx,
        .sampling_interval = sampling_interval,
        .input_source = opts.input_source,
    };
}

/// Caller must guarantee that:
/// - channel used must not be deinit before input listener deinit is completed
/// - notcurses must not be stopped before input listener deinitis completed
pub fn listen(self: *Self, io: std.Io) !void {
    self.future = try io.concurrent(coreLoop, .{ self, io });
}

pub fn deinit(self: *Self, io: std.Io) void {
    const log = std.log.scoped(.input_parser);

    if (self.future) |*fut| {
        fut.cancel(io) catch |err| {
            if (err != error.Canceled)
                log.err("Error canceling future {any}", .{err});
        };
    }
}

/// This is the core loop of the input parsing routine
/// This is also made public so it can be used in other contextj
/// Note that this loop does _not_ block indefinitely for an input
/// This is because we need to accommodate for a cancellation point
pub fn coreLoop(self: *Self, io: std.Io) anyerror!void {
    const log = std.log.scoped(.input_parser);

    var input = std.mem.zeroes(c.ncinput);

    while (true) {
        try io.checkCancel();

        const key = self.input_source.get_input_nblock(self.nc_ctx, &input);
        if (key != 0) {
            const now_ms: i64 = std.Io.Clock.real.now(io).toMilliseconds();

            const input_event: InputEvent = .{
                .timestamp = now_ms,
                .key = key,
                .ncinput = input,
            };

            self.sender.trySend(io, input_event) catch |err| {
                log.err("Error encountering while sending: {any}", .{err});
            };
        }

        try io.sleep(self.sampling_interval, .awake);
    }
}

test "init" {
    const alloc = std.testing.allocator;
    const channel = try util.Spsc(InputEvent).init(alloc, 2);
    defer channel.deinit();

    // Do not initialize real notcurses in the Zig test runner: the runner uses
    // stdio for its own protocol, and notcurses takes over the terminal.
    const fake_nc_ctx: *c.notcurses = @ptrFromInt(1);

    const parser = try init(alloc, fake_nc_ctx, channel.tx, .{});
    try std.testing.expectEqual(std.Io.Duration.fromMilliseconds(16), parser.sampling_interval);
}

test "core loop" {
    const alloc = std.testing.allocator;
    const channel = try util.Spsc(InputEvent).init(alloc, 2);
    defer channel.deinit();

    const fake_nc_ctx: *c.notcurses = @ptrFromInt(1);

    const input_source = struct {
        fn getInputNblockFake(nc_ctx: *c.notcurses, input: *c.ncinput) u32 {
            _ = nc_ctx;
            _ = input;
            return 'o';
        }
    }.getInputNblockFake;

    const io = std.testing.io;
    var parser = try init(alloc, fake_nc_ctx, channel.tx, .{
        .input_source = .{ .get_input_nblock = &input_source },
    });
    defer parser.deinit(io);

    try parser.listen(io);

    var rx = channel.rx;
    const res = try rx.recv(io);

    std.debug.assert(res.key == 'o');
}

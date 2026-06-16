const std = @import("std");

pub const c = @cImport({
    @cInclude("locale.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
    @cInclude("wchar.h");
    @cInclude("notcurses/notcurses.h");
    @cInclude("notcurses/direct.h");
});

/// A SPSC (single producer, single consumer)
/// The sender is supposed to be owned by one thread and one thread only
/// For that reason there is no need to compare
pub fn Spsc(
    comptime T: type,
) type {
    return struct {
        pub const Sender = struct {
            inner: *Inner,

            pub fn trySend(self: @This(), io: std.Io, pkg: T) !void {
                const inner = self.inner;

                const sender_alive = inner.sender_alive.load(.monotonic);
                const receiver_alive = inner.receiver_alive.load(.acquire);
                const tail = inner.tail.load(.monotonic);
                const head = inner.head.load(.acquire);
                const cap = inner.buf.len;
                // head and tail are monotonic ring counters. They are allowed
                // to wrap, so compute the occupancy with wrapping arithmetic.
                const buffer_full = cap == (tail -% head);

                if (!sender_alive or !receiver_alive) {
                    return error.ChannelClosed;
                } else if (buffer_full) {
                    return error.ChannelFull;
                }

                const slot = tail % cap;
                inner.buf[slot] = pkg;
                inner.tail.store(tail +% 1, .release);

                // This is only a futex epoch. Wrapping is acceptable; waiters
                // only care that the value changes before they are woken.
                _ = inner.not_empty.fetchAdd(1, .release);
                io.futexWake(u32, &inner.not_empty.raw, 1);
            }
        };

        pub const Receiver = struct {
            inner: *Inner,

            pub fn recv(self: @This(), io: std.Io) !T {
                return try self.recvWithTimeout(io, 0);
            }

            pub fn recvWithTimeout(self: @This(), io: std.Io, timeout_ms: i64) !T {
                if (timeout_ms < 0) return error.InvalidTimeout;

                const inner = self.inner;

                const sender_alive = inner.sender_alive.load(.monotonic);
                const receiver_alive = inner.receiver_alive.load(.acquire);
                const cap = inner.buf.len;

                if (!sender_alive or !receiver_alive) {
                    return error.ChannelClosed;
                }

                var head = inner.head.load(.monotonic);
                var tail = inner.tail.load(.acquire);

                if (head < tail) {
                    const slot = head % cap;
                    const res = inner.buf[slot];
                    inner.head.store(head +% 1, .release);
                    return res;
                }

                const not_empty_epoch = inner.not_empty.load(.acquire);
                const timeout: std.Io.Timeout =
                    if (timeout_ms == 0) .none else .{
                        .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake },
                    };
                try io.futexWaitTimeout(u32, &inner.not_empty.raw, not_empty_epoch, timeout);

                head = inner.head.load(.monotonic);
                tail = inner.tail.load(.acquire);
                if (head == tail) {
                    return error.Timeout;
                }

                const slot = head % cap;
                const res = inner.buf[slot];
                inner.head.store(head +% 1, .release);

                return res;
            }
        };

        pub const Channel = struct {
            rx: Receiver,
            tx: Sender,
            inner: *Inner,

            pub fn deinit(self: @This()) void {
                const alloc = self.inner.alloc;
                self.inner.deinit();
                alloc.destroy(self.inner);
            }
        };

        const Inner = struct {
            alloc: std.mem.Allocator,
            buf: []T,
            head: std.atomic.Value(usize) = .init(0),
            tail: std.atomic.Value(usize) = .init(0),
            sender_alive: std.atomic.Value(bool) = .init(true),
            receiver_alive: std.atomic.Value(bool) = .init(true),
            not_empty: std.atomic.Value(u32) = .init(0),

            pub fn deinit(self: @This()) void {
                self.alloc.free(self.buf);
            }
        };

        pub fn init(alloc: std.mem.Allocator, init_cap: usize) !Channel {
            if (init_cap == 0) return error.ZeroCapacity;
            // The wrapped distance `tail -% head` is unambiguous only if the
            // ring capacity is at most half the counter range.
            if (init_cap > (std.math.maxInt(usize) / 2)) return error.CapacityTooLarge;

            var buf = try std.ArrayList(T).initCapacity(alloc, init_cap);
            const slice = buf.allocatedSlice();
            const inner = try alloc.create(Inner);
            inner.* = .{
                .alloc = alloc,
                .buf = slice,
            };
            const sender: Sender = .{ .inner = inner };
            const receiver: Receiver = .{ .inner = inner };

            return .{ .tx = sender, .rx = receiver, .inner = inner };
        }
    };
}

test "spsc rejects zero capacity" {
    try std.testing.expectError(
        error.ZeroCapacity,
        Spsc(i32).init(std.testing.allocator, 0),
    );
}

test "spsc recv with timeout returns timeout when empty" {
    const io = std.Options.debug_io;
    const test_alloc = std.testing.allocator;

    const channel = try Spsc(i32).init(test_alloc, 2);
    defer channel.deinit();
    const rx = channel.rx;

    try std.testing.expectError(error.Timeout, rx.recvWithTimeout(io, 1));
}

test "spsc reports full" {
    const io = std.Options.debug_io;
    const test_alloc = std.testing.allocator;

    const channel = try Spsc(i32).init(test_alloc, 2);
    defer channel.deinit();
    const tx = channel.tx;

    try tx.trySend(io, 10);
    try tx.trySend(io, 20);
    try std.testing.expectError(error.ChannelFull, tx.trySend(io, 30));
}

test "spsc sends and receives one item" {
    const io = std.Options.debug_io;
    const test_alloc = std.testing.allocator;

    const channel = try Spsc(i32).init(test_alloc, 2);
    defer channel.deinit();
    const tx = channel.tx;
    const rx = channel.rx;

    try tx.trySend(io, 123);
    try std.testing.expectEqual(@as(i32, 123), try rx.recv(io));
}

test "spsc sends and receives across threads" {
    const Chan = Spsc(i32);
    const test_alloc = std.testing.allocator;

    const Result = struct {
        value: i32 = 0,
        err: ?anyerror = null,
    };

    const ThreadFns = struct {
        fn producer(tx: Chan.Sender, result: *Result) void {
            const io = std.Options.debug_io;

            // Give the receiver a chance to block before the sender publishes.
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};

            tx.trySend(io, 456) catch |err| {
                result.err = err;
            };
        }

        fn consumer(rx: Chan.Receiver, result: *Result) void {
            const io = std.Options.debug_io;

            result.value = rx.recvWithTimeout(io, 1000) catch |err| {
                result.err = err;
                return;
            };
        }
    };

    const channel = try Chan.init(test_alloc, 2);
    defer channel.deinit();
    const tx = channel.tx;
    const rx = channel.rx;

    var producer_result: Result = .{};
    var consumer_result: Result = .{};

    const producer_thread = try std.Thread.spawn(.{}, ThreadFns.producer, .{ tx, &producer_result });
    const consumer_thread = try std.Thread.spawn(.{}, ThreadFns.consumer, .{ rx, &consumer_result });

    producer_thread.join();
    consumer_thread.join();

    if (producer_result.err) |err| return err;
    if (consumer_result.err) |err| return err;

    try std.testing.expectEqual(@as(i32, 456), consumer_result.value);
}

const std = @import("std");

pub const c = @cImport({
    @cInclude("locale.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
    @cInclude("wchar.h");
    @cInclude("notcurses/notcurses.h");
    @cInclude("notcurses/direct.h");
    @cInclude("tree_sitter/api.h");
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

pub fn LeakyBucket(comptime T: type) type {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .@"struct" => |s| {
            var has_field = false;
            for (s.fields) |field| {
                if (std.mem.eql(u8, field.name, "timestamp")) {
                    has_field = true;
                    break;
                }
            }

            if (!has_field) {
                @compileError("Type supplied missing timestamp");
            }
        },
        else => @compileError("Expected struct"),
    }

    return struct {
        pub const Opts = struct {
            // Debounce period in ms
            debounce: i64 = 1000,
        };

        pub const Slice = struct {
            first: []T,
            second: ?[]T,

            pub const Iterator = struct {
                idx: usize = 0,
                slice: *const Slice,

                pub fn next(self: *Iterator) ?*T {
                    if (self.slice.first.len > self.idx) {
                        const idx = self.idx;
                        self.idx += 1;
                        return &self.slice.first[idx];
                    }

                    const second = self.slice.second orelse return null;
                    const second_idx = self.idx - self.slice.first.len;

                    if (second_idx < second.len) {
                        self.idx += 1;
                        return &second[second_idx];
                    }

                    return null;
                }
            };

            pub fn iterator(self: *const Slice) Iterator {
                return .{
                    .slice = self,
                };
            }
        };

        const Self = @This();
        const BUF_LEN: usize = 25;

        head: usize = 0,
        tail: usize = 0,
        debounce: i64,
        buf: [BUF_LEN]T,

        pub fn init(opts: Opts) Self {
            return .{
                .debounce = opts.debounce,
                .buf = undefined,
            };
        }

        // TODO: choose a better data structure here so we don't have to
        // iterate through backwards linearly
        pub fn insertAndReport(self: *Self, item: T) !Slice {
            const next_tail = (self.tail + 1) % BUF_LEN;
            if (next_tail == self.head) {
                return error.BufferFull;
            }

            self.buf[self.tail] = item;
            self.tail = next_tail;

            const curr_time: i64 = @field(item, "timestamp");
            const limit = curr_time - self.debounce;

            var is_wrapped = self.tail < self.head;

            var i = self.tail;
            var limit_reached = false;

            if (is_wrapped) {
                while (i > 0) {
                    i -= 1;
                    const time: i64 = @field(self.buf[i], "timestamp");
                    if (limit > time) {
                        limit_reached = true;
                        break;
                    }
                }

                if (limit_reached) {
                    self.head = (i +% 1) % BUF_LEN;
                } else {
                    i = BUF_LEN;

                    while (i > self.head) {
                        i -= 1;
                        const time: i64 = @field(self.buf[i], "timestamp");
                        if (limit > time) {
                            self.head = (i + 1) % BUF_LEN;
                            break;
                        }
                    }
                }
            } else {
                while (i > self.head) {
                    i -= 1;
                    const time: i64 = @field(self.buf[i], "timestamp");
                    if (limit > time) {
                        limit_reached = true;
                        break;
                    }
                }

                if (limit_reached) {
                    self.head = (i +% 1) % BUF_LEN;
                }
            }

            is_wrapped = self.tail < self.head;

            return .{
                .first = if (is_wrapped) self.buf[self.head..] else self.buf[self.head..self.tail],
                .second = if (is_wrapped) self.buf[0..self.tail] else null,
            };
        }

        pub fn clear(self: *Self) void {
            self.head = self.tail;
        }
    };
}

test "leaky bucket reports recent non-wrapped items" {
    const Event = struct {
        timestamp: i64,
        value: u8,
    };
    const Bucket = LeakyBucket(Event);

    var bucket = Bucket.init(.{ .debounce = 100 });

    _ = try bucket.insertAndReport(.{ .timestamp = 0, .value = 'a' });
    _ = try bucket.insertAndReport(.{ .timestamp = 50, .value = 'b' });
    const reported = try bucket.insertAndReport(.{ .timestamp = 120, .value = 'c' });

    try std.testing.expectEqual(@as(usize, 2), reported.first.len);
    try std.testing.expectEqual(@as(?[]Event, null), reported.second);
    try std.testing.expectEqual(@as(u8, 'b'), reported.first[0].value);
    try std.testing.expectEqual(@as(u8, 'c'), reported.first[1].value);
}

test "leaky bucket reports recent wrapped items" {
    const Event = struct {
        timestamp: i64,
        value: u8,
    };
    const Bucket = LeakyBucket(Event);

    var bucket = Bucket.init(.{ .debounce = 25 });

    // Move tail/head near the end so subsequent inserts wrap around.
    for (0..23) |idx| {
        _ = try bucket.insertAndReport(.{
            .timestamp = @intCast(idx),
            .value = @intCast(idx),
        });
    }
    bucket.clear();

    _ = try bucket.insertAndReport(.{ .timestamp = 1000, .value = 'a' }); // index 23
    _ = try bucket.insertAndReport(.{ .timestamp = 1010, .value = 'b' }); // index 24
    _ = try bucket.insertAndReport(.{ .timestamp = 1020, .value = 'c' }); // index 0
    _ = try bucket.insertAndReport(.{ .timestamp = 1030, .value = 'd' }); // index 1
    const reported = try bucket.insertAndReport(.{ .timestamp = 1040, .value = 'e' }); // index 2

    try std.testing.expectEqual(@as(usize, 3), reported.first.len);
    try std.testing.expectEqual(@as(?[]Event, null), reported.second);
    try std.testing.expectEqual(@as(u8, 'c'), reported.first[0].value);
    try std.testing.expectEqual(@as(u8, 'd'), reported.first[1].value);
    try std.testing.expectEqual(@as(u8, 'e'), reported.first[2].value);
}

test "leaky bucket reports split slices while wrapped" {
    const Event = struct {
        timestamp: i64,
        value: u8,
    };
    const Bucket = LeakyBucket(Event);

    var bucket = Bucket.init(.{ .debounce = 10_000 });

    for (0..23) |idx| {
        _ = try bucket.insertAndReport(.{
            .timestamp = @intCast(idx),
            .value = @intCast(idx),
        });
    }
    bucket.clear();

    _ = try bucket.insertAndReport(.{ .timestamp = 1000, .value = 'a' }); // index 23
    _ = try bucket.insertAndReport(.{ .timestamp = 1010, .value = 'b' }); // index 24
    const reported = try bucket.insertAndReport(.{ .timestamp = 1020, .value = 'c' }); // index 0

    try std.testing.expectEqual(@as(usize, 2), reported.first.len);
    try std.testing.expectEqual(@as(u8, 'a'), reported.first[0].value);
    try std.testing.expectEqual(@as(u8, 'b'), reported.first[1].value);

    const second = reported.second orelse return error.ExpectedSecondSlice;
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(@as(u8, 'c'), second[0].value);
}

test "leaky bucket reports buffer full" {
    const Event = struct {
        timestamp: i64,
    };
    const Bucket = LeakyBucket(Event);

    var bucket = Bucket.init(.{ .debounce = 10_000 });

    // This ring-buffer design reserves one slot to distinguish full from empty,
    // so a backing buffer of 25 elements has 24 usable slots.
    for (0..24) |idx| {
        _ = try bucket.insertAndReport(.{ .timestamp = @intCast(idx) });
    }

    try std.testing.expectError(error.BufferFull, bucket.insertAndReport(.{ .timestamp = 24 }));
}

pub fn getDirRelativeToHome(dest_slice: []u8, subpath: []const u8) ![]u8 {
    const home = std.c.getenv("HOME") orelse return error.NoHomeFound;
    const home_path: []const u8 = std.mem.span(home);
    return try std.fmt.bufPrint(dest_slice, "{s}/{s}", .{ home_path, subpath });
}

pub fn getDirRelativeToHomeSentinel(dest_slice: []u8, subpath: []const u8) ![:0]u8 {
    const home = std.c.getenv("HOME") orelse return error.NoHomeFound;
    const home_path: []const u8 = std.mem.span(home);
    return try std.fmt.bufPrintSentinel(dest_slice, "{s}/{s}", .{ home_path, subpath }, 0);
}

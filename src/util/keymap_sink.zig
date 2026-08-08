const std = @import("std");

const LeakyBucket = @import("leaky_bucket.zig").LeakyBucket;

pub fn ParseResult(comptime CommandType: type) type {
    return struct {
        command: @Tuple(&.{ CommandType, ?CommandType }),
        consumed: usize,
    };
}

/// Use this to define your own input parser by supplying your own keymap
pub fn KeymapSink(
    comptime ContextType: type,
    comptime InputEventType: type,
    comptime CommandType: type,
) type {
    return struct {
        pub const Bucket = LeakyBucket(InputEventType);
        pub const Opts = Bucket.Opts;
        pub const Result = ParseResult(CommandType);
        pub const ParsingFn = *const fn (ContextType, *Bucket.Slice.Iterator) ?Result;

        const Self = @This();

        parsing_fn: ParsingFn,
        bucket: Bucket,
        ctx: ContextType,

        pub fn init(
            ctx: ContextType,
            parsing_fn: ParsingFn,
            bucket_opts: Opts,
        ) Self {
            return .{
                .parsing_fn = parsing_fn,
                .bucket = Bucket.init(bucket_opts),
                .ctx = ctx,
            };
        }

        pub fn processForPotentialHit(self: *Self, input_event: InputEventType) !?@Tuple(&.{ CommandType, ?CommandType }) {
            const slice = try self.bucket.insertAndReport(input_event);
            var iter = slice.iterator();

            if (self.parsing_fn(self.ctx, &iter)) |res| {
                self.bucket.evictN(res.consumed);
                return res.command;
            }

            return null;
        }

        pub fn nextTimeoutIn(self: Self, cur_time: i64) ?i64 {
            if (self.bucket.head == self.bucket.tail)
                return null;

            const bucket_size = self.bucket.buf.len;
            const latest_idx = if (self.bucket.tail == 0) bucket_size - 1 else self.bucket.tail - 1;
            const latest = &self.bucket.buf[latest_idx];
            const latest_ts: i64 = @field(latest.*, "timestamp");

            const next_timeout_in = cur_time - latest_ts;

            return @max(0, next_timeout_in);
        }
    };
}

pub const KeyChord = struct {
    key: u32,
    mods: u32,

    pub const SingleContext = struct {
        pub fn hash(_: SingleContext, chord: KeyChord) u64 {
            var h = std.hash.Wyhash.init(0);

            std.hash.autoHash(&h, chord.key);
            std.hash.autoHash(&h, chord.mods);

            return h.final();
        }

        pub fn eql(_: SingleContext, a: KeyChord, b: KeyChord) bool {
            return a.key == b.key and a.mods == b.mods;
        }
    };

    pub const SequenceContext = struct {
        pub fn hash(_: SequenceContext, sequence: []const KeyChord) u64 {
            var h = std.hash.Wyhash.init(0);
            std.hash.autoHash(&h, sequence.len);

            for (sequence) |seq| {
                std.hash.autoHash(&h, seq.key);
                std.hash.autoHash(&h, seq.mods);
            }

            return h.final();
        }

        pub fn eql(_: SequenceContext, a: []const KeyChord, b: []const KeyChord) bool {
            if (a.len != b.len) return false;

            for (a, b) |a_, b_| {
                if (a_.key != b_.key) return false;
                if (a_.mods != b_.mods) return false;
            }

            return true;
        }
    };
};

pub fn Binding(comptime T: type) type {
    return struct { keys: []const KeyChord, command: T };
}

test "keymap sink returns command and evicts consumed events" {
    const Event = struct {
        timestamp: i64,
        key: u8,
    };
    const Command = enum { open };
    const Sink = KeymapSink(void, Event, Command);
    const Parser = struct {
        fn parse(_: void, iter: *Sink.Bucket.Slice.Iterator) ?Sink.Result {
            var matched: usize = 0;

            while (iter.next()) |event| {
                if (matched == 0 and event.key == 'a') {
                    matched = 1;
                    continue;
                }

                if (matched == 1 and event.key == 'b') {
                    return .{ .command = .{ .open, null }, .consumed = 2 };
                }

                matched = 0;
            }

            return null;
        }
    };

    var sink = Sink.init({}, Parser.parse, .{ .debounce = 10_000 });

    try std.testing.expectEqual(@as(bool, true), (try sink.processForPotentialHit(.{ .timestamp = 0, .key = 'a' })) == null);
    const hit = (try sink.processForPotentialHit(.{ .timestamp = 1, .key = 'b' })).?;
    try std.testing.expectEqual(Command.open, hit[0]);
    try std.testing.expectEqual(@as(?Command, null), hit[1]);

    try std.testing.expectEqual(@as(bool, true), (try sink.processForPotentialHit(.{ .timestamp = 2, .key = 'c' })) == null);
    const reported = try sink.bucket.insertAndReport(.{ .timestamp = 3, .key = 'd' });

    try std.testing.expectEqual(@as(usize, 2), reported.first.len);
    try std.testing.expectEqual(@as(?[]Event, null), reported.second);
    try std.testing.expectEqual(@as(u8, 'c'), reported.first[0].key);
    try std.testing.expectEqual(@as(u8, 'd'), reported.first[1].key);
}

test "keymap sink keeps events when parser misses" {
    const Event = struct {
        timestamp: i64,
        key: u8,
    };
    const Command = enum { open };
    const Sink = KeymapSink(void, Event, Command);
    const Parser = struct {
        fn parse(_: void, iter: *Sink.Bucket.Slice.Iterator) ?Sink.Result {
            while (iter.next()) |event| {
                if (event.key == 'z') return .{ .command = .{ .open, null }, .consumed = 1 };
            }
            return null;
        }
    };

    var sink = Sink.init({}, Parser.parse, .{ .debounce = 10_000 });

    try std.testing.expectEqual(@as(bool, true), (try sink.processForPotentialHit(.{ .timestamp = 0, .key = 'x' })) == null);
    try std.testing.expectEqual(@as(bool, true), (try sink.processForPotentialHit(.{ .timestamp = 1, .key = 'y' })) == null);
    const reported = try sink.bucket.insertAndReport(.{ .timestamp = 2, .key = 'w' });

    try std.testing.expectEqual(@as(usize, 3), reported.first.len);
    try std.testing.expectEqual(@as(?[]Event, null), reported.second);
    try std.testing.expectEqual(@as(u8, 'x'), reported.first[0].key);
    try std.testing.expectEqual(@as(u8, 'y'), reported.first[1].key);
    try std.testing.expectEqual(@as(u8, 'w'), reported.first[2].key);
}

test "keymap sink evicts consumed events from wrapped bucket" {
    const Event = struct {
        timestamp: i64,
        key: u8,
    };
    const Command = enum { open };
    const Sink = KeymapSink(void, Event, Command);
    const Parser = struct {
        fn parse(_: void, iter: *Sink.Bucket.Slice.Iterator) ?Sink.Result {
            var matched: usize = 0;

            while (iter.next()) |event| {
                if (matched == 0 and event.key == 'a') {
                    matched = 1;
                    continue;
                }

                if (matched == 1 and event.key == 'b') {
                    matched = 2;
                    continue;
                }

                if (matched == 2 and event.key == 'c') {
                    return .{ .command = .{ .open, null }, .consumed = 3 };
                }

                matched = 0;
            }

            return null;
        }
    };

    var sink = Sink.init({}, Parser.parse, .{ .debounce = 10_000 });

    for (0..23) |idx| {
        _ = try sink.bucket.insertAndReport(.{ .timestamp = @intCast(idx), .key = @intCast(idx) });
    }
    sink.bucket.clear();

    try std.testing.expectEqual(@as(bool, true), (try sink.processForPotentialHit(.{ .timestamp = 1000, .key = 'a' })) == null); // index 23
    try std.testing.expectEqual(@as(bool, true), (try sink.processForPotentialHit(.{ .timestamp = 1001, .key = 'b' })) == null); // index 24
    const hit = (try sink.processForPotentialHit(.{ .timestamp = 1002, .key = 'c' })).?; // index 0
    try std.testing.expectEqual(Command.open, hit[0]);
    try std.testing.expectEqual(@as(?Command, null), hit[1]);

    try std.testing.expectEqual(@as(bool, true), (try sink.processForPotentialHit(.{ .timestamp = 1003, .key = 'd' })) == null);
    const reported = try sink.bucket.insertAndReport(.{ .timestamp = 1004, .key = 'e' });

    try std.testing.expectEqual(@as(usize, 2), reported.first.len);
    try std.testing.expectEqual(@as(?[]Event, null), reported.second);
    try std.testing.expectEqual(@as(u8, 'd'), reported.first[0].key);
    try std.testing.expectEqual(@as(u8, 'e'), reported.first[1].key);
}

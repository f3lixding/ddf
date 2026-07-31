const std = @import("std");

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

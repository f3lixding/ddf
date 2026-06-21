const std = @import("std");

const util = @import("util.zig");
const c = util.c;
const DiffWindow = @import("components/DiffWindow.zig");

const protocol = @import("protocol.zig");
const InputEvent = protocol.InputEvent;
const FrameTime = protocol.FrameTime;
const Receiver = util.Spsc(InputEvent).Receiver;
const Conclusion = protocol.Conclusion;
const Component = @import("components/Component.zig");

const Self = @This();

alloc: std.mem.Allocator,

components: std.ArrayList(Component) = .empty,
rx: Receiver,
future: ?std.Io.Future(anyerror!void) = null,

pub fn init(alloc: std.mem.Allocator, rx: Receiver) Self {
    return .{
        .alloc = alloc,
        .rx = rx,
    };
}

pub fn start(self: *Self, io: std.Io, nc_ctx: *c.notcurses) !void {
    self.future = try std.Io.concurrent(io, coreLoop, .{ self, io, nc_ctx });
}

pub fn deinit(self: *Self, io: std.Io) void {
    const log = std.log.scoped(.app);

    if (self.future) |*fut| {
        fut.cancel(io) catch |err| switch (err) {
            error.Canceled => {},
            else => log.err("Error cancelling app core loop: {any}", .{err}),
        };
        self.future = null;
    }

    self.components.deinit(self.alloc);
}

fn coreLoop(self: *Self, io: std.Io, nc_ctx: *c.notcurses) anyerror!void {
    _ = nc_ctx;
    var last_tick = std.Io.Timestamp.now(io, .awake);

    while (true) {
        try io.checkCancel();

        const interval = self.loopTime();
        const recv_res = self.rx.recvWithTimeout(io, interval);

        const now = std.Io.Timestamp.now(io, .awake);
        const elapsed = last_tick.durationTo(now);
        last_tick = now;
        const frame_time: FrameTime = .{
            .now_ms = now.toMilliseconds(),
            .elapsed_ms = elapsed.toMilliseconds(),
        };

        // Notes to self. To be deleted later:
        // Here we should go through the stack and pick out the first with a conclusion
        // This means we should probably need to come up with a protocol agreed upon by all components
        if (recv_res) |evt| {
            try self.handleInputEvent(evt);
        } else |err| switch (err) {
            error.Timeout => {
                try self.tick(frame_time);
            },
            else => return err,
        }

        // try self.render();
    }
}

fn handleInputEvent(self: *Self, evt: InputEvent) !void {
    var i = self.components.items.len;

    while (i > 0) {
        i -= 1;
        const handle_res: Conclusion = try self.components.items[i].handleInputEvent(evt);

        switch (handle_res) {
            .Dismount => {
                const to_remove = self.components.orderedRemove(i);
                try to_remove.cleanUp();
            },
            .Mount => |to_mount| {
                // Iterating by index from the original end means newly-mounted
                // components do not handle the same input event that mounted them.
                try self.components.append(self.alloc, to_mount);
            },
            .Noop => continue,
        }
    }
}

fn tick(self: *Self, frame_time: FrameTime) !void {
    var i = self.components.items.len;

    while (i > 0) {
        i -= 1;
        const tick_res = try self.components.items[i].update(frame_time);

        switch (tick_res) {
            .Dismount => {
                const to_remove = self.components.orderedRemove(i);
                try to_remove.cleanUp();
            },
            .Mount => |to_mount| {
                // Iterating by index from the original end means newly-mounted
                // components do not handle the same input event that mounted them.
                try self.components.append(self.alloc, to_mount);
            },
            .Noop => continue,
        }
    }
}

fn render(self: *const Self, nc_ctx: *c.notcurses) !void {
    _ = self;
    _ = nc_ctx;
}

fn loopTime(self: Self) i64 {
    var shortest: i64 = std.time.ms_per_s;

    for (self.components.items) |*comp| {
        const comp_interval = comp.updateInterval() orelse continue;
        shortest = @min(shortest, comp_interval);
    }

    return shortest;
}

test "handleInputEvent mounts and dismounts components" {
    const TestComponent = struct {
        result: Conclusion,
        handled_count: usize = 0,
        cleanup_count: usize = 0,

        fn updateInterval(ptr: *anyopaque) ?i64 {
            _ = ptr;
            return null;
        }

        fn update(ptr: *anyopaque, frame_time: FrameTime) anyerror!Conclusion {
            _ = ptr;
            _ = frame_time;
            return .Noop;
        }

        fn renderFn(ptr: *anyopaque, nc_ctx: *c.notcurses) anyerror!void {
            _ = ptr;
            _ = nc_ctx;
        }

        fn keyHandler(ptr: *anyopaque, evt: InputEvent) anyerror!Conclusion {
            _ = evt;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.handled_count += 1;
            return self.result;
        }

        fn isDirty(ptr: *anyopaque) bool {
            _ = ptr;
            return false;
        }

        fn cleanUp(ptr: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.cleanup_count += 1;
        }

        const vtable: Component.VTable = .{
            .update_interval = updateInterval,
            .update = update,
            .render = renderFn,
            .key_handler = keyHandler,
            .clean_up = cleanUp,
            .is_dirty = isDirty,
        };

        fn component(self: *@This()) Component {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }
    };

    const alloc = std.testing.allocator;
    const channel = try util.Spsc(InputEvent).init(alloc, 1);
    defer channel.deinit();

    var app = init(alloc, channel.rx);
    defer app.deinit(std.testing.io);

    var mounted_state: TestComponent = .{ .result = .Noop };
    const mounted_component = mounted_state.component();

    var keep_state: TestComponent = .{ .result = .Noop };
    var dismount_state: TestComponent = .{ .result = .Dismount };
    var mounting_state: TestComponent = .{ .result = .{ .Mount = mounted_component } };

    try app.components.append(alloc, keep_state.component());
    try app.components.append(alloc, dismount_state.component());
    try app.components.append(alloc, mounting_state.component());

    const input_event: InputEvent = .{
        .timestamp = 123,
        .key = 'x',
        .ncinput = std.mem.zeroes(c.ncinput),
    };

    try app.handleInputEvent(input_event);

    try std.testing.expectEqual(@as(usize, 1), keep_state.handled_count);
    try std.testing.expectEqual(@as(usize, 1), dismount_state.handled_count);
    try std.testing.expectEqual(@as(usize, 1), mounting_state.handled_count);
    try std.testing.expectEqual(@as(usize, 0), mounted_state.handled_count);
    try std.testing.expectEqual(@as(usize, 1), dismount_state.cleanup_count);

    try std.testing.expectEqual(@as(usize, 3), app.components.items.len);
    try std.testing.expectEqual(keep_state.component().ptr, app.components.items[0].ptr);
    try std.testing.expectEqual(mounting_state.component().ptr, app.components.items[1].ptr);
    try std.testing.expectEqual(mounted_component.ptr, app.components.items[2].ptr);
}

test "app core loop consumes input until cancelled" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const channel = try util.Spsc(InputEvent).init(alloc, 1);
    defer channel.deinit();

    var app = init(alloc, channel.rx);
    defer app.deinit(io);

    try app.start(io, @ptrFromInt(1));

    const input_event: InputEvent = .{
        .timestamp = 123,
        .key = 'x',
        .ncinput = std.mem.zeroes(c.ncinput),
    };

    try channel.tx.trySend(io, input_event);

    // The channel has capacity 1. Once the app core loop consumes the first
    // event, sending a second event will succeed.
    var consumed_first = false;
    for (0..100) |_| {
        channel.tx.trySend(io, input_event) catch |err| switch (err) {
            error.ChannelFull => {
                try io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
                continue;
            },
            else => return err,
        };

        consumed_first = true;
        break;
    }

    try std.testing.expect(consumed_first);
}

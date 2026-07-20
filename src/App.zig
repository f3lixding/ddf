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
const RenderCtx = protocol.RenderCtx;

const Self = @This();

alloc: std.mem.Allocator,

components: std.ArrayList(Component) = .empty,
rx: Receiver,
future: ?std.Io.Future(anyerror!void) = null,
render_ctx: RenderCtx = undefined,

pub const Opts = struct {};

pub fn init(alloc: std.mem.Allocator, rx: Receiver) Self {
    return .{
        .alloc = alloc,
        .rx = rx,
    };
}

pub fn start(self: *Self, io: std.Io, nc_ctx: *c.notcurses) !void {
    // This is here so the tests can be ran without the involvement of notcurses
    // I need to find a better way to do this in the future
    if (self.components.items.len > 0) {
        var rows: c_uint = 0;
        var cols: c_uint = 0;

        if (c.notcurses_refresh(nc_ctx, &rows, &cols) < 0) {
            return error.RefreshFailed;
        }

        self.render_ctx = .{
            .term_rows = rows,
            .term_cols = cols,
            .nc_ctx = nc_ctx,
        };
    }
    self.future = try std.Io.concurrent(io, coreLoop, .{ self, io, nc_ctx });
}

/// This is like start but it blocks until the App is concluded
pub fn startAndAwait(self: *Self, io: std.Io, nc_ctx: *c.notcurses) !void {
    try self.start(io, nc_ctx);
    try self.future.?.await(io);
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
    var last_tick = std.Io.Timestamp.now(io, .awake);
    try self.render(nc_ctx);

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

        if (recv_res) |evt| {
            self.handleInputEvent(nc_ctx, evt) catch |err| switch (err) {
                error.Terminate => break,
                else => std.log.scoped(.app).err("input handler failed: {any}", .{err}),
            };
        } else |err| switch (err) {
            error.Timeout => {
                // we handle this outside of this block
            },
            else => return err,
        }

        try self.tick(frame_time);

        try self.render(nc_ctx);
    }
}

fn handleInputEvent(self: *Self, nc_ctx: *c.notcurses, evt: InputEvent) !void {
    if (evt.key == c.NCKEY_RESIZE) {
        if (c.notcurses_refresh(nc_ctx, &self.render_ctx.term_rows, &self.render_ctx.term_cols) < 0) {
            return error.RefreshFailed;
        }
    }
    var i = self.components.items.len;

    while (i > 0) {
        i -= 1;
        const handle_res: Conclusion = try self.components.items[i].handleInputEvent(evt);

        switch (handle_res) {
            .Dismount => {
                const to_remove = self.components.orderedRemove(i);
                try to_remove.cleanUp();

                if (i > 0) {
                    try self.components.items[i - 1].wake();
                }

                break;
            },
            .Mount => |to_mount| {
                // Iterating by index from the original end means newly-mounted
                // components do not handle the same input event that mounted them.
                if (to_mount.hide) {
                    try self.components.items[i].hide();
                }
                try self.components.append(self.alloc, to_mount.component);
            },
            .Quit => return error.Terminate,
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
                try self.components.append(self.alloc, to_mount.component);
            },
            .Quit => return error.Terminate,
            .Noop => continue,
        }
    }
}

fn render(self: *const Self, nc_ctx: *c.notcurses) !void {
    const log = std.log.scoped(.app);
    const render_start_ns = nowNs();

    var needs_to_call_render = false;
    var component_render_ns: i128 = 0;
    for (self.components.items) |*comp| {
        const comp_start_ns = nowNs();
        const rendered = try comp.render(&self.render_ctx);
        component_render_ns += nowNs() - comp_start_ns;
        needs_to_call_render = rendered or needs_to_call_render;
    }

    var nc_render_ns: i128 = 0;
    if (needs_to_call_render) {
        const nc_render_start_ns = nowNs();
        if (c.notcurses_render(nc_ctx) < 0) {
            return error.RenderFailed;
        }
        nc_render_ns = nowNs() - nc_render_start_ns;
    }

    log.debug("App.render profile: total_ms={d:.3} component_ms={d:.3} notcurses_render_ms={d:.3} did_render={any}", .{
        nsToMs(nowNs() - render_start_ns),
        nsToMs(component_render_ns),
        nsToMs(nc_render_ns),
        needs_to_call_render,
    });
}

fn nowNs() i128 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (@as(i128, ts.tv_sec) * std.time.ns_per_s) + @as(i128, ts.tv_nsec);
}

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
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

        fn update(ptr: *anyopaque, frame_time: FrameTime) anyerror!Conclusion {
            _ = ptr;
            _ = frame_time;
            return .Noop;
        }

        fn renderFn(ptr: *anyopaque, render_ctx: *const RenderCtx) anyerror!void {
            _ = ptr;
            _ = render_ctx;
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
    var mounting_state: TestComponent = .{ .result = .{ .Mount = .{
        .component = mounted_component,
        .hide = false,
    } } };

    try app.components.append(alloc, keep_state.component());
    try app.components.append(alloc, dismount_state.component());
    try app.components.append(alloc, mounting_state.component());

    const input_event: InputEvent = .{
        .timestamp = 123,
        .key = 'x',
        .ncinput = std.mem.zeroes(c.ncinput),
    };

    try app.handleInputEvent(@ptrFromInt(1), input_event);

    // Handling stops after a component dismounts, so lower components do not
    // handle the same input event after stack shape changes.
    try std.testing.expectEqual(@as(usize, 0), keep_state.handled_count);
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

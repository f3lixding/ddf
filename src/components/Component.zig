const std = @import("std");

const util = @import("../util.zig");
const c = util.c;
const protocol = @import("../protocol.zig");
const InputEvent = protocol.InputEvent;
const FrameTime = protocol.FrameTime;
const Conclusion = protocol.Conclusion;

const Component = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    update_interval: *const fn (*anyopaque) ?i64,
    update: *const fn (*anyopaque, FrameTime) anyerror!Conclusion,
    render: *const fn (*anyopaque, *c.notcurses) anyerror!void,
    key_handler: *const fn (*anyopaque, InputEvent) anyerror!Conclusion,
    clean_up: *const fn (*anyopaque) anyerror!void,
    is_dirty: *const fn (*anyopaque) bool,
};

/// Called to update internal state that depends on app-loop time, such as
/// animations or scheduled refreshes, as opposed to external input events.
pub fn update(self: Component, frame_time: FrameTime) anyerror!Conclusion {
    return try self.vtable.update(self.ptr, frame_time);
}

/// Called by the orchestrator to retrieve the component's preference to have
/// internal states updated
pub fn updateInterval(self: Component) ?i64 {
    return self.vtable.update_interval(self.ptr);
}

pub fn render(self: Component, nc_ctx: *c.notcurses) anyerror!void {
    if (self.vtable.is_dirty(self.ptr)) {
        try self.vtable.render(self.ptr, nc_ctx);
    }
}

pub fn handleInputEvent(self: Component, evt: InputEvent) anyerror!Conclusion {
    return try self.vtable.key_handler(self.ptr, evt);
}

pub fn cleanUp(self: Component) anyerror!void {
    try self.vtable.clean_up(self.ptr);
}

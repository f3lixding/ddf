const std = @import("std");

const util = @import("../util.zig");
const c = util.c;
const protocol = @import("../protocol.zig");
const InputEvent = protocol.InputEvent;
const FrameTime = protocol.FrameTime;
const Conclusion = protocol.Conclusion;
const RenderCtx = protocol.RenderCtx;

const Component = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    update_interval: ?*const fn (*anyopaque) i64 = null,
    update: ?*const fn (*anyopaque, FrameTime) anyerror!Conclusion = null,
    render: *const fn (*anyopaque, *const RenderCtx) anyerror!void,
    key_handler: ?*const fn (*anyopaque, InputEvent) anyerror!Conclusion = null,
    clean_up: ?*const fn (*anyopaque) anyerror!void = null,
    is_dirty: *const fn (*anyopaque) bool = &struct {
        pub fn isDirty(ptr: *anyopaque) bool {
            _ = ptr;
            return true;
        }
    }.isDirty,
    wake: ?*const fn (*anyopaque) anyerror!void = null,
    hide: ?*const fn (*anyopaque) anyerror!void = null,
};

/// Called to update internal state that depends on app-loop time, such as
/// animations or scheduled refreshes, as opposed to external input events.
pub fn update(self: Component, frame_time: FrameTime) anyerror!Conclusion {
    const updateFn = self.vtable.update orelse return .Noop;
    return try updateFn(self.ptr, frame_time);
}

/// Called by the orchestrator to retrieve the component's preference to have
/// internal states updated
pub fn updateInterval(self: Component) ?i64 {
    const updateIntervalFn = self.vtable.update_interval orelse return null;
    return updateIntervalFn(self.ptr);
}

pub fn render(self: Component, render_ctx: *const RenderCtx) anyerror!bool {
    if (self.vtable.is_dirty(self.ptr)) {
        try self.vtable.render(self.ptr, render_ctx);
        return true;
    }
    return false;
}

pub fn handleInputEvent(self: Component, evt: InputEvent) anyerror!Conclusion {
    const keyHandlerFn = self.vtable.key_handler orelse return .Noop;
    return try keyHandlerFn(self.ptr, evt);
}

pub fn cleanUp(self: Component) anyerror!void {
    const cleanUpFn = self.vtable.clean_up orelse return;
    try cleanUpFn(self.ptr);
}

/// Opposite to hide. This should restore a Component's normal state
/// This is called on the new top Component when a Component is unmounted
pub fn wake(self: Component) anyerror!void {
    const wakeFn = self.vtable.wake orelse return;
    return try wakeFn(self.ptr);
}

/// Components that are hidden should not be called upon for update and render
/// This function is an opportunity for Components to clear their planes
pub fn hide(self: Component) anyerror!void {
    const hideFn = self.vtable.hide orelse return;
    return try hideFn(self.ptr);
}

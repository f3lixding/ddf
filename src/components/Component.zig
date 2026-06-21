const std = @import("std");

const util = @import("../util.zig");
const c = util.c;
const protocol = @import("../protocol.zig");
const InputEvent = protocol.InputEvent;
const Conclusion = protocol.Conclusion;

const Component = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    update_interval: *const fn (*anyopaque) ?i64,
    update: *const fn (*anyopaque, i64) anyerror!void,
    render: *const fn (*anyopaque, *c.notcurses) anyerror!void,
    key_handler: *const fn (*anyopaque, InputEvent) anyerror!Conclusion,
    should_update: *const fn (*anyopaque, i64) bool,
    clean_up: *const fn (*anyopaque) anyerror!void,
};

pub fn update(self: Component, time_elapsed: i64) anyerror!Conclusion {
    return try self.vtable.update(self.ptr, time_elapsed);
}

pub fn updateInterval(self: Component) ?i64 {
    return self.vtable.update_interval(self.ptr);
}

pub fn render(self: Component, nc_ctx: *c.notcurses) anyerror!void {
    try self.vtable.render(self.ptr, nc_ctx);
}

pub fn handleInputEvent(self: Component, evt: InputEvent) anyerror!Conclusion {
    return try self.vtable.key_handler(self.ptr, evt);
}

pub fn shouldUpdate(self: Component, cur_time_ms: i64) bool {
    return self.vtable.should_update(self.ptr, cur_time_ms);
}

pub fn cleanUp(self: Component) anyerror!void {
    try self.vtable.clean_up(self.ptr);
}

const std = @import("std");

const util = @import("../util.zig");
const c = util.c;
const Gif = @import("Gif.zig");
const FrameTime = @import("../protocol.zig").FrameTime;
const Conclusion = @import("../protocol.zig").Conclusion;

const Self = @This();

gif: Gif,

pub const Opts = struct {
    y: c_int = 0,
    x: c_int = 0,
    height: c_uint,
    width: ?c_uint = null,
};

pub fn init(
    nc_ctx: *c.notcurses,
    parent_plane: *c.ncplane,
    opts: Opts,
) !Self {
    const gif = try Gif.init(
        nc_ctx,
        parent_plane,
        .{
            .y = opts.y,
            .x = opts.x,
            .height = opts.height,
            .width = opts.width,
            .asset_name = "bongo-cat.gif",
        },
    );

    return .{ .gif = gif };
}

pub fn deinit(self: *Self) void {
    self.gif.deinit();
}

pub fn render(self: *Self, nc_ctx: *c.notcurses) !void {
    try self.gif.render(nc_ctx);
}

pub fn isDirty(self: Self) bool {
    return self.gif.dirty;
}

pub fn update(self: *Self, ft: FrameTime) !Conclusion {
    return try self.gif.update(ft);
}

const std = @import("std");

const util = @import("../util/root.zig");
const c = util.c;
const Gif = @import("Gif.zig");
const assets = @import("../assets/assets.zig");
const FrameTime = @import("../protocol.zig").FrameTime;
const Conclusion = @import("../protocol.zig").Conclusion;

const Self = @This();

plane: *c.ncplane,
gif: Gif,
state: State = .{ .normal = 1 },
pending_transition: bool = false,

pub const Opts = struct {
    y: c_int = 0,
    x: c_int = 0,
    height: c_uint,
    width: ?c_uint = null,
};

pub const State = union(enum) {
    // viewport line idx
    normal: usize,
    // viewport line idx
    // the range is _inclusive_
    visual: struct { range: [2]usize, focus_bound: usize },
    hidden,
};

pub fn init(
    nc_ctx: *c.notcurses,
    parent_plane: *c.ncplane,
    opts: Opts,
) !Self {
    var plane_opts = std.mem.zeroes(c.ncplane_options);
    plane_opts.y = opts.y;
    plane_opts.x = opts.x;
    plane_opts.rows = 1;
    plane_opts.cols = opts.width orelse 1;
    plane_opts.name = "line_indicator_plane";

    const plane = c.ncplane_create(parent_plane, &plane_opts) orelse return error.CreatePlaneFailed;
    errdefer _ = c.ncplane_destroy(plane);

    const gif = try Gif.init(
        nc_ctx,
        plane,
        .{
            .y = 0,
            .x = 0,
            .height = opts.height,
            .width = null,
            .asset = .{
                .name = "bongo-cat.gif",
                .bytes = assets.line_indicator,
            },
        },
    );

    return .{ .plane = plane, .gif = gif };
}

pub fn deinit(self: *Self) void {
    self.gif.deinit();
    _ = c.ncplane_destroy(self.plane);
}

pub fn render(self: *Self, nc_ctx: *c.notcurses) !void {
    self.pending_transition = false;

    switch (self.state) {
        .hidden => return,

        .visual => |visual| {
            const range = &visual.range;
            const focus_idx = range[visual.focus_bound];
            const lower_idx = @min(range[0], range[1]);
            const higher_idx = @max(range[0], range[1]);
            const height = higher_idx - lower_idx + 1;

            try self.resizeToParentWidthWithHeight(@intCast(height));
            try self.setVisualBg();

            if (c.ncplane_move_yx(self.plane, @intCast(lower_idx), 1) < 0) {
                return error.MovePlaneFailed;
            }
            try self.gif.move(@intCast(focus_idx - lower_idx), 0);
        },

        .normal => |idx| {
            try self.resizeToParentWidthWithHeight(1);
            try self.setNormalBg();
            if (c.ncplane_move_yx(self.plane, @intCast(idx), 1) < 0) {
                return error.MovePlaneFailed;
            }
            try self.gif.move(0, 0);
        },
    }

    try self.gif.render(nc_ctx);
}

pub fn isDirty(self: Self) bool {
    return switch (self.state) {
        .hidden => false,
        else => self.gif.dirty or self.pending_transition,
    };
}

pub fn enterVisualMode(self: *Self) void {
    const cur_vp_idx = switch (self.state) {
        .normal => |idx| idx,
        else => return,
    };

    self.state = .{ .visual = .{
        .range = .{ cur_vp_idx, cur_vp_idx },
        .focus_bound = 0,
    } };

    self.pending_transition = true;
    self.gif.dirty = true;
}

pub fn setVisualControlledIndex(self: *Self, viewport_idx: usize, scroll_delta: isize) void {
    switch (self.state) {
        .visual => |*visual| {
            visual.range[0] = shiftedViewportIndex(visual.range[0], scroll_delta);
            visual.range[1] = shiftedViewportIndex(visual.range[1], scroll_delta);
            visual.range[visual.focus_bound] = viewport_idx;
        },
        else => return,
    }

    self.pending_transition = true;
    self.gif.dirty = true;
}

fn shiftedViewportIndex(idx: usize, delta: isize) usize {
    if (delta >= 0) return idx + @as(usize, @intCast(delta));
    return idx -| @as(usize, @intCast(-delta));
}

pub fn update(self: *Self, ft: FrameTime) !Conclusion {
    try self.resizeToParentWidthForState();
    if (self.state == .hidden) return .Noop;
    return try self.gif.update(ft);
}

pub fn resize(self: *Self, height: c_uint, width: c_uint) !void {
    const new_height = @max(@as(c_uint, 1), height);
    const new_width = @max(@as(c_uint, 1), width);

    var old_height: c_uint = 0;
    var old_width: c_uint = 0;
    c.ncplane_dim_yx(self.plane, &old_height, &old_width);
    if (old_height == new_height and old_width == new_width) return;

    if (c.ncplane_resize_simple(self.plane, new_height, new_width) < 0) {
        return error.ResizePlaneFailed;
    }
    self.gif.dirty = true;
}

fn resizeToParentWidthForState(self: *Self) !void {
    const height: c_uint = switch (self.state) {
        .visual => |visual| @intCast(@max(visual.range[0], visual.range[1]) - @min(visual.range[0], visual.range[1]) + 1),
        else => 1,
    };
    try self.resizeToParentWidthWithHeight(height);
}

fn resizeToParentWidthWithHeight(self: *Self, height: c_uint) !void {
    const parent = c.ncplane_parent(self.plane) orelse return;
    const parent_width = c.ncplane_dim_x(parent);
    try self.resize(height, parent_width -| 2);
}

pub fn move(self: *Self, y: c_int) !void {
    self.state = .{ .normal = @intCast(@max(y, 1)) };
    try self.gif.move(0, 0);
    self.gif.dirty = true;
}

pub fn hide(self: *Self) void {
    self.state = .hidden;
    self.gif.hide() catch {};
}

pub fn unhide(self: *Self) void {
    if (self.state == .hidden) self.state = .{ .normal = 0 };
    self.gif.unhide();
}

/// Returns the index that is currently being controlled in visual mode This is
/// external facing because only consumer of line indicator has context has to
/// when to scroll So it does not quite make sense to store all that states in
/// here (thus we need to vend this number to its consumer)
pub fn currentControlledIndex(self: Self) ?usize {
    return switch (self.state) {
        .visual => |visual| blk: {
            const idx = visual.focus_bound;
            break :blk visual.range[idx];
        },
        else => null,
    };
}

fn setVisualBg(self: *Self) !void {
    try self.setBg(0x50, 0x40, 0x30);
}

fn setNormalBg(self: *Self) !void {
    // Subtle blue-gray highlight: visible enough to track focus, but much less
    // prominent than visual mode.
    try self.setBg(0x3a, 0x4a, 0x52);
}

fn setBg(self: *Self, r: u8, g: u8, b: u8) !void {
    var channels: u64 = 0;
    _ = c.ncchannels_set_fg_default(&channels);
    _ = c.ncchannels_set_bg_rgb8(&channels, r, g, b);
    _ = c.ncchannels_set_bg_alpha(&channels, c.NCALPHA_BLEND);

    // `ncplane_erase()` clears cells to the plane base cell; setting only the
    // current bg channel is not enough to make an empty plane visibly colored.
    // Keep the base cell's grapheme empty (gcluster == 0) so text from lower
    // planes still shows through; only the background tint blends over it.
    var base = std.mem.zeroes(c.nccell);
    base.channels = channels;
    if (c.ncplane_set_base_cell(self.plane, &base) < 0) {
        return error.SetBgFailed;
    }
    c.ncplane_erase(self.plane);
}

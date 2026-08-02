const std = @import("std");

const util = @import("../util/root.zig");
const c = util.c;

const Self = @This();

const TIPS: []const u8 = "j/k move • Ctrl-d/u page • V select • c comment • q quit";

pub const Mode = enum {
    normal,
    comment,
    select,
    search,

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .comment => "COMMENT",
            .select => "SELECT",
            .search => "SEARCH",
        };
    }
};

pub const Op = union(enum) {
    add_single: u8,
    add_multiple: []const u8,
    delete_single,
};

pub const State = union(Mode) {
    normal: []const u8,
    comment,
    select,
    search: Query,
};

pub const Query = struct {
    pub const SearchDirection = enum {
        up,
        down,
    };

    pub const Result = enum {
        unknown,
        found,
        not_found,
    };

    dir: SearchDirection = .down,
    query: std.ArrayList(u8) = .empty,
    result: Result = .unknown,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.query.deinit(alloc);
    }
};

pub const Opts = struct {
    y: c_int = 0,
    x: c_int = 0,
    height: c_uint,
    width: ?c_uint = null,
};

plane: *c.ncplane,
state: State = .{ .normal = TIPS },
pending_transition: bool = true,

pub fn init(parent_plane: *c.ncplane, opts: Opts) !Self {
    var plane_opts = std.mem.zeroes(c.ncplane_options);
    plane_opts.y = opts.y;
    plane_opts.x = opts.x;
    plane_opts.rows = opts.height;
    plane_opts.cols = opts.width orelse 1;
    plane_opts.name = "detail_bar_plane";

    const plane = c.ncplane_create(parent_plane, &plane_opts) orelse return error.CreatePlaneFailed;

    return .{ .plane = plane };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    _ = c.ncplane_destroy(self.plane);

    switch (self.state) {
        .search => |*query| query.deinit(alloc),
        else => {},
    }
}

pub fn setMode(self: *Self, alloc: std.mem.Allocator, mode: Mode) void {
    if (std.meta.activeTag(self.state) == mode) return;

    switch (self.state) {
        .search => |*query| query.deinit(alloc),
        else => {},
    }

    self.state = switch (mode) {
        .normal => .{ .normal = TIPS },
        .comment => .comment,
        .select => .select,
        .search => .{ .search = .{} },
    };
    self.pending_transition = true;
}

pub fn flipSearchDirection(self: *Self) void {
    switch (self.state) {
        .search => |*s| {
            s.dir = if (s.dir == .up) .down else .up;
            s.result = .unknown;
            self.pending_transition = true;
        },
        else => {},
    }
}

pub fn setSearchResult(self: *Self, found: bool) void {
    switch (self.state) {
        .search => |*s| {
            const result: Query.Result = if (found) .found else .not_found;
            if (s.result == result) return;
            s.result = result;
            self.pending_transition = true;
        },
        else => {},
    }
}

pub fn modifySearchQuery(self: *Self, alloc: std.mem.Allocator, op: Op) !void {
    switch (self.state) {
        .search => |*s| {
            const query = &s.query;

            switch (op) {
                .add_single => |char| {
                    try query.append(alloc, char);
                    s.result = .unknown;
                    self.pending_transition = true;
                },
                .add_multiple => |arr| {
                    try query.appendSlice(alloc, arr);
                    s.result = .unknown;
                    self.pending_transition = true;
                },
                .delete_single => {
                    if (query.items.len > 0) {
                        query.items.len -= 1;
                        s.result = .unknown;
                        self.pending_transition = true;
                    }
                },
            }
        },
        else => {},
    }
}

/// Keep the bar pinned to the bottom of its parent plane and spanning its width.
pub fn update(self: *Self, parent_plane: *c.ncplane) !void {
    var parent_rows: c_uint = 0;
    var parent_cols: c_uint = 0;
    c.ncplane_dim_yx(parent_plane, &parent_rows, &parent_cols);

    const width = @max(@as(c_uint, 1), parent_cols);
    const y: c_int = @intCast(parent_rows -| 1);

    var rows: c_uint = 0;
    var cols: c_uint = 0;
    c.ncplane_dim_yx(self.plane, &rows, &cols);

    var abs_y: c_int = 0;
    var abs_x: c_int = 0;
    c.ncplane_yx(self.plane, &abs_y, &abs_x);

    if (rows == 1 and cols == width and abs_y == y and abs_x == 0) return;

    try self.resize(.{ .height = 1, .y = y, .x = 0, .width = width });
}

pub fn resize(self: *Self, opts: Opts) !void {
    if (c.ncplane_resize_simple(self.plane, opts.height, opts.width orelse 1) < 0) {
        return error.ResizePlaneFailed;
    }
    if (c.ncplane_move_yx(self.plane, opts.y, opts.x) < 0) {
        return error.MovePlaneFailed;
    }
    self.pending_transition = true;
}

pub fn render(self: *Self, nc_ctx: *c.notcurses) !void {
    _ = nc_ctx;
    self.pending_transition = false;

    try self.setTipsBaseBg();
    c.ncplane_erase(self.plane);

    var rows: c_uint = 0;
    var cols: c_uint = 0;
    c.ncplane_dim_yx(self.plane, &rows, &cols);
    if (rows == 0 or cols == 0) return;

    const mode_text = std.meta.activeTag(self.state).label();
    var mode_buf: [32]u8 = undefined;
    const mode_segment = blk: switch (self.state) {
        .search => |*s| {
            if (s.dir == .up) {
                break :blk try std.fmt.bufPrint(&mode_buf, " {s} (UP) ", .{mode_text});
            } else {
                break :blk try std.fmt.bufPrint(&mode_buf, " {s} (DOWN) ", .{mode_text});
            }
        },
        else => break :blk try std.fmt.bufPrint(&mode_buf, " {s} ", .{mode_text}),
    };

    const mode_clipped = util.clipToDisplayWidth(mode_segment, cols);

    try self.drawMode(mode_clipped);

    const mode_width = util.displayWidth(mode_clipped);
    if (mode_width >= cols) return;

    var tips_buf: [512]u8 = undefined;
    const tips = switch (self.state) {
        .normal => |msg| msg,
        .comment => "type comment • Enter newline • Esc finish",
        .select => "j/k extend • o flip side • c comment • Esc cancel",
        .search => |*s| switch (s.result) {
            .unknown, .found => s.query.items,
            .not_found => std.fmt.bufPrint(&tips_buf, "NO RESULTS • {s}", .{s.query.items}) catch "NO RESULTS",
        },
    };
    const tips_x: c_int = @intCast(mode_width);
    const remaining_width: usize = @intCast(cols - mode_width);
    const tips_clipped = util.clipToDisplayWidth(tips, remaining_width);
    try self.drawTips(tips_x, tips_clipped);
}

pub fn isDirty(self: Self) bool {
    return self.pending_transition;
}

pub fn conclude(self: Self) ?Query {
    return switch (self.state) {
        .normal, .comment, .select => null,
        .search => |query| query,
    };
}

fn drawMode(self: *Self, text: []const u8) !void {
    c.ncplane_set_styles(self.plane, c.NCSTYLE_BOLD);
    if (c.ncplane_set_fg_rgb8(self.plane, 0x00, 0x00, 0x00) < 0) return error.SetColorFailed;
    if (c.ncplane_set_bg_rgb8(self.plane, 0xaf, 0x87, 0xff) < 0) return error.SetColorFailed;
    defer {
        c.ncplane_set_styles(self.plane, c.NCSTYLE_NONE);
        c.ncplane_set_fg_default(self.plane);
        c.ncplane_set_bg_default(self.plane);
    }

    try util.putEgcSegment(self.plane, 0, 0, text);
}

fn drawTips(self: *Self, x: c_int, text: []const u8) !void {
    if (c.ncplane_set_fg_rgb8(self.plane, 0x20, 0x20, 0x20) < 0) return error.SetColorFailed;
    defer c.ncplane_set_fg_default(self.plane);

    try util.putEgcSegment(self.plane, 0, x + 1, text);
}

fn setTipsBaseBg(self: *Self) !void {
    var channels: u64 = 0;
    _ = c.ncchannels_set_fg_default(&channels);
    _ = c.ncchannels_set_bg_rgb8(&channels, 0xd0, 0xd0, 0xd0);
    _ = c.ncchannels_set_bg_alpha(&channels, c.NCALPHA_BLEND);

    var base = std.mem.zeroes(c.nccell);
    base.channels = channels;
    if (c.ncplane_set_base_cell(self.plane, &base) < 0) {
        return error.SetBgFailed;
    }
}

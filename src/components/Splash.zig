//! This is the base component for the app and will always be spawned first at
//! the bottom and only at the bottom of the stack.
const std = @import("std");

const util = @import("../util.zig");
const consts = @import("../consts.zig");
const c = util.c;
const protocol = @import("../protocol.zig");

const InputEvent = protocol.InputEvent;
const FrameTime = protocol.FrameTime;
const Conclusion = protocol.Conclusion;
const RenderCtx = protocol.RenderCtx;

const Component = @import("Component.zig");
const DiffWindow = @import("DiffWindow.zig");
const Bucket = util.LeakyBucket(InputEvent);
const logging = std.log.scoped(.splash);
const Gif = @import("Gif.zig");

const Self = @This();

alloc: std.mem.Allocator,
io: std.Io,
input_bucket: Bucket,
initial_render_done: bool = false,
hidden: bool = false,
hiding: bool = false,
gif: ?Gif = null,
logo: [5][:0]const u8 = .{
    "     ____  ______ ",
    "    / __ \\/ ____/",
    "   / / / / /_     ",
    "  / /_/ / __/     ",
    " /_____/_/        ",
},

pub fn initInterface(self: *Self) Component {
    return .{
        .ptr = self,
        .vtable = &.{
            .render = struct {
                pub fn _render(ptr: *anyopaque, render_ctx: *const RenderCtx) !void {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    try @call(.always_inline, render, .{ self_typed, render_ctx });
                }
            }._render,

            .is_dirty = struct {
                pub fn isDirty(ptr: *anyopaque) bool {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    if (self_typed.hiding) return true;
                    if (self_typed.hidden) return false;

                    return if (self_typed.gif) |g| gif: {
                        const res = if (g.hidden) false else g.dirty;
                        break :gif res;
                    } else false;
                }
            }.isDirty,

            .key_handler = struct {
                pub fn handleInput(ptr: *anyopaque, event: InputEvent) !Conclusion {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    return try @call(.always_inline, handleInputEvent, .{ self_typed, event });
                }
            }.handleInput,

            .update = struct {
                pub fn _update(ptr: *anyopaque, ft: FrameTime) !Conclusion {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    return try @call(.always_inline, update, .{ self_typed, ft });
                }
            }._update,

            .update_interval = struct {
                pub fn updateInterval(ptr: *anyopaque) i64 {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    if (self_typed.gif) |*g| {
                        return g.updateInterval() orelse 1000;
                    }
                    return 1000;
                }
            }.updateInterval,

            .wake = struct {
                pub fn wake_(ptr: *anyopaque) !void {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    return try @call(.always_inline, wake, .{self_typed});
                }
            }.wake_,

            .hide = struct {
                pub fn hide_(ptr: *anyopaque) !void {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    return try @call(.always_inline, hide, .{self_typed});
                }
            }.hide_,
        },
    };
}

pub fn init(alloc: std.mem.Allocator, io: std.Io, nc_ctx: *c.notcurses) !Self {
    const input_bucket = Bucket.init(.{});
    const stdplane = c.notcurses_stdplane(nc_ctx) orelse return error.NoStdplane;
    const gif = try Gif.init(
        nc_ctx,
        stdplane,
        .{
            .height = 20,
            .asset_name = "scuba-scuba-cat.gif",
        },
    );

    return .{
        .alloc = alloc,
        .io = io,
        .input_bucket = input_bucket,
        .gif = gif,
    };
}

pub fn handleInputEvent(self: *Self, input_event: InputEvent) !Conclusion {
    if (self.hidden) {
        return .Noop;
    }

    const key = input_event.key;

    switch (key) {
        'q' => return .Quit,
        c.NCKEY_RESIZE => {
            self.initial_render_done = false;
        },
        else => {
            const input_slice = self.input_bucket.insertAndReport(input_event) catch retry: {
                self.input_bucket.clear();
                break :retry try self.input_bucket.insertAndReport(input_event);
            };
            // TODO: codify this routine
            const open_diff = " df";
            var iter = input_slice.iterator();

            var last_relevant_evt: ?*InputEvent = null;
            var count: usize = 0;
            while (iter.next()) |event| {
                if (event.key == open_diff[0]) {
                    count = 1;
                    last_relevant_evt = event;
                    continue;
                }

                if (event.key == open_diff[count])
                    count += 1;

                if (count >= open_diff.len) {
                    const diff_window = try self.alloc.create(DiffWindow);
                    errdefer self.alloc.destroy(diff_window);
                    diff_window.* = try DiffWindow.init(self.alloc, self.io);

                    self.hiding = true;

                    return .{ .Mount = .{ .component = diff_window.initInterface(), .hide = true } };
                }
            }
        },
    }

    return .Noop;
}

pub fn render(self: *Self, render_ctx: *const RenderCtx) !void {
    const nc_ctx = render_ctx.nc_ctx;

    if (self.hidden and !self.hiding) return;

    if (!self.initial_render_done) {
        var rows: c_uint = 0;
        var cols: c_uint = 0;

        const stdplane = c.notcurses_stdplane(nc_ctx) orelse return error.NoStdplane;
        c.ncplane_dim_yx(stdplane, &rows, &cols);

        c.ncplane_erase(stdplane);

        const title: [:0]const u8 = "doodle finder";
        const hint: [:0]const u8 = "press j/f, resize the terminal, make something messy";

        const logo_width: c_uint = @intCast(self.logo[0].len);
        const block_height: c_uint = self.logo.len + 4;
        const origin_y = centered(rows, block_height);
        const origin_x = centered(cols, logo_width);

        if (c.ncplane_set_fg_rgb8(stdplane, 0x85, 0xd7, 0xff) < 0) return error.SetColorFailed;
        c.ncplane_set_styles(stdplane, c.NCSTYLE_BOLD);

        for (self.logo, 0..) |line, i| {
            const y: c_int = origin_y + @as(c_int, @intCast(i));
            if (c.ncplane_putstr_yx(stdplane, y, origin_x, line.ptr) < 0) {
                return error.PutStrFailed;
            }
        }

        c.ncplane_set_styles(stdplane, c.NCSTYLE_NONE);
        if (c.ncplane_set_fg_rgb8(stdplane, 0xff, 0xd8, 0x66) < 0) return error.SetColorFailed;
        try putCentered(stdplane, origin_y + @as(c_int, @intCast(self.logo.len)) + 1, cols, title);

        if (c.ncplane_set_fg_rgb8(stdplane, 0x88, 0x88, 0x88) < 0) return error.SetColorFailed;
        try putCentered(stdplane, origin_y + @as(c_int, @intCast(self.logo.len)) + 3, cols, hint);

        self.initial_render_done = true;

        const gif_x = origin_x + @as(c_int, @intCast(logo_width));
        if (self.gif) |*gif| {
            try gif.move(origin_y, gif_x);
        }
    } else if (self.hiding) {
        self.hiding = false;

        const stdplane = c.notcurses_stdplane(nc_ctx) orelse return error.NoStdplane;
        c.ncplane_erase(stdplane);
        c.ncplane_set_styles(stdplane, c.NCSTYLE_NONE);
        c.ncplane_set_fg_default(stdplane);
        c.ncplane_set_bg_default(stdplane);

        if (self.gif) |*gif| {
            gif.hide();
        }

        return;
    }

    if (self.gif) |*gif| try gif.render(nc_ctx);
}

pub fn update(self: *Self, ft: FrameTime) !Conclusion {
    if (self.hidden) return .Noop;

    if (self.gif) |*gif| {
        return try gif.update(ft);
    }

    return .Noop;
}

pub fn wake(self: *Self) !void {
    self.hidden = false;
    self.hiding = false;
    self.initial_render_done = false;
    self.input_bucket.clear();

    if (self.gif) |*gif| {
        gif.unhide();
    }
}

pub fn hide(self: *Self) !void {
    self.hidden = true;
    self.hiding = true;
    self.input_bucket.clear();

    if (self.gif) |*gif| {
        gif.dirty = false;
    }
}

fn centered(outer: c_uint, inner: c_uint) c_int {
    if (outer <= inner) return 0;
    return @intCast((outer - inner) / 2);
}

fn putCentered(plane: *c.ncplane, y: c_int, cols: c_uint, text: [:0]const u8) !void {
    const text_width: c_uint = @intCast(text.len);
    const x = centered(cols, text_width);
    if (c.ncplane_putstr_yx(plane, y, x, text.ptr) < 0) {
        return error.PutStrFailed;
    }
}

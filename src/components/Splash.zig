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
const Component = @import("Component.zig");
const Bucket = util.LeakyBucket(InputEvent);
const RenderCtx = protocol.RenderCtx;
const ASSET_PATH = consts.ASSET_PATH;

const cat_gif = @embedFile("../assets/scuba-scuba-cat.gif");

const Self = @This();

input_bucket: Bucket,
initial_render_done: bool = false,
gif: ?Gif = null,

pub fn initInterface(self: *Self) Component {
    return .{
        .ptr = self,
        .vtable = &.{
            .render = struct {
                pub fn _render(ptr: *anyopaque, render_ctx: *const RenderCtx, nc_ctx: *c.notcurses) !void {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    try @call(.always_inline, render, .{ self_typed, render_ctx, nc_ctx });
                }
            }._render,

            .is_dirty = struct {
                pub fn isDirty(ptr: *anyopaque) bool {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    return if (self_typed.gif) |g|
                        g.dirty
                    else
                        false;
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
        },
    };
}

const Gif = struct {
    visual: *c.ncvisual,
    plane: *c.ncplane,
    vopts: c.ncvisual_options,

    frame_interval_ms: i64 = 1000 / 24,
    elapsed_ms: i64 = 0,
    dirty: bool = true,

    pub fn init(parent_plane: *c.ncplane) !Gif {
        // TODO: move more of this into util
        var path_buf: [256]u8 = undefined;
        var full_path_buf: [256]u8 = undefined;

        const subpath = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ ASSET_PATH, "scuba-scuba-cat.gif" });
        const full_asset_path = try util.getDirRelativeToHomeSentinel(&full_path_buf, subpath);
        std.log.err("full asset path: {s}", .{full_asset_path});

        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const file_exists = if (std.Io.Dir.accessAbsolute(io, full_asset_path, .{})) true else |_| false;

        if (!file_exists) {
            if (std.fs.path.dirname(full_asset_path)) |parent| {
                try std.Io.Dir.cwd().createDirPath(io, parent);
            }
            var file = try std.Io.Dir.createFileAbsolute(io, full_asset_path, .{});
            defer file.close(io);

            try file.writeStreamingAll(io, cat_gif);
        }

        const visual = c.ncvisual_from_file(full_asset_path.ptr) orelse return error.GifLoadFailed;
        var popts = std.mem.zeroes(c.ncplane_options);
        popts.y = 2;
        popts.x = 4;
        popts.rows = 20;
        popts.cols = 40;
        popts.name = "gif";

        const plane = c.ncplane_create(parent_plane, &popts) orelse return error.CreatePlaneFailed;

        var vopts = std.mem.zeroes(c.ncvisual_options);
        vopts.n = plane;
        vopts.scaling = c.NCSCALE_SCALE;
        vopts.blitter = c.NCBLIT_DEFAULT;
        vopts.y = 0;
        vopts.x = 0;

        return .{
            .visual = visual,
            .plane = plane,
            .vopts = vopts,
        };
    }

    pub fn update(self: *Gif, frame_time: FrameTime) !Conclusion {
        self.elapsed_ms += frame_time.elapsed_ms;

        while (self.elapsed_ms >= self.frame_interval_ms) {
            self.elapsed_ms -= self.frame_interval_ms;

            const rc = c.ncvisual_decode_loop(self.visual);
            if (rc < 0) return error.DecodeGifFailed;

            self.dirty = true;
        }

        return .Noop;
    }

    pub fn render(self: *Gif, nc_ctx: *c.notcurses) !void {
        if (!self.dirty) return;

        c.ncplane_erase(self.plane);

        if (c.ncvisual_blit(nc_ctx, self.visual, &self.vopts) == null) {
            return error.BlitGifFailed;
        }

        self.dirty = false;
    }

    pub fn updateInterval(self: *Gif) ?i64 {
        _ = self;
        return 1000 / 24;
    }
};

pub fn init(nc_ctx: *c.notcurses) !Self {
    const input_bucket = Bucket.init(.{});
    const stdplane = c.notcurses_stdplane(nc_ctx) orelse return error.NoStdplane;
    const gif = try Gif.init(stdplane);

    return .{
        .input_bucket = input_bucket,
        .gif = gif,
    };
}

pub fn handleInputEvent(self: *Self, input_event: InputEvent) !Conclusion {
    const key = input_event.key;

    switch (key) {
        'q' => return .Quit,
        c.NCKEY_RESIZE => {
            self.initial_render_done = false;
        },
        else => {},
    }

    return .Noop;
}

pub fn render(self: *Self, render_ctx: *const RenderCtx, nc_ctx: *c.notcurses) !void {
    if (!self.initial_render_done) {
        const rows = render_ctx.rows;
        const cols = render_ctx.cols;

        const stdplane = c.notcurses_stdplane(nc_ctx) orelse return error.NoStdplane;

        c.ncplane_erase(stdplane);

        const logo = [_][:0]const u8{
            "     ____  ______ ",
            "    / __ \\/ ____/",
            "   / / / / /_     ",
            "  / /_/ / __/     ",
            " /_____/_/        ",
        };
        const title: [:0]const u8 = "doodle finder";
        const hint: [:0]const u8 = "press j/f, resize the terminal, make something messy";

        const logo_width: c_uint = logo[0].len;
        const block_height: c_uint = logo.len + 4;
        const origin_y = centered(rows, block_height);
        const origin_x = centered(cols, logo_width);

        if (c.ncplane_set_fg_rgb8(stdplane, 0x85, 0xd7, 0xff) < 0) return error.SetColorFailed;
        c.ncplane_set_styles(stdplane, c.NCSTYLE_BOLD);

        for (logo, 0..) |line, i| {
            const y: c_int = origin_y + @as(c_int, @intCast(i));
            if (c.ncplane_putstr_yx(stdplane, y, origin_x, line.ptr) < 0) {
                return error.PutStrFailed;
            }
        }

        c.ncplane_set_styles(stdplane, c.NCSTYLE_NONE);
        if (c.ncplane_set_fg_rgb8(stdplane, 0xff, 0xd8, 0x66) < 0) return error.SetColorFailed;
        try putCentered(stdplane, origin_y + @as(c_int, @intCast(logo.len)) + 1, cols, title);

        if (c.ncplane_set_fg_rgb8(stdplane, 0x88, 0x88, 0x88) < 0) return error.SetColorFailed;
        try putCentered(stdplane, origin_y + @as(c_int, @intCast(logo.len)) + 3, cols, hint);

        self.initial_render_done = true;
    }

    if (self.gif) |*gif| try gif.render(nc_ctx);
}

pub fn update(self: *Self, ft: FrameTime) !Conclusion {
    if (self.gif) |*gif| {
        return try gif.update(ft);
    }
    return .Noop;
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

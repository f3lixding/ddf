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
const DiffWindow = @import("DiffWindow.zig");
const Bucket = util.LeakyBucket(InputEvent);
const RenderCtx = protocol.RenderCtx;
const ASSET_PATH = consts.ASSET_PATH;
const logging = std.log.scoped(.splash);

const cat_gif = @embedFile("../assets/scuba-scuba-cat.gif");

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

const Gif = struct {
    visual: *c.ncvisual,
    plane: *c.ncplane,
    vopts: c.ncvisual_options,
    hidden: bool = false,

    frame_interval_ms: i64 = 1000 / 24,
    elapsed_ms: i64 = 0,
    dirty: bool = true,

    pub const Opts = struct {
        y: c_int = 0,
        x: c_int = 0,
        height: c_uint,
        width: ?c_uint = null,
    };

    pub fn init(nc_ctx: *c.notcurses, parent_plane: *c.ncplane, opts: Opts) !Gif {
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
        popts.y = opts.y;
        popts.x = opts.x;
        popts.rows = opts.height;
        popts.cols = if (opts.width) |width| width else blk: {
            var geom = std.mem.zeroes(c.ncvgeom);

            if (c.ncvisual_geom(null, visual, null, &geom) < 0) {
                return error.VisualGeomFailed;
            }

            const gif_height = geom.pixy;
            const gif_width = geom.pixx;

            break :blk (opts.height * gif_width + gif_height - 1) / gif_height;
        };
        popts.name = "gif";

        const plane = c.ncplane_create(parent_plane, &popts) orelse return error.CreatePlaneFailed;

        var vopts = std.mem.zeroes(c.ncvisual_options);
        vopts.n = plane;
        vopts.y = 0;
        vopts.x = 0;

        if (shouldTryPixelBlit(nc_ctx)) {
            configurePixelBlit(&vopts);
        } else {
            configureFallbackBlit(&vopts);
        }

        return .{
            .visual = visual,
            .plane = plane,
            .vopts = vopts,
        };
    }

    pub fn move(self: *Gif, y: c_int, x: c_int) !void {
        if (c.ncplane_move_yx(self.plane, y, x) < 0) {
            return error.MovePlaneFailed;
        }
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
        if (self.hidden) return;
        if (!self.dirty) return;

        c.ncplane_erase(self.plane);

        if (c.ncvisual_blit(nc_ctx, self.visual, &self.vopts) == null) {
            // Pixel support detection can be wrong in practice. If the strict
            // pixel blit fails, fall back to a Unicode-cell blitter and retry.
            if (self.vopts.blitter == c.NCBLIT_PIXEL) {
                configureFallbackBlit(&self.vopts);
                c.ncplane_erase(self.plane);
                if (c.ncvisual_blit(nc_ctx, self.visual, &self.vopts) == null) {
                    return error.BlitGifFailed;
                }
            } else {
                return error.BlitGifFailed;
            }
        }

        self.dirty = false;
    }

    pub fn hide(self: *Gif) void {
        c.ncplane_erase(self.plane);
        self.hidden = true;
        self.dirty = false;
    }

    pub fn unhide(self: *Gif) void {
        self.hidden = false;
        self.dirty = true;
    }

    fn shouldTryPixelBlit(nc_ctx: *c.notcurses) bool {
        if (std.c.getenv("TMUX") != null) return false;
        if (!c.notcurses_canopen_images(nc_ctx)) return false;
        return c.notcurses_canpixel(nc_ctx);
    }

    fn configurePixelBlit(vopts: *c.ncvisual_options) void {
        vopts.scaling = c.NCSCALE_SCALE_HIRES;
        vopts.blitter = c.NCBLIT_PIXEL;
        // Fail instead of silently degrading, so render() can choose our
        // explicit fallback path.
        vopts.flags |= c.NCVISUAL_OPTION_NODEGRADE;
    }

    fn configureFallbackBlit(vopts: *c.ncvisual_options) void {
        vopts.scaling = c.NCSCALE_SCALE;
        vopts.blitter = c.NCBLIT_4x2;
        vopts.flags &= ~@as(u64, c.NCVISUAL_OPTION_NODEGRADE);
    }

    pub fn updateInterval(self: *Gif) ?i64 {
        _ = self;
        return 1000 / 24;
    }
};

pub fn init(alloc: std.mem.Allocator, io: std.Io, nc_ctx: *c.notcurses) !Self {
    const input_bucket = Bucket.init(.{});
    const stdplane = c.notcurses_stdplane(nc_ctx) orelse return error.NoStdplane;
    const gif = try Gif.init(nc_ctx, stdplane, .{ .height = 20 });

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

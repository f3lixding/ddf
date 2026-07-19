const std = @import("std");

const util = @import("../util.zig");
const c = util.c;
const consts = @import("../consts.zig");
const FrameTime = @import("../protocol.zig").FrameTime;
const Conclusion = @import("../protocol.zig").Conclusion;

const assets = @import("../assets/assets.zig");
const ASSET_PATH = consts.ASSET_PATH;

const Self = @This();

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
    asset_name: [*c]const u8,
};

pub fn init(nc_ctx: *c.notcurses, parent_plane: *c.ncplane, opts: Opts) !Self {
    // TODO: move more of this into util
    var path_buf: [256]u8 = undefined;
    var full_path_buf: [256]u8 = undefined;

    const subpath = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ ASSET_PATH, opts.asset_name });
    const full_asset_path = try util.getDirRelativeToHomeSentinel(&full_path_buf, subpath);
    std.log.info("full asset path: {s}", .{full_asset_path});

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

        const asset_bytes = if (std.mem.eql(u8, std.mem.span(opts.asset_name), "bongo-cat.gif"))
            assets.line_indicator
        else
            assets.splash_screen;
        try file.writeStreamingAll(io, asset_bytes);
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
    popts.name = opts.asset_name;

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

pub fn deinit(self: *Self) void {
    _ = c.ncplane_destroy(self.plane);
    c.ncvisual_destroy(self.visual);
}

pub fn move(self: *Self, y: c_int, x: c_int) !void {
    if (c.ncplane_move_yx(self.plane, y, x) < 0) {
        return error.MovePlaneFailed;
    }
}

pub fn update(self: *Self, frame_time: FrameTime) !Conclusion {
    self.elapsed_ms += frame_time.elapsed_ms;

    while (self.elapsed_ms >= self.frame_interval_ms) {
        self.elapsed_ms -= self.frame_interval_ms;

        const rc = c.ncvisual_decode_loop(self.visual);
        if (rc < 0) return error.DecodeGifFailed;

        self.dirty = true;
    }

    return .Noop;
}

pub fn render(self: *Self, nc_ctx: *c.notcurses) !void {
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

pub fn hide(self: *Self) void {
    c.ncplane_erase(self.plane);
    self.hidden = true;
    self.dirty = false;
}

pub fn unhide(self: *Self) void {
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

pub fn updateInterval(self: *Self) ?i64 {
    _ = self;
    return 1000 / 24;
}

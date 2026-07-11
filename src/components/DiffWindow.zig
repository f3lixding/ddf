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
const Diff = @import("diff.zig").Diff;

const Self = @This();

const DIFF_COMMAND: []const u8 = "jj diff --tool=:git --color never";
const DIFF_ARGV: []const []const u8 = &.{ "jj", "diff", "--tool=:git", "--color", "never" };

alloc: std.mem.Allocator,
output: []u8,
stderr: []u8,
diff: ?Diff = null,
plane: ?*c.ncplane = null,
dirty: bool = true,

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
                    return self_typed.dirty;
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

            .clean_up = struct {
                pub fn cleanUp(ptr: *anyopaque) !void {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    deinit(self_typed);
                }
            }.cleanUp,
        },
    };
}

pub fn init(alloc: std.mem.Allocator, io: std.Io) !Self {
    const run_result = try std.process.run(alloc, io, .{
        .argv = DIFF_ARGV,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    errdefer alloc.free(run_result.stdout);
    errdefer alloc.free(run_result.stderr);

    if (run_result.term != .exited or run_result.term.exited != 0) {
        return error.DiffCommandFailed;
    }

    const maybe_diff: ?Diff = if (run_result.stdout.len == 0)
        null
    else
        try Diff.init(alloc, run_result.stdout, 80);

    return .{
        .alloc = alloc,
        .output = run_result.stdout,
        .stderr = run_result.stderr,
        .diff = maybe_diff,
    };
}

pub fn deinit(self: *Self) void {
    if (self.plane) |plane| {
        _ = c.ncplane_destroy(plane);
        self.plane = null;
    }

    if (self.diff) |*diff| {
        diff.deinit(self.alloc);
        self.diff = null;
    }

    self.alloc.free(self.output);
    self.alloc.free(self.stderr);
}

pub fn handleInputEvent(self: *Self, input_event: InputEvent) !Conclusion {
    switch (input_event.key) {
        'q', c.NCKEY_ESC => return .Dismount,
        'j', c.NCKEY_DOWN => {
            if (self.diff) |*diff| {
                if (diff.top_line + 1 < diff.display_lines.items.len) {
                    diff.top_line += 1;
                    self.dirty = true;
                }
            }
        },
        'k', c.NCKEY_UP => {
            if (self.diff) |*diff| {
                if (diff.top_line > 0) {
                    diff.top_line -= 1;
                    self.dirty = true;
                }
            }
        },
        c.NCKEY_RESIZE => self.dirty = true,
        else => {},
    }

    return .Noop;
}

pub fn render(self: *Self, render_ctx: *const RenderCtx) !void {
    const plane = try self.ensurePlane(render_ctx);

    if (self.diff) |*diff| {
        const width = @max(@as(c_uint, 1), render_ctx.term_cols);
        try diff.update(width);
        try diff.render(render_ctx.nc_ctx, plane);
    } else {
        c.ncplane_erase(plane);
        const msg = "No diff to display";
        if (c.ncplane_putnstr_yx(plane, 0, 0, msg.len, msg.ptr) < 0) {
            return error.PutStrFailed;
        }
    }

    self.dirty = false;
}

pub fn update(self: *Self, ft: FrameTime) !Conclusion {
    _ = self;
    _ = ft;
    return .Noop;
}

fn ensurePlane(self: *Self, render_ctx: *const RenderCtx) !*c.ncplane {
    const rows = @max(@as(c_uint, 1), render_ctx.term_rows);
    const cols = @max(@as(c_uint, 1), render_ctx.term_cols);

    if (self.plane) |plane| {
        if (c.ncplane_resize_simple(plane, rows, cols) < 0) {
            return error.ResizePlaneFailed;
        }
        if (c.ncplane_move_yx(plane, 0, 0) < 0) {
            return error.MovePlaneFailed;
        }
        return plane;
    }

    const stdplane = c.notcurses_stdplane(render_ctx.nc_ctx) orelse return error.NoStdplane;
    var opts = std.mem.zeroes(c.ncplane_options);
    opts.y = 0;
    opts.x = 0;
    opts.rows = rows;
    opts.cols = cols;
    opts.name = "diff-window";

    const plane = c.ncplane_create(stdplane, &opts) orelse return error.CreatePlaneFailed;
    self.plane = plane;
    return plane;
}

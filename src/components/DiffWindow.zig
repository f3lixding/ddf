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
const LineIndicator = @import("LineIndicator.zig");

const Self = @This();

const DIFF_COMMAND: []const u8 = "jj diff --tool=:git --color never";
const DIFF_ARGV: []const []const u8 = &.{ "jj", "diff", "--tool=:git", "--color", "never" };

alloc: std.mem.Allocator,
output: []u8,
stderr: []u8,
diff: ?Diff = null,
main_plane: ?*c.ncplane = null,
sub_plane: ?*c.ncplane = null,
indicator_plane: ?*c.ncplane = null,
line_indicator: ?LineIndicator = null,
focus_line: usize = 0,
viewport_rows: usize = 1,
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
                    if (self_typed.dirty) return true;
                    if (self_typed.line_indicator) |indicator| return indicator.isDirty();
                    return false;
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
                    _ = ptr;
                    return 1000 / 24;
                }
            }.updateInterval,

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
    if (self.line_indicator) |*indicator| {
        indicator.deinit();
        self.line_indicator = null;
    }
    if (self.indicator_plane) |plane| {
        _ = c.ncplane_destroy(plane);
        self.indicator_plane = null;
    }
    if (self.sub_plane) |plane| {
        _ = c.ncplane_destroy(plane);
        self.sub_plane = null;
    }
    if (self.main_plane) |plane| {
        _ = c.ncplane_destroy(plane);
        self.main_plane = null;
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
                if (self.moveFocusDown(diff)) {
                    self.dirty = true;
                }
            }
        },
        'k', c.NCKEY_UP => {
            if (self.diff) |*diff| {
                if (self.moveFocusUp(diff)) {
                    self.dirty = true;
                }
            }
        },
        'u', 'U' => {
            if (self.diff) |*diff| {
                if ((input_event.ncinput.modifiers & c.NCKEY_MOD_CTRL) != 0) {
                    if (self.moveFocusPageUp(diff)) {
                        self.dirty = true;
                    }
                }
            }
        },
        'd', 'D' => {
            if (self.diff) |*diff| {
                if ((input_event.ncinput.modifiers & c.NCKEY_MOD_CTRL) != 0) {
                    if (self.moveFocusPageDown(diff)) {
                        self.dirty = true;
                    }
                }
            }
        },
        c.NCKEY_RESIZE => self.dirty = true,
        else => {},
    }

    return .Noop;
}

pub fn render(self: *Self, render_ctx: *const RenderCtx) !void {
    const planes = try self.ensurePlane(render_ctx);
    const main_plane = planes.main_plane;
    const sub_plane = planes.sub_plane;
    const indicator_plane = planes.line_indicator_plane;

    try drawBorder(main_plane);

    // TODO: because we have multiple planes now we would need to understand which plane is dirty
    if (self.diff) |*diff| {
        var rows: c_uint = 0;
        var cols: c_uint = 0;
        c.ncplane_dim_yx(sub_plane, &rows, &cols);
        self.viewport_rows = @max(@as(usize, 1), rows);
        try diff.update(cols);
        try diff.render(render_ctx.nc_ctx, sub_plane);
    } else {
        c.ncplane_erase(sub_plane);
        const msg = "No diff to display";
        if (c.ncplane_putnstr_yx(sub_plane, 0, 0, msg.len, msg.ptr) < 0) {
            return error.PutStrFailed;
        }
    }

    if (self.line_indicator) |*indicator| {
        try indicator.render(render_ctx.nc_ctx);
    } else {
        c.ncplane_erase(indicator_plane);
    }

    self.dirty = false;
}

pub fn update(self: *Self, ft: FrameTime) !Conclusion {
    if (self.line_indicator) |*indicator| {
        return try indicator.update(ft);
    }

    return .Noop;
}

fn moveFocusDown(self: *Self, diff: *Diff) bool {
    if (self.focus_line + 1 >= diff.display_lines.items.len) return false;

    const margin = @min(@as(usize, 5), self.viewport_rows -| 1);
    const viewport_row = self.focus_line -| diff.top_line;
    const bottom_margin_row = self.viewport_rows -| 1 -| margin;

    self.focus_line += 1;
    if (viewport_row >= bottom_margin_row and diff.top_line + self.viewport_rows < diff.display_lines.items.len) {
        diff.top_line += 1;
    }

    return true;
}

fn moveFocusUp(self: *Self, diff: *Diff) bool {
    if (self.focus_line == 0) return false;

    const margin = @min(@as(usize, 5), self.viewport_rows -| 1);
    const viewport_row = self.focus_line -| diff.top_line;

    self.focus_line -= 1;
    if (viewport_row <= margin and diff.top_line > 0) {
        diff.top_line -= 1;
    }

    return true;
}

fn moveFocusPageUp(self: *Self, diff: *Diff) bool {
    if (self.focus_line == 0) return false;

    const viewport_row = self.focus_line -| diff.top_line;
    self.focus_line -|= pageScrollAmount(self);
    keepFocusAtViewportRow(self, diff, viewport_row);
    return true;
}

fn moveFocusPageDown(self: *Self, diff: *Diff) bool {
    if (self.focus_line + 1 >= diff.display_lines.items.len) return false;

    const viewport_row = self.focus_line -| diff.top_line;
    self.focus_line = @min(self.focus_line + pageScrollAmount(self), diff.display_lines.items.len - 1);
    keepFocusAtViewportRow(self, diff, viewport_row);
    return true;
}

fn pageScrollAmount(self: *const Self) usize {
    return @max(@as(usize, 1), self.viewport_rows -| 2);
}

fn keepFocusAtViewportRow(self: *Self, diff: *Diff, viewport_row: usize) void {
    const max_top = diff.display_lines.items.len -| self.viewport_rows;
    diff.top_line = @min(self.focus_line -| viewport_row, max_top);
}

fn ensurePlane(self: *Self, render_ctx: *const RenderCtx) !struct {
    main_plane: *c.ncplane,
    sub_plane: *c.ncplane,
    line_indicator_plane: *c.ncplane,
} {
    const rows = @max(@as(c_uint, 1), render_ctx.term_rows);
    const cols = @max(@as(c_uint, 1), render_ctx.term_cols);

    if (self.main_plane) |plane| {
        if (c.ncplane_resize_simple(plane, rows, cols) < 0) {
            return error.ResizePlaneFailed;
        }
        if (c.ncplane_move_yx(plane, 0, 0) < 0) {
            return error.MovePlaneFailed;
        }
    } else {
        const stdplane = c.notcurses_stdplane(render_ctx.nc_ctx) orelse return error.NoStdplane;
        var opts = std.mem.zeroes(c.ncplane_options);
        opts.y = 0;
        opts.x = 0;
        opts.rows = rows;
        opts.cols = cols;
        opts.name = "diff_window_main_plane";

        const plane = c.ncplane_create(stdplane, &opts) orelse return error.CreatePlaneFailed;
        self.main_plane = plane;
    }

    if (self.sub_plane) |plane| {
        const rows_ = if (rows >= 2) rows - 2 else rows;
        const cols_ = if (cols >= 4) cols - 4 else cols;
        if (c.ncplane_resize_simple(plane, rows_, cols_) < 0) {
            return error.ResizePlaneFailed;
        }
        if (c.ncplane_move_yx(plane, 1, 3) < 0) {
            return error.MovePlaneFailed;
        }
    } else {
        const main_plane = self.main_plane.?;
        var opts = std.mem.zeroes(c.ncplane_options);
        opts.y = 1;
        opts.x = 3;
        opts.rows = if (rows >= 2) rows - 2 else rows;
        opts.cols = if (cols >= 4) cols - 4 else cols;
        opts.name = "diff_window_sub_plane";

        const plane = c.ncplane_create(main_plane, &opts) orelse return error.CreatePlaneFailed;
        self.sub_plane = plane;
    }

    const indicator_y: c_int = @intCast((self.focus_line -| if (self.diff) |diff| diff.top_line else 0) + 1);
    if (self.indicator_plane) |plane| {
        const main_plane = self.main_plane.?;
        const main_cols = c.ncplane_dim_x(main_plane);
        if (c.ncplane_resize_simple(plane, 1, @max(@as(c_uint, 1), main_cols -| 2)) < 0) {
            return error.ResizePlaneFailed;
        }
        if (c.ncplane_move_yx(plane, indicator_y, 1) < 0) {
            return error.MovePlaneFailed;
        }
    } else {
        const main_plane = self.main_plane.?;
        const main_cols = c.ncplane_dim_x(main_plane);

        var opts = std.mem.zeroes(c.ncplane_options);
        opts.y = indicator_y;
        opts.x = 1;
        opts.rows = 1;
        opts.cols = @max(@as(c_uint, 1), main_cols -| 2);
        opts.name = "line_indicator_plane";

        const plane = c.ncplane_create(main_plane, &opts) orelse return error.CreatePlaneFailed;
        self.indicator_plane = plane;
    }

    if (self.line_indicator == null) {
        self.line_indicator = try LineIndicator.init(render_ctx.nc_ctx, self.indicator_plane.?, .{
            .y = 0,
            .x = 0,
            .height = 1,
        });
    } else if (self.line_indicator) |*indicator| {
        try indicator.gif.move(0, 0);
    }

    return .{
        .sub_plane = self.sub_plane.?,
        .main_plane = self.main_plane.?,
        .line_indicator_plane = self.indicator_plane.?,
    };
}

fn drawBorder(plane: *c.ncplane) !void {
    c.ncplane_erase(plane);

    var rows: c_uint = 0;
    var cols: c_uint = 0;
    c.ncplane_dim_yx(plane, &rows, &cols);
    if (rows < 2 or cols < 2) return;

    const last_y: c_int = @intCast(rows - 1);
    const last_x: c_int = @intCast(cols - 1);

    c.ncplane_set_styles(plane, c.NCSTYLE_BOLD);
    if (c.ncplane_set_fg_rgb8(plane, 0x83, 0xa5, 0x98) < 0) {
        return error.DrawBorderFailed;
    }
    defer {
        c.ncplane_set_styles(plane, c.NCSTYLE_NONE);
        c.ncplane_set_fg_default(plane);
    }

    try putBorderSegment(plane, 0, 0, "┏");
    try putBorderSegment(plane, 0, last_x, "┓");
    try putBorderSegment(plane, last_y, 0, "┗");
    try putBorderSegment(plane, last_y, last_x, "┛");

    var x: c_int = 1;
    while (x < last_x) : (x += 1) {
        try putBorderSegment(plane, 0, x, "━");
        try putBorderSegment(plane, last_y, x, "━");
    }

    var y: c_int = 1;
    while (y < last_y) : (y += 1) {
        try putBorderSegment(plane, y, 0, "┃");
        try putBorderSegment(plane, y, last_x, "┃");
    }
}

fn putBorderSegment(plane: *c.ncplane, y: c_int, x: c_int, text: []const u8) !void {
    if (c.ncplane_putnstr_yx(plane, y, x, text.len, text.ptr) < 0) {
        return error.DrawBorderFailed;
    }
}

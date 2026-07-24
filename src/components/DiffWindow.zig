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
const diff_ = @import("diff.zig");
const Diff = diff_.Diff;
const LineIndicator = @import("LineIndicator.zig");
const Comments = @import("Comments.zig");

const Self = @This();

const DIFF_ARGV: []const []const u8 = &.{ "jj", "diff", "--tool=:git", "--color", "never" };

alloc: std.mem.Allocator,
output: []u8,
stderr: []u8,

main_plane: ?*c.ncplane = null,
sub_plane: ?*c.ncplane = null,
indicator_plane: ?*c.ncplane = null,

diff: ?Diff = null,
line_indicator: ?LineIndicator = null,
comments: ?Comments = null,

top_line: usize = 0,
focus_line: usize = 0,
viewport_rows: usize = 1,
viewport_cols: c_uint = 0,
pending_resize: bool = false,
dirty: bool = true,

display_lines: std.ArrayList(DisplayLine) = .empty,

/// This is analogous to the DisplayLine to the subcomponents to this component
/// (i.e. Diff and Comments). They are references to their respective
/// DisplayLine. This is a way to delegate the rendering to these subcomponents
/// while maintaining control over what gets spliced in between them
const DisplayLine = union(enum) {
    diff: struct {
        line: *diff_.DisplayLine,
        comment_idx: ?usize = 0,
        comment_hidden: bool = false,
    },
    comments: struct {
        line: *Comments.DisplayLine,
        comment: *Comments.Comment,
    },

    pub fn isTargetable(self: DisplayLine) bool {
        return switch (self) {
            // TODO: Add logic here so we don't select over file metadata
            .diff => true,
            .comments => |*comment| comment.line.targetable,
        };
    }
};

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
                    // We will only handle key down
                    if (event.key == 0 or event.ncinput.evtype == c.NCTYPE_RELEASE)
                        return .Noop;

                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    return try @call(.always_inline, handleInputEvent, .{ self_typed, event });
                }
            }.handleInput,

            .update = struct {
                pub fn _update(ptr: *anyopaque, ft: FrameTime, render_ctx: *const RenderCtx) !Conclusion {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    return try @call(.always_inline, update, .{ self_typed, ft, render_ctx });
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
                    const alloc = self_typed.alloc;
                    deinit(self_typed);
                    alloc.destroy(self_typed);
                }
            }.cleanUp,
        },
    };
}

pub fn init(alloc: std.mem.Allocator, io: std.Io) !Self {
    const log = std.log.scoped(.diff_window);
    const init_start_ns = nowNs();
    const command_start_ns = nowNs();
    const run_result = try std.process.run(alloc, io, .{
        .argv = DIFF_ARGV,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    const command_ns = nowNs() - command_start_ns;
    log.info("diff command completed: stdout_bytes={d} stderr_bytes={d} elapsed_ms={d:.3}", .{
        run_result.stdout.len,
        run_result.stderr.len,
        nsToMs(command_ns),
    });
    errdefer alloc.free(run_result.stdout);
    errdefer alloc.free(run_result.stderr);

    if (run_result.term != .exited or run_result.term.exited != 0) {
        return error.DiffCommandFailed;
    }

    var self: Self = .{
        .alloc = alloc,
        .output = run_result.stdout,
        .stderr = run_result.stderr,
    };

    const parse_start_ns = nowNs();
    self.diff = if (run_result.stdout.len == 0)
        null
    else blk: {
        const diff = try Diff.init(alloc, io, run_result.stdout, 80);

        var dw_display_lines: std.ArrayList(DisplayLine) = .empty;
        errdefer dw_display_lines.deinit(alloc);

        for (diff.display_lines.items) |*diff_display_lines| {
            try dw_display_lines.append(alloc, .{ .diff = .{
                .line = diff_display_lines,
            } });
        }

        self.display_lines = dw_display_lines;

        break :blk diff;
    };
    const parse_ns = nowNs() - parse_start_ns;

    log.info("DiffWindow.init profile: total_ms={d:.3} command_ms={d:.3} diff_init_ms={d:.3}", .{
        nsToMs(nowNs() - init_start_ns),
        nsToMs(command_ns),
        nsToMs(parse_ns),
    });

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.line_indicator) |*indicator| {
        indicator.deinit();
        self.line_indicator = null;
    }
    if (self.diff) |*diff| {
        diff.deinit(self.alloc);
        self.diff = null;
    }
    if (self.comments) |*comments| {
        comments.deinit(self.alloc);
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

    self.display_lines.deinit(self.alloc);
    self.alloc.free(self.output);
    self.alloc.free(self.stderr);
}

pub fn handleInputEvent(self: *Self, input_event: InputEvent) !Conclusion {
    switch (input_event.key) {
        'q', c.NCKEY_ESC => return .Dismount,
        'j', c.NCKEY_DOWN => {
            if (self.diff != null) {
                if (self.moveFocusDown()) {
                    self.dirty = true;
                }
            }
        },
        'k', c.NCKEY_UP => {
            if (self.diff != null) {
                if (self.moveFocusUp()) {
                    self.dirty = true;
                }
            }
        },
        'u', 'U' => {
            if (self.diff != null) {
                if ((input_event.ncinput.modifiers & c.NCKEY_MOD_CTRL) != 0) {
                    if (self.moveFocusPageUp()) {
                        self.dirty = true;
                    }
                }
            }
        },
        'd', 'D' => {
            if (self.diff != null) {
                if ((input_event.ncinput.modifiers & c.NCKEY_MOD_CTRL) != 0) {
                    if (self.moveFocusPageDown()) {
                        self.dirty = true;
                    }
                }
            }
        },
        c.NCKEY_RESIZE => {
            self.pending_resize = true;
            self.dirty = true;
        },
        else => {},
    }

    return .Noop;
}

pub fn render(self: *Self, render_ctx: *const RenderCtx) !void {
    const log = std.log.scoped(.diff_window);
    const render_start_ns = nowNs();

    const ensure_start_ns = nowNs();
    const planes = try self.ensurePlane(render_ctx);
    const ensure_ns = nowNs() - ensure_start_ns;

    const main_plane = planes.main_plane;
    const sub_plane = planes.sub_plane;
    const indicator_plane = planes.line_indicator_plane;

    const border_start_ns = nowNs();
    const active_file_name = if (self.diff) |*diff|
        diff.fileNameForDisplayLine(self.focus_line)
    else
        null;
    try drawBorder(main_plane, active_file_name);
    const border_ns = nowNs() - border_start_ns;

    var diff_render_ns: i128 = 0;
    var indicator_render_ns: i128 = 0;

    if (self.diff) |*diff| {
        _ = diff;

        const diff_render_start_ns = nowNs();
        c.ncplane_erase(sub_plane);

        const start = @min(self.top_line, self.display_lines.items.len);
        const visible_count = @min(self.viewport_rows, self.display_lines.items.len - start);

        for (self.display_lines.items[start .. start + visible_count], 0..) |*line, viewport_row| {
            switch (line.*) {
                .diff => |*diff_line| {
                    try diff_line.line.render(render_ctx.nc_ctx, sub_plane, @intCast(viewport_row));
                },
                else => {},
            }
        }

        diff_render_ns = nowNs() - diff_render_start_ns;
    } else {
        c.ncplane_erase(sub_plane);
        const msg = "No diff to display";
        if (c.ncplane_putnstr_yx(sub_plane, 0, 0, msg.len, msg.ptr) < 0) {
            return error.PutStrFailed;
        }
    }

    const indicator_render_start_ns = nowNs();
    if (self.line_indicator) |*indicator| {
        try indicator.render(render_ctx.nc_ctx);
    } else {
        c.ncplane_erase(indicator_plane);
    }
    indicator_render_ns = nowNs() - indicator_render_start_ns;

    self.dirty = false;

    log.debug("DiffWindow.render profile: total_ms={d:.3} ensure_ms={d:.3} border_ms={d:.3} diff_update_ms={d:.3} diff_render_ms={d:.3} indicator_ms={d:.3}", .{
        nsToMs(nowNs() - render_start_ns),
        nsToMs(ensure_ns),
        nsToMs(border_ns),
        0,
        nsToMs(diff_render_ns),
        nsToMs(indicator_render_ns),
    });
}

pub fn update(self: *Self, ft: FrameTime, render_ctx: *const RenderCtx) !Conclusion {
    if (self.pending_resize) {
        _ = try self.ensurePlane(render_ctx);
        self.pending_resize = false;

        if (self.diff) |*diff| {
            if (try diff.updateWidth(self.viewport_cols)) {
                self.display_lines.clearAndFree(self.alloc);

                // TODO: splice the comments line here
                for (diff.display_lines.items) |*line| {
                    try self.display_lines.append(self.alloc, .{ .diff = .{
                        .line = line,
                    } });
                }

                self.dirty = true;
            }
        }
    } else if (self.diff) |*diff| {
        if (try diff.updateHighlights()) {
            self.display_lines.clearAndFree(self.alloc);

            // TODO: splice the comments line here
            for (diff.display_lines.items) |*line| {
                try self.display_lines.append(self.alloc, .{ .diff = .{
                    .line = line,
                } });
            }

            self.dirty = true;
        }
    }

    if (self.line_indicator) |*indicator| {
        return try indicator.update(ft);
    }

    return .Noop;
}

fn nowNs() i128 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (@as(i128, ts.tv_sec) * std.time.ns_per_s) + @as(i128, ts.tv_nsec);
}

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

fn moveFocusDown(self: *Self) bool {
    if (self.focus_line + 1 >= self.display_lines.items.len) return false;

    const margin = @min(@as(usize, 5), self.viewport_rows -| 1);
    const viewport_row = self.focus_line -| self.top_line;
    const bottom_margin_row = self.viewport_rows -| 1 -| margin;

    self.focus_line += 1;
    if (viewport_row >= bottom_margin_row and self.top_line + self.viewport_rows < self.display_lines.items.len) {
        self.top_line += 1;
    }

    return true;
}

fn moveFocusUp(self: *Self) bool {
    if (self.focus_line == 0) return false;

    const margin = @min(@as(usize, 5), self.viewport_rows -| 1);
    const viewport_row = self.focus_line -| self.top_line;

    self.focus_line -= 1;
    if (viewport_row <= margin and self.top_line > 0) {
        self.top_line -= 1;
    }

    return true;
}

fn moveFocusPageUp(self: *Self) bool {
    if (self.focus_line == 0) return false;

    const viewport_row = self.focus_line -| self.top_line;
    self.focus_line -|= pageScrollAmount(self);
    self.keepFocusAtViewportRow(viewport_row);
    return true;
}

fn moveFocusPageDown(self: *Self) bool {
    if (self.focus_line + 1 >= self.display_lines.items.len) return false;

    const viewport_row = self.focus_line -| self.top_line;
    self.focus_line = @min(self.focus_line + pageScrollAmount(self), self.display_lines.items.len - 1);
    self.keepFocusAtViewportRow(viewport_row);
    return true;
}

fn pageScrollAmount(self: *const Self) usize {
    return @max(@as(usize, 1), self.viewport_rows -| 2);
}

fn keepFocusAtViewportRow(self: *Self, viewport_row: usize) void {
    const max_top = self.display_lines.items.len -| self.viewport_rows;
    self.top_line = @min(self.focus_line -| viewport_row, max_top);
}

// If you want to make the base cell of a plane transparent:
// fn makePlaneTransparent(plane: *c.ncplane) !void {
//     var cell = std.mem.zeroes(c.nccell);
//
//     if (c.nccell_set_fg_alpha(&cell, c.NCALPHA_TRANSPARENT) < 0)
//         return error.SetAlphaFailed;
//     if (c.nccell_set_bg_alpha(&cell, c.NCALPHA_TRANSPARENT) < 0)
//         return error.SetAlphaFailed;
//
//     if (c.ncplane_set_base_cell(plane, &cell) < 0)
//         return error.SetBaseCellFailed;
//
//     c.ncplane_erase(plane);
// }
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

    const sub_rows = if (rows >= 2) rows - 2 else rows;
    const sub_cols = if (cols >= 4) cols - 4 else cols;
    if (self.sub_plane) |plane| {
        if (c.ncplane_resize_simple(plane, sub_rows, sub_cols) < 0) {
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
        opts.rows = sub_rows;
        opts.cols = sub_cols;
        opts.name = "diff_window_sub_plane";

        const plane = c.ncplane_create(main_plane, &opts) orelse return error.CreatePlaneFailed;
        self.sub_plane = plane;
    }
    self.viewport_rows = @max(@as(usize, 1), @as(usize, @intCast(sub_rows)));
    self.viewport_cols = sub_cols;

    const indicator_y: c_int = @intCast((self.focus_line -| if (self.diff != null) self.top_line else 0) + 1);
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
            .height = 2,
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

fn drawBorder(plane: *c.ncplane, active_file_name: ?[]const u8) !void {
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

    if (active_file_name) |file_name| {
        try drawBorderTitle(plane, cols, file_name);
    }

    var y: c_int = 1;
    while (y < last_y) : (y += 1) {
        try putBorderSegment(plane, y, 0, "┃");
        try putBorderSegment(plane, y, last_x, "┃");
    }
}

fn drawBorderTitle(plane: *c.ncplane, cols: c_uint, file_name: []const u8) !void {
    if (cols <= 6 or file_name.len == 0) return;

    const max_name_len: usize = @intCast(cols - 6);
    const visible_name = if (file_name.len > max_name_len)
        file_name[file_name.len - max_name_len ..]
    else
        file_name;

    var x: c_int = 2;
    try putBorderSegment(plane, 0, x, " ");
    x += 1;
    try putBorderSegment(plane, 0, x, visible_name);
    x += @intCast(visible_name.len);
    try putBorderSegment(plane, 0, x, " ");
}

fn putBorderSegment(plane: *c.ncplane, y: c_int, x: c_int, text: []const u8) !void {
    if (c.ncplane_putnstr_yx(plane, y, x, text.len, text.ptr) < 0) {
        return error.DrawBorderFailed;
    }
}

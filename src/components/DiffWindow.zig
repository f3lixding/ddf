const std = @import("std");

const util = @import("../util/root.zig");
const consts = @import("../consts.zig");
const c = util.c;
const protocol = @import("../protocol.zig");
const LineId = protocol.LineId;
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
const Cursor = @import("Cursor.zig");

const Self = @This();
const DisplayLineStorage = util.FenwickTreeStorage(DisplayLine);

const DIFF_ARGV: []const []const u8 = &.{ "jj", "diff", "--tool=:git", "--color", "never" };

const State = union(enum) {
    normal,
    editing: struct {
        first_display_line: usize,
        comment: *Comments.Comment,
    },
    select: struct { usize, usize },
};

state: State = .normal,

alloc: std.mem.Allocator,
output: []u8,
stderr: []u8,

main_plane: ?*c.ncplane = null,
sub_plane: ?*c.ncplane = null,
indicator_plane: ?*c.ncplane = null,

diff: ?Diff = null,
line_indicator: ?LineIndicator = null,
comments: ?Comments = null,
cursor: ?Cursor = null,

top_line: usize = 0,
focus_line: usize = 0,
viewport_rows: usize = 1,
viewport_cols: c_uint = 0,
pending_resize: bool = false,
dirty: bool = true,

display_lines: DisplayLineStorage,

/// This is analogous to the DisplayLine to the subcomponents to this component
/// (i.e. Diff and Comments). They are references to their respective
/// DisplayLine. This is a way to delegate the rendering to these subcomponents
/// while maintaining control over what gets spliced in between them
const DisplayLine = union(enum) {
    diff: struct {
        line: *diff_.DisplayLine,
        stable_idx: usize = 0,
        comment_idx: ?usize = null,
        comment_hidden: bool = false,
    },
    comments: struct {
        line_idx: usize,
        comment: *Comments.Comment,
    },

    pub fn isTargetable(self: DisplayLine) bool {
        return switch (self) {
            // TODO: Add logic here so we don't select over file metadata
            .diff => true,
            .comments => |*comment| comment.comment.display_lines.items[comment.line_idx].targetable,
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
                    if (self_typed.line_indicator) |*indicator| return indicator.isDirty();
                    if (self_typed.cursor) |*cursor| return cursor.isDirty();
                    return false;
                }
            }.isDirty,

            .key_handler = struct {
                pub fn handleInput(ptr: *anyopaque, event: InputEvent, render_ctx: *const RenderCtx) !Conclusion {
                    _ = render_ctx;
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

pub fn init(alloc: std.mem.Allocator, io: std.Io, render_ctx: *const RenderCtx) !Self {
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
        .display_lines = .{ .alloc = alloc },
        .output = run_result.stdout,
        .stderr = run_result.stderr,
    };

    const parse_start_ns = nowNs();
    const planes = try self.ensurePlane(render_ctx);
    const sub_plane = planes.sub_plane;
    self.diff = if (run_result.stdout.len == 0)
        null
    else blk: {
        const sub_plane_width = c.ncplane_dim_x(sub_plane);
        const diff = try Diff.init(alloc, io, run_result.stdout, sub_plane_width);

        for (diff.display_lines.items, 0..) |*diff_display_lines, original_idx| {
            try self.display_lines.append(.{ .diff = .{
                .line = diff_display_lines,
                .stable_idx = original_idx,
            } });
        }

        break :blk diff;
    };

    self.comments = try .init(alloc);

    self.cursor = try .init(render_ctx.nc_ctx, sub_plane, .{ .height = 2 });

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
    if (self.cursor) |*cursor| {
        cursor.deinit();
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

    self.display_lines.deinit();
    self.alloc.free(self.output);
    self.alloc.free(self.stderr);
}

pub fn handleInputEvent(self: *Self, input_event: InputEvent) !Conclusion {
    // Special casing universal events
    if (input_event.key == c.NCKEY_RESIZE) {
        self.pending_resize = true;
        self.dirty = true;

        return .Noop;
    }

    switch (self.state) {
        .normal => {
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

                'c', 'C' => {
                    if (self.diff != null) {
                        const focused_line = self.display_lines.getPtr(self.focus_line) orelse return .Noop;

                        switch (focused_line.*) {
                            .diff => |*diff_display_line| {
                                if (self.comments) |*comments| {
                                    // here we are only considering one line since we got here via normal mode
                                    const src_line_number: usize = if (diff_display_line.line.line_number) |line_number|
                                        line_number.number
                                    else
                                        0;

                                    const line_id: LineId = .{
                                        .src_line_numbers = .{ src_line_number, null },
                                        .file_path = diff_display_line.line.file_path orelse "no file path",
                                        .display_rank = diff_display_line.stable_idx,
                                        .kind = diff_display_line.line.kind,
                                    };

                                    // Here is what is happening since it might
                                    // not be apparent to myself a few weeks
                                    // later what goes on here:
                                    // 1. Regardless of what the delta is in terms of displaylines, we move to the next focus line for editing. This could mean that we scroll on behalf of the user
                                    // 2. Hide the LineIndicator
                                    const comment = try comments.newComment(self.alloc, line_id);
                                    const next_insertable_line_num = blk: {
                                        // we'll take that of the closing half, if any
                                        const focus_src_line_num = line_id.src_line_numbers.@"1" orelse line_id.src_line_numbers.@"0";

                                        const display_line_count = self.display_lines.len();
                                        if (self.focus_line + 1 >= display_line_count) {
                                            break :blk self.focus_line + 1;
                                        } else {
                                            var idx = self.focus_line + 1;
                                            while (idx < display_line_count) : (idx += 1) {
                                                const line = self.display_lines.getPtr(idx) orelse break :blk display_line_count;
                                                switch (line.*) {
                                                    .diff => |diff| {
                                                        if (diff.line.line_number) |line_number| {
                                                            const diff_line_number = line_number.number;
                                                            if (diff_line_number == 0) continue;
                                                            if (focus_src_line_num < diff_line_number) break :blk idx;
                                                        }
                                                    },
                                                    else => {},
                                                }
                                            }
                                            break :blk display_line_count;
                                        }
                                    };

                                    const comment_x = self.commentBoxX();
                                    const comment_box_width = @max(@as(c_uint, 2), self.viewport_cols -| comment_x -| 1);
                                    try comment.rebuildDisplayLines(self.alloc, comment_box_width);

                                    for (comment.display_lines.items, 0..) |_, i| {
                                        try self.display_lines.insert(next_insertable_line_num + i, .{ .comments = .{
                                            .line_idx = i,
                                            .comment = comment,
                                        } });
                                    }

                                    self.state = .{ .editing = .{
                                        .first_display_line = next_insertable_line_num,
                                        .comment = comment,
                                    } };

                                    self.hideLineIndicator();
                                    try self.syncEditingCursor();

                                    self.dirty = true;
                                }
                            },
                            .comments => {},
                        }
                    }
                },

                else => {},
            }
        },

        .editing => |editing_detail| {
            const comment = editing_detail.comment;

            switch (input_event.key) {
                c.NCKEY_ESC => {
                    self.state = .normal;
                    if (self.cursor) |*cursor| try cursor.hide();
                    self.dirty = true;
                },

                c.NCKEY_BACKSPACE, 127 => {
                    if (comment.content.items.len > 0) {
                        try comment.removeContent(lastUtf8CodepointLen(comment.content.items));
                        try self.rebuildDisplayLinesAfterEditing();
                    }
                },

                c.NCKEY_ENTER, '\n', '\r' => {
                    try comment.appendContent(self.alloc, "\n");
                    try self.rebuildDisplayLinesAfterEditing();
                },

                else => {
                    const log = std.log.scoped(.diff_window);
                    var text_buf: [c.NCINPUT_MAX_EFF_TEXT_CODEPOINTS * 4]u8 = undefined;
                    const text = inputText(input_event, &text_buf);
                    if (isTextInput(text)) {
                        try comment.appendContent(self.alloc, text);
                        log.info("editing append text comment_ptr=0x{x} key={d} text_len={d} content_len={d} modifiers={d} text='{s}'", .{ @intFromPtr(comment), input_event.key, text.len, comment.content.items.len, input_event.ncinput.modifiers, text });
                        try self.rebuildDisplayLinesAfterEditing();
                    } else {
                        log.info("editing ignored input comment_ptr=0x{x} key={d} text_len={d} modifiers={d}", .{ @intFromPtr(comment), input_event.key, text.len, input_event.ncinput.modifiers });
                    }
                },
            }
        },

        .select => |range| {
            _ = range;
        },
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

        const display_line_count = self.display_lines.len();
        const start = @min(self.top_line, display_line_count);
        const visible_count = @min(self.viewport_rows, display_line_count - start);

        if (visible_count > 0) {
            var render_lines_ctx: RenderVisibleLinesCtx = .{
                .self = self,
                .nc_ctx = render_ctx.nc_ctx,
                .sub_plane = sub_plane,
            };
            try self.display_lines.performActionOnRange(
                start,
                start + visible_count - 1,
                renderVisibleDisplayLine,
                &render_lines_ctx,
            );
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
    if (indicator_plane) |plane| {
        if (self.line_indicator) |*indicator| {
            try indicator.render(render_ctx.nc_ctx);
        } else {
            c.ncplane_erase(plane);
        }
    }
    if (self.cursor) |*cursor| {
        try cursor.render(render_ctx.nc_ctx);
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

const RenderVisibleLinesCtx = struct {
    self: *Self,
    nc_ctx: *c.notcurses,
    sub_plane: *c.ncplane,
    viewport_row: usize = 0,
};

fn renderVisibleDisplayLine(ctx: *RenderVisibleLinesCtx, line: *DisplayLine) !void {
    const log = std.log.scoped(.diff_window);
    const viewport_row = ctx.viewport_row;
    defer ctx.viewport_row += 1;

    switch (line.*) {
        .diff => |*diff_line| {
            try diff_line.line.render(ctx.nc_ctx, ctx.sub_plane, @intCast(viewport_row));
        },
        .comments => |*comment_line| {
            const comment_display_line = commentDisplayLine(comment_line.comment, comment_line.line_idx) orelse return;
            const content = comment_display_line.content;
            log.debug("render comment line viewport_row={d} comment_ptr=0x{x} targetable={} bytes={d} display_width={d} content='{s}'", .{ viewport_row, @intFromPtr(comment_line.comment), comment_display_line.targetable, content.len, displayWidth(content), content });

            var rows: c_uint = 0;
            var cols: c_uint = 0;
            c.ncplane_dim_yx(ctx.sub_plane, &rows, &cols);

            const y: c_uint = @intCast(viewport_row);
            const x = ctx.self.commentBoxX();
            if (y >= rows or x >= cols) return;

            // Avoid writing into the final terminal column. Some
            // terminals/notcurses paths reject UTF-8 EGCs there.
            const available_cols: usize = cols -| x -| 1;
            if (available_cols == 0) return;

            const clipped = util.clipToDisplayWidth(content, available_cols);
            if (clipped.len == 0) return;

            putCommentSegment(ctx.sub_plane, @intCast(y), @intCast(x), clipped) catch |err| {
                log.err("comment render failed y={d} x={d} rows={d} cols={d} text_len={d} clipped_len={d} err={}", .{ y, x, rows, cols, content.len, clipped.len, err });
                return err;
            };
        },
    }
}

pub fn update(self: *Self, ft: FrameTime, render_ctx: *const RenderCtx) !Conclusion {
    if (self.pending_resize) {
        _ = try self.ensurePlane(render_ctx);
        self.pending_resize = false;

        if (self.diff) |*diff| {
            if (try diff.updateWidth(self.viewport_cols)) {
                try self.rebuildDisplayLinesWithComments();
                try self.syncEditingCursor();
                self.dirty = true;
            }
        }
    } else if (self.diff) |*diff| {
        if (try diff.updateHighlights()) {
            self.dirty = true;
        }
    }

    if (self.line_indicator) |*indicator| {
        _ = try indicator.update(ft);
    }
    if (self.cursor) |*cursor| {
        _ = try cursor.update(ft);
    }

    return .Noop;
}

fn rebuildDisplayLinesWithComments(self: *Self) !void {
    const diff = &(self.diff orelse return);

    const maybe_comments = if (self.comments) |*comments| blk: {
        break :blk try comments.sortedComments(self.alloc);
    } else null;
    defer if (maybe_comments) |comments| self.alloc.free(comments);

    self.display_lines.clearAndFree();

    var comment_idx: usize = 0;
    for (diff.display_lines.items, 0..) |*line_from_diff, stable_idx| {
        try self.display_lines.append(.{ .diff = .{
            .line = line_from_diff,
            .stable_idx = stable_idx,
        } });

        if (maybe_comments) |comments| {
            if (!isLastDisplayLineForSource(diff.display_lines.items, stable_idx)) continue;

            while (comment_idx < comments.len) {
                const cur_comment = comments[comment_idx];
                if (!commentBelongsAfterDiffLine(cur_comment, line_from_diff)) break;

                try self.appendCommentDisplayLines(cur_comment);
                comment_idx += 1;
            }
        }
    }
}

fn isLastDisplayLineForSource(lines: []const diff_.DisplayLine, idx: usize) bool {
    const cur_number = if (lines[idx].line_number) |line_number| line_number.number else return true;
    if (cur_number == 0) return true;

    if (idx + 1 >= lines.len) return true;
    const next_number = if (lines[idx + 1].line_number) |line_number| line_number.number else return true;

    return cur_number != next_number or
        lines[idx].kind != lines[idx + 1].kind or
        !optionalPathEql(lines[idx].file_path, lines[idx + 1].file_path);
}

fn commentBelongsAfterDiffLine(comment: *const Comments.Comment, line: *const diff_.DisplayLine) bool {
    const line_number = if (line.line_number) |num| num.number else return false;
    if (line_number == 0) return false;

    const comment_number = comment.line_id.src_line_numbers.@"1" orelse comment.line_id.src_line_numbers.@"0";
    if (comment_number != line_number) return false;
    if (comment.line_id.kind != line.kind) return false;

    const file_path = line.file_path orelse return false;
    return std.mem.eql(u8, comment.line_id.file_path, file_path);
}

fn optionalPathEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn putCommentSegment(plane: *c.ncplane, y: c_int, x: c_int, text: []const u8) !void {
    if (text.len == 0 or y < 0 or x < 0) return;

    var rows: c_uint = 0;
    var cols: c_uint = 0;
    c.ncplane_dim_yx(plane, &rows, &cols);

    const uy: c_uint = @intCast(y);
    if (uy >= rows) return;

    var cx = x;
    var i: usize = 0;
    while (i < text.len) {
        if (cx < 0) return;
        const ux: c_uint = @intCast(cx);
        if (ux + 1 >= cols) return;

        const cp_len = utf8CodepointLen(text[i..]);
        var egc_buf: [8:0]u8 = [_:0]u8{0} ** 8;
        @memcpy(egc_buf[0..cp_len], text[i .. i + cp_len]);

        var bytes_written: usize = 0;
        const written = c.ncplane_putegc_yx(plane, y, cx, &egc_buf, &bytes_written);
        if (written < 0) {
            // Do not take down the app for a render clipping issue. The caller
            // already clipped to the visible width, but notcurses can still
            // reject some EGCs near the right edge.
            return;
        }

        cx += @max(written, 1);
        i += cp_len;
    }
}

fn utf8CodepointLen(input: []const u8) usize {
    std.debug.assert(input.len > 0);

    const len = std.unicode.utf8ByteSequenceLength(input[0]) catch return 1;
    if (len > input.len) return 1;
    return len;
}

fn appendCommentDisplayLines(self: *Self, comment: *Comments.Comment) !void {
    const log = std.log.scoped(.diff_window);
    const comment_x = self.commentBoxX();
    const comment_box_width = @max(@as(c_uint, 2), self.viewport_cols -| comment_x -| 1);
    log.info("append comment display lines comment_ptr=0x{x} content_len={d} viewport_cols={d} comment_x={d} box_width={d}", .{ @intFromPtr(comment), comment.content.items.len, self.viewport_cols, comment_x, comment_box_width });
    try comment.rebuildDisplayLines(self.alloc, comment_box_width);

    for (comment.display_lines.items, 0..) |*comment_display_line, i| {
        log.info("generated comment display line comment_ptr=0x{x} local_idx={d} targetable={} bytes={d} display_width={d} content='{s}'", .{ @intFromPtr(comment), i, comment_display_line.targetable, comment_display_line.content.len, displayWidth(comment_display_line.content), comment_display_line.content });
        try self.display_lines.append(.{ .comments = .{
            .line_idx = i,
            .comment = comment,
        } });
    }
}

fn rebuildDisplayLinesAfterEditing(self: *Self) !void {
    const log = std.log.scoped(.diff_window);
    const before_len = self.display_lines.len();
    const editing = switch (self.state) {
        .editing => |editing| editing,
        else => return,
    };

    try self.patchDisplayLinesForEditedComment(editing.first_display_line, editing.comment);
    log.info("patch after editing display_lines before={d} after={d}", .{ before_len, self.display_lines.len() });
    try self.syncEditingCursor();
    self.dirty = true;
}

fn patchDisplayLinesForEditedComment(self: *Self, first_display_line: usize, comment: *Comments.Comment) !void {
    const old_len = self.commentDisplayLineCount(first_display_line, comment);

    const comment_x = self.commentBoxX();
    const comment_box_width = @max(@as(c_uint, 2), self.viewport_cols -| comment_x -| 1);
    try comment.rebuildDisplayLines(self.alloc, comment_box_width);
    const new_len = comment.display_lines.items.len;

    const shared_len = @min(old_len, new_len);
    for (0..shared_len) |i| {
        const line = self.display_lines.getPtr(first_display_line + i) orelse return error.IndexNotFound;
        line.* = .{ .comments = .{
            .line_idx = i,
            .comment = comment,
        } };
    }

    if (new_len > old_len) {
        for (old_len..new_len) |i| {
            try self.display_lines.insert(first_display_line + i, .{ .comments = .{
                .line_idx = i,
                .comment = comment,
            } });
        }
    } else if (new_len < old_len) {
        try self.display_lines.removeFromIndexRange(self.alloc, first_display_line + new_len, first_display_line + old_len - 1);
    }
}

fn commentDisplayLineCount(self: *Self, first_display_line: usize, comment: *const Comments.Comment) usize {
    var count: usize = 0;
    var idx = first_display_line;

    while (idx < self.display_lines.len()) : (idx += 1) {
        const line = self.display_lines.getPtr(idx) orelse break;
        switch (line.*) {
            .comments => |comment_line| {
                if (comment_line.comment != comment) break;
                count += 1;
            },
            else => break,
        }
    }

    return count;
}

fn syncEditingCursor(self: *Self) !void {
    const editing = switch (self.state) {
        .editing => |editing| editing,
        else => return,
    };

    const log = std.log.scoped(.diff_window);
    const maybe_cursor_display_line = self.lastEditableDisplayLineForComment(editing.first_display_line, editing.comment);
    const cursor_display_line = maybe_cursor_display_line orelse editing.first_display_line;
    log.info("sync editing cursor comment_ptr=0x{x} first_display_line={d} found_line={?} cursor_line={d} top_line_before={d} content_len={d} end_col={d}", .{ @intFromPtr(editing.comment), editing.first_display_line, maybe_cursor_display_line, cursor_display_line, self.top_line, editing.comment.content.items.len, self.commentEndColumn(editing.comment) });
    self.autoScroll(cursor_display_line);

    if (self.cursor) |*cursor| {
        const y: c_int = @intCast(cursor_display_line -| self.top_line);
        const x: c_int = @intCast(self.commentBoxX() + 1 + self.commentEndColumn(editing.comment));
        try cursor.move(y, x);
        cursor.unhide();
    }
}

fn lastEditableDisplayLineForComment(self: *Self, start_from: usize, comment: *const Comments.Comment) ?usize {
    var result: ?usize = null;
    var idx = start_from;

    while (idx < self.display_lines.len()) : (idx += 1) {
        const line = self.display_lines.getPtr(idx) orelse break;
        switch (line.*) {
            .comments => |comment_line| {
                if (comment_line.comment != comment) break;
                const comment_display_line = commentDisplayLine(comment_line.comment, comment_line.line_idx) orelse break;
                if (comment_display_line.targetable) result = idx;
            },
            else => break,
        }
    }

    return result;
}

/// Adjusts the top line such that the focus line is situated appropriately:
/// - Top line remains unchanged if the new focus line is in view
/// - If the new focus line is not in view (i.e. below the bottom of the
///   current viewport), we place choose a top line that would place the new
///   focus line at the second last line of the viewport (we are leaving one line
///   for the bottom of the border)
fn autoScroll(self: *Self, destination_idx: usize) void {
    const bottom = self.top_line +| self.viewport_rows;
    if (destination_idx < bottom) return;
    self.top_line = destination_idx -| self.viewport_rows +| 2;
}

fn commentEndColumn(self: *const Self, comment: *const Comments.Comment) c_uint {
    const comment_x = self.commentBoxX();
    const comment_box_width = @max(@as(c_uint, 2), self.viewport_cols -| comment_x -| 1);
    const inner_width = comment_box_width - 2;
    const content = comment.content.items;

    if (content.len == 0) return 0;

    var result: c_uint = 0;
    var physical_lines = std.mem.splitScalar(u8, content, '\n');
    while (physical_lines.next()) |physical_line| {
        if (physical_line.len == 0) {
            result = 0;
            continue;
        }

        var remaining = physical_line;
        while (remaining.len > 0) {
            const wrapped = util.wrapLine(remaining, inner_width);
            result = wrapped.display_width;
            const end = wrapped.end orelse remaining.len;
            remaining = remaining[end..];
        }
    }

    return result;
}

fn commentDisplayLine(comment: *Comments.Comment, idx: usize) ?*Comments.DisplayLine {
    if (idx >= comment.display_lines.items.len) return null;
    return &comment.display_lines.items[idx];
}

fn displayWidth(content: []const u8) c_uint {
    return util.wrapLine(content, std.math.maxInt(c_uint)).display_width;
}

fn inputText(input_event: InputEvent, buf: *[c.NCINPUT_MAX_EFF_TEXT_CODEPOINTS * 4]u8) []const u8 {
    const effective_text = effectiveInputText(input_event, buf);
    if (isTextInput(effective_text)) return effective_text;

    // Without effective text, continue to ignore shortcut-style modified keys.
    if ((input_event.ncinput.modifiers & (c.NCKEY_MOD_CTRL | c.NCKEY_MOD_ALT)) != 0) return "";

    if (input_event.key >= 0x20 and input_event.key <= 0x7e) {
        buf[0] = @intCast(input_event.key);
        return buf[0..1];
    }

    return inputUtf8(input_event);
}

fn effectiveInputText(input_event: InputEvent, buf: *[c.NCINPUT_MAX_EFF_TEXT_CODEPOINTS * 4]u8) []const u8 {
    var len: usize = 0;
    for (input_event.ncinput.eff_text) |raw_cp| {
        if (raw_cp == 0) break;
        const cp: u21 = std.math.cast(u21, raw_cp) orelse return "";
        const cp_len = std.unicode.utf8Encode(cp, buf[len..]) catch return "";
        len += cp_len;
    }
    return buf[0..len];
}

fn inputUtf8(input_event: InputEvent) []const u8 {
    const raw = input_event.ncinput.utf8[0..];
    return std.mem.sliceTo(raw, 0);
}

fn isTextInput(text: []const u8) bool {
    if (text.len == 0) return false;

    // Do not append C0/DEL controls. Printable ASCII is handled from
    // input_event.key before we trust ncinput.utf8 because notcurses can report
    // stale/control bytes there for ordinary keypresses on this path.
    if (text.len == 1 and (text[0] < 0x20 or text[0] == 0x7f)) return false;

    return std.unicode.utf8ValidateSlice(text);
}

fn lastUtf8CodepointLen(content: []const u8) usize {
    if (content.len == 0) return 0;

    var idx = content.len - 1;
    while (idx > 0 and (content[idx] & 0b1100_0000) == 0b1000_0000) {
        idx -= 1;
    }

    return content.len - idx;
}

fn commentBoxX(self: *const Self) c_uint {
    if (self.diff) |*diff| return diff.line_number_width + 2;
    return 0;
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
    if (self.focus_line + 1 >= self.display_lines.len()) return false;

    const margin = @min(@as(usize, 5), self.viewport_rows -| 1);
    const viewport_row = self.focus_line -| self.top_line;
    const bottom_margin_row = self.viewport_rows -| 1 -| margin;

    self.focus_line += 1;
    if (viewport_row >= bottom_margin_row and self.top_line + self.viewport_rows < self.display_lines.len()) {
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
    if (self.focus_line + 1 >= self.display_lines.len()) return false;

    const viewport_row = self.focus_line -| self.top_line;
    self.focus_line = @min(self.focus_line + pageScrollAmount(self), self.display_lines.len() - 1);
    self.keepFocusAtViewportRow(viewport_row);
    return true;
}

fn pageScrollAmount(self: *const Self) usize {
    return @max(@as(usize, 1), self.viewport_rows -| 2);
}

fn keepFocusAtViewportRow(self: *Self, viewport_row: usize) void {
    const max_top = self.display_lines.len() -| self.viewport_rows;
    self.top_line = @min(self.focus_line -| viewport_row, max_top);
}

fn hideLineIndicator(self: *Self) void {
    if (self.line_indicator) |*indicator| {
        indicator.deinit();
        self.line_indicator = null;
    }

    if (self.indicator_plane) |plane| {
        _ = c.ncplane_destroy(plane);
        self.indicator_plane = null;
    }
}

fn ensurePlane(self: *Self, render_ctx: *const RenderCtx) !struct {
    main_plane: *c.ncplane,
    sub_plane: *c.ncplane,
    line_indicator_plane: ?*c.ncplane,
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

    if (self.state == .editing) {
        self.hideLineIndicator();
    } else {
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
            indicator.unhide();
        }
    }

    return .{
        .sub_plane = self.sub_plane.?,
        .main_plane = self.main_plane.?,
        .line_indicator_plane = self.indicator_plane,
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

const std = @import("std");

const util = @import("../../util/root.zig");
const consts = @import("../../consts.zig");
const c = util.c;
const protocol = @import("../../protocol.zig");
const LineId = protocol.LineId;
const InputEvent = protocol.InputEvent;
const Input = protocol.Input;
const FrameTime = protocol.FrameTime;
const Conclusion = protocol.Conclusion;
const Component = @import("../Component.zig");
const Bucket = util.LeakyBucket(Input);
const RenderCtx = protocol.RenderCtx;
const ASSET_PATH = consts.ASSET_PATH;
const diff_ = @import("../diff.zig");
const Diff = diff_.Diff;
const LineIndicator = @import("../LineIndicator.zig");
const Comments = @import("../Comments.zig");
const Cursor = @import("../Cursor.zig");
const DetailBar = @import("../DetailBar.zig");

const default_keymaps = @import("default_keymaps.zig");
const Command = default_keymaps.Command;
const CommandKind = default_keymaps.CommandKind;
const CommandText = default_keymaps.Text;
const DisplayLineStorage = util.FenwickTreeStorage(DisplayLine);
const KeymapSink = util.KeymapSink(KeymapSinkCtx, Input, Command);
const KeyChord = util.KeyChord;

const Self = @This();

const DIFF_ARGV: []const []const u8 = &.{ "jj", "diff", "--tool=:git", "--color", "never" };
const default_bindings = default_keymaps.default_bindings;

const State = union(enum) {
    pub const EditState = union(enum) { normal: struct {
        first_display_line: usize,
        comment: *Comments.Comment,
    }, deletion: struct {
        first_display_line: usize,
        comment_rows: usize,
    } };

    normal,
    editing: EditState,
    select,
    search,
    seek,
};

const Keymaps = std.HashMap(
    []const KeyChord,
    CommandKind,
    KeyChord.SequenceContext,
    std.hash_map.default_max_load_percentage,
);

const KeymapPrefixes = std.AutoHashMap(KeyChord, void);

const KeymapSinkCtx = struct {
    state: *const State,
    keymap: Keymaps,
    prefixes: KeymapPrefixes,
};

fn chordFromInput(input: Input) KeyChord {
    return .{
        .key = input.key,
        .mods = @intCast(input.ncinput.modifiers),
    };
}

fn emptyCommandText() CommandText {
    return .{ .buf = undefined, .len = 0 };
}

fn commandTextFromInput(input: Input) ?CommandText {
    var tmp: [util.input_text_buffer_len]u8 = undefined;
    const text = util.inputText(input.key, input.ncinput, &tmp);
    if (!util.isTextInput(text)) return null;

    var res: CommandText = .{ .buf = undefined, .len = text.len };
    @memcpy(res.buf[0..text.len], text);
    return res;
}

fn commandFromKind(kind: CommandKind) Command {
    return switch (kind) {
        .dismount => .dismount,
        .resize => .resize,
        .move_up => .move_up,
        .move_down => .move_down,
        .move_page_up => .move_page_up,
        .move_page_down => .move_page_down,
        .move_selection_up => .move_selection_up,
        .move_selection_down => .move_selection_down,
        .move_selection_page_up => .move_selection_page_up,
        .move_selection_page_down => .move_selection_page_down,
        .goto_top => .goto_top,
        .goto_bottom => .goto_bottom,
        .center_focus => .center_focus,
        .enter_select => .enter_select,
        .exit_to_normal => .exit_to_normal,
        .toggle_selection_bound => .toggle_selection_bound,
        .start_comment_at_focus => .start_comment_at_focus,
        .start_comment_at_selection => .start_comment_at_selection,
        .start_search_up => .start_search_up,
        .start_search_down => .start_search_down,
        .accept_search => .accept_search,
        .search_delete_char => .search_delete_char,
        .search_add_text => .{ .search_add_text = emptyCommandText() },
        .repeat_search => .repeat_search,
        .repeat_search_opposite => .repeat_search_opposite,
        .finish_editing => .finish_editing,
        .edit_delete_char => .edit_delete_char,
        .edit_add_newline => .edit_add_newline,
        .edit_add_text => .{ .edit_add_text = emptyCommandText() },
    };
}

fn commandForSequence(
    state: State,
    bindings: []const default_keymaps.Binding,
    sequence: []const KeyChord,
    latest_input: Input,
) ?Command {
    for (bindings) |binding| {
        if (KeyChord.SequenceContext.eql(.{}, sequence, binding.keys)) return commandFromKind(binding.command);
    }

    if (sequence.len != 1) return null;

    const text = commandTextFromInput(latest_input) orelse return null;
    return switch (state) {
        .search => .{ .search_add_text = text },
        .editing => .{ .edit_add_text = text },
        else => null,
    };
}

state: *State,

alloc: std.mem.Allocator,
output: []u8,
stderr: []u8,

main_plane: ?*c.ncplane = null,
sub_plane: ?*c.ncplane = null,

diff: ?Diff = null,
line_indicator: ?LineIndicator = null,
comments: ?Comments = null,
cursor: ?Cursor = null,
detail_bar: ?DetailBar = null,

top_line: usize = 0,
focus_line: usize = 0,
viewport_rows: usize = 1,
viewport_cols: c_uint = 0,
pending_resize: bool = false,
display_dirty: bool = true,
keymap_sink: KeymapSink,

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
                    if (self_typed.display_dirty) return true;
                    if (self_typed.diff) |diff| if (diff.isDirty()) return true;
                    if (self_typed.line_indicator) |*indicator| if (indicator.isDirty()) return true;
                    if (self_typed.cursor) |*cursor| if (cursor.isDirty()) return true;
                    if (self_typed.detail_bar) |*bar| if (bar.isDirty()) return true;
                    return false;
                }
            }.isDirty,

            .key_handler = struct {
                pub fn handleInput(ptr: *anyopaque, event: InputEvent, render_ctx: *const RenderCtx) !Conclusion {
                    _ = render_ctx;
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));

                    switch (event) {
                        .timeout => {
                            self_typed.keymap_sink.bucket.clear();
                            return .Claimed;
                        },
                        .input => |input| {
                            // We will only handle key down
                            if (input.key == 0 or input.ncinput.evtype == c.NCTYPE_RELEASE)
                                return .Noop;

                            const commands = try self_typed.keymap_sink.processForPotentialHit(input) orelse return .Noop;

                            const first_res = try @call(.always_inline, handleInputEvent, .{ self_typed, commands[0] });
                            switch (first_res) {
                                .Noop, .Claimed => {},
                                else => return first_res,
                            }

                            if (commands[1]) |second| {
                                return try @call(.always_inline, handleInputEvent, .{ self_typed, second });
                            }

                            return first_res;
                        },
                    }
                }
            }.handleInput,

            .update = struct {
                pub fn _update(ptr: *anyopaque, ft: FrameTime, render_ctx: *const RenderCtx) !Conclusion {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    return try @call(.always_inline, update, .{ self_typed, ft, render_ctx });
                }
            }._update,

            .next_update_time = struct {
                pub fn updateInterval(ptr: *anyopaque, frame_time: FrameTime) i64 {
                    const normal_frame_interval: i64 = 1000 / 24;
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    const from_km = self_typed.keymap_sink.nextTimeoutIn(frame_time.now_ms) orelse std.math.maxInt(i64);

                    return @min(normal_frame_interval, from_km);
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

    const state = try alloc.create(State);
    errdefer alloc.destroy(state);
    state.* = .normal;

    var keymap: Keymaps = .init(alloc);
    errdefer keymap.deinit();
    for (default_bindings) |binding| {
        try keymap.put(binding.keys, binding.command);
    }

    var prefixes: KeymapPrefixes = .init(alloc);
    errdefer prefixes.deinit();
    for (default_bindings) |binding| {
        if (binding.keys.len > 1) {
            try prefixes.put(binding.keys[0], {});
        }
    }

    const keymapsink_ctx = KeymapSinkCtx{
        .state = state,
        .keymap = keymap,
        .prefixes = prefixes,
    };

    var self: Self = .{
        .alloc = alloc,
        .state = state,
        .display_lines = .{ .alloc = alloc },
        .output = run_result.stdout,
        .stderr = run_result.stderr,
        .keymap_sink = .init(keymapsink_ctx, struct {
            pub fn parse(ctx: KeymapSinkCtx, iter: *Bucket.Slice.Iterator) ?KeymapSink.Result {
                var len: usize = 0;
                var sequence_buf: [8]KeyChord = undefined;
                var latest_input: ?Input = null;

                while (iter.next()) |input| {
                    if (len >= sequence_buf.len) return null;
                    sequence_buf[len] = chordFromInput(input.*);
                    latest_input = input.*;
                    len += 1;
                }

                if (len == 0) return null;

                const input = latest_input.?;
                const component_state = ctx.state.*;
                const sequence = sequence_buf[0..len];
                if (commandForSequence(component_state, default_keymaps.universal_bindings[0..], sequence, input)) |command| {
                    return .{ .command = .{ command, null }, .consumed = len };
                }

                const active_bindings = switch (component_state) {
                    .normal => default_keymaps.normal_bindings[0..],
                    .editing => default_keymaps.editing_bindings[0..],
                    .select => default_keymaps.select_bindings[0..],
                    .search => default_keymaps.search_bindings[0..],
                    .seek => default_keymaps.seek_bindings[0..],
                };

                if (commandForSequence(component_state, active_bindings, sequence, input)) |command| {
                    return .{ .command = .{ command, null }, .consumed = len };
                }

                if (len == 1 and ctx.prefixes.contains(sequence[0])) return null;

                return null;
            }
        }.parse, .{}),
    };

    const parse_start_ns = nowNs();
    const planes = try self.ensurePlane(render_ctx);
    const main_plane = planes.main_plane;
    const sub_plane = planes.sub_plane;

    const main_cols = c.ncplane_dim_x(main_plane);
    self.line_indicator = try LineIndicator.init(render_ctx.nc_ctx, main_plane, .{
        .y = 1,
        .x = 1,
        .height = 2,
        .width = @max(@as(c_uint, 1), main_cols -| 2),
    });

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

    self.detail_bar = try .init(main_plane, .{
        .height = 1,
        .width = main_cols,
        .y = @intCast(render_ctx.term_rows -| 1),
    });

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
    if (self.detail_bar) |*bar| {
        bar.deinit(self.alloc);
    }

    if (self.sub_plane) |plane| {
        _ = c.ncplane_destroy(plane);
        self.sub_plane = null;
    }
    if (self.main_plane) |plane| {
        _ = c.ncplane_destroy(plane);
        self.main_plane = null;
    }

    self.keymap_sink.ctx.keymap.deinit();
    self.keymap_sink.ctx.prefixes.deinit();
    self.display_lines.deinit();
    self.alloc.free(self.output);
    self.alloc.free(self.stderr);
    self.alloc.destroy(self.state);
}

pub fn handleInputEvent(self: *Self, command: Command) !Conclusion {
    defer if (self.detail_bar) |*bar| {
        bar.setMode(self.alloc, detailBarMode(self.state));
    };

    switch (command) {
        .resize => {
            self.pending_resize = true;
            self.display_dirty = true;
            return .Noop;
        },

        .dismount => return .Dismount,

        .move_down => {
            if (self.diff != null and self.moveFocusDown()) {
                try self.syncLineIndicatorToFocus();
                self.display_dirty = true;
            }
        },

        .move_up => {
            if (self.diff != null and self.moveFocusUp()) {
                try self.syncLineIndicatorToFocus();
                self.display_dirty = true;
            }
        },

        .move_page_down => {
            if (self.diff != null and self.moveFocusPageDown()) {
                try self.syncLineIndicatorToFocus();
                self.display_dirty = true;
            }
        },

        .move_page_up => {
            if (self.diff != null and self.moveFocusPageUp()) {
                try self.syncLineIndicatorToFocus();
                self.display_dirty = true;
            }
        },

        .enter_select => {
            if (self.diff != null and self.line_indicator != null) {
                self.state.* = .select;
                self.line_indicator.?.enterVisualMode();
            }
        },

        .exit_to_normal => {
            self.state.* = .normal;
            if (self.cursor) |*cursor| try cursor.hide();
            try self.syncLineIndicatorToFocus();
        },

        .start_comment_at_focus => {
            if (self.diff != null) {
                try self.startCommentFromDisplayRange(self.focus_line, self.focus_line);
            }
        },

        .move_selection_down => {
            if (try self.moveSelectionFocus(.down)) self.display_dirty = true;
        },

        .move_selection_up => {
            if (try self.moveSelectionFocus(.up)) self.display_dirty = true;
        },

        .move_selection_page_down => {
            if (try self.moveSelectionFocus(.page_down)) self.display_dirty = true;
        },

        .move_selection_page_up => {
            if (try self.moveSelectionFocus(.page_up)) self.display_dirty = true;
        },

        .toggle_selection_bound => {
            if (self.line_indicator) |*indicator| switch (indicator.state) {
                .visual => |*visual| {
                    visual.focus_bound = if (visual.focus_bound == 0) 1 else 0;
                    self.focus_line = self.top_line +| visual.range[visual.focus_bound] -| 1;
                    indicator.pending_transition = true;
                    indicator.gif.dirty = true;
                    self.display_dirty = true;
                },
                else => {},
            };
        },

        .start_comment_at_selection => {
            if (self.line_indicator) |indicator| switch (indicator.state) {
                .visual => |visual| {
                    const start = self.top_line +| visual.range[0] -| 1;
                    const end = self.top_line +| visual.range[1] -| 1;
                    try self.startCommentFromDisplayRange(start, end);
                },
                else => {},
            };
        },

        .start_search_down => {
            if (self.detail_bar) |*bar| {
                bar.setMode(self.alloc, .search);
                self.state.* = .search;
            }
        },

        .start_search_up => {
            if (self.detail_bar) |*bar| {
                bar.setMode(self.alloc, .search);
                bar.flipSearchDirection();
                self.state.* = .search;
            }
        },

        .accept_search => {
            const query = self.detail_bar.?.conclude() orelse return .Noop;
            if (query.result == .found) {
                self.state.* = .seek;
            } else if (self.detail_bar) |*bar| {
                bar.setSearchResult(false);
            }
        },

        .search_delete_char => {
            try self.detail_bar.?.modifySearchQuery(self.alloc, .delete_single);
            _ = try self.searchFromDetailBar(null);
        },

        .search_add_text => |text| {
            const text_slice = text.slice();
            if (util.isTextInput(text_slice)) {
                try self.detail_bar.?.modifySearchQuery(self.alloc, .{ .add_multiple = text_slice });
                _ = try self.searchFromDetailBar(null);
            }
        },

        .repeat_search => {
            _ = try self.searchFromDetailBar(null);
        },

        .repeat_search_opposite => {
            const query = self.detail_bar.?.conclude() orelse return .Noop;
            _ = try self.searchFromDetailBar(oppositeSearchDirection(query.dir));
        },

        .finish_editing => {
            switch (self.state.*) {
                .editing => |editing_detail| switch (editing_detail) {
                    .normal => |editing| {
                        const comment = editing.comment;
                        if (comment.content.items.len == 0) {
                            const comment_rows = self.commentDisplayLineCount(editing.first_display_line, comment);
                            if (self.comments.?.removeComment(self.alloc, comment)) {
                                self.state.* = .{ .editing = .{ .deletion = .{
                                    .first_display_line = editing.first_display_line,
                                    .comment_rows = comment_rows,
                                } } };
                                try self.rebuildDisplayLinesAfterEditing();
                            }
                        }
                    },
                    .deletion => {},
                },
                else => {},
            }
            self.state.* = .normal;
            if (self.cursor) |*cursor| try cursor.hide();
            try self.syncLineIndicatorToFocus();
        },

        .edit_delete_char => {
            switch (self.state.*) {
                .editing => |editing_detail| switch (editing_detail) {
                    .normal => |editing| {
                        const comment = editing.comment;
                        if (comment.content.items.len > 0) {
                            try comment.removeContent(util.lastUtf8CodepointLen(comment.content.items));
                            try self.rebuildDisplayLinesAfterEditing();
                        }
                    },
                    .deletion => {},
                },
                else => {},
            }
        },

        .edit_add_newline => {
            switch (self.state.*) {
                .editing => |editing_detail| switch (editing_detail) {
                    .normal => |editing| {
                        try editing.comment.appendContent(self.alloc, "\n");
                        try self.rebuildDisplayLinesAfterEditing();
                    },
                    .deletion => {},
                },
                else => {},
            }
        },

        .edit_add_text => |text| {
            const text_slice = text.slice();
            switch (self.state.*) {
                .editing => |editing_detail| switch (editing_detail) {
                    .normal => |editing| {
                        if (util.isTextInput(text_slice)) {
                            try editing.comment.appendContent(self.alloc, text_slice);
                            try self.rebuildDisplayLinesAfterEditing();
                        }
                    },
                    .deletion => {},
                },
                else => {},
            }
        },

        .goto_top, .goto_bottom, .center_focus => {},
    }

    return .Claimed;
}

pub fn render(self: *Self, render_ctx: *const RenderCtx) !void {
    const log = std.log.scoped(.diff_window);
    const render_start_ns = nowNs();

    const ensure_start_ns = nowNs();
    const planes = try self.ensurePlane(render_ctx);
    const ensure_ns = nowNs() - ensure_start_ns;

    const main_plane = planes.main_plane;
    const sub_plane = planes.sub_plane;

    const diff_dirty = if (self.diff) |diff| diff.isDirty() else false;
    const display_dirty = self.display_dirty or diff_dirty;

    var border_ns: i128 = 0;
    if (display_dirty) {
        const border_start_ns = nowNs();
        const active_file_name = if (self.diff) |*diff|
            diff.fileNameForDisplayLine(self.focus_line)
        else
            null;
        try drawBorder(main_plane, active_file_name, 1);
        border_ns = nowNs() - border_start_ns;
    }

    var diff_render_ns: i128 = 0;
    if (display_dirty) {
        if (self.diff) |*diff| {
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

            diff.markClean();
            diff_render_ns = nowNs() - diff_render_start_ns;
        } else {
            c.ncplane_erase(sub_plane);
            const msg = "No diff to display";
            if (c.ncplane_putnstr_yx(sub_plane, 0, 0, msg.len, msg.ptr) < 0) {
                return error.PutStrFailed;
            }
        }
    }

    var indicator_render_ns: i128 = 0;
    const indicator_render_start_ns = nowNs();
    if (self.line_indicator) |*indicator| {
        if (indicator.isDirty()) try indicator.render(render_ctx.nc_ctx);
    }
    if (self.cursor) |*cursor| {
        if (cursor.isDirty()) try cursor.render(render_ctx.nc_ctx);
    }
    if (self.detail_bar) |*bar| {
        if (bar.isDirty()) try bar.render(render_ctx.nc_ctx);
    }
    indicator_render_ns = nowNs() - indicator_render_start_ns;

    self.display_dirty = false;

    log.debug("DiffWindow.render profile: total_ms={d:.3} ensure_ms={d:.3} border_ms={d:.3} diff_update_ms={d:.3} diff_render_ms={d:.3} indicator_ms={d:.3}", .{
        nsToMs(nowNs() - render_start_ns),
        nsToMs(ensure_ns),
        nsToMs(border_ns),
        0,
        nsToMs(diff_render_ns),
        nsToMs(indicator_render_ns),
    });
}

fn searchFromDetailBar(self: *Self, override_dir: ?DetailBar.Query.SearchDirection) !bool {
    const bar = &(self.detail_bar orelse return false);
    const query = bar.conclude() orelse return false;
    if (query.query.items.len == 0) return false;

    const dir = override_dir orelse query.dir;
    const hit = self.findSearchHit(query.query.items, dir) orelse {
        bar.setSearchResult(false);
        return false;
    };
    bar.setSearchResult(true);
    self.focus_line = hit;
    self.scrollFocusIntoView();
    try self.syncLineIndicatorToFocus();
    self.display_dirty = true;
    return true;
}

fn findSearchHit(self: *Self, needle: []const u8, dir: DetailBar.Query.SearchDirection) ?usize {
    if (needle.len == 0) return null;

    return switch (dir) {
        .down => self.findSearchHitDown(needle),
        .up => self.findSearchHitUp(needle),
    };
}

fn findSearchHitDown(self: *Self, needle: []const u8) ?usize {
    const line_count = self.display_lines.len();
    if (line_count == 0) return null;

    var idx = @min(self.focus_line +| 1, line_count);
    while (idx < line_count) : (idx += 1) {
        if (self.displayLineContains(idx, needle)) return idx;
    }

    idx = 0;
    while (idx <= self.focus_line and idx < line_count) : (idx += 1) {
        if (self.displayLineContains(idx, needle)) return idx;
    }

    return null;
}

fn findSearchHitUp(self: *Self, needle: []const u8) ?usize {
    const line_count = self.display_lines.len();
    if (line_count == 0) return null;

    var idx = self.focus_line;
    while (idx > 0) {
        idx -= 1;
        if (self.displayLineContains(idx, needle)) return idx;
    }

    idx = line_count;
    while (idx > self.focus_line + 1) {
        idx -= 1;
        if (self.displayLineContains(idx, needle)) return idx;
    }

    return null;
}

fn displayLineContains(self: *Self, idx: usize, needle: []const u8) bool {
    const line = self.display_lines.getPtr(idx) orelse return false;
    const haystack = switch (line.*) {
        .diff => |diff_line| diff_line.line.text,
        .comments => |comment_line| blk: {
            const comment_display_line = commentDisplayLine(comment_line.comment, comment_line.line_idx) orelse return false;
            break :blk comment_display_line.content;
        },
    };

    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn scrollFocusIntoView(self: *Self) void {
    if (self.focus_line < self.top_line) {
        self.top_line = self.focus_line;
        return;
    }

    const bottom = self.top_line +| self.viewport_rows;
    if (self.focus_line >= bottom) {
        self.top_line = self.focus_line -| self.viewport_rows +| 2;
    }
}

fn oppositeSearchDirection(dir: DetailBar.Query.SearchDirection) DetailBar.Query.SearchDirection {
    return switch (dir) {
        .down => .up,
        .up => .down,
    };
}

fn detailBarMode(state: *const State) DetailBar.Mode {
    return switch (state.*) {
        .normal => .normal,
        .editing => .comment,
        .select => .select,
        .search, .seek => .search,
    };
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
            log.debug("render comment line viewport_row={d} comment_ptr=0x{x} targetable={} bytes={d} display_width={d} content='{s}'", .{ viewport_row, @intFromPtr(comment_line.comment), comment_display_line.targetable, content.len, util.displayWidth(content), content });

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

            util.putEgcSegment(ctx.sub_plane, @intCast(y), @intCast(x), clipped) catch |err| {
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
                self.refreshEditingDisplayLineAfterRebuild();
                try self.syncEditingCursor();
                self.display_dirty = true;
            }
        }

        if (self.detail_bar) |*bar| {
            try bar.update(self.main_plane.?);
        }
    } else if (self.diff) |*diff| {
        _ = try diff.updateHighlights();
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

fn startCommentFromDisplayRange(self: *Self, start: usize, end: usize) !void {
    const comments = &(self.comments orelse return);
    const range_start = @min(start, end);
    const range_end = @min(@max(start, end), self.display_lines.len() -| 1);

    var first_line: ?*diff_.DisplayLine = null;
    var first_src_line_number: usize = 0;
    var last_line: ?*diff_.DisplayLine = null;
    var last_src_line_number: usize = 0;
    var last_display_line_idx: usize = range_start;
    var last_stable_idx: usize = 0;

    var idx = range_start;
    while (idx <= range_end) : (idx += 1) {
        const display_line = self.display_lines.getPtr(idx) orelse break;
        switch (display_line.*) {
            .diff => |*diff_display_line| {
                const src_line_number = if (diff_display_line.line.line_number) |line_number|
                    line_number.number
                else
                    continue;
                if (src_line_number == 0) continue;

                if (first_line == null) {
                    first_line = diff_display_line.line;
                    first_src_line_number = src_line_number;
                }

                last_line = diff_display_line.line;
                last_src_line_number = src_line_number;
                last_display_line_idx = idx;
                last_stable_idx = diff_display_line.stable_idx;
            },
            .comments => {},
        }
    }

    const closing_line = last_line orelse return;
    const line_id: LineId = .{
        .src_line_numbers = .{ first_src_line_number, if (first_src_line_number == last_src_line_number) null else last_src_line_number },
        .file_path = closing_line.file_path orelse "no file path",
        .display_rank = last_stable_idx,
        .kind = closing_line.kind,
    };

    const comment = try comments.newComment(self.alloc, line_id);
    const next_insertable_line_num = self.commentInsertIndexForDiffAt(last_display_line_idx, closing_line);

    const comment_x = self.commentBoxX();
    const comment_box_width = @max(@as(c_uint, 2), self.viewport_cols -| comment_x -| 1);
    try comment.rebuildDisplayLines(self.alloc, comment_box_width);

    for (comment.display_lines.items, 0..) |_, i| {
        try self.display_lines.insert(next_insertable_line_num + i, .{ .comments = .{
            .line_idx = i,
            .comment = comment,
        } });
    }

    self.state.* = .{ .editing = .{ .normal = .{
        .first_display_line = next_insertable_line_num,
        .comment = comment,
    } } };

    self.hideLineIndicator();
    try self.syncEditingCursor();
    self.display_dirty = true;
}

fn commentInsertIndexForDiffAt(self: *Self, start_idx: usize, focused: *const diff_.DisplayLine) usize {
    var idx = start_idx + 1;
    while (idx < self.display_lines.len()) : (idx += 1) {
        const line = self.display_lines.getPtr(idx) orelse return self.display_lines.len();
        switch (line.*) {
            .diff => |diff_line| {
                if (!sameDiffSource(focused, diff_line.line)) return idx;
            },
            .comments => {},
        }
    }
    return self.display_lines.len();
}

fn sameDiffSource(a: *const diff_.DisplayLine, b: *const diff_.DisplayLine) bool {
    const a_number = if (a.line_number) |line_number| line_number.number else return false;
    const b_number = if (b.line_number) |line_number| line_number.number else return false;
    if (a_number == 0 or b_number == 0) return false;

    return a_number == b_number and
        a.kind == b.kind and
        optionalPathEql(a.file_path, b.file_path);
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

fn appendCommentDisplayLines(self: *Self, comment: *Comments.Comment) !void {
    const log = std.log.scoped(.diff_window);
    const comment_x = self.commentBoxX();
    const comment_box_width = @max(@as(c_uint, 2), self.viewport_cols -| comment_x -| 1);
    log.info("append comment display lines comment_ptr=0x{x} content_len={d} viewport_cols={d} comment_x={d} box_width={d}", .{ @intFromPtr(comment), comment.content.items.len, self.viewport_cols, comment_x, comment_box_width });
    try comment.rebuildDisplayLines(self.alloc, comment_box_width);

    for (comment.display_lines.items, 0..) |*comment_display_line, i| {
        log.info("generated comment display line comment_ptr=0x{x} local_idx={d} targetable={} bytes={d} display_width={d} content='{s}'", .{ @intFromPtr(comment), i, comment_display_line.targetable, comment_display_line.content.len, util.displayWidth(comment_display_line.content), comment_display_line.content });
        try self.display_lines.append(.{ .comments = .{
            .line_idx = i,
            .comment = comment,
        } });
    }
}

fn rebuildDisplayLinesAfterEditing(self: *Self) !void {
    const log = std.log.scoped(.diff_window);
    const before_len = self.display_lines.len();
    const edit_state = switch (self.state.*) {
        .editing => |editing| editing,
        else => return,
    };

    try self.patchDisplayLinesForEditedComment(edit_state);
    log.info("patch after editing display_lines before={d} after={d}", .{ before_len, self.display_lines.len() });
    try self.syncEditingCursor();
    self.display_dirty = true;
}

fn patchDisplayLinesForEditedComment(self: *Self, edit_state: State.EditState) !void {
    switch (edit_state) {
        .normal => |editing| {
            const first_display_line = editing.first_display_line;
            const comment = editing.comment;

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
                const removed = try self.display_lines.removeFromIndexRange(self.alloc, first_display_line + new_len, first_display_line + old_len - 1);
                defer self.alloc.free(removed);
            }
        },

        .deletion => |deletion| {
            const first_display_line = deletion.first_display_line;
            const comment_height = deletion.comment_rows;
            const removed = try self.display_lines.removeFromIndexRange(self.alloc, first_display_line, first_display_line + comment_height - 1);
            defer self.alloc.free(removed);
        },
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

fn refreshEditingDisplayLineAfterRebuild(self: *Self) void {
    switch (self.state.*) {
        .editing => |*edit_state| switch (edit_state.*) {
            .normal => |*editing| {
                editing.first_display_line = self.firstDisplayLineForComment(editing.comment) orelse editing.first_display_line;
            },
            .deletion => {},
        },
        else => {},
    }
}

fn firstDisplayLineForComment(self: *Self, comment: *const Comments.Comment) ?usize {
    var idx: usize = 0;
    while (idx < self.display_lines.len()) : (idx += 1) {
        const line = self.display_lines.getPtr(idx) orelse return null;
        switch (line.*) {
            .comments => |comment_line| if (comment_line.comment == comment) return idx,
            else => {},
        }
    }
    return null;
}

fn syncEditingCursor(self: *Self) !void {
    const edit_state = switch (self.state.*) {
        .editing => |editing| editing,
        else => return,
    };

    const editing = switch (edit_state) {
        .normal => |editing| editing,
        .deletion => {
            if (self.cursor) |*cursor| try cursor.hide();
            return;
        },
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
        indicator.hide();
    }
}

const SelectionDirection = enum { up, down, page_up, page_down };

fn moveSelectionFocus(self: *Self, direction: SelectionDirection) !bool {
    const indicator = &(self.line_indicator orelse return false);
    const controlled_viewport_idx = indicator.currentControlledIndex() orelse return false;

    const old_top_line = self.top_line;
    self.focus_line = self.top_line +| controlled_viewport_idx -| 1;

    const moved = switch (direction) {
        .up => self.moveFocusUp(),
        .down => self.moveFocusDown(),
        .page_up => self.moveFocusPageUp(),
        .page_down => self.moveFocusPageDown(),
    };
    if (!moved) return false;

    const new_viewport_idx = self.focus_line -| self.top_line + 1;
    const scroll_delta: isize = @as(isize, @intCast(old_top_line)) - @as(isize, @intCast(self.top_line));
    indicator.setVisualControlledIndex(new_viewport_idx, scroll_delta);
    indicator.unhide();
    return true;
}

fn syncLineIndicatorToFocus(self: *Self) !void {
    if (self.state.* == .editing) return;
    const indicator = &(self.line_indicator orelse return);
    const indicator_y: c_int = @intCast((self.focus_line -| if (self.diff != null) self.top_line else 0) + 1);
    try indicator.move(indicator_y);
    indicator.unhide();
}

fn ensurePlane(self: *Self, render_ctx: *const RenderCtx) !struct {
    main_plane: *c.ncplane,
    sub_plane: *c.ncplane,
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

    // 1 for the border, 1 for the detail bar
    const sub_rows = if (rows >= 3) rows - 3 else rows;
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

    return .{
        .sub_plane = self.sub_plane.?,
        .main_plane = self.main_plane.?,
    };
}

fn drawBorder(plane: *c.ncplane, active_file_name: ?[]const u8, space_to_leave_at_bottom: usize) !void {
    c.ncplane_erase(plane);

    var rows: c_uint = 0;
    var cols: c_uint = 0;
    c.ncplane_dim_yx(plane, &rows, &cols);
    if (rows < 2 or cols < 2) return;

    const last_y: c_int = @intCast(rows - space_to_leave_at_bottom - 1);
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

//! This is the base component for the app and will always be spawned first at
//! the bottom and only at the bottom of the stack.
const std = @import("std");

const util = @import("../util/root.zig");
const assets = @import("../assets/assets.zig");
const c = util.c;
const protocol = @import("../protocol.zig");

const InputEvent = protocol.InputEvent;
const Input = protocol.Input;
const FrameTime = protocol.FrameTime;
const Conclusion = protocol.Conclusion;
const RenderCtx = protocol.RenderCtx;

const Component = @import("Component.zig");
const DiffWindow = @import("diff_window/root.zig").DiffWindow;
const Backend = @import("../App.zig").Backend;
const Bucket = util.LeakyBucket(Input);
const Gif = @import("Gif.zig");

const Self = @This();
const HistoryEntry = struct {
    id: []const u8,
    subject: []const u8,
};

alloc: std.mem.Allocator,
io: std.Io,
input_bucket: Bucket,
history: []u8,
entries: std.ArrayList(HistoryEntry),
selected: usize = 0,
scroll_top: usize = 0,
backend: Backend,
initial_render_done: bool = false,
hidden: bool = false,
hiding: bool = false,
gif: ?Gif = null,

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
                    if (!self_typed.initial_render_done) return true;
                    return if (self_typed.gif) |gif| !gif.hidden and gif.dirty else false;
                }
            }.isDirty,

            .key_handler = struct {
                pub fn handleInput(ptr: *anyopaque, event: InputEvent, render_ctx: *const RenderCtx) !Conclusion {
                    const input = switch (event) {
                        .input => |input| input,
                        .timeout => return .Noop,
                    };
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    return try @call(.always_inline, handleInputEvent, .{ self_typed, input, render_ctx });
                }
            }.handleInput,

            .update = struct {
                pub fn _update(ptr: *anyopaque, ft: FrameTime, render_ctx: *const RenderCtx) !Conclusion {
                    _ = render_ctx;
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    return try @call(.always_inline, update, .{ self_typed, ft });
                }
            }._update,

            .next_update_time = struct {
                pub fn updateInterval(ptr: *anyopaque, frame_time: FrameTime) i64 {
                    _ = frame_time;
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    if (self_typed.gif) |*gif| {
                        if (!self_typed.hidden and !gif.hidden) return gif.updateInterval() orelse 1000;
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

            .clean_up = struct {
                pub fn cleanUp(ptr: *anyopaque) !void {
                    const self_typed: *Self = @ptrCast(@alignCast(ptr));
                    deinit(self_typed);
                    self_typed.alloc.destroy(self_typed);
                }
            }.cleanUp,
        },
    };
}

pub fn deinit(self: *Self) void {
    if (self.gif) |*gif| gif.deinit();
    self.entries.deinit(self.alloc);
    self.alloc.free(self.history);
}

pub fn init(alloc: std.mem.Allocator, io: std.Io, backend: Backend) !Self {
    const argv: []const []const u8 = switch (backend) {
        .jj => &.{ "jj", "log", "--no-graph", "--color=never", "--no-pager", "-r", "ancestors(@, 64) ~ root()", "-T", "commit_id ++ \"\\t\" ++ coalesce(description.first_line(), \"(no description set)\") ++ \"\\n\"" },
        .git => &.{ "git", "log", "--no-color", "--max-count=64", "--format=%H%x09%s", "HEAD" },
    };
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer alloc.free(result.stderr);

    const history: []u8 = if (result.term != .exited or result.term.exited != 0) history: {
        alloc.free(result.stdout);
        if (backend != .git) return error.HistoryCommandFailed;
        // An unborn Git repository has no HEAD to list yet.
        const head = try std.process.run(alloc, io, .{
            .argv = &.{ "git", "rev-parse", "--verify", "HEAD" },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        });
        defer alloc.free(head.stdout);
        defer alloc.free(head.stderr);
        if (head.term == .exited and head.term.exited != 0) {
            break :history try alloc.dupe(u8, "");
        }
        return error.HistoryCommandFailed;
    } else result.stdout;
    errdefer alloc.free(history);

    var entries: std.ArrayList(HistoryEntry) = .empty;
    errdefer entries.deinit(alloc);
    var lines = std.mem.splitScalar(u8, history, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (separator == 0) continue;
        try entries.append(alloc, .{ .id = line[0..separator], .subject = line[separator + 1 ..] });
    }

    return .{
        .alloc = alloc,
        .io = io,
        .input_bucket = Bucket.init(.{}),
        .history = history,
        .entries = entries,
        .backend = backend,
    };
}

pub fn handleInputEvent(self: *Self, input_event: Input, render_ctx: *const RenderCtx) !Conclusion {
    if (self.hidden or input_event.ncinput.evtype == c.NCTYPE_RELEASE) {
        return .Noop;
    }

    const key = input_event.key;

    switch (key) {
        'q' => return .Quit,

        'j', c.NCKEY_DOWN, 'k', c.NCKEY_UP => {
            self.input_bucket.clear();
            if (key == 'j' or key == c.NCKEY_DOWN) {
                if (self.selected + 1 < self.entries.items.len) self.selected += 1;
            } else if (self.selected > 0) {
                self.selected -= 1;
            }
            const visible_rows: usize = @intCast(render_ctx.term_rows -| 10);
            if (visible_rows > 0 and self.selected >= self.scroll_top + visible_rows) {
                self.scroll_top = self.selected - visible_rows + 1;
            } else if (self.selected < self.scroll_top) {
                self.scroll_top = self.selected;
            }
            self.initial_render_done = false;
            return .Claimed;
        },

        c.NCKEY_ENTER, '\r', '\n' => {
            self.input_bucket.clear();
            if (self.entries.items.len == 0) return .Claimed;
            const id = self.entries.items[self.selected].id;
            const argv: []const []const u8 = switch (self.backend) {
                .jj => &.{ "jj", "diff", "-r", id, "--tool=:git", "--color=never" },
                .git => &.{ "git", "show", "--format=", "--first-parent", "-m", "--no-ext-diff", "--no-color", id },
            };
            return try self.openDiff(render_ctx, argv);
        },

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

            var last_relevant_evt: ?*Input = null;
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
                    const argv: []const []const u8 = switch (self.backend) {
                        .jj => &.{ "jj", "diff", "--tool=:git", "--color", "never" },
                        .git => &.{ "git", "diff", "HEAD", "--no-ext-diff", "--no-color" },
                    };
                    return try self.openDiff(render_ctx, argv);
                }
            }
        },
    }

    return .Noop;
}

fn openDiff(self: *Self, render_ctx: *const RenderCtx, argv: []const []const u8) !Conclusion {
    const diff_window = try self.alloc.create(DiffWindow);
    errdefer self.alloc.destroy(diff_window);
    diff_window.* = try DiffWindow.init(self.alloc, self.io, render_ctx, argv);
    self.hiding = true;
    return .{ .Mount = .{ .component = diff_window.initInterface(), .hide = true } };
}

pub fn render(self: *Self, render_ctx: *const RenderCtx) !void {
    const nc_ctx = render_ctx.nc_ctx;

    if (self.hidden and !self.hiding) return;

    const stdplane = c.notcurses_stdplane(nc_ctx) orelse return error.NoStdplane;
    if (self.hiding) {
        self.hiding = false;
        c.ncplane_erase(stdplane);
        if (self.gif) |*gif| {
            if (!gif.hidden) try gif.hide();
        }
        return;
    }
    if (!self.initial_render_done) {
        var rows: c_uint = 0;
        var cols: c_uint = 0;
        c.ncplane_dim_yx(stdplane, &rows, &cols);
        c.ncplane_erase(stdplane);
        c.ncplane_set_bg_default(stdplane);
        if (rows == 0 or cols == 0) return;

        const show_cat = rows >= 24 and cols >= 72;
        if (show_cat) {
            if (self.gif == null) {
                self.gif = try Gif.init(nc_ctx, stdplane, .{
                    .height = 20,
                    .asset = .{ .name = "scuba-scuba-cat.gif", .bytes = assets.splash_screen },
                });
            }
            const gif = &self.gif.?;
            if (gif.hidden) gif.unhide();
            try gif.move(1, @intCast(cols - c.ncplane_dim_x(gif.plane) - 2));
        } else if (self.gif) |*gif| {
            if (!gif.hidden) try gif.hide();
        }
        const content_cols = if (show_cat) cols - c.ncplane_dim_x(self.gif.?.plane) - 4 else cols;

        c.ncplane_set_styles(stdplane, c.NCSTYLE_BOLD);
        if (c.ncplane_set_fg_rgb8(stdplane, 0x85, 0xd7, 0xff) < 0) return error.SetColorFailed;
        try putClipped(stdplane, 1, 3, content_cols, if (self.backend == .jj) "ddf  /  jj" else "ddf  /  git");

        c.ncplane_set_styles(stdplane, c.NCSTYLE_NONE);
        if (c.ncplane_set_fg_rgb8(stdplane, 0x88, 0x88, 0x88) < 0) return error.SetColorFailed;
        try putClipped(stdplane, 3, 3, content_cols, "Review working tree and history");

        if (c.ncplane_set_fg_rgb8(stdplane, 0xff, 0xd8, 0x66) < 0) return error.SetColorFailed;
        try putClipped(stdplane, 5, 3, content_cols, if (self.backend == .jj) "RECENT REVISIONS  /  @ to ancestors" else "RECENT COMMITS  /  HEAD to ancestors");

        const visible_rows: usize = @intCast(rows -| 10);
        if (visible_rows > 0 and self.selected >= self.scroll_top + visible_rows) {
            self.scroll_top = self.selected - visible_rows + 1;
        }
        var row: c_uint = 7;
        var index: usize = self.scroll_top;
        while (row < rows -| 3 and index < self.entries.items.len) : ({
            row += 1;
            index += 1;
        }) {
            const entry = self.entries.items[index];
            const is_selected = index == self.selected;
            if (is_selected) {
                c.ncplane_set_styles(stdplane, c.NCSTYLE_BOLD);
                if (c.ncplane_set_fg_rgb8(stdplane, 0xff, 0xd8, 0x66) < 0) return error.SetColorFailed;
                try putClipped(stdplane, @intCast(row), 1, content_cols, ">");
            }

            if (index == 0) {
                c.ncplane_set_styles(stdplane, c.NCSTYLE_BOLD);
                if (c.ncplane_set_fg_rgb8(stdplane, 0x85, 0xd7, 0xff) < 0) return error.SetColorFailed;
                try putClipped(stdplane, @intCast(row), 3, content_cols, if (self.backend == .jj) "@" else "HEAD");
            } else {
                c.ncplane_set_styles(stdplane, c.NCSTYLE_NONE);
                if (c.ncplane_set_fg_rgb8(stdplane, 0x88, 0x88, 0x88) < 0) return error.SetColorFailed;
                try putClipped(stdplane, @intCast(row), 3, content_cols, "  |");
            }
            if (is_selected) {
                c.ncplane_set_styles(stdplane, c.NCSTYLE_BOLD);
                if (c.ncplane_set_fg_rgb8(stdplane, 0xff, 0xd8, 0x66) < 0) return error.SetColorFailed;
            }
            try putClipped(stdplane, @intCast(row), 10, content_cols, entry.id[0..@min(8, entry.id.len)]);
            if (!is_selected and c.ncplane_set_fg_rgb8(stdplane, 0xeb, 0xdb, 0xb2) < 0) return error.SetColorFailed;
            try putClipped(stdplane, @intCast(row), 20, content_cols, entry.subject);
        }

        if (self.entries.items.len == 0) {
            if (c.ncplane_set_fg_rgb8(stdplane, 0x88, 0x88, 0x88) < 0) return error.SetColorFailed;
            try putClipped(stdplane, 7, 3, content_cols, "No commits yet");
        }

        c.ncplane_set_styles(stdplane, c.NCSTYLE_NONE);
        if (c.ncplane_set_fg_rgb8(stdplane, 0xff, 0xd8, 0x66) < 0) return error.SetColorFailed;
        if (cols < 65 and rows >= 12) try putClipped(stdplane, @intCast(rows - 2), 3, cols, "Space d f  working tree diff");
        try putClipped(stdplane, @intCast(rows - 1), 3, cols, if (cols < 65) "j/k select  Enter diff  q quit" else "j/k select  Enter commit diff  Space d f working tree diff  q quit");
        self.initial_render_done = true;
    }

    if (self.gif) |*gif| try gif.render(nc_ctx);
}

pub fn update(self: *Self, ft: FrameTime) !Conclusion {
    if (self.hidden) return .Noop;
    if (self.gif) |*gif| {
        if (!gif.hidden) return try gif.update(ft);
    }
    return .Noop;
}

pub fn wake(self: *Self) !void {
    self.hidden = false;
    self.hiding = false;
    self.initial_render_done = false;
    self.input_bucket.clear();
}

pub fn hide(self: *Self) !void {
    self.hidden = true;
    self.hiding = true;
    self.input_bucket.clear();
}

fn putClipped(plane: *c.ncplane, y: c_int, x: c_uint, cols: c_uint, text: []const u8) !void {
    if (x >= cols) return;
    var rows: c_uint = 0;
    var width: c_uint = 0;
    c.ncplane_dim_yx(plane, &rows, &width);
    if (y < 0 or y >= rows) return;
    const clipped = util.clipToDisplayWidth(text, cols - x);
    if (clipped.len == 0) return;
    if (c.ncplane_putnstr_yx(plane, y, @intCast(x), clipped.len, clipped.ptr) < 0) {
        return error.PutStrFailed;
    }
}

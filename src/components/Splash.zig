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

alloc: std.mem.Allocator,
io: std.Io,
input_bucket: Bucket,
history: []u8,
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
    self.alloc.free(self.history);
}

pub fn init(alloc: std.mem.Allocator, io: std.Io, backend: Backend) !Self {
    const argv: []const []const u8 = switch (backend) {
        .jj => &.{ "jj", "log", "--no-graph", "--color=never", "--no-pager", "-r", "ancestors(@, 64) ~ root()", "-T", "commit_id.short(8) ++ \"\\t\" ++ coalesce(description.first_line(), \"(no description set)\") ++ \"\\n\"" },
        .git => &.{ "git", "log", "--no-color", "--max-count=64", "--format=%h%x09%s", "HEAD" },
    };
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer alloc.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
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
            return .{ .alloc = alloc, .io = io, .backend = backend, .input_bucket = Bucket.init(.{}), .history = try alloc.dupe(u8, "") };
        }
        return error.HistoryCommandFailed;
    }

    return .{
        .alloc = alloc,
        .io = io,
        .input_bucket = Bucket.init(.{}),
        .history = result.stdout,
        .backend = backend,
    };
}

pub fn handleInputEvent(self: *Self, input_event: Input, render_ctx: *const RenderCtx) !Conclusion {
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
                    const diff_window = try self.alloc.create(DiffWindow);
                    errdefer self.alloc.destroy(diff_window);
                    const argv: []const []const u8 = switch (self.backend) {
                        .jj => &.{ "jj", "diff", "--tool=:git", "--color", "never" },
                        .git => &.{ "git", "diff", "HEAD", "--no-ext-diff", "--no-color" },
                    };
                    diff_window.* = try DiffWindow.init(self.alloc, self.io, render_ctx, argv);

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

        var commits = std.mem.splitScalar(u8, self.history, '\n');
        var row: c_uint = 7;
        var index: usize = 0;
        while (row < rows -| 3) : (row += 1) {
            const line = commits.next() orelse break;
            if (line.len == 0) break;
            const separator = std.mem.indexOfScalar(u8, line, '\t') orelse continue;

            if (index == 0) {
                c.ncplane_set_styles(stdplane, c.NCSTYLE_BOLD);
                if (c.ncplane_set_fg_rgb8(stdplane, 0x85, 0xd7, 0xff) < 0) return error.SetColorFailed;
                try putClipped(stdplane, @intCast(row), 3, content_cols, if (self.backend == .jj) "@" else "HEAD");
            } else {
                c.ncplane_set_styles(stdplane, c.NCSTYLE_NONE);
                if (c.ncplane_set_fg_rgb8(stdplane, 0x88, 0x88, 0x88) < 0) return error.SetColorFailed;
                try putClipped(stdplane, @intCast(row), 3, content_cols, "  |");
            }
            try putClipped(stdplane, @intCast(row), 10, content_cols, line[0..separator]);
            if (c.ncplane_set_fg_rgb8(stdplane, 0xeb, 0xdb, 0xb2) < 0) return error.SetColorFailed;
            try putClipped(stdplane, @intCast(row), 20, content_cols, line[separator + 1 ..]);
            index += 1;
        }

        if (index == 0 and self.history.len == 0) {
            if (c.ncplane_set_fg_rgb8(stdplane, 0x88, 0x88, 0x88) < 0) return error.SetColorFailed;
            try putClipped(stdplane, 7, 3, content_cols, "No commits yet");
        }

        c.ncplane_set_styles(stdplane, c.NCSTYLE_NONE);
        if (c.ncplane_set_fg_rgb8(stdplane, 0xff, 0xd8, 0x66) < 0) return error.SetColorFailed;
        try putClipped(stdplane, @intCast(rows - 1), 3, cols, if (cols < 65) "Space d f  diff    q  quit" else "Space d f  working tree diff     q  quit");
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

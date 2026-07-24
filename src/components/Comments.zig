const std = @import("std");

const util = @import("../util.zig");
const c = util.c;
const Gif = @import("Gif.zig");
const LineId = @import("../protocol.zig").LineId;

const Self = @This();

pub const Comment = struct {
    const CommentSelf = @This();

    line_id: LineId,
    content: std.ArrayList(u8) = .empty,

    pub fn init(line_id: LineId) Comment {
        return .{
            .line_id = line_id,
        };
    }

    pub fn deinit(self: *Comment, alloc: std.mem.Allocator) void {
        self.content.deinit(alloc);
    }

    pub fn appendContent(
        self: *Comment,
        alloc: std.mem.Allocator,
        incoming: []u8,
    ) !void {
        try self.content.appendSlice(alloc, incoming);
    }

    pub fn removeContent(self: *Comment, len: usize) !void {
        const content = &self.content;
        if (content.items.len < len) return;
        content.items.len -= len;
    }

    pub fn formattedMessage(self: Comment, alloc: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        var temp_buf: [1024]u8 = undefined;

        const line_numbers = &self.line_id.line_numbers;
        const start = line_numbers.@"0";
        const end = line_numbers.@"1";
        const file_path = self.line_id.file_path;

        const written_slice = if (end) |end_|
            try std.fmt.bufPrint(&temp_buf, "Comment on line {d} to {d} in {s}: ", .{ start, end_, file_path })
        else
            try std.fmt.bufPrint(&temp_buf, "Comment on line {d} in {s}: ", .{ start, file_path });

        try buf.appendSlice(alloc, "\n\n");
        try buf.appendSlice(alloc, written_slice);
        try buf.append(alloc, '\n');
        try buf.appendSlice(alloc, &self.content.items);
    }

    /// A border is drawn around the content.
    /// The content is line wrapped.
    pub fn toDisplayLines(
        self: CommentSelf,
        alloc: std.mem.Allocator,
        width: c_uint,
        buf: *std.ArrayList(DisplayLine),
    ) !void {
        if (width < 2) return error.WidthTooSmall;

        const total_width: usize = @intCast(width);
        const inner_width = total_width - 2;

        try buf.append(alloc, .{
            .content = try borderLine(alloc, "┌", "─", "┐", inner_width),
            .targetable = false,
        });

        if (self.content.items.len == 0) {
            try buf.append(alloc, .{
                .content = try contentLine(alloc, "", inner_width),
                .targetable = true,
            });
        } else {
            var physical_lines = std.mem.splitScalar(u8, self.content.items, '\n');
            while (physical_lines.next()) |physical_line| {
                var remaining = physical_line;

                if (remaining.len == 0) {
                    try buf.append(alloc, .{
                        .content = try contentLine(alloc, "", inner_width),
                        .targetable = true,
                    });
                    continue;
                }

                while (remaining.len > 0) {
                    const wrapped = util.wrapLine(remaining, @intCast(inner_width));
                    const end = wrapped.end orelse remaining.len;

                    try buf.append(alloc, .{
                        .content = try contentLine(alloc, remaining[0..end], inner_width),
                        .targetable = true,
                    });

                    remaining = remaining[end..];
                }
            }
        }

        try buf.append(alloc, .{
            .content = try borderLine(alloc, "└", "─", "┘", inner_width),
            .targetable = false,
        });
    }

    fn borderLine(
        alloc: std.mem.Allocator,
        left: []const u8,
        fill: []const u8,
        right: []const u8,
        inner_width: usize,
    ) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);

        try buf.appendSlice(alloc, left);
        for (0..inner_width) |_| try buf.appendSlice(alloc, fill);
        try buf.appendSlice(alloc, right);

        return try buf.toOwnedSlice(alloc);
    }

    fn contentLine(alloc: std.mem.Allocator, content: []const u8, inner_width: usize) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);

        try buf.appendSlice(alloc, "│");
        try buf.appendSlice(alloc, content);

        const content_width = displayWidth(content);
        if (content_width < inner_width) {
            try buf.appendNTimes(alloc, ' ', inner_width - content_width);
        }

        try buf.appendSlice(alloc, "│");

        return try buf.toOwnedSlice(alloc);
    }

    fn displayWidth(content: []const u8) usize {
        return util.wrapLine(content, std.math.maxInt(c_uint)).display_width;
    }
};

/// Claims ownership of the content slices
/// Owner of DisplayLine is responsible for freeing it
pub const DisplayLine = struct {
    content: []const u8,
    targetable: bool,

    pub fn deinit(self: DisplayLine, alloc: std.mem.Allocator) void {
        alloc.free(self.content);
    }
};

pub const Opts = struct {
    cursor_gif_name: []const u8,
    parent_plane: *c.ncplane,
};

/// This is really the cursor. This component owns the lifecycle of this Gif
/// end to end, including the plane on which it is rendered on.
gif: ?Gif = null,
// Current problems (doodle, delete later):
// - Relate a Comment to a DiffWindow.DisplayLine (this one is not so important)
// - Relate a DiffWindow.DisplayLine to Comment (so we know how to splice it)
// - Ensure this relationship survives resizes
// - Ensure this relationship survives splices (i.e. during comment addition)
//
// During resize or comments addition / removal, the array of
// DiffWindow.DisplayLine gets reconstructed. Its indices consequently considered
// unstable. For that reason we cannot use its indices as anchor to maintain
// the aforementioned relationship.
//
// At the time of writing, there is no partial rebuild of the array of
// DiffWindow.DisplayLine. Every time there is a change the entire array of
// DiffWindow.DisplayLine would be flushed and rebuilt.
// A reasonable (and perhaps naive) approach here would be the following:
// - As we are rebuilding the array of DiffWindow.DisplayLine, we have a stack of Comments
// - For each DiffWindow.DisplayLine, we check to see if it is related to the top of the stack
// - If it is, we append it to DiffWindow.DisplayLine
//
// This aforementioned method requires that the order of Comments to
// DiffWindow.DisplayLine to be stable. In general, this is a safe assumption to have.
comments: std.ArrayList(Comment) = .empty,
display_lines: std.ArrayList(DisplayLine) = .empty,

pub fn init(alloc: std.mem.Allocator, nc_ctx: *c.notcurses, opts: Opts) Self {
    const gif = try Gif.init(
        nc_ctx,
        opts.parent_plane,
        .{
            .height = 1,
            .asset_name = opts.cursor_gif_name,
        },
    );

    return .{
        .gif = gif,
        .comments = .init(alloc),
    };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    if (self.gif) |*gif| {
        gif.deinit();
    }

    for (self.comments.items) |*comment| {
        comment.deinit(alloc);
    }
    self.comments.deinit(alloc);

    for (self.display_lines.items) |*display_line| {
        display_line.deinit(alloc);
    }
    self.display_lines.deinit(alloc);
}

pub fn getOrPut(self: *Self, line_number: usize) !*Comment {
    const get_or_put_res = try self.comments.getOrPut(line_number);
    return get_or_put_res.value_ptr;
}

pub fn removeComment(self: *Self, line_number: usize) bool {
    return self.comments.remove(line_number);
}

/// Caller owns the returned slice
pub fn formattedMessage(self: Self, alloc: std.mem.Allocator) !?[]const u8 {
    if (self.comments.items.len == 0) return null;

    var res: std.ArrayList(u8) = .empty;

    return try res.toOwnedSlice(alloc);
}

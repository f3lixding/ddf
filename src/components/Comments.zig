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

        const line_numbers = &self.line_id.src_line_numbers;
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

comments: std.HashMap(LineId, std.ArrayList(*Comment), LineId.Context, std.hash_map.default_max_load_percentage),
display_lines: std.ArrayList(DisplayLine) = .empty,

const SortCtx = struct {
    pub fn lessThan(ctx: @This(), a: Comment, b: Comment) bool {
        _ = ctx;

        const stable_idx_a = a.line_id.display_rank;
        const stable_idx_b = b.line_id.display_rank;

        return stable_idx_a < stable_idx_b;
    }
};

pub fn init(alloc: std.mem.Allocator) !Self {
    return .{
        .comments = .init(alloc),
    };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    var vals_iter = self.comments.valueIterator();
    while (vals_iter.next()) |val| {
        for (val.items) |comment| {
            comment.deinit(alloc);
            alloc.destroy(comment);
        }
        val.deinit(alloc);
    }
    self.comments.deinit();

    for (self.display_lines.items) |*display_line| {
        display_line.deinit(alloc);
    }
    self.display_lines.deinit(alloc);
}

pub fn newComment(self: *Self, alloc: std.mem.Allocator, line_id: LineId) !*Comment {
    const new_comment = try alloc.create(Comment);
    new_comment.* = .init(line_id);

    const res = try self.comments.getOrPut(line_id);
    if (!res.found_existing) res.value_ptr.* = .empty;
    try res.value_ptr.append(alloc, new_comment);

    return new_comment;
}

pub fn removeComment(self: *Self, alloc: std.mem.Allocator, comment_to_delete: *const Comment) bool {
    const line_id = &comment_to_delete.line_id;

    if (self.comments.get(line_id)) |*comments| {
        const found_and_deleted = for (comments.items) |comment| blk: {
            if (comment_to_delete == comment) {
                comment.deinit(alloc);
                break :blk true;
            }
        } else false;

        if (comments.items.len == 0)
            _ = self.comments.remove(line_id);

        return found_and_deleted;
    }

    return false;
}

/// Caller owns the memory
pub fn sortedComments(self: *Self, alloc: std.mem.Allocator) ![]*Comment {
    const Map = @TypeOf(self.comments);
    const Entry = Map.Entry;

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(alloc);

    var it = self.comments.iterator();
    while (it.next()) |entry| {
        try entries.append(alloc, entry);
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return LineId.Context.lessThan({}, a.key_ptr.*, b.key_ptr.*);
        }
    }.lessThan);

    var res: std.ArrayList(*Comment) = .empty;
    for (entries.items) |entry| {
        const lines = entry.value_ptr;
        for (lines.items) |comment| {
            try res.append(alloc, comment);
        }
    }

    return try res.toOwnedSlice(alloc);
}

/// Caller owns the returned slice
pub fn formattedMessage(self: Self, alloc: std.mem.Allocator) !?[]const u8 {
    if (self.comments.items.len == 0) return null;

    var res: std.ArrayList(u8) = .empty;

    for (self.comments.items) |*comment| {
        try comment.formattedMessage(alloc, &res);
    }

    return try res.toOwnedSlice(alloc);
}

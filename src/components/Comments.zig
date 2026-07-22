const std = @import("std");

const util = @import("../util.zig");
const c = util.c;
const Gif = @import("Gif.zig");

const Self = @This();

const Comment = struct {
    line_number: usize = 0,
    content: std.ArrayList(u8) = .empty,

    pub fn init(line_number: usize) Comment {
        return .{
            .line_number = line_number,
        };
    }

    pub fn deinit(self: *Comment, alloc: std.mem.Allocator) void {
        self.content.deinit(alloc);
    }
};

pub const DisplayLine = struct {};

pub const Opts = struct {
    cursor_gif_name: []const u8,
    parent_plane: *c.ncplane,
};

/// This is really the cursor
gif: ?Gif = null,
comments: std.AutoHashMap(usize, Comment),
display_lines: std.ArrayList(DisplayLine) = .empty,

pub fn init(alloc: std.mem.Allocator, opts: Opts) Self {
    _ = opts;
    return .{ .comments = .init(alloc) };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    var map_iter = self.comments.valueIterator();
    while (map_iter.next()) |comment| {
        comment.deinit(alloc);
    }
    self.comments.deinit();

    self.display_lines.deinit(alloc);
}

pub fn getOrPut(self: *Self, line_number: usize) !*Comment {
    const get_or_put_res = try self.comments.getOrPut(line_number);
    return get_or_put_res.value_ptr;
}

pub fn removeComment(self: *Self, line_number: usize) bool {
    return self.comments.remove(line_number);
}

pub fn render(self: Self, nc_ctx: *c.notcurses) !void {
    _ = self;
    _ = nc_ctx;
}

pub fn isDirty(self: Self) bool {
    _ = self;
}

pub fn formattedMessage(self: Self) ?[]const u8 {
    _ = self;
}

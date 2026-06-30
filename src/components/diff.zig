const std = @import("std");
const log = std.log.scoped(.diff);

const startsWith = std.mem.startsWith;

pub const Diff = struct {
    files: []FileDiff,

    pub fn init(alloc: std.mem.Allocator, input: []const u8) !Diff {
        var lines = std.mem.splitScalar(u8, input, '\n');
        var files: std.ArrayList(FileDiff) = .empty;

        while (lines.next()) |line| {
            std.debug.print("line: {s}\n", .{line});
            if (!startsWith(u8, line, "diff")) {
                return error.MalformedDiff;
            }

            var buf: std.ArrayList([]const u8) = .empty;
            try buf.append(alloc, line);

            var file_diff: FileDiff = undefined;

            // Parsing meta
            while (true) {
                const peek = lines.peek() orelse break;

                if (startsWith(u8, peek, "@@")) {
                    const slice = try buf.toOwnedSlice(alloc);
                    defer alloc.free(slice);
                    const meta = try parseMeta(slice);

                    file_diff.old_path = meta.old_path;
                    file_diff.new_path = meta.new_path;

                    _ = lines.next();

                    break;
                } else if (startsWith(u8, peek, "diff")) {
                    break;
                }

                const next_line = lines.next().?;
                try buf.append(alloc, next_line);
            }

            // Parse hunks
            var hunks: std.ArrayList(Hunk) = .empty;

            while (true) {
                const peek = lines.peek();

                if (peek == null or startsWith(u8, peek.?, "@@")) {
                    _ = lines.next();
                    if (buf.items.len > 0) {
                        const slice = try buf.toOwnedSlice(alloc);
                        defer alloc.free(slice);

                        const hunk = try parseHunk(alloc, slice);
                        try hunks.append(alloc, hunk);
                    }
                } else if (startsWith(u8, peek.?, "diff")) {
                    break;
                }

                const next_line = lines.next() orelse break;
                try buf.append(alloc, next_line);
            }

            file_diff.hunks = try hunks.toOwnedSlice(alloc);

            try files.append(alloc, file_diff);
        }

        return .{
            .files = try files.toOwnedSlice(alloc),
        };
    }

    // TODO: refine param list
    pub fn render(self: Diff) void {
        _ = self;
    }

    pub fn deinit(self: Diff, alloc: std.mem.Allocator) void {
        for (self.files) |file| {
            file.deinit(alloc);
        }
        alloc.free(self.files);
    }
};

pub const FileDiff = struct {
    old_path: []const u8,
    new_path: []const u8,
    hunks: []Hunk,

    // TODO: refine param list
    pub fn render(self: FileDiff) void {
        _ = self;
    }

    pub fn deinit(self: FileDiff, alloc: std.mem.Allocator) void {
        for (self.hunks) |hunk| {
            hunk.deinit(alloc);
        }
        alloc.free(self.hunks);
    }
};

pub const Hunk = struct {
    // TODO: actually parse these info
    old_start: usize = 0,
    old_len: usize = 0,
    new_start: usize = 0,
    new_len: usize = 0,
    lines: []DiffLine,

    // TODO: refine param list
    pub fn render(self: Hunk) void {
        _ = self;
    }

    pub fn deinit(self: Hunk, alloc: std.mem.Allocator) void {
        alloc.free(self.lines);
    }
};

pub const DiffLine = union(enum) {
    context: []const u8,
    add: []const u8,
    remove: []const u8,

    // TODO: refine param list
    pub fn render(self: DiffLine) void {
        _ = self;
    }
};

/// Does NOT copy
fn parseMeta(inputs: [][]const u8) !struct { old_path: []const u8, new_path: []const u8 } {
    std.debug.assert(inputs.len > 0);

    const first_line = inputs[0];
    var iter = std.mem.splitBackwardsAny(u8, first_line, " ");

    const new_path = iter.next() orelse return error.MalformedMetaInput;
    const old_path = iter.next() orelse return error.MalformedMetaInput;

    return .{
        .old_path = old_path,
        .new_path = new_path,
    };
}

/// DOES copy
fn parseHunk(alloc: std.mem.Allocator, inputs: [][]const u8) !Hunk {
    std.debug.assert(inputs.len > 0);

    var lines: std.ArrayList(DiffLine) = .empty;

    for (inputs) |input| {
        var line: DiffLine = undefined;

        if (startsWith(u8, input, " ")) {
            line = .{ .context = input };
        } else if (startsWith(u8, input, "-")) {
            line = .{ .remove = input };
        } else if (startsWith(u8, input, "+")) {
            line = .{ .add = input };
        } else {
            log.err("Unknown line encountered. Skipping", .{});
            continue;
        }

        try lines.append(alloc, line);
    }

    return .{
        .lines = try lines.toOwnedSlice(alloc),
    };
}

test "parseMeta extracts old and new paths from diff header" {
    var inputs = [_][]const u8{
        "diff --git a/src/components/DiffWindow.zig b/src/components/DiffWindow.zig",
        "index 95a0b682a7..dc2be24e5f 100644",
        "--- a/src/components/DiffWindow.zig",
        "+++ b/src/components/DiffWindow.zig",
    };

    const meta = try parseMeta(&inputs);

    try std.testing.expectEqualStrings("a/src/components/DiffWindow.zig", meta.old_path);
    try std.testing.expectEqualStrings("b/src/components/DiffWindow.zig", meta.new_path);
}

test "parseHunk classifies context add and remove lines" {
    const alloc = std.testing.allocator;

    const context = " const std = @import(\"std\");";
    const add = "+const util = @import(\"../util.zig\");";
    const remove = "-const old = @import(\"old.zig\");";
    var inputs = [_][]const u8{ context, add, remove };

    const hunk = try parseHunk(alloc, &inputs);
    defer hunk.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), hunk.lines.len);
    try std.testing.expectEqualStrings(" const std = @import(\"std\");", hunk.lines[0].context);
    try std.testing.expectEqualStrings("+const util = @import(\"../util.zig\");", hunk.lines[1].add);
    try std.testing.expectEqualStrings("-const old = @import(\"old.zig\");", hunk.lines[2].remove);
}

test "Diff.init parses a single file diff" {
    const input =
        \\diff --git a/src/components/DiffWindow.zig b/src/components/DiffWindow.zig
        \\index 95a0b682a7..dc2be24e5f 100644
        \\--- a/src/components/DiffWindow.zig
        \\+++ b/src/components/DiffWindow.zig
        \\@@ -1,1 +1,3 @@
        \\ const std = @import("std");
        \\+const util = @import("../util.zig");
        \\-const old = @import("old.zig");
        \\
    ;

    const alloc = std.testing.allocator;
    const diff = try Diff.init(alloc, input);
    defer diff.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), diff.files.len);
    try std.testing.expectEqualStrings("a/src/components/DiffWindow.zig", diff.files[0].old_path);
    try std.testing.expectEqualStrings("b/src/components/DiffWindow.zig", diff.files[0].new_path);

    try std.testing.expectEqual(@as(usize, 1), diff.files[0].hunks.len);
    try std.testing.expectEqual(@as(usize, 3), diff.files[0].hunks[0].lines.len);
    try std.testing.expectEqualStrings(" const std = @import(\"std\");", diff.files[0].hunks[0].lines[0].context);
    try std.testing.expectEqualStrings("+const util = @import(\"../util.zig\");", diff.files[0].hunks[0].lines[1].add);
    try std.testing.expectEqualStrings("-const old = @import(\"old.zig\");", diff.files[0].hunks[0].lines[2].remove);
}

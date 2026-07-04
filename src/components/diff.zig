const std = @import("std");
const log = std.log.scoped(.diff);

const util = @import("../util.zig");
const c = util.c;

const startsWith = std.mem.startsWith;

pub const Diff = struct {
    files: []FileDiff,
    display_lines: std.ArrayList(DisplayLine),
    top_line: usize = 0,
    width: c_uint,
    widest: c_uint,
    did_wrap: bool,
    alloc: std.mem.Allocator,

    /// The caller needs to ensure the input stays intact until deinit is
    /// called. The construction of Diff as well as its children makes no
    /// attempt to copy the underlying slices
    pub fn init(
        alloc: std.mem.Allocator,
        input: []const u8,
        width: c_uint,
    ) !Diff {
        var lines = std.mem.splitScalar(u8, input, '\n');
        var files: std.ArrayList(FileDiff) = .empty;

        while (lines.next()) |line| {
            if (!startsWith(u8, line, "diff")) {
                return error.MalformedDiff;
            }

            var meta_buf: std.ArrayList([]const u8) = .empty;
            try meta_buf.append(alloc, line);

            var file_diff: FileDiff = undefined;

            // Parse file metadata: diff --git, index, ---, +++, etc.
            while (true) {
                const peek = lines.peek() orelse break;

                if (startsWith(u8, peek, "@@") or startsWith(u8, peek, "diff")) {
                    break;
                }

                const next_line = lines.next().?;
                try meta_buf.append(alloc, next_line);
            }

            file_diff.meta_lines = try meta_buf.toOwnedSlice(alloc);
            const meta = try parseMeta(file_diff.meta_lines);
            file_diff.old_path = meta.old_path;
            file_diff.new_path = meta.new_path;

            // Parse hunks. Each hunk owns an allocated slice of parsed line
            // descriptors, but all text points into the caller-owned input.
            var hunks: std.ArrayList(Hunk) = .empty;

            while (lines.peek()) |peek| {
                if (startsWith(u8, peek, "diff")) break;
                if (!startsWith(u8, peek, "@@")) return error.MalformedDiff;

                const hunk_header = lines.next().?;
                var hunk_buf: std.ArrayList([]const u8) = .empty;

                while (lines.peek()) |hunk_peek| {
                    if (startsWith(u8, hunk_peek, "@@") or startsWith(u8, hunk_peek, "diff")) break;
                    try hunk_buf.append(alloc, lines.next().?);
                }

                const hunk_lines = try hunk_buf.toOwnedSlice(alloc);
                defer alloc.free(hunk_lines);

                const hunk = try parseHunk(alloc, hunk_header, hunk_lines);
                try hunks.append(alloc, hunk);
            }

            file_diff.hunks = try hunks.toOwnedSlice(alloc);

            try files.append(alloc, file_diff);
        }

        var display_lines: std.ArrayList(DisplayLine) = .empty;
        var gather_result: GatherResult = .{};
        for (files.items) |file_diff| {
            gather_result.merge(try file_diff.gatherDisplayLines(alloc, &display_lines, width));
        }

        return .{
            .files = try files.toOwnedSlice(alloc),
            .display_lines = display_lines,
            .width = width,
            .widest = gather_result.widest,
            .did_wrap = gather_result.did_wrap,
            .alloc = alloc,
        };
    }

    pub fn render(
        self: Diff,
        nc_ctx: *c.notcurses,
        plane: *c.ncplane,
    ) !void {
        var rows: c_uint = 0;
        var cols: c_uint = 0;
        c.ncplane_dim_yx(plane, &rows, &cols);

        c.ncplane_erase(plane);

        const start = @min(self.top_line, self.display_lines.items.len);
        const visible_count = @min(@as(usize, rows), self.display_lines.items.len - start);

        for (self.display_lines.items[start .. start + visible_count], 0..) |line, row| {
            try line.render(nc_ctx, plane, @intCast(row));
        }

        if (c.notcurses_render(nc_ctx) < 0) {
            return error.RenderFailed;
        }
    }

    pub fn update(self: *Diff, width: c_uint) !void {
        if (self.width == width) return;
        if (self.width < width) {
            self.width = width;
            if (!self.did_wrap) return;
        } else if (!self.did_wrap and self.widest < width) {
            self.width = width;
            return;
        }

        self.display_lines.clearRetainingCapacity();

        var gather_result: GatherResult = .{};
        for (self.files) |file| {
            gather_result.merge(try file.gatherDisplayLines(self.alloc, &self.display_lines, width));
        }

        self.width = width;
        self.widest = gather_result.widest;
        self.did_wrap = gather_result.did_wrap;
    }

    pub fn deinit(self: *Diff, alloc: std.mem.Allocator) void {
        for (self.files) |file| {
            file.deinit(alloc);
        }
        alloc.free(self.files);
        self.display_lines.deinit(alloc);
    }
};

const GatherResult = struct {
    widest: c_uint = 0,
    did_wrap: bool = false,

    fn merge(self: *GatherResult, other: GatherResult) void {
        self.widest = @max(self.widest, other.widest);
        self.did_wrap = self.did_wrap or other.did_wrap;
    }
};

pub const FileDiff = struct {
    old_path: []const u8,
    new_path: []const u8,
    meta_lines: [][]const u8,
    hunks: []Hunk,

    pub fn deinit(self: FileDiff, alloc: std.mem.Allocator) void {
        alloc.free(self.meta_lines);
        for (self.hunks) |hunk| {
            hunk.deinit(alloc);
        }
        alloc.free(self.hunks);
    }

    // TODO: we would need to perform syntax highlighting here as well
    pub fn gatherDisplayLines(
        self: FileDiff,
        alloc: std.mem.Allocator,
        buf: *std.ArrayList(DisplayLine),
        width: c_uint,
    ) !GatherResult {
        var result: GatherResult = .{};

        for (self.meta_lines) |meta_line| {
            result.merge(try gatherTextDisplayLines(
                alloc,
                buf,
                .file_header,
                meta_line,
                width,
            ));
        }

        for (self.hunks) |hunk| {
            result.merge(try hunk.gatherDisplayLines(alloc, buf, width));
        }

        return result;
    }
};

pub const Hunk = struct {
    header: []const u8,
    // TODO: actually parse these info
    old_start: usize = 0,
    old_len: usize = 0,
    new_start: usize = 0,
    new_len: usize = 0,
    lines: []DiffLine,

    pub fn deinit(self: Hunk, alloc: std.mem.Allocator) void {
        alloc.free(self.lines);
    }

    pub fn gatherDisplayLines(
        self: Hunk,
        alloc: std.mem.Allocator,
        buf: *std.ArrayList(DisplayLine),
        width: c_uint,
    ) !GatherResult {
        var result: GatherResult = .{};

        result.merge(try gatherTextDisplayLines(
            alloc,
            buf,
            .hunk_header,
            self.header,
            width,
        ));

        for (self.lines) |line| {
            result.merge(try line.gatherDisplayLines(alloc, buf, width));
        }

        return result;
    }
};

pub const DiffLine = union(enum) {
    context: []const u8,
    add: []const u8,
    remove: []const u8,

    pub fn gatherDisplayLines(
        self: DiffLine,
        alloc: std.mem.Allocator,
        buf: *std.ArrayList(DisplayLine),
        width: c_uint,
    ) !GatherResult {
        const line = self.intoDisplayLine();
        return try gatherTextDisplayLines(alloc, buf, line.kind, line.text, width);
    }

    fn intoDisplayLine(self: DiffLine) DisplayLine {
        return switch (self) {
            .context => |text| .{ .kind = DisplayLine.Kind.context, .text = text },
            .add => |text| .{ .kind = DisplayLine.Kind.add, .text = text },
            .remove => |text| .{ .kind = DisplayLine.Kind.remove, .text = text },
        };
    }
};

/// An alternate representation of parsed content optmized for rendering
const DisplayLine = struct {
    const Kind = enum {
        file_header,
        hunk_header,
        context,
        add,
        remove,
    };

    kind: Kind,
    text: []const u8,

    pub fn render(
        self: DisplayLine,
        nc_ctx: *c.notcurses,
        plane: *c.ncplane,
        offset: c_int,
    ) !void {
        _ = nc_ctx;

        c.ncplane_set_styles(plane, c.NCSTYLE_NONE);
        c.ncplane_set_bg_default(plane);

        switch (self.kind) {
            .file_header => {
                c.ncplane_set_styles(plane, c.NCSTYLE_BOLD);
                if (c.ncplane_set_fg_rgb8(plane, 0x85, 0xd7, 0xff) < 0) return error.SetColorFailed;
            },
            .hunk_header => {
                if (c.ncplane_set_fg_rgb8(plane, 0xd7, 0xaf, 0xff) < 0) return error.SetColorFailed;
            },
            .context => {
                c.ncplane_set_fg_default(plane);
            },
            .add => {
                if (c.ncplane_set_fg_rgb8(plane, 0x87, 0xd7, 0x87) < 0) return error.SetColorFailed;
            },
            .remove => {
                if (c.ncplane_set_fg_rgb8(plane, 0xff, 0x87, 0x87) < 0) return error.SetColorFailed;
            },
        }

        if (c.ncplane_putnstr_yx(plane, offset, 0, self.text.len, self.text.ptr) < 0) {
            return error.PutStrFailed;
        }

        c.ncplane_set_styles(plane, c.NCSTYLE_NONE);
        c.ncplane_set_fg_default(plane);
        c.ncplane_set_bg_default(plane);
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

fn gatherTextDisplayLines(
    alloc: std.mem.Allocator,
    buf: *std.ArrayList(DisplayLine),
    kind: DisplayLine.Kind,
    text: []const u8,
    width: c_uint,
) !GatherResult {
    var remaining = text;
    var result: GatherResult = .{};

    while (remaining.len > 0) {
        const wrapped = wrapLine(remaining, width);
        result.widest = @max(result.widest, wrapped.display_width);

        const end = wrapped.end orelse {
            try buf.append(alloc, .{
                .kind = kind,
                .text = remaining,
            });
            break;
        };

        result.did_wrap = true;
        if (end == 0) break;

        try buf.append(alloc, .{
            .kind = kind,
            .text = remaining[0..end],
        });
        remaining = remaining[end..];
    }

    return result;
}

/// Does NOT copy
fn parseHunk(alloc: std.mem.Allocator, header: []const u8, inputs: [][]const u8) !Hunk {
    var lines: std.ArrayList(DiffLine) = .empty;

    for (inputs) |input| {
        if (input.len == 0) continue;

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
        .header = header,
        .lines = try lines.toOwnedSlice(alloc),
    };
}

const WrapLineResult = struct {
    /// Byte index where the current rendered segment should end. `null` means
    /// the whole input fits without wrapping.
    end: ?usize,
    /// Display width of the segment described by `end`, or of the whole input
    /// when `end` is null.
    display_width: c_uint,
};

// TODO: util candidate
/// Given a slice and a width for display area, return where the current line
/// should wrap plus the display width of the segment. If `end` is null, the
/// current line is not long enough to create a wrap and `display_width` is the
/// width of the entire input.
fn wrapLine(input: []const u8, width: c_uint) WrapLineResult {
    if (input.len == 0) return .{ .end = null, .display_width = 0 };

    const max_width: usize = width;
    if (max_width == 0) return .{ .end = 0, .display_width = 0 };

    var cols: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        const start = i;
        const cp_len = utf8CodepointLen(input[start..]);
        const cp_width = codepointDisplayWidth(input[start .. start + cp_len]);

        if (cols + cp_width > max_width) {
            // If the first codepoint itself is wider than the viewport, return
            // its end so callers can still make progress rather than looping
            // forever on the same input. In that case the segment's display
            // width can be wider than the viewport.
            return if (start == 0)
                .{ .end = cp_len, .display_width = @intCast(cp_width) }
            else
                .{ .end = start, .display_width = @intCast(cols) };
        }

        cols += cp_width;
        i += cp_len;
    }

    return .{ .end = null, .display_width = @intCast(cols) };
}

fn utf8CodepointLen(input: []const u8) usize {
    std.debug.assert(input.len > 0);

    const len = std.unicode.utf8ByteSequenceLength(input[0]) catch return 1;
    if (len > input.len) return 1;
    return len;
}

fn codepointDisplayWidth(input: []const u8) usize {
    std.debug.assert(input.len > 0);

    if (input.len == 1) {
        if (input[0] == '\t') return 4;
        return switch (input[0]) {
            0x00...0x1f, 0x7f => 0,
            else => 1,
        };
    }

    const cp = std.unicode.utf8Decode(input) catch return 1;
    if (isCombiningCodepoint(cp)) return 0;

    return 1;
}

fn isCombiningCodepoint(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036f,
        0x1ab0...0x1aff,
        0x1dc0...0x1dff,
        0x20d0...0x20ff,
        0xfe20...0xfe2f,
        => true,
        else => false,
    };
}

/// Entry point for testing rendering
pub fn main(init: std.process.Init) !void {
    const input: [:0]const u8 =
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

    const alloc = init.gpa;

    if (c.setlocale(c.LC_ALL, "") == null) {
        return error.SetLocaleFailed;
    }

    var opts = std.mem.zeroes(c.notcurses_options);
    const nc_ctx = c.notcurses_init(&opts, null) orelse {
        return error.NotcursesInitFailed;
    };
    defer _ = c.notcurses_stop(nc_ctx);

    var rows: c_uint = 0;
    var cols: c_uint = 0;

    if (c.notcurses_refresh(nc_ctx, &rows, &cols) < 0) {
        return error.RefreshFailed;
    }

    var diff = try Diff.init(alloc, input, cols);
    defer diff.deinit(alloc);

    const plane = c.notcurses_stdplane(nc_ctx) orelse return error.CreatePlaneFailed;

    try diff.render(nc_ctx, plane);

    var key_input = std.mem.zeroes(c.ncinput);
    while (true) {
        const key = c.notcurses_get_blocking(nc_ctx, &key_input);
        if (key == 'q') {
            break;
        }
    }
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

    const hunk = try parseHunk(alloc, "@@ -1,1 +1,3 @@", &inputs);
    defer hunk.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), hunk.lines.len);
    try std.testing.expectEqualStrings(" const std = @import(\"std\");", hunk.lines[0].context);
    try std.testing.expectEqualStrings("+const util = @import(\"../util.zig\");", hunk.lines[1].add);
    try std.testing.expectEqualStrings("-const old = @import(\"old.zig\");", hunk.lines[2].remove);
}

test "wrapLine returns null end and width when line fits" {
    const exact = wrapLine("abc", 3);
    try std.testing.expectEqual(null, exact.end);
    try std.testing.expectEqual(@as(c_uint, 3), exact.display_width);

    const shorter = wrapLine("abc", 4);
    try std.testing.expectEqual(null, shorter.end);
    try std.testing.expectEqual(@as(c_uint, 3), shorter.display_width);
}

test "wrapLine returns byte index and segment width where wrapping should occur" {
    const width_three = wrapLine("abcd", 3);
    try std.testing.expectEqual(@as(?usize, 3), width_three.end);
    try std.testing.expectEqual(@as(c_uint, 3), width_three.display_width);

    const width_one = wrapLine("abcd", 1);
    try std.testing.expectEqual(@as(?usize, 1), width_one.end);
    try std.testing.expectEqual(@as(c_uint, 1), width_one.display_width);
}

test "wrapLine does not split utf8 codepoints" {
    // é is two bytes, but this implementation treats it as one display column.
    const wrapped = wrapLine("éab", 2);
    try std.testing.expectEqual(@as(?usize, 3), wrapped.end);
    try std.testing.expectEqual(@as(c_uint, 2), wrapped.display_width);
}

test "Diff.init tracks widest display line after wrapping" {
    const input =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1,1 +1,3 @@
        \\ short
        \\+123456789
        \\-123456789012
        \\
    ;

    const alloc = std.testing.allocator;
    var diff = try Diff.init(alloc, input, 10);
    defer diff.deinit(alloc);

    try std.testing.expectEqual(@as(c_uint, 10), diff.widest);
    try std.testing.expect(diff.did_wrap);
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
    var diff = try Diff.init(alloc, input, 80);
    defer diff.deinit(alloc);

    try std.testing.expect(!diff.did_wrap);

    try std.testing.expectEqual(@as(usize, 1), diff.files.len);
    try std.testing.expectEqualStrings("a/src/components/DiffWindow.zig", diff.files[0].old_path);
    try std.testing.expectEqualStrings("b/src/components/DiffWindow.zig", diff.files[0].new_path);

    try std.testing.expectEqual(@as(usize, 1), diff.files[0].hunks.len);
    try std.testing.expectEqual(@as(usize, 3), diff.files[0].hunks[0].lines.len);
    try std.testing.expectEqualStrings(" const std = @import(\"std\");", diff.files[0].hunks[0].lines[0].context);
    try std.testing.expectEqualStrings("+const util = @import(\"../util.zig\");", diff.files[0].hunks[0].lines[1].add);
    try std.testing.expectEqualStrings("-const old = @import(\"old.zig\");", diff.files[0].hunks[0].lines[2].remove);
}

const std = @import("std");

pub const WrapLineResult = struct {
    /// Byte index where the current rendered segment should end. `null` means
    /// the whole input fits without wrapping.
    end: ?usize,
    /// Display width of the segment described by `end`, or of the whole input
    /// when `end` is null.
    display_width: c_uint,
};

/// Given a slice and a width for display area, return where the current line
/// should wrap plus the display width of the segment. If `end` is null, the
/// current line is not long enough to create a wrap and `display_width` is the
/// width of the entire input.
pub fn wrapLine(input: []const u8, width: c_uint) WrapLineResult {
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

pub fn clipToDisplayWidth(input: []const u8, width: usize) []const u8 {
    if (input.len == 0 or width == 0) return input[0..0];

    var cols: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        const start = i;
        const cp_len = utf8CodepointLen(input[start..]);
        const cp_width = codepointDisplayWidth(input[start .. start + cp_len]);

        if (cols + cp_width > width) break;

        cols += cp_width;
        i += cp_len;
    }

    return input[0..i];
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

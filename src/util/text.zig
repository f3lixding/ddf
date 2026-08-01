const std = @import("std");
const c = @import("c.zig").c;

pub const input_text_buffer_len = c.NCINPUT_MAX_EFF_TEXT_CODEPOINTS * 4;

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

pub fn displayWidth(content: []const u8) c_uint {
    return wrapLine(content, std.math.maxInt(c_uint)).display_width;
}

pub fn inputText(key: u32, ncinput: c.ncinput, buf: *[input_text_buffer_len]u8) []const u8 {
    const effective_text = effectiveInputText(ncinput, buf);
    if (isTextInput(effective_text)) return effective_text;

    // Without effective text, continue to ignore shortcut-style modified keys.
    if ((ncinput.modifiers & (c.NCKEY_MOD_CTRL | c.NCKEY_MOD_ALT)) != 0) return "";

    if (key >= 0x20 and key <= 0x7e) {
        buf[0] = @intCast(key);
        return buf[0..1];
    }

    return inputUtf8(ncinput);
}

pub fn isTextInput(text: []const u8) bool {
    if (text.len == 0) return false;

    // Do not append C0/DEL controls. Printable ASCII is handled from the input
    // key before we trust ncinput.utf8 because notcurses can report
    // stale/control bytes there for ordinary keypresses on this path.
    if (text.len == 1 and (text[0] < 0x20 or text[0] == 0x7f)) return false;

    return std.unicode.utf8ValidateSlice(text);
}

pub fn lastUtf8CodepointLen(content: []const u8) usize {
    if (content.len == 0) return 0;

    var idx = content.len - 1;
    while (idx > 0 and (content[idx] & 0b1100_0000) == 0b1000_0000) {
        idx -= 1;
    }

    return content.len - idx;
}

pub fn putEgcSegment(plane: *c.ncplane, y: c_int, x: c_int, text: []const u8) !void {
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

pub fn utf8CodepointLen(input: []const u8) usize {
    std.debug.assert(input.len > 0);

    const len = std.unicode.utf8ByteSequenceLength(input[0]) catch return 1;
    if (len > input.len) return 1;
    return len;
}

fn effectiveInputText(ncinput: c.ncinput, buf: *[input_text_buffer_len]u8) []const u8 {
    var len: usize = 0;
    for (ncinput.eff_text) |raw_cp| {
        if (raw_cp == 0) break;
        const cp: u21 = std.math.cast(u21, raw_cp) orelse return "";
        const cp_len = std.unicode.utf8Encode(cp, buf[len..]) catch return "";
        len += cp_len;
    }
    return buf[0..len];
}

fn inputUtf8(ncinput: c.ncinput) []const u8 {
    const raw = ncinput.utf8[0..];
    return std.mem.sliceTo(raw, 0);
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

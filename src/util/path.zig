const std = @import("std");

pub fn getDirRelativeToHome(dest_slice: []u8, subpath: []const u8) ![]u8 {
    const home = std.c.getenv("HOME") orelse return error.NoHomeFound;
    const home_path: []const u8 = std.mem.span(home);
    return try std.fmt.bufPrint(dest_slice, "{s}/{s}", .{ home_path, subpath });
}

pub fn getDirRelativeToHomeSentinel(dest_slice: []u8, subpath: []const u8) ![:0]u8 {
    const home = std.c.getenv("HOME") orelse return error.NoHomeFound;
    const home_path: []const u8 = std.mem.span(home);
    return try std.fmt.bufPrintSentinel(dest_slice, "{s}/{s}", .{ home_path, subpath }, 0);
}

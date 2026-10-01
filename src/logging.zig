const std = @import("std");

/// Once the active log file reaches this size it is rotated.
const SIZE_UPPER_BOUND: u64 = 10 * 1024 * 1024;

var mutex: std.Io.Mutex = .init;
var global_io: ?std.Io = null;
var global_file: ?std.Io.File = null;
var min_level: std.log.Level = .err;
var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
var global_path: []const u8 = &.{};

/// Initialize the process-wide std.log sink.
/// Call this once, before spawning worker tasks that may log.
pub fn init(io: std.Io, path: []const u8) !void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (global_file != null) return error.AlreadyInitialized;
    if (path.len > path_buf.len) return error.NameTooLong;

    if (std.c.getenv("DDF_LOG")) |value| {
        const converted: []const u8 = std.mem.span(value);
        if (parseLevel(converted)) |level| {
            min_level = level;
        }
    }

    const file = openLogFile(io, .cwd(), path, SIZE_UPPER_BOUND, nowSecs(io)) catch
        return error.FailedToLocateFile;

    @memcpy(path_buf[0..path.len], path);
    global_path = path_buf[0..path.len];
    global_io = io;
    global_file = file;
}

/// Opens `path` for appending. If it is already at or over `size_limit`, it is
/// rotated first and a fresh file is created in its place.
fn openLogFile(io: std.Io, dir: std.Io.Dir, path: []const u8, size_limit: u64, now_secs: u64) !std.Io.File {
    const existing = dir.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return try dir.createFile(io, path, .{}),
        else => return err,
    };

    const size = existing.length(io) catch |err| {
        existing.close(io);
        return err;
    };
    if (size < size_limit) return existing;

    existing.close(io);
    try rotate(io, dir, path, now_secs);
    return try dir.createFile(io, path, .{});
}

/// Renames `<path>` to `<path>.yyyy-mm-dd-hh:mm` (UTC, matching the log line
/// timestamps). A previous rotation within the same minute is overwritten.
fn rotate(io: std.Io, dir: std.Io.Dir, path: []const u8, now_secs: u64) !void {
    const now = std.time.epoch.EpochSeconds{ .secs = now_secs };
    const day_seconds = now.getDaySeconds();
    const year_day = now.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}.{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}:{d:0>2}", .{
        path,
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    });
    try dir.rename(path, dir, dst, io);
}

fn nowSecs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.real.now(io).toSeconds());
}

/// Called with `mutex` held when the active file has grown past the limit.
/// Best-effort: on any failure we keep writing to the current file rather than
/// losing logs or falling back to stderr (which would corrupt the TUI).
fn rotateActiveFile(io: std.Io, current: std.Io.File) std.Io.File {
    rotate(io, .cwd(), global_path, nowSecs(io)) catch return current;
    // On POSIX the open handle follows the renamed file, so `current` stays
    // valid until the new file is in place.
    const fresh = std.Io.Dir.cwd().createFile(io, global_path, .{}) catch return current;
    current.close(io);
    global_file = fresh;
    return fresh;
}

/// Shut down the process-wide std.log sink.
/// Call this after canceling/awaiting worker tasks that may log.
pub fn deinit(io: std.Io) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (global_file) |file| file.close(io);

    global_file = null;
    global_io = null;
}

/// std.Options.logFn-compatible logger.
/// Logging functions cannot return errors, so this is best-effort.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(min_level))
        return;

    const io = global_io orelse return std.log.defaultLog(level, scope, format, args);

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    var file = global_file orelse return std.log.defaultLog(level, scope, format, args);

    // Logging should not be interrupted by task cancellation.
    const prev_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev_cancel_protection);

    var end = file.length(io) catch return;
    if (end >= SIZE_UPPER_BOUND) {
        file = rotateActiveFile(io, file);
        end = file.length(io) catch return;
    }

    var buffer: [1024]u8 = undefined;
    var file_writer = std.Io.File.writerStreaming(file, io, &buffer);
    file_writer.seekTo(end) catch return;
    const writer = &file_writer.interface;

    const now = std.time.epoch.EpochSeconds{
        .secs = nowSecs(io),
    };
    const day_seconds = now.getDaySeconds();
    const year_day = now.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    writer.print("[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC] [{s}] [{s}] ", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        @tagName(level),
        @tagName(scope),
    }) catch return;
    writer.print(format, args) catch return;
    writer.writeByte('\n') catch return;
    writer.flush() catch return;
}

fn parseLevel(value: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, value, "err")) return .err;
    if (std.mem.eql(u8, value, "warn")) return .warn;
    if (std.mem.eql(u8, value, "info")) return .info;
    if (std.mem.eql(u8, value, "debug")) return .debug;
    return null;
}

fn expectFileContent(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const io = std.testing.io;
    var buf: [64]u8 = undefined;
    const content = try dir.readFile(io, path, &buf);
    try std.testing.expectEqualStrings(expected, content);
}

fn expectMissing(dir: std.Io.Dir, path: []const u8) !void {
    try std.testing.expectError(error.FileNotFound, dir.statFile(std.testing.io, path, .{}));
}

// 2026-10-01 17:37:49 UTC
const test_now: u64 = 1790876269;

test "rotate renames to a timestamped file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "ddf.log", .data = "current" });
    try rotate(io, tmp.dir, "ddf.log", test_now);

    try expectMissing(tmp.dir, "ddf.log");
    try expectFileContent(tmp.dir, "ddf.log.2026-10-01-17:37", "current");
}

test "openLogFile keeps a small file and rotates a full one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Missing file gets created.
    const created = try openLogFile(io, tmp.dir, "ddf.log", 8, test_now);
    created.close(io);
    try expectFileContent(tmp.dir, "ddf.log", "");

    // Under the limit: reopened as-is.
    try tmp.dir.writeFile(io, .{ .sub_path = "ddf.log", .data = "small" });
    const kept = try openLogFile(io, tmp.dir, "ddf.log", 8, test_now);
    kept.close(io);
    try expectFileContent(tmp.dir, "ddf.log", "small");
    try expectMissing(tmp.dir, "ddf.log.2026-10-01-17:37");

    // At the limit: rotated and replaced by an empty file.
    try tmp.dir.writeFile(io, .{ .sub_path = "ddf.log", .data = "12345678" });
    const fresh = try openLogFile(io, tmp.dir, "ddf.log", 8, test_now);
    fresh.close(io);
    try expectFileContent(tmp.dir, "ddf.log", "");
    try expectFileContent(tmp.dir, "ddf.log.2026-10-01-17:37", "12345678");
}

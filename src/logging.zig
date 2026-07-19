const std = @import("std");

const SIZE_UPPER_BOUND: u64 = 52_428_000;

var mutex: std.Io.Mutex = .init;
var global_io: ?std.Io = null;
var global_file: ?std.Io.File = null;
var min_level: std.log.Level = .err;

/// Initialize the process-wide std.log sink.
/// Call this once, before spawning worker tasks that may log.
pub fn init(io: std.Io, path: []const u8) !void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (global_file != null) return error.AlreadyInitialized;

    if (std.c.getenv("DF_LOG")) |value| {
        const converted: []const u8 = std.mem.span(value);
        if (parseLevel(converted)) |level| {
            min_level = level;
        }
    }

    const file = final: while (true) {
        const candidate = std.Io.Dir.openFileAbsolute(
            io,
            path,
            .{ .mode = .read_write },
        ) catch |err| file: {
            switch (err) {
                error.FileNotFound => {
                    const file = try std.Io.Dir.createFileAbsolute(io, path, .{
                        .truncate = true,
                    });
                    break :file file;
                },
                else => return error.FailedToLocateFile,
            }
        };

        const file_stat = try candidate.stat(io);
        if (file_stat.size >= SIZE_UPPER_BOUND) {
            candidate.close(io);
            try std.Io.Dir.deleteFileAbsolute(io, path);
            continue;
        }

        break :final candidate;
    };

    global_io = io;
    global_file = file;
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

    const file = global_file orelse return std.log.defaultLog(level, scope, format, args);

    // Logging should not be interrupted by task cancellation.
    const prev_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev_cancel_protection);

    var buffer: [1024]u8 = undefined;
    var file_writer = std.Io.File.writerStreaming(file, io, &buffer);
    const end = file.length(io) catch return;
    file_writer.seekTo(end) catch return;
    const writer = &file_writer.interface;

    const now = std.time.epoch.EpochSeconds{
        .secs = @intCast(std.Io.Clock.real.now(io).toSeconds()),
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

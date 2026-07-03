const std = @import("std");
const diff = @import("components/diff.zig");
const logging = @import("logging.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

pub fn main(init: std.process.Init) !void {
    try logging.init(init.io, "/tmp/diff_render.log");
    defer logging.deinit(init.io);

    try diff.main(init);
}

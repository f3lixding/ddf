const std = @import("std");
const Io = std.Io;

const util = @import("util.zig");
const c = util.c;
const logging = @import("logging.zig");
const InputParser = @import("InputParser.zig");
const protocol = @import("protocol.zig");
const App = @import("App.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

const Opts = struct {
    const Self = @This();

    // these are stubs.
    // we are going to have real args later
    stub_a: ?[]const u8 = null,
    stub_b: ?[]const u8 = null,

    pub fn parseFromArgs(args: std.process.Args, errMsgWriter: *std.Io.Writer) !Self {
        var iter = args.iterate();
        var res: Self = .{};

        while (iter.next()) |field| {
            if (std.mem.eql(u8, "--along", field) or std.mem.eql(u8, "-a", field)) {
                const val = iter.next() orelse {
                    errMsgWriter.writeAll("provide a value for a\n") catch {};
                    errMsgWriter.flush() catch {};
                    return error.MissingValue;
                };
                res.stub_a = val;
            } else if (std.mem.eql(u8, "--blong", field) or std.mem.eql(u8, "-b", field)) {
                const val = iter.next() orelse {
                    errMsgWriter.writeAll("provide a value for a\n") catch {};
                    errMsgWriter.flush() catch {};
                    return error.MissingValue;
                };
                res.stub_b = val;
            }
        }

        return res;
    }

    pub fn execute(self: Self, alloc: std.mem.Allocator, io: std.Io) !void {
        _ = self;

        const Spsc = util.Spsc;
        const InputEvent = protocol.InputEvent;

        if (c.setlocale(c.LC_ALL, "") == null) {
            return error.SetLocaleFailed;
        }

        var opts = std.mem.zeroes(c.notcurses_options);
        const nc_ctx = c.notcurses_init(&opts, null) orelse {
            return error.NotcursesInitFailed;
        };
        defer _ = c.notcurses_stop(nc_ctx);

        const channel = try Spsc(InputEvent).init(alloc, 25);
        defer channel.deinit();

        var input_parser = try InputParser.init(alloc, nc_ctx, channel.tx, .{
            .input_source = .{ .get_input_nblock = struct {
                fn getInput(_nc_ctx: *c.notcurses, input: *c.ncinput) u32 {
                    return c.notcurses_get_nblock(_nc_ctx, input);
                }
            }.getInput },
        });
        defer input_parser.deinit(io);

        try input_parser.listen(io);

        var app = App.init(alloc, channel.rx);
        const Splash = @import("components/Splash.zig");
        const splash = try alloc.create(Splash);
        splash.* = try .init(alloc, io, nc_ctx);
        try app.components.append(alloc, splash.initInterface());

        defer app.deinit(io);

        try app.startAndAwait(io, nc_ctx);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args;

    const io = init.io;
    try logging.init(io, "/tmp/df.log");
    defer logging.deinit(io);

    std.log.info("started", .{});
    var buf: [256]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var stdout_writer = std.Io.File.writer(stdout, io, &buf);
    const errMsgWriter = &stdout_writer.interface;

    const opts = try Opts.parseFromArgs(args, errMsgWriter);
    std.debug.print("{any}\n", .{opts});

    opts.execute(std.heap.page_allocator, init.io) catch |err| {
        std.log.err("Execute failed: {any}", .{err});
    };
}

test {
    _ = @import("util.zig");
    _ = @import("InputParser.zig");
    _ = @import("App.zig");
    _ = @import("components/diff.zig");
    _ = @import("components/syntax_highlighter.zig");
    _ = @import("TreeSitter.zig");
}

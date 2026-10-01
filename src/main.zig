const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const util = @import("util/root.zig");
const c = util.c;
const logging = @import("logging.zig");
const InputParser = @import("InputParser.zig");
const protocol = @import("protocol.zig");
const App = @import("App.zig");
const Backend = App.Backend;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

const Opts = struct {
    const Self = @This();

    const detection_commands = [_]struct { Backend, []const []const u8 }{
        .{ .jj, &.{ "jj", "root", "--color=never" } },
        .{ .git, &.{ "git", "rev-parse", "--show-toplevel" } },
        .{ .mercurial, &.{ "hg", "root" } },
    };

    args: ?[]const [:0]const u8 = null,
    backend: ?Backend = null,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Self {
        const backend: ?Backend = blk: for (detection_commands) |item| {
            const backend = item.@"0";
            const cmd = item.@"1";

            const result = std.process.run(alloc, io, .{
                .argv = cmd,
                .stdout_limit = .limited(16 * 1024 * 1024),
                .stderr_limit = .limited(1024 * 1024),
            }) catch continue;
            defer alloc.free(result.stdout);
            defer alloc.free(result.stderr);

            if (result.term == .exited and result.term.exited == 0) break :blk backend;
        } else null;

        return .{
            .backend = backend,
        };
    }

    pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
        if (self.args) |args| {
            alloc.free(args);
        }
    }

    pub fn execute(self: Self, alloc: std.mem.Allocator, io: std.Io) !void {
        if (self.backend == null) {
            var buf: [256]u8 = undefined;
            const stdout = std.Io.File.stdout();
            var stdout_writer = std.Io.File.writer(stdout, io, &buf);
            const errMsgWriter = &stdout_writer.interface;

            try errMsgWriter.writeAll("No valid backend detected in current directory\n");
            try errMsgWriter.flush();

            return;
        }

        const Spsc = util.Spsc;
        const InputEvent = protocol.InputEvent;

        if (c.setlocale(c.LC_ALL, "") == null) {
            return error.SetLocaleFailed;
        }

        var opts = std.mem.zeroes(c.notcurses_options);
        opts.flags |= c.NCOPTION_SUPPRESS_BANNERS;

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

        const start_args: ?[]const []const u8 = if (self.args) |args| args else null;
        var app = App.init(alloc, channel.rx, .{
            .backend = self.backend.?,
            .start_args = start_args,
        });
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
    try logging.init(io, "/tmp/ddf.log");
    defer logging.deinit(io);

    std.log.info("started", .{});
    var buf: [256]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var stdout_writer = std.Io.File.writer(stdout, io, &buf);
    const errMsgWriter = &stdout_writer.interface;

    var opts = Opts.init(init.gpa, init.io);
    defer opts.deinit(init.gpa);

    const args_slice = args.toSlice(init.gpa) catch {
        try errMsgWriter.writeAll("Failed to retrieve args slice");
        return;
    };
    opts.args = args_slice;

    const DebugAllocator = std.heap.DebugAllocator(.{
        .stack_trace_frames = 20,
    });
    var debug_alloc: ?DebugAllocator = null;
    const alloc = if (comptime build_options.use_testing_allocator) blk: {
        debug_alloc = DebugAllocator{};
        break :blk debug_alloc.?.allocator();
    } else std.heap.smp_allocator;
    defer {
        if (debug_alloc) |*allocator| {
            if (allocator.deinit() == .leak)
                @panic("Memory leaked");
        }
    }

    opts.execute(alloc, init.io) catch |err| {
        std.log.err("Execute failed: {any}", .{err});
    };
}

test {
    _ = @import("util/root.zig");
    _ = @import("logging.zig");
    _ = @import("InputParser.zig");
    _ = @import("App.zig");
    _ = @import("components/diff.zig");
    _ = @import("components/syntax_highlighter.zig");
    _ = @import("TreeSitter.zig");
}

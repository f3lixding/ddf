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

const MSG: []const u8 =
    \\ddf — review diffs in your terminal
    \\
    \\Usage:
    \\  ddf [OPTIONS] [DIFF_ARGS...]
    \\
    \\With no diff arguments, show recent history. With diff arguments, open
    \\the diff directly and pass those arguments to the selected backend.
    \\
    \\Options:
    \\  -h, --help    Show this help and exit
    \\
    \\Diff arguments are interpreted by jj diff or git diff. ddf detects the
    \\repository automatically; in a colocated repository, it prefers jj.
    \\
    \\Examples:
    \\  ddf           Browse recent revisions
    \\  ddf -r @-     Review a jj revision's diff
    \\  ddf HEAD~1 HEAD -- src/   Review a Git commit range within src/
    \\
;

const NativeArgs = enum { help };

const Opts = struct {
    const Self = @This();

    const detection_commands = [_]struct { Backend, []const []const u8 }{
        .{ .jj, &.{ "jj", "root", "--color=never" } },
        .{ .git, &.{ "git", "rev-parse", "--show-toplevel" } },
    };

    native_args: ?NativeArgs = null,
    raw_args: ?[]const [:0]const u8 = null,
    opaque_args: []const [:0]const u8 = &.{},
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
        if (self.raw_args) |args| {
            alloc.free(args);
        }
    }

    pub fn processArgs(self: *Self, args: []const [:0]const u8) void {
        var i: usize = 1; // skips the executable name

        while (i < args.len) : (i += 1) {
            const arg = args[i];

            // TODO: add more parsing for when we add more native args
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                self.native_args = .help;
            } else {
                break;
            }
        }

        self.raw_args = args;
        self.opaque_args = args[i..];
    }

    pub fn execute(self: Self, alloc: std.mem.Allocator, io: std.Io) !void {
        var buf: [256]u8 = undefined;
        const stdout = std.Io.File.stdout();
        var stdout_writer = std.Io.File.writer(stdout, io, &buf);
        const msg_writer = &stdout_writer.interface;

        if (self.native_args) |native_args| {
            switch (native_args) {
                .help => {
                    // Display help text
                    try msg_writer.writeAll(MSG);
                    try msg_writer.flush();
                },
            }

            return;
        }

        if (self.backend == null) {
            try msg_writer.writeAll("No jj or git repository detected in current directory\n");
            try msg_writer.flush();

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

        var app = App.init(alloc, channel.rx, .{ .backend = self.backend.? });
        defer app.deinit(io);
        if (self.opaque_args.len == 0) {
            const Splash = @import("components/Splash.zig");
            const splash = try alloc.create(Splash);
            splash.* = Splash.init(alloc, io, self.backend.?) catch |err| {
                alloc.destroy(splash);
                return err;
            };
            app.components.append(alloc, splash.initInterface()) catch |err| {
                splash.deinit();
                alloc.destroy(splash);
                return err;
            };
        } else {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(alloc);
            try argv.appendSlice(alloc, switch (self.backend.?) {
                .jj => &.{ "jj", "diff", "--tool=:git", "--color=never" },
                .git => &.{ "git", "diff", "--no-ext-diff", "--no-color" },
            });
            for (self.opaque_args) |arg| try argv.append(alloc, arg);

            var rows: c_uint = 0;
            var cols: c_uint = 0;
            if (c.notcurses_refresh(nc_ctx, &rows, &cols) < 0) return error.RefreshFailed;
            const render_ctx: protocol.RenderCtx = .{
                .term_rows = rows,
                .term_cols = cols,
                .nc_ctx = nc_ctx,
            };

            const DiffWindow = @import("components/diff_window/root.zig").DiffWindow;
            const diff = try alloc.create(DiffWindow);
            diff.* = DiffWindow.init(alloc, io, &render_ctx, argv.items) catch |err| {
                alloc.destroy(diff);
                return err;
            };
            app.components.append(alloc, diff.initInterface()) catch |err| {
                diff.deinit();
                alloc.destroy(diff);
                return err;
            };
        }

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
    opts.processArgs(args_slice);

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

const std = @import("std");
const Io = std.Io;

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
};

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args;

    const io = init.io;
    var buf: [256]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var stdout_writer = std.Io.File.writer(stdout, io, &buf);
    const errMsgWriter = &stdout_writer.interface;

    const opts = try Opts.parseFromArgs(args, errMsgWriter);
    std.debug.print("{any}\n", .{opts});
}

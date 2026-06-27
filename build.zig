const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bin_name = b.option([]const u8, "bin-name", "bin name") orelse "df";
    const rpaths = b.option([]const u8, "rpath", "rpath to add");
    const interpreter = b.option([]const u8, "interpreter", "ELF interpreter to set with patchelf");
    const patchelf = b.option([]const u8, "patchelf", "patchelf executable") orelse "patchelf";
    const test_filter = b.option([]const u8, "filter", "test filter, delimited with |");

    const exe = b.addExecutable(.{
        .name = bin_name,
        .root_module = b.addModule("main_module", .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Use the system linker instead of Zig's built-in ELF linker. This produces
    // ELF files that Nix/patchelf can reliably fix up.
    exe.use_lld = false;
    exe.pie = true;

    linkNc(exe);
    addNixRPath(exe, rpaths);

    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = b.addModule("test_module", .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .filters = if (test_filter) |filter| filter: {
            var iter = std.mem.splitScalar(u8, filter, '|');
            var res: std.ArrayList([]const u8) = .empty;
            while (iter.next()) |item| {
                res.append(b.allocator, item) catch return;
            }
            break :filter res.toOwnedSlice(b.allocator) catch return;
        } else &.{},
    });
    unit_tests.use_lld = false;
    unit_tests.pie = true;

    linkNc(unit_tests);
    addNixRPath(unit_tests, rpaths);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    if (interpreter) |interp| {
        const patch_tests = b.addSystemCommand(&.{
            patchelf,
            "--set-interpreter",
            interp,
        });
        patch_tests.addFileArg(unit_tests.getEmittedBin());
        run_unit_tests.step.dependOn(&patch_tests.step);
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn linkNc(bin: *std.Build.Step.Compile) void {
    // notcurses headers use wcwidth/wcswidth, whose declarations are exposed
    // by libc only when X/Open feature macros are enabled.
    bin.root_module.addCMacro("_XOPEN_SOURCE", "700");

    bin.root_module.linkSystemLibrary("notcurses", .{
        .use_pkg_config = .yes,
        // We need this for all the extra functionalities we are using
        .needed = true,
    });
}

fn addNixRPath(bin: *std.Build.Step.Compile, maybe_rpaths: ?[]const u8) void {
    const rpaths = maybe_rpaths orelse return;

    var path_iter = std.mem.splitScalar(u8, rpaths, ':');

    while (path_iter.next()) |path| {
        if (path.len == 0) continue;
        bin.root_module.addRPath(.{ .cwd_relative = path });
    }
}

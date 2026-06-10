const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "df",
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
    addNixRPath(b, exe);

    b.installArtifact(exe);
}

fn linkNc(bin: *std.Build.Step.Compile) void {
    // notcurses headers use wcwidth/wcswidth, whose declarations are exposed
    // by libc only when X/Open feature macros are enabled.
    bin.root_module.addCMacro("_XOPEN_SOURCE", "700");

    bin.root_module.linkSystemLibrary("notcurses", .{
        .use_pkg_config = .yes,
    });
}

fn addNixRPath(b: *std.Build, bin: *std.Build.Step.Compile) void {
    const rpaths = b.option([]const u8, "rpath", "rpath to add") orelse return;

    var path_iter = std.mem.splitScalar(u8, rpaths, ':');

    while (path_iter.next()) |path| {
        if (path.len == 0) continue;
        bin.root_module.addRPath(.{ .cwd_relative = path });
    }
}

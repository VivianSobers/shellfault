const std = @import("std");

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag == .linux and optimize != .debug) {
        var query = target.query;
        query.abi = .musl;
        target = b.resolveTargetQuery(query);
    }

    const lua_dep = b.dependency("lua", .{});
    const lua_src_path = lua_dep.path(".");
    const lua_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lua_mod.addIncludePath(lua_src_path);
    lua_mod.addCSourceFiles(.{
        .root = lua_src_path,
        .files = &.{
            "lapi.c",
            "lauxlib.c",
            "lbaselib.c",
            "lcode.c",
            "lcorolib.c",
            "lctype.c",
            "ldblib.c",
            "ldebug.c",
            "ldo.c",
            "ldump.c",
            "lfunc.c",
            "lgc.c",
            "linit.c",
            "liolib.c",
            "llex.c",
            "lmathlib.c",
            "lmem.c",
            "loadlib.c",
            "lobject.c",
            "lopcodes.c",
            "loslib.c",
            "lparser.c",
            "lstate.c",
            "lstring.c",
            "lstrlib.c",
            "ltable.c",
            "ltablib.c",
            "ltm.c",
            "lundump.c",
            "lutf8lib.c",
            "lvm.c",
            "lzio.c",
        },
    });

    const lua_lib = b.addLibrary(.{
        .name = "lua",
        .root_module = lua_mod,
        .linkage = .static,
    });

    const c_headers = b.addWriteFiles();
    const c_header = c_headers.add("c.h",
        \\#include <lua.h>
        \\#include <lauxlib.h>
        \\#include <lualib.h>
    );

    const translate_c = b.addTranslateC(.{
        .root_source_file = c_header,
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(lua_src_path);
    const c_mod = translate_c.createModule();

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.linkLibrary(lua_lib);
    exe_mod.addImport("c", c_mod);

    const exe = b.addExecutable(.{
        .name = "shellfault",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.linkLibrary(lua_lib);
    test_mod.addImport("c", c_mod);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const e2e_step = b.step("e2e", "Run e2e tests");
    const bats_cmd = b.addSystemCommand(&.{ "bats", "tests/e2e" });
    bats_cmd.setCwd(b.path("."));
    bats_cmd.step.dependOn(b.getInstallStep());
    e2e_step.dependOn(&bats_cmd.step);
}

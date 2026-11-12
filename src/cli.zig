const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RunOptions = struct {
    script: []const u8,
    args: []const []const u8 = &.{},
    fixture: ?[]const u8 = null,
    out: []const u8 = "shellfault-out",
    timeout_s: u32 = 60,
    bash: ?[]const u8 = null,
};

pub const Options = union(enum) {
    version,
    points: RunOptions,
    run: RunOptions,
};

pub var err_msg_buf: [256]u8 = undefined;
pub var err_msg: []const u8 = "";

pub fn parse(gpa: Allocator, argv: []const []const u8) !Options {
    _ = gpa;
    if (argv.len == 0) {
        err_msg = "missing command";
        return error.Usage;
    }

    const cmd = argv[0];
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "version")) {
        return .version;
    }

    const is_run = std.mem.eql(u8, cmd, "run");
    const is_points = std.mem.eql(u8, cmd, "points");

    if (!is_run and !is_points) {
        err_msg = std.fmt.bufPrint(&err_msg_buf, "unknown command: {s}", .{cmd}) catch "unknown command";
        return error.Usage;
    }

    var run_opts = RunOptions{
        .script = "",
    };

    var script_set = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            if (i < argv.len) {
                run_opts.args = argv[i..];
            }
            break;
        } else if (std.mem.eql(u8, arg, "--fixture")) {
            i += 1;
            if (i >= argv.len) {
                err_msg = "--fixture requires an argument";
                return error.Usage;
            }
            run_opts.fixture = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--fixture=")) {
            run_opts.fixture = arg["--fixture=".len..];
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= argv.len) {
                err_msg = "--out requires an argument";
                return error.Usage;
            }
            run_opts.out = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            run_opts.out = arg["--out=".len..];
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= argv.len) {
                err_msg = "--timeout requires an argument";
                return error.Usage;
            }
            run_opts.timeout_s = std.fmt.parseInt(u32, argv[i], 10) catch {
                err_msg = "invalid timeout";
                return error.Usage;
            };
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            run_opts.timeout_s = std.fmt.parseInt(u32, arg["--timeout=".len..], 10) catch {
                err_msg = "invalid timeout";
                return error.Usage;
            };
        } else if (std.mem.eql(u8, arg, "--bash")) {
            i += 1;
            if (i >= argv.len) {
                err_msg = "--bash requires an argument";
                return error.Usage;
            }
            run_opts.bash = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--bash=")) {
            run_opts.bash = arg["--bash=".len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            err_msg = std.fmt.bufPrint(&err_msg_buf, "unknown option: {s}", .{arg}) catch "unknown option";
            return error.Usage;
        } else {
            if (!script_set) {
                run_opts.script = arg;
                script_set = true;
            } else {
                err_msg = std.fmt.bufPrint(&err_msg_buf, "unexpected argument: {s}", .{arg}) catch "unexpected argument";
                return error.Usage;
            }
        }
    }

    if (!script_set) {
        err_msg = "missing script argument";
        return error.Usage;
    }

    if (is_run) {
        return Options{ .run = run_opts };
    } else {
        return Options{ .points = run_opts };
    }
}

test "parses run with args after --" {
    const argv = [_][]const u8{ "run", "a b.sh", "--", "x", "--y" };
    const opts = try parse(std.testing.allocator, &argv);
    try std.testing.expect(opts == .run);
    try std.testing.expectEqualStrings("a b.sh", opts.run.script);
    try std.testing.expectEqual(@as(usize, 2), opts.run.args.len);
    try std.testing.expectEqualStrings("x", opts.run.args[0]);
    try std.testing.expectEqualStrings("--y", opts.run.args[1]);
}

test "unknown command is usage error" {
    const argv = [_][]const u8{"frobnicate"};
    try std.testing.expectError(error.Usage, parse(std.testing.allocator, &argv));
}

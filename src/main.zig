const std = @import("std");
pub const cli = @import("cli.zig");
pub const lua = @import("lua.zig");
pub const session = @import("session.zig");

test {
    _ = cli;
    _ = lua;
    _ = @import("manifest.zig");
    _ = @import("workspace.zig");
    _ = @import("trace.zig");
    _ = @import("points.zig");
    _ = @import("supervise.zig");
    _ = session;
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    if (args.len < 2) {
        std.Io.File.stderr().writeStreamingAll(init.io, "missing command\n") catch {};
        return 2;
    }

    const opts = cli.parse(init.gpa, args[1..]) catch |err| {
        if (err == error.Usage) {
            if (cli.err_msg.len > 0) {
                std.Io.File.stderr().writeStreamingAll(init.io, cli.err_msg) catch {};
                std.Io.File.stderr().writeStreamingAll(init.io, "\n") catch {};
            }
            return 2;
        }
        return 2;
    };

    switch (opts) {
        .version => {
            std.Io.File.stdout().writeStreamingAll(init.io, "shellfault 0.0.0 (Lua 5.4.8)\n") catch {};
            return 0;
        },
        .points => |run_opts| {
            defer session.deinitErrors(init.gpa);
            const b = session.baseline(init.gpa, init.io, run_opts) catch |err| {
                if (err == error.ReferenceFailed) {
                    session.printReferenceFailed(init.io);
                    return 2;
                } else if (err == error.Nondeterministic) {
                    session.printNondeterministic(init.io);
                    return 2;
                } else if (err == error.TraceUnreadable) {
                    std.Io.File.stderr().writeStreamingAll(init.io, "trace unreadable\n") catch {};
                    return 2;
                }
                return 2;
            };
            defer b.deinit(init.gpa);

            session.printPoints(init.gpa, init.io, b) catch return 2;
            return 0;
        },
        .run => |run_opts| {
            defer session.deinitErrors(init.gpa);
            const b = session.baseline(init.gpa, init.io, run_opts) catch |err| {
                if (err == error.ReferenceFailed) {
                    session.printReferenceFailed(init.io);
                    return 2;
                } else if (err == error.Nondeterministic) {
                    session.printNondeterministic(init.io);
                    return 2;
                } else if (err == error.TraceUnreadable) {
                    std.Io.File.stderr().writeStreamingAll(init.io, "trace unreadable\n") catch {};
                    return 2;
                }
                return 2;
            };
            defer b.deinit(init.gpa);

            if (b.rerun) |finding| {
                switch (finding) {
                    .failed => |exit| {
                        const line = switch (exit) {
                            .code => |c| std.fmt.allocPrint(init.gpa, "RERUN: second run failed (exit {d})\n", .{c}) catch return 2,
                            .signal => |s| std.fmt.allocPrint(init.gpa, "RERUN: second run failed (signal {d})\n", .{s}) catch return 2,
                        };
                        defer init.gpa.free(line);
                        std.Io.File.stdout().writeStreamingAll(init.io, line) catch {};
                        return 1;
                    },
                    .changed => |changes| {
                        std.Io.File.stdout().writeStreamingAll(init.io, "RERUN: second run changed the workspace\n") catch {};
                        for (changes) |c| {
                            const line = std.fmt.allocPrint(init.gpa, "  {s} {s}\n", .{ @tagName(c.what), c.path }) catch continue;
                            defer init.gpa.free(line);
                            std.Io.File.stdout().writeStreamingAll(init.io, line) catch {};
                        }
                        return 1;
                    },
                }
            }

            var externals = std.StringHashMap(usize).init(init.gpa);
            defer externals.deinit();
            for (b.trace.calls) |call| {
                const gop = externals.getOrPut(call.name) catch continue;
                if (!gop.found_existing) {
                    gop.value_ptr.* = 1;
                } else {
                    gop.value_ptr.* += 1;
                }
            }

            const line = std.fmt.allocPrint(init.gpa, "baseline ok: {d} crash points, {d} external commands\n", .{
                b.crash_points.len,
                externals.count(),
            }) catch return 2;
            defer init.gpa.free(line);
            std.Io.File.stdout().writeStreamingAll(init.io, line) catch {};
            return 0;
        },
    }
}

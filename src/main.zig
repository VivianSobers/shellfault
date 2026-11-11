const std = @import("std");
pub const cli = @import("cli.zig");
pub const lua = @import("lua.zig");

test {
    _ = cli;
    _ = lua;
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
        .points => {
            return 0;
        },
        .run => {
            return 0;
        },
    }
}

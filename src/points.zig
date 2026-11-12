const std = @import("std");
const testing = std.testing;
const trace = @import("trace.zig");

pub const Boundary = trace.Boundary;
pub const Call = trace.Call;
pub const Warning = trace.Warning;
pub const Trace = trace.Trace;
pub const stable = trace.stable;

const SourceLine = struct {
    source: []const u8,
    line: u32,
};

const SourceLineContext = struct {
    pub fn hash(self: @This(), sl: SourceLine) u64 {
        _ = self;
        var h = std.hash.Wyhash.init(0);
        h.update(sl.source);
        std.hash.autoHash(&h, sl.line);
        return h.final();
    }
    pub fn eql(self: @This(), a: SourceLine, b: SourceLine) bool {
        _ = self;
        return a.line == b.line and std.mem.eql(u8, a.source, b.source);
    }
};

const FirstLast = struct {
    first: usize,
    last: usize,
};

pub fn firstAndLastPerLine(gpa: std.mem.Allocator, bs: []const Boundary) ![]const Boundary {
    if (bs.len == 0) return try gpa.alloc(Boundary, 0);

    var map = std.HashMap(SourceLine, FirstLast, SourceLineContext, std.hash_map.default_max_load_percentage).init(gpa);
    defer map.deinit();

    for (bs, 0..) |b, i| {
        const key = SourceLine{ .source = b.source, .line = b.line };
        const gop = try map.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .first = i, .last = i };
        } else {
            gop.value_ptr.last = i;
        }
    }

    var result: std.ArrayList(Boundary) = .empty;
    errdefer result.deinit(gpa);

    for (bs, 0..) |b, i| {
        const key = SourceLine{ .source = b.source, .line = b.line };
        const entry = map.get(key).?;
        if (i == entry.first or i == entry.last) {
            try result.append(gpa, b);
        }
    }

    return try result.toOwnedSlice(gpa);
}

test "loop line keeps first and last" {
    const b1: Boundary = .{ .id = "1", .source = "loop.sh", .line = 3, .funcs = "", .command = "echo a" };
    const b2: Boundary = .{ .id = "2", .source = "loop.sh", .line = 3, .funcs = "", .command = "echo b" };
    const b3: Boundary = .{ .id = "3", .source = "loop.sh", .line = 3, .funcs = "", .command = "echo c" };
    const b4: Boundary = .{ .id = "4", .source = "loop.sh", .line = 3, .funcs = "", .command = "echo d" };
    const b5: Boundary = .{ .id = "5", .source = "loop.sh", .line = 3, .funcs = "", .command = "echo e" };
    const b6: Boundary = .{ .id = "6", .source = "loop.sh", .line = 4, .funcs = "", .command = "echo f" };

    const bs = [_]Boundary{ b1, b2, b3, b4, b5, b6 };
    const pts = try firstAndLastPerLine(testing.allocator, &bs);
    defer testing.allocator.free(pts);

    try testing.expectEqual(@as(usize, 3), pts.len);
    try testing.expectEqualStrings("1", pts[0].id);
    try testing.expectEqualStrings("5", pts[1].id);
    try testing.expectEqualStrings("6", pts[2].id);
}

test "duplicate id is not stable" {
    const b1: Boundary = .{ .id = "1", .source = "s.sh", .line = 1, .funcs = "", .command = "cmd1" };
    const b1_dup: Boundary = .{ .id = "1", .source = "s.sh", .line = 1, .funcs = "", .command = "cmd1" };
    const b2: Boundary = .{ .id = "2", .source = "s.sh", .line = 2, .funcs = "", .command = "cmd2" };

    const t1: Trace = .{
        .boundaries = @constCast(&[_]Boundary{ b1, b1_dup, b2 }),
        .calls = &.{},
        .warnings = &.{},
    };
    const t2: Trace = .{
        .boundaries = @constCast(&[_]Boundary{ b1, b2 }),
        .calls = &.{},
        .warnings = &.{},
    };
    const res = try stable(testing.allocator, t1, t2);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(usize, 1), res.len);
    try testing.expectEqualStrings("2", res[0].id);
}

test "id with a different command in the second trace is not stable" {
    const b1_a: Boundary = .{ .id = "1", .source = "s.sh", .line = 1, .funcs = "", .command = "cmdA" };
    const b1_b: Boundary = .{ .id = "1", .source = "s.sh", .line = 1, .funcs = "", .command = "cmdB" };
    const b2: Boundary = .{ .id = "2", .source = "s.sh", .line = 2, .funcs = "", .command = "cmd2" };

    const t1: Trace = .{
        .boundaries = @constCast(&[_]Boundary{ b1_a, b2 }),
        .calls = &.{},
        .warnings = &.{},
    };
    const t2: Trace = .{
        .boundaries = @constCast(&[_]Boundary{ b1_b, b2 }),
        .calls = &.{},
        .warnings = &.{},
    };
    const res = try stable(testing.allocator, t1, t2);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(usize, 1), res.len);
    try testing.expectEqualStrings("2", res[0].id);
}

test "identical traces are fully stable" {
    const b1: Boundary = .{ .id = "1", .source = "s.sh", .line = 1, .funcs = "", .command = "cmd1" };
    const b2: Boundary = .{ .id = "2", .source = "s.sh", .line = 2, .funcs = "", .command = "cmd2" };

    const t1: Trace = .{
        .boundaries = @constCast(&[_]Boundary{ b1, b2 }),
        .calls = &.{},
        .warnings = &.{},
    };
    const t2: Trace = .{
        .boundaries = @constCast(&[_]Boundary{ b1, b2 }),
        .calls = &.{},
        .warnings = &.{},
    };
    const res = try stable(testing.allocator, t1, t2);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(usize, 2), res.len);
    try testing.expectEqualStrings("1", res[0].id);
    try testing.expectEqualStrings("2", res[1].id);
}

test "multiple files on same line keep distinct first and last" {
    const b1: Boundary = .{ .id = "1", .source = "a.sh", .line = 10, .funcs = "", .command = "echo a1" };
    const b2: Boundary = .{ .id = "2", .source = "a.sh", .line = 10, .funcs = "", .command = "echo a2" };
    const b3: Boundary = .{ .id = "3", .source = "b.sh", .line = 10, .funcs = "", .command = "echo b1" };
    const b4: Boundary = .{ .id = "4", .source = "b.sh", .line = 10, .funcs = "", .command = "echo b2" };

    const bs = [_]Boundary{ b1, b2, b3, b4 };
    const pts = try firstAndLastPerLine(testing.allocator, &bs);
    defer testing.allocator.free(pts);

    try testing.expectEqual(@as(usize, 4), pts.len);
    try testing.expectEqualStrings("1", pts[0].id);
    try testing.expectEqualStrings("2", pts[1].id);
    try testing.expectEqualStrings("3", pts[2].id);
    try testing.expectEqualStrings("4", pts[3].id);
}

test "empty boundaries slice" {
    const bs = [_]Boundary{};
    const pts = try firstAndLastPerLine(testing.allocator, &bs);
    defer testing.allocator.free(pts);
    try testing.expectEqual(@as(usize, 0), pts.len);
}

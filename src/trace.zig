const std = @import("std");
const testing = std.testing;

pub const Boundary = struct {
    id: []const u8,
    source: []const u8,
    line: u32,
    funcs: []const u8,
    command: []const u8,
};

pub const Call = struct {
    id: []const u8,
    name: []const u8,
};

pub const Warning = struct {
    id: []const u8,
    source: []const u8,
    line: u32,
    what: []const u8,
};

pub const Trace = struct {
    boundaries: []Boundary,
    calls: []Call,
    warnings: []Warning,

    pub fn deinit(self: Trace, gpa: std.mem.Allocator) void {
        for (self.boundaries) |b| {
            gpa.free(b.command);
        }
        gpa.free(self.boundaries);
        gpa.free(self.calls);
        gpa.free(self.warnings);
    }
};

pub threadlocal var last_error_line: usize = 0;
pub threadlocal var bad_line: usize = 0;
pub threadlocal var bad_line_number: usize = 0;

fn recordErrorLine(line_no: usize) void {
    last_error_line = line_no;
    bad_line = line_no;
    bad_line_number = line_no;
}

pub fn unescapeCommand(gpa: std.mem.Allocator, raw: []const u8) error{ BadTrace, OutOfMemory }![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacityPrecise(gpa, raw.len);

    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\') {
            i += 1;
            if (i >= raw.len) return error.BadTrace;
            switch (raw[i]) {
                '\\' => out.appendAssumeCapacity('\\'),
                't' => out.appendAssumeCapacity('\t'),
                'n' => out.appendAssumeCapacity('\n'),
                'r' => out.appendAssumeCapacity('\r'),
                else => return error.BadTrace,
            }
            i += 1;
        } else {
            out.appendAssumeCapacity(c);
            i += 1;
        }
    }

    return try out.toOwnedSlice(gpa);
}

pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Trace {
    var boundaries: std.ArrayList(Boundary) = .empty;
    var calls: std.ArrayList(Call) = .empty;
    var warnings: std.ArrayList(Warning) = .empty;

    errdefer {
        for (boundaries.items) |b| {
            gpa.free(b.command);
        }
        boundaries.deinit(gpa);
        calls.deinit(gpa);
        warnings.deinit(gpa);
    }

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (line.len == 0) {
            // Trailing empty line after final newline is valid POSIX terminator
            if (it.peek() == null) {
                break;
            }
            recordErrorLine(line_no);
            return error.BadTrace;
        }

        var field_it = std.mem.splitScalar(u8, line, '\t');
        const tag = field_it.next() orelse {
            recordErrorLine(line_no);
            return error.BadTrace;
        };

        if (std.mem.eql(u8, tag, "B")) {
            const id = field_it.next() orelse {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            const source = field_it.next() orelse {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            const line_str = field_it.next() orelse {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            const funcs = field_it.next() orelse {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            const raw_cmd = field_it.next() orelse {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            if (field_it.next() != null) {
                recordErrorLine(line_no);
                return error.BadTrace;
            }

            if (id.len == 0 or source.len == 0) {
                recordErrorLine(line_no);
                return error.BadTrace;
            }

            const line_num = std.fmt.parseInt(u32, line_str, 10) catch {
                recordErrorLine(line_no);
                return error.BadTrace;
            };

            const cmd = unescapeCommand(gpa, raw_cmd) catch {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            errdefer gpa.free(cmd);

            try boundaries.append(gpa, .{
                .id = id,
                .source = source,
                .line = line_num,
                .funcs = funcs,
                .command = cmd,
            });
        } else if (std.mem.eql(u8, tag, "X")) {
            const id = field_it.next() orelse {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            const name = field_it.next() orelse {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            if (field_it.next() != null) {
                recordErrorLine(line_no);
                return error.BadTrace;
            }

            if (id.len == 0 or name.len == 0) {
                recordErrorLine(line_no);
                return error.BadTrace;
            }

            try calls.append(gpa, .{
                .id = id,
                .name = name,
            });
        } else if (std.mem.eql(u8, tag, "W")) {
            const id = field_it.next() orelse {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            const source = field_it.next() orelse {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            const line_str = field_it.next() orelse {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            const what = field_it.next() orelse {
                recordErrorLine(line_no);
                return error.BadTrace;
            };
            if (field_it.next() != null) {
                recordErrorLine(line_no);
                return error.BadTrace;
            }

            if (id.len == 0 or source.len == 0 or what.len == 0) {
                recordErrorLine(line_no);
                return error.BadTrace;
            }

            const line_num = std.fmt.parseInt(u32, line_str, 10) catch {
                recordErrorLine(line_no);
                return error.BadTrace;
            };

            try warnings.append(gpa, .{
                .id = id,
                .source = source,
                .line = line_num,
                .what = what,
            });
        } else {
            recordErrorLine(line_no);
            return error.BadTrace;
        }
    }

    return Trace{
        .boundaries = try boundaries.toOwnedSlice(gpa),
        .calls = try calls.toOwnedSlice(gpa),
        .warnings = try warnings.toOwnedSlice(gpa),
    };
}

pub fn stable(gpa: std.mem.Allocator, a: Trace, b: Trace) ![]const Boundary {
    var a_counts = std.StringHashMap(usize).init(gpa);
    defer a_counts.deinit();

    for (a.boundaries) |ba| {
        const gop = try a_counts.getOrPut(ba.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
        } else {
            gop.value_ptr.* += 1;
        }
    }

    const BInfo = struct {
        count: usize,
        boundary: Boundary,
    };
    var b_map = std.StringHashMap(BInfo).init(gpa);
    defer b_map.deinit();

    for (b.boundaries) |bb| {
        const gop = try b_map.getOrPut(bb.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .count = 1, .boundary = bb };
        } else {
            gop.value_ptr.count += 1;
        }
    }

    var result: std.ArrayList(Boundary) = .empty;
    errdefer result.deinit(gpa);

    for (a.boundaries) |ba| {
        const a_count = a_counts.get(ba.id) orelse 0;
        if (a_count != 1) continue;

        const b_info = b_map.get(ba.id) orelse continue;
        if (b_info.count != 1) continue;

        const bb = b_info.boundary;
        if (ba.line == bb.line and
            std.mem.eql(u8, ba.source, bb.source) and
            std.mem.eql(u8, ba.command, bb.command))
        {
            try result.append(gpa, ba);
        }
    }

    return try result.toOwnedSlice(gpa);
}

test "parses all record kinds" {
    const sample =
        "B\t1\tdeploy.sh\t10\t\techo starting\n" ++
        "X\t1\t/bin/echo\n" ++
        "B\t2\tdeploy.sh\t11\tmain\tcp -r a b\n" ++
        "X\t2\tcp\n" ++
        "W\t3\tdeploy.sh\t20\tdebug-trap-replaced\n";

    const tr = try parse(testing.allocator, sample);
    defer tr.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), tr.boundaries.len);
    try testing.expectEqualStrings("1", tr.boundaries[0].id);
    try testing.expectEqualStrings("deploy.sh", tr.boundaries[0].source);
    try testing.expectEqual(@as(u32, 10), tr.boundaries[0].line);
    try testing.expectEqualStrings("", tr.boundaries[0].funcs);
    try testing.expectEqualStrings("echo starting", tr.boundaries[0].command);

    try testing.expectEqualStrings("2", tr.boundaries[1].id);
    try testing.expectEqualStrings("deploy.sh", tr.boundaries[1].source);
    try testing.expectEqual(@as(u32, 11), tr.boundaries[1].line);
    try testing.expectEqualStrings("main", tr.boundaries[1].funcs);
    try testing.expectEqualStrings("cp -r a b", tr.boundaries[1].command);

    try testing.expectEqual(@as(usize, 2), tr.calls.len);
    try testing.expectEqualStrings("1", tr.calls[0].id);
    try testing.expectEqualStrings("/bin/echo", tr.calls[0].name);
    try testing.expectEqualStrings("2", tr.calls[1].id);
    try testing.expectEqualStrings("cp", tr.calls[1].name);

    try testing.expectEqual(@as(usize, 1), tr.warnings.len);
    try testing.expectEqualStrings("3", tr.warnings[0].id);
    try testing.expectEqualStrings("deploy.sh", tr.warnings[0].source);
    try testing.expectEqual(@as(u32, 20), tr.warnings[0].line);
    try testing.expectEqualStrings("debug-trap-replaced", tr.warnings[0].what);
}

test "unescapes command" {
    const sample = "B\t1\ts.sh\t5\t\tprintf 'hello\\tworld\\nback\\\\slash'\n";

    const tr = try parse(testing.allocator, sample);
    defer tr.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), tr.boundaries.len);
    try testing.expectEqualStrings("printf 'hello\tworld\nback\\slash'", tr.boundaries[0].command);
}

test "bad line is an error with its number" {
    const sample =
        "B\t1\ts.sh\t1\t\techo 1\n" ++
        "B\t2\ts.sh\t2\t\techo 2\n" ++
        "NOT_A_VALID_RECORD\n" ++
        "B\t4\ts.sh\t4\t\techo 4\n";

    try testing.expectError(error.BadTrace, parse(testing.allocator, sample));
    try testing.expectEqual(@as(usize, 3), last_error_line);
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

test "empty trace" {
    const tr = try parse(testing.allocator, "");
    defer tr.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), tr.boundaries.len);
    try testing.expectEqual(@as(usize, 0), tr.calls.len);
    try testing.expectEqual(@as(usize, 0), tr.warnings.len);
}

test "bad line number in B record" {
    const sample = "B\t1\ts.sh\txyz\t\tcmd\n";
    try testing.expectError(error.BadTrace, parse(testing.allocator, sample));
    try testing.expectEqual(@as(usize, 1), last_error_line);
}

test "bad escape sequence in command" {
    const sample = "B\t1\ts.sh\t1\t\techo \\q\n";
    try testing.expectError(error.BadTrace, parse(testing.allocator, sample));
    try testing.expectEqual(@as(usize, 1), last_error_line);
}

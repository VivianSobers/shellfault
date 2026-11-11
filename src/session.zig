const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");
const workspace = @import("workspace.zig");
const supervise = @import("supervise.zig");
const manifest = @import("manifest.zig");
const trace = @import("trace.zig");
const points = @import("points.zig");

const preload_bash = @embedFile("preload.bash");

pub const RerunFinding = union(enum) {
    failed: supervise.Exit,
    changed: []manifest.Change,
};

pub const Baseline = struct {
    reference: manifest.Manifest,
    trace: trace.Trace,
    rerun: ?RerunFinding,
    ambiguous: usize,
    crash_points: []const trace.Boundary,
    trace_text: []const u8,

    pub fn deinit(self: Baseline, gpa: Allocator) void {
        self.reference.deinit(gpa);
        self.trace.deinit(gpa);
        if (self.rerun) |r| {
            switch (r) {
                .changed => |changes| manifest.freeChanges(gpa, changes),
                .failed => {},
            }
        }
        gpa.free(self.crash_points);
        gpa.free(self.trace_text);
    }
};

pub var last_ref_exit: ?supervise.Exit = null;
pub var last_ref_stderr: []const u8 = "";
var last_ref_stderr_raw: ?[]u8 = null;
pub var nondeterministic_changes: ?[]manifest.Change = null;

pub fn deinitErrors(gpa: Allocator) void {
    if (last_ref_stderr_raw) |raw| {
        gpa.free(raw);
        last_ref_stderr_raw = null;
    }
    last_ref_stderr = "";
    last_ref_exit = null;
    if (nondeterministic_changes) |changes| {
        manifest.freeChanges(gpa, changes);
        nondeterministic_changes = null;
    }
}

pub fn printReferenceFailed(io: std.Io) void {
    if (last_ref_exit) |exit| {
        var line_buf: [256]u8 = undefined;
        const msg = switch (exit) {
            .code => |c| std.fmt.bufPrint(&line_buf, "reference run failed (exit {d})\n", .{c}) catch "reference run failed\n",
            .signal => |s| std.fmt.bufPrint(&line_buf, "reference run failed (signal {d})\n", .{s}) catch "reference run failed\n",
        };
        std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    }
    if (last_ref_stderr.len > 0) {
        std.Io.File.stderr().writeStreamingAll(io, last_ref_stderr) catch {};
        if (last_ref_stderr[last_ref_stderr.len - 1] != '\n') {
            std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
        }
    }
}

pub fn printNondeterministic(io: std.Io) void {
    std.Io.File.stderr().writeStreamingAll(io, "two clean runs differ:\n") catch {};
    if (nondeterministic_changes) |changes| {
        for (changes) |c| {
            var line_buf: [4096]u8 = undefined;
            const msg = std.fmt.bufPrint(&line_buf, "  {s} {s}\n", .{ @tagName(c.what), c.path }) catch continue;
            std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
        }
    }
}

pub fn printPoints(gpa: Allocator, io: std.Io, b: Baseline) !void {
    for (b.crash_points) |cp| {
        const line = try std.fmt.allocPrint(gpa, "{s}  {s}:{d}  {s}\n", .{ cp.id, cp.source, cp.line, cp.command });
        defer gpa.free(line);
        try std.Io.File.stdout().writeStreamingAll(io, line);
    }

    if (b.ambiguous > 0) {
        const line = try std.fmt.allocPrint(gpa, "skipped: {d} ambiguous boundaries\n", .{b.ambiguous});
        defer gpa.free(line);
        try std.Io.File.stdout().writeStreamingAll(io, line);
    }

    var externals = std.StringHashMap(usize).init(gpa);
    defer externals.deinit();

    for (b.trace.calls) |call| {
        const gop = try externals.getOrPut(call.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
        } else {
            gop.value_ptr.* += 1;
        }
    }

    const ExtEntry = struct { name: []const u8, count: usize };
    var ext_list: std.ArrayList(ExtEntry) = .empty;
    defer ext_list.deinit(gpa);

    var it = externals.iterator();
    while (it.next()) |entry| {
        try ext_list.append(gpa, .{ .name = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    std.sort.pdq(ExtEntry, ext_list.items, {}, struct {
        fn lessThan(_: void, lhs: ExtEntry, rhs: ExtEntry) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);

    for (ext_list.items) |e| {
        const line = try std.fmt.allocPrint(gpa, "external: {s} ({d} calls)\n", .{ e.name, e.count });
        defer gpa.free(line);
        try std.Io.File.stdout().writeStreamingAll(io, line);
    }

    for (b.trace.warnings) |w| {
        const line = try std.fmt.allocPrint(gpa, "warning: {s}:{d}: DEBUG trap replaced; later points are not covered\n", .{ w.source, w.line });
        defer gpa.free(line);
        try std.Io.File.stdout().writeStreamingAll(io, line);
    }
}

pub fn getLastLines(text: []const u8, max_lines: usize) []const u8 {
    if (text.len == 0 or max_lines == 0) return "";
    var lines: usize = 0;
    var i: usize = text.len;
    if (i > 0 and text[i - 1] == '\n') i -= 1;
    while (i > 0) {
        i -= 1;
        if (text[i] == '\n') {
            lines += 1;
            if (lines >= max_lines) {
                return text[i + 1 ..];
            }
        }
    }
    return text;
}

fn recordRefFailure(gpa: Allocator, io: std.Io, exit: supervise.Exit, stderr_path: []const u8) void {
    last_ref_exit = exit;
    if (last_ref_stderr_raw) |raw| {
        gpa.free(raw);
        last_ref_stderr_raw = null;
    }
    const raw = std.Io.Dir.cwd().readFileAlloc(io, stderr_path, gpa, .limited(1024 * 1024)) catch null;
    last_ref_stderr_raw = raw;
    if (raw) |bytes| {
        last_ref_stderr = getLastLines(bytes, 20);
    } else {
        last_ref_stderr = "";
    }
}

fn getSystemEnvMap(gpa: Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(gpa);
    errdefer map.deinit();

    var i: usize = 0;
    while (std.c.environ[i]) |entry_ptr| : (i += 1) {
        const entry = std.mem.span(entry_ptr);
        if (std.mem.indexOfScalar(u8, entry, '=')) |eq_pos| {
            const key = entry[0..eq_pos];
            const val = entry[eq_pos + 1 ..];
            try map.put(key, val);
        }
    }
    if (!map.contains("PATH")) {
        try map.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    }
    return map;
}

fn resolveBash(gpa: Allocator, io: std.Io, opts: cli.RunOptions, script_path: []const u8) ![]const u8 {
    if (opts.bash) |b| {
        if (b.len > 0) return gpa.dupe(u8, b);
    }

    var buf: [512]u8 = undefined;
    const header = std.Io.Dir.cwd().readFile(io, script_path, &buf) catch "";

    if (std.mem.startsWith(u8, header, "#!")) {
        const line_end = std.mem.indexOfScalar(u8, header, '\n') orelse header.len;
        var line = header[2..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, line, "/usr/bin/env")) {
            var rest = std.mem.trim(u8, line["/usr/bin/env".len..], " \t");
            if (std.mem.startsWith(u8, rest, "-S")) {
                rest = std.mem.trim(u8, rest[2..], " \t");
            }
            var it = std.mem.tokenizeAny(u8, rest, " \t");
            if (it.next()) |cmd| {
                return gpa.dupe(u8, cmd);
            }
            return gpa.dupe(u8, "bash");
        } else {
            var it = std.mem.tokenizeAny(u8, line, " \t");
            if (it.next()) |cmd| {
                return gpa.dupe(u8, cmd);
            }
        }
    }

    return gpa.dupe(u8, "bash");
}

fn getWsTokens(
    io: std.Io,
    ws: []const u8,
    real_buf: *[std.Io.Dir.max_path_bytes]u8,
    tokens_buf: *[2][]const u8,
) ![]const []const u8 {
    var ws_dir = if (std.fs.path.isAbsolute(ws))
        try std.Io.Dir.openDirAbsolute(io, ws, .{})
    else
        try std.Io.Dir.cwd().openDir(io, ws, .{});
    defer ws_dir.close(io);

    const real_len = try ws_dir.realPath(io, real_buf);
    const real_ws = real_buf[0..real_len];

    if (std.mem.eql(u8, ws, real_ws)) {
        tokens_buf[0] = ws;
        return tokens_buf[0..1];
    } else {
        tokens_buf[0] = ws;
        tokens_buf[1] = real_ws;
        return tokens_buf[0..2];
    }
}

fn makeRunId(gpa: Allocator, session_dir: []const u8, run_name: []const u8) ![]const u8 {
    const session_name = std.fs.path.basename(session_dir);
    return std.fmt.allocPrint(gpa, "{s}-{s}", .{ session_name, run_name });
}

fn readTraceText(gpa: Allocator, io: std.Io, trace_path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, trace_path, gpa, .limited(256 * 1024 * 1024)) catch error.TraceUnreadable;
}

pub fn baseline(gpa: Allocator, io: std.Io, opts: cli.RunOptions) !Baseline {
    deinitErrors(gpa);

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    const abs_out = if (std.fs.path.isAbsolute(opts.out))
        try gpa.dupe(u8, opts.out)
    else
        try std.Io.Dir.path.join(gpa, &.{ cwd, opts.out });
    defer gpa.free(abs_out);

    try std.Io.Dir.cwd().createDirPath(io, abs_out);

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const epoch_seconds: u64 = @intCast(ts.sec);
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(epoch_seconds / std.time.epoch.secs_per_day) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = std.time.epoch.DaySeconds{ .secs = @intCast(epoch_seconds % std.time.epoch.secs_per_day) };

    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;
    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    var attempt: usize = 0;
    var session_dir: []const u8 = undefined;
    while (true) : (attempt += 1) {
        const name = if (attempt == 0)
            try std.fmt.allocPrint(gpa, "session-{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
                year, month, day, hour, minute, second,
            })
        else
            try std.fmt.allocPrint(gpa, "session-{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z-{d}", .{
                year, month, day, hour, minute, second, attempt,
            });
        defer gpa.free(name);

        session_dir = try std.Io.Dir.path.join(gpa, &.{ abs_out, name });
        const status = try std.Io.Dir.cwd().createDirPathStatus(io, session_dir, .default_dir);
        if (status == .existed) {
            gpa.free(session_dir);
            continue;
        }
        break;
    }
    defer gpa.free(session_dir);

    // Write preload.bash into session directory
    const preload_path = try std.Io.Dir.path.join(gpa, &.{ session_dir, "preload.bash" });
    defer gpa.free(preload_path);
    {
        var file = try std.Io.Dir.cwd().createFile(io, preload_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, preload_bash);
    }

    const abs_fixture = if (opts.fixture) |fix|
        if (std.fs.path.isAbsolute(fix))
            try gpa.dupe(u8, fix)
        else
            try std.Io.Dir.path.join(gpa, &.{ cwd, fix })
    else
        null;
    defer if (abs_fixture) |fix| gpa.free(fix);

    const abs_script = if (std.fs.path.isAbsolute(opts.script))
        try gpa.dupe(u8, opts.script)
    else
        try std.Io.Dir.path.join(gpa, &.{ cwd, opts.script });
    defer gpa.free(abs_script);

    const bash_exe = try resolveBash(gpa, io, opts, abs_script);
    defer gpa.free(bash_exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bash_exe);
    try argv.append(gpa, abs_script);
    for (opts.args) |arg| {
        try argv.append(gpa, arg);
    }

    var base_env = try getSystemEnvMap(gpa);
    defer base_env.deinit();

    const ref1_run_id = try makeRunId(gpa, session_dir, "ref1");
    defer gpa.free(ref1_run_id);
    const ref2_run_id = try makeRunId(gpa, session_dir, "ref2");
    defer gpa.free(ref2_run_id);
    const rerun_run_id = try makeRunId(gpa, session_dir, "rerun");
    defer gpa.free(rerun_run_id);

    // Run 1: ref1
    const ref1 = try workspace.create(gpa, io, session_dir, "ref1", abs_fixture);
    defer ref1.deinit(gpa);

    var ref1_env = try workspace.env(gpa, io, ref1, &base_env, 1);
    defer ref1_env.deinit();
    try ref1_env.put("BASH_ENV", preload_path);
    try ref1_env.put("SF_MODE", "reference");

    const ref1_stdout = try std.Io.Dir.path.join(gpa, &.{ ref1.ctl, "stdout.log" });
    defer gpa.free(ref1_stdout);
    const ref1_stderr = try std.Io.Dir.path.join(gpa, &.{ ref1.ctl, "stderr.log" });
    defer gpa.free(ref1_stderr);

    const res1 = try supervise.run(gpa, .{
        .argv = argv.items,
        .env = &ref1_env,
        .cwd = ref1.ws,
        .stdout_path = ref1_stdout,
        .stderr_path = ref1_stderr,
        .timeout_ms = opts.timeout_s * 1000,
        .run_id = ref1_run_id,
    });

    if (res1.timed_out or res1.exit != .code or res1.exit.code != 0) {
        recordRefFailure(gpa, io, res1.exit, ref1_stderr);
        return error.ReferenceFailed;
    }

    const ref1_trace_path = try std.Io.Dir.path.join(gpa, &.{ ref1.ctl, "trace.log" });
    defer gpa.free(ref1_trace_path);
    const ref1_trace_text = try readTraceText(gpa, io, ref1_trace_path);
    errdefer gpa.free(ref1_trace_text);

    const ref1_trace = try trace.parse(gpa, ref1_trace_text);
    errdefer ref1_trace.deinit(gpa);

    var ref1_real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var ref1_tokens_buf: [2][]const u8 = undefined;
    const ref1_tokens = try getWsTokens(io, ref1.ws, &ref1_real_buf, &ref1_tokens_buf);

    const ref1_manifest = try manifest.build(gpa, io, ref1.ws, &workspace.default_ignores, ref1_tokens);
    errdefer ref1_manifest.deinit(gpa);

    // Run 2: ref2
    const ref2 = try workspace.create(gpa, io, session_dir, "ref2", abs_fixture);
    defer ref2.deinit(gpa);

    var ref2_env = try workspace.env(gpa, io, ref2, &base_env, 1);
    defer ref2_env.deinit();
    try ref2_env.put("BASH_ENV", preload_path);
    try ref2_env.put("SF_MODE", "reference");

    const ref2_stdout = try std.Io.Dir.path.join(gpa, &.{ ref2.ctl, "stdout.log" });
    defer gpa.free(ref2_stdout);
    const ref2_stderr = try std.Io.Dir.path.join(gpa, &.{ ref2.ctl, "stderr.log" });
    defer gpa.free(ref2_stderr);

    const res2 = try supervise.run(gpa, .{
        .argv = argv.items,
        .env = &ref2_env,
        .cwd = ref2.ws,
        .stdout_path = ref2_stdout,
        .stderr_path = ref2_stderr,
        .timeout_ms = opts.timeout_s * 1000,
        .run_id = ref2_run_id,
    });

    if (res2.timed_out or res2.exit != .code or res2.exit.code != 0) {
        recordRefFailure(gpa, io, res2.exit, ref2_stderr);
        return error.ReferenceFailed;
    }

    const ref2_trace_path = try std.Io.Dir.path.join(gpa, &.{ ref2.ctl, "trace.log" });
    defer gpa.free(ref2_trace_path);
    const ref2_trace_text = try readTraceText(gpa, io, ref2_trace_path);
    defer gpa.free(ref2_trace_text);

    const ref2_trace = try trace.parse(gpa, ref2_trace_text);
    defer ref2_trace.deinit(gpa);

    var ref2_real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var ref2_tokens_buf: [2][]const u8 = undefined;
    const ref2_tokens = try getWsTokens(io, ref2.ws, &ref2_real_buf, &ref2_tokens_buf);

    const ref2_manifest = try manifest.build(gpa, io, ref2.ws, &workspace.default_ignores, ref2_tokens);
    defer ref2_manifest.deinit(gpa);

    const ref_diff = try manifest.diff(gpa, ref1_manifest, ref2_manifest);
    if (ref_diff.len > 0) {
        nondeterministic_changes = ref_diff;
        return error.Nondeterministic;
    }
    manifest.freeChanges(gpa, ref_diff);

    const stable_boundaries = try trace.stable(gpa, ref1_trace, ref2_trace);
    defer gpa.free(stable_boundaries);

    const crash_points = try points.firstAndLastPerLine(gpa, stable_boundaries);
    errdefer gpa.free(crash_points);

    const ambiguous = if (ref1_trace.boundaries.len >= stable_boundaries.len)
        ref1_trace.boundaries.len - stable_boundaries.len
    else
        0;

    // Run 3: rerun
    const rerun_run = try workspace.create(gpa, io, session_dir, "rerun", ref1.ws);
    defer rerun_run.deinit(gpa);

    var rerun_env = try workspace.env(gpa, io, rerun_run, &base_env, 1);
    defer rerun_env.deinit();
    try rerun_env.put("BASH_ENV", preload_path);
    try rerun_env.put("SF_MODE", "reference");

    const rerun_stdout = try std.Io.Dir.path.join(gpa, &.{ rerun_run.ctl, "stdout.log" });
    defer gpa.free(rerun_stdout);
    const rerun_stderr = try std.Io.Dir.path.join(gpa, &.{ rerun_run.ctl, "stderr.log" });
    defer gpa.free(rerun_stderr);

    const res_rerun = try supervise.run(gpa, .{
        .argv = argv.items,
        .env = &rerun_env,
        .cwd = rerun_run.ws,
        .stdout_path = rerun_stdout,
        .stderr_path = rerun_stderr,
        .timeout_ms = opts.timeout_s * 1000,
        .run_id = rerun_run_id,
    });

    var rerun_finding: ?RerunFinding = null;
    if (res_rerun.timed_out or res_rerun.exit != .code or res_rerun.exit.code != 0) {
        rerun_finding = .{ .failed = res_rerun.exit };
    } else {
        var rerun_real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var rerun_tokens_buf: [2][]const u8 = undefined;
        const own_tokens = try getWsTokens(io, rerun_run.ws, &rerun_real_buf, &rerun_tokens_buf);
        // The rerun starts from a copy of ref1's workspace, so files it leaves alone still hold ref1's path.
        var all_tokens_buf: [4][]const u8 = undefined;
        @memcpy(all_tokens_buf[0..own_tokens.len], own_tokens);
        @memcpy(all_tokens_buf[own_tokens.len .. own_tokens.len + ref1_tokens.len], ref1_tokens);
        const rerun_tokens = all_tokens_buf[0 .. own_tokens.len + ref1_tokens.len];

        const rerun_manifest = try manifest.build(gpa, io, rerun_run.ws, &workspace.default_ignores, rerun_tokens);
        defer rerun_manifest.deinit(gpa);

        const rerun_changes = try manifest.diff(gpa, ref1_manifest, rerun_manifest);
        if (rerun_changes.len > 0) {
            rerun_finding = .{ .changed = rerun_changes };
        } else {
            manifest.freeChanges(gpa, rerun_changes);
        }
    }

    return Baseline{
        .reference = ref1_manifest,
        .trace = ref1_trace,
        .rerun = rerun_finding,
        .ambiguous = ambiguous,
        .crash_points = crash_points,
        .trace_text = ref1_trace_text,
    };
}

test "getLastLines extracts tail lines" {
    const text = "line 1\nline 2\nline 3\nline 4\nline 5\n";
    const last3 = getLastLines(text, 3);
    try std.testing.expectEqualStrings("line 3\nline 4\nline 5\n", last3);

    const last10 = getLastLines(text, 10);
    try std.testing.expectEqualStrings(text, last10);

    const empty = getLastLines("", 5);
    try std.testing.expectEqualStrings("", empty);
}

test "resolveBash handles various shebangs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir_path = dir_buf[0..dir_len];

    // Case 1: opts.bash explicit
    {
        const bash = try resolveBash(gpa, io, .{ .script = "foo.sh", .bash = "/custom/bash" }, "foo.sh");
        defer gpa.free(bash);
        try std.testing.expectEqualStrings("/custom/bash", bash);
    }

    // Case 2: #!/usr/bin/env bash
    {
        const script_path = try std.Io.Dir.path.join(gpa, &.{ dir_path, "env_bash.sh" });
        defer gpa.free(script_path);
        {
            var file = try tmp.dir.createFile(io, "env_bash.sh", .{});
            defer file.close(io);
            try file.writeStreamingAll(io, "#!/usr/bin/env bash\necho hi\n");
        }
        const bash = try resolveBash(gpa, io, .{ .script = script_path }, script_path);
        defer gpa.free(bash);
        try std.testing.expectEqualStrings("bash", bash);
    }

    // Case 3: #!/bin/bash
    {
        const script_path = try std.Io.Dir.path.join(gpa, &.{ dir_path, "bin_bash.sh" });
        defer gpa.free(script_path);
        {
            var file = try tmp.dir.createFile(io, "bin_bash.sh", .{});
            defer file.close(io);
            try file.writeStreamingAll(io, "#!/bin/bash\necho hi\n");
        }
        const bash = try resolveBash(gpa, io, .{ .script = script_path }, script_path);
        defer gpa.free(bash);
        try std.testing.expectEqualStrings("/bin/bash", bash);
    }

    // Case 4: No shebang -> defaults to bash
    {
        const script_path = try std.Io.Dir.path.join(gpa, &.{ dir_path, "noshebang.sh" });
        defer gpa.free(script_path);
        {
            var file = try tmp.dir.createFile(io, "noshebang.sh", .{});
            defer file.close(io);
            try file.writeStreamingAll(io, "echo hi\n");
        }
        const bash = try resolveBash(gpa, io, .{ .script = script_path }, script_path);
        defer gpa.free(bash);
        try std.testing.expectEqualStrings("bash", bash);
    }
}

test "baseline on clean idempotent script" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir_path = dir_buf[0..dir_len];

    const script_path = try std.Io.Dir.path.join(gpa, &.{ dir_path, "ok.sh" });
    defer gpa.free(script_path);
    {
        var file = try tmp.dir.createFile(io, "ok.sh", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "#!/usr/bin/env bash\necho ok\n");
    }

    const out_dir = try std.Io.Dir.path.join(gpa, &.{ dir_path, "sf-out" });
    defer gpa.free(out_dir);

    var b = try baseline(gpa, io, .{
        .script = script_path,
        .out = out_dir,
    });
    defer b.deinit(gpa);
    defer deinitErrors(gpa);

    try std.testing.expect(b.rerun == null);
    try std.testing.expect(b.crash_points.len > 0);
}

test "baseline on failing script returns ReferenceFailed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir_path = dir_buf[0..dir_len];

    const script_path = try std.Io.Dir.path.join(gpa, &.{ dir_path, "fail.sh" });
    defer gpa.free(script_path);
    {
        var file = try tmp.dir.createFile(io, "fail.sh", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "#!/usr/bin/env bash\nexit 17\n");
    }

    const out_dir = try std.Io.Dir.path.join(gpa, &.{ dir_path, "sf-out" });
    defer gpa.free(out_dir);

    const res = baseline(gpa, io, .{
        .script = script_path,
        .out = out_dir,
    });
    defer deinitErrors(gpa);

    try std.testing.expectError(error.ReferenceFailed, res);
    try std.testing.expect(last_ref_exit != null);
    try std.testing.expectEqual(@as(u8, 17), last_ref_exit.?.code);
}

const std = @import("std");
const builtin = @import("builtin");

pub const Allocator = std.mem.Allocator;

pub const Spec = struct {
    argv: []const []const u8,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    stdout_path: []const u8,
    stderr_path: []const u8,
    timeout_ms: u32,
    run_id: []const u8,
};

pub const Exit = union(enum) {
    code: u8,
    signal: u8,
};

pub const Result = struct {
    exit: Exit,
    timed_out: bool,
    leftovers: u32,
    duration_ms: u64,
};

pub fn run(gpa: Allocator, spec: Spec) !Result {
    if (spec.argv.len == 0) return error.InvalidArgv;

    var env_map = try spec.env.clone(gpa);
    defer env_map.deinit();
    try env_map.put("SF_RUN_ID", spec.run_id);

    const exec_path_z = try resolveExecPath(gpa, spec.argv[0], &env_map);
    defer gpa.free(exec_path_z);

    const argv_block = try makeArgv(gpa, spec.argv);
    defer argv_block.deinit(gpa);

    const env_block = try env_map.createPosixBlock(gpa, .{});
    defer env_block.deinit(gpa);

    const cwd_z = try gpa.dupeSentinel(u8, spec.cwd, 0);
    defer gpa.free(cwd_z);

    const stdout_path_z = try gpa.dupeSentinel(u8, spec.stdout_path, 0);
    defer gpa.free(stdout_path_z);
    const stderr_path_z = try gpa.dupeSentinel(u8, spec.stderr_path, 0);
    defer gpa.free(stderr_path_z);

    const stdout_fd = std.c.open(stdout_path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (stdout_fd < 0) return error.CannotOpenFile;
    defer _ = std.c.close(stdout_fd);

    const stderr_fd = std.c.open(stderr_path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (stderr_fd < 0) return error.CannotOpenFile;
    defer _ = std.c.close(stderr_fd);

    const stdin_fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (stdin_fd < 0) return error.CannotOpenFile;
    defer _ = std.c.close(stdin_fd);

    if (builtin.os.tag == .linux) {
        _ = std.os.linux.prctl(36, 1, 0, 0, 0); // PR_SET_CHILD_SUBREAPER = 36
    }

    const start_ms = getMonotonicMs();
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        _ = std.c.setpgid(0, 0);
        _ = std.c.dup2(stdin_fd, std.posix.STDIN_FILENO);
        _ = std.c.dup2(stdout_fd, std.posix.STDOUT_FILENO);
        _ = std.c.dup2(stderr_fd, std.posix.STDERR_FILENO);
        if (stdin_fd > 2) _ = std.c.close(stdin_fd);
        if (stdout_fd > 2) _ = std.c.close(stdout_fd);
        if (stderr_fd > 2) _ = std.c.close(stderr_fd);
        // Never run the command anywhere but its own working directory.
        if (std.c.chdir(cwd_z.ptr) != 0) std.c.exit(127);
        _ = std.c.execve(exec_path_z.ptr, argv_block.slice.ptr, env_block.slice.ptr);
        std.c.exit(127);
    }
    // Also set the group from the parent, so signalling -pid cannot race the child's own setpgid.
    _ = std.c.setpgid(pid, pid);

    var status: c_int = 0;
    var timed_out = false;
    while (true) {
        const waited = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
        if (waited == pid) break;
        if (waited < 0) return error.WaitpidFailed;

        const elapsed_ms = getMonotonicMs() - start_ms;
        if (elapsed_ms >= spec.timeout_ms) {
            timed_out = true;
            break;
        }
        sleepMs(10);
    }

    if (groupAlive(pid)) {
        _ = std.c.kill(-pid, std.c.SIG.TERM);
        var term_wait_ms: usize = 0;
        while (term_wait_ms < 2000 and groupAlive(pid)) : (term_wait_ms += 20) {
            sleepMs(20);
        }
        if (groupAlive(pid)) {
            _ = std.c.kill(-pid, std.c.SIG.KILL);
            sleepMs(10);
        }
    }

    if (timed_out) {
        while (true) {
            const waited = std.c.waitpid(pid, &status, 0);
            if (waited == pid or waited < 0) break;
        }
    }

    var leftovers = try cleanupLeftovers(gpa, spec.run_id);
    if (groupAlive(pid)) leftovers += 1;

    const duration_ms = getMonotonicMs() - start_ms;
    return Result{
        .exit = decodeExit(status),
        .timed_out = timed_out,
        .leftovers = leftovers,
        .duration_ms = duration_ms,
    };
}

fn getMonotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const s: u64 = @intCast(ts.sec);
    const ns: u64 = @intCast(ts.nsec);
    return s * 1000 + ns / 1_000_000;
}

fn sleepMs(ms: u64) void {
    var req = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    var rem: std.c.timespec = undefined;
    while (std.c.nanosleep(&req, &rem) != 0) {
        req = rem;
    }
}

fn decodeExit(status: c_int) Exit {
    const ustatus: u32 = @bitCast(status);
    if (std.posix.W.IFEXITED(ustatus)) {
        return .{ .code = @intCast(std.posix.W.EXITSTATUS(ustatus)) };
    }
    return .{ .signal = @intCast(@intFromEnum(std.posix.W.TERMSIG(ustatus))) };
}

const ArgvBlock = struct {
    slice: [:null]?[*:0]u8,

    pub fn deinit(self: ArgvBlock, gpa: Allocator) void {
        for (self.slice) |maybe_p| {
            if (maybe_p) |p| {
                const s = std.mem.sliceTo(p, 0);
                gpa.free(p[0..s.len :0]);
            }
        }
        gpa.free(self.slice);
    }
};

fn makeArgv(gpa: Allocator, argv: []const []const u8) !ArgvBlock {
    const buf = try gpa.allocSentinel(?[*:0]u8, argv.len, null);
    errdefer gpa.free(buf);
    var i: usize = 0;
    errdefer {
        for (buf[0..i]) |maybe_p| {
            if (maybe_p) |p| {
                const s = std.mem.sliceTo(p, 0);
                gpa.free(p[0..s.len :0]);
            }
        }
    }
    for (argv) |a| {
        const z = try gpa.dupeSentinel(u8, a, 0);
        buf[i] = z.ptr;
        i += 1;
    }
    return .{ .slice = buf };
}

fn resolveExecPath(gpa: Allocator, exe: []const u8, env: *const std.process.Environ.Map) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, exe, '/') != null) return gpa.dupeSentinel(u8, exe, 0);
    const path = env.get("PATH") orelse "/usr/bin:/bin:/usr/sbin:/sbin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, exe }, 0);
        defer gpa.free(candidate);
        if (std.c.access(candidate.ptr, std.c.X_OK) == 0) {
            return gpa.dupeSentinel(u8, candidate, 0);
        }
    }
    return error.ExecutableNotFound;
}

fn cleanupLeftovers(gpa: Allocator, run_id: []const u8) !u32 {
    if (builtin.os.tag == .linux) {
        return cleanupLinux(gpa, run_id);
    } else if (builtin.os.tag.isDarwin()) {
        return cleanupDarwin(gpa, run_id);
    }
    return 0;
}

fn cleanupDarwin(gpa: Allocator, run_id: []const u8) !u32 {
    if (!builtin.os.tag.isDarwin()) return 0;
    const my_uid = std.c.getuid();
    const my_pid = std.c.getpid();

    var mib = [_]c_int{ std.c.CTL.KERN, std.c.KERN.PROC, 0 };
    var len: usize = 0;
    if (std.c.sysctl(&mib, 3, null, &len, null, 0) != 0) return 0;

    const buf = try gpa.alloc(u8, len);
    defer gpa.free(buf);
    if (std.c.sysctl(&mib, 3, buf.ptr, &len, null, 0) != 0) return 0;

    const marker = try std.fmt.allocPrint(gpa, "SF_RUN_ID={s}", .{run_id});
    defer gpa.free(marker);

    var to_kill: std.ArrayList(i32) = .empty;
    defer to_kill.deinit(gpa);

    const count = len / 648;
    var args_buf: [65536]u8 = undefined;

    for (0..count) |i| {
        const entry = buf[i * 648 .. (i + 1) * 648];
        const pid = std.mem.readInt(i32, entry[40..44], .little);
        const uid = std.mem.readInt(u32, entry[420..424], .little);
        const ruid = std.mem.readInt(u32, entry[392..396], .little);
        if (pid <= 1 or pid == my_pid) continue;
        if (ruid != my_uid and uid != my_uid) continue;

        var args_mib = [_]c_int{ std.c.CTL.KERN, std.c.KERN.PROCARGS2, pid };
        var args_len: usize = args_buf.len;
        if (std.c.sysctl(&args_mib, 3, &args_buf, &args_len, null, 0) == 0) {
            if (std.mem.indexOf(u8, args_buf[0..args_len], marker) != null) {
                try to_kill.append(gpa, pid);
            }
        }
    }

    if (to_kill.items.len == 0) return 0;

    for (to_kill.items) |p| {
        _ = std.c.kill(p, std.c.SIG.TERM);
    }

    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        var any_alive = false;
        for (to_kill.items) |p| {
            if (pidAlive(p)) {
                any_alive = true;
                break;
            }
        }
        if (!any_alive) break;
        sleepMs(20);
    }

    for (to_kill.items) |p| {
        if (pidAlive(p)) {
            _ = std.c.kill(p, std.c.SIG.KILL);
        }
    }
    sleepMs(10);

    var leftovers: u32 = 0;
    for (to_kill.items) |p| {
        if (pidAlive(p)) leftovers += 1;
    }
    return leftovers;
}

fn cleanupLinux(gpa: Allocator, run_id: []const u8) !u32 {
    if (builtin.os.tag != .linux) return 0;
    var reap_status: c_int = 0;
    while (std.c.waitpid(-1, &reap_status, std.posix.W.NOHANG) > 0) {}

    const marker = try std.fmt.allocPrint(gpa, "SF_RUN_ID={s}", .{run_id});
    defer gpa.free(marker);

    var killed: std.ArrayList(i32) = .empty;
    defer killed.deinit(gpa);

    const dir = std.c.opendir("/proc") orelse return 0;
    defer _ = std.c.closedir(dir);

    const my_pid = std.c.getpid();

    while (std.c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
        const pid = std.fmt.parseInt(i32, name, 10) catch continue;
        if (pid <= 1 or pid == my_pid) continue;

        const env_path = try std.fmt.allocPrintSentinel(gpa, "/proc/{s}/environ", .{name}, 0);
        defer gpa.free(env_path);

        const bytes = readFileAlloc(gpa, env_path, 1 << 20) catch continue;
        defer gpa.free(bytes);

        if (std.mem.indexOf(u8, bytes, marker) == null) continue;

        _ = std.c.kill(pid, std.c.SIG.TERM);
        try killed.append(gpa, pid);
    }

    if (killed.items.len == 0) return 0;

    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        var any_alive = false;
        for (killed.items) |p| {
            if (pidAlive(p)) {
                any_alive = true;
                break;
            }
        }
        if (!any_alive) break;
        sleepMs(20);
    }

    for (killed.items) |p| {
        if (pidAlive(p)) {
            _ = std.c.kill(p, std.c.SIG.KILL);
        }
    }
    sleepMs(10);

    while (std.c.waitpid(-1, &reap_status, std.posix.W.NOHANG) > 0) {}

    var leftovers: u32 = 0;
    for (killed.items) |p| {
        if (pidAlive(p)) leftovers += 1;
    }
    return leftovers;
}

fn groupAlive(pgid: i32) bool {
    const rc = std.c.kill(-pgid, @enumFromInt(0));
    if (rc == 0) return true;
    const err = std.c._errno().*;
    if (err == @intFromEnum(std.c.E.PERM)) return true;
    return false;
}

fn pidAlive(pid: i32) bool {
    const rc = std.c.kill(pid, @enumFromInt(0));
    if (rc == 0) return true;
    const err = std.c._errno().*;
    if (err == @intFromEnum(std.c.E.PERM)) return true;
    return false;
}

fn makePath(gpa: Allocator, root: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, name });
}

fn tmpDirPath(gpa: Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const rel = try std.fmt.allocPrintSentinel(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    defer gpa.free(rel);

    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const res = std.c.realpath(rel.ptr, &buf) orelse return error.RealpathFailed;
    return gpa.dupe(u8, std.mem.sliceTo(res, 0));
}

fn readFileAlloc(gpa: Allocator, path_str: []const u8, max_size: usize) ![]u8 {
    const path_z = try gpa.dupeSentinel(u8, path_str, 0);
    defer gpa.free(path_z);

    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    const buf = try gpa.alloc(u8, max_size);
    errdefer gpa.free(buf);

    var total_read: usize = 0;
    while (total_read < max_size) {
        const rc = std.c.read(fd, buf.ptr + total_read, max_size - total_read);
        if (rc < 0) return error.ReadFailed;
        if (rc == 0) break;
        total_read += @intCast(rc);
    }
    return gpa.realloc(buf, total_read);
}

fn parsePid(bytes: []const u8) !i32 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return std.fmt.parseInt(i32, trimmed, 10);
}

fn initTestEnv(gpa: Allocator) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    try env.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    return env;
}

test "missing cwd does not run the command" {
    const gpa = std.testing.allocator;
    var env = try initTestEnv(gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDirPath(gpa, &tmp);
    defer gpa.free(dir);
    const out = try makePath(gpa, dir, "stdout.log");
    defer gpa.free(out);
    const err = try makePath(gpa, dir, "stderr.log");
    defer gpa.free(err);
    const missing = try makePath(gpa, dir, "no-such-dir");
    defer gpa.free(missing);

    const spec = Spec{
        .argv = &[_][]const u8{ "/bin/sh", "-c", "echo ran" },
        .env = &env,
        .cwd = missing,
        .stdout_path = out,
        .stderr_path = err,
        .timeout_ms = 5000,
        .run_id = "t5-nocwd",
    };
    const got = try run(gpa, spec);
    try std.testing.expectEqualDeep(Exit{ .code = 127 }, got.exit);
    const stdout = try readFileAlloc(gpa, out, 4096);
    defer gpa.free(stdout);
    try std.testing.expectEqualStrings("", stdout);
}

test "reports exit code" {
    const gpa = std.testing.allocator;
    var env = try initTestEnv(gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpDirPath(gpa, &tmp);
    defer gpa.free(cwd);
    const out = try makePath(gpa, cwd, "stdout.log");
    defer gpa.free(out);
    const err = try makePath(gpa, cwd, "stderr.log");
    defer gpa.free(err);

    const spec = Spec{
        .argv = &[_][]const u8{ "/bin/sh", "-c", "exit 3" },
        .env = &env,
        .cwd = cwd,
        .stdout_path = out,
        .stderr_path = err,
        .timeout_ms = 5000,
        .run_id = "t5-exit",
    };
    const got = try run(gpa, spec);
    try std.testing.expect(!got.timed_out);
    try std.testing.expectEqualDeep(Exit{ .code = 3 }, got.exit);
}

test "reports killing signal" {
    const gpa = std.testing.allocator;
    var env = try initTestEnv(gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpDirPath(gpa, &tmp);
    defer gpa.free(cwd);
    const out = try makePath(gpa, cwd, "stdout.log");
    defer gpa.free(out);
    const err = try makePath(gpa, cwd, "stderr.log");
    defer gpa.free(err);

    const spec = Spec{
        .argv = &[_][]const u8{ "/bin/sh", "-c", "kill -9 $$" },
        .env = &env,
        .cwd = cwd,
        .stdout_path = out,
        .stderr_path = err,
        .timeout_ms = 5000,
        .run_id = "t5-signal",
    };
    const got = try run(gpa, spec);
    try std.testing.expectEqualDeep(Exit{ .signal = 9 }, got.exit);
}

test "timeout kills the group" {
    const gpa = std.testing.allocator;
    var env = try initTestEnv(gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpDirPath(gpa, &tmp);
    defer gpa.free(cwd);
    const out = try makePath(gpa, cwd, "stdout.log");
    defer gpa.free(out);
    const err = try makePath(gpa, cwd, "stderr.log");
    defer gpa.free(err);
    const pid_file = try makePath(gpa, cwd, "bg.pid");
    defer gpa.free(pid_file);

    const spec = Spec{
        .argv = &[_][]const u8{ "/bin/sh", "-c", "sleep 100 & echo $! > bg.pid; sleep 100" },
        .env = &env,
        .cwd = cwd,
        .stdout_path = out,
        .stderr_path = err,
        .timeout_ms = 300,
        .run_id = "t5-timeout",
    };
    const got = try run(gpa, spec);
    try std.testing.expect(got.timed_out);

    const pid_txt = try readFileAlloc(gpa, pid_file, 256);
    defer gpa.free(pid_txt);
    const pid = try parsePid(pid_txt);
    try std.testing.expect(!pidAlive(pid));
}

test "double-forked daemon does not survive" {
    const gpa = std.testing.allocator;
    var env = try initTestEnv(gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpDirPath(gpa, &tmp);
    defer gpa.free(cwd);
    const out = try makePath(gpa, cwd, "stdout.log");
    defer gpa.free(out);
    const err = try makePath(gpa, cwd, "stderr.log");
    defer gpa.free(err);
    const pid_file = try makePath(gpa, cwd, "daemon.pid");
    defer gpa.free(pid_file);

    const cmd = if (builtin.os.tag == .linux)
        "(setsid sh -c 'sleep 300 & echo $! > daemon.pid' &) ; sleep 0.1 ; exit 0"
    else
        "nohup sh -c 'sleep 300 & echo $! > daemon.pid' >/dev/null 2>&1 & sleep 0.1 ; exit 0";

    const spec = Spec{
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
        .env = &env,
        .cwd = cwd,
        .stdout_path = out,
        .stderr_path = err,
        .timeout_ms = 5000,
        .run_id = "t5-daemon",
    };
    _ = try run(gpa, spec);

    const pid_txt = try readFileAlloc(gpa, pid_file, 256);
    defer gpa.free(pid_txt);
    const pid = try parsePid(pid_txt);
    try std.testing.expect(!pidAlive(pid));
}

test "stdin is dev null" {
    const gpa = std.testing.allocator;
    var env = try initTestEnv(gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpDirPath(gpa, &tmp);
    defer gpa.free(cwd);
    const out = try makePath(gpa, cwd, "stdout.log");
    defer gpa.free(out);
    const err = try makePath(gpa, cwd, "stderr.log");
    defer gpa.free(err);

    const spec = Spec{
        .argv = &[_][]const u8{ "/bin/sh", "-c", "set -e; read x; echo done" },
        .env = &env,
        .cwd = cwd,
        .stdout_path = out,
        .stderr_path = err,
        .timeout_ms = 2000,
        .run_id = "t5-stdin",
    };
    const got = try run(gpa, spec);
    try std.testing.expect(!got.timed_out);
    try std.testing.expectEqualDeep(Exit{ .code = 1 }, got.exit);
}

test "output goes to the given files" {
    const gpa = std.testing.allocator;
    var env = try initTestEnv(gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpDirPath(gpa, &tmp);
    defer gpa.free(cwd);
    const out = try makePath(gpa, cwd, "stdout.log");
    defer gpa.free(out);
    const err = try makePath(gpa, cwd, "stderr.log");
    defer gpa.free(err);

    const spec = Spec{
        .argv = &[_][]const u8{ "/bin/sh", "-c", "echo hello; echo ohno 1>&2" },
        .env = &env,
        .cwd = cwd,
        .stdout_path = out,
        .stderr_path = err,
        .timeout_ms = 2000,
        .run_id = "t5-output",
    };
    const got = try run(gpa, spec);
    try std.testing.expectEqualDeep(Exit{ .code = 0 }, got.exit);

    const out_bytes = try readFileAlloc(gpa, out, 4096);
    defer gpa.free(out_bytes);
    const err_bytes = try readFileAlloc(gpa, err, 4096);
    defer gpa.free(err_bytes);
    try std.testing.expect(std.mem.indexOf(u8, out_bytes, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_bytes, "ohno") != null);
}

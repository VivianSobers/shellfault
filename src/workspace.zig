const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const EnvMap = std.process.Environ.Map;

pub const default_ignores = [_][]const u8{".sf-tmp/**"};

pub const CloneKind = enum {
    clonefile,
    ficlone,
    copy,
};

pub const Run = struct {
    root: []const u8,
    ws: []const u8,
    ctl: []const u8,

    pub fn deinit(self: Run, gpa: Allocator) void {
        gpa.free(self.root);
        gpa.free(self.ws);
        gpa.free(self.ctl);
    }
};

const darwin = struct {
    extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: u32) c_int;
};

const linux_impl = struct {
    const linux = std.os.linux;
    const FICLONE: u32 = 0x40049409;
    const AT = linux.AT;
    const S = linux.S;

    fn cloneTreeLinux(src: []const u8, dst: []const u8) !CloneKind {
        var src_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        var dst_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        if (src.len >= src_buf.len or dst.len >= dst_buf.len) return error.NameTooLong;
        @memcpy(src_buf[0..src.len], src);
        src_buf[src.len] = 0;
        @memcpy(dst_buf[0..dst.len], dst);
        dst_buf[dst.len] = 0;
        const src_z: [*:0]const u8 = src_buf[0..src.len :0];
        const dst_z: [*:0]const u8 = dst_buf[0..dst.len :0];

        var stx: linux.Statx = undefined;
        const stat_rc = linux.statx(AT.FDCWD, src_z, AT.SYMLINK_NOFOLLOW, linux.STATX{ .TYPE = true, .MODE = true }, &stx);
        if (linux.errno(stat_rc) != .SUCCESS) {
            return error.FileNotFound;
        }

        if (S.ISLNK(stx.mode)) {
            var target_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const link_len = linux.readlinkat(AT.FDCWD, src_z, &target_buf, target_buf.len);
            if (linux.errno(link_len) != .SUCCESS) return error.SystemResources;
            if (link_len >= target_buf.len) return error.NameTooLong;
            target_buf[link_len] = 0;
            const target_z: [*:0]const u8 = target_buf[0..link_len :0];
            const sym_rc = linux.symlinkat(target_z, AT.FDCWD, dst_z);
            if (linux.errno(sym_rc) != .SUCCESS) return error.PathAlreadyExists;
            return .copy;
        } else if (S.ISREG(stx.mode)) {
            return cloneRegularFile(AT.FDCWD, src_z, AT.FDCWD, dst_z, stx.mode & 0o7777);
        } else if (S.ISDIR(stx.mode)) {
            const mkdir_rc = linux.mkdirat(AT.FDCWD, dst_z, stx.mode & 0o7777);
            if (linux.errno(mkdir_rc) != .SUCCESS) return error.PathAlreadyExists;

            const open_src = linux.openat(AT.FDCWD, src_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (linux.errno(open_src) != .SUCCESS) return error.FileNotFound;
            const src_fd: linux.fd_t = @intCast(open_src);
            defer _ = linux.close(src_fd);

            const open_dst = linux.openat(AT.FDCWD, dst_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (linux.errno(open_dst) != .SUCCESS) return error.FileNotFound;
            const dst_fd: linux.fd_t = @intCast(open_dst);
            defer _ = linux.close(dst_fd);

            var result: CloneKind = .ficlone;
            try cloneDirChildren(src_fd, dst_fd, &result);
            return result;
        } else {
            return error.InvalidArgument;
        }
    }

    fn cloneRegularFile(src_dfd: linux.fd_t, src_name: [*:0]const u8, dst_dfd: linux.fd_t, dst_name: [*:0]const u8, mode: u32) !CloneKind {
        const open_src = linux.openat(src_dfd, src_name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(open_src) != .SUCCESS) return error.FileNotFound;
        const sfd: linux.fd_t = @intCast(open_src);
        defer _ = linux.close(sfd);

        const open_dst = linux.openat(dst_dfd, dst_name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, mode);
        if (linux.errno(open_dst) != .SUCCESS) return error.PathAlreadyExists;
        const dfd: linux.fd_t = @intCast(open_dst);
        defer _ = linux.close(dfd);

        const ioctl_rc = linux.ioctl(dfd, FICLONE, @as(usize, @intCast(sfd)));
        if (ioctl_rc == 0) {
            return .ficlone;
        }

        // Fall back to byte copy
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = linux.read(sfd, &buf, buf.len);
            if (n == 0) break;
            if (linux.errno(n) != .SUCCESS) return error.SystemResources;
            var written: usize = 0;
            while (written < n) {
                const w = linux.write(dfd, buf[written..n].ptr, n - written);
                if (linux.errno(w) != .SUCCESS) return error.SystemResources;
                written += w;
            }
        }
        return .copy;
    }

    fn cloneDirChildren(src_dfd: linux.fd_t, dst_dfd: linux.fd_t, result: *CloneKind) !void {
        var buf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
        while (true) {
            const nread = linux.getdents64(src_dfd, &buf, buf.len);
            if (nread == 0) break;
            if (linux.errno(nread) != .SUCCESS) return error.SystemResources;

            var bpos: usize = 0;
            while (bpos < nread) {
                const d: *const linux.dirent64 = @ptrCast(@alignCast(&buf[bpos]));
                bpos += d.reclen;

                const name_ptr: [*:0]const u8 = @ptrCast(&d.name);
                const name = std.mem.span(name_ptr);
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
                    continue;
                }

                var stx: linux.Statx = undefined;
                const stat_rc = linux.statx(src_dfd, name_ptr, AT.SYMLINK_NOFOLLOW, linux.STATX{ .TYPE = true, .MODE = true }, &stx);
                if (linux.errno(stat_rc) != .SUCCESS) continue;

                if (S.ISLNK(stx.mode)) {
                    var target_buf: [Io.Dir.max_path_bytes]u8 = undefined;
                    const link_len = linux.readlinkat(src_dfd, name_ptr, &target_buf, target_buf.len);
                    if (linux.errno(link_len) != .SUCCESS) return error.SystemResources;
                    if (link_len >= target_buf.len) return error.NameTooLong;
                    target_buf[link_len] = 0;
                    const target_z: [*:0]const u8 = target_buf[0..link_len :0];
                    _ = linux.symlinkat(target_z, dst_dfd, name_ptr);
                } else if (S.ISDIR(stx.mode)) {
                    _ = linux.mkdirat(dst_dfd, name_ptr, stx.mode & 0o7777);
                    const open_child_src = linux.openat(src_dfd, name_ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
                    if (linux.errno(open_child_src) == .SUCCESS) {
                        const child_src_fd: linux.fd_t = @intCast(open_child_src);
                        defer _ = linux.close(child_src_fd);
                        const open_child_dst = linux.openat(dst_dfd, name_ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
                        if (linux.errno(open_child_dst) == .SUCCESS) {
                            const child_dst_fd: linux.fd_t = @intCast(open_child_dst);
                            defer _ = linux.close(child_dst_fd);
                            try cloneDirChildren(child_src_fd, child_dst_fd, result);
                        }
                    }
                } else if (S.ISREG(stx.mode)) {
                    const file_kind = try cloneRegularFile(src_dfd, name_ptr, dst_dfd, name_ptr, stx.mode & 0o7777);
                    if (file_kind == .copy) {
                        result.* = .copy;
                    }
                }
            }
        }
    }
};

pub fn cloneTree(src: []const u8, dst: []const u8) !CloneKind {
    if (builtin.os.tag == .linux) {
        return linux_impl.cloneTreeLinux(src, dst);
    } else if (builtin.target.os.tag.isDarwin()) {
        var src_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        var dst_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        if (src.len >= src_buf.len or dst.len >= dst_buf.len) return error.NameTooLong;
        @memcpy(src_buf[0..src.len], src);
        src_buf[src.len] = 0;
        @memcpy(dst_buf[0..dst.len], dst);
        dst_buf[dst.len] = 0;
        const src_z: [*:0]const u8 = src_buf[0..src.len :0];
        const dst_z: [*:0]const u8 = dst_buf[0..dst.len :0];

        const rc = darwin.clonefile(src_z, dst_z, 0);
        if (rc != 0) {
            const err = std.c._errno().*;
            return switch (err) {
                @intFromEnum(std.posix.E.NOENT) => error.FileNotFound,
                @intFromEnum(std.posix.E.EXIST) => error.PathAlreadyExists,
                @intFromEnum(std.posix.E.ACCES), @intFromEnum(std.posix.E.PERM) => error.AccessDenied,
                @intFromEnum(std.posix.E.NOSPC) => error.NoSpaceLeft,
                @intFromEnum(std.posix.E.NAMETOOLONG) => error.NameTooLong,
                @intFromEnum(std.posix.E.NOTDIR) => error.NotDir,
                @intFromEnum(std.posix.E.LOOP) => error.SymLinkLoop,
                @intFromEnum(std.posix.E.ROFS) => error.ReadOnlyFileSystem,
                else => error.SystemResources,
            };
        }
        return .clonefile;
    } else {
        @compileError("unsupported OS tag for cloneTree");
    }
}

pub fn create(gpa: Allocator, io: Io, session_dir: []const u8, name: []const u8, fixture: ?[]const u8) !Run {
    const root = try std.Io.Dir.path.join(gpa, &.{ session_dir, "runs", name });
    errdefer gpa.free(root);
    const ws = try std.Io.Dir.path.join(gpa, &.{ root, "ws" });
    errdefer gpa.free(ws);
    const ctl = try std.Io.Dir.path.join(gpa, &.{ root, "ctl" });
    errdefer gpa.free(ctl);

    try Io.Dir.cwd().createDirPath(io, ctl);

    if (fixture) |fix| {
        _ = try cloneTree(fix, ws);
    } else {
        try Io.Dir.cwd().createDirPath(io, ws);
    }

    return Run{
        .root = root,
        .ws = ws,
        .ctl = ctl,
    };
}

pub fn env(gpa: Allocator, io: Io, run: Run, base: *const EnvMap, seed: u64) !EnvMap {
    var new_map = try base.clone(gpa);
    errdefer new_map.deinit();

    const home = try std.Io.Dir.path.join(gpa, &.{ run.ws, ".sf-home" });
    defer gpa.free(home);
    const tmp = try std.Io.Dir.path.join(gpa, &.{ run.ws, ".sf-tmp" });
    defer gpa.free(tmp);

    const xdg_config = try std.Io.Dir.path.join(gpa, &.{ home, ".config" });
    defer gpa.free(xdg_config);
    const xdg_data = try std.Io.Dir.path.join(gpa, &.{ home, ".local", "share" });
    defer gpa.free(xdg_data);
    const xdg_cache = try std.Io.Dir.path.join(gpa, &.{ home, ".cache" });
    defer gpa.free(xdg_cache);
    const xdg_state = try std.Io.Dir.path.join(gpa, &.{ home, ".local", "state" });
    defer gpa.free(xdg_state);

    try Io.Dir.cwd().createDirPath(io, home);
    try Io.Dir.cwd().createDirPath(io, tmp);
    try Io.Dir.cwd().createDirPath(io, xdg_config);
    try Io.Dir.cwd().createDirPath(io, xdg_data);
    try Io.Dir.cwd().createDirPath(io, xdg_cache);
    try Io.Dir.cwd().createDirPath(io, xdg_state);

    try new_map.put("HOME", home);
    try new_map.put("TMPDIR", tmp);
    try new_map.put("XDG_CONFIG_HOME", xdg_config);
    try new_map.put("XDG_DATA_HOME", xdg_data);
    try new_map.put("XDG_CACHE_HOME", xdg_cache);
    try new_map.put("XDG_STATE_HOME", xdg_state);
    try new_map.put("TZ", "UTC");
    try new_map.put("LC_ALL", "C");
    try new_map.put("SOURCE_DATE_EPOCH", "315532800");
    try new_map.put("SF_CTL", run.ctl);

    const seed_str = try std.fmt.allocPrint(gpa, "{d}", .{seed});
    defer gpa.free(seed_str);
    try new_map.put("SF_SEED", seed_str);

    _ = new_map.swapRemove("SF_ROOT");

    return new_map;
}

test "clone preserves content mode and symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tmp_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(std.testing.io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_len];

    // Create outside file
    const outside_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_path, "outside" });
    defer std.testing.allocator.free(outside_path);
    const outside_file = try Io.Dir.cwd().createFile(std.testing.io, outside_path, .{});
    try outside_file.writeStreamingAll(std.testing.io, "outside content\n");
    outside_file.close(std.testing.io);

    // Create src directory
    const src_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_path, "src" });
    defer std.testing.allocator.free(src_path);
    try Io.Dir.cwd().createDirPath(std.testing.io, src_path);

    // Create regular file with mode 0755
    const exec_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ src_path, "exec.sh" });
    defer std.testing.allocator.free(exec_path);
    const exec_file = try Io.Dir.cwd().createFile(std.testing.io, exec_path, .{});
    try exec_file.writeStreamingAll(std.testing.io, "#!/bin/sh\necho ok\n");
    exec_file.close(std.testing.io);

    try Io.Dir.cwd().setFilePermissions(
        std.testing.io,
        exec_path,
        Io.File.Permissions.fromMode(0o755),
        .{ .follow_symlinks = false },
    );

    // Create symlink to ../outside inside src
    const link_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ src_path, "link_to_outside" });
    defer std.testing.allocator.free(link_path);
    try Io.Dir.cwd().symLink(std.testing.io, "../outside", link_path, .{});

    // Destination path
    const dst_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_path, "dst" });
    defer std.testing.allocator.free(dst_path);

    // Clone tree
    const kind = try cloneTree(src_path, dst_path);
    std.debug.print("cloneTree used {s}\n", .{@tagName(kind)});

    if (builtin.os.tag == .macos) {
        try std.testing.expectEqual(CloneKind.clonefile, kind);
    }

    // Verify cloned executable mode and content
    const dst_exec_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ dst_path, "exec.sh" });
    defer std.testing.allocator.free(dst_exec_path);
    const stat = try Io.Dir.cwd().statFile(std.testing.io, dst_exec_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o777);

    // Verify cloned symlink
    const dst_link_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ dst_path, "link_to_outside" });
    defer std.testing.allocator.free(dst_link_path);
    const link_stat = try Io.Dir.cwd().statFile(std.testing.io, dst_link_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.File.Kind.sym_link, link_stat.kind);

    var target_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const target_len = try Io.Dir.cwd().readLink(std.testing.io, dst_link_path, &target_buf);
    try std.testing.expectEqualStrings("../outside", target_buf[0..target_len]);
}

test "clone of missing fixture is an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tmp_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(std.testing.io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_len];

    const missing = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_path, "missing_fixture" });
    defer std.testing.allocator.free(missing);
    const dst_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_path, "dst" });
    defer std.testing.allocator.free(dst_path);

    try std.testing.expectError(error.FileNotFound, cloneTree(missing, dst_path));
    try std.testing.expectError(error.FileNotFound, create(std.testing.allocator, std.testing.io, tmp_path, "run_fail", missing));
}

test "env points home and tmp into the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tmp_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(std.testing.io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_len];

    const session_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_path, "session" });
    defer std.testing.allocator.free(session_dir);

    var run = try create(std.testing.allocator, std.testing.io, session_dir, "trial-1", null);
    defer run.deinit(std.testing.allocator);

    var base = EnvMap.init(std.testing.allocator);
    defer base.deinit();
    try base.put("SF_ROOT", "/unwanted/root");
    try base.put("PATH", "/usr/bin:/bin");

    var run_env = try env(std.testing.allocator, std.testing.io, run, &base, 12345);
    defer run_env.deinit();

    const expected_home = try std.Io.Dir.path.join(std.testing.allocator, &.{ run.ws, ".sf-home" });
    defer std.testing.allocator.free(expected_home);
    const expected_tmp = try std.Io.Dir.path.join(std.testing.allocator, &.{ run.ws, ".sf-tmp" });
    defer std.testing.allocator.free(expected_tmp);

    try std.testing.expectEqualStrings(expected_home, run_env.get("HOME").?);
    try std.testing.expectEqualStrings(expected_tmp, run_env.get("TMPDIR").?);
    try std.testing.expectEqualStrings("UTC", run_env.get("TZ").?);
    try std.testing.expectEqualStrings("C", run_env.get("LC_ALL").?);
    try std.testing.expectEqualStrings("315532800", run_env.get("SOURCE_DATE_EPOCH").?);
    try std.testing.expectEqualStrings(run.ctl, run_env.get("SF_CTL").?);
    try std.testing.expectEqualStrings("12345", run_env.get("SF_SEED").?);
    try std.testing.expect(run_env.get("SF_ROOT") == null);
    try std.testing.expectEqualStrings("/usr/bin:/bin", run_env.get("PATH").?);

    // Verify directories created
    const home_stat = try Io.Dir.cwd().statFile(std.testing.io, expected_home, .{});
    try std.testing.expectEqual(Io.File.Kind.directory, home_stat.kind);
    const tmp_stat = try Io.Dir.cwd().statFile(std.testing.io, expected_tmp, .{});
    try std.testing.expectEqual(Io.File.Kind.directory, tmp_stat.kind);
}

test "ctl is outside ws" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tmp_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(std.testing.io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_len];

    const session_dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_path, "session" });
    defer std.testing.allocator.free(session_dir);

    var run = try create(std.testing.allocator, std.testing.io, session_dir, "trial-2", null);
    defer run.deinit(std.testing.allocator);

    try std.testing.expect(!std.mem.startsWith(u8, run.ctl, run.ws));
    try std.testing.expect(!std.mem.startsWith(u8, run.ws, run.ctl));

    const expected_root = try std.Io.Dir.path.join(std.testing.allocator, &.{ session_dir, "runs", "trial-2" });
    defer std.testing.allocator.free(expected_root);
    const expected_ws = try std.Io.Dir.path.join(std.testing.allocator, &.{ expected_root, "ws" });
    defer std.testing.allocator.free(expected_ws);
    const expected_ctl = try std.Io.Dir.path.join(std.testing.allocator, &.{ expected_root, "ctl" });
    defer std.testing.allocator.free(expected_ctl);

    try std.testing.expectEqualStrings(expected_root, run.root);
    try std.testing.expectEqualStrings(expected_ws, run.ws);
    try std.testing.expectEqualStrings(expected_ctl, run.ctl);

    const ws_stat = try Io.Dir.cwd().statFile(std.testing.io, run.ws, .{});
    try std.testing.expectEqual(Io.File.Kind.directory, ws_stat.kind);
    const ctl_stat = try Io.Dir.cwd().statFile(std.testing.io, run.ctl, .{});
    try std.testing.expectEqual(Io.File.Kind.directory, ctl_stat.kind);
}

test "benchmark cloneTree on 10,000-file tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tmp_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(std.testing.io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_len];

    const src_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_path, "bench_src" });
    defer std.testing.allocator.free(src_path);
    try Io.Dir.cwd().createDirPath(std.testing.io, src_path);

    // Create 100 directories each with 100 files = 10,000 files
    var d: usize = 0;
    while (d < 100) : (d += 1) {
        var dname_buf: [32]u8 = undefined;
        const dname = try std.fmt.bufPrint(&dname_buf, "d_{d}", .{d});
        const dpath = try std.Io.Dir.path.join(std.testing.allocator, &.{ src_path, dname });
        defer std.testing.allocator.free(dpath);
        try Io.Dir.cwd().createDirPath(std.testing.io, dpath);

        var f: usize = 0;
        while (f < 100) : (f += 1) {
            var fname_buf: [32]u8 = undefined;
            const fname = try std.fmt.bufPrint(&fname_buf, "f_{d}.txt", .{f});
            const fpath = try std.Io.Dir.path.join(std.testing.allocator, &.{ dpath, fname });
            defer std.testing.allocator.free(fpath);

            const file = try Io.Dir.cwd().createFile(std.testing.io, fpath, .{});
            try file.writeStreamingAll(std.testing.io, "hello shellfault\n");
            file.close(std.testing.io);
        }
    }

    const dst_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_path, "bench_dst" });
    defer std.testing.allocator.free(dst_path);

    const t_start = Io.Timestamp.now(std.testing.io, .awake);
    const kind = try cloneTree(src_path, dst_path);
    const t_end = Io.Timestamp.now(std.testing.io, .awake);

    const elapsed_ns = t_end.nanoseconds - t_start.nanoseconds;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const elapsed_s = elapsed_ms / 1000.0;

    std.debug.print("\n=== Benchmark ===\ncloneTree on 10,000 files used {s}: {d:.2} ms ({d:.4} s)\n=================\n", .{
        @tagName(kind),
        elapsed_ms,
        elapsed_s,
    });

    if (builtin.os.tag == .macos) {
        try std.testing.expectEqual(CloneKind.clonefile, kind);
    }
}

test "FICLONE clones files on Linux" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tmp_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(std.testing.io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_len];

    const src_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_path, "linux_src" });
    defer std.testing.allocator.free(src_path);
    try Io.Dir.cwd().createDirPath(std.testing.io, src_path);

    const fpath = try std.Io.Dir.path.join(std.testing.allocator, &.{ src_path, "file.txt" });
    defer std.testing.allocator.free(fpath);
    const file = try Io.Dir.cwd().createFile(std.testing.io, fpath, .{});
    try file.writeStreamingAll(std.testing.io, "ficlone content\n");
    file.close(std.testing.io);

    const dst_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ tmp_path, "linux_dst" });
    defer std.testing.allocator.free(dst_path);

    const kind = try cloneTree(src_path, dst_path);
    std.debug.print("Linux cloneTree used {s}\n", .{@tagName(kind)});
    try std.testing.expect(kind == .ficlone or kind == .copy);
}



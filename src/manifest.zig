const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    file,
    dir,
    symlink,
    other,

    pub fn fromFileKind(k: std.Io.File.Kind) Kind {
        return switch (k) {
            .file => .file,
            .directory => .dir,
            .sym_link => .symlink,
            else => .other,
        };
    }
};

pub const Entry = struct {
    path: []const u8,
    kind: Kind,
    mode: u16,
    size: u64,
    sha256: [32]u8,
    link: []const u8,
};

pub const Manifest = struct {
    entries: []Entry,

    pub fn deinit(self: Manifest, gpa: Allocator) void {
        for (self.entries) |entry| {
            if (entry.path.len > 0) gpa.free(entry.path);
            if (entry.link.len > 0) gpa.free(entry.link);
        }
        gpa.free(self.entries);
    }
};

pub const Change = struct {
    pub const What = enum {
        added,
        removed,
        kind,
        mode,
        content,
        link,
    };

    path: []const u8,
    what: What,
};

pub fn freeChanges(gpa: Allocator, changes: []Change) void {
    for (changes) |c| gpa.free(c.path);
    gpa.free(changes);
}

fn stringLessThan(a: []const u8, b: []const u8) bool {
    const min_len = @min(a.len, b.len);
    for (a[0..min_len], b[0..min_len]) |ca, cb| {
        if (ca < cb) return true;
        if (ca > cb) return false;
    }
    return a.len < b.len;
}

fn stringOrder(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);
    for (a[0..min_len], b[0..min_len]) |ca, cb| {
        if (ca < cb) return .lt;
        if (ca > cb) return .gt;
    }
    return std.math.order(a.len, b.len);
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return stringLessThan(a.path, b.path);
}

pub fn isIgnored(ignores: []const []const u8, rel_path: []const u8) bool {
    for (ignores) |pat| {
        if (matchGlob(pat, rel_path)) return true;
    }
    return false;
}

pub fn matchGlob(pattern: []const u8, path: []const u8) bool {
    var pat = pattern;
    if (std.mem.startsWith(u8, pat, "./")) pat = pat[2..];
    if (std.mem.startsWith(u8, pat, "/")) pat = pat[1..];

    return matchGlobHelper(pat, path);
}

fn matchGlobHelper(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;

    // Pattern ending with "/**"
    if (std.mem.endsWith(u8, pattern, "/**")) {
        const prefix = pattern[0 .. pattern.len - 3];
        if (matchGlobHelper(prefix, path)) return true;
        if (path.len > prefix.len and path[prefix.len] == '/' and matchGlobHelper(prefix, path[0..prefix.len])) {
            return true;
        }
    }

    // Pattern starting with "**"
    if (pattern.len >= 2 and pattern[0] == '*' and pattern[1] == '*') {
        const rest_pat = pattern[2..];
        if (rest_pat.len == 0) return true;
        if (rest_pat[0] == '/') {
            if (matchGlobHelper(rest_pat[1..], path)) return true;
            for (path, 0..) |c, i| {
                if (c == '/') {
                    if (matchGlobHelper(rest_pat[1..], path[i + 1 ..])) return true;
                }
            }
            return false;
        }
        for (0..path.len + 1) |i| {
            if (matchGlobHelper(rest_pat, path[i..])) return true;
        }
        return false;
    }

    if (pattern[0] == '*') {
        const rest_pat = pattern[1..];
        var i: usize = 0;
        while (i <= path.len) : (i += 1) {
            if (matchGlobHelper(rest_pat, path[i..])) return true;
            if (i < path.len and path[i] == '/') break;
        }
        return false;
    }

    if (pattern[0] == '?') {
        if (path.len == 0 or path[0] == '/') return false;
        return matchGlobHelper(pattern[1..], path[1..]);
    }

    if (path.len == 0 or path[0] != pattern[0]) return false;
    return matchGlobHelper(pattern[1..], path[1..]);
}

fn writeEscaped(writer: anytype, s: []const u8) !void {
    const hex_chars = "0123456789abcdef";
    for (s) |b| {
        switch (b) {
            '\\' => try writer.writeAll("\\\\"),
            '\t' => try writer.writeAll("\\t"),
            '\n' => try writer.writeAll("\\n"),
            0x20...0x5b, 0x5d...0x7e => try writer.writeByte(b),
            else => {
                const hex_buf = [4]u8{ '\\', 'x', hex_chars[b >> 4], hex_chars[b & 0x0f] };
                try writer.writeAll(&hex_buf);
            },
        }
    }
}

fn parseHexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn parseEscaped(gpa: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                '\\' => {
                    try out.append(gpa, '\\');
                    i += 2;
                },
                't' => {
                    try out.append(gpa, '\t');
                    i += 2;
                },
                'n' => {
                    try out.append(gpa, '\n');
                    i += 2;
                },
                'r' => {
                    try out.append(gpa, '\r');
                    i += 2;
                },
                'x' => {
                    if (i + 3 < s.len) {
                        const hi = parseHexNibble(s[i + 2]) orelse return error.InvalidEscape;
                        const lo = parseHexNibble(s[i + 3]) orelse return error.InvalidEscape;
                        try out.append(gpa, (hi << 4) | lo);
                        i += 4;
                    } else {
                        return error.InvalidEscape;
                    }
                },
                else => {
                    try out.append(gpa, s[i + 1]);
                    i += 2;
                },
            }
        } else {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(gpa);
}

pub fn write(m: Manifest, writer: anytype) !void {
    const hex_chars = "0123456789abcdef";
    for (m.entries) |entry| {
        try writer.writeAll(@tagName(entry.kind));
        try writer.writeByte('\t');

        try writer.print("{o}\t", .{entry.mode});
        try writer.print("{d}\t", .{entry.size});

        var sha_hex: [64]u8 = undefined;
        for (entry.sha256, 0..) |b, i| {
            sha_hex[i * 2 + 0] = hex_chars[b >> 4];
            sha_hex[i * 2 + 1] = hex_chars[b & 0x0f];
        }
        try writer.writeAll(&sha_hex);
        try writer.writeByte('\t');

        try writeEscaped(writer, entry.path);
        try writer.writeByte('\t');

        try writeEscaped(writer, entry.link);
        try writer.writeByte('\n');
    }
}

pub fn parse(gpa: Allocator, text: []const u8) !Manifest {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |e| {
            if (e.path.len > 0) gpa.free(e.path);
            if (e.link.len > 0) gpa.free(e.link);
        }
        entries.deinit(gpa);
    }

    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        var col_it = std.mem.splitScalar(u8, line, '\t');

        const kind_str = col_it.next() orelse return error.BadManifest;
        const mode_str = col_it.next() orelse return error.BadManifest;
        const size_str = col_it.next() orelse return error.BadManifest;
        const sha_str = col_it.next() orelse return error.BadManifest;
        const path_str = col_it.next() orelse return error.BadManifest;
        const link_str = col_it.next() orelse "";

        const kind: Kind = if (std.mem.eql(u8, kind_str, "file"))
            .file
        else if (std.mem.eql(u8, kind_str, "dir"))
            .dir
        else if (std.mem.eql(u8, kind_str, "symlink"))
            .symlink
        else if (std.mem.eql(u8, kind_str, "other"))
            .other
        else
            return error.BadManifest;

        const mode = std.fmt.parseInt(u16, mode_str, 8) catch return error.BadManifest;
        const size = std.fmt.parseInt(u64, size_str, 10) catch return error.BadManifest;

        if (sha_str.len != 64) return error.BadManifest;
        var sha256: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&sha256, sha_str) catch return error.BadManifest;

        const path = try parseEscaped(gpa, path_str);
        errdefer gpa.free(path);

        const link = if (link_str.len > 0)
            try parseEscaped(gpa, link_str)
        else
            "";
        errdefer if (link.len > 0) gpa.free(link);

        try entries.append(gpa, .{
            .path = path,
            .kind = kind,
            .mode = mode,
            .size = size,
            .sha256 = sha256,
            .link = link,
        });
    }

    std.sort.pdq(Entry, entries.items, {}, entryLessThan);

    return Manifest{ .entries = try entries.toOwnedSlice(gpa) };
}

pub fn diff(gpa: Allocator, a: Manifest, b: Manifest) ![]Change {
    var changes: std.ArrayList(Change) = .empty;
    errdefer {
        for (changes.items) |c| gpa.free(c.path);
        changes.deinit(gpa);
    }

    var i: usize = 0;
    var j: usize = 0;

    while (i < a.entries.len and j < b.entries.len) {
        const ea = a.entries[i];
        const eb = b.entries[j];
        const ord = stringOrder(ea.path, eb.path);

        switch (ord) {
            .lt => {
                try changes.append(gpa, .{
                    .path = try gpa.dupe(u8, ea.path),
                    .what = .removed,
                });
                i += 1;
            },
            .gt => {
                try changes.append(gpa, .{
                    .path = try gpa.dupe(u8, eb.path),
                    .what = .added,
                });
                j += 1;
            },
            .eq => {
                if (ea.kind != eb.kind) {
                    try changes.append(gpa, .{
                        .path = try gpa.dupe(u8, ea.path),
                        .what = .kind,
                    });
                } else {
                    switch (ea.kind) {
                        .file => {
                            if (ea.size != eb.size or !std.mem.eql(u8, &ea.sha256, &eb.sha256)) {
                                try changes.append(gpa, .{
                                    .path = try gpa.dupe(u8, ea.path),
                                    .what = .content,
                                });
                            }
                            if (ea.mode != eb.mode) {
                                try changes.append(gpa, .{
                                    .path = try gpa.dupe(u8, ea.path),
                                    .what = .mode,
                                });
                            }
                        },
                        .symlink => {
                            if (!std.mem.eql(u8, ea.link, eb.link)) {
                                try changes.append(gpa, .{
                                    .path = try gpa.dupe(u8, ea.path),
                                    .what = .link,
                                });
                            }
                            if (ea.mode != eb.mode) {
                                try changes.append(gpa, .{
                                    .path = try gpa.dupe(u8, ea.path),
                                    .what = .mode,
                                });
                            }
                        },
                        .dir => {
                            if (ea.mode != eb.mode) {
                                try changes.append(gpa, .{
                                    .path = try gpa.dupe(u8, ea.path),
                                    .what = .mode,
                                });
                            }
                        },
                        .other => {
                            if (ea.mode != eb.mode) {
                                try changes.append(gpa, .{
                                    .path = try gpa.dupe(u8, ea.path),
                                    .what = .mode,
                                });
                            }
                        },
                    }
                }
                i += 1;
                j += 1;
            },
        }
    }

    while (i < a.entries.len) : (i += 1) {
        try changes.append(gpa, .{
            .path = try gpa.dupe(u8, a.entries[i].path),
            .what = .removed,
        });
    }

    while (j < b.entries.len) : (j += 1) {
        try changes.append(gpa, .{
            .path = try gpa.dupe(u8, b.entries[j].path),
            .what = .added,
        });
    }

    return changes.toOwnedSlice(gpa);
}

pub const token_replacement = "@SF_WS@";
pub const max_normalize_file_size: u64 = 64 * 1024 * 1024;

pub fn replaceTokens(gpa: Allocator, input: []const u8, path_tokens: []const []const u8) !?[]u8 {
    if (path_tokens.len == 0 or input.len == 0) return null;

    var active_tokens: std.ArrayList([]const u8) = .empty;
    defer active_tokens.deinit(gpa);

    for (path_tokens) |tok| {
        if (tok.len > 0) {
            try active_tokens.append(gpa, tok);
        }
    }
    if (active_tokens.items.len == 0) return null;

    var has_match = false;
    for (active_tokens.items) |tok| {
        if (std.mem.indexOf(u8, input, tok) != null) {
            has_match = true;
            break;
        }
    }
    if (!has_match) return null;

    std.sort.pdq([]const u8, active_tokens.items, {}, struct {
        fn greaterLength(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.greaterLength);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    var chunk_start: usize = 0;
    while (i < input.len) {
        var matched_tok: ?[]const u8 = null;
        for (active_tokens.items) |tok| {
            if (std.mem.startsWith(u8, input[i..], tok)) {
                matched_tok = tok;
                break;
            }
        }

        if (matched_tok) |tok| {
            if (i > chunk_start) {
                try out.appendSlice(gpa, input[chunk_start..i]);
            }
            try out.appendSlice(gpa, token_replacement);
            i += tok.len;
            chunk_start = i;
        } else {
            i += 1;
        }
    }

    if (chunk_start < input.len) {
        try out.appendSlice(gpa, input[chunk_start..]);
    }

    return try out.toOwnedSlice(gpa);
}

pub fn build(gpa: Allocator, io: std.Io, root: []const u8, ignores: []const []const u8, path_tokens: []const []const u8) !Manifest {
    var root_dir = if (std.fs.path.isAbsolute(root))
        try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true, .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true, .follow_symlinks = false });
    defer root_dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |e| {
            if (e.path.len > 0) gpa.free(e.path);
            if (e.link.len > 0) gpa.free(e.link);
        }
        entries.deinit(gpa);
    }

    try scanDir(gpa, io, root_dir, "", ignores, path_tokens, &entries);

    std.sort.pdq(Entry, entries.items, {}, entryLessThan);

    return Manifest{ .entries = try entries.toOwnedSlice(gpa) };
}

fn scanDir(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    ignores: []const []const u8,
    path_tokens: []const []const u8,
    entries: *std.ArrayList(Entry),
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |ent| {
        const sub_path = if (rel_prefix.len == 0)
            try gpa.dupe(u8, ent.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, ent.name });
        var sub_path_owned = true;
        defer if (sub_path_owned) gpa.free(sub_path);

        if (isIgnored(ignores, sub_path)) {
            continue;
        }

        const stat = try dir.statFile(io, ent.name, .{ .follow_symlinks = false });
        const kind = Kind.fromFileKind(stat.kind);
        const raw_mode: u32 = @intCast(stat.permissions.toMode());
        const mode: u16 = @truncate(raw_mode & 0o7777);

        switch (kind) {
            .dir => {
                try entries.append(gpa, .{
                    .path = sub_path,
                    .kind = .dir,
                    .mode = mode,
                    .size = 0,
                    .sha256 = @splat(0),
                    .link = "",
                });
                sub_path_owned = false;

                var sub_dir = try dir.openDir(io, ent.name, .{ .iterate = true, .follow_symlinks = false });
                defer sub_dir.close(io);

                try scanDir(gpa, io, sub_dir, sub_path, ignores, path_tokens, entries);
            },
            .symlink => {
                var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const link_len = try dir.readLink(io, ent.name, &target_buf);
                const raw_link = target_buf[0..link_len];
                const replaced_link = try replaceTokens(gpa, raw_link, path_tokens);
                const link = if (replaced_link) |r| r else try gpa.dupe(u8, raw_link);
                var link_owned = true;
                defer if (link_owned) gpa.free(link);

                try entries.append(gpa, .{
                    .path = sub_path,
                    .kind = .symlink,
                    .mode = mode,
                    .size = link.len,
                    .sha256 = @splat(0),
                    .link = link,
                });
                sub_path_owned = false;
                link_owned = false;
            },
            .file => {
                var file = try dir.openFile(io, ent.name, .{});
                defer file.close(io);

                var hash: [32]u8 = undefined;
                var final_size: u64 = stat.size;

                if (stat.size <= max_normalize_file_size and path_tokens.len > 0) {
                    const raw_bytes = try gpa.alloc(u8, @intCast(stat.size));
                    defer gpa.free(raw_bytes);

                    const n = try file.readPositionalAll(io, raw_bytes, 0);
                    const content = raw_bytes[0..n];

                    const replaced = try replaceTokens(gpa, content, path_tokens);
                    if (replaced) |rep| {
                        defer gpa.free(rep);
                        final_size = rep.len;
                        std.crypto.hash.sha2.Sha256.hash(rep, &hash, .{});
                    } else {
                        final_size = content.len;
                        std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});
                    }
                } else {
                    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                    var read_buf: [8192]u8 = undefined;
                    var offset: u64 = 0;
                    while (true) {
                        const n = try file.readPositionalAll(io, &read_buf, offset);
                        if (n == 0) break;
                        hasher.update(read_buf[0..n]);
                        offset += n;
                        if (n < read_buf.len) break;
                    }
                    hasher.final(&hash);
                }

                try entries.append(gpa, .{
                    .path = sub_path,
                    .kind = .file,
                    .mode = mode,
                    .size = final_size,
                    .sha256 = hash,
                    .link = "",
                });
                sub_path_owned = false;
            },
            .other => {
                try entries.append(gpa, .{
                    .path = sub_path,
                    .kind = .other,
                    .mode = mode,
                    .size = stat.size,
                    .sha256 = @splat(0),
                    .link = "",
                });
                sub_path_owned = false;
            },
        }
    }
}

test "identical trees have no changes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const root_path = dir_buf[0..dir_len];

    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello world" });
    try tmp.dir.createDir(io, "sub", .default_dir);
    var sub = try tmp.dir.openDir(io, "sub", .{});
    defer sub.close(io);
    try sub.writeFile(io, .{ .sub_path = "nested.txt", .data = "nested content" });

    var m1 = try build(gpa, io, root_path, &.{}, &.{});
    defer m1.deinit(gpa);
    var m2 = try build(gpa, io, root_path, &.{}, &.{});
    defer m2.deinit(gpa);

    const changes = try diff(gpa, m1, m2);
    defer freeChanges(gpa, changes);

    try std.testing.expectEqual(0, changes.len);
}

test "detects added removed and content changes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const root_path = dir_buf[0..dir_len];

    try tmp.dir.writeFile(io, .{ .sub_path = "removed.txt", .data = "goodbye" });
    try tmp.dir.writeFile(io, .{ .sub_path = "content.txt", .data = "before" });
    try tmp.dir.writeFile(io, .{ .sub_path = "same.txt", .data = "constant" });

    var m1 = try build(gpa, io, root_path, &.{}, &.{});
    defer m1.deinit(gpa);

    try tmp.dir.deleteFile(io, "removed.txt");
    try tmp.dir.writeFile(io, .{ .sub_path = "content.txt", .data = "after" });
    try tmp.dir.writeFile(io, .{ .sub_path = "added.txt", .data = "hello" });

    var m2 = try build(gpa, io, root_path, &.{}, &.{});
    defer m2.deinit(gpa);

    const changes = try diff(gpa, m1, m2);
    defer freeChanges(gpa, changes);

    try std.testing.expectEqual(3, changes.len);
    try std.testing.expectEqualStrings("added.txt", changes[0].path);
    try std.testing.expectEqual(Change.What.added, changes[0].what);

    try std.testing.expectEqualStrings("content.txt", changes[1].path);
    try std.testing.expectEqual(Change.What.content, changes[1].what);

    try std.testing.expectEqualStrings("removed.txt", changes[2].path);
    try std.testing.expectEqual(Change.What.removed, changes[2].what);
}

test "mode change is reported" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const root_path = dir_buf[0..dir_len];

    try tmp.dir.writeFile(io, .{ .sub_path = "script.sh", .data = "#!/bin/bash\necho ok\n" });
    try tmp.dir.setFilePermissions(io, "script.sh", .fromMode(0o644), .{});

    var m1 = try build(gpa, io, root_path, &.{}, &.{});
    defer m1.deinit(gpa);

    try tmp.dir.setFilePermissions(io, "script.sh", .fromMode(0o755), .{});

    var m2 = try build(gpa, io, root_path, &.{}, &.{});
    defer m2.deinit(gpa);

    const changes = try diff(gpa, m1, m2);
    defer freeChanges(gpa, changes);

    try std.testing.expectEqual(1, changes.len);
    try std.testing.expectEqualStrings("script.sh", changes[0].path);
    try std.testing.expectEqual(Change.What.mode, changes[0].what);
}

test "symlink is recorded not followed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const root_path = dir_buf[0..dir_len];

    try tmp.dir.symLink(io, "/etc", "my_etc", .{});

    var m = try build(gpa, io, root_path, &.{}, &.{});
    defer m.deinit(gpa);

    try std.testing.expectEqual(1, m.entries.len);
    try std.testing.expectEqualStrings("my_etc", m.entries[0].path);
    try std.testing.expectEqual(Kind.symlink, m.entries[0].kind);
    try std.testing.expectEqualStrings("/etc", m.entries[0].link);
    const zero_sha: [32]u8 = @splat(0);
    try std.testing.expectEqual(zero_sha, m.entries[0].sha256);
}

test "ignore globs" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const root_path = dir_buf[0..dir_len];

    try tmp.dir.createDir(io, ".sf-tmp", .default_dir);
    var tmp_sub = try tmp.dir.openDir(io, ".sf-tmp", .{});
    defer tmp_sub.close(io);
    try tmp_sub.writeFile(io, .{ .sub_path = "cache.bin", .data = "cached" });

    try tmp.dir.createDir(io, "sub", .default_dir);
    var sub = try tmp.dir.openDir(io, "sub", .{});
    defer sub.close(io);
    try sub.writeFile(io, .{ .sub_path = "build.log", .data = "log in sub" });
    try sub.writeFile(io, .{ .sub_path = "code.zig", .data = "pub fn main() void {}" });

    try tmp.dir.writeFile(io, .{ .sub_path = "build.log", .data = "log in root" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root.zig", .data = "pub const x = 1;" });

    var m = try build(gpa, io, root_path, &.{ ".sf-tmp/**", "*.log" }, &.{});
    defer m.deinit(gpa);

    for (m.entries) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.path, ".sf-tmp"));
        try std.testing.expect(!std.mem.eql(u8, entry.path, "build.log"));
    }

    var found_sub_log = false;
    var found_root_zig = false;
    var found_sub_zig = false;
    for (m.entries) |entry| {
        if (std.mem.eql(u8, entry.path, "sub/build.log")) found_sub_log = true;
        if (std.mem.eql(u8, entry.path, "root.zig")) found_root_zig = true;
        if (std.mem.eql(u8, entry.path, "sub/code.zig")) found_sub_zig = true;
    }
    try std.testing.expect(found_sub_log);
    try std.testing.expect(found_root_zig);
    try std.testing.expect(found_sub_zig);
}

test "awkward names round trip" {
    const gpa = std.testing.allocator;

    const awkward_path = "path with space \tand\nnewline\xffend";
    const awkward_link = "link with space \tand\nnewline\xffend";

    var entries = try gpa.alloc(Entry, 1);
    defer gpa.free(entries);

    var dummy_hash: [32]u8 = undefined;
    @memset(&dummy_hash, 0x42);

    entries[0] = .{
        .path = awkward_path,
        .kind = .symlink,
        .mode = 0o755,
        .size = 1234,
        .sha256 = dummy_hash,
        .link = awkward_link,
    };

    const m = Manifest{ .entries = entries };

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(m, &w);

    const serialized = w.buffered();

    var parsed = try parse(gpa, serialized);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(1, parsed.entries.len);
    try std.testing.expectEqualStrings(awkward_path, parsed.entries[0].path);
    try std.testing.expectEqualStrings(awkward_link, parsed.entries[0].link);
    try std.testing.expectEqual(Kind.symlink, parsed.entries[0].kind);
    try std.testing.expectEqual(@as(u16, 0o755), parsed.entries[0].mode);
    try std.testing.expectEqual(@as(u64, 1234), parsed.entries[0].size);
    try std.testing.expectEqual(dummy_hash, parsed.entries[0].sha256);
}

test "all bytes 0 to 255 round trip" {
    const gpa = std.testing.allocator;

    var all_bytes: [256]u8 = undefined;
    for (0..256) |i| {
        all_bytes[i] = @intCast(i);
    }

    var entries = try gpa.alloc(Entry, 1);
    defer gpa.free(entries);

    var dummy_hash: [32]u8 = undefined;
    @memset(&dummy_hash, 0x99);

    entries[0] = .{
        .path = &all_bytes,
        .kind = .file,
        .mode = 0o600,
        .size = 256,
        .sha256 = dummy_hash,
        .link = &all_bytes,
    };

    const m = Manifest{ .entries = entries };

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(m, &w);

    var parsed = try parse(gpa, w.buffered());
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(1, parsed.entries.len);
    try std.testing.expectEqualStrings(&all_bytes, parsed.entries[0].path);
    try std.testing.expectEqualStrings(&all_bytes, parsed.entries[0].link);
}

test "symlink outside workspace and broken symlink" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const root_path = dir_buf[0..dir_len];

    // Symlink pointing outside workspace (relative)
    try tmp.dir.symLink(io, "../outside_path", "rel_outside", .{});
    // Symlink pointing to nonexistent path
    try tmp.dir.symLink(io, "does_not_exist", "broken_link", .{});

    var m = try build(gpa, io, root_path, &.{}, &.{});
    defer m.deinit(gpa);

    try std.testing.expectEqual(2, m.entries.len);
    // Alphabetically: "broken_link" < "rel_outside"
    try std.testing.expectEqualStrings("broken_link", m.entries[0].path);
    try std.testing.expectEqual(Kind.symlink, m.entries[0].kind);
    try std.testing.expectEqualStrings("does_not_exist", m.entries[0].link);

    try std.testing.expectEqualStrings("rel_outside", m.entries[1].path);
    try std.testing.expectEqual(Kind.symlink, m.entries[1].kind);
    try std.testing.expectEqualStrings("../outside_path", m.entries[1].link);
}

test "diff detects kind change and link change" {
    const gpa = std.testing.allocator;

    var a_entries = try gpa.alloc(Entry, 2);
    defer gpa.free(a_entries);
    var b_entries = try gpa.alloc(Entry, 2);
    defer gpa.free(b_entries);

    const zero_sha: [32]u8 = @splat(0);

    // a has file "alpha" and symlink "beta" -> "target1"
    a_entries[0] = .{
        .path = "alpha",
        .kind = .file,
        .mode = 0o644,
        .size = 10,
        .sha256 = zero_sha,
        .link = "",
    };
    a_entries[1] = .{
        .path = "beta",
        .kind = .symlink,
        .mode = 0o777,
        .size = 7,
        .sha256 = zero_sha,
        .link = "target1",
    };

    // b has symlink "alpha" -> "dest" (kind change) and symlink "beta" -> "target2" (link change)
    b_entries[0] = .{
        .path = "alpha",
        .kind = .symlink,
        .mode = 0o777,
        .size = 4,
        .sha256 = zero_sha,
        .link = "dest",
    };
    b_entries[1] = .{
        .path = "beta",
        .kind = .symlink,
        .mode = 0o777,
        .size = 7,
        .sha256 = zero_sha,
        .link = "target2",
    };

    const m_a = Manifest{ .entries = a_entries };
    const m_b = Manifest{ .entries = b_entries };

    const changes = try diff(gpa, m_a, m_b);
    defer freeChanges(gpa, changes);

    try std.testing.expectEqual(2, changes.len);
    try std.testing.expectEqualStrings("alpha", changes[0].path);
    try std.testing.expectEqual(Change.What.kind, changes[0].what);

    try std.testing.expectEqualStrings("beta", changes[1].path);
    try std.testing.expectEqual(Change.What.link, changes[1].what);
}

test "workspace path in content is normalized" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp1 = std.testing.tmpDir(.{ .iterate = true });
    defer tmp1.cleanup();
    var tmp2 = std.testing.tmpDir(.{ .iterate = true });
    defer tmp2.cleanup();

    var buf1: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len1 = try tmp1.dir.realPath(io, &buf1);
    const root1 = buf1[0..len1];

    var buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len2 = try tmp2.dir.realPath(io, &buf2);
    const root2 = buf2[0..len2];

    const content1 = try std.fmt.allocPrint(gpa, "PATH={s}/bin\n", .{root1});
    defer gpa.free(content1);
    try tmp1.dir.writeFile(io, .{ .sub_path = "profile", .data = content1 });

    const content2 = try std.fmt.allocPrint(gpa, "PATH={s}/bin\n", .{root2});
    defer gpa.free(content2);
    try tmp2.dir.writeFile(io, .{ .sub_path = "profile", .data = content2 });

    var m1 = try build(gpa, io, root1, &.{}, &.{root1});
    defer m1.deinit(gpa);
    var m2 = try build(gpa, io, root2, &.{}, &.{root2});
    defer m2.deinit(gpa);

    const changes = try diff(gpa, m1, m2);
    defer freeChanges(gpa, changes);

    try std.testing.expectEqual(0, changes.len);
}

test "absolute symlink into workspace is normalized" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp1 = std.testing.tmpDir(.{ .iterate = true });
    defer tmp1.cleanup();
    var tmp2 = std.testing.tmpDir(.{ .iterate = true });
    defer tmp2.cleanup();

    var buf1: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len1 = try tmp1.dir.realPath(io, &buf1);
    const root1 = buf1[0..len1];

    var buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len2 = try tmp2.dir.realPath(io, &buf2);
    const root2 = buf2[0..len2];

    try tmp1.dir.createDir(io, "bin", .default_dir);
    try tmp2.dir.createDir(io, "bin", .default_dir);

    const target1 = try std.Io.Dir.path.join(gpa, &.{ root1, "bin" });
    defer gpa.free(target1);
    try tmp1.dir.symLink(io, target1, "current", .{});

    const target2 = try std.Io.Dir.path.join(gpa, &.{ root2, "bin" });
    defer gpa.free(target2);
    try tmp2.dir.symLink(io, target2, "current", .{});

    var m1 = try build(gpa, io, root1, &.{}, &.{root1});
    defer m1.deinit(gpa);
    var m2 = try build(gpa, io, root2, &.{}, &.{root2});
    defer m2.deinit(gpa);

    const changes = try diff(gpa, m1, m2);
    defer freeChanges(gpa, changes);

    try std.testing.expectEqual(0, changes.len);
    for (m1.entries) |entry| {
        if (std.mem.eql(u8, entry.path, "current")) {
            try std.testing.expectEqualStrings("@SF_WS@/bin", entry.link);
        }
    }
}

test "unreadable subdirectory is an error without double free" {
    if (std.c.getuid() == 0) return error.SkipZigTest;

    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const root_path = dir_buf[0..dir_len];

    try tmp.dir.createDir(io, "a", .default_dir);
    var a_dir = try tmp.dir.openDir(io, "a", .{ .iterate = true });
    defer a_dir.close(io);

    try a_dir.createDir(io, "locked", .default_dir);
    var locked_dir = try a_dir.openDir(io, "locked", .{ .iterate = true });
    try locked_dir.writeFile(io, .{ .sub_path = "f.txt", .data = "secret" });
    locked_dir.close(io);

    try a_dir.setFilePermissions(io, "locked", .fromMode(0o000), .{});
    defer a_dir.setFilePermissions(io, "locked", .fromMode(0o755), .{}) catch {};

    const res = build(gpa, io, root_path, &.{}, &.{});
    try std.testing.expectError(error.AccessDenied, res);
}


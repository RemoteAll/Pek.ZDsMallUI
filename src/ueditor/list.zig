//! UEditor 文件管理器（`listimage` / `listfile`）：按目录递归列出、按扩展名过滤、分页。
//!
//! 对齐 C# `Pek.DsMallUI/UEditor/ListFileManager.cs` 的结果结构
//! （`{state, list:[{url}], start, size, total}`）；C# 版用
//! `Directory.GetFiles(..., SearchOption.AllDirectories)`，这里用同样的递归 + 深度上限
//! （防配置成 `/` 时扫全盘）。

const std = @import("std");
const zzig = @import("zzig");

const path = @import("path.zig");

/// 递归遍历深度上限（UEditor 目录一般是 `/images/2026/11/09`，8 层足够）。
pub const MAX_DEPTH: usize = 8;

/// 分页结果。
pub const FileList = struct {
    /// 全量匹配数
    total: usize = 0,
    /// 本页文件 URL（已带 `public_prefix`）
    items: []const []const u8 = &.{},
    /// 起始偏移（回显）
    start: usize = 0,
    /// 请求页大小（回显）
    size: usize = 0,
};

/// 列表结果（失败带具体原因，便于直接回给前端）。
pub const ListResult = union(enum) {
    ok: FileList,
    fail: []const u8,
};

/// 列出目录下的文件。
///
/// - `root`：物理根目录（如 `wwwroot/upload`）；
/// - `relative`：`ueconfig` 里的 `imageManagerListPath`（如 `/images`）；
/// - `extensions`：允许的扩展名（小写、带点）；
/// - `public_prefix`：URL 前缀（如 `/upload`）。
pub fn listFiles(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative: []const u8,
    extensions: []const []const u8,
    public_prefix: []const u8,
    start: usize,
    size: usize,
) ListResult {
    const trimmed = std.mem.trim(u8, relative, " \t");
    const rel = std.mem.trimStart(u8, trimmed, "/");
    const dir_path = std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel }) catch return .{ .fail = "目录路径拼接失败（内存不足）" };

    const stat = zzig.fsio.statFile(io, dir_path) catch |err| {
        const message = std.fmt.allocPrint(arena, "目录不存在：{s}（{s}）", .{ dir_path, @errorName(err) }) catch "目录不存在";
        return .{ .fail = message };
    };
    if (stat.kind != .directory) {
        const message = std.fmt.allocPrint(arena, "不是目录：{s}", .{dir_path}) catch "不是目录";
        return .{ .fail = message };
    }

    var found: std.ArrayList([]const u8) = .empty;
    walk(arena, io, dir_path, MAX_DEPTH, &found) catch |err| {
        const message = std.fmt.allocPrint(arena, "遍历目录失败（{s}）：{s}", .{ dir_path, @errorName(err) }) catch "遍历目录失败";
        return .{ .fail = message };
    };
    std.mem.sort([]const u8, found.items, {}, lessThan);

    const prefix = std.mem.trimEnd(u8, public_prefix, "/");
    var matched: std.ArrayList([]const u8) = .empty;
    for (found.items) |file_path| {
        const ext = path.extensionOf(file_path);
        var lowercase_buffer: [64]u8 = undefined;
        if (ext.len > lowercase_buffer.len) continue;
        for (ext, 0..) |c, index| lowercase_buffer[index] = std.ascii.toLower(c);
        const ext_lower = lowercase_buffer[0..ext.len];

        var ok = false;
        for (extensions) |allowed| {
            if (std.mem.eql(u8, allowed, ext_lower)) {
                ok = true;
                break;
            }
        }
        if (!ok) continue;

        const rel_file = if (std.mem.startsWith(u8, file_path, root))
            std.mem.trimStart(u8, file_path[root.len..], "/")
        else
            file_path;
        matched.append(arena, std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, rel_file }) catch file_path) catch {
            return .{ .fail = "内存不足（列表）" };
        };
    }

    const total = matched.items.len;
    const page_size = if (size == 0) 1 else size;
    const begin = @min(start, total);
    const end = @min(begin + page_size, total);

    return .{ .ok = .{
        .total = total,
        .items = matched.items[begin..end],
        .start = start,
        .size = size,
    } };
}

/// 递归收集文件路径（`depth` 为 0 时停止）。
fn walk(
    arena: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    depth: usize,
    out: *std.ArrayList([]const u8),
) !void {
    if (depth == 0) return;

    var dir = try zzig.fsio.openDirIterable(io, dir_path);
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const child = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => try walk(arena, io, child, depth - 1, out),
            .file, .sym_link => try out.append(arena, child),
            else => {},
        }
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ————— 测试 —————

const testing = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    root: []const u8,

    fn init(tag: []const u8, files: []const []const u8) !Fixture {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const arena = arena_state.allocator();
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".", arena);
        const root = try std.fmt.allocPrint(arena, "{s}/.zig-cache/zdsmallui-list-{s}", .{ cwd, tag });
        std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
        try zzig.fsio.makePath(testing.io, root);

        for (files) |relative| {
            const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, relative });
            if (std.fs.path.dirname(full)) |parent| try zzig.fsio.makePath(testing.io, parent);
            try zzig.fsio.writeFile(testing.io, full, "x");
        }
        return .{ .arena_state = arena_state, .root = root };
    }

    fn deinit(self: *Fixture) void {
        const root = self.root;
        std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
        self.arena_state.deinit();
    }
};

test "文件列表：递归列举、扩展名过滤、URL 前缀" {
    var fixture = try Fixture.init("basic", &.{
        "images/2026/a.png",
        "images/2026/b.jpg",
        "images/2026/c.txt",
        "images/2026/d.PNG",
        "images/readme.md",
    });
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const result = listFiles(arena, testing.io, fixture.root, "/images", &.{ ".png", ".jpg" }, "/upload", 0, 10);
    try testing.expect(result == .ok);
    try testing.expectEqual(@as(usize, 3), result.ok.total);
    for (result.ok.items) |url| {
        try testing.expect(std.mem.startsWith(u8, url, "/upload/images/2026/"));
    }
    // 目录内的其它扩展名不出现
    for (result.ok.items) |url| {
        try testing.expect(std.mem.indexOf(u8, url, ".txt") == null);
        try testing.expect(std.mem.indexOf(u8, url, ".md") == null);
    }
}

test "文件列表：分页与起始偏移越界" {
    var fixture = try Fixture.init("page", &.{
        "images/a.png",
        "images/b.png",
        "images/c.png",
    });
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const page = listFiles(arena, testing.io, fixture.root, "/images", &.{".png"}, "/upload", 2, 1);
    try testing.expect(page == .ok);
    try testing.expectEqual(@as(usize, 3), page.ok.total);
    try testing.expectEqual(@as(usize, 1), page.ok.items.len);
    try testing.expectEqual(@as(usize, 2), page.ok.start);

    const beyond = listFiles(arena, testing.io, fixture.root, "/images", &.{".png"}, "/upload", 99, 10);
    try testing.expect(beyond == .ok);
    try testing.expectEqual(@as(usize, 0), beyond.ok.items.len);

    const bigger_page = listFiles(arena, testing.io, fixture.root, "/images", &.{".png"}, "/upload", 1, 10);
    try testing.expect(bigger_page == .ok);
    try testing.expectEqual(@as(usize, 2), bigger_page.ok.items.len);
}

test "文件列表：目录不存在给出具体原因" {
    var fixture = try Fixture.init("missing", &.{"images/a.png"});
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const result = listFiles(arena, testing.io, fixture.root, "/nope", &.{".png"}, "/upload", 0, 10);
    try testing.expect(result == .fail);
    try testing.expect(std.mem.indexOf(u8, result.fail, "目录不存在") != null);
}

//! 扫描视图目录 → 生成 `views_generated.zig`（包内相对路径的 `@embedFile` 清单）。
//!
//! 为什么不用手写清单：新增一个 `.zshtml` 就得记得去 `src/views.zig` 加一行，
//! 漏了就是「视图不存在」的运行时 500。
//!
//! 为什么是**独立可执行程序**而不是在 `build.zig` 配置阶段扫描：
//! `zig build` 会缓存 `build()` 的执行结果（build.zig 内容不变就不重跑），
//! 配置阶段的副作用会导致「新增视图但清单没更新」—— 静默失效（2026-11-23 实测踩到）。
//! 做成 run step 并以 `Views` / `Areas` 目录作为输入依赖后，内容一变就会重跑。
//!
//! 用法（由 `build.zig` 自动调用，通常不用手跑）：
//! ```powershell
//! zig build gen-views
//! ```

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator(); // 进程内一次分配，退出即回收
    const io = init.io;
    var cwd = std.Io.Dir.cwd();

    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(gpa);

    // 参数：由 build.zig 传入（`Views` `Areas` 两个目录），缺省用默认值
    const argv = try init.minimal.args.toSlice(gpa);
    const views_dir = if (argv.len > 1) argv[1] else "Views";
    const areas_dir = if (argv.len > 2) argv[2] else "Areas";

    // 1) 共享视图 `Views/**/*.zshtml`
    if (cwd.openDir(io, views_dir, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zshtml")) continue;
            const normalized = try normalizeSlashes(gpa, entry.path);
            try entries.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ views_dir, normalized }));
        }
    } else |_| {}

    // 2) 区域视图 `Areas/**/Views/**/*.zshtml`（可执行程序参数里传 `Areas`）
    if (cwd.openDir(io, areas_dir, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zshtml")) continue;
            const normalized = try normalizeSlashes(gpa, entry.path);
            // 只要 `.../Views/...` 下的：`Admin/Views/Home/Index.zshtml`
            if (std.mem.indexOf(u8, normalized, "Views/") == null) continue;
            try entries.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ areas_dir, normalized }));
        }
    } else |_| {}

    // 稳定顺序（生成文件可 diff；测试输出可复现）
    std.mem.sort([]const u8, entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(
        \\//! **自动生成，请勿手改** —— `zig build` 时由 `tools/gen_views.zig` 扫描
        \\//! `Views/**` 与 `Areas/**/Views/**` 下的 `.zshtml` 生成；新增视图不用改任何清单。
        \\
        \\pub const Entry = struct {
        \\    /// 相对库根的规范路径（`/` 分隔）
        \\    relative: []const u8,
        \\    /// 模板源码（编译期内嵌）
        \\    source: []const u8,
        \\};
        \\
        \\pub const ENTRIES = [_]Entry{
        \\
    );
    for (entries.items) |relative| {
        try writer.print("    .{{ .relative = \"{s}\", .source = @embedFile(\"{s}\") }},\n", .{ relative, relative });
    }
    try writer.writeAll("};\n");

    // 内容相同就不写（避免每次 build 都改 mtime → 触发下游重编）
    const target_path = "views_generated.zig";
    const existing = cwd.readFileAlloc(io, target_path, gpa, .limited(4 * 1024 * 1024)) catch null;
    const content = out.written();
    if (existing) |old| {
        if (std.mem.eql(u8, old, content)) return;
    }
    try cwd.writeFile(io, .{ .sub_path = target_path, .data = content });
}

/// 把 Windows 原生分隔符 `\` 换成 `/`（`relative` 是跨平台的**规范路径**）。
fn normalizeSlashes(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    const out = try gpa.alloc(u8, path.len);
    for (path, 0..) |c, i| out[i] = if (c == '\\') '/' else c;
    return out;
}

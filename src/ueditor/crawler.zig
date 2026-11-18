//! UEditor 远程图片抓取（`catchimage`）。
//!
//! 对齐 C# `Pek.DsMallUI/UEditor/CrawlerHandler.cs`：接收 `source[]` 列表（最多 10 个），
//! 逐个下载并落盘到本地上传目录，返回 `{state:"SUCCESS", list:[{state, source, url}]}`。
//!
//! 与 C# 的差异（C# 版把下载逻辑整体注释掉了，只回 `state=null`）：
//! - 这里真正实现下载，走 `zzig.Http.fetchBytesWithTimeout`（**带 20 秒超时**，
//!   避免远端挂死拖住请求线程）；
//! - **协议白名单**：只允许 `http`/`https`（C# 注释里的 `IsExternalAddress` 校验在上游缺失，
//!   会导致 SSRF 到 `file://` / 内网元数据地址）；
//! - 单文件体积上限取 `catcherMaxSize`，超限直接失败。
//!
//! 已知差异：`zzig.Http` 的响应只回状态与正文、不含响应头，故扩展名按 URL 末段推断，
//! 无扩展名时按 `.jpg` 兜底（Rust 版按 `Content-Type` 猜；两者在「URL 带扩展名」的
//! 常见场景下结果一致）。

const std = @import("std");
const zzig = @import("zzig");

const config_mod = @import("config.zig");
const path = @import("path.zig");
const upload = @import("upload.zig");

/// 抓取列表上限（与 C# `sources.Length <= 10` 的约束一致）。
pub const MAX_SOURCES: usize = 10;

/// 单个来源的抓取超时。
pub const FETCH_TIMEOUT_MS: u64 = 20_000;

/// 抓取一个请求里的全部来源。
///
/// `sources` 来自表单字段 `source[]`（可重复）。
pub fn catchImages(
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.UeditorConfig,
    uploader: upload.Uploader,
    sources: []const []const u8,
) !zzig.web.Value {
    if (sources.len == 0) {
        var builder = zzig.web.ObjectBuilder.init(arena);
        try builder.str("state", "参数错误：没有指定抓取源");
        return builder.finish();
    }
    if (sources.len > MAX_SOURCES) {
        var builder = zzig.web.ObjectBuilder.init(arena);
        try builder.str("state", try std.fmt.allocPrint(arena, "抓取源超过上限 {d} 个", .{MAX_SOURCES}));
        return builder.finish();
    }

    var upload_config = try upload.UploadConfig.image(arena, config);
    // 抓取图片用自己的格式与大小配置
    if (config.getStr("catcherPathFormat")) |value| upload_config.path_format = value;
    if (config.getInt("catcherMaxSize")) |size| {
        if (size > 0) upload_config.size_limit = @intCast(size);
    }
    const allow = try config.getStringList(arena, "catcherAllowFiles");
    if (allow.len > 0) upload_config.allow_extensions = allow;

    var entries = try arena.alloc(zzig.web.Value, sources.len);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    for (sources, 0..) |raw_source, index| {
        const source = std.mem.trim(u8, raw_source, " \t\r\n");
        entries[index] = switch (fetchOne(arena, allocator, &client, source, upload_config, uploader)) {
            .ok => |url| blk: {
                var builder = zzig.web.ObjectBuilder.init(arena);
                try builder.str("state", "SUCCESS");
                try builder.str("source", source);
                try builder.str("url", url);
                break :blk builder.finish();
            },
            .fail => |reason| blk: {
                var builder = zzig.web.ObjectBuilder.init(arena);
                try builder.str("state", try std.fmt.allocPrint(arena, "抓取错误：{s}", .{reason}));
                try builder.str("source", source);
                try builder.str("url", "");
                break :blk builder.finish();
            },
        };
    }

    var builder = zzig.web.ObjectBuilder.init(arena);
    try builder.str("state", "SUCCESS");
    try builder.list("list", entries);
    return builder.finish();
}

const FetchOutcome = union(enum) {
    ok: []const u8,
    fail: []const u8,
};

/// 下载单张图片并落盘，返回可访问 URL。
fn fetchOne(
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    source: []const u8,
    config: upload.UploadConfig,
    uploader: upload.Uploader,
) FetchOutcome {
    const lower_ok = std.ascii.startsWithIgnoreCase(source, "http://") or
        std.ascii.startsWithIgnoreCase(source, "https://");
    if (!lower_ok) {
        return .{ .fail = std.fmt.allocPrint(arena, "不支持的协议（仅 http/https）：{s}", .{truncate(arena, source, 120)}) catch "不支持的协议" };
    }

    const options = zzig.Http.RequestOptions{ .url = source, .method = .GET };
    const response = zzig.Http.fetchBytesWithTimeout(allocator, client, options, FETCH_TIMEOUT_MS, 50) catch |err| {
        return .{ .fail = std.fmt.allocPrint(arena, "下载失败（{s}）", .{@errorName(err)}) catch "下载失败" };
    };
    defer allocator.free(response.body);

    const status = @backingInt(response.status);
    if (status < 200 or status > 299) {
        return .{ .fail = std.fmt.allocPrint(arena, "远端返回 HTTP {d}", .{status}) catch "远端返回错误状态" };
    }
    if (response.body.len == 0) return .{ .fail = "远端返回空内容" };

    // 文件名：URL 末段（去查询串/片段），没有扩展名时按 content-type 猜（此处按 .jpg 兜底）
    const name = fileNameOf(arena, source) catch "remote.jpg";
    const outcome = uploader.saveBytes(arena, config, name, response.body);
    if (outcome.state.isSuccess()) {
        return .{ .ok = outcome.url orelse "" };
    }
    return .{ .fail = outcome.err orelse outcome.state.message() };
}

/// 从 URL 推断落盘文件名（去掉 `?` / `#` 之后的内容；补默认扩展名）。
fn fileNameOf(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    var end = source.len;
    if (std.mem.indexOfAny(u8, source, "?#")) |index| end = index;
    const trimmed = source[0..end];

    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    const segment = if (slash) |index| trimmed[index + 1 ..] else trimmed;
    if (segment.len == 0) {
        return std.fmt.allocPrint(arena, "{d}.jpg", .{zzig.compat.timestamp()});
    }
    if (path.extensionOf(segment).len == 0) {
        return std.fmt.allocPrint(arena, "{s}.jpg", .{segment});
    }
    return arena.dupe(u8, segment);
}

/// 截断长文本（错误消息里避免倾倒整条 URL）。
fn truncate(arena: std.mem.Allocator, text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    return std.fmt.allocPrint(arena, "{s}…", .{text[0..max]}) catch text;
}

/// 便于调用方在无网络环境做单元测试：仅校验来源列表。
pub fn validateSources(sources: []const []const u8) ?[]const u8 {
    if (sources.len == 0) return "参数错误：没有指定抓取源";
    if (sources.len > MAX_SOURCES) return "抓取源超过上限 10 个";
    return null;
}

// ————— 测试 —————

const testing = std.testing;

test "抓取：来源数量校验" {
    try testing.expect(validateSources(&.{}) != null);
    const many = [_][]const u8{ "http://a/1.png", "http://a/2.png", "http://a/3.png", "http://a/4.png", "http://a/5.png", "http://a/6.png", "http://a/7.png", "http://a/8.png", "http://a/9.png", "http://a/10.png", "http://a/11.png" };
    try testing.expect(validateSources(&many) != null);
    try testing.expect(validateSources(many[0..10]) == null);
}

test "抓取：非 http/https 协议不发起网络请求就失败" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var config = try config_mod.UeditorConfig.embedded(arena);
    _ = &config;
    const uploader = upload.Uploader.init(arena, testing.io, ".zig-cache/zdsmallui-crawler", "/upload");
    const upload_config = try upload.UploadConfig.image(arena, config);

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const outcome = fetchOne(arena, testing.allocator, &client, "file:///etc/passwd", upload_config, uploader);
    try testing.expect(outcome == .fail);
    try testing.expect(std.mem.indexOf(u8, outcome.fail, "仅 http/https") != null);
}

test "抓取：URL 文件名推断" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("a.png", try fileNameOf(arena, "http://x/y/a.png?w=1#frag"));
    try testing.expectEqualStrings("noext.jpg", try fileNameOf(arena, "http://x/y/noext"));
    try testing.expectEqualStrings("中文.png", try fileNameOf(arena, "http://x/中文.png"));
}

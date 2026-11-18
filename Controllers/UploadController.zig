//! 上传控制器（对应 C# `Pek.DsMallUI/Controllers/UploadController.cs`）。
//!
//! | 路由 | 说明 |
//! |---|---|
//! | `GET/POST /fileuploader?action=...` | UEditor 统一入口（C# 的绝对路由，前端配置的 `serverUrl`） |
//! | `GET/POST /Upload/fileuploader` | 同上，MVC 风格别名（`{controller}/{action}`） |
//! | `GET /Upload/downloads/{path}` | 下载上传目录内的文件（对应 C# `[Route("downloads")]`） |
//!
//! 下载为什么走**兜底处理器**：上传目录天然是多层（`images/2026/11/09/x.png`），
//! 路由占位只支持单段 `{name}`；而 zzig 的中间件只在「命中路由」或「设置了 fallback」时执行，
//! 未命中路由的深路径根本进不了中间件。因此这里注册 fallback：
//! **上传目录下载 → wwwroot 静态资源 → 404**，既覆盖深路径，又与 `App` 默认行为保持一致。
//! 文件解析复用 `zzig.web.StaticFiles`（路径穿越防护 + ETag/304 + 流式发送）。

const std = @import("std");
const zzig = @import("zzig");

const ueditor = @import("../src/ueditor/mod.zig");

const router = zzig.web.router;

/// 下载路由前缀（大小写不敏感匹配）。
pub const DOWNLOAD_PREFIX = "/upload/downloads/";

/// 上传控制器。
pub const UploadController = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    service: ueditor.UeditorService,
    downloads: zzig.web.StaticFiles,
    prefix: []const u8,
    /// 挂载时的应用（下载未命中时回退到 wwwroot 静态资源）
    app: ?*zzig.web.App = null,

    /// `upload_root` 同时作为下载根与静态根（与 C# 的 `WebRootPath + UploadPath` 一致）。
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        service: ueditor.UeditorService,
        upload_root: []const u8,
    ) !*UploadController {
        const self = try allocator.create(UploadController);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .service = service,
            .downloads = try zzig.web.StaticFiles.init(allocator, io, upload_root),
            .prefix = DOWNLOAD_PREFIX,
        };
        // 下载目录要允许「非常规扩展名」（上传文件类型由 ueconfig 白名单控制）
        self.downloads.serveUnknownFileTypes(true);
        return self;
    }

    /// 释放下载目录的静态资源表与服务配置。
    pub fn deinit(self: *UploadController) void {
        self.downloads.deinit();
        self.allocator.destroy(self);
    }

    /// UEditor 服务引用（供上层读取配置）。
    pub fn ueditorService(self: *const UploadController) *const ueditor.UeditorService {
        return &self.service;
    }

    /// 挂载入口路由与下载兜底。
    pub fn mount(self: *UploadController, app: *zzig.web.App) !void {
        // ① C# 绝对路由：/fileuploader（UEditor 前端 serverUrl 的默认形态）
        const entry = router.Handler{ .ctx = @ptrCast(self), .call = entryHandler };
        try app.map("*", "/fileuploader", entry);

        // ② MVC 风格别名：/Upload/fileuploader（路由器段匹配大小写不敏感）
        try app.map("*", "/upload/fileuploader", entry);

        // ③ 下载 + 静态兜底：/Upload/downloads/{多层路径}
        self.app = app;
        app.router.fallback(.{ .ctx = @ptrCast(self), .call = fallbackHandler });
    }

    /// 统一入口：执行一次 UEditor 请求并返回 JSON。
    fn entryHandler(raw: ?*anyopaque, c: *router.Ctx) anyerror!router.Response {
        const self: *UploadController = @ptrCast(@alignCast(raw orelse return error.MissingController));
        // 未带 action 时按 UEditor 惯例回配置（前端初始化会先取一次配置）
        const action = c.queryValue("action") orelse "config";
        const json = try self.service.handle(c.arena, action, c.query, c.header("content-type"), c.req.body);
        return router.Response.bytes(.ok, "application/json; charset=utf-8", json);
    }

    /// 兜底：上传目录下载 → wwwroot 静态 → 404。
    fn fallbackHandler(raw: ?*anyopaque, c: *router.Ctx) anyerror!router.Response {
        const self: *UploadController = @ptrCast(@alignCast(raw orelse return error.MissingController));

        if (startsWithIgnoreCase(c.req.path, self.prefix)) {
            if (!std.ascii.eqlIgnoreCase(c.req.method, "GET") and !std.ascii.eqlIgnoreCase(c.req.method, "HEAD")) {
                return router.Response.text(.method_not_allowed, "Method Not Allowed");
            }

            // 相对路径：/Upload/downloads/images/x.png → /images/x.png
            const rest = std.mem.trimStart(u8, c.req.path[self.prefix.len..], "/");
            if (rest.len == 0) return router.Response.text(.not_found, "Not Found");

            const target = try std.fmt.allocPrint(c.arena, "/{s}", .{rest});
            const response = try self.downloads.serve(c.arena, target, c.header("if-none-match")) orelse
                return router.Response.text(.not_found, "Not Found");

            // 带上 Content-Disposition（下载而非内联展示），中文名走 RFC 5987
            const file_name = std.fs.path.basename(target);
            const disposition = try contentDisposition(c.arena, file_name);

            const headers = try c.arena.alloc(std.http.Header, response.headers.len + 1);
            @memcpy(headers[0..response.headers.len], response.headers);
            headers[response.headers.len] = .{ .name = "content-disposition", .value = disposition };

            var with_header = response;
            with_header.headers = headers;
            return with_header;
        }

        // 其它未命中路由：回退到 wwwroot 静态资源（与 `App` 默认行为一致）
        if (self.app) |app| {
            if (try app.statics.serveRequest(c.arena, c.req)) |response| return response;
        }
        return router.Response.notFound();
    }
};

/// 构造 `Content-Disposition`（ASCII 名 + RFC 5987 UTF-8 名，中文文件名不丢）。
///
/// ASCII 部分**按字符**替换（与 C#/Rust 同口径：一个汉字 → 一个 `_`，不是三个）。
pub fn contentDisposition(arena: std.mem.Allocator, file_name: []const u8) ![]const u8 {
    var ascii: std.ArrayList(u8) = .empty;
    defer ascii.deinit(arena);

    if (std.unicode.Utf8View.init(file_name)) |view| {
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            const keep = codepoint < 0x80 and
                (std.ascii.isAlphanumeric(@intCast(codepoint)) or
                    codepoint == '.' or codepoint == '-' or codepoint == '_' or codepoint == ' ');
            try ascii.append(arena, if (keep) @intCast(codepoint) else '_');
        }
    } else |_| {
        for (file_name) |byte| {
            const keep = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_' or byte == ' ';
            try ascii.append(arena, if (keep) byte else '_');
        }
    }

    const encoded = try percentEncode(arena, file_name);
    return std.fmt.allocPrint(arena, "attachment; filename=\"{s}\"; filename*=UTF-8''{s}", .{ ascii.items, encoded });
}

/// RFC 5987 百分号编码（仅保留 unreserved 字符）。
pub fn percentEncode(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.ensureTotalCapacity(arena, text.len * 3);

    for (text) |byte| {
        const keep = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
        if (keep) {
            try out.append(arena, byte);
        } else {
            try out.print(arena, "%{X:0>2}", .{byte});
        }
    }
    return out.toOwnedSlice(arena);
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

// ————— 测试 —————

const testing = std.testing;

test "下载：Content-Disposition 保留中文（RFC 5987）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const header = try contentDisposition(arena, "报表 2026.pdf");
    // 非 ASCII 逐字符替换为 `_`，空格保留（两个汉字 → 两个下划线）
    try testing.expect(std.mem.indexOf(u8, header, "filename=\"__ 2026.pdf\"") != null);
    try testing.expect(std.mem.indexOf(u8, header, "filename*=UTF-8''") != null);
    try testing.expect(std.mem.indexOf(u8, header, "%E6%8A%A5") != null);
}

test "下载：静态根命中文件（下载中间件的文件源）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = ".zig-cache/zdsmallui-ctrl";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};

    const service = try ueditor.UeditorService.init(arena, testing.io, root, "/upload");
    const controller = try UploadController.init(testing.allocator, testing.io, service, root);
    defer controller.deinit();

    try zzig.fsio.makePath(testing.io, root ++ "/images");
    try zzig.fsio.writeFile(testing.io, root ++ "/images/a.txt", "hello");

    const response = try controller.downloads.serve(arena, "/images/a.txt", null) orelse
        return error.TestExpectedFile;
    try testing.expectEqual(std.http.Status.ok, response.status);
    if (response.file) |file| file.file.close(testing.io);
}

test "上传入口：无 action 时回配置" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const service = try ueditor.UeditorService.init(arena, testing.io, ".zig-cache/zdsmallui-entry", "/upload");
    const json = try service.handle(arena, "config", &.{}, null, "");
    try testing.expect(std.mem.indexOf(u8, json, "imageActionName") != null);
}

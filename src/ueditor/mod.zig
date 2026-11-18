//! UEditor 服务端协议实现（对齐百度 UEditor 1.4 后端约定）。
//!
//! 入口是 [`UeditorService.handle`]：按 `?action=...` 分发到配置 / 上传 / 涂鸦 /
//! 远程抓取 / 文件列表，统一返回 JSON（可用 `?callback=` 包裹为 JSONP，与 C# `Handler.WriteJson` 一致）。
//!
//! 配置来源优先级：`withConfigPath` 指定的文件 → 内置 `assets/ueconfig.json`
//! （与 C# 参考工程同一份）。

pub const config = @import("config.zig");
pub const crawler = @import("crawler.zig");
pub const list = @import("list.zig");
pub const path = @import("path.zig");
pub const upload = @import("upload.zig");

const std = @import("std");
const zzig = @import("zzig");
const multipart = @import("../multipart.zig");

pub const UeditorConfig = config.UeditorConfig;
pub const UploadConfig = upload.UploadConfig;
pub const UploadOutcome = upload.UploadOutcome;
pub const UploadState = upload.UploadState;
pub const Uploader = upload.Uploader;
pub const FileList = list.FileList;

/// UEditor 服务（配置 + 落盘器）。
pub const UeditorService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config_value: UeditorConfig,
    uploader_value: Uploader,
    /// 全局上传体积上限（与配置里的 `*MaxSize` 取小值）
    max_bytes: u64 = std.math.maxInt(u64),

    /// 使用内置配置创建服务。
    ///
    /// - `upload_root`：物理上传根目录（如 `wwwroot/upload`）；
    /// - `public_prefix`：对外 URL 前缀（如 `/upload`）。
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        upload_root: []const u8,
        public_prefix: []const u8,
    ) !UeditorService {
        return .{
            .allocator = allocator,
            .io = io,
            .config_value = try UeditorConfig.embedded(allocator),
            .uploader_value = Uploader.init(allocator, io, upload_root, public_prefix),
        };
    }

    /// 指定 `ueconfig.json` 路径（解析失败**记录告警并退回内置配置**）。
    pub fn withConfigPath(self: UeditorService, file_path: []const u8) UeditorService {
        var copy = self;
        copy.config_value = UeditorConfig.fromFile(self.allocator, self.io, file_path) catch |err| {
            zzig.Logger.warn("[ZDsMallUI] 加载 ueconfig 失败（{s}，{s}），退回内置配置", .{ file_path, @errorName(err) });
            return self;
        };
        return copy;
    }

    /// 指定 `ueconfig.json` 路径（失败即返回错误，不做静默回退）。
    pub fn tryWithConfigPath(self: UeditorService, file_path: []const u8) !UeditorService {
        var copy = self;
        const parsed = try UeditorConfig.fromFile(self.allocator, self.io, file_path);
        // 先解析成功再释放旧配置，避免失败时丢掉可用配置
        var previous = copy.config_value;
        previous.deinit();
        copy.config_value = parsed;
        return copy;
    }

    /// 直接注入配置（测试/多站点共用一份配置时使用）。
    pub fn withConfig(self: UeditorService, value: UeditorConfig) UeditorService {
        var copy = self;
        copy.config_value = value;
        return copy;
    }

    /// 全局体积上限。
    pub fn withMaxBytes(self: UeditorService, max_bytes: u64) UeditorService {
        var copy = self;
        copy.max_bytes = if (max_bytes == 0) 1 else max_bytes;
        copy.uploader_value = self.uploader_value.withMaxBytes(copy.max_bytes);
        return copy;
    }

    /// 当前配置。
    pub fn config(self: *const UeditorService) *const UeditorConfig {
        return &self.config_value;
    }

    /// 释放配置值树（服务本身不持有其它堆分配）。
    pub fn deinit(self: *UeditorService) void {
        self.config_value.deinit();
    }

    /// 落盘器。
    pub fn uploader(self: *const UeditorService) *const Uploader {
        return &self.uploader_value;
    }

    /// 处理一次 UEditor 请求，返回 JSON 文本（`callback` 存在时为 JSONP）。
    ///
    /// - `action`：查询串 `action`；
    /// - `query`：完整查询串（取 `callback` / `start` / `size`）；
    /// - `content_type`：请求头 `Content-Type`（multipart 解析用）；
    /// - `body`：请求体原始字节。
    pub fn handle(
        self: *const UeditorService,
        arena: std.mem.Allocator,
        action: []const u8,
        query: []const zzig.web.router.Param,
        content_type: ?[]const u8,
        body: []const u8,
    ) ![]const u8 {
        const json = try self.dispatch(arena, action, query, content_type, body);
        const callback = queryValue(query, "callback") orelse return json;
        if (std.mem.trim(u8, callback, " \t\r\n").len == 0) return json;
        return std.fmt.allocPrint(arena, "{s}({s});", .{ callback, json });
    }

    /// 分发实现（不含 JSONP 包装）。
    pub fn dispatch(
        self: *const UeditorService,
        arena: std.mem.Allocator,
        action_raw: []const u8,
        query: []const zzig.web.router.Param,
        content_type: ?[]const u8,
        body: []const u8,
    ) ![]const u8 {
        const action = std.mem.trim(u8, action_raw, " \t\r\n");

        if (std.ascii.eqlIgnoreCase(action, "config") or
            std.ascii.eqlIgnoreCase(action, self.config_value.getStr("configActionName") orelse "config"))
        {
            return self.config_value.toJson(arena);
        }

        if (self.isAction(action, "imageActionName")) {
            return self.uploadMultipart(arena, try UploadConfig.image(arena, self.config_value), content_type, body);
        }
        if (self.isAction(action, "scrawlActionName")) {
            return self.uploadBase64(arena, try UploadConfig.scrawl(arena, self.config_value), content_type, body);
        }
        if (self.isAction(action, "videoActionName")) {
            return self.uploadMultipart(arena, try UploadConfig.video(arena, self.config_value), content_type, body);
        }
        if (self.isAction(action, "fileActionName")) {
            return self.uploadMultipart(arena, try UploadConfig.file(arena, self.config_value), content_type, body);
        }
        if (self.isAction(action, "catcherActionName")) {
            return self.catchImages(arena, content_type, body);
        }
        if (self.isAction(action, "imageManagerActionName")) {
            return self.listFiles(arena, "imageManagerListPath", "imageManagerAllowFiles", "imageManagerListSize", query);
        }
        if (self.isAction(action, "fileManagerActionName")) {
            return self.listFiles(arena, "fileManagerListPath", "fileManagerAllowFiles", "fileManagerListSize", query);
        }

        var builder = zzig.web.ObjectBuilder.init(arena);
        try builder.str("state", try std.fmt.allocPrint(arena, "不支持的操作：{s}", .{action}));
        return (try builder.finish().jsonAlloc(arena));
    }

    /// 动作名是否匹配配置里的键（大小写不敏感；配置缺失时回退到官方默认名）。
    fn isAction(self: *const UeditorService, action: []const u8, key: []const u8) bool {
        const configured = self.config_value.getStr(key) orelse defaultActionName(key);
        return std.ascii.eqlIgnoreCase(action, configured);
    }

    /// 多段表单上传（图片/视频/附件）。
    fn uploadMultipart(
        self: *const UeditorService,
        arena: std.mem.Allocator,
        upload_config: UploadConfig,
        content_type: ?[]const u8,
        body: []const u8,
    ) ![]const u8 {
        const form = switch (multipart.FormData.parse(arena, content_type, body)) {
            .ok => |parsed| parsed,
            .fail => |message| {
                var builder = zzig.web.ObjectBuilder.init(arena);
                try builder.str("state", try std.fmt.allocPrint(arena, "表单解析失败：{s}", .{message}));
                return builder.finish().jsonAlloc(arena);
            },
        };
        return self.saveUpload(arena, upload_config, &form, false);
    }

    /// base64 表单上传（涂鸦）。
    fn uploadBase64(
        self: *const UeditorService,
        arena: std.mem.Allocator,
        upload_config: UploadConfig,
        content_type: ?[]const u8,
        body: []const u8,
    ) ![]const u8 {
        const form = switch (multipart.FormData.parse(arena, content_type, body)) {
            .ok => |parsed| parsed,
            .fail => |message| {
                var builder = zzig.web.ObjectBuilder.init(arena);
                try builder.str("state", try std.fmt.allocPrint(arena, "表单解析失败：{s}", .{message}));
                return builder.finish().jsonAlloc(arena);
            },
        };
        return self.saveUpload(arena, upload_config, &form, true);
    }

    fn saveUpload(
        self: *const UeditorService,
        arena: std.mem.Allocator,
        upload_config: UploadConfig,
        form: *const multipart.FormData,
        base64_upload: bool,
    ) ![]const u8 {
        const outcome = if (base64_upload)
            self.uploader_value.saveBase64(arena, upload_config, form)
        else
            self.uploader_value.saveMultipart(arena, upload_config, form);

        if (!outcome.state.isSuccess()) {
            // 失败必须留下可定位日志（含状态与具体原因）
            zzig.Logger.warn("[ZDsMallUI] UEditor 上传失败：{s}（字段 {s}，路径模板 {s}）", .{
                outcome.err orelse outcome.state.message(),
                upload_config.field_name,
                upload_config.path_format,
            });
        }
        const value = try outcome.toValue(arena);
        return value.jsonAlloc(arena);
    }

    /// 远程图片抓取。
    fn catchImages(
        self: *const UeditorService,
        arena: std.mem.Allocator,
        content_type: ?[]const u8,
        body: []const u8,
    ) ![]const u8 {
        const form = switch (multipart.FormData.parse(arena, content_type, body)) {
            .ok => |parsed| parsed,
            .fail => |message| {
                var builder = zzig.web.ObjectBuilder.init(arena);
                try builder.str("state", try std.fmt.allocPrint(arena, "表单解析失败：{s}", .{message}));
                return builder.finish().jsonAlloc(arena);
            },
        };

        // UEditor 前端提交 `source[]`（可能出现空名 `source[]` 多值，也可能写成 `source`）
        var sources = try form.values(arena, "source[]");
        if (sources.len == 0) sources = try form.values(arena, "source");

        const value = try crawler.catchImages(arena, self.allocator, self.io, self.config_value, self.uploader_value, sources);
        return value.jsonAlloc(arena);
    }

    /// 文件管理器列表。
    fn listFiles(
        self: *const UeditorService,
        arena: std.mem.Allocator,
        path_key: []const u8,
        allow_key: []const u8,
        size_key: []const u8,
        query: []const zzig.web.router.Param,
    ) ![]const u8 {
        const relative = self.config_value.getStr(path_key) orelse "/";
        const extensions = try self.config_value.getStringList(arena, allow_key);

        const start: usize = blk: {
            const text = queryValue(query, "start") orelse break :blk 0;
            const parsed = std.fmt.parseInt(usize, std.mem.trim(u8, text, " \t"), 10) catch 0;
            break :blk parsed;
        };
        const size: usize = blk: {
            if (queryValue(query, "size")) |text| {
                if (std.fmt.parseInt(usize, std.mem.trim(u8, text, " \t"), 10)) |parsed| {
                    if (parsed > 0) break :blk parsed;
                } else |_| {}
            }
            if (self.config_value.getInt(size_key)) |configured| {
                if (configured > 0) break :blk @intCast(configured);
            }
            break :blk 20;
        };

        switch (list.listFiles(
            arena,
            self.io,
            self.uploader_value.root,
            relative,
            extensions,
            self.uploader_value.public_prefix,
            start,
            size,
        )) {
            .fail => |message| {
                var builder = zzig.web.ObjectBuilder.init(arena);
                try builder.str("state", message);
                return builder.finish().jsonAlloc(arena);
            },
            .ok => |page| {
                const items = try arena.alloc(zzig.web.Value, page.items.len);
                for (page.items, 0..) |url, index| {
                    var item = zzig.web.ObjectBuilder.init(arena);
                    try item.str("url", url);
                    items[index] = item.finish();
                }
                var builder = zzig.web.ObjectBuilder.init(arena);
                try builder.str("state", "SUCCESS");
                try builder.list("list", items);
                try builder.int("start", @intCast(page.start));
                try builder.int("size", @intCast(page.size));
                try builder.int("total", @intCast(page.total));
                return builder.finish().jsonAlloc(arena);
            },
        }
    }
};

/// 配置键对应的官方默认动作名。
fn defaultActionName(key: []const u8) []const u8 {
    const pairs = [_][2][]const u8{
        .{ "imageActionName", "uploadimage" },
        .{ "scrawlActionName", "uploadscrawl" },
        .{ "videoActionName", "uploadvideo" },
        .{ "fileActionName", "uploadfile" },
        .{ "catcherActionName", "catchimage" },
        .{ "imageManagerActionName", "listimage" },
        .{ "fileManagerActionName", "listfile" },
    };
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair[0], key)) return pair[1];
    }
    return "";
}

/// 查询串取值（大小写不敏感；首个匹配）。
pub fn queryValue(query: []const zzig.web.router.Param, name: []const u8) ?[]const u8 {
    for (query) |param| {
        if (std.ascii.eqlIgnoreCase(param.name, name)) return param.value;
    }
    return null;
}

// ————— 测试 —————

const testing = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    root: []const u8,

    fn init(tag: []const u8) !Fixture {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const arena = arena_state.allocator();
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".", arena);
        const root = try std.fmt.allocPrint(arena, "{s}/.zig-cache/zdsmallui-service-{s}", .{ cwd, tag });
        std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
        try zzig.fsio.makePath(testing.io, root);
        return .{ .arena_state = arena_state, .root = root };
    }

    fn deinit(self: *Fixture) void {
        const root = self.root;
        std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
        self.arena_state.deinit();
    }
};

fn multipartBody(arena: std.mem.Allocator, field: []const u8, filename: []const u8, data: []const u8) !struct { content_type: []const u8, body: []const u8 } {
    const boundary = "----ZDsMallUITest";
    const body = try std.fmt.allocPrint(arena, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n{s}\r\n--{s}--\r\n", .{ boundary, field, filename, data, boundary });
    return .{
        .content_type = try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{boundary}),
        .body = body,
    };
}

test "UEditor：config 动作原样回吐配置" {
    var fixture = try Fixture.init("config");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const service = try UeditorService.init(arena, testing.io, fixture.root, "/upload");

    const json = try service.handle(arena, "config", &.{}, null, "");
    try testing.expect(std.mem.indexOf(u8, json, "imageActionName") != null);
}

test "UEditor：config 支持 JSONP 回调" {
    var fixture = try Fixture.init("jsonp");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const service = try UeditorService.init(arena, testing.io, fixture.root, "/upload");
    const query = [_]zzig.web.router.Param{.{ .name = "callback", .value = "cb" }};
    const json = try service.handle(arena, "config", &query, null, "");
    try testing.expect(std.mem.startsWith(u8, json, "cb("));
    try testing.expect(std.mem.endsWith(u8, json, ");"));
}

test "UEditor：uploadimage 落盘并返回 SUCCESS" {
    var fixture = try Fixture.init("upload");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const service = try UeditorService.init(arena, testing.io, fixture.root, "/upload");
    const payload = try multipartBody(arena, "upfile", "a.png", "\x89PNG");

    const json = try service.handle(arena, "uploadimage", &.{}, payload.content_type, payload.body);
    try testing.expect(std.mem.indexOf(u8, json, "\"state\":\"SUCCESS\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "/upload/images/") != null);
}

test "UEditor：不支持的动作给出明确文案" {
    var fixture = try Fixture.init("action");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const service = try UeditorService.init(arena, testing.io, fixture.root, "/upload");
    const json = try service.handle(arena, "nope", &.{}, null, "");
    try testing.expect(std.mem.indexOf(u8, json, "不支持的操作") != null);
}

test "UEditor：listimage 分页列出已上传文件" {
    var fixture = try Fixture.init("list");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    try zzig.fsio.makePath(testing.io, try std.fmt.allocPrint(arena, "{s}/images", .{fixture.root}));
    try zzig.fsio.writeFile(testing.io, try std.fmt.allocPrint(arena, "{s}/images/x.png", .{fixture.root}), "1");

    const service = try UeditorService.init(arena, testing.io, fixture.root, "/upload");
    const query = [_]zzig.web.router.Param{
        .{ .name = "start", .value = "0" },
        .{ .name = "size", .value = "10" },
    };
    const json = try service.handle(arena, "listimage", &query, null, "");
    try testing.expect(std.mem.indexOf(u8, json, "\"total\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "/upload/images/x.png") != null);
}

test "UEditor：multipart 缺失时报表单解析失败（带原因）" {
    var fixture = try Fixture.init("badform");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const service = try UeditorService.init(arena, testing.io, fixture.root, "/upload");
    const json = try service.handle(arena, "uploadimage", &.{}, "application/json", "{}");
    try testing.expect(std.mem.indexOf(u8, json, "表单解析失败") != null);
    try testing.expect(std.mem.indexOf(u8, json, "multipart") != null);
}

//! UEditor 文件上传（`uploadimage` / `uploadscrawl` / `uploadvideo` / `uploadfile`）。
//!
//! 行为对齐 C# 参考实现 `Pek.DsMallUI/UEditor/UploadHandler.cs` 的**设计意图**
//! （该文件当前把处理逻辑整体注释掉了，等价于「任何上传都返回未知错误」；
//! 这里按官方 UEditor 后端协议补齐，字段与状态文案保持 C# 一致）。
//!
//! 安全要点：
//! - **扩展名白名单**：取 `ueconfig.json` 的 `*AllowFiles`，归一化后比较（空列表 = 全拒）；
//! - **体积上限**：取 `*MaxSize`，与调用方 `max_upload_bytes` 取小值；
//! - **落盘路径二次校验**：格式化结果不得含 `..`，且必须落在 `root` 之内
//!   （`{filename}` 来自客户端，[`path.sanitizeFileName`] 已折叠 `..`，这里再做一次纵深防御）。

const std = @import("std");
const zzig = @import("zzig");

const base64 = @import("../base64.zig");
const multipart = @import("../multipart.zig");
const config_mod = @import("config.zig");
const path = @import("path.zig");

/// 上传结果状态（文案与 C# `UploadHandler.GetStateMessage` 完全一致）。
pub const UploadState = enum {
    /// 成功
    success,
    /// 不允许的文件格式
    type_not_allow,
    /// 文件大小超出服务器限制
    size_limit_exceed,
    /// 文件访问出错，请检查写入权限
    file_access_error,
    /// 网络错误
    network_error,
    /// 未知错误
    unknown,

    /// 返回给 UEditor 前端的 `state` 文本（同时也是 UEditor 判定成功的唯一依据）。
    pub fn message(self: UploadState) []const u8 {
        return switch (self) {
            .success => "SUCCESS",
            .type_not_allow => "不允许的文件格式",
            .size_limit_exceed => "文件大小超出服务器限制",
            .file_access_error => "文件访问出错，请检查写入权限",
            .network_error => "网络错误",
            .unknown => "未知错误",
        };
    }

    /// 是否成功。
    pub fn isSuccess(self: UploadState) bool {
        return self == .success;
    }
};

/// 单类上传的配置（对应 C# `UploadConfig`）。
pub const UploadConfig = struct {
    /// 允许的扩展名（已归一化为小写、带前导点）
    allow_extensions: []const []const u8 = &.{},
    /// 保存路径模板（如 `/images/{yyyy}/{mm}/{dd}/{filename}_{hh}{ii}`）
    path_format: []const u8 = path.DEFAULT_PATH_FORMAT,
    /// 体积上限（字节）
    size_limit: u64 = 20 * 1024 * 1024,
    /// 表单字段名
    field_name: []const u8 = "upfile",
    /// 是否 base64 上传（涂鸦）
    base64: bool = false,
    /// base64 上传时的文件名
    base64_filename: []const u8 = "",

    /// 图片上传（`image*` 配置）。
    pub fn image(allocator: std.mem.Allocator, config: config_mod.UeditorConfig) !UploadConfig {
        return fromPrefix(allocator, config, "image");
    }

    /// 涂鸦上传（`scrawl*` 配置；base64 表单值）。
    pub fn scrawl(allocator: std.mem.Allocator, config: config_mod.UeditorConfig) !UploadConfig {
        var cfg = try fromPrefix(allocator, config, "scrawl");
        cfg.allow_extensions = try allocator.dupe([]const u8, &.{".png"});
        cfg.base64 = true;
        cfg.base64_filename = "scrawl.png";
        return cfg;
    }

    /// 视频上传（`video*` 配置）。
    pub fn video(allocator: std.mem.Allocator, config: config_mod.UeditorConfig) !UploadConfig {
        return fromPrefix(allocator, config, "video");
    }

    /// 附件上传（`file*` 配置）。
    pub fn file(allocator: std.mem.Allocator, config: config_mod.UeditorConfig) !UploadConfig {
        return fromPrefix(allocator, config, "file");
    }

    fn fromPrefix(allocator: std.mem.Allocator, config: config_mod.UeditorConfig, prefix: []const u8) !UploadConfig {
        const field_key = try std.fmt.allocPrint(allocator, "{s}FieldName", .{prefix});
        const path_key = try std.fmt.allocPrint(allocator, "{s}PathFormat", .{prefix});
        const size_key = try std.fmt.allocPrint(allocator, "{s}MaxSize", .{prefix});
        const allow_key = try std.fmt.allocPrint(allocator, "{s}AllowFiles", .{prefix});

        return .{
            .allow_extensions = try config.getStringList(allocator, allow_key),
            .path_format = config.getStr(path_key) orelse path.DEFAULT_PATH_FORMAT,
            .size_limit = blk: {
                const size = config.getInt(size_key) orelse break :blk 20 * 1024 * 1024;
                break :blk if (size > 0) @intCast(size) else 20 * 1024 * 1024;
            },
            .field_name = config.getStr(field_key) orelse "upfile",
        };
    }
};

/// 一次上传的结果（序列化为 UEditor 约定的 JSON）。
pub const UploadOutcome = struct {
    /// 状态
    state: UploadState = .unknown,
    /// 可访问 URL（成功时）
    url: ?[]const u8 = null,
    /// 标题（原文件名，UEditor 用于展示）
    title: ?[]const u8 = null,
    /// 原始文件名
    original: ?[]const u8 = null,
    /// 文件类型（扩展名，含点）
    file_type: ?[]const u8 = null,
    /// 文件大小（字节）
    size: u64 = 0,
    /// 错误详情（失败时；成功为 `null`）
    err: ?[]const u8 = null,

    /// 失败结果（`message` 由 `arena` 持有）。
    pub fn fail(state: UploadState, message: []const u8) UploadOutcome {
        return .{ .state = state, .err = message };
    }

    /// 转 UEditor JSON 对象（`state` 恒有；空字段省略，避免前端把 null 当字符串）。
    pub fn toValue(self: UploadOutcome, arena: std.mem.Allocator) !zzig.web.Value {
        var builder = zzig.web.ObjectBuilder.init(arena);
        try builder.str("state", self.state.message());
        if (self.url) |url| try builder.str("url", url);
        if (self.title) |title| try builder.str("title", title);
        if (self.original) |original| try builder.str("original", original);
        if (self.file_type) |file_type| try builder.str("type", file_type);
        if (self.state.isSuccess()) try builder.int("size", @intCast(self.size));
        if (self.err) |message| try builder.str("error", message);
        return builder.finish();
    }
};

/// 上传落盘器（绑定一个物理根目录与对外 URL 前缀）。
pub const Uploader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    public_prefix: []const u8,
    max_bytes: u64 = std.math.maxInt(u64),

    /// `root` = 物理上传根目录（如 `wwwroot/upload`）；
    /// `public_prefix` = 对外 URL 前缀（如 `/upload`，末尾斜杠自动去掉）。
    ///
    /// **不分配内存**：前缀是调用方内存的切片（根与前缀的生命周期由调用方保证）。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8, public_prefix: []const u8) Uploader {
        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .public_prefix = std.mem.trimEnd(u8, std.mem.trim(u8, public_prefix, " \t"), "/"),
        };
    }

    /// 全局体积上限（与配置里的 `*MaxSize` 取小值；默认不额外限制）。
    pub fn withMaxBytes(self: Uploader, max_bytes: u64) Uploader {
        var copy = self;
        copy.max_bytes = if (max_bytes == 0) 1 else max_bytes;
        return copy;
    }

    /// 从多段表单取文件并落盘。
    pub fn saveMultipart(self: Uploader, arena: std.mem.Allocator, config: UploadConfig, form: *const multipart.FormData) UploadOutcome {
        const part = form.file(config.field_name) orelse {
            const message = std.fmt.allocPrint(arena, "表单缺少文件字段 {s}（multipart 解析成功）", .{config.field_name}) catch "表单缺少文件字段";
            return UploadOutcome.fail(.unknown, message);
        };
        const filename = part.filename orelse "file";
        return self.saveBytes(arena, config, filename, part.data);
    }

    /// 从 base64 表单值落盘（涂鸦）：取值形如 `data:image/png;base64,iVBOR...`。
    pub fn saveBase64(self: Uploader, arena: std.mem.Allocator, config: UploadConfig, form: *const multipart.FormData) UploadOutcome {
        const raw = form.value(config.field_name) orelse {
            const message = std.fmt.allocPrint(arena, "表单缺少涂鸦字段 {s}", .{config.field_name}) catch "表单缺少涂鸦字段";
            return UploadOutcome.fail(.unknown, message);
        };

        const data = base64.decodeDataUrl(self.allocator, raw) catch |err| {
            const message = std.fmt.allocPrint(arena, "涂鸦 base64 解码失败：{s}", .{@errorName(err)}) catch "涂鸦 base64 解码失败";
            return UploadOutcome.fail(.file_access_error, message);
        };
        defer self.allocator.free(data);

        const name = if (config.base64_filename.len == 0) "scrawl.png" else config.base64_filename;
        return self.saveBytes(arena, config, name, data);
    }

    /// 校验并落盘（扩展名 → 体积 → 路径 → 写入）。
    pub fn saveBytes(
        self: Uploader,
        arena: std.mem.Allocator,
        config: UploadConfig,
        original_name: []const u8,
        data: []const u8,
    ) UploadOutcome {
        const trimmed = std.mem.trim(u8, original_name, " \t\r\n");
        const name = if (trimmed.len == 0) "file" else trimmed;

        const extension_raw = config_mod.normalizeExtension(arena, path.extensionOf(name)) catch {
            return UploadOutcome.fail(.file_access_error, "扩展名归一化失败（内存不足）");
        };
        const extension: []const u8 = extension_raw;

        var allowed = false;
        for (config.allow_extensions) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate, extension)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) {
            const message = std.fmt.allocPrint(arena, "扩展名 {s} 不在允许列表 [{s}]", .{
                if (extension.len == 0) "(无)" else extension,
                joinSlices(arena, config.allow_extensions, ", ") catch "",
            }) catch "扩展名不在允许列表";
            return UploadOutcome.fail(.type_not_allow, message);
        }

        const size: u64 = @intCast(data.len);
        const limit = @min(config.size_limit, self.max_bytes);
        if (size > limit) {
            const message = std.fmt.allocPrint(arena, "文件 {d} 字节，超过上限 {d} 字节", .{ size, limit }) catch "文件超过上限";
            return UploadOutcome.fail(.size_limit_exceed, message);
        }

        const formatted = path.formatPath(arena, self.io, name, config.path_format) catch {
            return UploadOutcome.fail(.file_access_error, "保存路径格式化失败（内存不足）");
        };
        const relative = std.mem.trimStart(u8, formatted, "/");
        if (std.mem.indexOf(u8, relative, "..") != null) {
            const message = std.fmt.allocPrint(arena, "保存路径包含非法片段：{s}", .{relative}) catch "保存路径非法";
            return UploadOutcome.fail(.file_access_error, message);
        }

        const physical = std.fmt.allocPrint(arena, "{s}/{s}", .{ self.root, relative }) catch {
            return UploadOutcome.fail(.file_access_error, "保存路径拼接失败（内存不足）");
        };
        if (!self.isWithin(arena, physical)) {
            const message = std.fmt.allocPrint(arena, "保存路径越界：{s}", .{physical}) catch "保存路径越界";
            return UploadOutcome.fail(.file_access_error, message);
        }

        if (std.fs.path.dirname(physical)) |parent| {
            zzig.fsio.makePath(self.io, parent) catch |err| {
                const message = std.fmt.allocPrint(arena, "创建目录失败（{s}）：{s}", .{ parent, @errorName(err) }) catch "创建目录失败";
                return UploadOutcome.fail(.file_access_error, message);
            };
        }
        zzig.fsio.writeFile(self.io, physical, data) catch |err| {
            const message = std.fmt.allocPrint(arena, "写入文件失败（{s}）：{s}", .{ physical, @errorName(err) }) catch "写入文件失败";
            return UploadOutcome.fail(.file_access_error, message);
        };

        return .{
            .state = .success,
            .url = std.fmt.allocPrint(arena, "{s}/{s}", .{ self.public_prefix, relative }) catch null,
            .title = arena.dupe(u8, name) catch null,
            .original = arena.dupe(u8, name) catch null,
            .file_type = extension,
            .size = size,
        };
    }

    /// `path` 是否位于 `root` 之内（绝对路径前缀比较；用于阻断 `..` 逃逸）。
    fn isWithin(self: Uploader, arena: std.mem.Allocator, target: []const u8) bool {
        const abs_root = zzig.fsio.absolutePath(self.io, arena, self.root) catch return false;
        const abs_target = zzig.fsio.absolutePath(self.io, arena, target) catch return false;
        if (!std.mem.startsWith(u8, abs_target, abs_root)) return false;
        if (abs_target.len == abs_root.len) return false;
        const next = abs_target[abs_root.len];
        return next == '/' or next == '\\';
    }
};

fn joinSlices(allocator: std.mem.Allocator, items: []const []const u8, separator: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (items, 0..) |item, index| {
        if (index > 0) try out.appendSlice(allocator, separator);
        try out.appendSlice(allocator, item);
    }
    return out.toOwnedSlice(allocator);
}

// ————— 测试 —————

const testing = std.testing;

const TestEnv = struct {
    arena_state: std.heap.ArenaAllocator,
    root: []const u8,

    fn init(tag: []const u8) !TestEnv {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const arena = arena_state.allocator();
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".", arena);
        const root = try std.fmt.allocPrint(arena, "{s}/.zig-cache/zdsmallui-upload-{s}", .{ cwd, tag });
        std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
        try zzig.fsio.makePath(testing.io, root);
        return .{ .arena_state = arena_state, .root = root };
    }

    fn deinit(self: *TestEnv) void {
        const arena = self.arena_state.allocator();
        const root = self.root;
        _ = arena;
        std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
        self.arena_state.deinit();
    }
};

fn testConfig(arena: std.mem.Allocator, exts: []const []const u8, size_limit: u64) !UploadConfig {
    const copied = try arena.alloc([]const u8, exts.len);
    for (exts, 0..) |ext, index| copied[index] = ext;
    return .{
        .allow_extensions = copied,
        .path_format = "/images/{yyyy}/{mm}/{dd}/{filename}_{rand:6}",
        .size_limit = size_limit,
        .field_name = "upfile",
    };
}

test "上传：成功落盘并返回 URL" {
    var env = try TestEnv.init("ok");
    defer env.deinit();
    const arena = env.arena_state.allocator();

    const uploader = Uploader.init(arena, testing.io, env.root, "/upload");
    const config = try testConfig(arena, &.{".png"}, 1024);

    const outcome = uploader.saveBytes(arena, config, "a.png", "\x89PNG-data");
    try testing.expectEqual(UploadState.success, outcome.state);
    try testing.expect(std.mem.startsWith(u8, outcome.url.?, "/upload/images/"));
    try testing.expect(std.mem.endsWith(u8, outcome.url.?, ".png"));
    try testing.expectEqual(@as(u64, 9), outcome.size);
    try testing.expectEqualStrings("a.png", outcome.title.?);

    // 文件确实落盘
    const relative = outcome.url.?["/upload/".len..];
    const physical = try std.fmt.allocPrint(arena, "{s}/{s}", .{ env.root, relative });
    try testing.expect(zzig.fsio.exists(testing.io, physical));
}

test "上传：扩展名不在白名单被拒（空列表全拒）" {
    var env = try TestEnv.init("ext");
    defer env.deinit();
    const arena = env.arena_state.allocator();

    const uploader = Uploader.init(arena, testing.io, env.root, "/upload");
    const config = try testConfig(arena, &.{".png"}, 1024);
    const outcome = uploader.saveBytes(arena, config, "evil.exe", "x");
    try testing.expectEqual(UploadState.type_not_allow, outcome.state);
    try testing.expect(std.mem.indexOf(u8, outcome.err.?, ".exe") != null);

    const empty = try testConfig(arena, &.{}, 1024);
    const rejected = uploader.saveBytes(arena, empty, "a.png", "x");
    try testing.expectEqual(UploadState.type_not_allow, rejected.state);
}

test "上传：体积上限（配置与全局取小）" {
    var env = try TestEnv.init("size");
    defer env.deinit();
    const arena = env.arena_state.allocator();

    const uploader = Uploader.init(arena, testing.io, env.root, "/upload").withMaxBytes(4);
    const config = try testConfig(arena, &.{".png"}, 1024);

    const outcome = uploader.saveBytes(arena, config, "a.png", "12345");
    try testing.expectEqual(UploadState.size_limit_exceed, outcome.state);
    try testing.expect(std.mem.indexOf(u8, outcome.err.?, "超过上限 4 字节") != null);
}

test "上传：base64 涂鸦解码并落盘" {
    var env = try TestEnv.init("scrawl");
    defer env.deinit();
    const arena = env.arena_state.allocator();

    const uploader = Uploader.init(arena, testing.io, env.root, "/upload");
    var form = multipart.FormData{
        .allocator = arena,
        .parts = try arena.dupe(multipart.Part, &.{.{
            .name = "upfile",
            .data = "data:image/png;base64,aGVsbG8=",
        }}),
    };
    const scrawl = UploadConfig{ .allow_extensions = &.{".png"}, .field_name = "upfile", .base64 = true, .base64_filename = "scrawl.png" };
    const outcome = uploader.saveBase64(arena, scrawl, &form);
    try testing.expectEqual(UploadState.success, outcome.state);
    try testing.expect(std.mem.endsWith(u8, outcome.url.?, ".png"));

    // 非法 base64 明确失败
    form.parts = try arena.dupe(multipart.Part, &.{.{
        .name = "upfile",
        .data = "data:image/png;base64,!!!!",
    }});
    const bad = uploader.saveBase64(arena, scrawl, &form);
    try testing.expectEqual(UploadState.file_access_error, bad.state);
}

test "上传：缺文件字段时报未知错误并带上字段名" {
    var env = try TestEnv.init("missing");
    defer env.deinit();
    const arena = env.arena_state.allocator();

    const uploader = Uploader.init(arena, testing.io, env.root, "/upload");
    const config = try testConfig(arena, &.{".png"}, 1024);
    var form = multipart.FormData{ .allocator = arena };
    const outcome = uploader.saveMultipart(arena, config, &form);
    try testing.expectEqual(UploadState.unknown, outcome.state);
    try testing.expect(std.mem.indexOf(u8, outcome.err.?, "upfile") != null);
}

test "上传：结果 JSON 只带成功字段" {
    var env = try TestEnv.init("json");
    defer env.deinit();
    const arena = env.arena_state.allocator();

    const uploader = Uploader.init(arena, testing.io, env.root, "/upload");
    const config = try testConfig(arena, &.{".png"}, 1024);
    const outcome = uploader.saveBytes(arena, config, "a.png", "data");

    const value = try outcome.toValue(arena);
    try testing.expectEqualStrings("SUCCESS", value.get("state").?.asString().?);
    try testing.expect(value.get("url") != null);
    try testing.expect(value.get("size") != null);
    try testing.expectEqual(@as(i64, 4), value.get("size").?.asInt().?);
    try testing.expect(value.get("error") == null);
}

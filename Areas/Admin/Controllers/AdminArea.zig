//! 后台 Area 的**共享上下文**（对齐 C# `Areas/Admin` 的区域级状态）。
//!
//! 「一个控制器一个文件」（与 C# 一致）：
//! - [`@import("home.zig")`] → `HomeController`（`/{area}/home/index`）
//! - [`@import("config.zig")`] → `ConfigController`（`/{area}/config/index`、`updatebase`）
//! - [`@import("login.zig")`] → `LoginController`（`/{area}/login/index`、`login`）
//! - [`@import("upload.zig")`] → `UploadController`（`/fileuploader`、`/Upload/downloads/*`）
//!
//! 本文件只放**跨控制器共享**的东西：区域名/首页/上传前缀、数据源与视图渲染器、
//! 统一渲染与 Ajax 判定，以及把三个控制器挂到路由器上的 [`AdminArea.mount`]。
//!
//! **区域名可配置**（对齐 C# `DHSetting.Current.AdminArea` / `AdminArea.AreaName`）：
//! 默认 `Admin`，消费方在装配时改成自己的区域名（如 `Biz`）即可。

const std = @import("std");
const zzig = @import("zzig");

const area_mod = @import("../../../src/area.zig");
const backend_mod = @import("../../../src/backend.zig");
const views_mod = @import("../../../src/views.zig");

const config_controller = @import("ConfigController.zig");
const home_controller = @import("HomeController.zig");
const login_controller = @import("LoginController.zig");

const router = zzig.web.router;
const controller_mod = zzig.web.controller;
const ActionResult = zzig.web.controller.ActionResult;

/// 默认后台区域名（与 C# 默认 `Admin` 一致）。
pub const DEFAULT_ADMIN_AREA = area_mod.DEFAULT_AREA;

/// 指定区域的默认首页路由：`Biz` → `/biz/home/index`。
pub fn homeRoute(allocator: std.mem.Allocator, area_name: []const u8) ![]u8 {
    const prefix = try area_mod.routePrefix(allocator, area_name);
    defer allocator.free(prefix);
    return std.fmt.allocPrint(allocator, "{s}/home/index", .{prefix});
}

/// 后台 Area（区域级状态 + 控制器挂载）。
pub const AdminArea = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 数据源（站点设置 / 登录）
    backend: backend_mod.AdminBackend,
    /// 视图渲染器（与门面共用一份，避免每个控制器各建缓存）
    views: *views_mod.Views,
    /// 区域名（Pascal，如 `Biz`）
    area: []const u8,
    /// 登录成功后的落地页（默认 `/{area}/home/index`）
    home: []const u8,
    /// 上传 URL 前缀（首页展示用）
    upload_prefix: []const u8,
    /// 已挂载的控制器（生命周期由本对象持有）
    controllers: std.ArrayList(*controller_mod.Controller) = .empty,

    /// 指定数据源与视图根（默认区域 `Admin`，首页 `/{area}/home/index`）。
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        admin_backend: backend_mod.AdminBackend,
        views: *views_mod.Views,
    ) !*AdminArea {
        const self = try allocator.create(AdminArea);
        errdefer allocator.destroy(self);

        const default_area = try allocator.dupe(u8, area_mod.DEFAULT_AREA);
        errdefer allocator.free(default_area);
        const home = try homeRoute(allocator, default_area);
        errdefer allocator.free(home);
        const prefix = try allocator.dupe(u8, "/upload");
        errdefer allocator.free(prefix);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .backend = admin_backend,
            .views = views,
            .area = default_area,
            .home = home,
            .upload_prefix = prefix,
        };
        return self;
    }

    /// 释放控制器与自有字符串。
    pub fn deinit(self: *AdminArea) void {
        for (self.controllers.items) |ctrl| {
            ctrl.deinit();
            self.allocator.destroy(ctrl);
        }
        self.controllers.deinit(self.allocator);
        self.allocator.free(self.area);
        self.allocator.free(self.home);
        self.allocator.free(self.upload_prefix);
        self.allocator.destroy(self);
    }

    /// 更换区域名（`Biz` / `biz` 等价；非法字符直接报错）。首页路由随区域名重算。
    pub fn setAreaName(self: *AdminArea, name: []const u8) !void {
        const normalized = try area_mod.normalize(self.allocator, name);
        const home = try homeRoute(self.allocator, normalized);
        self.allocator.free(self.home);
        self.allocator.free(self.area);
        self.area = normalized;
        self.home = home;
    }

    /// 覆盖登录成功后的落地页（默认 `/{area}/home/index`）。
    pub fn setHome(self: *AdminArea, home: []const u8) !void {
        const copy = try self.allocator.dupe(u8, home);
        self.allocator.free(self.home);
        self.home = copy;
    }

    /// 上传 URL 前缀（首页展示用；与 `Builder.uploadPath` 保持一致）。
    pub fn setUploadPrefix(self: *AdminArea, prefix: []const u8) !void {
        const trimmed = std.mem.trim(u8, prefix, " \t");
        const without_tail = std.mem.trimEnd(u8, trimmed, "/");
        const normalized = if (without_tail.len == 0)
            try self.allocator.alloc(u8, 0)
        else if (without_tail[0] == '/')
            try self.allocator.dupe(u8, without_tail)
        else
            try std.fmt.allocPrint(self.allocator, "/{s}", .{without_tail});
        self.allocator.free(self.upload_prefix);
        self.upload_prefix = normalized;
    }

    /// 区域名（Pascal，如 `Biz`）。
    pub fn areaName(self: *const AdminArea) []const u8 {
        return self.area;
    }

    /// 路由前缀（小写，如 `/biz`）。
    pub fn routePrefix(self: *const AdminArea, allocator: std.mem.Allocator) ![]u8 {
        return area_mod.routePrefix(allocator, self.area);
    }

    /// 登录成功后的落地页。
    pub fn homePath(self: *const AdminArea) []const u8 {
        return self.home;
    }

    /// 挂载 Area 的全部控制器（一控制器一个文件，与 C# 目录结构一致）。
    ///
    /// | 路由 | 控制器 |
    /// |---|---|
    /// | `GET /{area}/home/index` | [`home_controller.HomeController`] |
    /// | `GET /{area}/config/index`、`POST /{area}/config/updatebase` | [`config_controller.ConfigController`] |
    /// | `GET /{area}/login/index`、`POST /{area}/login/login` | [`login_controller.LoginController`] |
    pub fn mount(self: *AdminArea, app: *zzig.web.App) !void {
        const segment = try area_mod.routeSegment(self.allocator, self.area);
        defer self.allocator.free(segment);

        {
            const prefix = try std.fmt.allocPrint(self.allocator, "{s}/home", .{segment});
            defer self.allocator.free(prefix);
            const ctrl = try self.newController(prefix);
            try ctrl.mapWithContext("GET", "index", @ptrCast(self), home_controller.HomeController.index);
            try ctrl.mount(&app.router);
        }
        {
            const prefix = try std.fmt.allocPrint(self.allocator, "{s}/config", .{segment});
            defer self.allocator.free(prefix);
            const ctrl = try self.newController(prefix);
            try ctrl.mapWithContext("GET", "index", @ptrCast(self), config_controller.ConfigController.index);
            try ctrl.mapWithContext("POST", "updatebase", @ptrCast(self), config_controller.ConfigController.updateBase);
            try ctrl.mount(&app.router);
        }
        {
            const prefix = try std.fmt.allocPrint(self.allocator, "{s}/login", .{segment});
            defer self.allocator.free(prefix);
            const ctrl = try self.newController(prefix);
            try ctrl.mapWithContext("GET", "index", @ptrCast(self), login_controller.LoginController.index);
            try ctrl.mapWithContext("POST", "login", @ptrCast(self), login_controller.LoginController.login);
            try ctrl.mount(&app.router);
        }
    }

    fn newController(self: *AdminArea, prefix: []const u8) !*controller_mod.Controller {
        const ctrl = try self.allocator.create(controller_mod.Controller);
        errdefer self.allocator.destroy(ctrl);
        ctrl.* = try controller_mod.Controller.init(self.allocator, self.io, prefix);
        try self.controllers.append(self.allocator, ctrl);
        return ctrl;
    }
};

// ————— 控制器共用的小工具 —————

/// 控制器动作的上下文指针 → `*AdminArea`。
pub fn castSelf(raw: ?*anyopaque) *AdminArea {
    return @ptrCast(@alignCast(raw orelse @panic("AdminArea：缺少控制器上下文")));
}

/// 当前登录用户（由宿主鉴权中间件写入 `Ctx.setState("user", ...)`）。
pub fn currentUser(c: *router.Ctx) []const u8 {
    return c.stateValue("user") orelse "";
}

/// 渲染 Area 视图；失败返回 JSON 500（含具体路径，便于定位）。
pub fn renderView(
    self: *AdminArea,
    c: *router.Ctx,
    controller: []const u8,
    view: []const u8,
    model: zzig.web.Value,
) !ActionResult {
    return switch (self.views.render(c.arena, self.area, controller, view, model)) {
        .html => |html| .{ .response = router.Response.html(html) },
        .fail => |message| blk: {
            zzig.Logger.err("[ZDsMallUI] {s}", .{message});
            const envelope = try controller_mod.jsonResult(c.arena, 500, message, null);
            break :blk .{ .response = envelope };
        },
    };
}

/// 渲染共享提示页（对应 C# `Prompt(new PromptModel{...})`）。
pub fn renderPrompt(
    self: *AdminArea,
    c: *router.Ctx,
    message: []const u8,
    is_ok: bool,
    back_url: ?[]const u8,
) !ActionResult {
    var builder = zzig.web.ObjectBuilder.init(c.arena);
    try builder.str("title", if (is_ok) "操作成功" else "操作提示");
    try builder.str("message", message);
    try builder.boolean("isOk", is_ok);
    try builder.boolean("hasBackUrl", back_url != null);
    try builder.str("backUrl", back_url orelse "");
    try builder.boolean("autoBack", is_ok and back_url != null);

    return switch (self.views.renderShared(c.arena, "Prompt", builder.finish())) {
        .html => |html| .{ .response = router.Response.html(html) },
        .fail => |detail| blk: {
            zzig.Logger.err("[ZDsMallUI] {s}", .{detail});
            const envelope = try controller_mod.jsonResult(c.arena, 500, detail, null);
            break :blk .{ .response = envelope };
        },
    };
}

/// 是否 Ajax 请求（与 C# `Request.IsAjaxRequest()` 同口径）。
pub fn isAjax(c: *router.Ctx) bool {
    if (c.header("x-requested-with")) |value| {
        if (std.ascii.eqlIgnoreCase(value, "xmlhttprequest")) return true;
    }
    if (c.header("accept")) |value| {
        return containsIgnoreCase(value, "application/json");
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

/// 站内跳转目标校验：只允许以单个 `/` 开头的相对路径（防开放重定向）。
pub fn safeRedirect(target: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, target, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return null;
    if (std.mem.startsWith(u8, trimmed, "//")) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '\\') != null) return null;
    return trimmed;
}

// ————— 测试 —————

const testing = std.testing;

test "区域：首页路由随区域名变化" {
    const route = try homeRoute(testing.allocator, "Biz");
    defer testing.allocator.free(route);
    try testing.expectEqualStrings("/biz/home/index", route);
}

test "区域：站内跳转只允许单斜杠相对路径" {
    try testing.expectEqualStrings("/biz/config/index", safeRedirect("/biz/config/index").?);
    try testing.expectEqualStrings("/", safeRedirect(" / ").?);
    try testing.expect(safeRedirect("") == null);
    try testing.expect(safeRedirect("http://evil.example") == null);
    try testing.expect(safeRedirect("//evil.example") == null);
    try testing.expect(safeRedirect("/a\\b") == null);
}

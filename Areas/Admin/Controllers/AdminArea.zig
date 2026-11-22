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
const auth_mod = @import("../../../src/auth.zig");
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

/// 区域快照（区域名 + 首页路径）；切换时原子换指针，旧快照留到 `deinit`（读线程零锁且安全）。
pub const AreaState = struct {
    area: []const u8,
    home: []const u8,
};

/// 后台 Area（区域级状态 + 控制器挂载）。
pub const AdminArea = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 数据源（站点设置 / 登录）
    backend: backend_mod.AdminBackend,
    /// 视图渲染器（与门面共用一份，避免每个控制器各建缓存）
    views: *views_mod.Views,
    /// 当前区域快照（不可变；`setAreaName` 原子换新指针）
    state: std.atomic.Value(*const AreaState),
    /// 上传 URL 前缀（首页展示用）
    upload_prefix: []const u8,
    /// 登录鉴权（JWT 签发 / 校验 / 登出吊销）；`null` = 未启用（不签令牌）
    auth: ?*auth_mod.Auth = null,
    /// 登录防爆破守卫（可选；由门面在 `build()` 时注入）
    login_guard: ?*@import("../../../src/login_guard.zig").Guard = null,
    /// 已挂载的控制器（生命周期由本对象持有）
    controllers: std.ArrayList(*controller_mod.Controller) = .empty,
    /// 退役的旧快照（读线程可能还在用，延迟到 `deinit` 释放）
    retired_states: std.ArrayList(*AreaState) = .empty,

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

        const state = try allocator.create(AreaState);
        errdefer allocator.destroy(state);
        state.* = .{ .area = default_area, .home = home };

        self.* = .{
            .allocator = allocator,
            .io = io,
            .backend = admin_backend,
            .views = views,
            .state = .init(state),
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
        for (self.retired_states.items) |state| {
            self.allocator.free(state.area);
            self.allocator.free(state.home);
            self.allocator.destroy(state);
        }
        self.retired_states.deinit(self.allocator);
        const current = self.state.load(.acquire);
        self.allocator.free(current.area);
        self.allocator.free(current.home);
        self.allocator.destroy(@constCast(current));
        if (self.auth) |auth| auth.deinit();
        self.allocator.free(self.upload_prefix);
        self.allocator.destroy(self);
    }

    /// 接管登录鉴权器（生命周期转归本对象；登出时一并释放）。
    pub fn setAuth(self: *AdminArea, auth: *auth_mod.Auth) void {
        if (self.auth) |existing| existing.deinit();
        self.auth = auth;
    }

    /// 注入登录防爆破守卫（不注入则不做失败计数）。
    pub fn setLoginGuard(self: *AdminArea, guard: *@import("../../../src/login_guard.zig").Guard) void {
        self.login_guard = guard;
    }

    /// 登录页路径（`/{area}/login/index`）。
    pub fn loginPath(self: *const AdminArea, allocator: std.mem.Allocator) ![]u8 {
        const prefix = try area_mod.routePrefix(allocator, self.areaName());
        defer allocator.free(prefix);
        return std.fmt.allocPrint(allocator, "{s}/login/index", .{prefix});
    }

    /// 更换区域名（`Biz` / `biz` 等价；非法字符直接报错）。首页路由随区域名重算。
    ///
    /// 路由是动态段 `/{area}/...`，换名后旧地址立即 404；旧快照延迟到 `deinit` 释放，
    /// 读线程（`areaName` / `homePath`）无锁且不会读到悬垂切片。
    pub fn setAreaName(self: *AdminArea, name: []const u8) !void {
        const normalized = try area_mod.normalize(self.allocator, name);
        errdefer self.allocator.free(normalized);
        const home = try homeRoute(self.allocator, normalized);
        errdefer self.allocator.free(home);

        const next = try self.allocator.create(AreaState);
        errdefer self.allocator.destroy(next);
        next.* = .{ .area = normalized, .home = home };

        const old = self.state.swap(next, .acq_rel);
        self.retired_states.append(self.allocator, @constCast(old)) catch {};

        // 切换后**立即**把默认视图落到新区域目录（只补缺失，不覆盖）。
        // 否则「切过去后的第一个请求」会撞上「视图不存在」，第二个请求才正常
        // （2026-11-22 冒烟日志：渲染 Admin/Login/Index 失败 → 下一次 200）。
        _ = views_mod.materializeFor(
            self.allocator,
            self.io,
            self.views.root,
            self.views.areas_root,
            normalized,
        ) catch |err| blk: {
            zzig.Logger.warn(
                "[ZDsMallUI] 区域 {s} 默认视图落地失败（{s}）：该区域首个请求可能回退到 Admin 视图",
                .{ normalized, @errorName(err) },
            );
            break :blk 0;
        };
    }

    /// 覆盖登录成功后的落地页（默认 `/{area}/home/index`）。
    pub fn setHome(self: *AdminArea, home: []const u8) !void {
        const current = self.state.load(.acquire);
        const area_copy = try self.allocator.dupe(u8, current.area);
        errdefer self.allocator.free(area_copy);
        const home_copy = try self.allocator.dupe(u8, home);
        errdefer self.allocator.free(home_copy);

        const next = try self.allocator.create(AreaState);
        errdefer self.allocator.destroy(next);
        next.* = .{ .area = area_copy, .home = home_copy };

        const old = self.state.swap(next, .acq_rel);
        self.retired_states.append(self.allocator, @constCast(old)) catch {};
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
        return self.state.load(.acquire).area;
    }

    /// 路由前缀（小写，如 `/biz`）。
    pub fn routePrefix(self: *const AdminArea, allocator: std.mem.Allocator) ![]u8 {
        return area_mod.routePrefix(allocator, self.areaName());
    }

    /// 登录成功后的落地页。
    pub fn homePath(self: *const AdminArea) []const u8 {
        return self.state.load(.acquire).home;
    }

    /// 挂载 Area 的全部控制器（一控制器一个文件，与 C# 目录结构一致）。
    ///
    /// | 路由 | 控制器 |
    /// |---|---|
    /// | `GET /{area}/home/index` | [`home_controller.HomeController`] |
    /// | `GET /{area}/config/index`、`POST /{area}/config/updatebase` | [`config_controller.ConfigController`] |
    /// | `GET /{area}/login/index`、`POST /{area}/login/login` | [`login_controller.LoginController`] |
    /// | `POST|GET /{area}/login/logout`、`GET /{area}/login/status` | [`login_controller.LoginController`] |
    pub fn mount(self: *AdminArea, app: *zzig.web.App) !void {
        // 动态段 `{area}`：区域名可在运行期改（配合配置热加载），旧地址由 `guarded` 拦截为 404
        const segment = "{area}";

        // 鉴权中间件先于控制器生效：解析 Cookie / Bearer 写入链路状态（`auth.uid` / `user`）
        if (self.auth) |auth| try app.useMiddleware(auth.middleware());

        // 区域根：`/{area}` 与 `/{area}/` 直接 302 到后台首页（C# 同样行为；否则用户手输 `/admin/` 会看到 404）
        try app.router.any("/{area}", .{ .ctx = @ptrCast(self), .call = areaRootCall });
        try app.router.any("/{area}/", .{ .ctx = @ptrCast(self), .call = areaRootCall });

        {
            const prefix = try std.fmt.allocPrint(self.allocator, "{s}/home", .{segment});
            defer self.allocator.free(prefix);
            const ctrl = try self.newController(prefix);
            try ctrl.mapWithContext("GET", "index", @ptrCast(self), guarded(home_controller.HomeController.index));
            // 框架内欢迎页（C# `Main/Index` 的位置）
            try ctrl.mapWithContext("GET", "dashboard", @ptrCast(self), guarded(home_controller.HomeController.dashboard));
            try ctrl.mount(&app.router);
        }
        {
            const prefix = try std.fmt.allocPrint(self.allocator, "{s}/config", .{segment});
            defer self.allocator.free(prefix);
            const ctrl = try self.newController(prefix);
            try ctrl.mapWithContext("GET", "index", @ptrCast(self), guarded(config_controller.ConfigController.index));
            try ctrl.mapWithContext("POST", "updatebase", @ptrCast(self), guarded(config_controller.ConfigController.updateBase));
            try ctrl.mount(&app.router);
        }
        {
            const prefix = try std.fmt.allocPrint(self.allocator, "{s}/login", .{segment});
            defer self.allocator.free(prefix);
            const ctrl = try self.newController(prefix);
            try ctrl.mapWithContext("GET", "index", @ptrCast(self), guarded(login_controller.LoginController.index));
            try ctrl.mapWithContext("POST", "login", @ptrCast(self), guarded(login_controller.LoginController.login));
            // 登出同时开 POST（表单/接口）与 GET（页面上的退出链接）
            try ctrl.mapWithContext("POST", "logout", @ptrCast(self), guarded(login_controller.LoginController.logout));
            try ctrl.mapWithContext("GET", "logout", @ptrCast(self), guarded(login_controller.LoginController.logout));
            try ctrl.mapWithContext("GET", "status", @ptrCast(self), guarded(login_controller.LoginController.status));
            try ctrl.mount(&app.router);
        }
    }

    /// 区域段校验（大小写不敏感）：`/biz/...` 只在该区域当前为 `Biz` 时生效。
    pub fn areaMatches(c: *router.Ctx, area: []const u8) bool {
        const segment = c.param("area") orelse return false;
        return std.ascii.eqlIgnoreCase(segment, area);
    }

    /// 区域根（`/{area}` / `/{area}/`）→ 302 到 `/{area}/home/index`；区域不匹配则 404。
    fn areaRootCall(raw: ?*anyopaque, c: *router.Ctx) anyerror!zzig.web.Response {
        const self: *AdminArea = @ptrCast(@alignCast(raw orelse return router.Response.notFound()));
        const segment = c.param("area") orelse return router.Response.notFound();
        if (!std.ascii.eqlIgnoreCase(segment, self.areaName())) return router.Response.notFound();
        const location = try std.fmt.allocPrint(c.arena, "/{s}/home/index", .{segment});
        return router.Response.redirectAlloc(c.arena, location);
    }

    /// 给控制器动作包一层区域校验：区域不匹配直接 404（改区域名后旧地址立即失效）。
    fn guarded(
        comptime action: fn (?*anyopaque, *router.Ctx) anyerror!controller_mod.ActionResult,
    ) fn (?*anyopaque, *router.Ctx) anyerror!controller_mod.ActionResult {
        return struct {
            fn call(raw: ?*anyopaque, c: *router.Ctx) anyerror!controller_mod.ActionResult {
                const self = castSelf(raw);
                if (!areaMatches(c, self.areaName())) return .{ .response = router.Response.notFound() };
                return action(raw, c);
            }
        }.call;
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
    return switch (self.views.render(c.arena, self.areaName(), controller, view, model)) {
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

/// 是否 Ajax 请求（转发 `zzig.web.router.isAjax`，与 C# `Request.IsAjaxRequest()` 同口径）。
pub fn isAjax(c: *router.Ctx) bool {
    return router.isAjax(c.req);
}

/// 站内跳转目标校验（转发 `zzig.web.router.safeLocalPath`，防开放重定向）。
pub fn safeRedirect(target: []const u8) ?[]const u8 {
    return router.safeLocalPath(target);
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

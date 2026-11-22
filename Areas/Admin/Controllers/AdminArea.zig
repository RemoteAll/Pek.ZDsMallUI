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

const area_mod = @import("../../../src/deps.zig").area;
const auth_mod = @import("../../../src/deps.zig").auth;
const backend_mod = @import("../../../src/deps.zig").backend;
const captcha_mod = @import("../../../src/deps.zig").captcha;
const views_mod = @import("../../../src/deps.zig").views;
const language_controllers = @import("LanguageControllers.zig");

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
    login_guard: ?*@import("../../../src/deps.zig").login_guard.Guard = null,
    /// 图形验证码存储（可选；注入后「失败达阈值」的登录会要求验证码）
    captcha: ?*captcha_mod.Store = null,
    /// 多语言仓储（由门面注入；后台文案按用户语言取）
    languages: ?*@import("../../../src/deps.zig").language.Store = null,
    /// 菜单注册表（由门面注入；框架页顶部/左侧菜单从这里生成）
    menus: ?*@import("../../../src/deps.zig").menu.Registry = null,
    /// 已挂载的控制器（生命周期由本对象持有）
    controllers: std.ArrayList(*controller_mod.Controller) = .empty,
    /// 退役的旧快照（读线程可能还在用，延迟到 `deinit` 释放）
    retired_states: std.ArrayList(*AreaState) = .empty,
    /// 站点设置保存成功后的回调（业务侧用来把库值回写配置文件、刷缓存等）。
    ///
    /// 为什么放在这里：`ConfigController` 只负责「校验 → 写库」，
    /// 「库值如何落到业务配置文件」是业务知识（文件名/格式/热加载），库不该写死。
    settings_saved_ctx: ?*anyopaque = null,
    settings_saved_hook: ?*const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) void = null,

    /// 注册「站点设置保存成功」回调（幂等：后注册的覆盖先注册的）。
    pub fn onSettingsSaved(
        self: *AdminArea,
        ctx: ?*anyopaque,
        hook: *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) void,
    ) void {
        self.settings_saved_ctx = ctx;
        self.settings_saved_hook = hook;
    }

    /// 站点设置保存成功后的统一入口（控制器调用；无钩子时什么都不做）。
    pub fn notifySettingsSaved(self: *AdminArea, arena: std.mem.Allocator) void {
        const hook = self.settings_saved_hook orelse return;
        hook(self.settings_saved_ctx, arena);
    }

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
    pub fn setLoginGuard(self: *AdminArea, guard: *@import("../../../src/deps.zig").login_guard.Guard) void {
        self.login_guard = guard;
    }

    /// 注入验证码存储（不注入则不启用验证码）。
    pub fn setCaptcha(self: *AdminArea, store: *captcha_mod.Store) void {
        self.captcha = store;
    }

    /// 注入多语言仓储（不注入则后台文案为控制器硬编码文本）。
    pub fn setLanguages(self: *AdminArea, store: *@import("../../../src/deps.zig").language.Store) void {
        self.languages = store;
    }

    /// 注入菜单注册表（不注入则视图拿不到 `groups`）。
    pub fn setMenus(self: *AdminArea, registry: *@import("../../../src/deps.zig").menu.Registry) void {
        self.menus = registry;
    }

    /// 当前用户的后台界面语言：用户偏好 → 默认语言 → 0。
    ///
    /// **只管后台**：前台语言由站点自己的 Cookie 决定（两者互不影响）。
    pub fn languageIdFor(self: *const AdminArea, user_name: []const u8) i32 {
        const store = self.languages orelse return 0;
        const preferred = self.backend.languageId(user_name);
        if (preferred != 0) {
            for (store.all()) |row| {
                if (row.id == preferred) return preferred;
            }
        }
        return if (store.defaultLanguage()) |row| row.id else 0;
    }

    /// 后台语言下拉选项（右上角「语言」子菜单用）：`[{name, code, url}]`。
    pub fn languageOptions(self: *const AdminArea, arena: std.mem.Allocator, current_id: i32) !zzig.web.Value {
        const store = self.languages orelse return .{ .list = &.{} };
        const prefix = try area_mod.routePrefix(arena, self.areaName());
        const back = try std.fmt.allocPrint(arena, "{s}/home/index", .{prefix});

        var list: std.ArrayList(zzig.web.Value) = .empty;
        for (store.all()) |row| {
            if (!row.status) continue;
            var builder = zzig.web.ObjectBuilder.init(arena);
            try builder.int("id", row.id);
            try builder.str("name", row.name);
            try builder.str("displayName", row.display_name);
            try builder.str("code", row.code);
            try builder.str("url", try std.fmt.allocPrint(arena, "{s}/home/setlanguage?culture={s}&returnUrl={s}", .{ prefix, row.code, back }));
            try builder.boolean("current", row.id == current_id);
            try list.append(arena, builder.finish());
        }
        return .{ .list = try list.toOwnedSlice(arena) };
    }

    /// 当前用户应看到的菜单树（`groups[]`，已是该用户语言）。
    pub fn menuGroups(
        self: *const AdminArea,
        arena: std.mem.Allocator,
        user_name: []const u8,
    ) !zzig.web.Value {
        const registry = self.menus orelse return .{ .list = &.{} };
        const store = self.languages orelse return .{ .list = &.{} };
        const prefix = try area_mod.routePrefix(arena, self.areaName());
        return registry.build(arena, prefix, store, self.languageIdFor(user_name));
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

        // 内置视图不落盘：换名后把内置源按新区域名重新注册即可立即生效
        // （渲染候选里仍保留 `Admin` 回退，所以注册成哪个名字都不会丢视图）。
        views_mod.registerDefaults(&self.views.renderer, normalized) catch |err| blk: {
            zzig.Logger.warn(
                "[ZDsMallUI] 区域 {s} 内置视图注册失败（{s}）：该区域首个请求可能回退到 Admin 视图",
                .{ normalized, @errorName(err) },
            );
            break :blk {};
        };
        // 顺手清掉老版本落到该区域目录的副本（只删带生成标记的，用户改过的保留）
        _ = views_mod.cleanupGeneratedCopies(
            self.allocator,
            self.io,
            self.views.root,
            self.views.areas_root,
            normalized,
        );
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

        // 验证码图片（URL 对齐 C# `DHSetting.CaptChaUrl = "/CaptCha/GetCheckCode"`）：返回 SVG + 下发 id Cookie
        if (self.captcha != null) {
            try app.router.any("/CaptCha/GetCheckCode", .{ .ctx = @ptrCast(self), .call = captchaImageCall });
        }

        {
            const prefix = try std.fmt.allocPrint(self.allocator, "{s}/home", .{segment});
            defer self.allocator.free(prefix);
            const ctrl = try self.newController(prefix);
            try ctrl.mapWithContext("GET", "index", @ptrCast(self), guarded(home_controller.HomeController.index));
            // 框架内欢迎页（C# `Main/Index` 的位置）
            try ctrl.mapWithContext("GET", "dashboard", @ptrCast(self), guarded(home_controller.HomeController.dashboard));
            // 右上角「清除缓存」（C# `Home/ClearCache`）
            try ctrl.mapWithContext("GET", "clearcache", @ptrCast(self), guarded(home_controller.HomeController.clearCache));
            // 右上角「语言」切换（只改当前用户的后台语言，与前台语言隔离）
            try ctrl.mapWithContext("GET", "setlanguage", @ptrCast(self), guarded(home_controller.HomeController.setLanguage));
            try ctrl.mapWithContext("GET", "modifypw", @ptrCast(self), guarded(home_controller.HomeController.modifyPw));
            try ctrl.mapWithContext("POST", "modifypwsubmit", @ptrCast(self), guarded(home_controller.HomeController.modifyPwSubmit));
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
            // 多语言（对齐 C# `Culture`）：列表 / 设默认 / 启停 / 新增
            const prefix = try std.fmt.allocPrint(self.allocator, "{s}/culture", .{segment});
            defer self.allocator.free(prefix);
            const ctrl = try self.newController(prefix);
            try ctrl.mapWithContext("GET", "index", @ptrCast(self), guarded(language_controllers.CultureController.index));
            try ctrl.mapWithContext("GET", "setdefault", @ptrCast(self), guarded(language_controllers.CultureController.setDefault));
            try ctrl.mapWithContext("GET", "togglestatus", @ptrCast(self), guarded(language_controllers.CultureController.toggleStatus));
            try ctrl.mapWithContext("POST", "add", @ptrCast(self), guarded(language_controllers.CultureController.add));
            try ctrl.mapWithContext("GET", "delete", @ptrCast(self), guarded(language_controllers.CultureController.delete));
            try ctrl.mapWithContext("GET", "addculture", @ptrCast(self), guarded(language_controllers.CultureController.addCulture));
            try ctrl.mapWithContext("GET", "editculture", @ptrCast(self), guarded(language_controllers.CultureController.editCulture));
            try ctrl.mapWithContext("POST", "saveculture", @ptrCast(self), guarded(language_controllers.CultureController.saveCulture));
            try ctrl.mount(&app.router);
        }
        {
            // 语言包（对齐 C# `Languages`）：按语言列出键值并保存
            const prefix = try std.fmt.allocPrint(self.allocator, "{s}/languages", .{segment});
            defer self.allocator.free(prefix);
            const ctrl = try self.newController(prefix);
            try ctrl.mapWithContext("GET", "index", @ptrCast(self), guarded(language_controllers.LanguagesController.index));
            try ctrl.mapWithContext("POST", "save", @ptrCast(self), guarded(language_controllers.LanguagesController.save));
            // 行内编辑保存（对齐 C# `EditLanValue`）：返回 JSON
            try ctrl.mapWithContext("POST", "editlanvalue", @ptrCast(self), guarded(language_controllers.LanguagesController.editLanValueCall));
            // 导出 / 导入（对齐 C# `Export` / `Import`）：CSV，导入正文是纯文本
            try ctrl.mapWithContext("GET", "export", @ptrCast(self), guarded(language_controllers.LanguagesController.exportResourcesCall));
            try ctrl.mapWithContext("POST", "import", @ptrCast(self), guarded(language_controllers.LanguagesController.importResourcesCall));
            try ctrl.mapWithContext("GET", "delete", @ptrCast(self), guarded(language_controllers.LanguagesController.deleteResourceCall));
            try ctrl.mapWithContext("GET", "addlanguages", @ptrCast(self), guarded(language_controllers.LanguagesController.addLanguagesCall));
            try ctrl.mapWithContext("GET", "editlanguages", @ptrCast(self), guarded(language_controllers.LanguagesController.editLanguagesCall));
            try ctrl.mapWithContext("POST", "savelanguages", @ptrCast(self), guarded(language_controllers.LanguagesController.saveLanguagesCall));
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

    /// 验证码 cookie 名（按区域区分，避免同域多实例串号）。
    pub fn captchaCookieName(self: *AdminArea, arena: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(arena, "{s}_captcha", .{self.areaName()});
    }

    /// `GET /CaptCha/GetCheckCode`：签发一份验证码，返回 SVG 并把 id 写进 HttpOnly Cookie。
    fn captchaImageCall(raw: ?*anyopaque, c: *router.Ctx) anyerror!zzig.web.Response {
        const self: *AdminArea = @ptrCast(@alignCast(raw orelse return router.Response.notFound()));
        const store = self.captcha orelse return router.Response.notFound();

        const now_ms = zzig.compat.milliTimestamp();
        const issue = try store.issue(c.arena, now_ms);
        const svg = try captcha_mod.renderSvg(c.arena, issue.code);

        const cookie_name = try self.captchaCookieName(c.arena);
        const cookie = try std.fmt.allocPrint(
            c.arena,
            "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}",
            .{ cookie_name, issue.id, store.opts.ttl_seconds },
        );

        const headers = try c.arena.alloc(std.http.Header, 2);
        headers[0] = .{ .name = "set-cookie", .value = cookie };
        headers[1] = .{ .name = "cache-control", .value = "no-store" };
        return .{
            .content_type = "image/svg+xml; charset=utf-8",
            .body = svg,
            .headers = headers,
        };
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
    // 与用户语言相关的装配统一放这里：所有后台页面的 `@Model.lang.*` 都能用
    const localized = withLanguage(self, c.arena, currentUser(c), model) catch model;
    return switch (self.views.render(c.arena, self.areaName(), controller, view, localized)) {
        .html => |html| .{ .response = router.Response.html(html) },
        .fail => |message| blk: {
            zzig.Logger.err("[ZDsMallUI] {s}", .{message});
            const envelope = try controller_mod.jsonResult(c.arena, 500, message, null);
            break :blk .{ .response = envelope };
        },
    };
}

/// 给模型补 `lang` / `groups`（后台页面通用）。
///
/// - `lang`：当前用户语言的语言包对象（`@Model.lang.menu_settings`）；
/// - `groups`：当前用户菜单树（顶部导航 + 左侧菜单）。
///
/// 视图里引用 `lang.<标识符>` 是编译期已知集合（[`language.BUILTIN_STRINGS`]），
/// 所以缺键只会回退内置文案，不会出现「属性不存在」。
///
/// 取「当前后台语言」的文案对象（`@Model.lang.*`），给**不套 `_Layout`** 的独立页面用
/// （登录页）：它没有 `withLanguage` 的上下文，但同样要按后台语言显示（未登录时用默认语言）。
pub fn langObject(self: *AdminArea, arena: std.mem.Allocator, user_name: []const u8) !zzig.web.Value {
    const store = self.languages orelse return .{ .object = &.{} };
    return store.buildLangObject(arena, self.languageIdFor(user_name));
}

fn withLanguage(
    self: *AdminArea,
    arena: std.mem.Allocator,
    user_name: []const u8,
    model: zzig.web.Value,
) !zzig.web.Value {
    const store = self.languages orelse return model;
    const culture_id = self.languageIdFor(user_name);

    var builder = zzig.web.ObjectBuilder.init(arena);
    switch (model) {
        .object => |fields| {
            for (fields) |field| {
                try builder.put(field.name, field.value);
            }
        },
        else => {},
    }
    try builder.put("lang", try store.buildLangObject(arena, culture_id));
    try builder.put("groups", try self.menuGroups(arena, user_name));
    const options = try self.languageOptions(arena, culture_id);
    try builder.put("languages", options);
    try builder.put("hasLanguages", .{ .boolean = switch (options) {
        .list => |items| items.len > 1,
        else => false,
    } });
    return builder.finish();
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

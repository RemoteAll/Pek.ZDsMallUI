//! 后台首页控制器（对应 C# `Areas/Admin/Controllers/HomeController`）。
//!
//! | 路由（`{area}` 由配置决定） | 说明 |
//! |---|---|
//! | `GET /{area}/home/index` | 后台框架页（顶部导航 + 左侧菜单 + 右侧 iframe，对齐 C# `DashBoard`） |
//! | `GET /{area}/home/dashboard` | 框架内欢迎页（C# `Main/Index`） |

const std = @import("std");
const zzig = @import("zzig");

const area_mod = @import("../../../src/deps.zig").area;
const admin_area = @import("AdminArea.zig");
const version = @import("../../../src/deps.zig").version;
const sysinfo = @import("../../../src/deps.zig").sysinfo;

const router = zzig.web.router;
const ActionResult = zzig.web.controller.ActionResult;

/// 后台首页控制器。
pub const HomeController = struct {
    /// 菜单声明（对齐 C# 控制器上的 `[DHMenu(...)]`）：库挂载时自动注册并写进 `Menu` 表。
    pub const menu: @import("../../../src/deps.zig").menu.MenuDecl = .{
        .group = "console",
        .name = "welcome",
        .title_key = "欢迎页",
        .url = "{area}/home/dashboard",
        .icon = "&#xe6a7;",
        .order = 10,
    };
    /// `GET /{area}/home/index`：后台**框架页**（顶部 + 左侧 + iframe）。
    pub fn index(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const model = try buildModel(self, c.arena, admin_area.currentUser(c));
        return admin_area.renderView(self, c, "Home", "Index", model);
    }

    /// `GET /{area}/home/dashboard`：框架内欢迎页（iframe 里显示）。
    pub fn dashboard(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const model = try buildModel(self, c.arena, admin_area.currentUser(c));
        return admin_area.renderView(self, c, "Home", "Dashboard", model);
    }

    /// `GET /{area}/home/clearcache`：清空模板缓存后回到欢迎页（对齐 C# `Home/ClearCache`）。
    pub fn clearCache(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        self.views.clearCache();
        const location = try std.fmt.allocPrint(c.arena, "{s}/home/dashboard", .{try area_mod.routePrefix(c.arena, self.areaName())});
        return .{ .response = try router.Response.redirectAlloc(c.arena, location) };
    }

    /// `GET /{area}/home/setlanguage`：切换**当前用户**的后台界面语言。
    ///
    /// 只 写这个用户自己的偏好（C# `UserDetail.LanguageId`），不影响别人、也不影响前台语言。
    pub fn setLanguage(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const route = try area_mod.routePrefix(c.arena, self.areaName());
        const fallback = try std.fmt.allocPrint(c.arena, "{s}/home/index", .{route});

        const culture = std.mem.trim(u8, c.queryValue("culture") orelse "", " \t");
        const back = admin_area.safeRedirect(c.queryValue("returnUrl") orelse "") orelse fallback;

        const store = self.languages orelse {
            return .{ .response = try router.Response.redirectAlloc(c.arena, back) };
        };
        const target = store.find(culture) orelse {
            zzig.Logger.warn("[ZDsMallUI] 切换语言失败：语言代码 {s} 不存在", .{culture});
            return .{ .response = try router.Response.redirectAlloc(c.arena, back) };
        };
        const user = admin_area.currentUser(c);
        if (user.len > 0) {
            self.backend.setLanguageId(user, target.id);
            zzig.Logger.info("[ZDsMallUI] 用户 {s} 的后台语言切换为 {s}", .{ user, target.code });
        }
        return .{ .response = try router.Response.redirectAlloc(c.arena, back) };
    }

    /// `GET /{area}/home/modifypw`：修改密码页（对齐 C# `Home/ModifyPw`）。
    pub fn modifyPw(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        return renderModifyPw(self, c, "", "");
    }

    /// `POST /{area}/home/modifypwsubmit`：校验旧密码 → 写新密码。
    ///
    /// 注意：zzig 的 controller 以 action 名为键、**同名的第二个注册会覆盖第一个**，
    /// 所以 GET 与 POST 用两个 action 名（`modifypw` / `modifypwsubmit`）。
    pub fn modifyPwSubmit(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const user = admin_area.currentUser(c);

        const old_password = c.formValue("OldPassword") orelse "";
        const password = c.formValue("Password") orelse "";
        const repassword = c.formValue("RePassword") orelse "";

        if (std.mem.trim(u8, old_password, " \t\r\n").len == 0) {
            return renderModifyPw(self, c, "原密码不可为空", "");
        }
        if (password.len < 6) {
            return renderModifyPw(self, c, "新密码至少 6 位", "");
        }
        if (!std.mem.eql(u8, password, repassword)) {
            return renderModifyPw(self, c, "两次输入的新密码不一致", "");
        }
        if (user.len == 0) {
            const route = try area_mod.routePrefix(c.arena, self.areaName());
            return .{ .response = try router.Response.redirectAlloc(c.arena, try std.fmt.allocPrint(c.arena, "{s}/login/index", .{route})) };
        }
        if (!self.backend.supportsChangePassword()) {
            return renderModifyPw(self, c, "当前数据源不支持修改密码", "");
        }

        const ok = self.backend.changePassword(c.arena, user, old_password, password) catch |err| {
            zzig.Logger.err("[ZDsMallUI] 修改密码失败（用户 {s}）：{s}", .{ user, @errorName(err) });
            return renderModifyPw(self, c, "修改失败，请查看后台日志", "");
        };
        if (!ok) return renderModifyPw(self, c, "原密码不正确", "");

        zzig.Logger.info("[ZDsMallUI] 用户 {s} 已修改密码", .{user});
        const route = try area_mod.routePrefix(c.arena, self.areaName());
        const location = try std.fmt.allocPrint(c.arena, "{s}/home/dashboard", .{route});
        return .{ .response = try router.Response.redirectAlloc(c.arena, location) };
    }

    /// 组装首页模型（控制器与测试共用）。
    pub fn buildModel(self: *admin_area.AdminArea, arena: std.mem.Allocator, user: []const u8) !zzig.web.Value {
        const display_name = try self.backend.displayName(arena);
        const settings = try self.backend.settings(arena);
        const site_name = if (settings.get("siteName")) |value| value.asString() orelse "" else "";
        const route = try area_mod.routePrefix(arena, self.areaName());

        var menu_config = zzig.web.ObjectBuilder.init(arena);
        try menu_config.str("name", "站点设置");
        try menu_config.str("url", try std.fmt.allocPrint(arena, "{s}/config/index", .{route}));
        try menu_config.str("desc", "站点名称、SEO、客服、页脚与自定义 HTML");

        var menu_ueditor = zzig.web.ObjectBuilder.init(arena);
        try menu_ueditor.str("name", "UEditor 配置");
        try menu_ueditor.str("url", "/fileuploader?action=config");
        try menu_ueditor.str("desc", "富文本编辑器后端配置（JSON，前端初始化用）");

        // 快捷入口：只放**登录后真正会用**的页面。
        // 「登录页」不再列出 —— 已登录的管理员点它只会回到登录页（自己的账号已登录，没有任何操作价值）。

        var builder = zzig.web.ObjectBuilder.init(arena);
        try builder.str("title", try std.fmt.allocPrint(arena, "管理后台 - {s}", .{display_name}));
        try builder.str("displayName", display_name);
        try builder.str("userName", if (user.len == 0) "访客" else user);
        try builder.str("siteName", std.mem.trim(u8, site_name, " \t"));
        try builder.str("areaName", self.areaName());
        try builder.str("areaRoute", route);
        try builder.str("uploadPrefix", self.upload_prefix);
        try builder.str("version", version.VERSION);
        try builder.str("dashboardUrl", try std.fmt.allocPrint(arena, "{s}/home/dashboard", .{route}));
        try builder.list("menus", &.{ menu_config.finish(), menu_ueditor.finish() });
        try builder.boolean("hasMenus", true);

        // 服务状态（欢迎页的卡片区）：进程资源快照。取数失败不影响页面（视图显示「—」）。
        const snap = sysinfo.collect(arena, self.io);
        try builder.boolean("statOk", snap.ok);
        try builder.int("statPid", @intCast(snap.pid));
        try builder.int("statThreads", @intCast(snap.threads));
        try builder.int("statHandles", @intCast(snap.handles));
        try builder.str("statRss", try sysinfo.formatBytes(arena, snap.rss_bytes));
        try builder.str("statCpu", try std.fmt.allocPrint(arena, "{d:.1}%", .{snap.cpu_percent}));
        try builder.str("statUptime", try sysinfo.formatUptime(arena, snap.up_seconds));
        try builder.str("statStartAt", try formatUnix(arena, snap.start_unix));
        try builder.str("statIoRead", try sysinfo.formatBytes(arena, snap.io_read_bytes));
        try builder.str("statIoWrite", try sysinfo.formatBytes(arena, snap.io_write_bytes));
        try builder.str("statEnv", @tagName(@import("builtin").os.tag));

        // 左侧菜单分组：由**菜单注册表**生成（`ui.addMenu(...)` 注册的项会自动出现），
        // 这里不再硬编码分组 —— `AdminArea.renderView` 会注入 `groups`（含项目追加的菜单）。
        return builder.finish();
    }
};

/// unix 秒 → `2026-11-23 09:29:42`（**本地时区**；0 表示未知）。
///
/// 具体实现（含「曾经误把 UTC 当本地时间」的说明）在 [`sysinfo.formatLocalTime`]。
fn formatUnix(arena: std.mem.Allocator, unix_seconds: i64) ![]const u8 {
    return sysinfo.formatLocalTime(arena, unix_seconds);
}

/// 构造左侧二级菜单项（`name` / `url` / `icon`）。
fn menuItem(arena: std.mem.Allocator, name: []const u8, url: []const u8, icon: []const u8) !zzig.web.Value {
    var item = zzig.web.ObjectBuilder.init(arena);
    try item.str("name", name);
    try item.str("url", url);
    try item.str("icon", icon);
    return item.finish();
}

/// 渲染「修改密码」页（`error` 为空表示首次进入）。
fn renderModifyPw(self: *admin_area.AdminArea, c: *router.Ctx, err_text: []const u8, notice: []const u8) !ActionResult {
    var builder = zzig.web.ObjectBuilder.init(c.arena);
    try builder.str("title", "修改密码 - 管理后台");
    try builder.str("displayName", try self.backend.displayName(c.arena));
    try builder.str("userName", admin_area.currentUser(c));
    try builder.str("areaRoute", try area_mod.routePrefix(c.arena, self.areaName()));
    try builder.str("error", err_text);
    try builder.str("notice", notice);
    try builder.boolean("hasError", err_text.len > 0);
    return admin_area.renderView(self, c, "Home", "ModifyPw", builder.finish());
}

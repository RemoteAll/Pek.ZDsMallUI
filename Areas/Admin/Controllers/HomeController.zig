//! 后台首页控制器（对应 C# `Areas/Admin/Controllers/HomeController`）。
//!
//! | 路由（`{area}` 由配置决定） | 说明 |
//! |---|---|
//! | `GET /{area}/home/index` | 后台框架页（顶部导航 + 左侧菜单 + 右侧 iframe，对齐 C# `DashBoard`） |
//! | `GET /{area}/home/dashboard` | 框架内欢迎页（C# `Main/Index`） |

const std = @import("std");
const zzig = @import("zzig");

const area_mod = @import("../../../src/area.zig");
const admin_area = @import("AdminArea.zig");
const version = @import("../../../src/version.zig");

const router = zzig.web.router;
const ActionResult = zzig.web.controller.ActionResult;

/// 后台首页控制器。
pub const HomeController = struct {
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

        var menu_login = zzig.web.ObjectBuilder.init(arena);
        try menu_login.str("name", "登录页");
        try menu_login.str("url", try std.fmt.allocPrint(arena, "{s}/login/index", .{route}));
        try menu_login.str("desc", "后台登录入口（账号由 AdminBackend 提供）");

        var menu_ueditor = zzig.web.ObjectBuilder.init(arena);
        try menu_ueditor.str("name", "UEditor 配置");
        try menu_ueditor.str("url", "/fileuploader?action=config");
        try menu_ueditor.str("desc", "富文本编辑器后端配置（JSON，前端初始化用）");

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
        try builder.list("menus", &.{ menu_config.finish(), menu_login.finish(), menu_ueditor.finish() });
        try builder.boolean("hasMenus", true);

        // 左侧菜单分组（对齐 C# `MenuTree`：一级分组 → 二级菜单 → iframe 打开）
        var group_system = zzig.web.ObjectBuilder.init(arena);
        try group_system.str("key", "system");
        try group_system.str("name", "系统");
        try group_system.list("items", &.{
            try menuItem(arena, "欢迎页", try std.fmt.allocPrint(arena, "{s}/home/dashboard", .{route}), "&#xe68e;"),
            try menuItem(arena, "站点设置", try std.fmt.allocPrint(arena, "{s}/config/index", .{route}), "&#xe614;"),
            try menuItem(arena, "登录页", try std.fmt.allocPrint(arena, "{s}/login/index", .{route}), "&#xe66f;"),
        });

        var group_content = zzig.web.ObjectBuilder.init(arena);
        try group_content.str("key", "content");
        try group_content.str("name", "内容");
        try group_content.list("items", &.{
            try menuItem(arena, "上传管理", "/fileuploader?action=listimage", "&#xe63c;"),
            try menuItem(arena, "UEditor 配置", "/fileuploader?action=config", "&#xe60a;"),
        });

        var group_site = zzig.web.ObjectBuilder.init(arena);
        try group_site.str("key", "site");
        try group_site.str("name", "站点");
        try group_site.list("items", &.{
            try menuItem(arena, "访问首页", "/", "&#xe68e;"),
            try menuItem(arena, "退出登录", try std.fmt.allocPrint(arena, "{s}/login/logout", .{route}), "&#xe70c;"),
        });

        try builder.list("groups", &.{ group_system.finish(), group_content.finish(), group_site.finish() });
        return builder.finish();
    }
};

/// 构造左侧二级菜单项（`name` / `url` / `icon`）。
fn menuItem(arena: std.mem.Allocator, name: []const u8, url: []const u8, icon: []const u8) !zzig.web.Value {
    var item = zzig.web.ObjectBuilder.init(arena);
    try item.str("name", name);
    try item.str("url", url);
    try item.str("icon", icon);
    return item.finish();
}

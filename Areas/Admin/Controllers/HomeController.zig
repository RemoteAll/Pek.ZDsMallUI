//! 后台首页控制器（对应 C# `Areas/Admin/Controllers/HomeController`）。
//!
//! | 路由（`{area}` 由配置决定） | 说明 |
//! |---|---|
//! | `GET /{area}/home/index` | 后台首页（控制台卡片 + 快捷入口） |

const std = @import("std");
const zzig = @import("zzig");

const area_mod = @import("../../../src/area.zig");
const admin_area = @import("AdminArea.zig");
const version = @import("../../../src/version.zig");

const router = zzig.web.router;
const ActionResult = zzig.web.controller.ActionResult;

/// 后台首页控制器。
pub const HomeController = struct {
    /// `GET /{area}/home/index`：控制台卡片 + 菜单。
    pub fn index(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const model = try buildModel(self, c.arena, admin_area.currentUser(c));
        return admin_area.renderView(self, c, "Home", "Index", model);
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
        try builder.str("userName", user);
        try builder.str("siteName", std.mem.trim(u8, site_name, " \t"));
        try builder.str("areaName", self.areaName());
        try builder.str("areaRoute", route);
        try builder.str("uploadPrefix", self.upload_prefix);
        try builder.str("version", version.VERSION);
        try builder.list("menus", &.{ menu_config.finish(), menu_login.finish(), menu_ueditor.finish() });
        try builder.boolean("hasMenus", true);
        return builder.finish();
    }
};

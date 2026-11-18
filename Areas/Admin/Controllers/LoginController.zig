//! 后台登录控制器（对应 C# `Areas/Admin/Controllers/LoginController`）。
//!
//! | 路由（`{area}` 由配置决定） | 说明 |
//! |---|---|
//! | `GET /{area}/login/index` | 登录页 |
//! | `POST /{area}/login/login` | 登录（成功 302 跳后台首页；Ajax 请求返回 JSON 信封） |

const std = @import("std");
const zzig = @import("zzig");

const area_mod = @import("../../../src/area.zig");
const admin_area = @import("AdminArea.zig");

const router = zzig.web.router;
const controller_mod = zzig.web.controller;
const ActionResult = zzig.web.controller.ActionResult;

/// 后台登录控制器。
pub const LoginController = struct {
    /// `GET /{area}/login/index`：渲染登录页。
    pub fn index(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const model = try buildModel(self, c.arena, admin_area.currentUser(c), null);
        return admin_area.renderView(self, c, "Login", "Index", model);
    }

    /// `POST /{area}/login/login`：校验账号（成功 302 / Ajax JSON，失败重渲染并提示）。
    pub fn login(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);

        const user_name = std.mem.trim(u8, c.formValue("UserName") orelse "", " \t\r\n");
        const pass = c.formValue("Password") orelse "";
        const return_url = std.mem.trim(u8, c.formValue("returnUrl") orelse "", " \t\r\n");

        switch (try self.backend.login(c.arena, user_name, pass)) {
            .ok => |user| {
                if (admin_area.isAjax(c)) {
                    var data: std.Io.Writer.Allocating = .init(c.arena);
                    defer data.deinit();
                    try data.writer.print("{{\"id\":{d},\"userName\":", .{user.id});
                    try zzig.web.value.writeJsonString(&data.writer, user.user_name);
                    try data.writer.writeAll(",\"displayName\":");
                    try zzig.web.value.writeJsonString(&data.writer, user.display_name);
                    try data.writer.writeAll(",\"isAdmin\":");
                    try data.writer.writeAll(if (user.is_admin) "true" else "false");
                    try data.writer.writeAll(",\"home\":");
                    try zzig.web.value.writeJsonString(&data.writer, self.home);
                    try data.writer.writeAll("}");
                    return .{ .response = try controller_mod.jsonResult(c.arena, 0, "", try data.toOwnedSlice()) };
                }
                const target = admin_area.safeRedirect(return_url) orelse self.home;
                return .{ .response = try router.Response.redirectAlloc(c.arena, target) };
            },
            .err => |message| {
                zzig.Logger.warn("[ZDsMallUI] 登录失败（{s}）：{s}", .{ user_name, message });
                if (admin_area.isAjax(c)) {
                    return .{ .response = try controller_mod.jsonResult(c.arena, 401, message, null) };
                }
                const model = try buildModel(self, c.arena, admin_area.currentUser(c), message);
                return admin_area.renderView(self, c, "Login", "Index", model);
            },
        }
    }

    /// 组装登录页模型（控制器与测试共用）。
    pub fn buildModel(
        self: *admin_area.AdminArea,
        arena: std.mem.Allocator,
        user: []const u8,
        error_message: ?[]const u8,
    ) !zzig.web.Value {
        const display_name = try self.backend.displayName(arena);
        const route = try area_mod.routePrefix(arena, self.area);

        var builder = zzig.web.ObjectBuilder.init(arena);
        try builder.str("title", try std.fmt.allocPrint(arena, "登录 - {s}", .{display_name}));
        try builder.str("displayName", display_name);
        try builder.str("areaName", self.area);
        try builder.str("areaRoute", route);
        try builder.str("userName", user);
        try builder.boolean("hasError", error_message != null);
        try builder.str("error", error_message orelse "");
        return builder.finish();
    }
};

//! 站点设置控制器（对应 C# `Areas/Admin/Controllers/ConfigController.cs`）。
//!
//! | 路由（`{area}` 由配置决定） | 说明 |
//! |---|---|
//! | `GET /{area}/config/index` | 站点设置页（渲染 `Views/{Area}/Config/Index.cshtml`） |
//! | `POST /{area}/config/updatebase` | 保存设置（字段名与 C# `ConfigController.UpdateBase` 一致） |

const std = @import("std");
const zzig = @import("zzig");

const area_mod = @import("../../../src/deps.zig").area;
const admin_area = @import("AdminArea.zig");

const router = zzig.web.router;
const controller_mod = zzig.web.controller;
const ActionResult = zzig.web.controller.ActionResult;

/// 站点设置控制器。
pub const ConfigController = struct {
    /// `GET /{area}/config/index`：渲染设置页。
    pub fn index(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const model = try buildModel(self, c.arena, false, admin_area.currentUser(c));
        return admin_area.renderView(self, c, "Config", "Index", model);
    }

    /// `POST /{area}/config/updatebase`：保存设置（字段名与 C# `UpdateBase` 参数一致）。
    ///
    /// Ajax 请求返回 JSON 信封；普通表单提交后渲染提示页并自动回跳设置页（与 C# 一致）。
    pub fn updateBase(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);

        const site_name = std.mem.trim(u8, c.formValue("SiteName") orelse "", " \t\r\n");
        if (site_name.len == 0) {
            if (admin_area.isAjax(c)) {
                return .{ .response = try controller_mod.jsonResult(c.arena, 400, "网站名称不可为空", null) };
            }
            return admin_area.renderPrompt(self, c, "网站名称不可为空", false, null);
        }

        switch (try self.backend.saveSettings(c.arena, c.form)) {
            .err => |message| {
                zzig.Logger.warn("[ZDsMallUI] 保存站点设置失败：{s}", .{message});
                if (admin_area.isAjax(c)) {
                    return .{ .response = try controller_mod.jsonResult(c.arena, 500, message, null) };
                }
                return admin_area.renderPrompt(self, c, message, false, null);
            },
            .ok => {},
        }

        // 库已改：通知业务侧把「库值」同步到自己的配置文件（文件名/格式/热加载属业务知识）。
        // 放在响应之前：保存接口返回成功时，磁盘上的配置文件已经是新值。
        self.notifySettingsSaved(c.arena);

        if (admin_area.isAjax(c)) {
            return .{ .response = try controller_mod.jsonResult(c.arena, 0, "保存成功", null) };
        }
        const route = try area_mod.routePrefix(c.arena, self.areaName());
        const back_url = try std.fmt.allocPrint(c.arena, "{s}/config/index", .{route});
        return admin_area.renderPrompt(self, c, "保存成功", true, back_url);
    }

    /// 组装设置页模型（控制器与测试共用）：数据源设置 + 模板必备键。
    pub fn buildModel(
        self: *admin_area.AdminArea,
        arena: std.mem.Allocator,
        saved: bool,
        user: []const u8,
    ) !zzig.web.Value {
        const display_name = try self.backend.displayName(arena);
        const settings = try self.backend.settings(arena);
        const route = try area_mod.routePrefix(arena, self.areaName());

        if (settings != .object) return error.BackendSettingsNotObject;

        var builder = zzig.web.ObjectBuilder.init(arena);
        // 数据源设置优先（缺失的键由 views.withTemplateDefaults 补默认值）
        for (settings.object) |field| try builder.put(field.name, field.value);

        try builder.put("title", .{ .string = try std.fmt.allocPrint(arena, "站点设置 - {s}", .{display_name}) });
        try builder.put("displayName", .{ .string = display_name });
        try builder.put("userName", .{ .string = user });
        try builder.put("saved", .{ .boolean = saved });
        try builder.put("areaName", .{ .string = self.areaName() });
        try builder.put("areaRoute", .{ .string = route });

        // 多语言列表（C# 从 Language.FindByStatus() 取；Zig 侧由数据源提供，缺省为空）
        const languages = settings.get("languages") orelse zzig.web.Value{ .list = &.{} };
        const has_languages = languages == .list and languages.list.len > 0;
        try builder.put("languages", languages);
        try builder.put("hasLanguages", .{ .boolean = has_languages });
        return builder.finish();
    }

    /// 兼容入口（对齐 Rust 版 `AdminArea::page_model`）。
    pub fn pageModel(
        self: *admin_area.AdminArea,
        arena: std.mem.Allocator,
        saved: bool,
        user: []const u8,
    ) !zzig.web.Value {
        return buildModel(self, arena, saved, user);
    }
};

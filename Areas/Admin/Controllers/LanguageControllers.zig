//! 多语言 / 语言包管理（对齐 C# `CultureController` + `LanguagesController`）。
//!
//! **页面在库、菜单在项目**：这两个页面是库提供的能力（任何引库的项目都能用），
//! 但菜单由业务项目自己 `ui.addMenu(...)` 注册 —— 对齐 C# 在业务项目控制器上标 `[DHMenu]`。

const std = @import("std");
const zzig = @import("zzig");

const admin_area = @import("AdminArea.zig");
const language_mod = @import("../../../src/deps.zig").language;

const router = zzig.web.router;
const ActionResult = zzig.web.controller.ActionResult;

/// 多语言（语言列表）。
pub const CultureController = struct {
    /// `GET /{area}/culture`：语言列表（名称 / 代码 / 状态 / 是否默认）。
    pub fn index(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const store = self.languages orelse return renderMissing(self, c);
        const user = admin_area.currentUser(c);
        const culture_id = self.languageIdFor(user);

        var rows: std.ArrayList(zzig.web.Value) = .empty;
        for (store.all()) |row| {
            var builder = zzig.web.ObjectBuilder.init(c.arena);
            try builder.int("id", row.id);
            try builder.str("name", row.name);
            try builder.str("englishName", row.english_name);
            try builder.str("code", row.code);
            try builder.boolean("enabled", row.status);
            try builder.boolean("isDefault", row.is_default);
            try rows.append(c.arena, builder.finish());
        }

        var model = zzig.web.ObjectBuilder.init(c.arena);
        try model.str("title", "多语言管理");
        try model.list("rows", try rows.toOwnedSlice(c.arena));
        try model.str("areaRoute", try areaPrefix(self, c));
        try model.int("currentId", culture_id);
        try model.str("saved", c.queryValue("saved") orelse "");
        try model.str("error", c.queryValue("error") orelse "");
        return admin_area.renderView(self, c, "Culture", "Index", model.finish());
    }

    /// `GET /{area}/culture/setdefault?id=N`：设为默认语言。
    pub fn setDefault(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const store = self.languages orelse return redirectTo(self, c, "/culture/index", "error=未启用多语言");
        const id = std.fmt.parseInt(i32, c.queryValue("id") orelse "", 10) catch 0;
        if (id <= 0) return redirectTo(self, c, "/culture/index", "error=参数 id 无效");
        store.makeDefault(id) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 设置默认语言失败（id={d}）：{s}", .{ id, @errorName(e) });
            return redirectTo(self, c, "/culture/index", "error=保存失败，详见日志");
        };
        return redirectTo(self, c, "/culture/index", "saved=1");
    }

    /// `GET /{area}/culture/togglestatus?id=N`：启用 / 停用。
    pub fn toggleStatus(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const store = self.languages orelse return redirectTo(self, c, "/culture/index", "error=未启用多语言");
        const id = std.fmt.parseInt(i32, c.queryValue("id") orelse "", 10) catch 0;
        const enable = std.mem.eql(u8, c.queryValue("enable") orelse "1", "1");
        if (id <= 0) return redirectTo(self, c, "/culture/index", "error=参数 id 无效");
        store.setStatus(id, enable) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 切换语言状态失败（id={d}）：{s}", .{ id, @errorName(e) });
            return redirectTo(self, c, "/culture/index", "error=保存失败，详见日志");
        };
        return redirectTo(self, c, "/culture/index", "saved=1");
    }

    /// `POST /{area}/culture/add`：新增语言。
    pub fn add(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const store = self.languages orelse return redirectTo(self, c, "/culture/index", "error=未启用多语言");

        const name = std.mem.trim(u8, c.formValue("Name") orelse "", " \t\r\n");
        const english = std.mem.trim(u8, c.formValue("EnglishName") orelse "", " \t\r\n");
        const code = std.mem.trim(u8, c.formValue("UniqueSeoCode") orelse "", " \t\r\n");
        if (name.len == 0 or code.len == 0) return redirectTo(self, c, "/culture/index", "error=名称与语言代码不能为空");
        const order = std.fmt.parseInt(i32, c.formValue("DisplayOrder") orelse "0", 10) catch 0;

        store.addLanguage(name, if (english.len == 0) name else english, code, order) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 新增语言失败（{s}）：{s}", .{ code, @errorName(e) });
            return redirectTo(self, c, "/culture/index", "error=新增失败（语言代码可能已存在）");
        };
        return redirectTo(self, c, "/culture/index", "saved=1");
    }
};

/// 语言包（键值翻译）。
pub const LanguagesController = struct {
    /// `GET /{area}/languages?culture=N`：列出内置键在当前语言下的文本。
    pub fn index(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const store = self.languages orelse return renderMissing(self, c);
        const user = admin_area.currentUser(c);

        const requested = std.fmt.parseInt(i32, c.queryValue("culture") orelse "", 10) catch 0;
        const culture_id = if (requested > 0) requested else self.languageIdFor(user);

        var rows: std.ArrayList(zzig.web.Value) = .empty;
        for (language_mod.BUILTIN_STRINGS) |entry| {
            var builder = zzig.web.ObjectBuilder.init(c.arena);
            try builder.str("key", entry.key);
            // `ident` = 表单字段后缀（`v_<ident>`），也是视图里 `@Model.lang.<ident>` 用的标识符
            try builder.str("ident", try language_mod.identifier(c.arena, entry.key));
            try builder.str("value", store.text(culture_id, entry.key));
            try rows.append(c.arena, builder.finish());
        }

        var options: std.ArrayList(zzig.web.Value) = .empty;
        for (store.all()) |row| {
            if (!row.status) continue;
            var builder = zzig.web.ObjectBuilder.init(c.arena);
            try builder.int("id", row.id);
            try builder.str("name", row.name);
            try builder.boolean("current", row.id == culture_id);
            try options.append(c.arena, builder.finish());
        }

        var model = zzig.web.ObjectBuilder.init(c.arena);
        try model.str("title", "语言包管理");
        try model.list("rows", try rows.toOwnedSlice(c.arena));
        try model.list("cultures", try options.toOwnedSlice(c.arena));
        try model.int("cultureId", culture_id);
        try model.str("areaRoute", try areaPrefix(self, c));
        try model.str("saved", c.queryValue("saved") orelse "");
        try model.str("error", c.queryValue("error") orelse "");
        return admin_area.renderView(self, c, "Languages", "Index", model.finish());
    }

    /// `POST /{area}/languages/save`：保存当前语言下的一批键值。
    ///
    /// 表单字段名形如 `v_<键名>`（键名里的 `.` 换成 `_` 以避免解析问题）。
    pub fn save(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const store = self.languages orelse return redirectTo(self, c, "/languages/index", "error=未启用多语言");
        const culture_id = std.fmt.parseInt(i32, c.formValue("CultureId") orelse "0", 10) catch 0;
        if (culture_id <= 0) return redirectTo(self, c, "/languages/index", "error=语言参数无效");

        var saved: usize = 0;
        for (language_mod.BUILTIN_STRINGS) |entry| {
            const ident = try language_mod.identifier(c.arena, entry.key);
            const field = try std.fmt.allocPrint(c.arena, "v_{s}", .{ident});
            const text = std.mem.trim(u8, c.formValue(field) orelse "", " \t\r\n");
            if (text.len == 0) continue;
            store.saveResource(culture_id, entry.key, text) catch |e| {
                zzig.Logger.err("[ZDsMallUI] 保存语言包失败（{s}）：{s}", .{ entry.key, @errorName(e) });
                return redirectTo(self, c, "/languages/index", "error=保存失败，详见日志");
            };
            saved += 1;
        }
        zzig.Logger.info("[ZDsMallUI] 语言包已保存 {d} 条（culture={d}）", .{ saved, culture_id });
        return redirectTo(self, c, "/languages/index", "saved=1");
    }
};

fn areaPrefix(self: *admin_area.AdminArea, c: *router.Ctx) ![]const u8 {
    return @import("../../../src/deps.zig").area.routePrefix(c.arena, self.areaName());
}

fn redirectTo(self: *admin_area.AdminArea, c: *router.Ctx, path: []const u8, query: []const u8) !ActionResult {
    const prefix = try areaPrefix(self, c);
    const location = try std.fmt.allocPrint(c.arena, "{s}{s}?{s}", .{ prefix, path, query });
    return .{ .response = try router.Response.redirectAlloc(c.arena, location) };
}

fn renderMissing(self: *admin_area.AdminArea, c: *router.Ctx) !ActionResult {
    return admin_area.renderPrompt(self, c, "当前数据源未启用多语言（需要在 Builder 里设置 storage）", false, "");
}

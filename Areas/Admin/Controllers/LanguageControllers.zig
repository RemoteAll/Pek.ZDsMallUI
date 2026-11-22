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

        // 搜索（对齐 C# `Culture/Index`：name 关键字 + status 有效/无效）
        const keyword = std.mem.trim(u8, c.queryValue("name") orelse "", " \t\r\n");
        const status_filter = std.fmt.parseInt(i32, c.queryValue("status") orelse "-1", 10) catch -1;

        var rows: std.ArrayList(zzig.web.Value) = .empty;
        for (store.all()) |row| {
            if (keyword.len > 0) {
                const hit = containsIgnoreCase(row.name, keyword) or
                    containsIgnoreCase(row.display_name, keyword) or
                    containsIgnoreCase(row.english_name, keyword);
                if (!hit) continue;
            }
            if (status_filter == 1 and !row.status) continue;
            if (status_filter == 0 and row.status) continue;

            var builder = zzig.web.ObjectBuilder.init(c.arena);
            try builder.int("id", row.id);
            try builder.str("name", row.name);
            try builder.str("displayName", if (row.display_name.len > 0) row.display_name else row.name);
            try builder.str("englishName", row.english_name);
            try builder.str("languageCulture", row.language_culture);
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
        try model.str("keyword", keyword);
        try model.int("statusFilter", status_filter);
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

    /// `GET /{area}/culture/addculture`：新增页（C# `AddCulture`）。
    pub fn addCulture(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        var model = zzig.web.ObjectBuilder.init(c.arena);
        try model.str("title", "多语言 - 添加");
        try model.str("areaRoute", try areaPrefix(self, c));
        return admin_area.renderView(self, c, "Culture", "AddCulture", model.finish());
    }

    /// `GET /{area}/culture/editculture?id=N`：编辑页（C# `EditCulture`）。
    pub fn editCulture(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const store = self.languages orelse return renderMissing(self, c);
        const id = std.fmt.parseInt(i32, c.queryValue("id") orelse "", 10) catch 0;
        const row = store.find(std.fmt.allocPrint(c.arena, "{d}", .{id}) catch "") orelse
            return redirectTo(self, c, "/culture/index", "error=语言不存在");

        var model = zzig.web.ObjectBuilder.init(c.arena);
        try model.str("title", "多语言 - 编辑");
        try model.str("areaRoute", try areaPrefix(self, c));
        var builder = zzig.web.ObjectBuilder.init(c.arena);
        try builder.int("id", row.id);
        try builder.str("name", row.name);
        try builder.str("displayName", row.display_name);
        try builder.str("englishName", row.english_name);
        try builder.str("languageCulture", row.language_culture);
        try builder.str("code", row.code);
        try builder.str("flag", row.flag);
        try builder.str("domain", row.domain);
        try builder.int("lcid", row.lcid);
        try builder.int("order", row.order);
        try builder.str("remark", row.remark);
        try builder.boolean("enabled", row.status);
        try builder.boolean("isDefault", row.is_default);
        try model.put("row", builder.finish());
        return admin_area.renderView(self, c, "Culture", "EditCulture", model.finish());
    }

    /// `POST /{area}/culture/saveculture`：保存（`Id=0` 新增，否则更新）。
    pub fn saveCulture(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const store = self.languages orelse return redirectTo(self, c, "/culture/index", "error=未启用多语言");

        const id = std.fmt.parseInt(i32, c.formValue("Id") orelse "0", 10) catch 0;
        const name = std.mem.trim(u8, c.formValue("Name") orelse "", " \t\r\n");
        const display_name = std.mem.trim(u8, c.formValue("DisplayName") orelse "", " \t\r\n");
        const english = std.mem.trim(u8, c.formValue("EnglishName") orelse "", " \t\r\n");
        const language_culture = std.mem.trim(u8, c.formValue("LanguageCulture") orelse "", " \t\r\n");
        const code = std.mem.trim(u8, c.formValue("UniqueSeoCode") orelse "", " \t\r\n");
        const remark = std.mem.trim(u8, c.formValue("Remark") orelse "", " \t\r\n");
        const enabled = std.mem.eql(u8, c.formValue("Status") orelse "1", "1");
        const order = std.fmt.parseInt(i32, c.formValue("DisplayOrder") orelse "0", 10) catch 0;
        if (name.len == 0 or code.len == 0) return redirectTo(self, c, "/culture/index", "error=标题与 Url 缩写不能为空");

        if (id > 0) {
            store.updateLanguage(id, name, display_name, english, language_culture, code, enabled, order, remark) catch |e| {
                zzig.Logger.err("[ZDsMallUI] 更新语言失败（id={d}）：{s}", .{ id, @errorName(e) });
                return redirectTo(self, c, "/culture/index", "error=保存失败，详见日志");
            };
        } else {
            store.addLanguage(name, display_name, english, language_culture, code, order) catch |e| {
                zzig.Logger.err("[ZDsMallUI] 新增语言失败（{s}）：{s}", .{ code, @errorName(e) });
                return redirectTo(self, c, "/culture/index", "error=新增失败（Url 缩写可能已存在）");
            };
        }
        return redirectTo(self, c, "/culture/index", "saved=1");
    }

    /// `GET /{area}/culture/delete?id=N`：删除语言（默认语言不可删；连同语言包一起删）。
    pub fn delete(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const store = self.languages orelse return redirectTo(self, c, "/culture/index", "error=未启用多语言");
        const id = std.fmt.parseInt(i32, c.queryValue("id") orelse "", 10) catch 0;
        if (id <= 0) return redirectTo(self, c, "/culture/index", "error=参数 id 无效");
        store.removeLanguage(id) catch |e| {
            zzig.Logger.warn("[ZDsMallUI] 删除语言失败（id={d}）：{s}", .{ id, @errorName(e) });
            return redirectTo(self, c, "/culture/index", if (e == error.CannotRemoveDefaultLanguage) "error=默认语言不可删除" else "error=删除失败，详见日志");
        };
        return redirectTo(self, c, "/culture/index", "saved=1");
    }

    /// `POST /{area}/culture/add`：新增语言。
    pub fn add(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const store = self.languages orelse return redirectTo(self, c, "/culture/index", "error=未启用多语言");

        const name = std.mem.trim(u8, c.formValue("Name") orelse "", " \t\r\n");
        const display_name = std.mem.trim(u8, c.formValue("DisplayName") orelse "", " \t\r\n");
        const english = std.mem.trim(u8, c.formValue("EnglishName") orelse "", " \t\r\n");
        const language_culture = std.mem.trim(u8, c.formValue("LanguageCulture") orelse "", " \t\r\n");
        const code = std.mem.trim(u8, c.formValue("UniqueSeoCode") orelse "", " \t\r\n");
        if (name.len == 0 or code.len == 0) return redirectTo(self, c, "/culture/index", "error=标题与 Url 缩写不能为空");
        const order = std.fmt.parseInt(i32, c.formValue("DisplayOrder") orelse "0", 10) catch 0;

        store.addLanguage(name, display_name, english, language_culture, code, order) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 新增语言失败（{s}）：{s}", .{ code, @errorName(e) });
            return redirectTo(self, c, "/culture/index", "error=新增失败（语言代码可能已存在）");
        };
        return redirectTo(self, c, "/culture/index", "saved=1");
    }
};

/// 语言包（键值翻译）。
pub const LanguagesController = struct {
    /// 供路由挂载：删除一条语言包（挂在模块级，见文件末尾 `deleteResource`）。
    pub const deleteResourceCall = deleteResource;
    /// 供路由挂载：新增 / 编辑 / 保存（模块级函数，见文件末尾）。
    pub const addLanguagesCall = addLanguages;
    pub const editLanguagesCall = editLanguages;
    pub const saveLanguagesCall = saveLanguages;
    /// `GET /{area}/languages?culture=N`：列出内置键在当前语言下的文本。
    pub fn index(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const store = self.languages orelse return renderMissing(self, c);
        const user = admin_area.currentUser(c);

        const requested = std.fmt.parseInt(i32, c.queryValue("culture") orelse "", 10) catch 0;
        const culture_id = if (requested > 0) requested else self.languageIdFor(user);

        // 键集合 = 内置键 ∪ 自定义键（自定义键可在页面上新增/删除）
        // 搜索（对齐 C# `Languages/Index`：lanKey + lanValue）
        const lan_key = std.mem.trim(u8, c.queryValue("lanKey") orelse "", " \t\r\n");
        const lan_value = std.mem.trim(u8, c.queryValue("lanValue") orelse "", " \t\r\n");

        const keys = try store.resourceKeys(c.arena);
        var rows: std.ArrayList(zzig.web.Value) = .empty;
        for (keys) |key| {
            if (lan_key.len > 0 and std.mem.indexOf(u8, key, lan_key) == null) continue;
            const text_value = store.text(culture_id, key);
            if (lan_value.len > 0 and std.mem.indexOf(u8, text_value, lan_value) == null) continue;

            var builder = zzig.web.ObjectBuilder.init(c.arena);
            try builder.str("key", key);
            // `ident` = 表单字段后缀（`v_<ident>`），也是视图里 `@Model.lang.<ident>` 用的标识符
            try builder.str("ident", try language_mod.identifier(c.arena, key));
            try builder.str("value", text_value);
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
        try model.str("cultureName", if (store.find(std.fmt.allocPrint(c.arena, "{d}", .{culture_id}) catch "") ) |row| row.display_name else "");
        try model.str("lanKey", lan_key);
        try model.str("lanValue", lan_value);
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

        // 1) 已有键（内置 ∪ 自定义）：非空就保存
        var saved: usize = 0;
        const keys = try store.resourceKeys(c.arena);
        for (keys) |key| {
            const ident = try language_mod.identifier(c.arena, key);
            const field = try std.fmt.allocPrint(c.arena, "v_{s}", .{ident});
            const text = std.mem.trim(u8, c.formValue(field) orelse "", " \t\r\n");
            if (text.len == 0) continue;
            store.saveResource(culture_id, key, text) catch |e| {
                zzig.Logger.err("[ZDsMallUI] 保存语言包失败（{s}）：{s}", .{ key, @errorName(e) });
                return redirectTo(self, c, "/languages/index", "error=保存失败，详见日志");
            };
            saved += 1;
        }

        // 2) 新增自定义键（`NewKey` + `NewValue`）
        const new_key = std.mem.trim(u8, c.formValue("NewKey") orelse "", " \t\r\n");
        const new_value = std.mem.trim(u8, c.formValue("NewValue") orelse "", " \t\r\n");
        if (new_key.len > 0 and new_value.len > 0) {
            store.saveResource(culture_id, new_key, new_value) catch |e| {
                zzig.Logger.err("[ZDsMallUI] 新增语言包键失败（{s}）：{s}", .{ new_key, @errorName(e) });
                return redirectTo(self, c, "/languages/index", "error=新增键失败，详见日志");
            };
            saved += 1;
        }
        zzig.Logger.info("[ZDsMallUI] 语言包已保存 {d} 条（culture={d}）", .{ saved, culture_id });
        return redirectTo(self, c, "/languages/index", "saved=1");
    }
};

/// `GET /{area}/languages/addlanguages`：新增语言包页（C# `AddLanguages`）。
pub fn addLanguages(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
    const self = admin_area.castSelf(raw);
    var model = zzig.web.ObjectBuilder.init(c.arena);
    try model.str("title", "语言包 - 添加");
    try model.str("areaRoute", try areaPrefix(self, c));
    return admin_area.renderView(self, c, "Languages", "AddLanguages", model.finish());
}

/// `GET /{area}/languages/editlanguages?key=...`：编辑某条语言包（C# `EditLanguages`）。
pub fn editLanguages(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
    const self = admin_area.castSelf(raw);
    const store = self.languages orelse return renderMissing(self, c);
    const key = std.mem.trim(u8, c.queryValue("key") orelse "", " \t\r\n");
    if (key.len == 0) return redirectTo(self, c, "/languages/index", "error=缺少翻译键");

    // 每种语言给出该键的当前值（C# 编辑页就是每种语言一个 textarea）
    var list: std.ArrayList(zzig.web.Value) = .empty;
    for (store.all()) |row| {
        if (!row.status) continue;
        var item = zzig.web.ObjectBuilder.init(c.arena);
        try item.int("id", row.id);
        try item.str("name", row.name);
        try item.str("value", store.text(row.id, key));
        try list.append(c.arena, item.finish());
    }

    var model = zzig.web.ObjectBuilder.init(c.arena);
    try model.str("title", "语言包 - 编辑");
    try model.str("areaRoute", try areaPrefix(self, c));
    try model.str("lanKey", key);
    try model.list("languages", try list.toOwnedSlice(c.arena));
    return admin_area.renderView(self, c, "Languages", "EditLanguages", model.finish());
}

/// `POST /{area}/languages/savelanguages`：新增页/编辑页保存（`LanKey` + `v_<语言id>` 多语言值）。
pub fn saveLanguages(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
    const self = admin_area.castSelf(raw);
    const store = self.languages orelse return redirectTo(self, c, "/languages/index", "error=未启用多语言");

    const key = std.mem.trim(u8, c.formValue("LanKey") orelse "", " \t\r\n");
    if (key.len == 0) return redirectTo(self, c, "/languages/index", "error=翻译键不能为空");

    var saved: usize = 0;
    for (store.all()) |row| {
        if (!row.status) continue;
        const field = try std.fmt.allocPrint(c.arena, "v_{d}", .{row.id});
        const text = std.mem.trim(u8, c.formValue(field) orelse "", " \t\r\n");
        if (text.len == 0) continue;
        store.saveResource(row.id, key, text) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 保存语言包失败（{s}/{s}）：{s}", .{ row.code, key, @errorName(e) });
            return redirectTo(self, c, "/languages/index", "error=保存失败，详见日志");
        };
        saved += 1;
    }
    zzig.Logger.info("[ZDsMallUI] 语言包已保存：{s}（{d} 种语言）", .{ key, saved });
    return redirectTo(self, c, "/languages/index", "saved=1");
}

fn deleteResource(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
    const self = admin_area.castSelf(raw);
    const store = self.languages orelse return redirectTo(self, c, "/languages/index", "error=未启用多语言");
    const culture_id = std.fmt.parseInt(i32, c.queryValue("culture") orelse "0", 10) catch 0;
    const key = std.mem.trim(u8, c.queryValue("key") orelse "", " \t\r\n");
    if (culture_id <= 0 or key.len == 0) return redirectTo(self, c, "/languages/index", "error=参数无效");
    store.removeResource(culture_id, key) catch |e| {
        zzig.Logger.err("[ZDsMallUI] 删除语言包失败（{s}）：{s}", .{ key, @errorName(e) });
        return redirectTo(self, c, "/languages/index", "error=删除失败，详见日志");
    };
    return redirectTo(self, c, "/languages/index", "saved=1");
}

/// 大小写不敏感的子串包含（Zig 0.17 的 std.ascii 没有 indexOfIgnoreCase）。
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

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

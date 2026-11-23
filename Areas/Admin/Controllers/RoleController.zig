//! 角色权限管理（对齐 C# `Areas/Admin/Controllers/RoleController`：列表 / 新增 / 编辑 / 删除）。
//!
//! 数据表是 `Pek.ZCode` 的 `Member.xml` 里的 `Role`（C# 同源），**读写走 ORM**（不手写 SQL）：
//! 表名/列名取自模型，换库（SQLite / MySQL / PostgreSQL）只改连接串。
//!
//! 口径（与 C# 一致）：
//! - `IsSystem = true` 的角色是系统内置：**不能改名、不能删除**（只允许改排序/启用）；
//! - 删除前检查是否还有用户在用（`User.RoleID`），有则拒绝并说明数量。

const std = @import("std");
const zzig = @import("zzig");
const zcode = @import("zcode");

const admin_area = @import("AdminArea.zig");
/// 菜单/动作声明类型（`Item` / `ACTION_TITLES`）
const menu_dep = @import("../../../src/deps.zig").menu;

const router = zzig.web.router;
const ActionResult = zzig.web.controller.ActionResult;

pub const RoleController = struct {
    /// 菜单声明（对齐 C# `[DHMenu]`）
    pub const menu: @import("../../../src/deps.zig").menu.MenuDecl = .{
        .group = "settings",
        .name = "role",
        .title_key = "角色权限管理",
        .url = "{area}/role/index",
        .icon = "&#xe67b;",
        .order = 38,
        // 动作**不限 4 个**：导出 / 审核 / 上架…随意加，权限表按 chips 自动换行
        .actions = &.{ menu_dep.act("index"), menu_dep.act("edit"), menu_dep.act("save"), menu_dep.act("delete") },
    };
    /// `GET /{area}/role/index`：角色列表。
    pub fn index(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;

        var builder = zzig.web.ObjectBuilder.init(arena);
        try buildBase(self, &builder, c, "角色权限管理");

        const rows = listRoles(self, arena) catch |err| blk: {
            zzig.Logger.err("[ZDsMallUI] 读取角色失败：{s}", .{@errorName(err)});
            break :blk @as([]const zzig.web.Value, &.{});
        };
        try builder.list("rows", rows);
        try builder.int("count", @intCast(rows.len));
        try builder.boolean("ready", self.dal != null and self.session != null);
        return admin_area.renderView(self, c, "Role", "Index", builder.finish());
    }

    /// `GET /{area}/role/edit?id=N`：新增（0/缺省）或编辑。
    pub fn edit(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;
        const id = std.fmt.parseInt(i32, c.queryValue("id") orelse "0", 10) catch 0;

        var builder = zzig.web.ObjectBuilder.init(arena);
        try buildBase(self, &builder, c, if (id == 0) "新增角色" else "编辑角色");
        try builder.boolean("ready", self.dal != null and self.session != null);
        try builder.str("error", "");

        var row = RoleRow{};
        if (id != 0) {
            if (self.dal != null and self.session != null) {
                if (loadRole(self, id) catch null) |found| {
                    row = found;
                } else {
                    try builder.str("error", try std.fmt.allocPrint(arena, "角色不存在（Id={d}）", .{id}));
                }
            }
        }
        try putRole(&builder, row, id);
        // 权限勾选树：来自 `Menu` 表（目录分组 + 菜单项），勾选值 = 该菜单 URL 的**控制器段**
        // （与 `AdminArea.canAccess` 同一口径，所以勾完立刻生效）
        var module_count: usize = 0;
        try builder.list("permissionGroups", permissionTree(self, arena, row.permission, row.data_scope_map, &module_count) catch &.{});
        try builder.int("moduleCount", @intCast(module_count));
        return admin_area.renderView(self, c, "Role", "Edit", builder.finish());
    }

    /// `POST /{area}/role/save`：保存（校验失败回到表单并保留输入）。
    pub fn save(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;
        const id = std.fmt.parseInt(i32, c.formValue("id") orelse "0", 10) catch 0;
        const name = std.mem.trim(u8, c.formValue("name") orelse "", " \t\r\n");
        const sort = std.fmt.parseInt(i32, std.mem.trim(u8, c.formValue("sort") orelse "0", " \t\r\n"), 10) catch 0;
        const enable = isOn(c.formValue("enable"));
        // 权限：界面上是复选框 `permission[]`（可多值），存盘为逗号分隔的控制器段串。
        // 兼容旧的手填方式（单值 `permission` 且不是复选框）。
        const permission = try collectPermissions(c.arena, c);
        // 数据范围（角色级，对齐 XCode.Membership `Role.DataScope`）
        const data_scope = std.fmt.parseInt(i32, std.mem.trim(u8, c.formValue("dataScope") orelse "0", " \t\r\n"), 10) catch 0;
        const data_dept_ids = std.mem.trim(u8, c.formValue("dataDeptIds") orelse "", " \t\r\n");
        // 按资源覆盖：表单名 `dataScopeOverride[article]`，值为空 = 继承角色级
        const data_scope_map = try collectScopeOverrides(c.arena, c);

        if (self.dal == null or self.session == null) {
            return renderSaveError(self, c, id, .{ .id = id, .name = name, .sort = sort, .enable = enable, .permission = permission }, "数据库未启用，无法保存角色");
        }
        if (name.len == 0) {
            return renderSaveError(self, c, id, .{ .id = id, .name = name, .sort = sort, .enable = enable, .permission = permission }, "请填写角色名称");
        }

        const result = saveRole(self, .{
            .id = id,
            .name = name,
            .sort = sort,
            .enable = enable,
            .permission = permission,
            .data_scope = data_scope,
            .data_dept_ids = data_dept_ids,
            .data_scope_map = data_scope_map,
        }) catch |err| {
            const message = switch (err) {
                error.DuplicateName => "角色名称已存在，请换一个",
                error.SystemRoleRename => "系统内置角色不允许改名（可改排序 / 启用 / 权限）",
                error.RecordNotFound => "角色不存在（可能已被删除）",
                else => "保存失败，请查看日志",
            };
            if (err != error.OutOfMemory) {
                zzig.Logger.warn("[ZDsMallUI] 保存角色失败（id={d}, name={s}）：{s}", .{ id, name, @errorName(err) });
            }
            return renderSaveError(self, c, id, .{ .id = id, .name = name, .sort = sort, .enable = enable, .permission = permission }, message);
        };
        _ = result;

        const route = try area_mod_prefix(self, arena);
        return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}/role/index?saved=1", .{route})) };
    }

    /// `GET /{area}/role/delete?id=N`：删除（系统角色 / 仍被用户引用 → 拒绝）。
    pub fn delete(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;
        const id = std.fmt.parseInt(i32, c.queryValue("id") orelse "0", 10) catch 0;
        const route = try area_mod_prefix(self, arena);
        const back = try std.fmt.allocPrint(arena, "{s}/role/index", .{route});

        if (id == 0) return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}?denied=1", .{back})) };
        const removed = removeRole(self, id) catch |err| {
            zzig.Logger.warn("[ZDsMallUI] 删除角色失败（Id={d}）：{s}", .{ id, @errorName(err) });
            const flag = switch (err) {
                error.SystemRoleDelete => "system",
                error.RoleInUse => "inuse",
                else => "denied",
            };
            return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}?{s}=1", .{ back, flag })) };
        };
        const flag = if (removed) "deleted" else "denied";
        return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}?{s}=1", .{ back, flag })) };
    }
};

/// 角色行（页面用）。
const RoleRow = struct {
    id: i32 = 0,
    name: []const u8 = "",
    role_type: i32 = 0,
    enable: bool = true,
    is_system: bool = false,
    permission: []const u8 = "",
    sort: i32 = 0,
    /// 数据范围：0 全部 / 1 本部门及下级 / 2 本部门 / 3 仅本人 / 4 自定义
    /// （对齐 XCode.Membership `Role.DataScope`，业务查询据此加 where）
    data_scope: i32 = 0,
    /// 自定义范围时的部门编号列表（逗号分隔，`Role.DataDepartmentIds`）
    data_dept_ids: []const u8 = "",
    /// 按资源覆盖的数据范围（存 `Role.Ex4`，格式 `article=3;order=1`；未列出的资源用角色级 `data_scope`）
    data_scope_map: []const u8 = "",
};

const SaveInput = struct {
    id: i32,
    name: []const u8,
    sort: i32,
    enable: bool,
    permission: []const u8,
    /// 数据范围：0 全部 / 1 本部门及下级 / 2 本部门 / 3 仅本人 / 4 自定义
    data_scope: i32 = 0,
    /// 自定义范围时的部门编号（逗号分隔）
    data_dept_ids: []const u8 = "",
    /// 按资源覆盖（`article=3;order=1`，存 `Role.Ex4`）
    data_scope_map: []const u8 = "",
};

fn buildBase(self: *admin_area.AdminArea, builder: *zzig.web.ObjectBuilder, c: *router.Ctx, title: []const u8) !void {
    const arena = c.arena;
    try builder.str("title", title);
    try builder.str("areaRoute", try area_mod_prefix(self, arena));
    try builder.str("userName", admin_area.currentUser(c));
    try builder.str("saved", c.queryValue("saved") orelse "");
    try builder.str("deleted", c.queryValue("deleted") orelse "");
    try builder.str("denied", c.queryValue("denied") orelse "");
    try builder.str("system", c.queryValue("system") orelse "");
    try builder.str("inuse", c.queryValue("inuse") orelse "");
}

fn area_mod_prefix(self: *admin_area.AdminArea, arena: std.mem.Allocator) ![]u8 {
    return self.routePrefix(arena);
}

fn putRole(builder: *zzig.web.ObjectBuilder, row: RoleRow, id: i32) !void {
    try builder.int("id", id);
    var b = zzig.web.ObjectBuilder.init(builder.arena);
    try b.int("id", row.id);
    try b.str("name", row.name);
    try b.int("type", row.role_type);
    try b.boolean("enable", row.enable);
    try b.boolean("isSystem", row.is_system);
    try b.str("permission", row.permission);
    try b.int("sort", row.sort);
    try b.int("dataScope", row.data_scope);
    try b.str("dataDeptIds", row.data_dept_ids);
    try b.str("dataScopeMap", row.data_scope_map);
    try builder.put("row", b.finish());
}

fn isOn(raw: ?[]const u8) bool {
    const value = raw orelse return false;
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true");
}

/// 从表单收集权限（`permission[]` 多值 / 兼容旧的单个 `permission` 手填串），去重后拼成逗号串。
fn collectPermissions(arena: std.mem.Allocator, c: *router.Ctx) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(arena);

    for (c.form) |field| {
        const is_multi = std.mem.eql(u8, field.name, "permission[]");
        const is_single = std.mem.eql(u8, field.name, "permission");
        if (!is_multi and !is_single) continue;

        // 单值可能本身就是逗号串（旧数据/手填）→ 逐段拆
        var it = std.mem.splitScalar(u8, field.value, ',');
        while (it.next()) |raw| {
            const one = std.mem.trim(u8, raw, " \t\r\n");
            if (one.len == 0) continue;
            if (seen.contains(one)) continue;
            try seen.put(arena, try arena.dupe(u8, one), {});
            if (out.items.len > 0) try out.append(arena, ',');
            try out.appendSlice(arena, one);
        }
    }
    return out.toOwnedSlice(arena);
}

/// 权限勾选树：`[{ name: 目录名, items: [{ key: 控制器段, title: 菜单标题, actions: [{name,title,allowed,checked}] }] }]`。
///
/// `key` 取菜单 URL 的第二段（`{area}/role/index` → `role`）—— 与 `AdminArea.canAccess` 完全同口径。
/// 动作清单来自控制器上声明的 `menu.actions`（没声明 = 只给「查看」），
/// 勾选值写成 `role.save` 这种「控制器.动作」，由 `AdminArea.canAction` 判定。
fn permissionTree(
    self: *admin_area.AdminArea,
    arena: std.mem.Allocator,
    current: []const u8,
    scope_map: []const u8,
    total_out: ?*usize,
) ![]const zzig.web.Value {
    if (total_out) |t| t.* = 0;
    const dal = self.dal orelse return &.{};
    const s = self.session orelse return &.{};

    var q = zcode.Query.init(arena);
    defer q.deinit();
    _ = try q.orderBy("Sort", false);
    _ = try q.orderBy("ID", false);

    const ref = try dal.table("Menu");
    s.resetResults();
    const rows = try ref.queryRows(s, &q);

    // 控制器声明的动作（按控制器段索引）
    const decls: []const menu_dep.Item = if (self.menus) |reg| reg.itemList() else &.{};

    var groups: std.ArrayList(zzig.web.Value) = .empty;
    for (rows) |row| {
        if (columnInt(row, "Type") != 1) continue;
        if (columnInt(row, "ParentID") != 0) continue;
        const group_id = columnInt(row, "ID");

        var items: std.ArrayList(zzig.web.Value) = .empty;
        for (rows) |child| {
            if (columnInt(child, "Type") != 2) continue;
            if (columnInt(child, "ParentID") != group_id) continue;
            const key = controllerOfUrl(columnText(child, "Url"));
            if (key.len == 0) continue; // 目录/外链之类没有控制器段，跳过
            const title = columnText(child, "DisplayName");

            var acts: std.ArrayList(zzig.web.Value) = .empty;
            for (declActions(decls, key)) |a| {
                var ab = zzig.web.ObjectBuilder.init(arena);
                try ab.str("name", a.name);
                try ab.str("title", menu_dep.actionTitle(a));
                try ab.boolean("check", admin_area.AdminArea.permissionAllows(current, key, a.name));
                try acts.append(arena, ab.finish());
            }

            // 该资源的数据范围覆盖（`article=3` → hasScopeOverride + scopeOverride）
            const ov = scopeOverrideOf(scope_map, key);

            var b = zzig.web.ObjectBuilder.init(arena);
            try b.str("key", key);
            try b.str("title", if (title.len == 0) key else title);
            try b.boolean("checked", permissionHas(current, key));
            try b.boolean("hasScopeOverride", ov.has);
            try b.int("scopeOverride", ov.value);
            try b.list("actions", try acts.toOwnedSlice(arena));
            try items.append(arena, b.finish());
        }
        if (items.items.len == 0) continue;

        const group_title = columnText(row, "DisplayName");
        var gb = zzig.web.ObjectBuilder.init(arena);
        try gb.str("name", if (group_title.len == 0) try arena.dupe(u8, columnText(row, "Name")) else group_title);
        try gb.int("count", @intCast(items.items.len));
        if (total_out) |t| t.* += items.items.len;
        try gb.list("items", try items.toOwnedSlice(arena));
        try groups.append(arena, gb.finish());
    }
    return groups.toOwnedSlice(arena);
}

/// 控制器（按 `name` 或 URL 控制器段匹配）声明的动作清单。
/// 没声明任何动作的控制器 = 只有 `index`（只看不改）。
fn declActions(decls: []const menu_dep.Item, key: []const u8) []const menu_dep.Action {
    for (decls) |d| {
        const same = std.ascii.eqlIgnoreCase(d.name, key) or std.ascii.eqlIgnoreCase(controllerOfUrl(d.url), key);
        if (!same) continue;
        if (d.actions.len > 0) return d.actions;
        break;
    }
    return &only_index;
}

const only_index = [_]menu_dep.Action{.{ .name = "index" }};

/// `{area}/role/index` → `role`；`{area}/home/dashboard` → `home`；解析不出返回空串。
fn controllerOfUrl(url: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, url, '/');
    _ = it.next(); // `{area}` 段
    const seg = it.next() orelse return "";
    return std.mem.trim(u8, seg, " \t\r\n");
}

fn permissionHas(permission: []const u8, key: []const u8) bool {
    var it = std.mem.splitScalar(u8, permission, ',');
    while (it.next()) |raw| {
        const one = std.mem.trim(u8, raw, " \t\r\n");
        if (one.len == 0) continue;
        if (std.mem.eql(u8, one, "*")) return true; // 超级管理员 = 全选
        if (std.ascii.eqlIgnoreCase(one, key)) return true;
    }
    return false;
}

/// 读全部角色（按 Sort、ID 升序）。
fn listRoles(self: *admin_area.AdminArea, arena: std.mem.Allocator) ![]const zzig.web.Value {
    const dal = self.dal orelse return &.{};
    const s = self.session orelse return &.{};

    var q = zcode.Query.init(arena);
    defer q.deinit();
    _ = try q.orderBy("Sort", false);
    _ = try q.orderBy("ID", false);

    const ref = try dal.table("Role");
    s.resetResults();
    const rows = try ref.queryRows(s, &q);

    var out: std.ArrayList(zzig.web.Value) = .empty;
    for (rows) |row| {
        var b = zzig.web.ObjectBuilder.init(arena);
        try b.int("id", columnInt(row, "ID"));
        try b.str("name", try arena.dupe(u8, columnText(row, "Name")));
        try b.int("type", columnInt(row, "Type"));
        try b.boolean("enable", columnInt(row, "Enable") != 0);
        try b.boolean("isSystem", columnInt(row, "IsSystem") != 0);
        try b.int("sort", columnInt(row, "Sort"));
        try out.append(arena, b.finish());
    }
    return out.toOwnedSlice(arena);
}

fn loadRole(self: *admin_area.AdminArea, id: i32) !RoleRow {
    const dal = self.dal orelse return error.NotAttached;
    const s = self.session orelse return error.NotAttached;
    const ref = try dal.table("Role");
    var w = zcode.Where.init(s.gpa);
    defer w.deinit();
    _ = try w.eq("ID", .{ .int = id });

    var q = zcode.Query.init(s.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w);
    _ = q.take(1);

    s.resetResults();
    const rows = try ref.queryRows(s, &q);
    if (rows.len == 0) return error.RecordNotFound;
    const row = rows[0];
    return .{
        .id = columnInt(row, "ID"),
        .name = try self.allocator.dupe(u8, columnText(row, "Name")),
        .role_type = columnInt(row, "Type"),
        .enable = columnInt(row, "Enable") != 0,
        .is_system = columnInt(row, "IsSystem") != 0,
        .permission = try self.allocator.dupe(u8, columnText(row, "Permission")),
        .sort = columnInt(row, "Sort"),
        .data_scope = columnInt(row, "DataScope"),
        .data_dept_ids = try self.allocator.dupe(u8, columnText(row, "DataDepartmentIds")),
        .data_scope_map = try self.allocator.dupe(u8, columnText(row, "Ex4")),
    };
}

fn saveRole(self: *admin_area.AdminArea, input: SaveInput) !void {
    const dal = self.dal orelse return error.NotAttached;
    const s = self.session orelse return error.NotAttached;
    const ref = try dal.table("Role");

    // 唯一性（排除自己）
    var w = zcode.Where.init(s.gpa);
    defer w.deinit();
    _ = try w.eq("Name", .{ .text = input.name });
    s.resetResults();

    var q0 = zcode.Query.init(s.gpa);
    defer q0.deinit();
    _ = q0.filterWhere(&w);
    const same = try ref.queryRows(s, &q0);
    if (same.len > 0 and columnInt(same[0], "ID") != input.id) return error.DuplicateName;

    if (input.id == 0) {
        const now = zcode.DateTime.nowLocal();
        _ = try ref.insert(s, &.{
            zcode.dbtable.field("Name", .{ .text = input.name }),
            zcode.dbtable.field("Type", .{ .int = 2 }),
            zcode.dbtable.field("Enable", .{ .int = if (input.enable) 1 else 0 }),
            zcode.dbtable.field("IsSystem", .{ .int = 0 }),
            zcode.dbtable.field("Sort", .{ .int = input.sort }),
            zcode.dbtable.field("Permission", .{ .text = input.permission }),
            zcode.dbtable.field("DataScope", .{ .int = input.data_scope }),
            zcode.dbtable.field("DataDepartmentIds", .{ .text = input.data_dept_ids }),
            zcode.dbtable.field("Ex4", .{ .text = input.data_scope_map }),
            // 表上这两列 NOT NULL 且无默认（C# 由拦截器填），`TableRef.insert` 不自动带 → 必须显式传
            zcode.dbtable.field("CreateTime", .{ .datetime = now }),
            zcode.dbtable.field("UpdateTime", .{ .datetime = now }),
        });
        return;
    }

    var w2 = zcode.Where.init(s.gpa);
    defer w2.deinit();
    _ = try w2.eq("ID", .{ .int = input.id });
    s.resetResults();
    var q = zcode.Query.init(s.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w2);
    _ = q.take(1);
    const rows = try ref.queryRows(s, &q);
    if (rows.len == 0) return error.RecordNotFound;
    const is_system = columnInt(rows[0], "IsSystem") != 0;
    const current_name = columnText(rows[0], "Name");
    if (is_system and !std.mem.eql(u8, current_name, input.name)) return error.SystemRoleRename;

    // 超级管理员（权限串 `*`）的数据范围固定「全部」：视图里已不渲染选项，
    // 但手工 POST / 旧书签仍可能提交小范围，这里再兜一层，避免超管把自己锁成「仅本人」。
    const is_super = admin_area.AdminArea.hasAllPermission(input.permission);
    const data_scope = if (is_super) 0 else input.data_scope;
    const data_dept_ids: []const u8 = if (is_super) "" else input.data_dept_ids;
    const data_scope_map: []const u8 = if (is_super) "" else input.data_scope_map;

    _ = try ref.updateOne(s, &.{
        zcode.dbtable.field("Name", .{ .text = input.name }),
        zcode.dbtable.field("Enable", .{ .int = if (input.enable) 1 else 0 }),
        zcode.dbtable.field("Sort", .{ .int = input.sort }),
        zcode.dbtable.field("Permission", .{ .text = input.permission }),
        zcode.dbtable.field("DataScope", .{ .int = data_scope }),
        zcode.dbtable.field("DataDepartmentIds", .{ .text = data_dept_ids }),
        zcode.dbtable.field("Ex4", .{ .text = data_scope_map }),
    }, &w2, 0);
}

fn removeRole(self: *admin_area.AdminArea, id: i32) !bool {
    const dal = self.dal orelse return error.NotAttached;
    const s = self.session orelse return error.NotAttached;

    var w = zcode.Where.init(s.gpa);
    defer w.deinit();
    _ = try w.eq("ID", .{ .int = id });
    s.resetResults();
    const ref = try dal.table("Role");
    var q = zcode.Query.init(s.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w);
    _ = q.take(1);
    const rows = try ref.queryRows(s, &q);
    if (rows.len == 0) return false;
    if (columnInt(rows[0], "IsSystem") != 0) return error.SystemRoleDelete;

    // 仍被用户引用 → 拒绝（C# 同口径）
    var wu = zcode.Where.init(s.gpa);
    defer wu.deinit();
    _ = try wu.eq("RoleID", .{ .int = id });
    const users = try dal.table("User");
    s.resetResults();
    if (try users.count(s, &wu) > 0) return error.RoleInUse;

    _ = try ref.deleteOne(s, &w, 0);
    return true;
}

fn renderSaveError(
    self: *admin_area.AdminArea,
    c: *router.Ctx,
    id: i32,
    row: RoleRow,
    message: []const u8,
) !ActionResult {
    var builder = zzig.web.ObjectBuilder.init(c.arena);
    try buildBase(self, &builder, c, if (id == 0) "新增角色" else "编辑角色");
    try builder.boolean("ready", self.dal != null and self.session != null);
    try builder.str("error", message);
    try putRole(&builder, row, id);
    // 校验失败回到表单时同样要给出勾选树：视图里的 `@foreach (Model.permissionGroups)`
    // 一旦为 null 会直接渲染失败（整页 500），所以这里与 edit() 保持同一套模型。
    var module_count: usize = 0;
    try builder.list("permissionGroups", permissionTree(self, c.arena, row.permission, row.data_scope_map, &module_count) catch &.{});
    try builder.int("moduleCount", @intCast(module_count));
    return admin_area.renderView(self, c, "Role", "Edit", builder.finish());
}

// ————— 行取值小工具（`queryRows` 返回按列名的通用行）————

fn columnIndex(row: anytype, name: []const u8) ?usize {
    for (row.names, 0..) |n, i| {
        if (std.ascii.eqlIgnoreCase(n, name)) return i;
    }
    return null;
}

fn columnInt(row: anytype, name: []const u8) i32 {
    const idx = columnIndex(row, name) orelse return 0;
    return switch (row.values[idx]) {
        .int => |v| @intCast(v),
        .boolean => |v| if (v) 1 else 0,
        else => 0,
    };
}

fn columnText(row: anytype, name: []const u8) []const u8 {
    const idx = columnIndex(row, name) orelse return "";
    return switch (row.values[idx]) {
        .text => |v| v,
        else => "",
    };
}

/// 收集按资源覆盖的数据范围：表单名 `dataScopeOverride[article]`，值为 `0..4`（空 = 继承角色级）。
/// 输出格式 `article=3;order=1`（存 `Role.Ex4`）。
fn collectScopeOverrides(arena: std.mem.Allocator, c: *router.Ctx) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (c.form) |field| {
        const prefix = "dataScopeOverride[";
        if (!std.mem.startsWith(u8, field.name, prefix)) continue;
        if (!std.mem.endsWith(u8, field.name, "]")) continue;
        const key = std.mem.trim(u8, field.name[prefix.len .. field.name.len - 1], " \t\r\n");
        const val = std.mem.trim(u8, field.value, " \t\r\n");
        if (key.len == 0 or val.len == 0) continue;
        _ = std.fmt.parseInt(i32, val, 10) catch continue; // 只收 0..4 的数字
        if (out.items.len > 0) try out.append(arena, ';');
        try out.appendSlice(arena, key);
        try out.append(arena, '=');
        try out.appendSlice(arena, val);
    }
    return out.toOwnedSlice(arena);
}

/// 资源级范围覆盖：`map` 形如 `article=3;order=1`。
const ScopeOverride = struct { has: bool, value: i32 };

fn scopeOverrideOf(map: []const u8, key: []const u8) ScopeOverride {
    var it = std.mem.splitScalar(u8, map, ';');
    while (it.next()) |raw| {
        const one = std.mem.trim(u8, raw, " \t\r\n");
        if (one.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, one, '=') orelse continue;
        const k = std.mem.trim(u8, one[0..eq], " \t\r\n");
        const v = std.mem.trim(u8, one[eq + 1 ..], " \t\r\n");
        if (!std.ascii.eqlIgnoreCase(k, key)) continue;
        const n = std.fmt.parseInt(i32, v, 10) catch continue;
        return .{ .has = true, .value = n };
    }
    return .{ .has = false, .value = 0 };
}

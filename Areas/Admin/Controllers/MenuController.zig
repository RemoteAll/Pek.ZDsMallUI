//! 菜单管理（对齐 C# `Areas/Admin/Controllers/MenuController`：列表 / 新增 / 编辑 / 删除）。
//!
//! 数据表是 `Pek.ZCode` 的 `Member.xml` 里的 `Menu`（C# 同源，`BaseType="EntityTree"`），
//! **读写走 ORM**（不手写 SQL）。
//!
//! 与代码注册的关系（两条路径同一份数据）：
//! - 项目启动时 `ui.addMenu(...)` 注册的菜单会被 `menu_db.seedFromRegistry` **写进这张表**（只补缺）；
//! - 菜单渲染**以表为准**（`AdminArea.menuGroups` 优先读表），所以这里改完刷新即生效；
//! - `DisplayName` 就是语言包键（中文源文），与视图里的 `@T("…")` 同一套回退。

const std = @import("std");
const zzig = @import("zzig");
const zcode = @import("zcode");

const admin_area = @import("AdminArea.zig");
const menu_db = @import("../../../src/deps.zig").menu_db;

const router = zzig.web.router;
const ActionResult = zzig.web.controller.ActionResult;

pub const MenuController = struct {
    /// `GET /{area}/menu/index`：菜单树列表（目录 + 其下菜单项）。
    pub fn index(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;

        var builder = zzig.web.ObjectBuilder.init(arena);
        try buildBase(self, &builder, c, "菜单管理");

        const rows = listMenus(self, arena) catch |err| blk: {
            zzig.Logger.err("[ZDsMallUI] 读取菜单失败：{s}", .{@errorName(err)});
            break :blk @as([]const zzig.web.Value, &.{});
        };
        try builder.list("rows", rows);
        try builder.int("count", @intCast(rows.len));
        try builder.boolean("ready", self.dal != null and self.session != null);
        return admin_area.renderView(self, c, "Menu", "Index", builder.finish());
    }

    /// `GET /{area}/menu/edit?id=N`：新增（0/缺省）或编辑。
    pub fn edit(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;
        const id = std.fmt.parseInt(i32, c.queryValue("id") orelse "0", 10) catch 0;

        var builder = zzig.web.ObjectBuilder.init(arena);
        try buildBase(self, &builder, c, if (id == 0) "新增菜单" else "编辑菜单");
        try builder.boolean("ready", self.dal != null and self.session != null);
        try builder.str("error", "");

        var row = MenuRow{};
        if (id != 0) {
            if (self.dal != null and self.session != null) {
                if (loadMenu(self, id) catch null) |found| {
                    row = found;
                } else {
                    try builder.str("error", try std.fmt.allocPrint(arena, "菜单不存在（Id={d}）", .{id}));
                }
            }
        }
        try putMenu(&builder, row, id);
        // 父级下拉（只列目录）
        try builder.list("parents", try parentOptions(self, arena));
        return admin_area.renderView(self, c, "Menu", "Edit", builder.finish());
    }

    /// `POST /{area}/menu/save`：保存（校验失败回到表单并保留输入）。
    pub fn save(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;
        const id = std.fmt.parseInt(i32, c.formValue("id") orelse "0", 10) catch 0;

        const input = SaveInput{
            .id = id,
            .parent_id = std.fmt.parseInt(i32, std.mem.trim(u8, c.formValue("parentId") orelse "0", " \t\r\n"), 10) catch 0,
            .name = std.mem.trim(u8, c.formValue("name") orelse "", " \t\r\n"),
            .display_name = std.mem.trim(u8, c.formValue("displayName") orelse "", " \t\r\n"),
            .menu_type = std.fmt.parseInt(i32, std.mem.trim(u8, c.formValue("type") orelse "2", " \t\r\n"), 10) catch 2,
            .url = std.mem.trim(u8, c.formValue("url") orelse "", " \t\r\n"),
            .icon = std.mem.trim(u8, c.formValue("icon") orelse "", " \t\r\n"),
            .sort = std.fmt.parseInt(i32, std.mem.trim(u8, c.formValue("sort") orelse "0", " \t\r\n"), 10) catch 0,
            .visible = isOn(c.formValue("visible")),
            .remark = std.mem.trim(u8, c.formValue("remark") orelse "", " \t\r\n"),
        };

        if (self.dal == null or self.session == null) {
            return renderSaveError(self, c, input, "数据库未启用，无法保存菜单");
        }
        if (input.name.len == 0) return renderSaveError(self, c, input, "请填写菜单键（英文/数字/下划线）");
        if (input.display_name.len == 0) return renderSaveError(self, c, input, "请填写显示名称");
        if (input.menu_type == menu_db.TYPE_MENU and input.url.len == 0) {
            return renderSaveError(self, c, input, "菜单项必须填写链接");
        }

        saveMenu(self, input) catch |err| {
            const message = switch (err) {
                error.DuplicateName => "同一父级下已有同名菜单，请换一个菜单键",
                error.ParentMustBeDir => "上级必须是「目录」类型",
                error.ParentNotFound => "上级菜单不存在（可能已被删除）",
                error.RecordNotFound => "菜单不存在（可能已被删除）",
                else => "保存失败，请查看日志",
            };
            if (err != error.OutOfMemory) {
                zzig.Logger.warn("[ZDsMallUI] 保存菜单失败（id={d}, name={s}）：{s}", .{ input.id, input.name, @errorName(err) });
            }
            return renderSaveError(self, c, input, message);
        };

        const route = try self.routePrefix(arena);
        return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}/menu/index?saved=1", .{route})) };
    }

    /// `GET /{area}/menu/delete?id=N`：删除（有子菜单时拒绝）。
    pub fn delete(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;
        const id = std.fmt.parseInt(i32, c.queryValue("id") orelse "0", 10) catch 0;
        const route = try self.routePrefix(arena);
        const back = try std.fmt.allocPrint(arena, "{s}/menu/index", .{route});

        if (id == 0) return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}?denied=1", .{back})) };
        _ = removeMenu(self, id) catch |err| {
            zzig.Logger.warn("[ZDsMallUI] 删除菜单失败（Id={d}）：{s}", .{ id, @errorName(err) });
            const flag = switch (err) {
                error.HasChildren => "children",
                else => "denied",
            };
            return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}?{s}=1", .{ back, flag })) };
        };
        return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}?deleted=1", .{back})) };
    }
};

const MenuRow = struct {
    id: i32 = 0,
    parent_id: i32 = 0,
    name: []const u8 = "",
    display_name: []const u8 = "",
    menu_type: i32 = 2,
    url: []const u8 = "",
    icon: []const u8 = "",
    sort: i32 = 0,
    visible: bool = true,
    remark: []const u8 = "",
};

const SaveInput = struct {
    id: i32,
    parent_id: i32,
    name: []const u8,
    display_name: []const u8,
    menu_type: i32,
    url: []const u8,
    icon: []const u8,
    sort: i32,
    visible: bool,
    remark: []const u8,
};

fn buildBase(
    self: *admin_area.AdminArea,
    builder: *zzig.web.ObjectBuilder,
    c: *router.Ctx,
    title: []const u8,
) !void {
    const arena = c.arena;
    try builder.str("title", title);
    try builder.str("areaRoute", try self.routePrefix(arena));
    try builder.str("userName", admin_area.currentUser(c));
    try builder.str("saved", c.queryValue("saved") orelse "");
    try builder.str("deleted", c.queryValue("deleted") orelse "");
    try builder.str("denied", c.queryValue("denied") orelse "");
    try builder.str("children", c.queryValue("children") orelse "");
}

fn putMenu(builder: *zzig.web.ObjectBuilder, row: MenuRow, id: i32) !void {
    try builder.int("id", id);
    var b = zzig.web.ObjectBuilder.init(builder.arena);
    try b.int("id", row.id);
    try b.int("parentId", row.parent_id);
    try b.str("name", row.name);
    try b.str("displayName", row.display_name);
    try b.int("type", row.menu_type);
    try b.str("url", row.url);
    try b.str("icon", row.icon);
    try b.int("sort", row.sort);
    try b.boolean("visible", row.visible);
    try b.str("remark", row.remark);
    try builder.put("row", b.finish());
}

fn isOn(raw: ?[]const u8) bool {
    const value = raw orelse return false;
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true");
}

/// 目录 + 其下菜单，按 `Sort`、`ID` 升序平铺（视图用 `level` 缩进）。
fn listMenus(self: *admin_area.AdminArea, arena: std.mem.Allocator) ![]const zzig.web.Value {
    const dal = self.dal orelse return &.{};
    const s = self.session orelse return &.{};

    var q = zcode.Query.init(arena);
    defer q.deinit();
    _ = try q.orderBy("Sort", false);
    _ = try q.orderBy("ID", false);

    const ref = try dal.table("Menu");
    s.resetResults();
    const rows = try ref.queryRows(s, &q);

    var out: std.ArrayList(zzig.web.Value) = .empty;
    // 先目录（ParentID=0），再各自子项
    for (rows) |row| {
        if (columnInt(row, "ParentID") != 0) continue;
        try out.append(arena, try rowValue(arena, row, 0));
        const group_id = columnInt(row, "ID");
        for (rows) |child| {
            if (columnInt(child, "ParentID") != group_id) continue;
            try out.append(arena, try rowValue(arena, child, 1));
        }
    }
    // 父级已被删掉的孤儿行也列出来（否则界面上看不到、也没法删）
    for (rows) |row| {
        const pid = columnInt(row, "ParentID");
        if (pid == 0) continue;
        var parent_exists = false;
        for (rows) |candidate| {
            if (columnInt(candidate, "ID") == pid) {
                parent_exists = true;
                break;
            }
        }
        if (!parent_exists) try out.append(arena, try rowValue(arena, row, 1));
    }
    return out.toOwnedSlice(arena);
}

fn rowValue(arena: std.mem.Allocator, row: anytype, level: i32) !zzig.web.Value {
    var b = zzig.web.ObjectBuilder.init(arena);
    try b.int("id", columnInt(row, "ID"));
    try b.int("parentId", columnInt(row, "ParentID"));
    try b.str("name", try arena.dupe(u8, columnText(row, "Name")));
    try b.str("displayName", try arena.dupe(u8, columnText(row, "DisplayName")));
    try b.int("type", columnInt(row, "Type"));
    try b.str("url", try arena.dupe(u8, columnText(row, "Url")));
    try b.int("sort", columnInt(row, "Sort"));
    try b.boolean("visible", columnInt(row, "Visible") != 0);
    try b.int("level", level);
    return b.finish();
}

/// 父级下拉：只列目录（`Type=1`），并标出「（无）」。
fn parentOptions(self: *admin_area.AdminArea, arena: std.mem.Allocator) ![]const zzig.web.Value {
    const dal = self.dal orelse return &.{};
    const s = self.session orelse return &.{};

    var q = zcode.Query.init(arena);
    defer q.deinit();
    _ = try q.orderBy("Sort", false);

    const ref = try dal.table("Menu");
    s.resetResults();
    const rows = try ref.queryRows(s, &q);

    var out: std.ArrayList(zzig.web.Value) = .empty;
    var none = zzig.web.ObjectBuilder.init(arena);
    try none.int("id", 0);
    try none.str("name", "（无，作为一级目录）");
    try out.append(arena, none.finish());

    for (rows) |row| {
        if (columnInt(row, "Type") != menu_db.TYPE_DIR) continue;
        if (columnInt(row, "ParentID") != 0) continue;
        var b = zzig.web.ObjectBuilder.init(arena);
        try b.int("id", columnInt(row, "ID"));
        try b.str("name", try std.fmt.allocPrint(arena, "{s}（{s}）", .{
            try arena.dupe(u8, columnText(row, "DisplayName")),
            try arena.dupe(u8, columnText(row, "Name")),
        }));
        try out.append(arena, b.finish());
    }
    return out.toOwnedSlice(arena);
}

fn loadMenu(self: *admin_area.AdminArea, id: i32) !MenuRow {
    const dal = self.dal orelse return error.NotAttached;
    const s = self.session orelse return error.NotAttached;
    const ref = try dal.table("Menu");
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
        .parent_id = columnInt(row, "ParentID"),
        .name = try self.allocator.dupe(u8, columnText(row, "Name")),
        .display_name = try self.allocator.dupe(u8, columnText(row, "DisplayName")),
        .menu_type = if (columnInt(row, "Type") == 0) menu_db.TYPE_MENU else columnInt(row, "Type"),
        .url = try self.allocator.dupe(u8, columnText(row, "Url")),
        .icon = try self.allocator.dupe(u8, columnText(row, "Icon")),
        .sort = columnInt(row, "Sort"),
        .visible = columnInt(row, "Visible") != 0,
        .remark = try self.allocator.dupe(u8, columnText(row, "Remark")),
    };
}

fn saveMenu(self: *admin_area.AdminArea, input: SaveInput) !void {
    const dal = self.dal orelse return error.NotAttached;
    const s = self.session orelse return error.NotAttached;
    const ref = try dal.table("Menu");

    // 目录不能有父级；菜单项必须有目录父级
    var parent_id = input.parent_id;
    if (input.menu_type == menu_db.TYPE_DIR) parent_id = 0;
    if (input.menu_type == menu_db.TYPE_MENU) {
        if (parent_id == 0) return error.ParentMustBeDir;
        var wp = zcode.Where.init(s.gpa);
        defer wp.deinit();
        _ = try wp.eq("ID", .{ .int = parent_id });
        s.resetResults();
        var qp = zcode.Query.init(s.gpa);
        defer qp.deinit();
        _ = qp.filterWhere(&wp);
        _ = qp.take(1);
        const parents = try ref.queryRows(s, &qp);
        if (parents.len == 0) return error.ParentNotFound;
        if (columnInt(parents[0], "Type") != menu_db.TYPE_DIR) return error.ParentMustBeDir;
    }

    // `ParentID + Name` 唯一（表上就是这条唯一索引，排除自己）
    {
        var w = zcode.Where.init(s.gpa);
        defer w.deinit();
        _ = try w.eq("ParentID", .{ .int = parent_id });
        _ = try w.eq("Name", .{ .text = input.name });
        s.resetResults();
        var q0 = zcode.Query.init(s.gpa);
        defer q0.deinit();
        _ = q0.filterWhere(&w);
        const same = try ref.queryRows(s, &q0);
        if (same.len > 0 and columnInt(same[0], "ID") != input.id) return error.DuplicateName;
    }

    if (input.id == 0) {
        const now = zcode.DateTime.nowLocal();
        _ = try ref.insert(s, &.{
            zcode.dbtable.field("ParentID", .{ .int = parent_id }),
            zcode.dbtable.field("Name", .{ .text = input.name }),
            zcode.dbtable.field("DisplayName", .{ .text = input.display_name }),
            zcode.dbtable.field("Type", .{ .int = input.menu_type }),
            zcode.dbtable.field("Url", .{ .text = input.url }),
            zcode.dbtable.field("Icon", .{ .text = input.icon }),
            zcode.dbtable.field("Sort", .{ .int = input.sort }),
            zcode.dbtable.field("Visible", .{ .boolean = input.visible }),
            zcode.dbtable.field("Remark", .{ .text = input.remark }),
            // 两列 NOT NULL 且无默认（C# 由拦截器填）
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

    _ = try ref.updateOne(s, &.{
        zcode.dbtable.field("ParentID", .{ .int = parent_id }),
        zcode.dbtable.field("Name", .{ .text = input.name }),
        zcode.dbtable.field("DisplayName", .{ .text = input.display_name }),
        zcode.dbtable.field("Type", .{ .int = input.menu_type }),
        zcode.dbtable.field("Url", .{ .text = input.url }),
        zcode.dbtable.field("Icon", .{ .text = input.icon }),
        zcode.dbtable.field("Sort", .{ .int = input.sort }),
        zcode.dbtable.field("Visible", .{ .boolean = input.visible }),
        zcode.dbtable.field("Remark", .{ .text = input.remark }),
        zcode.dbtable.field("UpdateTime", .{ .datetime = zcode.DateTime.nowLocal() }),
    }, &w2, 0);
}

fn removeMenu(self: *admin_area.AdminArea, id: i32) !bool {
    const dal = self.dal orelse return error.NotAttached;
    const s = self.session orelse return error.NotAttached;

    // 有子菜单 → 拒绝（先删子项，避免一次操作删掉整棵树）
    var wc = zcode.Where.init(s.gpa);
    defer wc.deinit();
    _ = try wc.eq("ParentID", .{ .int = id });
    const ref = try dal.table("Menu");
    s.resetResults();
    if (try ref.count(s, &wc) > 0) return error.HasChildren;

    var w = zcode.Where.init(s.gpa);
    defer w.deinit();
    _ = try w.eq("ID", .{ .int = id });
    s.resetResults();
    _ = try ref.deleteOne(s, &w, 0);
    return true;
}

fn renderSaveError(
    self: *admin_area.AdminArea,
    c: *router.Ctx,
    input: SaveInput,
    message: []const u8,
) !ActionResult {
    var builder = zzig.web.ObjectBuilder.init(c.arena);
    try buildBase(self, &builder, c, if (input.id == 0) "新增菜单" else "编辑菜单");
    try builder.boolean("ready", self.dal != null and self.session != null);
    try builder.str("error", message);
    try putMenu(&builder, .{
        .id = input.id,
        .parent_id = input.parent_id,
        .name = input.name,
        .display_name = input.display_name,
        .menu_type = input.menu_type,
        .url = input.url,
        .icon = input.icon,
        .sort = input.sort,
        .visible = input.visible,
        .remark = input.remark,
    }, input.id);
    try builder.list("parents", try parentOptions(self, c.arena));
    return admin_area.renderView(self, c, "Menu", "Edit", builder.finish());
}

// ————— 行取值小工具 —————

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

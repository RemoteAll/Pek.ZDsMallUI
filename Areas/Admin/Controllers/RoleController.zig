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

const router = zzig.web.router;
const ActionResult = zzig.web.controller.ActionResult;

pub const RoleController = struct {
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
        const permission = c.formValue("permission") orelse "";

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
};

const SaveInput = struct {
    id: i32,
    name: []const u8,
    sort: i32,
    enable: bool,
    permission: []const u8,
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
    try builder.put("row", b.finish());
}

fn isOn(raw: ?[]const u8) bool {
    const value = raw orelse return false;
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true");
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

    _ = try ref.updateOne(s, &.{
        zcode.dbtable.field("Name", .{ .text = input.name }),
        zcode.dbtable.field("Enable", .{ .int = if (input.enable) 1 else 0 }),
        zcode.dbtable.field("Sort", .{ .int = input.sort }),
        zcode.dbtable.field("Permission", .{ .text = input.permission }),
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

//! 管理员管理（对齐 C# `Areas/Admin/Controllers/AdminUserController`：列表 / 新增 / 编辑 / 删除）。
//!
//! 数据表是 `Pek.ZCode` 的 `Member.xml` 里的 `User`（C# 同源）。口径：
//! - 只能管理**后台账号**（`Ex1 = 1`），前台会员不在这里出现；
//! - 口令一律走 `password.hash`（与 C# `SaltPasswordProvider` 字节级互通），**留空 = 不改**；
//! - 不能删除自己；不能把最后一个「超级管理员」账号删掉/改角色（否则没人能进后台）。

const std = @import("std");
const zzig = @import("zzig");
const zcode = @import("zcode");

const admin_area = @import("AdminArea.zig");
const deps = @import("../../../src/deps.zig");

const router = zzig.web.router;
const ActionResult = zzig.web.controller.ActionResult;

pub const AdminUserController = struct {
    /// 菜单声明（对齐 C# `[DHMenu]`）
    pub const menu: @import("../../../src/deps.zig").menu.MenuDecl = .{
        .group = "settings",
        .name = "adminuser",
        .title_key = "管理员管理",
        .url = "{area}/adminuser/index",
        .icon = "&#xe67d;",
        .order = 37,
    };
    /// `GET /{area}/adminuser/index`：管理员列表。
    pub fn index(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;

        var builder = zzig.web.ObjectBuilder.init(arena);
        try buildBase(self, &builder, c, "管理员管理");

        const rows = listUsers(self, arena) catch |err| blk: {
            zzig.Logger.err("[ZDsMallUI] 读取管理员失败：{s}", .{@errorName(err)});
            break :blk @as([]const zzig.web.Value, &.{});
        };
        try builder.list("rows", rows);
        try builder.int("count", @intCast(rows.len));
        try builder.boolean("ready", self.dal != null and self.session != null);
        return admin_area.renderView(self, c, "AdminUser", "Index", builder.finish());
    }

    /// `GET /{area}/adminuser/edit?id=N`：新增（0/缺省）或编辑。
    pub fn edit(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;
        const id = std.fmt.parseInt(i32, c.queryValue("id") orelse "0", 10) catch 0;

        var builder = zzig.web.ObjectBuilder.init(arena);
        try buildBase(self, &builder, c, if (id == 0) "新增管理员" else "编辑管理员");
        try builder.boolean("ready", self.dal != null and self.session != null);
        try builder.str("error", "");

        var row = UserRow{};
        if (id != 0) {
            if (self.dal != null and self.session != null) {
                if (loadUser(self, id) catch null) |found| {
                    row = found;
                } else {
                    try builder.str("error", try std.fmt.allocPrint(arena, "管理员不存在（Id={d}）", .{id}));
                }
            }
        }
        try putUser(&builder, row, id);
        try builder.list("roles", try roleOptions(self, arena, row.role_id));
        return admin_area.renderView(self, c, "AdminUser", "Edit", builder.finish());
    }

    /// `POST /{area}/adminuser/save`：保存（口令留空 = 不改）。
    pub fn save(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;
        const id = std.fmt.parseInt(i32, c.formValue("id") orelse "0", 10) catch 0;

        const input = SaveInput{
            .id = id,
            .name = std.mem.trim(u8, c.formValue("name") orelse "", " \t\r\n"),
            .display_name = std.mem.trim(u8, c.formValue("displayName") orelse "", " \t\r\n"),
            .password = c.formValue("password") orelse "",
            .role_id = std.fmt.parseInt(i32, std.mem.trim(u8, c.formValue("roleId") orelse "0", " \t\r\n"), 10) catch 0,
            .enable = isOn(c.formValue("enable")),
            .mail = std.mem.trim(u8, c.formValue("mail") orelse "", " \t\r\n"),
            .mobile = std.mem.trim(u8, c.formValue("mobile") orelse "", " \t\r\n"),
            .remark = std.mem.trim(u8, c.formValue("remark") orelse "", " \t\r\n"),
        };

        if (self.dal == null or self.session == null) {
            return renderSaveError(self, c, input, "数据库未启用，无法保存管理员");
        }
        if (input.name.len == 0) return renderSaveError(self, c, input, "请填写登录名");
        if (input.role_id == 0) return renderSaveError(self, c, input, "请选择角色");
        if (id == 0 and input.password.len == 0) return renderSaveError(self, c, input, "新增管理员必须设置口令");

        saveUser(self, input) catch |err| {
            const message = switch (err) {
                error.DuplicateName => "登录名已存在，请换一个",
                error.RecordNotFound => "管理员不存在（可能已被删除）",
                error.LastSuperAdmin => "这是最后一个超级管理员，不能改角色或停用（否则没人能进后台）",
                else => "保存失败，请查看日志",
            };
            if (err != error.OutOfMemory) {
                zzig.Logger.warn("[ZDsMallUI] 保存管理员失败（id={d}, name={s}）：{s}", .{ input.id, input.name, @errorName(err) });
            }
            return renderSaveError(self, c, input, message);
        };

        const route = try self.routePrefix(arena);
        return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}/adminuser/index?saved=1", .{route})) };
    }

    /// `GET /{area}/adminuser/delete?id=N`：删除（不能删自己 / 最后一个超级管理员）。
    pub fn delete(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const arena = c.arena;
        const id = std.fmt.parseInt(i32, c.queryValue("id") orelse "0", 10) catch 0;
        const route = try self.routePrefix(arena);
        const back = try std.fmt.allocPrint(arena, "{s}/adminuser/index", .{route});

        if (id == 0) return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}?denied=1", .{back})) };
        _ = removeUser(self, id, admin_area.currentUser(c)) catch |err| {
            zzig.Logger.warn("[ZDsMallUI] 删除管理员失败（Id={d}）：{s}", .{ id, @errorName(err) });
            const flag = switch (err) {
                error.DeleteSelf => "self",
                error.LastSuperAdmin => "lastsuper",
                else => "denied",
            };
            return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}?{s}=1", .{ back, flag })) };
        };
        return .{ .response = try router.Response.redirectAlloc(arena, try std.fmt.allocPrint(arena, "{s}?deleted=1", .{back})) };
    }
};

const UserRow = struct {
    id: i32 = 0,
    name: []const u8 = "",
    display_name: []const u8 = "",
    role_id: i32 = 0,
    enable: bool = true,
    mail: []const u8 = "",
    mobile: []const u8 = "",
    remark: []const u8 = "",
};

const SaveInput = struct {
    id: i32,
    name: []const u8,
    display_name: []const u8,
    password: []const u8,
    role_id: i32,
    enable: bool,
    mail: []const u8,
    mobile: []const u8,
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
    try builder.str("self", c.queryValue("self") orelse "");
    try builder.str("lastsuper", c.queryValue("lastsuper") orelse "");
}

fn putUser(builder: *zzig.web.ObjectBuilder, row: UserRow, id: i32) !void {
    try builder.int("id", id);
    var b = zzig.web.ObjectBuilder.init(builder.arena);
    try b.int("id", row.id);
    try b.str("name", row.name);
    try b.str("displayName", row.display_name);
    try b.int("roleId", row.role_id);
    try b.boolean("enable", row.enable);
    try b.str("mail", row.mail);
    try b.str("mobile", row.mobile);
    try b.str("remark", row.remark);
    try builder.put("row", b.finish());
}

fn isOn(raw: ?[]const u8) bool {
    const value = raw orelse return false;
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true");
}

/// 后台账号（`Ex1 = 1`）+ 角色名。
fn listUsers(self: *admin_area.AdminArea, arena: std.mem.Allocator) ![]const zzig.web.Value {
    const dal = self.dal orelse return &.{};
    const s = self.session orelse return &.{};

    const roles = try loadRolesMap(self, arena);

    var w = zcode.Where.init(s.gpa);
    defer w.deinit();
    _ = try w.eq("Ex1", .{ .int = 1 });

    var q = zcode.Query.init(s.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w);
    _ = try q.orderBy("ID", false);

    const ref = try dal.table("User");
    s.resetResults();
    const rows = try ref.queryRows(s, &q);

    var out: std.ArrayList(zzig.web.Value) = .empty;
    for (rows) |row| {
        const role_id = columnInt(row, "RoleID");
        var b = zzig.web.ObjectBuilder.init(arena);
        try b.int("id", columnInt(row, "ID"));
        try b.str("name", try arena.dupe(u8, columnText(row, "Name")));
        try b.str("displayName", try arena.dupe(u8, columnText(row, "DisplayName")));
        try b.int("roleId", role_id);
        try b.str("roleName", roleNameOf(roles, role_id));
        try b.boolean("enable", columnInt(row, "Enable") != 0);
        try b.str("mail", try arena.dupe(u8, columnText(row, "Mail")));
        try b.str("mobile", try arena.dupe(u8, columnText(row, "Mobile")));
        try b.int("logins", columnInt(row, "Logins"));
        try b.str("lastLogin", try arena.dupe(u8, columnText(row, "LastLogin")));
        try out.append(arena, b.finish());
    }
    return out.toOwnedSlice(arena);
}

const RoleLite = struct { id: i32, name: []const u8, permission: []const u8 };

fn loadRolesMap(self: *admin_area.AdminArea, arena: std.mem.Allocator) ![]const RoleLite {
    const dal = self.dal orelse return &.{};
    const s = self.session orelse return &.{};
    const ref = try dal.table("Role");
    var q = zcode.Query.init(s.gpa);
    defer q.deinit();
    _ = try q.orderBy("Sort", false);
    s.resetResults();
    const rows = try ref.queryRows(s, &q);
    var out: std.ArrayList(RoleLite) = .empty;
    for (rows) |row| {
        try out.append(arena, .{
            .id = columnInt(row, "ID"),
            .name = try arena.dupe(u8, columnText(row, "Name")),
            .permission = try arena.dupe(u8, columnText(row, "Permission")),
        });
    }
    return out.toOwnedSlice(arena);
}

fn roleNameOf(roles: []const RoleLite, id: i32) []const u8 {
    for (roles) |r| {
        if (r.id == id) return r.name;
    }
    return "";
}

fn roleOptions(self: *admin_area.AdminArea, arena: std.mem.Allocator, current: i32) ![]const zzig.web.Value {
    const roles = try loadRolesMap(self, arena);
    var out: std.ArrayList(zzig.web.Value) = .empty;
    for (roles) |r| {
        var b = zzig.web.ObjectBuilder.init(arena);
        try b.int("id", r.id);
        try b.str("name", r.name);
        try b.boolean("current", r.id == current);
        try out.append(arena, b.finish());
    }
    return out.toOwnedSlice(arena);
}

fn loadUser(self: *admin_area.AdminArea, id: i32) !UserRow {
    const dal = self.dal orelse return error.NotAttached;
    const s = self.session orelse return error.NotAttached;
    const ref = try dal.table("User");
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
        .display_name = try self.allocator.dupe(u8, columnText(row, "DisplayName")),
        .role_id = columnInt(row, "RoleID"),
        .enable = columnInt(row, "Enable") != 0,
        .mail = try self.allocator.dupe(u8, columnText(row, "Mail")),
        .mobile = try self.allocator.dupe(u8, columnText(row, "Mobile")),
        .remark = try self.allocator.dupe(u8, columnText(row, "Remark")),
    };
}

fn saveUser(self: *admin_area.AdminArea, input: SaveInput) !void {
    const dal = self.dal orelse return error.NotAttached;
    const s = self.session orelse return error.NotAttached;
    const ref = try dal.table("User");

    // 登录名唯一（排除自己）
    {
        var w = zcode.Where.init(s.gpa);
        defer w.deinit();
        _ = try w.eq("Name", .{ .text = input.name });
        s.resetResults();
        var q0 = zcode.Query.init(s.gpa);
        defer q0.deinit();
        _ = q0.filterWhere(&w);
        const same = try ref.queryRows(s, &q0);
        if (same.len > 0 and columnInt(same[0], "ID") != input.id) return error.DuplicateName;
    }

    // 口令：留空不改（编辑）；新增必须给
    var hashed: ?[]const u8 = null;
    defer if (hashed) |h| self.allocator.free(h);
    if (input.password.len > 0) {
        hashed = deps.password.hash(self.allocator, self.io, input.password) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 生成口令散列失败（{s}）", .{@errorName(e)});
            return e;
        };
    }

    if (input.id == 0) {
        const plain_hash = hashed orelse return error.PasswordRequired;
        const now = zcode.DateTime.nowLocal();
        _ = try ref.insert(s, &.{
            zcode.dbtable.field("Name", .{ .text = input.name }),
            zcode.dbtable.field("Password", .{ .text = plain_hash }),
            zcode.dbtable.field("DisplayName", .{ .text = input.display_name }),
            zcode.dbtable.field("RoleID", .{ .int = input.role_id }),
            zcode.dbtable.field("Ex1", .{ .int = 1 }), // 后台账号标记
            zcode.dbtable.field("Enable", .{ .boolean = input.enable }),
            zcode.dbtable.field("Mail", .{ .text = input.mail }),
            zcode.dbtable.field("Mobile", .{ .text = input.mobile }),
            zcode.dbtable.field("Remark", .{ .text = input.remark }),
            zcode.dbtable.field("Logins", .{ .int = 0 }),
            zcode.dbtable.field("UpdateUser", .{ .text = "" }),
            // `User` 表**没有 CreateTime**（C# 的 User 实体是 `RegisterTime`），只有 UpdateTime 是 NOT NULL
            zcode.dbtable.field("UpdateTime", .{ .datetime = now }),
        });
        return;
    }

    // 编辑：先取原记录（判断是否最后一个超级管理员）
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

    const old_role = columnInt(rows[0], "RoleID");
    const was_super = roleHasStar(self, old_role);
    const will_super = roleHasStar(self, input.role_id);
    if (was_super and (!will_super or !input.enable)) {
        if (try countSuperAdmins(self, input.id) == 0) return error.LastSuperAdmin;
    }

    var sets = std.ArrayList(zcode.sqlbuild.Field).empty;
    defer sets.deinit(s.gpa);
    try sets.append(s.gpa, zcode.dbtable.field("Name", .{ .text = input.name }));
    try sets.append(s.gpa, zcode.dbtable.field("DisplayName", .{ .text = input.display_name }));
    try sets.append(s.gpa, zcode.dbtable.field("RoleID", .{ .int = input.role_id }));
    try sets.append(s.gpa, zcode.dbtable.field("Enable", .{ .boolean = input.enable }));
    try sets.append(s.gpa, zcode.dbtable.field("Mail", .{ .text = input.mail }));
    try sets.append(s.gpa, zcode.dbtable.field("Mobile", .{ .text = input.mobile }));
    try sets.append(s.gpa, zcode.dbtable.field("Remark", .{ .text = input.remark }));
    try sets.append(s.gpa, zcode.dbtable.field("UpdateTime", .{ .datetime = zcode.DateTime.nowLocal() }));
    if (hashed) |h| try sets.append(s.gpa, zcode.dbtable.field("Password", .{ .text = h }));

    _ = try ref.updateOne(s, sets.items, &w2, 0);
}

fn removeUser(self: *admin_area.AdminArea, id: i32, operator_name: []const u8) !bool {
    const dal = self.dal orelse return error.NotAttached;
    const s = self.session orelse return error.NotAttached;

    var w = zcode.Where.init(s.gpa);
    defer w.deinit();
    _ = try w.eq("ID", .{ .int = id });
    s.resetResults();
    const ref = try dal.table("User");
    var q = zcode.Query.init(s.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w);
    _ = q.take(1);
    const rows = try ref.queryRows(s, &q);
    if (rows.len == 0) return false;

    const name = columnText(rows[0], "Name");
    if (std.mem.eql(u8, name, operator_name)) return error.DeleteSelf;

    const role_id = columnInt(rows[0], "RoleID");
    if (roleHasStar(self, role_id)) {
        if (try countSuperAdmins(self, id) == 0) return error.LastSuperAdmin;
    }

    _ = try ref.deleteOne(s, &w, 0);
    return true;
}

/// 除 `exclude_id` 外还有几个**启用的、角色权限含 `*`** 的后台账号。
fn countSuperAdmins(self: *admin_area.AdminArea, exclude_id: i32) !usize {
    const dal = self.dal orelse return 0;
    const s = self.session orelse return 0;
    const ref = try dal.table("User");

    var w = zcode.Where.init(s.gpa);
    defer w.deinit();
    _ = try w.eq("Ex1", .{ .int = 1 });
    var q = zcode.Query.init(s.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w);
    s.resetResults();
    const rows = try ref.queryRows(s, &q);

    var count: usize = 0;
    for (rows) |row| {
        if (columnInt(row, "ID") == exclude_id) continue;
        if (columnInt(row, "Enable") == 0) continue;
        if (roleHasStar(self, columnInt(row, "RoleID"))) count += 1;
    }
    return count;
}

/// 角色权限串是否含通配 `*`（= 超级管理员）。查不到按「否」。
fn roleHasStar(self: *admin_area.AdminArea, role_id: i32) bool {
    if (role_id == 0) return false;
    const dal = self.dal orelse return false;
    const s = self.session orelse return false;
    const ref = dal.table("Role") catch return false;
    var w = zcode.Where.init(s.gpa);
    defer w.deinit();
    _ = w.eq("ID", .{ .int = role_id }) catch return false;
    var q = zcode.Query.init(s.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w);
    _ = q.take(1);
    s.resetResults();
    const rows = ref.queryRows(s, &q) catch return false;
    if (rows.len == 0) return false;
    var it = std.mem.splitScalar(u8, columnText(rows[0], "Permission"), ',');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "*")) return true;
    }
    return false;
}

fn renderSaveError(
    self: *admin_area.AdminArea,
    c: *router.Ctx,
    input: SaveInput,
    message: []const u8,
) !ActionResult {
    var builder = zzig.web.ObjectBuilder.init(c.arena);
    try buildBase(self, &builder, c, if (input.id == 0) "新增管理员" else "编辑管理员");
    try builder.boolean("ready", self.dal != null and self.session != null);
    try builder.str("error", message);
    try putUser(&builder, .{
        .id = input.id,
        .name = input.name,
        .display_name = input.display_name,
        .role_id = input.role_id,
        .enable = input.enable,
        .mail = input.mail,
        .mobile = input.mobile,
        .remark = input.remark,
    }, input.id);
    try builder.list("roles", try roleOptions(self, c.arena, input.role_id));
    return admin_area.renderView(self, c, "AdminUser", "Edit", builder.finish());
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

//! 菜单的**数据库读写**（`Menu` 表，来自 `Pek.ZCode` 的 `membership/Member.xml`，与 C# 同源）。
//!
//! 为什么单独一个文件：`menu.zig` 只管「内存注册表 + 组装视图模型」（不依赖 DB，库自测不需要建库）；
//! 这里负责「代码注册 → 表 seed」「表 → 视图模型」，让后台的「菜单管理」是**真生效**的
//! （改名称/排序/隐藏后刷新即变），而不是只改一份没人读的表。
//!
//! 表结构（`BaseType="EntityTree"`）：
//! - 分组：`Type = 1`，`ParentID = 0`，`Name` = 分组键（`console` / `settings`），`DisplayName` = 中文标题；
//! - 菜单项：`Type = 2`，`ParentID` = 分组 ID，`Name` = 菜单键，`DisplayName` = 中文标题（同时是语言包键）。
//!
//! Seed 口径（对齐 C# `[DHMenu]` 重复扫描 upsert）：
//! - 首次启动把代码注册的菜单**插入**表；
//! - 已存在的行**只更新** `Url` / `Icon` / `Sort` / `ParentID` / `Type`，
//!   **保留**运维在后台改过的 `DisplayName` / `Visible` —— 否则每次重启把用户改动覆盖回去，等于假功能。

const std = @import("std");
const zzig = @import("zzig");
const zcode = @import("zcode");

const language = @import("language.zig");
const menu_mod = @import("menu.zig");

const value = zzig.web.value;

/// `Menu` 表的连接（`Dal` + 会话由库的 SQLite 后端提供）。
pub const Store = struct {
    dal: *zcode.Dal,
    session: *zcode.Session,
};

/// `Menu.Type`：1 = 目录（顶部导航分组）
pub const TYPE_DIR: i32 = 1;
/// `Menu.Type`：2 = 菜单（左侧菜单项）
pub const TYPE_MENU: i32 = 2;

/// 表里有没有菜单数据（决定渲染走表还是走内存注册表）。
pub fn hasRows(store: Store) bool {
    const ref = store.dal.table("Menu") catch return false;
    var q = zcode.Query.init(store.session.gpa);
    defer q.deinit();
    _ = q.take(1);
    store.session.resetResults();
    const rows = ref.queryRows(store.session, &q) catch return false;
    return rows.len > 0;
}

/// 把代码注册的菜单 upsert 进 `Menu` 表（幂等）。
///
/// 返回写入了多少行；失败只记日志、不影响启动（菜单表不可用时就继续用内存注册表）。
pub fn seedFromRegistry(
    store: Store,
    allocator: std.mem.Allocator,
    groups: []const menu_mod.Group,
    items: []const menu_mod.Item,
) !usize {
    const ref = try store.dal.table("Menu");
    const session = store.session;
    var written: usize = 0;

    // ————— 1. 分组（Type=1, ParentID=0）—————
    for (groups) |group| {
        const existing = try loadByPath(allocator, store, 0, group.key);
        defer freeMaybe(allocator, existing);
        if (existing) |row| {
            try updateMeta(store, row.id, .{
                .display_name = row.display_name,
                .url = "",
                .icon = "",
                .sort = group.order,
                .parent_id = 0,
                .type = TYPE_DIR,
            });
        } else {
            const now = zcode.DateTime.nowLocal();
            _ = try ref.insert(session, &.{
                zcode.dbtable.field("ParentID", .{ .int = 0 }),
                zcode.dbtable.field("Name", .{ .text = group.key }),
                zcode.dbtable.field("DisplayName", .{ .text = group.title_key }),
                zcode.dbtable.field("Type", .{ .int = TYPE_DIR }),
                zcode.dbtable.field("Url", .{ .text = "" }),
                zcode.dbtable.field("Sort", .{ .int = group.order }),
                zcode.dbtable.field("Icon", .{ .text = "" }),
                zcode.dbtable.field("Visible", .{ .boolean = true }),
                // 两列 NOT NULL 且无默认（C# 由拦截器填），`TableRef.insert` 不自动带
                zcode.dbtable.field("CreateTime", .{ .datetime = now }),
                zcode.dbtable.field("UpdateTime", .{ .datetime = now }),
            });
        }
        written += 1;
    }

    // ————— 2. 菜单项（Type=2, ParentID=分组 ID）—————
    for (items) |item| {
        const parent_row = (try loadByPath(allocator, store, 0, item.group)) orelse continue;
        defer allocator.free(parent_row.display_name);
        const parent_id = parent_row.id;

        const existing = try loadByPath(allocator, store, parent_id, item.name);
        defer freeMaybe(allocator, existing);
        if (existing) |row| {
            try updateMeta(store, row.id, .{
                .display_name = row.display_name, // 保留后台改过的名称
                .url = item.url,
                .icon = item.icon,
                .sort = item.order,
                .parent_id = parent_id,
                .type = TYPE_MENU,
            });
        } else {
            const now = zcode.DateTime.nowLocal();
            _ = try ref.insert(session, &.{
                zcode.dbtable.field("ParentID", .{ .int = parent_id }),
                zcode.dbtable.field("Name", .{ .text = item.name }),
                zcode.dbtable.field("DisplayName", .{ .text = item.title_key }),
                zcode.dbtable.field("Type", .{ .int = TYPE_MENU }),
                zcode.dbtable.field("Url", .{ .text = item.url }),
                zcode.dbtable.field("Sort", .{ .int = item.order }),
                zcode.dbtable.field("Icon", .{ .text = item.icon }),
                zcode.dbtable.field("Visible", .{ .boolean = item.visible }),
                zcode.dbtable.field("CreateTime", .{ .datetime = now }),
                zcode.dbtable.field("UpdateTime", .{ .datetime = now }),
            });
        }
        written += 1;
    }
    return written;
}

/// 从 `Menu` 表构建 `Model.groups`（与 `menu.Registry.build` 输出同构）。
///
/// `null` = 表里没有任何分组（调用方回退到内存注册表）。
pub fn buildValue(
    store: Store,
    arena: std.mem.Allocator,
    area_prefix: []const u8,
    languages: *const language.Store,
    culture_id: i32,
) !?value.Value {
    const ref = try store.dal.table("Menu");
    const session = store.session;

    var q = zcode.Query.init(session.gpa);
    defer q.deinit();
    _ = try q.orderBy("Sort", false);
    _ = try q.orderBy("ID", false);

    session.resetResults();
    const rows = try ref.queryRows(session, &q);
    if (rows.len == 0) return null;

    // 先收分组（Type=1）
    var group_list: std.ArrayList(value.Value) = .empty;
    for (rows) |row| {
        if (columnInt(row, "Type") != TYPE_DIR) continue;
        if (columnInt(row, "ParentID") != 0) continue;
        const group_id = columnInt(row, "ID");

        var item_list: std.ArrayList(value.Value) = .empty;
        for (rows) |child| {
            if (columnInt(child, "Type") != TYPE_MENU) continue;
            if (columnInt(child, "ParentID") != group_id) continue;
            if (columnInt(child, "Visible") == 0) continue;

            // 名称一律走语言包（DisplayName 就是中文键；与 `@T("…")` 同一套回退：查不到就用键本身）
            const display = columnText(child, "DisplayName");
            const title = if (display.len == 0) columnText(child, "Name") else languages.text(culture_id, display);

            var item_builder = value.ObjectBuilder.init(arena);
            try item_builder.str("name", try arena.dupe(u8, columnText(child, "Name")));
            try item_builder.str("title", title);
            try item_builder.str("url", try menu_mod.expandUrl(arena, columnText(child, "Url"), area_prefix));
            try item_builder.str("icon", try arena.dupe(u8, columnText(child, "Icon")));
            try item_list.append(arena, item_builder.finish());
        }
        if (item_list.items.len == 0) continue;

        const group_display = columnText(row, "DisplayName");
        var group_builder = value.ObjectBuilder.init(arena);
        try group_builder.str("key", try arena.dupe(u8, columnText(row, "Name")));
        try group_builder.str("name", if (group_display.len == 0) try arena.dupe(u8, columnText(row, "Name")) else languages.text(culture_id, group_display));
        try group_builder.list("items", try item_list.toOwnedSlice(arena));
        try group_list.append(arena, group_builder.finish());
    }

    if (group_list.items.len == 0) return null;
    return value.Value{ .list = try group_list.toOwnedSlice(arena) };
}

// ————— 内部 —————

const Row = struct {
    id: i32,
    display_name: []const u8,
};

const UpdateInput = struct {
    display_name: []const u8,
    url: []const u8,
    icon: []const u8,
    sort: i32,
    parent_id: i32,
    type: i32,
};

fn updateMeta(store: Store, id: i32, input: UpdateInput) !void {
    const ref = try store.dal.table("Menu");
    var w = zcode.Where.init(store.session.gpa);
    defer w.deinit();
    _ = try w.eq("ID", .{ .int = id });
    store.session.resetResults();
    _ = try ref.updateOne(store.session, &.{
        zcode.dbtable.field("ParentID", .{ .int = input.parent_id }),
        zcode.dbtable.field("Type", .{ .int = input.type }),
        zcode.dbtable.field("Url", .{ .text = input.url }),
        zcode.dbtable.field("Icon", .{ .text = input.icon }),
        zcode.dbtable.field("Sort", .{ .int = input.sort }),
        zcode.dbtable.field("DisplayName", .{ .text = input.display_name }),
    }, &w, 0);
}

/// 按 `ParentID + Name` 查一行（`Menu` 的唯一索引就是这两列）。
/// 返回的 `display_name` 用调用方 allocator 复制，用完要 `freeMaybe`。
fn loadByPath(allocator: std.mem.Allocator, store: Store, parent_id: i32, name: []const u8) !?Row {
    const ref = store.dal.table("Menu") catch return null;
    var w = zcode.Where.init(store.session.gpa);
    defer w.deinit();
    _ = try w.eq("ParentID", .{ .int = parent_id });
    _ = try w.eq("Name", .{ .text = name });

    var q = zcode.Query.init(store.session.gpa);
    defer q.deinit();
    _ = q.filterWhere(&w);
    _ = q.take(1);

    store.session.resetResults();
    const rows = ref.queryRows(store.session, &q) catch return null;
    if (rows.len == 0) return null;
    return Row{
        .id = columnInt(rows[0], "ID"),
        .display_name = try allocator.dupe(u8, columnText(rows[0], "DisplayName")),
    };
}

fn freeMaybe(allocator: std.mem.Allocator, row: ?Row) void {
    if (row) |r| allocator.free(r.display_name);
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

fn columnIndex(row: anytype, name: []const u8) ?usize {
    for (row.names, 0..) |n, i| {
        if (std.ascii.eqlIgnoreCase(n, name)) return i;
    }
    return null;
}

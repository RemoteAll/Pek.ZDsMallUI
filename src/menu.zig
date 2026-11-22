//! 后台菜单注册（对齐 C# 的 `[DHMenu]` 声明 + 菜单树）。
//!
//! C# 的做法：控制器上标 `[DHMenu(93, ParentMenuName = "Settings", CurrentMenuUrl = "~/{area}/Languages", ...)]`，
//! 框架在启动时把声明汇总进菜单表，`DashBoard` 视图拿 `List<MenuTree>` 渲染顶部导航 + 左侧菜单。
//! Zig 没有反射，所以改成**显式注册**（等价声明）：
//!
//! ```zig
//! try ui.addMenu(.{ .group = "settings", .title_key = "语言包",
//!     .name = "languages", .url = "{area}/languages", .icon = "&#xe71f;", .order = 93 });
//! ```
//!
//! - 库自带一组默认菜单（[`addDefaults`]：控制台 / 设置 / 站点设置 / 语言包 / 多语言）；
//! - 项目启动时 `addMenu` / `addMenuGroup` 追加自己的菜单 → 顶部导航与左侧菜单自动出现；
//! - `url` 里的 `{area}` 会替换成当前后台区域前缀（对齐 C# 的 `~/{area}/...`）。

const std = @import("std");
const zzig = @import("zzig");

const language = @import("language.zig");

const value = zzig.web.value;

/// 一级菜单（顶部导航）。
pub const Group = struct {
    /// 分组键（`console` / `settings` / `product` / `website`）
    key: []const u8,
    /// 显示名语言包键（`menu.settings`）
    title_key: []const u8,
    /// 排序（小的在前）
    order: i32 = 0,
};

/// 二级菜单（左侧菜单项）。
pub const Item = struct {
    /// 所属分组键
    group: []const u8,
    /// 菜单键（视图高亮 / 日志用）
    name: []const u8,
    /// 显示名语言包键
    title_key: []const u8,
    /// 链接（可含 `{area}`）
    url: []const u8,
    /// iconfont 实体（如 `&#xe71f;`）
    icon: []const u8 = "",
    /// 排序（小的在前）
    order: i32 = 0,
    /// 是否可见（`false` = 注册但隐藏，便于灰度）
    visible: bool = true,
};

/// 菜单注册表（线程安全：注册在启动期，读取在请求期）。
pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    groups: std.ArrayListUnmanaged(Group) = .empty,
    items: std.ArrayListUnmanaged(Item) = .empty,
    mutex: zzig.compat.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Registry {
        return .{ .allocator = allocator, .io = io };
    }

    /// 注册项快照（**只在启动期 seed 数据库时用**，不加锁；请求期请走 `build`）。
    pub fn groupList(self: *Registry) []const Group {
        return self.groups.items;
    }

    /// 菜单项快照（同上，仅启动期使用）。
    pub fn itemList(self: *Registry) []const Item {
        return self.items.items;
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.groups.items) |g| self.allocator.free(g.key);
        for (self.groups.items) |g| self.allocator.free(g.title_key);
        for (self.items.items) |i| {
            self.allocator.free(i.group);
            self.allocator.free(i.name);
            self.allocator.free(i.title_key);
            self.allocator.free(i.url);
            self.allocator.free(i.icon);
        }
        self.groups.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    /// 注册一级菜单（同 key 存在则更新排序/标题，不重复添加）。
    pub fn addGroup(self: *Registry, group: Group) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.groups.items) |*existing| {
            if (std.mem.eql(u8, existing.key, group.key)) {
                self.allocator.free(existing.title_key);
                existing.title_key = try self.allocator.dupe(u8, group.title_key);
                existing.order = group.order;
                return;
            }
        }
        try self.groups.append(self.allocator, .{
            .key = try self.allocator.dupe(u8, group.key),
            .title_key = try self.allocator.dupe(u8, group.title_key),
            .order = group.order,
        });
    }

    /// 注册二级菜单（同 `group + name` 存在则更新，等价于 C# 重复扫描时 upsert）。
    pub fn addItem(self: *Registry, item: Item) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.items.items) |*existing| {
            if (std.mem.eql(u8, existing.group, item.group) and std.mem.eql(u8, existing.name, item.name)) {
                self.allocator.free(existing.title_key);
                self.allocator.free(existing.url);
                self.allocator.free(existing.icon);
                existing.title_key = try self.allocator.dupe(u8, item.title_key);
                existing.url = try self.allocator.dupe(u8, item.url);
                existing.icon = try self.allocator.dupe(u8, item.icon);
                existing.order = item.order;
                existing.visible = item.visible;
                return;
            }
        }
        try self.items.append(self.allocator, .{
            .group = try self.allocator.dupe(u8, item.group),
            .name = try self.allocator.dupe(u8, item.name),
            .title_key = try self.allocator.dupe(u8, item.title_key),
            .url = try self.allocator.dupe(u8, item.url),
            .icon = try self.allocator.dupe(u8, item.icon),
            .order = item.order,
            .visible = item.visible,
        });
    }

    /// 库**自己**的默认菜单（只有库提供的页面才放这里）。
    ///
    /// 业务系统的菜单不要写进库：项目启动时用 `ui.addMenu(...)` 注册自己的
    /// —— 等价于 C# 在**业务项目**控制器上标 `[DHMenu(...)]`（框架扫描的是当前项目程序集）。
    pub fn addDefaults(self: *Registry) !void {
        try self.addGroup(.{ .key = "console", .title_key = "控制台", .order = 10 });
        try self.addGroup(.{ .key = "settings", .title_key = "设置", .order = 20 });

        try self.addItem(.{
            .group = "console",
            .name = "welcome",
            .title_key = "欢迎页",
            .url = "{area}/home/dashboard",
            .icon = "&#xe6a7;",
            .order = 10,
        });
        // 站点设置是库自带页面（ConfigController），所以菜单也由库注册
        try self.addItem(.{
            .group = "settings",
            .name = "site_settings",
            .title_key = "站点设置",
            .url = "{area}/config/index",
            .icon = "&#xe614;",
            .order = 20,
        });
        // 角色权限 / 管理员 / 菜单：**通用后台能力**（C# 在 Membership 通用模块里），随库注册
        try self.addItem(.{
            .group = "settings",
            .name = "adminuser",
            .title_key = "管理员管理",
            .url = "{area}/adminuser/index",
            .icon = "&#xe67d;",
            .order = 37,
        });
        try self.addItem(.{
            .group = "settings",
            .name = "role",
            .title_key = "角色权限管理",
            .url = "{area}/role/index",
            .icon = "&#xe67b;",
            .order = 38,
        });
        // 菜单管理：C# 在 Membership 通用模块（`MenuController`），随库注册
        try self.addItem(.{
            .group = "settings",
            .name = "menu",
            .title_key = "菜单管理",
            .url = "{area}/menu/index",
            .icon = "&#xe6a1;",
            .order = 39,
        });
    }

    /// 构建视图模型：`Model.groups`（顶部导航 + 左侧菜单一次渲染）。
    ///
    /// 返回的就是**列表本身**（视图里 `@foreach (var group in Model.groups)`）。
    /// 只输出「有可见菜单项」的分组（空分组点了没内容，体验差；项目注册了菜单项后自动出现）。
    pub fn build(
        self: *Registry,
        arena: std.mem.Allocator,
        area_prefix: []const u8,
        languages: *const language.Store,
        culture_id: i32,
    ) !value.Value {
        self.mutex.lock();
        defer self.mutex.unlock();

        var group_list: std.ArrayList(value.Value) = .empty;
        for (self.groups.items) |group| {
            var item_list: std.ArrayList(value.Value) = .empty;
            for (self.items.items) |item| {
                if (!item.visible) continue;
                if (!std.mem.eql(u8, item.group, group.key)) continue;
                var builder = value.ObjectBuilder.init(arena);
                try builder.str("name", item.name);
                try builder.str("title", languages.text(culture_id, item.title_key));
                try builder.str("url", try expandUrl(arena, item.url, area_prefix));
                try builder.str("icon", item.icon);
                try item_list.append(arena, builder.finish());
            }
            if (item_list.items.len == 0) continue;

            var builder = value.ObjectBuilder.init(arena);
            try builder.str("key", group.key);
            try builder.str("name", languages.text(culture_id, group.title_key));
            try builder.list("items", try item_list.toOwnedSlice(arena));
            try group_list.append(arena, builder.finish());
        }

        return .{ .list = try group_list.toOwnedSlice(arena) };
    }

    /// 菜单键 → 链接（当前区域下的绝对路径），供「你好，xxx」下拉与欢迎页快捷入口使用。
    pub fn urlOf(
        self: *Registry,
        arena: std.mem.Allocator,
        name: []const u8,
        area_prefix: []const u8,
    ) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |item| {
            if (!std.mem.eql(u8, item.name, name)) continue;
            return expandUrl(arena, item.url, area_prefix) catch null;
        }
        return null;
    }
};

/// `{area}` → 区域前缀（`/admin`）；其余原样。
///
/// 公开给 `menu_db.zig`（表驱动渲染）复用：两条渲染路径必须用同一套 `{area}` 口径。
pub fn expandUrl(arena: std.mem.Allocator, url: []const u8, area_prefix: []const u8) ![]const u8 {
    const marker = "{area}";
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var rest = url;
    while (std.mem.indexOf(u8, rest, marker)) |index| {
        try out.writer.writeAll(rest[0..index]);
        try out.writer.writeAll(area_prefix);
        rest = rest[index + marker.len ..];
    }
    try out.writer.writeAll(rest);
    return out.toOwnedSlice();
}

// ————— 测试 —————

const testing = std.testing;

test "菜单：注册 + 排序 + {area} 替换 + 空分组过滤" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.addDefaults();
    try registry.addGroup(.{ .key = "product", .title_key = "产品", .order = 30 });
    try registry.addItem(.{
        .group = "product",
        .name = "goods",
        .title_key = "语言包",
        .url = "{area}/goods",
        .icon = "&#xe600;",
        .order = 5,
    });

    var store = language.Store.init(testing.allocator, testing.io);
    defer store.deinit();
    try store.reload();

    const model = try registry.build(arena, "/biz", &store, store.defaultLanguage().?.id);
    const groups = switch (model) {
        .list => |items| items,
        else => @panic("groups 不是列表"),
    };
    try testing.expectEqual(@as(usize, 3), groups.len); // console / settings / product
    try testing.expectEqualStrings("控制台", groups[0].get("name").?.asString().?);

    const settings_items = switch (groups[1].get("items").?) {
        .list => |items| items,
        else => @panic("items 不是列表"),
    };
    // settings 组现在有「站点设置 + 管理员管理 + 角色权限管理 + 菜单管理」四项
    try testing.expectEqual(@as(usize, 4), settings_items.len);
    try testing.expectEqualStrings("/biz/config/index", settings_items[0].get("url").?.asString().?);

    const product_items = switch (groups[2].get("items").?) {
        .list => |items| items,
        else => @panic("items 不是列表"),
    };
    try testing.expectEqualStrings("/biz/goods", product_items[0].get("url").?.asString().?);
}

test "菜单：重复注册同名项是 upsert，不产生重复" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.addDefaults();
    try registry.addDefaults();

    var store = language.Store.init(testing.allocator, testing.io);
    defer store.deinit();
    try store.reload();

    const model = try registry.build(arena, "/admin", &store, store.defaultLanguage().?.id);
    const groups = switch (model) {
        .list => |items| items,
        else => @panic("groups 不是列表"),
    };
    try testing.expectEqual(@as(usize, 2), groups.len);
    // settings 组：站点设置 + 管理员 + 角色 + 菜单管理（重复 addDefaults 不应叠加）
    try testing.expectEqual(@as(usize, 4), switch (groups[1].get("items").?) {
        .list => |items| items.len,
        else => 0,
    });
}

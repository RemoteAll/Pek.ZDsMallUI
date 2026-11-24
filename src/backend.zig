//! 后台数据接口（站点设置 / 登录），把「持久化」从 UI 层解耦。
//!
//! C# 参考工程里 `ConfigController.UpdateBase` 直接写 `SiteInfo` / `DHSetting` / `SysConfig`
//! （XCode 实体）。UI 库不该把某个具体 ORM 焊死，故定义 [`AdminBackend`]（Zig 的 vtable 写法）
//! 由消费方实现：数据库、配置文件、`Pek.ZCode` 都行；内置 [`MemoryBackend`] 仅用于示例与测试。
//!
//! 口令校验一律走 [`@import("password.zig")`]（与 C# `SaltPasswordProvider` 字节级互通），
//! 不要在这里自写散列。

const std = @import("std");
const zzig = @import("zzig");
const password = @import("password.zig");

const router = zzig.web.router;

/// 登录成功后的用户信息（字段与 C# `IManage` 常用面保持一致）。
///
/// **只是内存结构体，不是表**：账号数据在 C# 的 `User` 表里（`Pek.ZCode/membership/Member.xml`），
/// 名字沿用 `AdminUser` 只为兼容既有调用方（`pek_zdsmallui.AdminUser` 导出）。
pub const AdminUser = struct {
    /// 主键（`User.ID`）
    id: i64,
    /// 登录名（`User.Name`）
    user_name: []const u8,
    /// 显示名（`User.DisplayName`）
    display_name: []const u8,
    /// 是否管理员（`User.RoleID == 1` 或 `User.Ex1 != 0`，与 C# `AdminUserController` 同口径）
    is_admin: bool,
};

/// 保存设置的结果（失败原因直接是面向运维的中文文案）。
pub const SaveOutcome = union(enum) {
    ok,
    err: []const u8,
};

/// 登录结果。
pub const LoginOutcome = union(enum) {
    ok: AdminUser,
    err: []const u8,
};

/// 设置键。
///
/// - `key`：**模板字段名**（camelCase，视图里写 `@Model.siteName`）；
/// - `store_key`：**库里 `Config.Name` 的值**（**PascalCase，严格对齐 C#**：
///   C# 的框架配置表是 `Config(Category,Name,Value,Remark)`，键就是实体属性名）。
///
/// 两者分开是因为「显示名」属于模板约定，而「存储名」必须与 C# 完全一致 ——
/// 这样同一份库在 C# / Zig 两侧读到的是同一批键，不会因为大小写差异互不认识。
pub const SettingsEntry = struct {
    key: []const u8,
    store_key: []const u8,
    default: []const u8,
};

/// 站点设置默认值（顺序即页面/JSON 输出顺序）。
pub const DEFAULT_SETTINGS = [_]SettingsEntry{
    .{ .key = "siteName", .store_key = "SiteName", .default = "" },
    .{ .key = "displayName", .store_key = "DisplayName", .default = "管理后台" },
    .{ .key = "seoTitle", .store_key = "SeoTitle", .default = "" },
    .{ .key = "seoKey", .store_key = "SeoKey", .default = "" },
    .{ .key = "seoDescribe", .store_key = "SeoDescribe", .default = "" },
    .{ .key = "registration", .store_key = "Registration", .default = "" },
    .{ .key = "copyright", .store_key = "Copyright", .default = "" },
    // 站点 Logo（前台头部品牌图标；空 = 前台回退成站点名首字母圆标）
    .{ .key = "logo", .store_key = "Logo", .default = "" },
    .{ .key = "customerTel", .store_key = "CustomerTel", .default = "" },
    .{ .key = "customerEmail", .store_key = "CustomerEmail", .default = "" },
    .{ .key = "urlSuffix", .store_key = "UrlSuffix", .default = ".html" },
    .{ .key = "statistical", .store_key = "Statistical", .default = "" },
    .{ .key = "pageFoot", .store_key = "PageFoot", .default = "" },
    .{ .key = "headerCustomHtml", .store_key = "HeaderCustomHtml", .default = "" },
    .{ .key = "footerCustomHtml", .store_key = "FooterCustomHtml", .default = "" },
    .{ .key = "curDomainUrl", .store_key = "CurDomainUrl", .default = "" },
    // 后台登录 JWT 密钥（`HS256:<长随机串>`）。
    // 语义：**空 = 不改**（首次为空时由业务启动逻辑生成并写入自己的配置文件）。
    .{ .key = "jwtSecret", .store_key = "JwtSecret", .default = "" },
    // 公司名称（C# 视图 `name="companyname"`，实体属性 `Company`）
    .{ .key = "company", .store_key = "Company", .default = "" },
    // 会话超时（秒，0 = 不超时）与刷新用户周期（秒）—— C# `DHSetting.SessionTimeout` / `RefreshUserPeriod`
    .{ .key = "sessionTimeout", .store_key = "SessionTimeout", .default = "0" },
    .{ .key = "refreshUserPeriod", .store_key = "RefreshUserPeriod", .default = "600" },
};

/// 表单键（C# 视图字段名）→ `Config.Name`（**PascalCase，与 C# 库里的键一致**）；
/// 未识别的键返回 `null`（忽略）。大小写不敏感匹配，所以 `companyname` 也能落到 `Company`。
pub fn formKeyToSetting(key: []const u8) ?[]const u8 {
    const pairs = [_][2][]const u8{
        .{ "SiteName", "SiteName" },
        .{ "DisplayName", "DisplayName" },
        .{ "SeoTitle", "SeoTitle" },
        .{ "SeoKey", "SeoKey" },
        .{ "SeoDescribe", "SeoDescribe" },
        .{ "Registration", "Registration" },
        .{ "Copyright", "Copyright" },
        .{ "Logo", "Logo" },
        .{ "CustomerTel", "CustomerTel" },
        .{ "CustomerEmail", "CustomerEmail" },
        .{ "UrlSuffix", "UrlSuffix" },
        .{ "Statistical", "Statistical" },
        .{ "PageFoot", "PageFoot" },
        .{ "HeaderCustomHtml", "HeaderCustomHtml" },
        .{ "FooterCustomHtml", "FooterCustomHtml" },
        .{ "CurDomainUrl", "CurDomainUrl" },
        .{ "JwtSecret", "JwtSecret" },
        .{ "companyname", "Company" },
        // C# 视图的 `id="sessiontimeout"` / `id="refreshuserperiod"`（全小写）
        .{ "sessiontimeout", "SessionTimeout" },
        .{ "refreshuserperiod", "RefreshUserPeriod" },
    };
    for (pairs) |pair| {
        if (std.ascii.eqlIgnoreCase(pair[0], key)) return pair[1];
    }
    return null;
}

/// 按默认键顺序构造设置值（`overrides` 提供已存值；缺失键用默认值补齐）。
pub fn settingsValue(
    arena: std.mem.Allocator,
    overrides: ?*const std.StringHashMapUnmanaged([]const u8),
) !zzig.web.Value {
    var builder = zzig.web.ObjectBuilder.init(arena);
    for (DEFAULT_SETTINGS) |entry| {
        const value = if (overrides) |map| lookupSettingIgnoreCase(map, entry.store_key) orelse entry.default else entry.default;
        try builder.str(entry.key, value);
    }
    return builder.finish();
}

/// 在小写无关语义下查一个具体键，找不到返回 `null`。
///
/// `Config.Name` 在 C# 的 `Model.xml` 里是 `COLLATE NOCASE`，历史库因此可能存着
/// `siteName` 而不是 `SiteName`；读写两侧都只能按大小写无关处理。
fn lookupSettingIgnoreCase(
    map: *const std.StringHashMapUnmanaged([]const u8),
    key: []const u8,
) ?[]const u8 {
    if (map.get(key)) |value| return value;
    var it = map.iterator();
    while (it.next()) |kv| {
        if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, key)) return kv.value_ptr.*;
    }
    return null;
}

/// 把一个键名归一成 `Config.Name` 的规范写法（`DEFAULT_SETTINGS` 的 `store_key`）。
///
/// 不在白名单里的键（如 `__configVersion` 这类元数据）原样返回。
pub fn canonicalStoreKey(key: []const u8) []const u8 {
    for (DEFAULT_SETTINGS) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.store_key, key) or std.ascii.eqlIgnoreCase(entry.key, key)) {
            return entry.store_key;
        }
    }
    return key;
}

/// 后台数据接口（vtable；`ptr` 指向实现方状态）。
pub const AdminBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 读取站点设置（作为配置页的 `@Model`）。**至少**含 [`DEFAULT_SETTINGS`] 的同名键。
        settings: *const fn (ptr: *anyopaque, arena: std.mem.Allocator) anyerror!zzig.web.Value,
        /// 保存站点设置（`form` 为原始表单键值，键名与 C# 视图字段一致）。
        save_settings: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, form: []const router.Param) anyerror!SaveOutcome,
        /// 校验登录（口令必须走 `password.zig`）。
        login: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, user_name: []const u8, pass: []const u8) anyerror!LoginOutcome,
        /// 系统显示名（渲染页面标题用）。
        display_name: *const fn (ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]const u8,
        /// 修改口令（旧口令校验 + 新口令入库，均走 `password.zig`）；未提供 = 不支持改密。
        change_password: ?*const fn (
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            user_name: []const u8,
            old_pass: []const u8,
            new_pass: []const u8,
        ) anyerror!bool = null,
        /// 读取用户的**后台界面语言**（`Language.Id`；0 = 未设置/跟默认语言）。
        /// 未提供实现 = 所有用户都用默认语言。
        language_id: ?*const fn (ptr: *anyopaque, user_name: []const u8) anyerror!i32 = null,
        /// 写入用户的**后台界面语言**（只影响这个用户，不影响前台）。
        set_language_id: ?*const fn (ptr: *anyopaque, user_name: []const u8, language_id: i32) anyerror!void = null,
    };

    /// 读取设置。
    pub fn settings(self: AdminBackend, arena: std.mem.Allocator) !zzig.web.Value {
        return self.vtable.settings(self.ptr, arena);
    }

    /// 保存设置。
    pub fn saveSettings(self: AdminBackend, arena: std.mem.Allocator, form: []const router.Param) !SaveOutcome {
        return self.vtable.save_settings(self.ptr, arena, form);
    }

    /// 登录。
    pub fn login(self: AdminBackend, arena: std.mem.Allocator, user_name: []const u8, pass: []const u8) !LoginOutcome {
        return self.vtable.login(self.ptr, arena, user_name, pass);
    }

    /// 系统显示名（缺设置时回退「管理后台」）。
    pub fn displayName(self: AdminBackend, arena: std.mem.Allocator) ![]const u8 {
        return self.vtable.display_name(self.ptr, arena);
    }

    /// 是否支持修改口令。
    pub fn supportsChangePassword(self: AdminBackend) bool {
        return self.vtable.change_password != null;
    }

    /// 修改口令：旧口令正确且新口令写入成功返回 `true`。
    pub fn changePassword(
        self: AdminBackend,
        arena: std.mem.Allocator,
        user_name: []const u8,
        old_pass: []const u8,
        new_pass: []const u8,
    ) !bool {
        const func = self.vtable.change_password orelse return false;
        return func(self.ptr, arena, user_name, old_pass, new_pass);
    }

    /// 读取用户的后台界面语言（未实现/未设置返回 0）。
    pub fn languageId(self: AdminBackend, user_name: []const u8) i32 {
        const func = self.vtable.language_id orelse return 0;
        return func(self.ptr, user_name) catch 0;
    }

    /// 保存用户的后台界面语言（未实现时静默忽略）。
    pub fn setLanguageId(self: AdminBackend, user_name: []const u8, language_id: i32) void {
        const func = self.vtable.set_language_id orelse return;
        func(self.ptr, user_name, language_id) catch |e| {
            zzig.Logger.warn("[ZDsMallUI] 保存用户 {s} 的语言偏好失败：{s}", .{ user_name, @errorName(e) });
        };
    }
};

/// 内存实现（示例 / 测试专用；重启即丢，生产请实现自己的 [`AdminBackend`]）。
pub const MemoryBackend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: zzig.compat.Mutex = .{},
    settings: std.StringHashMapUnmanaged([]const u8) = .empty,
    users: std.ArrayListUnmanaged(User) = .empty,

    /// 内存用户。
    pub const User = struct {
        id: i64,
        user_name: []const u8,
        display_name: []const u8,
        password: []const u8,
        is_admin: bool,
        /// 后台界面语言（`Language.Id`；0 = 跟默认语言）
        language_id: i32 = 0,
    };

    /// 创建（堆分配；默认账号 `admin` / `admin123`，**生产务必替换**）。
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*MemoryBackend {
        const self = try allocator.create(MemoryBackend);
        self.* = .{ .allocator = allocator, .io = io };
        try self.addUser("admin", "admin123", "管理员", true);
        return self;
    }

    /// 释放（键/值/用户字段全部由本对象拥有）。
    pub fn deinit(self: *MemoryBackend) void {
        var it = self.settings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.settings.deinit(self.allocator);

        for (self.users.items) |user| {
            self.allocator.free(user.user_name);
            self.allocator.free(user.display_name);
            self.allocator.free(user.password);
        }
        self.users.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 取可传给控制器的接口视图。
    pub fn backend(self: *MemoryBackend) AdminBackend {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = AdminBackend.VTable{
        .settings = settingsImpl,
        .save_settings = saveSettingsImpl,
        .login = loginImpl,
        .display_name = displayNameImpl,
        .change_password = changePasswordImpl,
        .language_id = languageIdImpl,
        .set_language_id = setLanguageIdImpl,
    };

    fn languageIdImpl(ptr: *anyopaque, user_name: []const u8) anyerror!i32 {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.users.items) |user| {
            if (std.mem.eql(u8, user.user_name, user_name)) return user.language_id;
        }
        return 0;
    }

    fn setLanguageIdImpl(ptr: *anyopaque, user_name: []const u8, language_id: i32) anyerror!void {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.users.items) |*user| {
            if (std.mem.eql(u8, user.user_name, user_name)) {
                user.language_id = language_id;
                return;
            }
        }
    }

    /// 改密：校验旧口令后写入新口令（复用 [`password`] 的哈希与升级逻辑）。
    fn changePasswordImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        user_name: []const u8,
        old_pass: []const u8,
        new_pass: []const u8,
    ) anyerror!bool {
        _ = arena;
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
        const name = std.mem.trim(u8, user_name, " \t\r\n");
        if (name.len == 0 or old_pass.len == 0 or new_pass.len == 0) return false;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.users.items) |*user| {
            if (!std.ascii.eqlIgnoreCase(user.user_name, name)) continue;
            if (!password.verify(old_pass, user.password)) return false;
            const hashed = try password.hash(self.allocator, self.io, new_pass);
            self.allocator.free(user.password);
            user.password = hashed;
            return true;
        }
        return false;
    }

    fn settingsImpl(ptr: *anyopaque, arena: std.mem.Allocator) anyerror!zzig.web.Value {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        return settingsValue(arena, &self.settings);
    }

    fn saveSettingsImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        form: []const router.Param,
    ) anyerror!SaveOutcome {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));

        // 与 C# 一致：网站名称必填
        var site_name: []const u8 = "";
        for (form) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, "SiteName")) {
                site_name = std.mem.trim(u8, field.value, " \t\r\n");
                break;
            }
        }
        if (site_name.len == 0) return .{ .err = "网站名称不可为空" };

        self.mutex.lock();
        defer self.mutex.unlock();

        for (form) |field| {
            const target = formKeyToSetting(field.name) orelse continue;
            const value = try self.allocator.dupe(u8, field.value);
            if (self.settings.getEntry(target)) |entry| {
                self.allocator.free(entry.value_ptr.*);
                entry.value_ptr.* = value;
            } else {
                const key = try self.allocator.dupe(u8, target);
                errdefer self.allocator.free(key);
                try self.settings.put(self.allocator, key, value);
            }
        }
        _ = arena;
        return .ok;
    }

    fn loginImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        user_name: []const u8,
        pass: []const u8,
    ) anyerror!LoginOutcome {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
        const name = std.mem.trim(u8, user_name, " \t\r\n");
        if (name.len == 0 or pass.len == 0) {
            return .{ .err = "用户名与密码均不可为空" };
        }

        // 不区分「用户不存在」与「密码错误」，避免用户名枚举
        const not_found: LoginOutcome = .{ .err = "用户名或密码不正确" };

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.users.items, 0..) |*user, index| {
            if (!std.ascii.eqlIgnoreCase(user.user_name, name)) continue;

            const result = try password.verifyAndUpgrade(self.allocator, self.io, .{}, pass, user.password);
            if (!result.ok) return not_found;
            if (result.upgraded) |upgraded| {
                self.allocator.free(user.password);
                user.password = upgraded;
            }
            _ = index;
            return .{ .ok = .{
                .id = user.id,
                .user_name = try arena.dupe(u8, user.user_name),
                .display_name = try arena.dupe(u8, user.display_name),
                .is_admin = user.is_admin,
            } };
        }
        return not_found;
    }

    fn displayNameImpl(ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]const u8 {
        const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        const stored = if (self.settings.get("displayName")) |value| try arena.dupe(u8, value) else null;
        self.mutex.unlock();

        if (stored) |value| {
            if (std.mem.trim(u8, value, " \t\r\n").len > 0) return value;
        }
        return "管理后台";
    }

    /// 添加（或覆盖）一个用户；口令按 [`password`] 存库（默认 `md5+sha1`）。
    pub fn addUser(
        self: *MemoryBackend,
        user_name: []const u8,
        pass: []const u8,
        display_name: []const u8,
        is_admin: bool,
    ) !void {
        const stored = try password.hash(self.allocator, self.io, pass);
        errdefer self.allocator.free(stored);

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.users.items) |*user| {
            if (std.ascii.eqlIgnoreCase(user.user_name, user_name)) {
                self.allocator.free(user.password);
                self.allocator.free(user.display_name);
                user.password = stored;
                user.display_name = try self.allocator.dupe(u8, display_name);
                user.is_admin = is_admin;
                return;
            }
        }

        try self.users.append(self.allocator, .{
            .id = @intCast(self.users.items.len + 1),
            .user_name = try self.allocator.dupe(u8, user_name),
            .display_name = try self.allocator.dupe(u8, display_name),
            .password = stored,
            .is_admin = is_admin,
        });
    }

    /// 直接写入某个设置键（示例/测试便捷入口）。
    pub fn setSetting(self: *MemoryBackend, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const copied = try self.allocator.dupe(u8, value);
        if (self.settings.getEntry(key)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = copied;
            return;
        }
        const key_copy = try self.allocator.dupe(u8, key);
        try self.settings.put(self.allocator, key_copy, copied);
    }
};

// ————— 测试 —————

const testing = std.testing;

test "backend：默认设置覆盖模板全部键" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const value = try settingsValue(arena, null);
    for (DEFAULT_SETTINGS) |entry| {
        try testing.expect(value.get(entry.key) != null);
    }
    try testing.expectEqualStrings("管理后台", value.get("displayName").?.asString().?);
    try testing.expectEqualStrings(".html", value.get("urlSuffix").?.asString().?);
}

test "backend：MemoryBackend 保存与读取设置" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mem = try MemoryBackend.init(testing.allocator, testing.io);
    defer mem.deinit();
    const backend = mem.backend();

    const form = [_]router.Param{
        .{ .name = "SiteName", .value = "商城" },
        .{ .name = "SeoTitle", .value = "标题" },
        .{ .name = "Unknown", .value = "忽略" },
    };
    const outcome = try backend.saveSettings(arena, &form);
    try testing.expect(outcome == .ok);

    const settings = try backend.settings(arena);
    try testing.expectEqualStrings("商城", settings.get("siteName").?.asString().?);
    try testing.expectEqualStrings("标题", settings.get("seoTitle").?.asString().?);
    try testing.expect(settings.get("Unknown") == null);
}

test "backend：网站名称必填" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mem = try MemoryBackend.init(testing.allocator, testing.io);
    defer mem.deinit();

    const form = [_]router.Param{.{ .name = "SiteName", .value = "   " }};
    const outcome = try mem.backend().saveSettings(arena, &form);
    try testing.expect(outcome == .err);
    try testing.expect(std.mem.indexOf(u8, outcome.err, "网站名称不可为空") != null);
}

test "backend：默认账号可登录，错误口令/未知用户一律同一文案" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mem = try MemoryBackend.init(testing.allocator, testing.io);
    defer mem.deinit();
    const backend = mem.backend();

    const ok = try backend.login(arena, "admin", "admin123");
    try testing.expect(ok == .ok);
    try testing.expect(ok.ok.is_admin);
    try testing.expectEqualStrings("admin", ok.ok.user_name);

    const bad = try backend.login(arena, "admin", "badpass");
    try testing.expect(bad == .err);
    const missing = try backend.login(arena, "nobody", "admin123");
    try testing.expect(missing == .err);
    try testing.expectEqualStrings(bad.err, missing.err);
}

test "backend：display_name 缺设置时回退" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mem = try MemoryBackend.init(testing.allocator, testing.io);
    defer mem.deinit();
    try testing.expectEqualStrings("管理后台", try mem.backend().displayName(arena));
}

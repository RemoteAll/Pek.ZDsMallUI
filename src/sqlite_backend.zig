//! 数据访问后端：**表结构由 `Pek.ZCode` 的 `syncSchema` 同步，读写一律走 ORM**
//! （`Dal.table()` + `TableRef`，账号用生成实体 `zcode.membership.entities.User`）。
//!
//! # 为什么必须走 ORM（用户要求，2026-11-22）
//! 手写 SQL 会夹带**方言专有语法**（`[User]` 方括号、`datetime('now','localtime')`、
//! `ON CONFLICT`、`INSERT OR IGNORE`、`PRAGMA`…），一旦换 MySQL / PostgreSQL 就得重写一遍。
//! 走 `TableRef` 后 SQL 由 `dialect.zig` 按 `DatabaseKind` 生成，**换库只改连接串**。
//!
//! # 模型来源（三层合并，一次 `syncSchema`）
//! 1. `MEMBER_XML`：C# 同源 `Pek.ZCode/membership/Member.xml`（`User` / `Role` / `Menu` …）；
//! 2. `MODEL_XML`：库自有 `Config` / `Session` / `UserDetail`；
//! 3. `project_xml`：项目自己的 `Model.xml`（业务表 / 多语言表）。
//!
//! 合并后**按 C# XCode 语义补全列属性**（`EntityModel.applyCsharpColumnDefaults`），
//! 保证「Zig 建出的表」与「C# 建出的表」逐列一致 —— 同一份库两边都能用。
//!
//! # 会话
//! 全进程**一条** `Session`（堆分配，地址稳定）：`Dal.openSession()` 每次都新建连接，
//! 早期「每请求 openSession」实测单条 INSERT ~1.1s，所以这里只开一次，用 `mutex` 串行化。

const std = @import("std");
const zzig = @import("zzig");
const zcode = @import("zcode");

const backend_mod = @import("backend.zig");
const password = @import("password.zig");

const router = zzig.web.router;

/// C# 同源 `User` 实体（由 `zcodegen` 从 `Member.xml` 生成，**不要手写**）。
const User = zcode.membership.entities.User;

/// 库内置模型：`Config`（站点配置）/ `Session`（令牌吊销）/ `UserDetail`（用户扩展）。
pub const MODEL_XML = @embedFile("../assets/Model.xml");

/// C# 同源 Membership 模型（9 张表）。**不在本库重复定义**，详见 `Pek.ZCode`。
pub const MEMBER_XML = zcode.membership.MemberXml;

/// 默认模型文件名（C# 同构，项目目录下同名文件优先）。
pub const DEFAULT_MODEL_FILE = "Model.xml";

/// 默认数据库目录（与 C# 侧 `Data/` 同构）。
pub const DEFAULT_DB_DIR = "Data";

/// 模型装配选项。
///
/// 默认 `membership = true`：合并 `Pek.ZCode` 的 C# 同源 `Member.xml`（User/Department/Role/Menu/
/// Parameter/Area/Log/Tenant/TenantUser 九张表）—— 这是「与 C# 共用同一个库、同一批数据」的前提。
///
/// 业务系统想**完全自己定义**成员域（不想要那九张表），可以 `membership = false`：
/// 此时只装配本库的 `Config`/`Session`/`UserDetail` + 项目 `Model.xml` + 项目实体；
/// 但后台框架仍按列名读写 `User`/`Role`/`Menu`，所以**项目必须自己声明这三张表且列名兼容**，
/// 表名不同则再用 `AdminArea.setTables` 指过去。详见 `src/membership_tables.zig`。
pub const ModelOptions = struct {
    /// 是否合并 C# 同源 `Member.xml`（默认 true）
    membership: bool = true,
};

pub const SqliteBackend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dal: zcode.Dal,
    /// 长生命周期会话。**必须堆分配**：`Session` 的语句缓存持有指向自身 `Db` 的句柄，
    /// 按值搬进别处会让那些指针失效（见 `Session.clearStmtCache` 的注释）。
    session: *zcode.Session,
    /// 三层模型合并后的内存（`Dal` 按值持有 `EntityModel`，其内部切片来自本 arena）。
    /// **必须是堆指针**：`ArenaAllocator.allocator()` 的 `ptr` 指向 arena 自身地址，
    /// 按值复制进结构体后那个地址就悬垂了（free 时报 `attempt to use null value`）。
    model_arena: *std.heap.ArenaAllocator,
    mutex: zzig.compat.Mutex = .{},
    /// 成员域三表名（默认 User / Role / Menu，与 C# Member.xml 同源；业务可 setTables 换成自己的表）
    tables: @import("membership_tables.zig").Tables = .{},
    /// 装配时用的选项（`membership = false` 表示没合并 C# 同源 `Member.xml`）
    model_options: ModelOptions = .{},

    /// 按 SQLite 文件路径打开（不存在则创建目录与库文件）。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*SqliteBackend {
        return initWithModel(allocator, io, path, null);
    }

    /// 同上，并额外带上**项目自己的 `Model.xml`**（业务表 / 多语言表）。
    pub fn initWithModel(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        project_xml: ?[]const u8,
    ) !*SqliteBackend {
        return initWithModelEntities(allocator, io, path, project_xml, .{});
    }

    /// 同上，并注入**消费方项目的实体**（`@import("entities/mod.zig").all`）。
    pub fn initWithModelEntities(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        project_xml: ?[]const u8,
        comptime entities: anytype,
    ) !*SqliteBackend {
        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) try zzig.fsio.makePath(io, dir);
        }
        const conn = try std.fmt.allocPrint(allocator, "Data Source={s};Provider=SQLite", .{path});
        defer allocator.free(conn);
        return initWithConnectionEntities(allocator, io, conn, project_xml, entities);
    }

    /// **任意连接串**（`Provider=SQLite|MySQL|PostgreSQL|...`）——这也是「切库」的唯一入口：
    /// 换个连接串即可，代码与模型都不用改。
    pub fn initWithConnection(
        allocator: std.mem.Allocator,
        io: std.Io,
        conn_str: []const u8,
        project_xml: ?[]const u8,
    ) !*SqliteBackend {
        return initWithConnectionEntities(allocator, io, conn_str, project_xml, .{});
    }

    /// 同上，并额外带上**消费方项目的实体**（`@import("entities/mod.zig").all` 这类 tuple）。
    ///
    /// 建表口径是 **`Model.xml` ∪ 实体**：`Model.xml` 可能被人为清理掉表/列，而实体仍被代码引用，
    /// 此时表/列必须继续存在（见 `EntityModel.mergeEntityTypes`）。
    pub fn initWithConnectionEntities(
        allocator: std.mem.Allocator,
        io: std.Io,
        conn_str: []const u8,
        project_xml: ?[]const u8,
        comptime entities: anytype,
    ) !*SqliteBackend {
        return initWithConnectionOptions(allocator, io, conn_str, project_xml, entities, .{});
    }

    /// 同 [`initWithConnectionEntities`]，但可指定 [`ModelOptions`]
    /// （`membership = false` = 业务自备成员域，不合并 C# 同源 `Member.xml`）。
    pub fn initWithConnectionOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        conn_str: []const u8,
        project_xml: ?[]const u8,
        comptime entities: anytype,
        options: ModelOptions,
    ) !*SqliteBackend {
        const model_arena = try allocator.create(std.heap.ArenaAllocator);
        model_arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            model_arena.deinit();
            allocator.destroy(model_arena);
        }
        const model = try mergeModel(model_arena.allocator(), project_xml, entities, options);

        const self = try allocator.create(SqliteBackend);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .dal = undefined, .session = undefined, .model_arena = model_arena, .model_options = options };

        self.dal = zcode.Dal.initWithModel(allocator, conn_str, model) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 打开数据库失败（{s}）：连接串 {s}", .{ @errorName(e), conn_str });
            return e;
        };
        errdefer self.dal.deinit();

        const s = self.dal.openSession() catch |e| {
            zzig.Logger.err("[ZDsMallUI] 建立数据库会话失败（{s}）：连接串 {s}", .{ @errorName(e), conn_str });
            return e;
        };
        const sp = try allocator.create(zcode.Session);
        sp.* = s; // 刚 open，语句缓存为空 —— 此刻搬动是安全的
        self.session = sp;
        errdefer {
            sp.deinit();
            allocator.destroy(sp);
        }

        const report = self.dal.syncSchema(self.session) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 同步表结构失败（{s}）：连接串 {s}", .{ @errorName(e), conn_str });
            return e;
        };
        if (report.tables_created > 0 or report.columns_added > 0 or report.indexes_created > 0) {
            zzig.Logger.info(
                "[ZDsMallUI] 表结构已同步（Membership+框架+项目）：新建表 {d} / 补列 {d} / 建索引 {d}",
                .{ report.tables_created, report.columns_added, report.indexes_created },
            );
        }
        zzig.Logger.info("[ZDsMallUI] 数据库就绪：{s} / {d} 张表", .{ @tagName(self.dal.opts.provider), self.dal.model.tables.len });

        try self.seedDefaultUser();
        // 角色 seed 失败**不能让整个后端起不来**（用户数据比内置角色重要）：
        // 记一条 warn，后台角色页会显示为空，手动新增即可。
        self.seedDefaultRoles() catch |err| {
            zzig.Logger.warn("[ZDsMallUI] 初始化内置角色失败（{s}）：角色列表可能为空，可在后台手动新增", .{@errorName(err)});
        };
        try self.ensureAllUserDetails();
        return self;
    }

    pub fn deinit(self: *SqliteBackend) void {
        self.session.deinit();
        self.allocator.destroy(self.session);
        self.dal.deinit();
        self.model_arena.deinit();
        self.allocator.destroy(self.model_arena);
        self.allocator.destroy(self);
    }

    pub fn backend(self: *SqliteBackend) backend_mod.AdminBackend {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// 底层 `Dal`（供**项目自己的业务表**使用：模型来自项目 `Model.xml` / 注入的实体）。
    ///
    /// 只给 `Dal`、不暴露库内部的 session：那是一个长生命周期会话，与业务会话混用会互相
    /// `resetResults()` 把对方的行集冲掉。调用方用 `dal.openSession()` 自己开一个（并自己负责 deinit）。
    pub fn dbDal(self: *SqliteBackend) *zcode.Dal {
        return &self.dal;
    }

    /// 全进程复用的一条 `Session`（堆分配、地址稳定）。
    ///
    /// 后台的自定义页面（角色 / 管理员 / 菜单）要直接用 ORM 读写，**必须复用这条连接**：
    /// `Dal.openSession()` 每次新建连接（实测单条 INSERT ~1.1s），不能每请求开一个。
    /// 并发由后台的 `mutex` 串行化（与库内部一致）。
    pub fn dbSession(self: *SqliteBackend) *zcode.Session {
        return self.session;
    }

    // ───────────────────────── 公共小工具 ─────────────────────────

    /// 读一条 `Config`（不存在返回 `null`）。给库内部用（JWT 密钥、配置快照等）。
    pub fn setting(self: *SqliteBackend, arena: std.mem.Allocator, key: []const u8) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.getSettingLocked(arena, key);
    }

    /// 与 [`setting`] 的区别：**键存在但值为空**时返回 `""`（而不是 `null`）。
    ///
    /// 为什么需要：调用方得区分两件事——
    /// - `null` = 库里没有这个键 → **不要**去覆盖配置文件里的旧值；
    /// - `""`   = 键存在、值就是空 → **要**把配置文件里那一项清空。
    /// 只用一个 `setting` 的话，「后台把域名清空」永远同步不到文件。
    pub fn settingRaw(self: *SqliteBackend, arena: std.mem.Allocator, key: []const u8) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.getSettingLockedKeepEmpty(arena, key);
    }

    /// `setting` 的底层：空值视为「没有」。
    fn getSettingLocked(self: *SqliteBackend, arena: std.mem.Allocator, key: []const u8) !?[]const u8 {
        const value = try self.getSettingLockedKeepEmpty(arena, key) orelse return null;
        if (value.len == 0) return null;
        return value;
    }

    /// 只区分「有没有这个键」，不把空值当无。
    fn getSettingLockedKeepEmpty(self: *SqliteBackend, arena: std.mem.Allocator, key: []const u8) !?[]const u8 {
        self.session.resetResults();

        // 键名统一成 `Config.Name` 的规范写法（`siteName` / `SiteName` 同一条记录）
        const norm_key = backend_mod.canonicalStoreKey(key);
        const ref = try self.dal.table("Config");
        var w = zcode.Where.init(self.allocator);
        defer w.deinit();
        _ = try w.eq("Name", .{ .text = norm_key });
        var q = zcode.Query.init(self.allocator);
        defer q.deinit();
        _ = try q.column("Value");
        _ = q.filterWhere(&w);

        const rows = try ref.queryRows(self.session, &q);
        if (rows.len == 0 or rows[0].values.len == 0) return null;
        const value = switch (rows[0].values[0]) {
            .text => |t| t,
            else => return null,
        };
        return try arena.dupe(u8, value);
    }

    /// 写一条 `Config`（有则更新、无则插入）。
    pub fn putSetting(self: *SqliteBackend, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.putSettingLocked(key, value);
    }

    fn putSettingLocked(self: *SqliteBackend, key: []const u8, value: []const u8) !void {
        // 见 `getSettingLocked`：写也走规范键名，不再产生 camelCase 新行
        const norm_key = backend_mod.canonicalStoreKey(key);
        const ref = try self.dal.table("Config");
        var w = zcode.Where.init(self.allocator);
        defer w.deinit();
        _ = try w.eq("Name", .{ .text = norm_key });

        if (try ref.count(self.session, &w) > 0) {
            _ = try ref.updateOne(self.session, &.{zcode.dbtable.field("Value", .{ .text = value })}, &w, 0);
        } else {
            _ = try ref.insert(self.session, &.{
                zcode.dbtable.field("Name", .{ .text = norm_key }),
                zcode.dbtable.field("Value", .{ .text = value }),
            });
        }
    }

    // ───────────────────────── 种子与迁移 ─────────────────────────

    /// 角色表为空时补三个内置角色（与 C# XCode Membership 默认一致：`RoleID = 1` 是超级管理员）。
    ///
    /// 为什么要 seed：`seedDefaultUser` 把默认账号放在 `RoleID = 1`，角色页若为空会显示「还有没角色」
    /// 却又有用户指向它；C# 侧这三条是框架初始化就有的。
    fn seedDefaultRoles(self: *SqliteBackend) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ref = try self.dal.table(self.tables.role);
        // 表里有角色就不再 seed（新库首次启动才建默认角色；不做老库兼容）
        if (try ref.count(self.session, null) > 0) return;

        const rows = [_]struct { name: []const u8, role_type: i32, sort: i32, permission: []const u8 }{
            // 超级管理员：`Permission = "*"` = 全权限（含菜单管理 / 角色管理本身），不可删不可改名
            .{ .name = "超级管理员", .role_type = 1, .sort = 1, .permission = "*" },
            .{ .name = "管理员", .role_type = 1, .sort = 2, .permission = "" },
            .{ .name = "普通用户", .role_type = 2, .sort = 3, .permission = "" },
        };
        for (rows) |row| {
            const now = zcode.DateTime.nowLocal();
            _ = try ref.insert(self.session, &.{
                zcode.dbtable.field("Name", .{ .text = row.name }),
                zcode.dbtable.field("Type", .{ .int = row.role_type }),
                zcode.dbtable.field("Enable", .{ .int = 1 }),
                // 内置角色：允许改排序/启用/权限，但不允许改名与删除（C# `Role.IsSystem` 语义）
                zcode.dbtable.field("IsSystem", .{ .int = 1 }),
                zcode.dbtable.field("Sort", .{ .int = row.sort }),
                zcode.dbtable.field("Permission", .{ .text = row.permission }),
                // `CreateTime` / `UpdateTime` 在表上是 **NOT NULL 且无默认**（C# 由拦截器填），
                // 走 `TableRef.insert` 不会自动带审计列 —— 必须显式传（否则 NOT NULL constraint failed）。
                zcode.dbtable.field("CreateTime", .{ .datetime = now }),
                zcode.dbtable.field("UpdateTime", .{ .datetime = now }),
            });
        }
        zzig.Logger.info("[ZDsMallUI] 已初始化 {d} 个内置角色（超级管理员 / 管理员 / 普通用户）", .{rows.len});
    }

    /// 超级管理员角色的 ID（按名字查；查不到回退 1）。默认账号的 `User.RoleID` 用它。
    fn superAdminRoleId(self: *SqliteBackend) !i32 {
        const ref = self.dal.table(self.tables.role) catch return 1;
        var w = zcode.Where.init(self.session.gpa);
        defer w.deinit();
        _ = w.eq("Name", .{ .text = "超级管理员" }) catch return 1;
        var q = zcode.Query.init(self.session.gpa);
        defer q.deinit();
        _ = q.filterWhere(&w);
        _ = q.take(1);
        self.session.resetResults();
        const rows = ref.queryRows(self.session, &q) catch return 1;
        if (rows.len == 0) return 1;
        const idx = blk: {
            for (rows[0].names, 0..) |n, i| {
                if (std.ascii.eqlIgnoreCase(n, "ID")) break :blk i;
            }
            return 1;
        };
        return switch (rows[0].values[idx]) {
            .int => |v| @intCast(v),
            else => 1,
        };
    }

    fn seedDefaultUser(self: *SqliteBackend) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = try zcode.entity.count(&self.dal, User, self.session, null);
        if (count > 0) return;

        const hashed = password.hash(self.allocator, self.io, "admin123") catch |e| {
            zzig.Logger.err("[ZDsMallUI] 生成默认口令散列失败（{s}）", .{@errorName(e)});
            return e;
        };
        defer self.allocator.free(hashed);

        // 写 **C# 的 `User` 表**（字段与 C# `DHStartup` 初始化管理员一致）：
        // `RoleID` = 超级管理员角色 + `Ex1=1` 后台管理员标记（C# `AdminUserController.CreateAdmin` 同口径）。
        // ★ 角色 ID 必须**查出来**：自增值不保证从 1 开始（测试库重建过就是 5/6/7），硬编码 1 会让用户指向不存在的角色。
        var user = User{
            .Name = "admin",
            .Password = hashed,
            .DisplayName = "管理员",
            .Sex = 0,
            .RoleID = try self.superAdminRoleId(),
            .Enable = true,
            .Ex1 = 1,
            .Logins = 0,
            .UpdateUser = "",
        };
        const id = try zcode.entity.insert(&self.dal, &user, self.session);
        try self.ensureUserDetailLocked(id);
        zzig.Logger.warn("[ZDsMallUI] 已创建默认账号 admin / admin123（**生产环境请立即修改**）", .{});
    }

    /// 保证 `UserDetail` 有对应行（C# 的 1:1 扩展表；后台界面语言存在 `LanguageId`）。
    fn ensureUserDetailLocked(self: *SqliteBackend, user_id: i64) !void {
        const ref = try self.dal.table("UserDetail");
        var w = zcode.Where.init(self.allocator);
        defer w.deinit();
        _ = try w.eq("Id", .{ .int = user_id });
        if (try ref.count(self.session, &w) > 0) return;
        _ = try ref.insert(self.session, &.{
            zcode.dbtable.field("Id", .{ .int = user_id }),
            zcode.dbtable.field("LanguageId", .{ .int = 0 }),
        });
    }

    fn ensureAllUserDetails(self: *SqliteBackend) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var w = zcode.Where.init(self.allocator);
        defer w.deinit();
        var q = zcode.Query.init(self.allocator);
        defer q.deinit();
        _ = try q.column("ID");
        _ = q.filterWhere(&w);

        const ref = try self.dal.table(self.tables.user);
        const rows = try ref.queryRows(self.session, &q);
        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(self.allocator);
        for (rows) |row| {
            if (row.values.len == 0) continue;
            if (row.values[0].asI64()) |id| try ids.append(self.allocator, id);
        }
        for (ids.items) |id| try self.ensureUserDetailLocked(id);
    }

    // ───────────────────────── AdminBackend 实现 ─────────────────────────

    const vtable = backend_mod.AdminBackend.VTable{
        .settings = settingsImpl,
        .save_settings = saveSettingsImpl,
        .login = loginImpl,
        .display_name = displayNameImpl,
        .change_password = changePasswordImpl,
        .language_id = languageIdImpl,
        .set_language_id = setLanguageIdImpl,
    };

    /// 全部配置（`Config` 表 → 页面对象，缺的用默认值补）。
    ///
    /// 读全表只查 `Name`/`Value` 两列 —— 走 `TableRef`（方言无关），不手写 SQL。
    fn settingsImpl(ptr: *anyopaque, arena: std.mem.Allocator) anyerror!zzig.web.Value {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.session.resetResults();

        var stored = std.StringHashMapUnmanaged([]const u8).empty;
        defer {
            var it = stored.iterator();
            while (it.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
                self.allocator.free(kv.value_ptr.*);
            }
            stored.deinit(self.allocator);
        }

        const ref = try self.dal.table("Config");
        var w = zcode.Where.init(self.allocator);
        defer w.deinit();
        var q = zcode.Query.init(self.allocator);
        defer q.deinit();
        _ = try q.column("Name");
        _ = try q.column("Value");
        _ = q.filterWhere(&w);

        for (try ref.queryRows(self.session, &q)) |row| {
            if (row.values.len < 2) continue;
            const name = switch (row.values[0]) {
                .text => |t| t,
                else => continue,
            };
            const value = switch (row.values[1]) {
                .text => |t| t,
                else => "",
            };
            if (name.len == 0) continue;
            const owned_key = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_key);
            const owned_val = try self.allocator.dupe(u8, value);
            try stored.put(self.allocator, owned_key, owned_val);
        }

        return backend_mod.settingsValue(arena, &stored);
    }

    /// 保存配置（表单参数）：与 C# 一致的口径 —— 网站名称必填、值没变不算脏、
    /// 只有真的改了才递增 `__configVersion` 并刷新 `__configUpdatedAt`。
    fn saveSettingsImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        form: []const router.Param,
    ) anyerror!backend_mod.SaveOutcome {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));
        _ = arena;

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

        var dirty = false;
        var tmp_state = std.heap.ArenaAllocator.init(self.allocator);
        defer tmp_state.deinit();

        for (form) |field| {
            const target = backend_mod.formKeyToSetting(field.name) orelse continue;
            if (!dirty) {
                const existing = try self.getSettingLocked(tmp_state.allocator(), target);
                if (existing == null or !std.mem.eql(u8, existing.?, field.value)) dirty = true;
            }
            try self.putSettingLocked(target, field.value);
        }
        if (!dirty) return .ok;

        // 版本戳：外部（「配置 ↔ 数据库」同步、缓存失效）据此判断「库里的设置变新了」。
        // 元数据、不是业务字段，不在 `formKeyToSetting` 白名单里。
        const prev_text = try self.getSettingLocked(tmp_state.allocator(), "__configVersion");
        const prev_version = if (prev_text) |t| (std.fmt.parseInt(i64, t, 10) catch 0) else 0;
        var buf: [64]u8 = undefined;
        try self.putSettingLocked("__configVersion", try std.fmt.bufPrint(&buf, "{d}", .{prev_version + 1}));
        try self.putSettingLocked("__configUpdatedAt", try std.fmt.bufPrint(&buf, "{d}", .{zzig.compat.milliTimestamp()}));
        return .ok;
    }

    /// 成功后按 C# `LoginCore` 口径更新 `Logins` / `Online`。
    fn loginImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        user_name: []const u8,
        pass: []const u8,
    ) anyerror!backend_mod.LoginOutcome {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));
        const name = std.mem.trim(u8, user_name, " \t\r\n");
        if (name.len == 0 or pass.len == 0) return .{ .err = "用户名与密码均不可为空" };

        // 不区分「用户不存在」与「密码错误」，避免用户名枚举
        const not_found: backend_mod.LoginOutcome = .{ .err = "用户名或密码不正确" };

        self.mutex.lock();
        defer self.mutex.unlock();
        self.session.resetResults();

        var w = zcode.Where.init(self.allocator);
        defer w.deinit();
        _ = try w.eq("Name", .{ .text = name });
        var q = zcode.Query.init(self.allocator);
        defer q.deinit();
        _ = q.filterWhere(&w);

        const users = try zcode.entity.queryRows(&self.dal, User, self.session, &q);
        if (users.len == 0) return not_found;
        const user = users[0];

        if (!user.Enable) return .{ .err = "账号已被停用" };
        const result = try password.verifyAndUpgrade(self.allocator, self.io, .{}, pass, user.Password);
        if (!result.ok) return not_found;

        // 旧算法自动升级（一次性回写）—— C# `LoginCore` 同口径
        //
        // **必须走 `updateOne` 显式列**：生成的实体 `dirty` 位图只由 setter 置位，
        // 直接赋值字段不算脏列，`entity.update` 会「无脏列 → 不发 SQL」（踩过：改密「成功」却登不上）。
        const ref = try self.dal.table(self.tables.user);
        var wu = zcode.Where.init(self.allocator);
        defer wu.deinit();
        _ = try wu.eq("ID", .{ .int = user.ID });
        var sets: [3]zcode.sqlbuild.Field = undefined;
        var n: usize = 0;
        // ★ `defer free` 必须挂在**函数作用域**：原先写在 `if (result.upgraded)` 块里，
        //   块一结束就释放了，后面 `updateOne` 拿的是已释放内存 → 库里落进 55 个 0x55（'U'），
        //   表现为「登录成功一次后，该账号口令永久损坏」（2026-11-23 实测踩到，`User.Password='UUU…'`）。
        const upgraded_opt = result.upgraded;
        defer if (upgraded_opt) |upgraded| self.allocator.free(upgraded);
        if (upgraded_opt) |upgraded| {
            sets[n] = zcode.dbtable.field("Password", .{ .text = upgraded });
            n += 1;
        }
        sets[n] = zcode.dbtable.field("Logins", .{ .int = user.Logins + 1 });
        n += 1;
        sets[n] = zcode.dbtable.field("Online", .{ .int = 1 });
        n += 1;
        _ = ref.updateOne(self.session, sets[0..n], &wu, user.ID) catch |e| {
            zzig.Logger.warn("[ZDsMallUI] 更新用户 {s} 的登录信息失败（{s}）", .{ user.Name, @errorName(e) });
        };

        return .{
            .ok = .{
                .id = user.ID,
                .user_name = try arena.dupe(u8, user.Name),
                .display_name = try arena.dupe(u8, user.DisplayName),
                // 「超级管理员」= **所属角色的权限串是通配 `*`**（不是 `Ex1`！`Ex1=1` 只表示「能进后台」）。
                // 这样任意角色都能被授予权限（含菜单管理/角色管理本身），只有超级管理员绕过菜单校验。
                .is_admin = self.roleIsSuper(user.RoleID),
            },
        };
    }

    /// 角色是否是超级管理员（`Role.Permission` 含 `*`）；查不到按「否」处理。
    fn roleIsSuper(self: *SqliteBackend, role_id: i32) bool {
        if (role_id == 0) return false;
        const ref = self.dal.table(self.tables.role) catch return false;
        var w = zcode.Where.init(self.session.gpa);
        defer w.deinit();
        _ = w.eq("ID", .{ .int = role_id }) catch return false;
        var q = zcode.Query.init(self.session.gpa);
        defer q.deinit();
        _ = q.filterWhere(&w);
        _ = q.take(1);
        self.session.resetResults();
        const rows = ref.queryRows(self.session, &q) catch return false;
        if (rows.len == 0) return false;
        for (rows[0].names, 0..) |n, i| {
            if (!std.ascii.eqlIgnoreCase(n, "Permission")) continue;
            const permission = switch (rows[0].values[i]) {
                .text => |t| t,
                else => return false,
            };
            var it = std.mem.splitScalar(u8, permission, ',');
            while (it.next()) |raw| {
                if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "*")) return true;
            }
            return false;
        }
        return false;
    }

    fn displayNameImpl(ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]const u8 {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));
        if (try self.setting(arena, "DisplayName")) |value| {
            const text = std.mem.trim(u8, value, " \t\r\n");
            if (text.len > 0) return text;
        }
        return "管理后台";
    }

    /// 改密：校验旧口令 → 新散列 → `UPDATE User`（只写 `Password` 一列）。
    fn changePasswordImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        user_name: []const u8,
        old_pass: []const u8,
        new_pass: []const u8,
    ) anyerror!bool {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));
        const name = std.mem.trim(u8, user_name, " \t\r\n");
        if (name.len == 0 or old_pass.len == 0 or new_pass.len == 0) return false;
        _ = arena;

        self.mutex.lock();
        defer self.mutex.unlock();
        self.session.resetResults();

        var w = zcode.Where.init(self.allocator);
        defer w.deinit();
        _ = try w.eq("Name", .{ .text = name });
        var q = zcode.Query.init(self.allocator);
        defer q.deinit();
        _ = q.filterWhere(&w);

        const users = try zcode.entity.queryRows(&self.dal, User, self.session, &q);
        if (users.len == 0) return false;
        if (!password.verify(old_pass, users[0].Password)) return false;

        const hashed = try password.hash(self.allocator, self.io, new_pass);
        defer self.allocator.free(hashed);

        // 显式列更新（不依赖实体脏位图：直接赋字段不会置脏，会变成「不发 SQL」）
        const ref = try self.dal.table(self.tables.user);
        var wu = zcode.Where.init(self.allocator);
        defer wu.deinit();
        _ = try wu.eq("ID", .{ .int = users[0].ID });
        const affected = try ref.updateOne(self.session, &.{zcode.dbtable.field("Password", .{ .text = hashed })}, &wu, users[0].ID);
        if (affected == 0) {
            zzig.Logger.warn("[ZDsMallUI] 改密影响 0 行（用户 {s}）：口令未落库", .{users[0].Name});
            return false;
        }
        return true;
    }

    /// 读用户的后台界面语言（C# `UserDetail.LanguageId`；没有行/记录返回 0 = 跟默认语言）。
    fn languageIdImpl(ptr: *anyopaque, user_name: []const u8) anyerror!i32 {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.session.resetResults();

        const user_id = (try self.findUserIdLocked(user_name)) orelse return 0;

        const ref = try self.dal.table("UserDetail");
        var w = zcode.Where.init(self.allocator);
        defer w.deinit();
        _ = try w.eq("Id", .{ .int = user_id });
        var q = zcode.Query.init(self.allocator);
        defer q.deinit();
        _ = try q.column("LanguageId");
        _ = q.filterWhere(&w);

        const rows = try ref.queryRows(self.session, &q);
        if (rows.len == 0 or rows[0].values.len == 0) return 0;
        return @intCast(rows[0].values[0].asI64() orelse 0);
    }

    /// 写用户的后台界面语言（`UserDetail.LanguageId`；只影响这个用户）。
    fn setLanguageIdImpl(ptr: *anyopaque, user_name: []const u8, language_id: i32) anyerror!void {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.session.resetResults();

        const user_id = (try self.findUserIdLocked(user_name)) orelse {
            zzig.Logger.warn("[ZDsMallUI] 写界面语言失败：用户 {s} 不存在", .{user_name});
            return;
        };
        try self.ensureUserDetailLocked(user_id);

        const ref = try self.dal.table("UserDetail");
        var w = zcode.Where.init(self.allocator);
        defer w.deinit();
        _ = try w.eq("Id", .{ .int = user_id });
        _ = try ref.updateOne(self.session, &.{zcode.dbtable.field("LanguageId", .{ .int = language_id })}, &w, user_id);
    }

    /// 按登录名取 `User.ID`（不存在返回 null）。
    fn findUserIdLocked(self: *SqliteBackend, user_name: []const u8) !?i64 {
        var w = zcode.Where.init(self.allocator);
        defer w.deinit();
        _ = try w.eq("Name", .{ .text = user_name });
        var q = zcode.Query.init(self.allocator);
        defer q.deinit();
        _ = try q.column("ID");
        _ = q.filterWhere(&w);

        const ref = try self.dal.table(self.tables.user);
        const rows = try ref.queryRows(self.session, &q);
        if (rows.len == 0 or rows[0].values.len == 0) return null;
        return rows[0].values[0].asI64();
    }
};

/// 合并三层模型并按 C# 语义补全列属性（详见文件头注释）。
fn mergeModel(
    allocator: std.mem.Allocator,
    project_xml: ?[]const u8,
    comptime entities: anytype,
    options: ModelOptions,
) !zcode.EntityModel {
    // `membership = false`：不碰 `Member.xml`，只从本库的 Model.xml 起头（表全部由库 + 项目自备）
    var model = if (options.membership)
        zcode.EntityModel.parse(allocator, MEMBER_XML) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 解析 C# 同源 Member.xml 失败（{s}）：Pek.ZCode 内置模型损坏", .{@errorName(e)});
            return e;
        }
    else
        zcode.EntityModel.parse(allocator, MODEL_XML) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 解析库内置 Model.xml 失败（{s}）", .{@errorName(e)});
            return e;
        };
    if (options.membership) try appendTables(allocator, &model, MODEL_XML, "库内置 Model.xml");
    if (project_xml) |xml| try appendTables(allocator, &model, xml, "项目 Model.xml");

    // **单库部署**：表级 `ConnName` 归零，等价 C# `ConnectionStrings` 的 `X: MapTo=DH`。
    // 不改 `Member.xml` 本身（它是 C# 同源文件）。
    for (model.tables) |*table| table.conn_name = null;

    // ★ 实体保底：建表 = `Model.xml` ∪ 实体。
    //   XML 被清理掉表/列时，只要实体还在被代码引用，表/列就继续建出来。
    try mergeEntityTypesInto(&model, entities, options.membership);

    // 按 C# XCode 语义补全：string/datetime 可空、值类型 NOT NULL + 默认 0
    model.applyCsharpColumnDefaults();
    return model;
}

/// 把内置实体（C# 同源 Membership + 库自身）与消费方项目实体并入模型，并汇总日志。
fn mergeEntityTypesInto(model: *zcode.EntityModel, comptime entities: anytype, with_membership: bool) !void {
    var members_tables: usize = 0;
    var members_columns: usize = 0;
    if (with_membership) {
        const members = model.mergeEntityTypes(zcode.membership.entities.all) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 并入 C# 同源 Membership 实体失败（{s}）：模型不完整，建表可能缺表", .{@errorName(e)});
            return e;
        };
        members_tables = members.tables_added;
        members_columns = members.columns_added;
    }
    const lib = model.mergeEntityTypes(@import("entities/mod.zig").all) catch |e| {
        zzig.Logger.err("[ZDsMallUI] 并入库内置实体（Config/Session/UserDetail）失败（{s}）", .{@errorName(e)});
        return e;
    };
    const proj = model.mergeEntityTypes(entities) catch |e| {
        zzig.Logger.err("[ZDsMallUI] 并入项目实体失败（{s}）：请检查 `builder.entities(...)` 的类型列表", .{@errorName(e)});
        return e;
    };

    const tables_added = members_tables + lib.tables_added + proj.tables_added;
    const columns_added = members_columns + lib.columns_added + proj.columns_added;
    if (tables_added > 0 or columns_added > 0) {
        zzig.Logger.info(
            "[ZDsMallUI] 实体保底：Model.xml 里缺失但实体仍在用 → 补表 {d} / 补列 {d}",
            .{ tables_added, columns_added },
        );
    }
}

fn appendTables(
    allocator: std.mem.Allocator,
    base: *zcode.EntityModel,
    xml: []const u8,
    what: []const u8,
) !void {
    const extra = zcode.EntityModel.parse(allocator, xml) catch |e| {
        zzig.Logger.err("[ZDsMallUI] 解析 {s} 失败（{s}）：请检查 <EntityModel>/<Tables>/<Table> 结构", .{ what, @errorName(e) });
        return e;
    };
    const merged = try allocator.alloc(zcode.TableMeta, base.tables.len + extra.tables.len);
    @memcpy(merged[0..base.tables.len], base.tables);
    @memcpy(merged[base.tables.len..], extra.tables);
    base.tables = merged;
}

const testing = std.testing;

test "后端：ORM 建表 + 设置读写 + 登录 + 重开数据仍在" {
    const dir = ".zig-cache/zdsmallui-test-db";
    std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    try zzig.fsio.makePath(testing.io, dir);

    const path = dir ++ "/Test.db";
    var be_opt: ?*SqliteBackend = SqliteBackend.init(testing.allocator, testing.io, path) catch |e| {
        std.debug.print("[SKIP] 本机没有可用 SQLite 驱动：{s}\n", .{@errorName(e)});
        return;
    };
    defer if (be_opt) |b| b.deinit();
    const be = be_opt.?;

    // 默认账号可登录（种子走实体 insert，读走 TableRef）
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const outcome = try be.backend().login(arena, "admin", "admin123");
        try testing.expect(outcome == .ok);
        try testing.expectEqualStrings("admin", outcome.ok.user_name);
    }

    // 错误口令被拒
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const outcome = try be.backend().login(arena, "admin", "wrong-password");
        try testing.expect(outcome == .err);
    }

    // 设置读写（有则更新、无则插入）
    try be.putSetting("SiteName", "ORM 测试站");
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        try testing.expectEqualStrings("ORM 测试站", (try be.setting(arena, "SiteName")).?);
    }
    try be.putSetting("SiteName", "ORM 测试站-改");
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        try testing.expectEqualStrings("ORM 测试站-改", (try be.setting(arena, "SiteName")).?);
    }

    // 控制器链路：`backend().saveSettings(form)` 必须真的落库（踩过：回归里 POST updatebase 返回 200 但回读不到）
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const form = [_]router.Param{
            .{ .name = "SiteName", .value = "保存链路站" },
            .{ .name = "SeoTitle", .value = "保存链路标题" },
        };
        const outcome = try be.backend().saveSettings(arena, &form);
        try testing.expect(outcome == .ok);
        try testing.expectEqualStrings("保存链路站", (try be.setting(arena, "SiteName")).?);
        try testing.expectEqualStrings("保存链路标题", (try be.setting(arena, "SeoTitle")).?);
        // 版本戳递增（外部据此判断「库里的设置变新了」）
        try testing.expect((try be.setting(arena, "__configVersion")) != null);
    }

    // 语言偏好落在 C# 的 UserDetail.LanguageId
    be.backend().setLanguageId("admin", 2);
    try testing.expectEqual(@as(i32, 2), be.backend().languageId("admin"));

    // 改密：**必须真的能登进来**（踩过：直接赋字段不置脏位 → entity.update 不发 SQL → 「成功」却登不上）
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        try testing.expect(try be.backend().changePassword(arena, "admin", "admin123", "newpass123"));
    }
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        try testing.expect((try be.backend().login(arena, "admin", "newpass123")) == .ok);
        try testing.expect((try be.backend().login(arena, "admin", "admin123")) == .err);
    }

    be.deinit();
    be_opt = null;

    // 重开：数据仍在（同一份库）
    const be2 = try SqliteBackend.init(testing.allocator, testing.io, path);
    defer be2.deinit();
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // 断言「最后一次写入的值」：上面的 `saveSettings` 用例把 `SiteName` 改成了「保存链路站」
        try testing.expectEqualStrings("保存链路站", (try be2.setting(arena, "SiteName")).?);
        // 键名大小写无关：用小写 `siteName` 也要读得到同一条记录（`Config.Name` 是 COLLATE NOCASE）
        try testing.expectEqualStrings("保存链路站", (try be2.setting(arena, "siteName")).?);
        try testing.expectEqual(@as(i32, 2), be2.backend().languageId("admin"));
    }
}

test "后端：membership=false 时只建库自身与项目的表，不建 C# 同源九张表" {
    const dir = ".zig-cache/zdsmallui-test-nomember";
    std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    try zzig.fsio.makePath(testing.io, dir);

    const path = dir ++ "/NoMember.db";
    const be_opt: ?*SqliteBackend = SqliteBackend.initWithConnectionOptions(
        testing.allocator,
        testing.io,
        "Data Source=" ++ path ++ ";Provider=SQLite",
        null,
        .{},
        .{ .membership = false },
    ) catch |e| {
        std.debug.print("[SKIP] 本机没有可用 SQLite 驱动：{s}\n", .{@errorName(e)});
        return;
    };
    defer if (be_opt) |b| b.deinit();
    const be = be_opt.?;

    // 库自身的表在
    _ = try be.dal.table("Config");
    _ = try be.dal.table("Session");
    // C# 同源 Membership 的表不在（Tenant / Department 属于 Member.xml）
    try testing.expectError(error.TableNotFound, be.dal.table("Tenant"));
    try testing.expectError(error.TableNotFound, be.dal.table("Department"));
    try testing.expect(be.model_options.membership == false);
}
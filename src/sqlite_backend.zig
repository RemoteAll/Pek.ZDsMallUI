//! SQLite 后端：与 C# 侧「有实体/配置就连库、没有就默认 SQLite」的口径对齐——
//! **默认把数据落在 `Data/{区域}.db`，重启不丢**，不需要外部数据库。
//!
//! 驱动来自 `zzig.db.sqlite`（动态加载 `sqlite3.dll` / `winsqlite3.dll`）；
//! 加载不到时由调用方回退到内存实现（见 `options.zig` 的 `Builder.storage`）。
//!
//! 表结构（幂等 `CREATE TABLE IF NOT EXISTS`，首次启动自动建）：
//!
//! ```sql
//! Setting(Key TEXT PRIMARY KEY, Value TEXT NOT NULL)
//! AdminUser(Id INTEGER PRIMARY KEY AUTOINCREMENT, UserName TEXT UNIQUE NOT NULL,
//!           DisplayName TEXT NOT NULL, Password TEXT NOT NULL,
//!           IsAdmin INTEGER NOT NULL, Enable INTEGER NOT NULL)
//! ```
//!
//! 种子数据：表里没有用户时插入 `admin` / `admin123`（口令走 [`password`]，默认 `md5+sha1`，与 C# 字节级互通）。

const std = @import("std");
const zzig = @import("zzig");

const backend_mod = @import("backend.zig");
const password = @import("password.zig");

const sqlite = zzig.db.sqlite;
const router = zzig.web.router;
const Value = zzig.db.Value;

/// 默认数据库目录（与 C# 侧 `Data/` 同构）。
pub const DEFAULT_DB_DIR = "Data";

pub const SqliteBackend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    lib: sqlite.Lib,
    db: sqlite.Db,
    mutex: zzig.compat.Mutex = .{},

    /// 打开（不存在则创建）数据库并建表 + 补种子用户。
    ///
    /// 注意：`sqlite.Db` 内部持有 `*Lib` 指针，**必须指向本对象里的 `lib` 字段**；
    /// 早期实现把栈上 `Lib` 复制进结构体，`db.lib` 仍指向已失效的栈地址（表现为 `prepare` 段错误）。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*SqliteBackend {
        const self = try allocator.create(SqliteBackend);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .lib = undefined,
            .db = undefined,
        };

        self.lib = sqlite.Lib.load(allocator) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 加载 SQLite 失败（{s}）：把 sqlite3.dll 放到程序目录即可", .{@errorName(e)});
            return e;
        };
        errdefer self.lib.deinit();

        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) try zzig.fsio.makePath(io, dir);
        }

        self.db = sqlite.Db.open(&self.lib, path) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 打开 SQLite 数据库失败（{s}，路径 {s}）", .{ @errorName(e), path });
            return e;
        };
        errdefer self.db.close();

        try self.createSchema();
        try self.seedDefaultUser();
        zzig.Logger.info("[ZDsMallUI] SQLite 就绪：{s}（驱动 {s}）", .{ path, self.lib.version() });
        return self;
    }

    pub fn deinit(self: *SqliteBackend) void {
        self.db.close();
        self.lib.deinit();
        self.allocator.destroy(self);
    }

    pub fn backend(self: *SqliteBackend) backend_mod.AdminBackend {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    // ---- 建表 / 种子 ----

    fn createSchema(self: *SqliteBackend) !void {
        _ = try self.db.exec(self.allocator,
            \\CREATE TABLE IF NOT EXISTS Setting (
            \\  Key   TEXT PRIMARY KEY,
            \\  Value TEXT NOT NULL
            \\);
        );
        _ = try self.db.exec(self.allocator,
            \\CREATE TABLE IF NOT EXISTS AdminUser (
            \\  Id          INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  UserName    TEXT NOT NULL UNIQUE,
            \\  DisplayName TEXT NOT NULL,
            \\  Password    TEXT NOT NULL,
            \\  IsAdmin     INTEGER NOT NULL DEFAULT 1,
            \\  Enable      INTEGER NOT NULL DEFAULT 1
            \\);
        );
    }

    fn seedDefaultUser(self: *SqliteBackend) !void {
        const count = try self.queryInt("SELECT COUNT(*) AS N FROM AdminUser", &.{});
        if (count > 0) return;
        const hashed = try password.hash(self.allocator, self.io, "admin123");
        defer self.allocator.free(hashed);
        try self.exec(
            "INSERT INTO AdminUser (UserName, DisplayName, Password, IsAdmin, Enable) VALUES (?, ?, ?, 1, 1)",
            &.{ .{ .text = "admin" }, .{ .text = "管理员" }, .{ .text = hashed } },
        );
        zzig.Logger.warn("[ZDsMallUI] 已创建默认账号 admin / admin123（**生产环境请立即修改**）", .{});
    }

    // ---- 底层执行 ----

    fn exec(self: *SqliteBackend, sql: []const u8, params: []const Value) !void {
        var stmt = try self.db.prepare(self.allocator, sql);
        defer stmt.finalize();
        try stmt.bindAll(params);
        try stmt.run();
    }

    fn queryInt(self: *SqliteBackend, sql: []const u8, params: []const Value) !i64 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const row = try self.queryOne(arena_state.allocator(), sql, params);
        const v = row.get("N") orelse return 0;
        return switch (v) {
            .int => |n| n,
            else => 0,
        };
    }

    /// 执行查询并读**第一行**（无行时返回空 Row）。
    ///
    /// `readRow` 的文本值借用传入的 `arena`，所以**必须由调用方提供**：
    /// 传自己的请求 arena 就能在本次请求内安全持有，传临时 arena 就只能当场用完。
    fn queryOne(self: *SqliteBackend, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !sqlite.Row {
        var stmt = try self.db.prepare(self.allocator, sql);
        defer stmt.finalize();
        try stmt.bindAll(params);
        // `readRow` 只在 step 拿到行后才有值（未 step 时列全是 null）
        if (!stmt.hasRow()) return .{};
        return stmt.readRow(arena);
    }

    // ---- AdminBackend 实现 ----

    const vtable = backend_mod.AdminBackend.VTable{
        .settings = settingsImpl,
        .save_settings = saveSettingsImpl,
        .login = loginImpl,
        .display_name = displayNameImpl,
    };

    fn settingsImpl(ptr: *anyopaque, arena: std.mem.Allocator) anyerror!zzig.web.Value {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        // 先把库里的值读进临时 map，再与默认键合并（缺键用默认值）
        var stored = std.StringHashMapUnmanaged([]const u8).empty;
        defer {
            var it = stored.iterator();
            while (it.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
                self.allocator.free(kv.value_ptr.*);
            }
            stored.deinit(self.allocator);
        }

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const tmp = arena_state.allocator();

        var stmt = try self.db.prepare(self.allocator, "SELECT Key, Value FROM Setting");
        defer stmt.finalize();
        while (stmt.hasRow()) {
            const row = try stmt.readRow(tmp);
            const key = row.get("Key") orelse break;
            const val = row.get("Value") orelse break;
            const owned_key = try self.allocator.dupe(u8, key.text);
            errdefer self.allocator.free(owned_key);
            const owned_val = try self.allocator.dupe(u8, val.text);
            try stored.put(self.allocator, owned_key, owned_val);
        }

        return backend_mod.settingsValue(arena, &stored);
    }

    fn saveSettingsImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        form: []const router.Param,
    ) anyerror!backend_mod.SaveOutcome {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));

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
        _ = arena;

        for (form) |field| {
            const target = backend_mod.formKeyToSetting(field.name) orelse continue;
            try self.exec(
                "INSERT INTO Setting (Key, Value) VALUES (?, ?) ON CONFLICT(Key) DO UPDATE SET Value = excluded.Value",
                &.{ .{ .text = target }, .{ .text = field.value } },
            );
        }
        return .ok;
    }

    fn loginImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        user_name: []const u8,
        pass: []const u8,
    ) anyerror!backend_mod.LoginOutcome {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));
        const name = std.mem.trim(u8, user_name, " \t\r\n");
        if (name.len == 0 or pass.len == 0) {
            return .{ .err = "用户名与密码均不可为空" };
        }
        // 不区分「用户不存在」与「密码错误」，避免用户名枚举
        const not_found: backend_mod.LoginOutcome = .{ .err = "用户名或密码不正确" };

        self.mutex.lock();
        defer self.mutex.unlock();

        const row = try self.queryOne(arena, "SELECT Id, UserName, DisplayName, Password, IsAdmin, Enable FROM AdminUser WHERE UserName = ? COLLATE NOCASE", &.{.{ .text = name }});
        if (row.names.len == 0) return not_found;

        const id = (row.get("Id") orelse return not_found).int;
        const db_user = (row.get("UserName") orelse return not_found).text;
        const db_display = (row.get("DisplayName") orelse return not_found).text;
        const db_password = (row.get("Password") orelse return not_found).text;
        const is_admin = switch (row.get("IsAdmin") orelse return not_found) {
            .int => |n| n != 0,
            else => false,
        };
        const enabled = switch (row.get("Enable") orelse return not_found) {
            .int => |n| n != 0,
            else => true,
        };
        if (!enabled) return .{ .err = "账号已被停用" };

        const result = try password.verifyAndUpgrade(self.allocator, self.io, .{}, pass, db_password);
        if (!result.ok) return not_found;
        // 旧算法自动升级（一次性回写）
        if (result.upgraded) |upgraded| {
            defer self.allocator.free(upgraded);
            try self.exec("UPDATE AdminUser SET Password = ? WHERE Id = ?", &.{
                .{ .text = upgraded },
                .{ .int = id },
            });
        }

        return .{ .ok = .{
            .id = id,
            .user_name = try arena.dupe(u8, db_user),
            .display_name = try arena.dupe(u8, db_display),
            .is_admin = is_admin,
        } };
    }

    fn displayNameImpl(ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]const u8 {
        const self: *SqliteBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const row = try self.queryOne(arena, "SELECT Value FROM Setting WHERE Key = 'displayName'", &.{});
        if (row.names.len > 0) {
            if (row.get("Value")) |v| {
                const text = std.mem.trim(u8, v.text, " \t\r\n");
                if (text.len > 0) return arena.dupe(u8, text);
            }
        }
        return "管理后台";
    }
};

const testing = std.testing;

test "sqlite 后端：建表 + 设置读写 + 登录（无驱动时显式 SKIP）" {
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

    // 默认账号可登录
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const outcome = try be.backend().login(arena, "admin", "admin123");
        try testing.expect(outcome == .ok);
        try testing.expectEqualStrings("admin", outcome.ok.user_name);
    }

    // 错误口令
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const outcome = try be.backend().login(arena_state.allocator(), "admin", "wrong");
        try testing.expect(outcome == .err);
    }

    // 保存设置 → 重新读取（走真实 INSERT ... ON CONFLICT）
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const form = [_]router.Param{
            .{ .name = "SiteName", .value = "SQLiteShop" },
            .{ .name = "DisplayName", .value = "SQLite 后台" },
        };
        const outcome = try be.backend().saveSettings(arena, &form);
        try testing.expect(outcome == .ok);
        try testing.expectEqualStrings("SQLite 后台", try be.backend().displayName(arena));
    }

    // 重开同一个库：数据必须在（持久化验证）
    {
        be.deinit();
        be_opt = null;
        const again = try SqliteBackend.init(testing.allocator, testing.io, path);
        defer again.deinit();
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        try testing.expectEqualStrings("SQLite 后台", try again.backend().displayName(arena_state.allocator()));
    }
}

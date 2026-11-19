//! SQLite 后端：**表结构由 `Pek.ZCode` 的 `Dal.syncSchema` 同步**（模型是唯一真相源：
//! 缺表建表、缺列 `ALTER TABLE ... ADD COLUMN`、缺索引建索引；**不删列、不改类型**），
//! 本文件里不写任何 `CREATE TABLE`。
//!
//! 分工（都实测过）：
//! - **建表/迁移**：`Pek.ZCode`（`EntityModel` + `Dal.syncSchema`），只在启动时跑一次，
//!   用完就把它的连接关掉；
//! - **运行期读写**：直接用 `zzig.db.sqlite`（一次 prepare + bind + step，没有 session 建连开销）。
//!   早期版本每个请求都 `Dal.openSession()`，实测单条 INSERT 要 ~1.1s（方言探测 + 建连），
//!   而 `Session` 按值拷进结构体会让它内部的指针失效（`prepare` 段错误），所以运行期不再用它。
//!
//! - 模型：`assets/zdsmallui-model.xml`；库文件：`Data/{区域}.db`
//! - 种子：库里没有用户时插入 `admin` / `admin123`（口令走 [`password`]，与 C# 字节级互通）

const std = @import("std");
const zzig = @import("zzig");
const zcode = @import("zcode");

const backend_mod = @import("backend.zig");
const password = @import("password.zig");

const sqlite = zzig.db.sqlite;
const router = zzig.web.router;
const Value = zzig.db.Value;

/// 内置模型（`Model.xml`，与 C# 同格式；结构变更只改它）。
pub const MODEL_XML = @embedFile("../assets/zdsmallui-model.xml");

/// 默认数据库目录（与 C# 侧 `Data/` 同构）。
pub const DEFAULT_DB_DIR = "Data";

pub const SqliteBackend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    lib: sqlite.Lib,
    db: sqlite.Db,
    mutex: zzig.compat.Mutex = .{},

    /// 打开（不存在则创建）数据库：先用 `Pek.ZCode` 同步表结构，再建运行期连接。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*SqliteBackend {
        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) try zzig.fsio.makePath(io, dir);
        }

        try syncSchema(allocator, path);

        const self = try allocator.create(SqliteBackend);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .lib = undefined, .db = undefined };

        self.lib = sqlite.Lib.load(allocator) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 加载 SQLite 失败（{s}）：把 sqlite3.dll 放到程序目录即可", .{@errorName(e)});
            return e;
        };
        errdefer self.lib.deinit();

        // **不显式指定 journal_mode/synchronous**：`zzig.db.sqlite.Options` 的默认值已经是
        // 最快的 `WAL + NORMAL`（2026-11-19 改）。这里只覆盖 busy_timeout —— 面板启动时常有
        // 外部工具（备份脚本、SQLiteStudio）占着库，8 秒等待比默认 5 秒更不容易误报失败。
        //
        // 若确认部署在网络盘（SMB/NFS 不支持 `-shm` 共享内存文件），把 `journal_mode` 显式设成
        // `"delete"` 即可；WAL 设置失败时驱动只打日志，不会中断打开。
        self.db = sqlite.Db.openWithOptions(&self.lib, path, .{
            .busy_timeout_ms = 8000,
        }) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 打开 SQLite 数据库失败（{s}，路径 {s}）", .{ @errorName(e), path });
            return e;
        };
        errdefer self.db.close();

        try self.seedDefaultUser();
        // 把**实际生效**的 journal_mode 打出来：WAL 在部分环境（网络盘 / 某些构建）会静默失败，
        // 而它是 32 倍写吞吐与「写时还能读」的关键，运维需要一眼能确认。
        var mode_buf: [32]u8 = undefined;
        if (self.queryScalarText("PRAGMA journal_mode", &.{}, &mode_buf)) |mode| {
            zzig.Logger.info("[ZDsMallUI] SQLite journal_mode = {s}", .{mode});
        } else |_| {}
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

    /// 用 `Pek.ZCode` 做增量建表（幂等：再跑一次不会重复建/不会报错）。
    fn syncSchema(allocator: std.mem.Allocator, path: []const u8) !void {
        const model = zcode.EntityModel.parse(allocator, MODEL_XML) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 解析内置 Model.xml 失败：{s}", .{@errorName(e)});
            return e;
        };
        const conn = try std.fmt.allocPrint(allocator, "Data Source={s};Provider=SQLite;JournalMode=WAL;Synchronous=NORMAL", .{path});
        defer allocator.free(conn);

        var dal = zcode.Dal.initWithModel(allocator, conn, model) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 建表连接失败（{s}，路径 {s}）", .{ @errorName(e), path });
            return e;
        };
        defer dal.deinit();

        var s = try dal.openSession();
        defer s.deinit();
        const report = dal.syncSchema(&s) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 同步表结构失败（库 {s}）：{s}", .{ path, @errorName(e) });
            return e;
        };
        if (report.tables_created > 0 or report.columns_added > 0 or report.indexes_created > 0) {
            zzig.Logger.info(
                "[ZDsMallUI] 表结构已同步：新建表 {d} / 补列 {d} / 建索引 {d}",
                .{ report.tables_created, report.columns_added, report.indexes_created },
            );
        }
    }

    // ---- 底层执行（调用方负责加锁）----

    fn exec(self: *SqliteBackend, sql: []const u8, params: []const Value) !void {
        var stmt = try self.db.prepare(self.allocator, sql);
        defer stmt.finalize();
        try stmt.bindAll(params);
        try stmt.run();
    }

    fn queryScalarInt(self: *SqliteBackend, sql: []const u8, params: []const Value) !i64 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const row = try self.queryOne(arena_state.allocator(), sql, params);
        const v = row.at(0) orelse return 0;
        return switch (v) {
            .int => |n| n,
            .boolean => |b| if (b) 1 else 0,
            else => 0,
        };
    }

    /// 读单列文本写进调用方提供的缓冲（典型用法：`PRAGMA journal_mode` 的回读）。
    /// 写进 `buf` 而不是分配：日志这类短命文本不必占堆，也不会漏。
    fn queryScalarText(self: *SqliteBackend, sql: []const u8, params: []const Value, buf: []u8) ![]const u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const row = try self.queryOne(arena_state.allocator(), sql, params);
        const v = row.at(0) orelse return "";
        const text = switch (v) {
            .text => |t| t,
            else => return "",
        };
        const n = @min(text.len, buf.len);
        @memcpy(buf[0..n], text[0..n]);
        return buf[0..n];
    }

    /// 查询并读**第一行**（无行返回空 Row）。`arena` 由调用方提供：`readRow` 的文本借用它。
    fn queryOne(self: *SqliteBackend, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !sqlite.Row {
        var stmt = try self.db.prepare(self.allocator, sql);
        defer stmt.finalize();
        try stmt.bindAll(params);
        if (!stmt.hasRow()) return .{};
        return stmt.readRow(arena);
    }

    // ---- 种子 ----

    fn seedDefaultUser(self: *SqliteBackend) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = try self.queryScalarInt("SELECT COUNT(*) FROM AdminUser", &.{});
        if (count > 0) return;

        const hashed = try password.hash(self.allocator, self.io, "admin123");
        defer self.allocator.free(hashed);
        try self.exec(
            "INSERT INTO AdminUser (UserName, DisplayName, Password, IsAdmin, Enable) VALUES (?, ?, ?, 1, 1)",
            &.{ .{ .text = "admin" }, .{ .text = "管理员" }, .{ .text = hashed } },
        );
        zzig.Logger.warn("[ZDsMallUI] 已创建默认账号 admin / admin123（**生产环境请立即修改**）", .{});
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
            const value = row.get("Value") orelse break;
            const owned_key = try self.allocator.dupe(u8, key.text);
            errdefer self.allocator.free(owned_key);
            const owned_val = try self.allocator.dupe(u8, value.text);
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

        const row = try self.queryOne(
            arena,
            "SELECT Id, UserName, DisplayName, Password, IsAdmin, Enable FROM AdminUser WHERE UserName = ? COLLATE NOCASE",
            &.{.{ .text = name }},
        );
        if (row.names.len == 0) return not_found;

        const id = (row.get("Id") orelse return not_found).int;
        const db_user = (row.get("UserName") orelse return not_found).text;
        const db_display = (row.get("DisplayName") orelse return not_found).text;
        const db_password = (row.get("Password") orelse return not_found).text;
        const is_admin = switch (row.get("IsAdmin") orelse return not_found) {
            .int => |n| n != 0,
            .boolean => |b| b,
            else => false,
        };
        const enabled = switch (row.get("Enable") orelse return not_found) {
            .int => |n| n != 0,
            .boolean => |b| b,
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

test "sqlite 后端：ZCode syncSchema 建表 + 设置读写 + 登录 + 重开数据仍在" {
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

    // 默认账号可登录（种子走 INSERT，读写走 prepare/bind）
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
        try testing.expect(try be.backend().login(arena_state.allocator(), "admin", "wrong") == .err);
    }

    // 保存设置 → 读取
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const form = [_]router.Param{
            .{ .name = "SiteName", .value = "SQLiteShop" },
            .{ .name = "DisplayName", .value = "SQLite 后台" },
        };
        try testing.expect(try be.backend().saveSettings(arena, &form) == .ok);
        try testing.expectEqualStrings("SQLite 后台", try be.backend().displayName(arena));
    }

    // 重开同一个库：数据仍在（持久化）+ syncSchema 再跑一次仍幂等
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

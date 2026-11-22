//! SQLite 版会话存储（`Pek.ZPermissions` 的 `session.Store` 接口实现）。
//!
//! 为什么需要：`Keeper.revoke` 把吊销记录写进 Store，默认的 `MemoryStore` **重启就丢** ——
//! 面板重启后，已登出的令牌又能用（在 JWT 自己的有效期内）。落库后重启仍失效。
//!
//! 表结构由 `assets/Model.xml` 的 `Session` 表提供（`Pek.ZCode` 的 `syncSchema`
//! 幂等建表，和 `Setting` / `AdminUser` 一个库）。
//!
//! 只实现 KV 三件套（`get` / `set` / `del`）：`sadd`/`srem`/`smembers` 用于「在线会话列表」，
//! 属可选能力，这里不实现（`supportsSets()` 为 false，在线列表降级，**吊销不受影响**）。

const std = @import("std");
const zzig = @import("zzig");
const zperms = @import("pek_zpermissions");

const sqlite = zzig.db.sqlite;
const Value = zzig.db.Value;

pub const SqliteSessionStore = struct {
    allocator: std.mem.Allocator,
    lib: sqlite.Lib,
    db: sqlite.Db,
    mutex: zzig.compat.Mutex = .{},

    /// 打开（表结构由调用方在此之前用 `Pek.ZCode` 的 `syncSchema` 建好）。
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*SqliteSessionStore {
        const self = try allocator.create(SqliteSessionStore);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .lib = undefined, .db = undefined };

        self.lib = sqlite.Lib.load(allocator) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 会话存储加载 SQLite 失败（{s}）", .{@errorName(e)});
            return e;
        };
        errdefer self.lib.deinit();

        self.db = sqlite.Db.open(&self.lib, path) catch |e| {
            zzig.Logger.err("[ZDsMallUI] 会话存储打开数据库失败（{s}，{s}）", .{ @errorName(e), path });
            return e;
        };
        errdefer self.db.close();
        _ = self.db.exec(allocator, "PRAGMA busy_timeout = 9000") catch {};

        // 顺手清一次过期项，避免表无限增长
        _ = self.db.exec(allocator, "DELETE FROM Session WHERE ExpireAt > 0 AND ExpireAt <= strftime('%s','now')") catch {};

        return self;
    }

    pub fn deinit(self: *SqliteSessionStore) void {
        self.db.close();
        self.lib.deinit();
        self.allocator.destroy(self);
    }

    /// 取 `Pek.ZPermissions` 需要的接口视图。
    pub fn store(self: *SqliteSessionStore) zperms.SessionStore {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    // ---- 内部 ----

    fn exec(self: *SqliteSessionStore, sql: []const u8, params: []const Value) !void {
        var stmt = try self.db.prepare(self.allocator, sql);
        defer stmt.finalize();
        try stmt.bindAll(params);
        try stmt.run();
    }

    /// 读一行（`arena` 由调用方给；文本借用它）。
    fn queryOne(self: *SqliteSessionStore, arena: std.mem.Allocator, sql: []const u8, params: []const Value) !sqlite.Row {
        var stmt = try self.db.prepare(self.allocator, sql);
        defer stmt.finalize();
        try stmt.bindAll(params);
        if (!stmt.hasRow()) return .{};
        return stmt.readRow(arena);
    }

    // ---- Store vtable ----

    const vtable = zperms.SessionStore.VTable{
        .available = availableImpl,
        .get = getImpl,
        .set = setImpl,
        .del = delImpl,
    };

    fn availableImpl(_: *anyopaque) bool {
        // 打开时就验证过连接；运行期失败由各方法返回 null/false（接口约定：不 panic）
        return true;
    }

    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, now: i64) ?[]u8 {
        const self: *SqliteSessionStore = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        const row = self.queryOne(arena_state.allocator(), "SELECT Value, ExpireAt FROM Session WHERE Key = ?", &.{.{ .text = key }}) catch |e| {
            zzig.Logger.warn("[ZDsMallUI] 会话读取失败（{s}）：{s}", .{ key, @errorName(e) });
            return null;
        };
        if (row.names.len == 0) return null;

        const value = row.get("Value") orelse return null;
        const expire_at: i64 = switch (row.get("ExpireAt") orelse return null) {
            .int => |n| n,
            else => 0,
        };
        if (expire_at > 0 and expire_at <= now) {
            self.exec("DELETE FROM Session WHERE Key = ?", &.{.{ .text = key }}) catch {};
            return null;
        }
        return allocator.dupe(u8, value.text) catch null;
    }

    fn setImpl(ptr: *anyopaque, key: []const u8, value: []const u8, ttl_secs: i64, now: i64) bool {
        const self: *SqliteSessionStore = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const expire_at: i64 = if (ttl_secs > 0) now + ttl_secs else 0;
        self.exec(
            "INSERT INTO Session (Key, Value, ExpireAt) VALUES (?, ?, ?) ON CONFLICT(Key) DO UPDATE SET Value = excluded.Value, ExpireAt = excluded.ExpireAt",
            &.{ .{ .text = key }, .{ .text = value }, .{ .int = expire_at } },
        ) catch |e| {
            zzig.Logger.warn("[ZDsMallUI] 会话写入失败（{s}）：{s}", .{ key, @errorName(e) });
            return false;
        };
        return true;
    }

    fn delImpl(ptr: *anyopaque, key: []const u8) bool {
        const self: *SqliteSessionStore = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        self.exec("DELETE FROM Session WHERE Key = ?", &.{.{ .text = key }}) catch |e| {
            zzig.Logger.warn("[ZDsMallUI] 会话删除失败（{s}）：{s}", .{ key, @errorName(e) });
            return false;
        };
        return true;
    }
};

const testing = std.testing;

test "sqlite 会话存储：set/get/del 与 TTL 过期" {
    const dir = ".zig-cache/zdsmallui-test-session";
    std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    try zzig.fsio.makePath(testing.io, dir);
    const path = dir ++ "/s.db";

    // 表结构用与生产一致的方式建（ZCode syncSchema）
    const zcode = @import("zcode");
    const model = try zcode.EntityModel.parse(testing.allocator, @embedFile("../assets/Model.xml"));
    const conn = try std.fmt.allocPrint(testing.allocator, "Data Source={s};Provider=SQLite", .{path});
    defer testing.allocator.free(conn);
    var dal = try zcode.Dal.initWithModel(testing.allocator, conn, model);
    defer dal.deinit();
    {
        var s = try dal.openSession();
        defer s.deinit();
        _ = try dal.syncSchema(&s);
    }

    const st = SqliteSessionStore.init(testing.allocator, path) catch |e| {
        std.debug.print("[SKIP] 本机没有可用 SQLite 驱动：{s}\n", .{@errorName(e)});
        return;
    };
    defer st.deinit();
    const store = st.store();

    try testing.expect(store.available());
    try testing.expect(store.get(testing.allocator, "nope", 100) == null);

    // 写入 → 读回
    try testing.expect(store.set("k1", "v1", 60, 1000));
    {
        const got = store.get(testing.allocator, "k1", 1000).?;
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("v1", got);
    }

    // 过期后读不到（并顺手删除）
    try testing.expect(store.get(testing.allocator, "k1", 1061) == null);

    // 删除
    try testing.expect(store.set("k2", "v2", 0, 1000)); // ttl=0 不过期
    try testing.expect(store.del("k2"));
    try testing.expect(store.get(testing.allocator, "k2", 9999) == null);

    // 不支持集合能力（在线列表降级，吊销不受影响）
    try testing.expect(!store.supportsSets());
}

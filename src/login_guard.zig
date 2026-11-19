//! 登录防爆破（按「客户端 IP」+「用户名」双维度计数，失败到阈值后短时封禁）。
//!
//! 口径（对齐 Rust 侧 `dhrust::net::login_guard` 的取舍）：
//! - **不硬锁账号**：只对「IP」「用户名」两个键做限时封禁，避免攻击者用错误口令把管理员永久锁死；
//! - **IP 维度宽松、用户维度严格**：办公室 NAT 下多人共用一个出口 IP，IP 阈值放大到 10 次；
//!   单账号被撞库的风险由用户维度（5 次）兜住；
//! - **键统一小写**：`Admin` / `admin`、`::FFFF:1.2.3.4` / `::ffff:1.2.3.4` 都归一到同一个键，防止换大小写绕过；
//! - **内存有界**：条目超 `max_entries` 先清过期项，仍超限就整表清空（宁可少限一次，不能被打爆内存）。
//!
//! 说明：这是**进程内**限流，多实例部署需换共享存储（Redis 等）；单实例面板足够。
//! 另外，反向代理后必须让 `zzig.http.server` 的 `trust_forwarded_for = true`，
//! 否则所有请求的 `remote_addr` 都是 `127.0.0.1`，IP 维度会退化成「全部算同一个客户端」。

const std = @import("std");
const zzig = @import("zzig");

pub const Options = struct {
    /// 同一 IP 允许的连续失败次数
    ip_max_fails: u32 = 10,
    /// 同一用户名允许的连续失败次数
    user_max_fails: u32 = 5,
    /// 封禁时长（秒）
    lock_seconds: i64 = 300,
    /// 计数窗口（秒）：超过窗口没有再失败就重新计数
    window_seconds: i64 = 600,
    /// 条目上限（防止被大量随机用户名撑爆内存）
    max_entries: usize = 4096,
};

const Entry = struct {
    fails: u32 = 0,
    first_ms: i64 = 0,
    locked_until_ms: i64 = 0,
};

const KEY_BUF_LEN = 96;
const PREFIX_IP: u8 = 'i';
const PREFIX_USER: u8 = 'u';

/// 登录失败守卫（**线程安全**，可挂在常驻服务上共享）。
pub const Guard = struct {
    allocator: std.mem.Allocator,
    mutex: zzig.compat.Mutex = .{},
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    opts: Options = .{},

    pub fn init(allocator: std.mem.Allocator, opts: Options) Guard {
        return .{ .allocator = allocator, .opts = opts };
    }

    pub fn deinit(self: *Guard) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// 距离可以再尝试还有多少秒（`null` = 放行）。
    pub fn retryAfterSeconds(self: *Guard, user: []const u8, ip: []const u8, now_ms: i64) ?i64 {
        var ip_buf: [KEY_BUF_LEN]u8 = undefined;
        var user_buf: [KEY_BUF_LEN]u8 = undefined;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.lockedSeconds(keyOf(&ip_buf, PREFIX_IP, ip), now_ms)) |secs| return secs;
        if (self.lockedSeconds(keyOf(&user_buf, PREFIX_USER, user), now_ms)) |secs| return secs;
        return null;
    }

    /// 记一次失败（任一维度达到阈值即开始封禁）。
    pub fn recordFailure(self: *Guard, user: []const u8, ip: []const u8, now_ms: i64) !void {
        var ip_buf: [KEY_BUF_LEN]u8 = undefined;
        var user_buf: [KEY_BUF_LEN]u8 = undefined;
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.bump(keyOf(&ip_buf, PREFIX_IP, ip), self.opts.ip_max_fails, now_ms);
        try self.bump(keyOf(&user_buf, PREFIX_USER, user), self.opts.user_max_fails, now_ms);
    }

    /// 登录成功 → 清掉两维计数。
    pub fn recordSuccess(self: *Guard, user: []const u8, ip: []const u8) void {
        var ip_buf: [KEY_BUF_LEN]u8 = undefined;
        var user_buf: [KEY_BUF_LEN]u8 = undefined;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.remove(keyOf(&ip_buf, PREFIX_IP, ip));
        self.remove(keyOf(&user_buf, PREFIX_USER, user));
    }

    /// 当前条目数（诊断/测试用）。
    pub fn count(self: *Guard) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.count();
    }

    // ---- 内部（调用方必须已持锁）----

    fn lockedSeconds(self: *Guard, key: []const u8, now_ms: i64) ?i64 {
        const entry = self.entries.get(key) orelse return null;
        if (entry.locked_until_ms <= now_ms) return null;
        // 向上取整：还剩 0.4 秒也要说「1 秒后再试」，不能报 0
        return @divTrunc(entry.locked_until_ms - now_ms + 999, 1000);
    }

    fn bump(self: *Guard, key: []const u8, limit: u32, now_ms: i64) !void {
        if (self.entries.count() >= self.opts.max_entries) self.evict(now_ms);

        const gop = try self.entries.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            // `getOrPut` 不复制 key，必须自己存一份
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
            gop.value_ptr.* = .{ .fails = 0, .first_ms = now_ms, .locked_until_ms = 0 };
        }
        const entry = gop.value_ptr;
        if (now_ms - entry.first_ms > self.opts.window_seconds * 1000) {
            entry.* = .{ .fails = 0, .first_ms = now_ms, .locked_until_ms = 0 };
        }
        entry.fails += 1;
        if (entry.fails >= limit) {
            entry.locked_until_ms = now_ms + self.opts.lock_seconds * 1000;
            entry.fails = 0;
            entry.first_ms = now_ms;
        }
    }

    fn remove(self: *Guard, key: []const u8) void {
        if (self.entries.fetchRemove(key)) |kv| self.allocator.free(kv.key);
    }

    /// 清过期条目；`max_entries` 用满仍清不出空间就整表清空（保内存不保精度）。
    fn evict(self: *Guard, now_ms: i64) void {
        const window_ms = self.opts.window_seconds * 1000;
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            const locked = entry.locked_until_ms > now_ms;
            if (!locked and now_ms - entry.first_ms > window_ms) {
                stale.append(self.allocator, kv.key_ptr.*) catch {};
            }
        }
        for (stale.items) |key| self.remove(key);

        if (self.entries.count() >= self.opts.max_entries) {
            var all = self.entries.iterator();
            while (all.next()) |kv| self.allocator.free(kv.key_ptr.*);
            self.entries.clearRetainingCapacity();
        }
    }
};

/// 构造 map 键：`<前缀><小写化后的标识>`（截断到缓冲上限，仍保留前缀区分维度）。
fn keyOf(buf: []u8, prefix: u8, ident: []const u8) []const u8 {
    const n = @min(ident.len, buf.len - 1);
    buf[0] = prefix;
    for (0..n) |i| buf[1 + i] = std.ascii.toLower(ident[i]);
    return buf[0 .. 1 + n];
}

const testing = std.testing;

test "login_guard：失败到阈值后封禁，成功后清零" {
    var g = Guard.init(testing.allocator, .{ .user_max_fails = 3, .ip_max_fails = 5, .lock_seconds = 60 });
    defer g.deinit();

    const now: i64 = 1_000_000;
    try testing.expect(g.retryAfterSeconds("admin", "1.2.3.4", now) == null);
    try g.recordFailure("admin", "1.2.3.4", now);
    try g.recordFailure("admin", "1.2.3.4", now);
    try testing.expect(g.retryAfterSeconds("admin", "1.2.3.4", now) == null);
    try g.recordFailure("admin", "1.2.3.4", now); // 第 3 次 → 用户维度锁定
    try testing.expectEqual(@as(?i64, 60), g.retryAfterSeconds("admin", "9.9.9.9", now));
    // 大小写变体不能绕过（键统一小写）
    try testing.expectEqual(@as(?i64, 60), g.retryAfterSeconds("AdMiN", "9.9.9.8", now));

    // 同一 IP 换个用户名不会被用户维度影响
    try testing.expect(g.retryAfterSeconds("other", "1.2.3.4", now) == null);

    // 成功登录清掉该用户/IP 的计数
    g.recordSuccess("admin", "1.2.3.4");
    try testing.expect(g.retryAfterSeconds("admin", "1.2.3.4", now) == null);
}

test "login_guard：封禁到期自动放行；IP 维度独立生效" {
    var g = Guard.init(testing.allocator, .{ .user_max_fails = 100, .ip_max_fails = 2, .lock_seconds = 30 });
    defer g.deinit();

    const now: i64 = 5_000_000;
    try g.recordFailure("u1", "8.8.8.8", now);
    try g.recordFailure("u2", "8.8.8.8", now);
    try testing.expectEqual(@as(?i64, 30), g.retryAfterSeconds("u3", "8.8.8.8", now));
    try testing.expect(g.retryAfterSeconds("u3", "8.8.8.8", now + 30_000) == null);
}

test "login_guard：条目上限有界（清空而不是无限增长）" {
    var g = Guard.init(testing.allocator, .{
        .user_max_fails = 100,
        .ip_max_fails = 100,
        .max_entries = 8,
        .window_seconds = 60,
    });
    defer g.deinit();

    const now: i64 = 7_000_000;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var buf: [32]u8 = undefined;
        const ip = try std.fmt.bufPrint(&buf, "10.0.{d}.{d}", .{ i / 250, i % 250 });
        try g.recordFailure("u", ip, now + @as(i64, @intCast(i)) * 1000);
    }
    try testing.expect(g.count() <= 8);
}

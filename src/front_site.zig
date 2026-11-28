//! 前台站点外壳的**三块公共状态**（2026-11-28 下沉：两个站点原来逐行同款）。
//!
//! 两个基于本库的前台站点（企业门户 `HaiLinXCom`、工具站 `Pek.ZTools`）的 `site.zig` 里，
//! 下列三段代码除了日志前缀 `[xxx]` 之外**字节级一致**（实测 16 个函数完全相同、另 6 个相似度 ≥0.9）：
//!
//! - [`FooterLinks`]：页脚文章入口（`/p/{code}`）——60 秒 TTL 缓存，命中时零查库；
//! - [`AssetCache`]：随包资源校验 / `.gz` 预压缩 / `?v=` 指纹（1 秒缓存，省 mtime syscall）；
//! - [`RateLimit`]：接口级限流阀门（`pek_zwaf.Throttle`，与 C# `[RateValve]` 同口径）。
//!
//! 为什么放在**本库**而不是 `zzig`：`FrontSite` 的形状由「后台框架 + 多语言仓储 + 后台站点设置」
//! 决定（`language.Store` / `AdminArea` 都在本库），`zzig` 不该反向依赖它们。
//! 而限流阀门用 **comptime 泛型**（`RateLimit(pek_zwaf)`），本库因此**不需要依赖 Pek.ZWaf**。
//!
//! 站点专属的部分（页面清单、页脚外链、JSON-LD、`pageModel`）仍留在各自 `site.zig`。

const std = @import("std");
const zzig = @import("zzig");

/// 页脚外链（文章）最小形状：`code` + `name`。
pub const Link = struct { code: []const u8, name: []const u8 };

/// 页脚文章入口：**变化驱动 + TTL**，避免「每页每请求都查库」。
///
/// `store_opt` 是**任意**提供 `listPublished(gpa) ![]Row`（`Row` 至少含 `code` / `name`）的仓储，
/// 用 Zig 的 duck typing 传进来 —— 各项目的文章仓储类型不同，不必为它抽接口。
/// **必须传 optional 指针**（`?*Store`，传 `null` 表示本站没有文章仓储）。
pub const FooterLinks = struct {
    /// 缓存有效期：文章改动不频繁，60 秒延迟足够。
    ttl_ms: i64 = 60_000,
    mutex: std.Io.Mutex = .init,
    cache: ?Cache = null,

    const Cache = struct { at_ms: i64, items: []Link };

    /// 取页脚文章链接（结果拷进 `arena`，调用方不用管生命周期）。
    ///
    /// 仓储为 `null` → 空列表；查库失败 → 记一条 warn 并返回空列表（不能因为页脚挂掉整页）。
    pub fn cached(
        self: *FooterLinks,
        gpa: std.mem.Allocator,
        io: std.Io,
        arena: std.mem.Allocator,
        store_opt: anytype,
        log_tag: []const u8,
    ) ![]Link {
        const store = store_opt orelse return &.{};
        const now = zzig.web.page_kit.nowMillis();

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.cache) |cache| {
            if (now - cache.at_ms < self.ttl_ms) return try dupeAll(arena, cache.items);
            // 过期：先释放旧值，再查库
            freeAll(gpa, cache.items);
            self.cache = null;
        }

        const rows = store.listPublished(gpa) catch |err| {
            zzig.Logger.warn("{s} 页脚文章列表读取失败（{s}）：本次不显示", .{ log_tag, @errorName(err) });
            return &.{};
        };
        // `listPublished` 返回的字符串指向 session 结果集 → 必须搬进自己的内存
        var items: std.ArrayList(Link) = .empty;
        errdefer {
            for (items.items) |item| {
                gpa.free(item.code);
                gpa.free(item.name);
            }
            items.deinit(gpa);
        }
        for (rows) |row| {
            try items.append(gpa, .{
                .code = try gpa.dupe(u8, row.code),
                .name = try gpa.dupe(u8, row.name),
            });
        }
        const owned = try items.toOwnedSlice(gpa);
        self.cache = .{ .at_ms = now, .items = owned };
        return try dupeAll(arena, owned);
    }

    pub fn deinit(self: *FooterLinks, gpa: std.mem.Allocator, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.cache) |cache| {
            freeAll(gpa, cache.items);
            self.cache = null;
        }
    }

    fn dupeAll(arena: std.mem.Allocator, items: []const Link) ![]Link {
        var out: std.ArrayList(Link) = .empty;
        errdefer out.deinit(arena);
        for (items) |item| {
            try out.append(arena, .{
                .code = try arena.dupe(u8, item.code),
                .name = try arena.dupe(u8, item.name),
            });
        }
        return out.toOwnedSlice(arena);
    }

    fn freeAll(gpa: std.mem.Allocator, items: []const Link) void {
        for (items) |item| {
            gpa.free(item.code);
            gpa.free(item.name);
        }
        gpa.free(items);
    }
};

/// 随包前端资源：校验 / 预压缩 / 指纹（口径由调用方的 `zzig.web.assets.Options` 决定）。
///
/// 指纹缓存 **1 秒**：它来自 `statFile(site.css)` 的 mtime，而每页要用两次（`<link>` 与页脚），
/// 一次 syscall 在 Windows 上就要几十微秒；1 秒粒度对「重新部署 / 改样式」完全够快。
pub const AssetCache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    /// 指纹兜底值（通常取程序版本号）。
    version_fallback: []const u8,
    opts: zzig.web.assets.Options,
    ttl_ms: i64 = 1000,
    mutex: std.Io.Mutex = .init,
    cached_version: []const u8 = "",
    cached_at_ms: i64 = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        base_dir: []const u8,
        version_fallback: []const u8,
        opts: zzig.web.assets.Options,
    ) AssetCache {
        return .{
            .gpa = gpa,
            .io = io,
            .base_dir = base_dir,
            .version_fallback = version_fallback,
            .opts = opts,
        };
    }

    /// 校验随包资源（缺失逐条列出并返回错误 —— 缺文件的站点不该假装起来了）。
    pub fn ensure(self: *AssetCache) !void {
        return zzig.web.assets.ensure(self.gpa, self.io, self.base_dir, self.opts);
    }

    /// 为随包静态资源预压缩 `.gz`（mtime 更新的才重压）。
    pub fn precompress(self: *AssetCache) void {
        zzig.web.assets.precompress(self.gpa, self.io, self.base_dir, self.opts);
    }

    /// 删掉 `.gz` 预压缩副本（开发模式用）。
    pub fn removePrecompressed(self: *AssetCache) void {
        zzig.web.assets.removePrecompressed(self.gpa, self.io, self.base_dir, self.opts);
    }

    /// `?v=` 指纹（1 秒缓存；返回的切片归缓存或 `arena`）。
    pub fn fingerprint(self: *AssetCache, arena: std.mem.Allocator) []const u8 {
        const now = zzig.web.page_kit.nowMillis();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.cached_version.len > 0 and now - self.cached_at_ms < self.ttl_ms) return self.cached_version;

        const fresh = zzig.web.assets.fingerprint(self.io, self.base_dir, self.opts, self.version_fallback, arena);
        if (self.gpa.dupe(u8, fresh)) |copy| {
            if (self.cached_version.len > 0) self.gpa.free(self.cached_version);
            self.cached_version = copy;
            self.cached_at_ms = now;
        } else |_| {}
        return fresh;
    }

    pub fn deinit(self: *AssetCache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.cached_version.len > 0) {
            self.gpa.free(self.cached_version);
            self.cached_version = "";
        }
        self.cached_at_ms = 0;
    }
};

/// 接口级限流阀门（`pek_zwaf.Throttle`）。
///
/// 泛型参数是 **Pek.ZWaf 模块本身**（`RateLimit(pek_zwaf)`）：这样本库不必依赖 ZWaf，
/// 而两个站点的 `Throttle` / `ThrottleRule` / `RateValve` 仍是同一份。
pub fn RateLimit(comptime zwaf: type) type {
    return struct {
        const Self = @This();

        throttle: ?*zwaf.Throttle = null,

        /// 给单个路由挂阀门（`Throttle.guard` 内部会深拷贝规则；未启用限流时原样返回）。
        pub fn limited(
            self: *Self,
            method: []const u8,
            path: []const u8,
            valve: zwaf.RateValve,
            inner: zzig.web.Handler,
        ) !zzig.web.Handler {
            const t = self.throttle orelse return inner;
            return t.guard(zwaf.ThrottleRule.new(method, path, &.{valve}), inner);
        }

        /// 按「每分钟次数」挂阀门（内部构造 `RateValve.ip`，控制器不用 import ZWaf）。
        pub fn limitedOf(
            self: *Self,
            method: []const u8,
            path: []const u8,
            per_min: u16,
            inner: zzig.web.Handler,
        ) !zzig.web.Handler {
            return self.limited(method, path, zwaf.RateValve.ip(per_min, 60), inner);
        }

        /// **具名**限流：同名规则共享配额（计数键含规则名）。
        ///
        /// 同一逻辑页面的多个地址（`/`、`/home`、`/{lang}` …）必须共用一份配额，
        /// 否则等于把配额变相放大好几倍。
        pub fn limitedNamed(
            self: *Self,
            name: []const u8,
            method: []const u8,
            path: []const u8,
            per_min: u16,
            inner: zzig.web.Handler,
        ) !zzig.web.Handler {
            const t = self.throttle orelse return inner;
            var rule = zwaf.ThrottleRule.new(method, path, &.{zwaf.RateValve.ip(per_min, 60)});
            rule.name = name;
            return t.guard(rule, inner);
        }

        pub fn deinit(self: *Self) void {
            if (self.throttle) |t| t.deinit();
            self.throttle = null;
        }
    };
}

// ── 用例 ──────────────────────────────────────────────────────

const testing = std.testing;

const FakeStore = struct {
    fail: bool = false,
    fn listPublished(self: *FakeStore, gpa: std.mem.Allocator) ![]const struct { code: []const u8, name: []const u8 } {
        _ = gpa;
        if (self.fail) return error.Boom;
        return &.{
            .{ .code = "about", .name = "关于我们" },
            .{ .code = "contact", .name = "联系我们" },
        };
    }
};

test "front_site.FooterLinks：首次查库、第二次命中缓存、arena 各自独立" {
    var store = FakeStore{};
    var links = FooterLinks{};
    defer links.deinit(testing.allocator, testing.io);

    var arena_a = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_a.deinit();
    const first = try links.cached(testing.allocator, testing.io, arena_a.allocator(), @as(?*FakeStore, &store), "[t]");
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expectEqualStrings("about", first[0].code);
    try testing.expectEqualStrings("联系", first[1].name[0..6]);

    // 缓存命中：即使仓储开始报错也照样有内容
    store.fail = true;
    var arena_b = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_b.deinit();
    const second = try links.cached(testing.allocator, testing.io, arena_b.allocator(), @as(?*FakeStore, &store), "[t]");
    try testing.expectEqual(@as(usize, 2), second.len);
}

test "front_site.FooterLinks：无仓储 / 查库失败都退化成空列表" {
    var links = FooterLinks{};
    defer links.deinit(testing.allocator, testing.io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const none = try links.cached(testing.allocator, testing.io, arena.allocator(), @as(?*FakeStore, null), "[t]");
    try testing.expectEqual(@as(usize, 0), none.len);

    var broken = FakeStore{ .fail = true };
    const failed = try links.cached(testing.allocator, testing.io, arena.allocator(), @as(?*FakeStore, &broken), "[t]");
    try testing.expectEqual(@as(usize, 0), failed.len);
}

test "front_site.FooterLinks：TTL 过期后重新查库" {
    var store = FakeStore{};
    var links = FooterLinks{ .ttl_ms = 0 };
    defer links.deinit(testing.allocator, testing.io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try links.cached(testing.allocator, testing.io, arena.allocator(), @as(?*FakeStore, &store), "[t]");
    // ttl = 0：下一次一定重查；仓储报错 → 空列表（证明没走缓存）
    store.fail = true;
    const again = try links.cached(testing.allocator, testing.io, arena.allocator(), @as(?*FakeStore, &store), "[t]");
    try testing.expectEqual(@as(usize, 0), again.len);
}

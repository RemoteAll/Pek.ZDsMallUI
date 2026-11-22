//! 后台登录鉴权：**JWT 签发 / 校验 / 登出吊销**（复用 `Pek.ZPermissions`）。
//!
//! 口径（三端互通，别自己写 HMAC）：
//! - 令牌是 **HS256 JWT**，与 C# `NewLife.Web.JwtBuilder`、Rust `Pek.RPermissions`
//!   同一套声明与签名规范（见 `Pek.ZPermissions/docs/互操作契约.md`）；
//! - 声明：`sub`（用户 id）、`name`（登录名）、`displayName`、`isAdmin`，
//!   以及库注入的 `iss` / `exp` / `iat` / `jti`；
//! - **传递方式**：浏览器走 `Cookie`（`HttpOnly; SameSite=Lax`），
//!   脚本/接口走 `Authorization: Bearer <token>`；两者都认；
//! - **登出立即失效**：`SessionKeeper.revoke(token)` 把令牌打进吊销表
//!   （默认内存实现；可注入 `SqliteStore`/`FileStore`/`RedisStore` 做持久化）。
//!
//! 硬口径（沿用 `Pek.ZPermissions`）：**存储不可用一律按纯 JWT 放行**，
//! 只有「明确登出 / 过期 / 被踢线」才拒绝。

const std = @import("std");
const zzig = @import("zzig");
const perms = @import("pek_zpermissions");

const backend = @import("backend.zig");

const router = zzig.web.router;

/// 链路状态键：与 `Pek.ZPermissions.http_auth` 保持一致（生态通用）。
pub const STATE_UID = perms.http_auth.STATE_UID;
/// 链路状态键：登录名（模板 `@Model.userName` 的来源）。
pub const STATE_USER = "user";

/// 是否管理员（`"1"` / `"0"`）：RBAC 判定用 —— 管理员绕过菜单权限检查。
pub const STATE_IS_ADMIN = "auth.isAdmin";
/// 链路状态键：当前令牌（登出用）。
pub const STATE_TOKEN = "auth.token";

/// 会话存储（外部持久化实现：`SqliteStore` / `FileStore` / `RedisStore`）。
pub const SessionStore = perms.session.Store;

/// 鉴权配置。
pub const Options = struct {
    /// 密钥配置 `算法:密钥`（如 `HS256:xxxx`）；**空 = 进程内随机**（仅开发用，重启后旧令牌失效）。
    secret: []const u8 = "",
    /// 签发者（`iss`）。
    issuer: []const u8 = "Pek.ZDsMallUI",
    /// 访问令牌有效期（分钟；默认 120，对齐 NewLife `JwtBuilder` 默认 2 小时）。
    expire_minutes: i64 = 120,
    /// 会话策略（空闲/绝对有效期，影响吊销表 TTL）。
    policy: perms.session.Policy = .{},
    /// Cookie 名（空 = `{area}_token`）。
    cookie_name: []const u8 = "",
    /// 客户端标识（写进会话记录，用于「踢掉某一端」）。
    client: []const u8 = "web",
    /// Cookie 是否加 `Secure`（面板走 HTTPS 时应为 `true`）。
    cookie_secure: bool = false,
    /// 是否**强制**后台页面登录（`false` = 只解析身份、不拦截，保持与 C#/Rust 版一致）。
    require_login: bool = false,
};

/// 签发结果。
pub const Issued = struct {
    /// 令牌文本
    token: []const u8,
    /// 过期时间（Unix 秒）
    expires_at: i64,
    /// 有效期（秒）
    expires_in: i64,
};

/// 已认证主体。
pub const Principal = struct {
    /// `sub`（用户 id 的十进制文本）
    uid: []const u8,
    /// `name`（登录名）
    user_name: []const u8,
    /// `displayName`
    display_name: []const u8,
    /// `isAdmin`
    is_admin: bool,
    /// 原始令牌（登出/审计用）
    token: []const u8,
    /// `exp`
    expires_at: i64,
};

/// 鉴权器（堆分配；挂载后不得移动）。
pub const Auth = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 原始密钥配置（自有内存；`secret.Key` 借用了它）
    secret_raw: []const u8,
    /// 解析后的密钥字节
    secret_key: []const u8,
    /// 签发者
    issuer: []const u8,
    /// 有效期（分钟）
    expire_minutes: i64,
    /// Cookie 名
    cookie_name: []const u8,
    /// 客户端标识
    client: []const u8,
    /// 是否给 Cookie 加 `Secure`
    cookie_secure: bool,
    /// 强制登录
    require_login: bool,
    /// 会话吊销器（默认内存存储）
    keeper: perms.session.Keeper,
    /// 自有的内存存储（未注入外部存储时非 null）
    memory_store: ?*perms.MemoryStore = null,
    /// 区域路由段（如 `biz`）
    area_segment: []const u8,
    /// 登录页路径（`/biz/login/index`）
    login_path: []const u8,

    /// 创建（`area` 用于生成路由前缀与默认 Cookie 名）。
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        area_name: []const u8,
        options: Options,
        external_store: ?perms.SessionStore,
    ) !*Auth {
        const self = try allocator.create(Auth);
        errdefer allocator.destroy(self);

        const area_segment = try @import("area.zig").routeSegment(allocator, area_name);
        errdefer allocator.free(area_segment);

        const secret_raw = if (options.secret.len > 0)
            try allocator.dupe(u8, options.secret)
        else
            try devSecret(allocator);
        errdefer allocator.free(secret_raw);

        const parsed = perms.secret.parse(secret_raw) catch |err| {
            zzig.Logger.err("[ZDsMallUI] JWT 密钥配置非法（{s}）：{s}", .{ secret_raw, perms.secret.describe(err) });
            return error.InvalidJwtSecret;
        };

        const issuer = try allocator.dupe(u8, options.issuer);
        errdefer allocator.free(issuer);

        const cookie_name = if (options.cookie_name.len > 0)
            try allocator.dupe(u8, options.cookie_name)
        else
            try std.fmt.allocPrint(allocator, "{s}_token", .{area_segment});
        errdefer allocator.free(cookie_name);

        const login_path = try std.fmt.allocPrint(allocator, "/{s}/login/index", .{area_segment});
        errdefer allocator.free(login_path);

        var memory_store: ?*perms.MemoryStore = null;
        const store: ?perms.SessionStore = external_store orelse blk: {
            const created = try allocator.create(perms.MemoryStore);
            created.* = perms.MemoryStore.init(allocator);
            memory_store = created;
            break :blk created.store();
        };
        errdefer if (memory_store) |created| {
            created.deinit();
            allocator.destroy(created);
        };

        self.* = .{
            .allocator = allocator,
            .io = io,
            .secret_raw = secret_raw,
            .secret_key = parsed.key,
            .issuer = issuer,
            .expire_minutes = if (options.expire_minutes > 0) options.expire_minutes else 120,
            .cookie_name = cookie_name,
            .client = if (options.client.len > 0) options.client else "web",
            .cookie_secure = options.cookie_secure,
            .require_login = options.require_login,
            .keeper = perms.session.Keeper.init(allocator, store, "zdsmallui:", options.policy),
            .memory_store = memory_store,
            .area_segment = area_segment,
            .login_path = login_path,
        };
        return self;
    }

    /// 释放（令牌表、密钥等全部自有内存）。
    pub fn deinit(self: *Auth) void {
        if (self.memory_store) |store| {
            store.deinit();
            self.allocator.destroy(store);
        }
        self.allocator.free(self.secret_raw);
        self.allocator.free(self.issuer);
        self.allocator.free(self.cookie_name);
        self.allocator.free(self.area_segment);
        self.allocator.free(self.login_path);
        self.allocator.destroy(self);
    }

    /// 签发令牌（`now = 0` 表示取当前时间）。
    pub fn issue(self: *Auth, arena: std.mem.Allocator, user: backend.AdminUser, now_ts: i64) !Issued {
        const now = if (now_ts > 0) now_ts else zzig.DateTime.nowUnix();

        var jti_buffer: [16]u8 = undefined;
        const source = std.Random.IoSource{ .io = self.io };
        const random = source.interface();
        random.bytes(&jti_buffer);
        const jti = std.fmt.bytesToHex(jti_buffer, .lower);

        const expires_at = now + self.expire_minutes * 60;
        const uid_text = try std.fmt.allocPrint(arena, "{d}", .{user.id});

        var payload: std.json.ObjectMap = .{};
        try payload.put(arena, "sub", .{ .string = uid_text });
        try payload.put(arena, "name", .{ .string = user.user_name });
        try payload.put(arena, "displayName", .{ .string = user.display_name });
        try payload.put(arena, "isAdmin", .{ .bool = user.is_admin });

        const builder = perms.Builder{
            .key = self.secret_key,
            .algorithm = "HS256",
            .issuer = self.issuer,
            .expire = expires_at,
            .issued_at = now,
            .id = &jti,
        };
        const token = try builder.encodeObject(arena, &payload, now);

        // 登记会话（存储不可用时静默降级为纯 JWT，不影响登录）
        _ = self.keeper.register(token, user.id, "", self.client, now);

        return .{ .token = token, .expires_at = expires_at, .expires_in = self.expire_minutes * 60 };
    }

    /// 从请求取令牌：**Cookie 优先，其次 `Authorization: Bearer`**。
    pub fn tokenOf(self: *Auth, req: router.Request) ?[]const u8 {
        if (cookieValue(req.header("cookie") orelse "", self.cookie_name)) |token| {
            if (token.len > 0) return token;
        }
        if (req.header("authorization")) |value| {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len > 7 and std.ascii.eqlIgnoreCase(trimmed[0..7], "bearer ")) {
                return std.mem.trim(u8, trimmed[7..], " \t");
            }
        }
        return null;
    }

    /// 校验并返回主体（签名 / 过期由 JWT 负责，登出状态由会话吊销表负责）。
    ///
    /// **返回的切片一律复制到调用方 `arena`**：`Decoded` 自带 arena，`deinit` 之后
    /// 原切片会变成悬垂指针（踩过：首页「当前用户」显示成二进制垃圾）。
    pub fn principal(self: *Auth, arena: std.mem.Allocator, req: router.Request, now_ts: i64) ?Principal {
        const token = self.tokenOf(req) orelse return null;
        const now = if (now_ts > 0) now_ts else zzig.DateTime.nowUnix();

        const builder = perms.Builder{ .key = self.secret_key, .algorithm = "HS256" };
        var decoded = builder.validate(arena, token, now) catch |err| {
            // 过期/篡改是高频正常事件，用 debug 级别，避免刷屏
            zzig.Logger.debug("[ZDsMallUI] 令牌校验失败：{s}", .{perms.jwt.message(err)});
            return null;
        };
        defer decoded.deinit();

        // 吊销表：只有明确登出/踢线才拒绝；存储不可用时放行
        if (!self.keeper.authorize(token, now)) return null;

        const payload = decoded.payload;
        const uid_raw = claimText(payload, "sub") orelse return null;
        const uid = arena.dupe(u8, uid_raw) catch return null;
        const user_name = arena.dupe(u8, claimText(payload, "name") orelse "") catch return null;
        const display_name = arena.dupe(u8, claimText(payload, "displayName") orelse "") catch return null;
        return .{
            .uid = uid,
            .user_name = user_name,
            .display_name = display_name,
            .is_admin = claimBool(payload, "isAdmin") orelse false,
            .token = token,
            .expires_at = claimInt(payload, "exp") orelse 0,
        };
    }

    /// 登出：把当前令牌打进吊销表（无令牌时什么也不做）。
    pub fn logout(self: *Auth, req: router.Request, now_ts: i64) void {
        const token = self.tokenOf(req) orelse return;
        const now = if (now_ts > 0) now_ts else zzig.DateTime.nowUnix();
        _ = self.keeper.revoke(token, now);
    }

    /// 登录成功后下发的 `Set-Cookie`。
    pub fn cookieHeader(self: *Auth, arena: std.mem.Allocator, token: []const u8, max_age_secs: i64) ![]const u8 {
        return std.fmt.allocPrint(
            arena,
            "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}{s}",
            .{ self.cookie_name, token, if (max_age_secs > 0) max_age_secs else 0, if (self.cookie_secure) "; Secure" else "" },
        );
    }

    /// 登出时下发的 `Set-Cookie`（清空）。
    pub fn clearedCookieHeader(self: *Auth, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(
            arena,
            "{s}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0{s}",
            .{ self.cookie_name, if (self.cookie_secure) "; Secure" else "" },
        );
    }

    /// 给响应追加 `Set-Cookie`（返回新响应，原响应不改）。
    pub fn withCookie(
        self: *Auth,
        arena: std.mem.Allocator,
        response: router.Response,
        cookie: []const u8,
    ) !router.Response {
        _ = self;
        const headers = try arena.alloc(std.http.Header, response.headers.len + 1);
        @memcpy(headers[0..response.headers.len], response.headers);
        headers[response.headers.len] = .{ .name = "set-cookie", .value = cookie };
        var out = response;
        out.headers = headers;
        return out;
    }

    /// 转成路由中间件：解析身份写入链路状态；`require_login` 时拦截后台页面。
    pub fn middleware(self: *Auth) router.Middleware {
        return .{ .ctx = @ptrCast(self), .call = invoke };
    }

    /// 直接跑一次中间件（测试用，绕过 Router）。
    pub fn invokeForTest(self: *Auth, c: *router.Ctx, next: router.Next) anyerror!router.Response {
        return invoke(@ptrCast(self), c, next);
    }

    fn invoke(raw: ?*anyopaque, c: *router.Ctx, next: router.Next) anyerror!router.Response {
        const self: *Auth = @ptrCast(@alignCast(raw orelse return error.MissingAuth));
        const now = zzig.DateTime.nowUnix();

        if (self.principal(c.arena, c.req, now)) |identity| {
            c.setState(STATE_UID, identity.uid) catch {};
            c.setState(STATE_USER, identity.user_name) catch {};
            c.setState(STATE_TOKEN, identity.token) catch {};
            c.setState(STATE_IS_ADMIN, if (identity.is_admin) "1" else "0") catch {};
        } else if (self.require_login and self.isGuardedPath(c.req.path)) {
            const target = try std.fmt.allocPrint(
                c.arena,
                "{s}?returnUrl={s}",
                .{ self.login_path, try zzig.url.encode(c.arena, c.req.path) },
            );
            return router.Response.redirectAlloc(c.arena, target);
        }
        return next.run(c);
    }

    /// 是否需要登录：区域内的页面（`/{area}/…`），但登录相关动作豁免。
    pub fn isGuardedPath(self: *Auth, path: []const u8) bool {
        const login_prefix = std.fmt.allocPrint(self.allocator, "/{s}/login", .{self.area_segment}) catch return false;
        defer self.allocator.free(login_prefix);
        if (zzig.ascii.startsWithIgnoreCase(path, login_prefix)) return false;

        const area_prefix = std.fmt.allocPrint(self.allocator, "/{s}/", .{self.area_segment}) catch return false;
        defer self.allocator.free(area_prefix);
        return zzig.ascii.startsWithIgnoreCase(path, area_prefix);
    }
};

// ————— 内部工具 —————

/// 从 `Cookie` 请求头取指定名字的值（转发 `zzig.cookie`，保留本模块入口便于测试/消费方）。
pub fn cookieValue(header: []const u8, name: []const u8) ?[]const u8 {
    return zzig.cookie.value(header, name);
}

fn claimText(payload: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = payload.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn claimBool(payload: std.json.ObjectMap, name: []const u8) ?bool {
    const value = payload.get(name) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn claimInt(payload: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = payload.get(name) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        else => null,
    };
}

/// RFC 3986 百分号编码（转发 `zzig.url.encode`，语义与之前一致）。
pub fn percentEncode(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    return zzig.url.encode(arena, text);
}

/// 开发用随机密钥：`HS256:<64 位十六进制>`（重启后旧令牌失效，生产必须显式配置）。
fn devSecret(allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [32]u8 = undefined;
    const io = zzig.compat.currentIo();
    const source = std.Random.IoSource{ .io = io };
    const random = source.interface();
    random.bytes(&buffer);
    const hex = std.fmt.bytesToHex(buffer, .lower);
    zzig.Logger.warn("[ZDsMallUI] 未配置 JWT 密钥：使用进程内随机密钥（重启后旧令牌全部失效，生产请调用 builder.jwtSecret()）", .{});
    return std.fmt.allocPrint(allocator, "HS256:{s}", .{hex});
}

// ————— 测试 —————

const testing = std.testing;

fn testUser() backend.AdminUser {
    return .{ .id = 7, .user_name = "admin", .display_name = "管理员", .is_admin = true };
}

fn makeAuth(arena: std.mem.Allocator) !*Auth {
    _ = arena;
    return Auth.init(testing.allocator, testing.io, "Biz", .{ .secret = "HS256:test-secret-key" }, null);
}

fn reqWithCookie(arena: std.mem.Allocator, cookie: []const u8) !router.Request {
    const headers = try arena.alloc(std.http.Header, 1);
    headers[0] = .{ .name = "cookie", .value = cookie };
    return .{ .method = "GET", .path = "/biz/home/index", .headers = headers };
}

test "鉴权：签发后可校验，声明齐全" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const auth = try makeAuth(arena);
    defer auth.deinit();

    const issued = try auth.issue(arena, testUser(), 1_700_000_000);
    try testing.expectEqual(@as(i64, 1_700_000_000 + 120 * 60), issued.expires_at);

    const principal = auth.principal(arena, try reqWithCookie(arena, try std.fmt.allocPrint(arena, "biz_token={s}", .{issued.token})), 1_700_000_100) orelse
        return error.TestExpectedPrincipal;
    try testing.expectEqualStrings("7", principal.uid);
    try testing.expectEqualStrings("admin", principal.user_name);
    try testing.expectEqualStrings("管理员", principal.display_name);
    try testing.expect(principal.is_admin);
}

test "鉴权：Authorization: Bearer 也能校验" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const auth = try makeAuth(arena);
    defer auth.deinit();
    const issued = try auth.issue(arena, testUser(), 1_700_000_000);

    const bearer = try arena.alloc(std.http.Header, 1);
    bearer[0] = .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{issued.token}) };
    const request = router.Request{ .method = "GET", .path = "/biz/home/index", .headers = bearer };
    try testing.expect(auth.principal(arena, request, 1_700_000_100) != null);
}

test "鉴权：过期与篡改令牌都拒绝" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const auth = try makeAuth(arena);
    defer auth.deinit();
    const issued = try auth.issue(arena, testUser(), 1_700_000_000);

    // 过期（exp = start + 7200）
    const cookie = try std.fmt.allocPrint(arena, "biz_token={s}", .{issued.token});
    try testing.expect(auth.principal(arena, try reqWithCookie(arena, cookie), 1_700_000_000 + 7201) == null);

    // 篡改最后一位签名
    var tampered = try arena.dupe(u8, issued.token);
    tampered[tampered.len - 1] = if (tampered[tampered.len - 1] == 'A') 'B' else 'A';
    const bad_cookie = try std.fmt.allocPrint(arena, "biz_token={s}", .{tampered});
    try testing.expect(auth.principal(arena, try reqWithCookie(arena, bad_cookie), 1_700_000_100) == null);
}

test "鉴权：登出后同一令牌立即失效（吊销表）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const auth = try makeAuth(arena);
    defer auth.deinit();
    const issued = try auth.issue(arena, testUser(), 1_700_000_000);
    const cookie = try std.fmt.allocPrint(arena, "biz_token={s}", .{issued.token});
    const request = try reqWithCookie(arena, cookie);

    try testing.expect(auth.principal(arena, request, 1_700_000_100) != null);

    auth.logout(request, 1_700_000_200);
    try testing.expect(auth.principal(arena, request, 1_700_000_300) == null);
}

test "鉴权：Cookie 属性（HttpOnly / SameSite / Max-Age）与清除" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const auth = try makeAuth(arena);
    defer auth.deinit();

    const header = try auth.cookieHeader(arena, "abc.def.ghi", 7200);
    try testing.expect(std.mem.startsWith(u8, header, "biz_token=abc.def.ghi;"));
    try testing.expect(std.mem.indexOf(u8, header, "HttpOnly") != null);
    try testing.expect(std.mem.indexOf(u8, header, "SameSite=Lax") != null);
    try testing.expect(std.mem.indexOf(u8, header, "Max-Age=7200") != null);
    try testing.expect(std.mem.indexOf(u8, header, "Secure") == null);

    const cleared = try auth.clearedCookieHeader(arena);
    try testing.expect(std.mem.indexOf(u8, cleared, "Max-Age=0") != null);
}

test "鉴权：Cookie 头解析" {
    try testing.expectEqualStrings("v1", cookieValue("a=v1; biz_token=v2", "a").?);
    try testing.expectEqualStrings("v2", cookieValue("a=v1; biz_token=v2", "biz_token").?);
    try testing.expect(cookieValue("a=v1", "biz_token") == null);
    try testing.expect(cookieValue("", "biz_token") == null);
}

test "鉴权：中间件写入 user 状态（不强制登录时不拦截）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const auth = try makeAuth(arena);
    defer auth.deinit();
    const issued = try auth.issue(arena, testUser(), 0);
    const cookie = try std.fmt.allocPrint(arena, "biz_token={s}", .{issued.token});

    const headers = try arena.alloc(std.http.Header, 1);
    headers[0] = .{ .name = "cookie", .value = cookie };
    var ctx = try router.Ctx.build(arena, .{ .method = "GET", .path = "/biz/home/index", .headers = headers });

    const Next = struct {
        fn run(_: *anyopaque, c: *router.Ctx) anyerror!router.Response {
            return router.Response.html(c.stateValue("user") orelse "");
        }
    };
    var marker: u8 = 0;
    const next = router.Next{ .ctx = @ptrCast(&marker), .call = Next.run };

    const response = try auth.invokeForTest(&ctx, next);
    try testing.expectEqualStrings("admin", response.body);
    try testing.expectEqualStrings("7", ctx.stateValue(STATE_UID).?);
}

test "鉴权：require_login 时后台页面跳登录页并带 returnUrl" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const auth = try Auth.init(testing.allocator, testing.io, "Biz", .{
        .secret = "HS256:test-secret-key",
        .require_login = true,
    }, null);
    defer auth.deinit();

    var ctx = try router.Ctx.build(arena, .{ .method = "GET", .path = "/biz/config/index" });
    const Next = struct {
        fn run(_: *anyopaque, _: *router.Ctx) anyerror!router.Response {
            return router.Response.html("reached");
        }
    };
    var marker: u8 = 0;
    const next = router.Next{ .ctx = @ptrCast(&marker), .call = Next.run };

    const response = try auth.invokeForTest(&ctx, next);
    try testing.expectEqual(std.http.Status.found, response.status);
    var location: ?[]const u8 = null;
    for (response.headers) |header| {
        if (std.mem.eql(u8, header.name, "location")) location = header.value;
    }
    try testing.expect(std.mem.indexOf(u8, location.?, "/biz/login/index?returnUrl=") != null);
    try testing.expect(std.mem.indexOf(u8, location.?, "%2Fbiz%2Fconfig%2Findex") != null);

    // 登录页本身豁免
    var login_ctx = try router.Ctx.build(arena, .{ .method = "GET", .path = "/biz/login/index" });
    const allowed = try auth.invokeForTest(&login_ctx, next);
    try testing.expectEqualStrings("reached", allowed.body);
}

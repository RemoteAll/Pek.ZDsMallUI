//! 后台登录 / 退出控制器（对应 C# `Areas/Admin/Controllers/LoginController`）。
//!
//! | 路由（`{area}` 由配置决定） | 说明 |
//! |---|---|
//! | `GET /{area}/login/index` | 登录页 |
//! | `POST /{area}/login/login` | 登录（成功：表单 302 + `Set-Cookie`；Ajax 返回 JSON 信封，含 `token`） |
//! | `POST|GET /{area}/login/logout` | 退出登录（吊销 JWT + 清 Cookie；Ajax JSON，表单 302 回登录页） |
//! | `GET /{area}/login/status` | 当前登录状态（前端与冒烟用） |
//!
//! **JWT 口径**：登录成功即签发 HS256 令牌（复用 `Pek.ZPermissions`，与 C#/Rust 字节级互通），
//! 浏览器走 `Cookie: {area}_token`（HttpOnly/SameSite=Lax），脚本走 `Authorization: Bearer <token>`；
//! 登出会把令牌写进吊销表，**同一令牌立即失效**。

const std = @import("std");
const zzig = @import("zzig");

const area_mod = @import("../../../src/deps.zig").area;
const auth_mod = @import("../../../src/deps.zig").auth;
const captcha_mod = @import("../../../src/deps.zig").captcha;
const admin_area = @import("AdminArea.zig");

const router = zzig.web.router;
const controller_mod = zzig.web.controller;
const ActionResult = zzig.web.controller.ActionResult;

/// 取客户端 IP（已由 `zzig.http.server` 按 `trust_forwarded_for` 穿透反代）；
/// 拿不到时用固定串，保证「无 IP」的请求仍受 IP 维度封禁约束。
fn clientIp(c: *router.Ctx) []const u8 {
    const addr = c.req.remote_addr orelse return "unknown";
    // `[::1]:8080` → `[::1]`
    if (std.mem.indexOfScalar(u8, addr, ']')) |close| {
        if (close + 1 < addr.len and addr[close + 1] == ':') return addr[0 .. close + 1];
        return addr;
    }
    // 裸 IPv6（多个冒号）原样返回；IPv4:port 去掉端口
    const first = std.mem.indexOfScalar(u8, addr, ':') orelse return addr;
    if (std.mem.lastIndexOfScalar(u8, addr, ':').? != first) return addr;
    return addr[0..first];
}

/// 后台登录控制器。
pub const LoginController = struct {
    /// `GET /{area}/login/index`：渲染登录页（回填 `?returnUrl=`）。
    pub fn index(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);
        const return_url = admin_area.safeRedirect(c.queryValue("returnUrl") orelse "") orelse "";
        const model = try buildModel(self, c.arena, admin_area.currentUser(c), null, return_url, clientIp(c), "");
        return admin_area.renderView(self, c, "Login", "Index", model);
    }

    /// `POST /{area}/login/login`：校验账号，成功签发 JWT。
    pub fn login(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);

        const user_name = std.mem.trim(u8, c.formValue("UserName") orelse "", " \t\r\n");
        const pass = c.formValue("Password") orelse "";
        const return_url = std.mem.trim(u8, c.formValue("returnUrl") orelse "", " \t\r\n");
        const client_ip = clientIp(c);
        const now_ms = zzig.compat.milliTimestamp();
        // 防爆破：命中封禁则直接回 429（不查库、不耗 CPU 做口令散列）
        if (self.login_guard) |guard| {
            if (guard.retryAfterSeconds(user_name, client_ip, now_ms)) |secs| {
                zzig.Logger.warn("[ZDsMallUI] 登录被拒（{s}@{s}）：失败次数过多，还需 {d} 秒", .{ user_name, client_ip, secs });
                const msg = try std.fmt.allocPrint(c.arena, "尝试次数过多，请 {d} 秒后再试", .{secs});
                if (admin_area.isAjax(c)) {
                    return .{ .response = try controller_mod.jsonResult(c.arena, 429, msg, null) };
                }
                const model = try buildModel(self, c.arena, admin_area.currentUser(c), msg, admin_area.safeRedirect(return_url) orelse "", client_ip, user_name);
                return admin_area.renderView(self, c, "Login", "Index", model);
            }
        }

        // 验证码：失败达阈值后必须填对（一次性消费；大小写不敏感）
        // 放在查库之前 —— 攻击者连口令散列都拿不到，省 CPU 也防「换 IP 继续撞库」。
        if (needsCaptcha(self, user_name, client_ip)) {
            const cookie_name = try self.captchaCookieName(c.arena);
            const captcha_id = zzig.cookie.value(c.req.header("cookie") orelse "", cookie_name) orelse "";
            const answer = c.formValue("Captcha") orelse "";
            const accepted = if (self.captcha) |store| store.take(captcha_id, answer, now_ms) else true;
            if (!accepted) {
                if (self.login_guard) |guard| {
                    guard.recordFailure(user_name, client_ip, now_ms) catch {};
                }
                zzig.Logger.warn("[ZDsMallUI] 登录被拒（{s}@{s}）：验证码不正确或已过期", .{ user_name, client_ip });
                const msg = "验证码不正确或已过期，请重新输入";
                if (admin_area.isAjax(c)) {
                    return .{ .response = try controller_mod.jsonResult(c.arena, 400, msg, null) };
                }
                const model = try buildModel(self, c.arena, admin_area.currentUser(c), msg, admin_area.safeRedirect(return_url) orelse "", client_ip, user_name);
                return admin_area.renderView(self, c, "Login", "Index", model);
            }
        }

        switch (try self.backend.login(c.arena, user_name, pass)) {
            .ok => |user| {
                if (self.login_guard) |guard| guard.recordSuccess(user.user_name, client_ip);
                // 签发 JWT（未装配鉴权器时跳过，保持纯登录行为）
                const issued: ?auth_mod.Issued = if (self.auth) |auth|
                    auth.issue(c.arena, user, 0) catch |err| blk: {
                        zzig.Logger.err("[ZDsMallUI] 登录成功但令牌签发失败（用户 {s}）：{s}", .{ user.user_name, @errorName(err) });
                        break :blk null;
                    }
                else
                    null;

                if (admin_area.isAjax(c)) {
                    var data: std.Io.Writer.Allocating = .init(c.arena);
                    defer data.deinit();
                    try data.writer.print("{{\"id\":{d},\"userName\":", .{user.id});
                    try zzig.web.value.writeJsonString(&data.writer, user.user_name);
                    try data.writer.writeAll(",\"displayName\":");
                    try zzig.web.value.writeJsonString(&data.writer, user.display_name);
                    try data.writer.writeAll(",\"isAdmin\":");
                    try data.writer.writeAll(if (user.is_admin) "true" else "false");
                    try data.writer.writeAll(",\"home\":");
                    try zzig.web.value.writeJsonString(&data.writer, self.homePath());
                    if (issued) |token| {
                        try data.writer.writeAll(",\"token\":");
                        try zzig.web.value.writeJsonString(&data.writer, token.token);
                        try data.writer.writeAll(",\"tokenType\":\"Bearer\",");
                        try data.writer.print("\"expiresIn\":{d},\"expiresAt\":{d}", .{ token.expires_in, token.expires_at });
                    }
                    try data.writer.writeAll("}");

                    var response = try controller_mod.jsonResult(c.arena, 0, "", try data.toOwnedSlice());
                    // Ajax 同样下发 Cookie：浏览器端后续页面刷新也能维持登录
                    if (self.auth) |auth| {
                        if (issued) |token| {
                            response = try auth.withCookie(c.arena, response, try auth.cookieHeader(c.arena, token.token, token.expires_in));
                        }
                    }
                    return .{ .response = response };
                }

                const target = admin_area.safeRedirect(return_url) orelse self.homePath();
                var response = try router.Response.redirectAlloc(c.arena, target);
                if (self.auth) |auth| {
                    if (issued) |token| {
                        response = try auth.withCookie(c.arena, response, try auth.cookieHeader(c.arena, token.token, token.expires_in));
                    }
                }
                return .{ .response = response };
            },
            .err => |message| {
                if (self.login_guard) |guard| {
                    guard.recordFailure(user_name, client_ip, now_ms) catch |e| {
                        zzig.Logger.err("[ZDsMallUI] 登录失败计数写入失败（{s}@{s}）：{s}", .{ user_name, client_ip, @errorName(e) });
                    };
                }
                zzig.Logger.warn("[ZDsMallUI] 登录失败（{s}@{s}）：{s}", .{ user_name, client_ip, message });
                if (admin_area.isAjax(c)) {
                    return .{ .response = try controller_mod.jsonResult(c.arena, 401, message, null) };
                }
                const model = try buildModel(self, c.arena, admin_area.currentUser(c), message, admin_area.safeRedirect(return_url) orelse "", client_ip, user_name);
                return admin_area.renderView(self, c, "Login", "Index", model);
            },
        }
    }

    /// `POST|GET /{area}/login/logout`：吊销当前令牌并清 Cookie。
    pub fn logout(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);

        if (self.auth) |auth| {
            const had_token = auth.tokenOf(c.req) != null;
            auth.logout(c.req, 0);
            zzig.Logger.info("[ZDsMallUI] 用户 {s} 退出登录（吊销令牌：{s}）", .{
                admin_area.currentUser(c),
                if (had_token) "是" else "无令牌",
            });
        }

        if (admin_area.isAjax(c)) {
            var response = try controller_mod.jsonResult(c.arena, 0, "已退出登录", null);
            if (self.auth) |auth| {
                response = try auth.withCookie(c.arena, response, try auth.clearedCookieHeader(c.arena));
            }
            return .{ .response = response };
        }

        const login_path = try self.loginPath(c.arena);
        var response = try router.Response.redirectAlloc(c.arena, login_path);
        if (self.auth) |auth| {
            response = try auth.withCookie(c.arena, response, try auth.clearedCookieHeader(c.arena));
        }
        return .{ .response = response };
    }

    /// `GET /{area}/login/status`：当前登录状态。
    pub fn status(raw: ?*anyopaque, c: *router.Ctx) anyerror!ActionResult {
        const self = admin_area.castSelf(raw);

        var data: std.Io.Writer.Allocating = .init(c.arena);
        defer data.deinit();

        if (self.auth) |auth| {
            if (auth.principal(c.arena, c.req, 0)) |principal| {
                try data.writer.writeAll("{\"authenticated\":true,\"userName\":");
                try zzig.web.value.writeJsonString(&data.writer, principal.user_name);
                try data.writer.writeAll(",\"displayName\":");
                try zzig.web.value.writeJsonString(&data.writer, principal.display_name);
                try data.writer.writeAll(",\"isAdmin\":");
                try data.writer.writeAll(if (principal.is_admin) "true" else "false");
                try data.writer.print(",\"expiresAt\":{d},\"uid\":", .{principal.expires_at});
                try zzig.web.value.writeJsonString(&data.writer, principal.uid);
                try data.writer.writeAll("}");
                return .{ .response = try controller_mod.jsonResult(c.arena, 0, "", try data.toOwnedSlice()) };
            }
        }
        try data.writer.writeAll("{\"authenticated\":false}");
        return .{ .response = try controller_mod.jsonResult(c.arena, 0, "", try data.toOwnedSlice()) };
    }

    /// 组装登录页模型（控制器与测试共用）。
    pub fn buildModel(
        self: *admin_area.AdminArea,
        arena: std.mem.Allocator,
        user: []const u8,
        error_message: ?[]const u8,
        return_url: []const u8,
        client_ip: []const u8,
        fail_user: []const u8,
    ) !zzig.web.Value {
        const display_name = try self.backend.displayName(arena);
        const route = try area_mod.routePrefix(arena, self.areaName());

        var builder = zzig.web.ObjectBuilder.init(arena);
        try builder.str("title", try std.fmt.allocPrint(arena, "登录 - {s}", .{display_name}));
        try builder.str("displayName", display_name);
        try builder.str("areaName", self.areaName());
        try builder.str("areaRoute", route);
        try builder.str("userName", user);
        try builder.str("returnUrl", return_url);
        try builder.boolean("hasError", error_message != null);
        try builder.str("error", error_message orelse "");
        try builder.boolean("requireCaptcha", needsCaptcha(self, fail_user, client_ip));
        try builder.str("captchaUrl", "/CaptCha/GetCheckCode");
        try builder.put("lang", try admin_area.langObject(self, arena, user));
        return builder.finish();
    }
};

/// 是否需要验证码：已启用 + 失败次数达到阈值（用户/ IP 取大）。
fn needsCaptcha(self: *admin_area.AdminArea, fail_user: []const u8, client_ip: []const u8) bool {
    if (self.captcha == null) return false;
    const guard = self.login_guard orelse return false;
    if (fail_user.len == 0 and client_ip.len == 0) return false;
    return guard.failCount(fail_user, client_ip, zzig.compat.milliTimestamp()) >= captcha_mod.require_for_fails;
}

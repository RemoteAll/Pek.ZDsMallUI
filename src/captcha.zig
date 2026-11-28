//! 薄壳：图形验证码的**实现**已下沉到 **`zzig.web.captcha`**（内存 TTL 存储 + SVG 渲染 + 一次性消费）。
//!
//! 为什么下沉：同一份「`GetVierificationCode` 契约」被实现过两次 ——
//! 本项目一份（SVG）、`HlktechFenLiu/zig` 一份（GIF，377 行）；两个项目都是 Zig + zzig，
//! 而那个项目**不依赖后台框架**，验证码又属于纯 HTTP 能力，所以正确的位置是 `zzig`。
//! 这里只保留后台自己的**策略**：失败几次后才要求验证码（与 `login_guard` 的封禁阈值配套）。
//!
//! 口径（与 C# `CaptchaController.GetVierificationCode` 一致）：
//! - 返回的 `id` 放 Cookie（`HttpOnly`），答案只在内存里比对，**不落 Cookie**；
//! - **一次性消费**（校验后立刻删除，防重放）；过期按 TTL 判；
//! - 字符集去掉 `0/O/1/I/l` 这类易混字符；
//! - 条目有上限：先清过期，仍超限整表清空（宁可少拦一次也不能被打爆）。

const std = @import("std");
const zzig = @import("zzig");

pub const Options = zzig.web.captcha.Options;
pub const Store = zzig.web.captcha.Store;
pub const Issue = zzig.web.captcha.Issue;
pub const renderSvg = zzig.web.captcha.renderSvg;

/// 达到多少次失败后才要求验证码（低于封禁阈值：用户 5 / IP 10）。
pub const require_for_fails: u32 = 3;

test "captcha 薄壳：签发→校验→一次性消费（指向 zzig 实现）" {
    const testing = std.testing;
    var store = Store.init(testing.allocator, .{});
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const issue = try store.issue(arena.allocator(), 1_000_000);
    try testing.expectEqual(@as(usize, 4), issue.code.len);
    try testing.expect(store.take(issue.id, issue.code, 1_000_001));
    try testing.expect(!store.take(issue.id, issue.code, 1_000_002));
}

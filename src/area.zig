//! Area（区域）命名与约定（对齐 ASP.NET Core Areas / C# `Pek.NCubeUI.Areas.Admin`）。
//!
//! C# 参考工程的区域名由配置决定（`DHSetting.Current.AdminArea`，默认 `Admin`），
//! 路由是 `/{area}/{controller}/{action}`，视图是 `Areas/{Area}/Views/{Controller}/{Action}.cshtml`。
//! Zig 侧保持同一套两级约定，但**区域名在装配时由消费方决定**（可来自它自己的配置/环境变量）：
//!
//! ```zig
//! var ui = try pek_zdsmallui.DsMallUi.builder(allocator, io).adminArea("Biz").build();
//! // → /biz/config/index、视图 Views/Biz/...（缺失时回退 Views/Admin/...）
//! ```
//!
//! 命名规则（严格校验，避免歧义进路由）：
//! - 非空，只允许 ASCII 字母、数字、`_`、`-`，且首字符必须是字母；
//! - 存储/视图目录用 **Pascal 化**（`biz` → `Biz`），URL 段用 **小写**（`/biz/...`）；
//! - 视图解析带回退：`{Area}/…` 不存在时用 `Admin/…`（内置默认视图只在 `Admin` 下维护）。

const std = @import("std");

/// 默认后台区域名（与 C# `AdminArea.AreaName` 默认值一致）。
pub const DEFAULT_AREA = "Admin";

/// 区域名校验错误。
pub const AreaError = error{
    /// 区域名不可为空
    Empty,
    /// 区域名必须以字母开头
    MustStartWithLetter,
    /// 区域名只能包含字母/数字/下划线/连字符
    InvalidCharacters,
};

/// 错误 → 面向运维的中文文案（含触发条件，便于定位配置来源）。
pub fn describe(err: AreaError) []const u8 {
    return switch (err) {
        error.Empty => "区域名不可为空（配置项 AdminArea 未填）",
        error.MustStartWithLetter => "区域名必须以字母开头（如 Admin / Biz）",
        error.InvalidCharacters => "区域名只能包含字母、数字、下划线、连字符（不允许 / 与空格）",
    };
}

/// 规范化区域名：去空白、首字符大写、其余小写；非法输入返回明确错误。
///
/// - `"Biz"` / `"biz"` / `" BIZ "` → `"Biz"`
/// - `""` / `"1admin"` / `"a/b"` → 错误
pub fn normalize(allocator: std.mem.Allocator, raw: []const u8) (AreaError || std.mem.Allocator.Error)![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.Empty;

    const first = trimmed[0];
    if (!std.ascii.isAlphabetic(first)) return error.MustStartWithLetter;
    for (trimmed) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidCharacters;
    }

    const out = try allocator.alloc(u8, trimmed.len);
    out[0] = std.ascii.toUpper(first);
    for (trimmed[1..], 1..) |c, index| out[index] = std.ascii.toLower(c);
    return out;
}

/// 路由段（小写、无前导斜杠）：`"Biz"` → `"biz"`。
pub fn routeSegment(allocator: std.mem.Allocator, area: []const u8) std.mem.Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, area, " \t\r\n");
    const out = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |c, index| out[index] = std.ascii.toLower(c);
    return out;
}

/// 路由前缀（带前导斜杠）：`"Biz"` → `"/biz"`。
pub fn routePrefix(allocator: std.mem.Allocator, area: []const u8) std.mem.Allocator.Error![]u8 {
    const segment = try routeSegment(allocator, area);
    defer allocator.free(segment);
    return std.fmt.allocPrint(allocator, "/{s}", .{segment});
}

/// 是否默认区域（`Admin`，大小写与首尾空白不敏感）。
pub fn isDefault(area: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, area, " \t\r\n"), DEFAULT_AREA);
}

// ————— 测试 —————

const testing = std.testing;

test "区域名：大小写与空白规范化" {
    const cases = [_]struct { raw: []const u8, want: []const u8 }{
        .{ .raw = " Biz ", .want = "Biz" },
        .{ .raw = "biz", .want = "Biz" },
        .{ .raw = "BIZ", .want = "Biz" },
        .{ .raw = "my_area-2", .want = "My_area-2" },
        .{ .raw = "Admin", .want = "Admin" },
    };
    for (cases) |case| {
        const got = try normalize(testing.allocator, case.raw);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case.want, got);
    }
}

test "区域名：非法输入必须拒绝" {
    try testing.expectError(error.Empty, normalize(testing.allocator, ""));
    try testing.expectError(error.Empty, normalize(testing.allocator, "   "));
    try testing.expectError(error.MustStartWithLetter, normalize(testing.allocator, "1admin"));
    try testing.expectError(error.InvalidCharacters, normalize(testing.allocator, "a/b"));
    // 中文不属于 ASCII 字母：明确拒绝（路由段无法安全承载）
    try testing.expectError(error.MustStartWithLetter, normalize(testing.allocator, "区域"));
}

test "区域名：路由前缀与默认判定" {
    const segment = try routeSegment(testing.allocator, "Biz");
    defer testing.allocator.free(segment);
    try testing.expectEqualStrings("biz", segment);

    const prefix = try routePrefix(testing.allocator, "Biz");
    defer testing.allocator.free(prefix);
    try testing.expectEqualStrings("/biz", prefix);

    try testing.expect(isDefault(" admin "));
    try testing.expect(!isDefault("Biz"));
}

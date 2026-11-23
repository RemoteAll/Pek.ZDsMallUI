//! 成员 / 角色 / 菜单三张表的**表名映射**（可替换点）。
//!
//! ## 为什么要这一层
//!
//! `User` / `Role` / `Menu` 的表结构来自 `Pek.ZCode` 的 `membership/Member.xml`（与 C# 同源），
//! 后台框架直接读写它们。但不同业务系统常常需要：
//! - 自己的用户表（多几列 / 多一张扩展表 / 已有历史表名 `SysUser`）；
//! - 自己的角色模型（比如按项目分组，而不是全局角色）；
//! - 自己的菜单来源（配置中心下发，而不是本库的 `Menu` 表）。
//!
//! 把它们写死成字面量，业务就只能改框架源码（2026-11-23 用户提出：
//! 「用户相关和菜单、权限等是不是可以考虑不要放在 Pek.ZCode 中了……会不会限制业务系统本身的发挥」）。
//! 所以这里给一层**表名映射**：默认值与 C# 完全一致（`User` / `Role` / `Menu`），
//! 业务通过 `admin_area.setTables(.{ .user = "SysUser" })` 即可指到自己的表，
//! **不改框架源码、不动 `Member.xml`**。
//!
//! ## 为什么只开放这三张
//!
//! `Config` / `UserDetail` / `Session` 属于**后台框架自己的表**（`assets/Model.xml`）：
//! 换掉它们等于换框架实现（配置读写、用户扩展列、会话吊销），不属于「业务发挥」的范畴。
//!
//! ## 约束（换表时业务要满足）
//!
//! 表名可以换，**列名仍需与 `Member.xml` 一致**（`ID` / `Name` / `Password` / `RoleID` /
//! `DataScope` / `DataDepartmentIds` / `Ex4` …）。原因：这些列被登录、权限判定、数据范围、
//! 菜单渲染直接引用，且与 C# 版读写同一份库。要加列请在自己的 `Model.xml` 里给同名的表追加。
//!
//! 真到了「连列都要不一样」的程度，说明该业务不该复用这套后台，应该自己实现
//! `membership/provider.zig` 的 `UserStore`（注入点已经存在）。

const std = @import("std");

/// 三张成员域表的表名。默认值 = C# `Member.xml` 的表名，换成别的只需 `setTables`。
pub const Tables = struct {
    /// 账号表（`User`）：登录、`RoleID` 归属、`Ex1=1` 标记后台账号。
    user: []const u8 = "User",
    /// 角色表（`Role`）：`Permission` 权限串 + `DataScope` / `DataDepartmentIds` / `Ex4` 数据范围。
    role: []const u8 = "Role",
    /// 菜单表（`Menu`）：目录（`Type=1`）/ 菜单项（`Type=2`），渲染的后台导航以它为准。
    menu: []const u8 = "Menu",

    /// 是否是默认表名（用于「要不要提示业务已换表」这类判断）。
    pub fn isDefault(self: Tables) bool {
        return std.mem.eql(u8, self.user, "User") and
            std.mem.eql(u8, self.role, "Role") and
            std.mem.eql(u8, self.menu, "Menu");
    }
};

test "表名映射：默认值即 C# 口径，换名字不影响判定" {
    const d = Tables{};
    try std.testing.expect(d.isDefault());
    try std.testing.expectEqualStrings("User", d.user);
    try std.testing.expectEqualStrings("Role", d.role);
    try std.testing.expectEqualStrings("Menu", d.menu);

    const custom = Tables{ .user = "SysUser" };
    try std.testing.expect(!custom.isDefault());
    try std.testing.expectEqualStrings("SysUser", custom.user);
    try std.testing.expectEqualStrings("Role", custom.role);
}

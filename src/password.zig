//! 口令散列：**唯一实现在 `Pek.ZCode` 的 `membership/password.zig`**，本文件只做签名适配。
//!
//! 历史（2026-11-22 下沉）：本库曾自带一份 5 档实现，`Pek.ZCode` 里另有一份 —— 同一算法两份代码
//! 必然漂移（当时 ZCode 版还不认 `$sha512$`，而那是 C# 的默认档）。现在只留 ZCode 一份，
//! 本文件保留既有调用签名（`hash(allocator, io, pw)` / `verifyAndUpgrade(allocator, io, provider, …)`）
//! 免得各调用点跟着改。
//!
//! 支持的档位（与 C# `SaltPasswordProvider` 一致）：`md5` / `sha1` / `sha512` /
//! `md5+sha1`（写入默认）/ `md5+sha512`，外加裸 MD5 与明文（登录时自动升级为 `$md5+sha1$`）。

const std = @import("std");
const core = @import("zcode").membership.password;

/// 验证 + 按需升级的结果（`upgraded` 为新散列，调用方负责释放）。
pub const UpgradeResult = core.VerifyResult;

/// 生成新口令散列（`$md5+sha1$盐$散列`）。
///
/// `io` 只为兼容既有调用方保留（ZCode 版用进程级 CSPRNG 取盐，不需要 io）。
pub fn hash(allocator: std.mem.Allocator, io: std.Io, password: []const u8) ![]u8 {
    _ = io;
    return core.hashAlloc(allocator, password);
}

/// 校验口令（明文 / 裸 MD5 / `$算法$盐$散列` 五档都认；常量时间比较）。
pub fn verify(password: []const u8, stored: []const u8) bool {
    return core.verify(password, stored);
}

/// 验证 + 按需升级（旧档 / 旧格式登录成功后自动改写为 `$md5+sha1$`）。
///
/// `provider` 只为兼容既有调用方保留（ZCode 版固定 `md5+sha1`，不支持时间盐）。
pub fn verifyAndUpgrade(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: anytype,
    password: []const u8,
    stored: []const u8,
) !UpgradeResult {
    _ = io;
    _ = provider;
    return core.verifyAndUpgradeAlloc(allocator, password, stored);
}

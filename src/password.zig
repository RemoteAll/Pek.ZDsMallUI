//! 口令散列：**与 C# `NewLife.Security.SaltPasswordProvider` 字节级互通**。
//!
//! 数据库里的口令列是跨语言共享资产：同一套账号库，C#（DH.NCore / DH.NCode）、
//! Rust（`dhrust::sign::password`）与 Zig 服务都要能互相验证。因此算法、盐值字符集、
//! 编码大小写、拼接顺序逐项对齐 C#（口径与 `DH.RustBase/src/sign/password.rs` 一致）。
//!
//! # 存储格式（C# 原样）
//! ```text
//! $算法$盐值$散列
//! 例：$md5+sha1$abCD12./xyZ9012$Xw9m0k...==
//! ```
//!
//! # 支持的算法（与 C# 同名）
//! | 算法 | 计算式 |
//! |---|---|
//! | `md5` | `HexUpper(MD5(HexUpper(MD5(密码)) + 盐))` |
//! | `sha1` | `Base64(HMACSHA1(key=盐, msg=密码))` |
//! | `sha512` | `Base64(HMACSHA512(key=盐, msg=密码))` |
//! | `md5+sha1` | `Base64(HMACSHA1(key=盐, msg=MD5原始字节(密码)))` |
//! | `md5+sha512` | `Base64(HMACSHA512(key=盐, msg=MD5原始字节(密码)))` |
//!
//! **默认算法 `md5+sha1`**：按「跨项目接续协议 · 登录口令规范」中 A 档（有 HTTPS 的面板）
//! 的口径选定——`sha512` / `sha1` 档只认明文，会丢掉「前端先 MD5 再提交」的能力。
//!
//! # 旧式口令（兼容 + 自动升级）
//! 不含 `$` 的历史值按 C# `Verify` 的老值分支处理：命中**明文**或 **MD5 十六进制**
//! （大小写不敏感）。登录成功后调用 [`verifyAndUpgrade`] 即把它替换成新格式。
//!
//! # 盐值
//! - 默认 16 位随机字符，字符集 `a-zA-Z0-9./`（与 C# `SaltPasswordProvider._cs` 一致）；
//! - `salt_time > 0` 时改用 **Unix 秒**作盐，并在验证时校验时间差（C# `SaltTime`）。

const std = @import("std");
const zzig = @import("zzig");

/// 默认算法（本库口径：`md5+sha1`，见文件头）。
pub const DEFAULT_ALGORITHM: Algorithm = .md5_sha1;

/// 盐值字符集（与 C# 逐字符一致，含末尾 `./`）。
pub const SALT_CHARSET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./";

/// 随机盐长度（C# 固定 16）。
pub const SALT_LENGTH = 16;

/// 支持的算法。
pub const Algorithm = enum {
    md5,
    sha1,
    sha512,
    md5_sha1,
    md5_sha512,

    /// 配置/存储里的算法名（与 C# `switch` 分支一致）。
    pub fn name(self: Algorithm) []const u8 {
        return switch (self) {
            .md5 => "md5",
            .sha1 => "sha1",
            .sha512 => "sha512",
            .md5_sha1 => "md5+sha1",
            .md5_sha512 => "md5+sha512",
        };
    }

    /// 由算法名解析（大小写不敏感；未知返回 `null`）。
    pub fn fromName(text: []const u8) ?Algorithm {
        const names = [_]Algorithm{ .md5, .sha1, .sha512, .md5_sha1, .md5_sha512 };
        for (names) |alg| {
            if (std.ascii.eqlIgnoreCase(alg.name(), text)) return alg;
        }
        return null;
    }
};

/// 口令提供者（对齐 C# `SaltPasswordProvider`）。
pub const Provider = struct {
    algorithm: Algorithm = DEFAULT_ALGORITHM,
    /// `> 0` 时使用 Unix 秒作盐并校验时间差（0 = 随机盐）。
    salt_time: i64 = 0,
};

/// 验证 + 升级结果。
pub const UpgradeResult = struct {
    /// 是否通过验证
    ok: bool,
    /// 需要改写时的新散列（调用方负责释放；`null` = 无需升级）
    upgraded: ?[]u8 = null,
};

/// 单次散列文本的最大长度（sha512 的 base64 = 88，md5 的十六进制 = 32，留足余量）。
const max_hash_text = 128;

/// 生成新口令散列（默认提供者）。
pub fn hash(allocator: std.mem.Allocator, io: std.Io, password: []const u8) ![]u8 {
    return hashWith(allocator, io, .{}, password);
}

/// 生成新口令散列（指定提供者）。
pub fn hashWith(allocator: std.mem.Allocator, io: std.Io, provider: Provider, password: []const u8) ![]u8 {
    var salt_buffer: [32]u8 = undefined;
    const salt = try createSalt(io, &salt_buffer, provider.salt_time);
    return hashWithSalt(allocator, provider.algorithm, password, salt);
}

/// 用**指定盐**生成散列（确定性；互通校验、批量迁移、单元测试用）。
pub fn hashWithSalt(
    allocator: std.mem.Allocator,
    algorithm: Algorithm,
    password: []const u8,
    salt: []const u8,
) ![]u8 {
    var buffer: [max_hash_text]u8 = undefined;
    const digest = compute(algorithm, password, salt, &buffer) orelse return error.UnsupportedAlgorithm;
    return std.fmt.allocPrint(allocator, "${s}${s}${s}", .{ algorithm.name(), salt, digest });
}

/// 验证口令（含旧式明文/MD5，以及「前端已算好 MD5 传输」的兼容分支）。
pub fn verify(password: []const u8, stored: []const u8) bool {
    return verifyWith(.{}, password, stored);
}

/// 验证口令（指定提供者，用于启用时间盐的场景）。
pub fn verifyWith(provider: Provider, password: []const u8, stored: []const u8) bool {
    const text = std.mem.trim(u8, stored, " \t\r\n");
    if (text.len == 0) return false;

    var parts: [4][]const u8 = undefined;
    const count = splitDollar(text, &parts);

    // ———— 旧式：明文或 MD5 十六进制（大小写不敏感）———
    if (count == 1) {
        if (eqlIgnoreCase(text, password)) return true;
        var md5_buffer: [32]u8 = undefined;
        const lower = md5HexLower(password, &md5_buffer);
        return eqlIgnoreCase(text, lower);
    }
    // 非 `$算法$盐$散列` 形态：C# 抛异常；这里按「验证失败」处理（不 panic）
    if (count != 4 or parts[0].len != 0) return false;

    const algorithm = Algorithm.fromName(parts[1]) orelse return false;
    const salt = parts[2];
    const want = parts[3];

    // 时间盐：超出允许时间差直接失败
    if (provider.salt_time > 0) {
        const ts = std.fmt.parseInt(i64, salt, 10) catch return false;
        const now = zzig.DateTime.nowUnix();
        const diff = if (now > ts) now - ts else ts - now;
        if (diff > provider.salt_time) return false;
    }

    // 1) 标准分支：口令明文
    var buffer: [max_hash_text]u8 = undefined;
    if (compute(algorithm, password, salt, &buffer)) |got| {
        if (timingSafeEql(want, got)) return true;
    }

    // 2) 兼容分支（对齐 C# Verify 的多路尝试）
    switch (algorithm) {
        // 传输的是「前端算好的 MD5 十六进制」：`(password + salt).MD5()`
        .md5 => {
            var joined: [512]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&joined);
            writer.print("{s}{s}", .{ password, salt }) catch return false;
            const got = md5HexUpperText(writer.buffered(), &buffer);
            if (eqlIgnoreCase(want, got)) return true;
            if (looksLikeMd5Hex(password) and password.len <= 32) {
                var upper_buffer: [32]u8 = undefined;
                for (password, 0..) |c, index| upper_buffer[index] = std.ascii.toUpper(c);
                var joined2: [512]u8 = undefined;
                var writer2: std.Io.Writer = .fixed(&joined2);
                writer2.print("{s}{s}", .{ upper_buffer[0..password.len], salt }) catch return false;
                const got2 = md5HexUpperText(writer2.buffered(), &buffer);
                if (eqlIgnoreCase(want, got2)) return true;
            }
            return false;
        },
        // 兼容「纯 SHA 散列」与「传输 MD5 十六进制」两种旧值
        .md5_sha1, .md5_sha512 => {
            if (timingSafeEql(want, hmacText(algorithm, salt, password, &buffer))) return true;
            var raw: [16]u8 = undefined;
            if (hexDecode(password, &raw)) |decoded| {
                if (timingSafeEql(want, hmacText(algorithm, salt, decoded, &buffer))) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// 验证 + 按需升级：对齐 C# `LoginCore`（验证通过后若仍是旧格式，立即改写为新散列）。
pub fn verifyAndUpgrade(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    password: []const u8,
    stored: []const u8,
) !UpgradeResult {
    if (!verifyWith(provider, password, stored)) return .{ .ok = false };
    if (!needsUpgrade(provider.algorithm, stored)) return .{ .ok = true };
    const upgraded = try hashWith(allocator, io, provider, password);
    return .{ .ok = true, .upgraded = upgraded };
}

/// 该散列是否需要升级（旧式、或算法与当前配置不同、或格式损坏）。
pub fn needsUpgrade(algorithm: Algorithm, stored: []const u8) bool {
    const text = std.mem.trim(u8, stored, " \t\r\n");
    if (text.len == 0) return true;
    var parts: [4][]const u8 = undefined;
    const count = splitDollar(text, &parts);
    if (count != 4 or parts[0].len != 0) return true;
    return !std.mem.eql(u8, parts[1], algorithm.name());
}

/// 是否为旧式散列（不含 `$`，即明文/MD5）。
pub fn isLegacy(stored: []const u8) bool {
    return std.mem.indexOfScalar(u8, std.mem.trim(u8, stored, " \t\r\n"), '$') == null;
}

/// 解析散列里的算法名（旧式/异常返回 `null`）。
pub fn algorithmOf(stored: []const u8) ?Algorithm {
    const text = std.mem.trim(u8, stored, " \t\r\n");
    var parts: [4][]const u8 = undefined;
    const count = splitDollar(text, &parts);
    if (count != 4 or parts[0].len != 0) return null;
    return Algorithm.fromName(parts[1]);
}

// ————— 内部实现 —————

/// 生成盐（时间盐 或 16 位随机字符）。
fn createSalt(io: std.Io, buffer: *[32]u8, salt_time: i64) ![]const u8 {
    if (salt_time > 0) {
        var writer: std.Io.Writer = .fixed(buffer);
        try writer.print("{d}", .{zzig.DateTime.nowUnix()});
        return writer.buffered();
    }
    var random: [SALT_LENGTH]u8 = undefined;
    const source = std.Random.IoSource{ .io = io };
    source.interface().bytes(&random);
    for (random, 0..) |byte, index| {
        buffer[index] = SALT_CHARSET[byte % SALT_CHARSET.len];
    }
    return buffer[0..SALT_LENGTH];
}

/// 按算法计算散列文本（写入 `buffer`，返回其切片）。
fn compute(
    algorithm: Algorithm,
    password: []const u8,
    salt: []const u8,
    buffer: *[max_hash_text]u8,
) ?[]const u8 {
    switch (algorithm) {
        // (password.MD5() + salt).MD5()；C# ToHex 为**大写**
        .md5 => {
            var inner_bytes: [32]u8 = undefined;
            const inner = md5HexUpper(password, &inner_bytes);
            var joined: [512]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&joined);
            writer.print("{s}{s}", .{ inner, salt }) catch return null;
            return md5HexUpperText(writer.buffered(), buffer);
        },
        .sha1 => return base64Into(&hmacSha1(salt, password), buffer),
        .sha512 => return base64Into(&hmacSha512(salt, password), buffer),
        .md5_sha1 => {
            const raw = md5Raw(password);
            return base64Into(&hmacSha1(salt, &raw), buffer);
        },
        .md5_sha512 => {
            const raw = md5Raw(password);
            return base64Into(&hmacSha512(salt, &raw), buffer);
        },
    }
}

/// HMAC 分支的文本化（`md5+sha1` / `md5+sha512` 的兼容分支用）。
fn hmacText(algorithm: Algorithm, salt: []const u8, data: []const u8, buffer: *[max_hash_text]u8) []const u8 {
    return switch (algorithm) {
        .md5_sha1 => base64Into(&hmacSha1(salt, data), buffer),
        .md5_sha512 => base64Into(&hmacSha512(salt, data), buffer),
        else => "",
    };
}

fn md5Raw(data: []const u8) [16]u8 {
    var out: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &out, .{});
    return out;
}

fn md5HexUpper(data: []const u8, buffer: *[32]u8) []const u8 {
    const hex = std.fmt.bytesToHex(md5Raw(data), .upper);
    @memcpy(buffer, &hex);
    return buffer;
}

/// MD5 十六进制大写 → 写入通用散列文本缓冲（`[max_hash_text]u8`）。
fn md5HexUpperText(data: []const u8, buffer: *[max_hash_text]u8) []const u8 {
    var temporary: [32]u8 = undefined;
    const hex = md5HexUpper(data, &temporary);
    @memcpy(buffer[0..32], hex);
    return buffer[0..32];
}

fn md5HexLower(data: []const u8, buffer: *[32]u8) []const u8 {
    const hex = std.fmt.bytesToHex(md5Raw(data), .lower);
    @memcpy(buffer, &hex);
    return buffer;
}

fn hmacSha1(key: []const u8, data: []const u8) [20]u8 {
    var out: [20]u8 = undefined;
    std.crypto.auth.hmac.HmacSha1.create(&out, data, key);
    return out;
}

fn hmacSha512(key: []const u8, data: []const u8) [64]u8 {
    var out: [64]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha512.create(&out, data, key);
    return out;
}

fn base64Into(data: []const u8, buffer: *[max_hash_text]u8) []const u8 {
    const size = std.base64.standard.Encoder.calcSize(data.len);
    if (size > buffer.len) return "";
    return std.base64.standard.Encoder.encode(buffer[0..size], data);
}

/// 按 `$` 切分（最多 4 段；C# 格式恰为 `$算法$盐$散列`）。
fn splitDollar(text: []const u8, out: *[4][]const u8) usize {
    var index: usize = 0;
    var start: usize = 0;
    var count: usize = 0;
    while (index <= text.len) : (index += 1) {
        if (index == text.len or text[index] == '$') {
            if (count < out.len) {
                out[count] = text[start..index];
                count += 1;
            } else {
                // 超出的段并入最后一段（视为格式错误，由调用方判失败）
                return 0;
            }
            start = index + 1;
        }
    }
    return count;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// 常量时间比较（避免按字节提前返回泄露信息）。
fn timingSafeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn looksLikeMd5Hex(text: []const u8) bool {
    if (text.len != 32) return false;
    for (text) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn hexDecode(text: []const u8, out: *[16]u8) ?[]const u8 {
    if (text.len != 32) return null;
    var index: usize = 0;
    while (index < 16) : (index += 1) {
        const high = hexVal(text[index * 2]) orelse return null;
        const low = hexVal(text[index * 2 + 1]) orelse return null;
        out[index] = (high << 4) | low;
    }
    return out;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ————— 测试 —————

const testing = std.testing;

test "口令：md5+sha1 与 C# 向量一致（固定盐）" {
    // 计算式固定，故结果确定；这里校验格式与可验证性，并锁定算法口径。
    const stored = try hashWithSalt(testing.allocator, .md5_sha1, "admin123", "abcDEF12./xyZ901");
    defer testing.allocator.free(stored);

    try testing.expect(std.mem.startsWith(u8, stored, "$md5+sha1$abcDEF12./xyZ901$"));
    try testing.expect(verify("admin123", stored));
    try testing.expect(!verify("admin1234", stored));
}

test "口令：默认提供者用 md5+sha1（不是 sha512）" {
    try testing.expectEqual(Algorithm.md5_sha1, DEFAULT_ALGORITHM);
    const stored = try hash(testing.allocator, testing.io, "abc");
    defer testing.allocator.free(stored);
    try testing.expect(std.mem.startsWith(u8, stored, "$md5+sha1$"));
}

test "口令：五种算法都可存可验" {
    const algorithms = [_]Algorithm{ .md5, .sha1, .sha512, .md5_sha1, .md5_sha512 };
    for (algorithms) |alg| {
        const stored = try hashWithSalt(testing.allocator, alg, "P@ssw0rd", "salt1234567890AB");
        defer testing.allocator.free(stored);
        try testing.expect(verify("P@ssw0rd", stored));
        try testing.expect(!verify("P@ssw0rd!", stored));
        try testing.expectEqual(alg, algorithmOf(stored).?);
    }
}

test "口令：旧式明文与 MD5 十六进制都能验证" {
    // 明文
    try testing.expect(verify("legacy", "legacy"));
    // MD5 十六进制（小写/大写都认）
    const stored = try testing.allocator.dupe(u8, "5f4dcc3b5aa765d61d8327deb882cf99"); // md5("password")
    defer testing.allocator.free(stored);
    try testing.expect(verify("password", stored));
    try testing.expect(verify("password", "5F4DCC3B5AA765D61D8327DEB882CF99"));
    try testing.expect(isLegacy(stored));
    try testing.expect(!isLegacy("$md5+sha1$a$b"));
}

test "口令：verifyAndUpgrade 会把旧格式升级为新格式" {
    const legacy = "admin123"; // 明文旧值
    const result = try verifyAndUpgrade(testing.allocator, testing.io, .{}, "admin123", legacy);
    try testing.expect(result.ok);
    const upgraded = result.upgraded orelse return error.TestExpectedUpgrade;
    defer testing.allocator.free(upgraded);

    try testing.expect(std.mem.startsWith(u8, upgraded, "$md5+sha1$"));
    try testing.expect(verify("admin123", upgraded));
    // 已是最新格式时不再产出新散列
    const again = try verifyAndUpgrade(testing.allocator, testing.io, .{}, "admin123", upgraded);
    try testing.expect(again.ok);
    try testing.expect(again.upgraded == null);
}

test "口令：前端 MD5 传输分支（$md5+sha1$ + md5 十六进制输入）" {
    const stored = try hashWithSalt(testing.allocator, .md5_sha1, "admin123", "salt1234567890AB");
    defer testing.allocator.free(stored);

    // 前端算好的小写 MD5(明文) = md5("admin123")
    var hex_buffer: [32]u8 = undefined;
    const md5_hex = md5HexLower("admin123", &hex_buffer);
    try testing.expect(verify(md5_hex, stored));
    // 大写形式同样接受
    for (hex_buffer, 0..) |c, index| hex_buffer[index] = std.ascii.toUpper(c);
    try testing.expect(verify(&hex_buffer, stored));
}

test "口令：随机盐长度与字符集" {
    const stored = try hash(testing.allocator, testing.io, "abc");
    defer testing.allocator.free(stored);
    var parts: [4][]const u8 = undefined;
    const count = splitDollar(stored, &parts);
    try testing.expectEqual(@as(usize, 4), count);
    try testing.expectEqual(@as(usize, SALT_LENGTH), parts[2].len);
    for (parts[2]) |c| try testing.expect(std.mem.indexOfScalar(u8, SALT_CHARSET, c) != null);
    try testing.expect(verify("abc", stored));
}

test "口令：损坏的散列不会 panic，只判失败" {
    try testing.expect(!verify("x", ""));
    try testing.expect(!verify("x", "$"));
    try testing.expect(!verify("x", "$md5$a"));
    try testing.expect(!verify("x", "$$$"));
    try testing.expect(!verify("x", "$nope$salt$hash"));
}

// ————— C# / Rust 互通黄金样本（跨端对拍，别改这些常量）—————
//
// 来源：`G:\Code\Rust\DH.RustBase\tools\csharp\DHRustDemo`（引用 `NewLife.Security.SaltPasswordProvider`）
// 实测命令：
//   DHRustDemo.exe password-hash-fixed <算法> "New#life" "abCD12./xyZ9012Q"
// 同款脚本：`DH.RustBase\scripts\password-interop.ps1`（Rust 侧 `matches_csharp_golden_hashes` 用的同一批值）。
// 任一侧改动算法 / 编码 / 大小写，这里立刻报警。
const GOLDEN_PASSWORD = "New#life";
const GOLDEN_SALT = "abCD12./xyZ9012Q";
const CSharpGolden = struct { algorithm: Algorithm, stored: []const u8 };
const CSHARP_GOLDEN = [_]CSharpGolden{
    .{ .algorithm = .md5, .stored = "$md5$abCD12./xyZ9012Q$F66328434CFAEF3EC9B394358D6D9C36" },
    .{ .algorithm = .sha1, .stored = "$sha1$abCD12./xyZ9012Q$fNkn6u3ykPZM4OPL/y6r6Jof2mY=" },
    .{ .algorithm = .sha512, .stored = "$sha512$abCD12./xyZ9012Q$ctlLR2xz3b1a9ARbpCkOZEFLvc6A2pLG/BMTVq99TR1pr9JIMs70qKj/OMjohcBvU0+XAyRh6CsExEMfvybOKg==" },
    .{ .algorithm = .md5_sha1, .stored = "$md5+sha1$abCD12./xyZ9012Q$FAXHeXyCpOSOPugOqcHia+ZVMOw=" },
    .{ .algorithm = .md5_sha512, .stored = "$md5+sha512$abCD12./xyZ9012Q$pO5mQ5rFhoYeCn+a6s1GhcvwqSgzbgWOuK3fC2VSaNQ1SGk5TSErph0jK5ThlAfkAbzdr9UM6Pe/xQ17Zk24Kw==" },
};

test "口令互通：五种算法与 C# 固定盐散列逐字一致" {
    for (CSHARP_GOLDEN) |golden| {
        const stored = try hashWithSalt(testing.allocator, golden.algorithm, GOLDEN_PASSWORD, GOLDEN_SALT);
        defer testing.allocator.free(stored);
        try testing.expectEqualStrings(golden.stored, stored);
        // 反向：C# 生成的值，Zig 必须能验证
        try testing.expect(verify(GOLDEN_PASSWORD, golden.stored));
        try testing.expect(!verify("wrong", golden.stored));
        try testing.expect(!needsUpgrade(golden.algorithm, golden.stored));
    }
}

test "口令互通：中文口令（UTF-8）与 C# 一致" {
    // C#: DHRustDemo.exe password-hash-fixed md5+sha1 "中文口令123" "abCD12./xyZ9012Q"
    const stored_md5_sha1 = "$md5+sha1$abCD12./xyZ9012Q$dR3AqHU3Uo0CBl7waSUoerv2fMc=";
    const stored_md5 = "$md5$abCD12./xyZ9012Q$BD5AD3872AB26F331056B0CB80328826";
    try testing.expect(verify("中文口令123", stored_md5_sha1));
    try testing.expect(verify("中文口令123", stored_md5));

    const computed = try hashWithSalt(testing.allocator, .md5_sha1, "中文口令123", GOLDEN_SALT);
    defer testing.allocator.free(computed);
    try testing.expectEqualStrings(stored_md5_sha1, computed);
}

test "口令互通：C# 生成的 md5+sha1 接受前端 MD5 传输（大小写都认）" {
    // C# 侧实测（DHRustDemo.exe password-verify-alg md5+sha1 <md5hex> <stored>）：
    //   明文 / 小写 MD5 / 大写 MD5 都是 OK，错误 MD5 是 FAIL。
    var hex_buffer: [32]u8 = undefined;
    const lower = md5HexLower(GOLDEN_PASSWORD, &hex_buffer);
    const golden = CSHARP_GOLDEN[3].stored; // $md5+sha1$…
    try testing.expect(verify(lower, golden));

    var upper: [32]u8 = undefined;
    for (lower, 0..) |c, index| upper[index] = std.ascii.toUpper(c);
    try testing.expect(verify(&upper, golden));

    // 另一个口令的 MD5 必须被拒
    var other: [32]u8 = undefined;
    try testing.expect(!verify(md5HexLower("admin123", &other), golden));
}

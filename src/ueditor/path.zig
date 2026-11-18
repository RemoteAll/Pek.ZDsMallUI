//! 上传保存路径格式化（对齐 UEditor 官方 `PathFormatter`，C# 参考实现见
//! `Pek.DsMallUI/UEditor/PathFormatter.cs`）。
//!
//! 支持的占位符（与官方文档一致）：
//! `{filename}` 原文件名（不含扩展名）、`{rand:6}` / `{rand6}` 指定位数随机数、
//! `{time}` 毫秒时间戳、`{yyyy}`/`{yy}`/`{mm}`/`{dd}`/`{hh}`/`{ii}`/`{ss}` 时间片。
//!
//! 与 C# 实现的两点差异（均为修复而非改口径，见 `docs/移植对照.md`）：
//! 1. **文件名清洗**替换非法字符为 `_` 并把 `..` 折叠为 `__`（C# 直接删除非法字符），
//!    避免 `{filename}` 造成目录穿越；
//! 2. **`{rand:n}` 生成 n 位数字**：C# 写作 `rand.Next(10^n, 10^(n+1))`，实际产出 **n+1 位**，
//!    与官方 PHP/Java 实现（n 位）不一致，这里按官方口径修正。

const std = @import("std");
const zzig = @import("zzig");

/// 默认命名规则（`pathFormat` 为空时使用）。
pub const DEFAULT_PATH_FORMAT = "{filename}_{rand:6}";

/// 随机数字来源（测试可注入固定值；`ctx` 为调用方上下文）。
pub const RandomFn = *const fn (ctx: ?*anyopaque, digits: usize, out: []u8) void;

/// 按当前本地时间格式化保存路径（返回以 `/` 分隔的相对路径，含扩展名）。
pub fn formatPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    original_filename: []const u8,
    path_format: []const u8,
) ![]u8 {
    var io_slot = io;
    return formatPathAt(
        allocator,
        original_filename,
        path_format,
        zzig.DateTime.nowLocal(),
        @ptrCast(&io_slot),
        randomFromIo,
    );
}

/// 可注入时间与随机源的格式化（便于测试；内部与 [`formatPath`] 同一实现）。
pub fn formatPathAt(
    allocator: std.mem.Allocator,
    original_filename: []const u8,
    path_format: []const u8,
    now: zzig.DateTime,
    random_ctx: ?*anyopaque,
    make_random: RandomFn,
) ![]u8 {
    const pattern = if (std.mem.trim(u8, path_format, " \t\r\n").len == 0) DEFAULT_PATH_FORMAT else path_format;

    const sanitized = try sanitizeFileName(allocator, original_filename);
    defer allocator.free(sanitized);

    const extension = extensionOf(sanitized);
    const stem = if (extension.len == 0) sanitized else sanitized[0 .. sanitized.len - extension.len];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, pattern.len + stem.len + 16);

    var rest = pattern;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        try out.appendSlice(allocator, rest[0..open]);
        const tail = rest[open..];
        const close = std.mem.indexOfScalar(u8, tail, '}') orelse {
            // 无配对 `}`：原样保留
            try out.appendSlice(allocator, tail);
            rest = "";
            break;
        };
        const token = tail[1..close];

        if (std.mem.eql(u8, token, "filename")) {
            try out.appendSlice(allocator, stem);
        } else if (std.mem.eql(u8, token, "time")) {
            const millis = @divTrunc(zzig.compat.nanoTimestamp(), std.time.ns_per_ms);
            try out.print(allocator, "{d}", .{millis});
        } else if (std.mem.eql(u8, token, "yyyy")) {
            try appendPadded(&out, allocator, @as(u32, @intCast(now.year)), 4);
        } else if (std.mem.eql(u8, token, "yy")) {
            try appendPadded(&out, allocator, @intCast(@mod(now.year, 100)), 2);
        } else if (std.mem.eql(u8, token, "mm")) {
            try appendPadded(&out, allocator, now.month, 2);
        } else if (std.mem.eql(u8, token, "dd")) {
            try appendPadded(&out, allocator, now.day, 2);
        } else if (std.mem.eql(u8, token, "hh")) {
            try appendPadded(&out, allocator, now.hour, 2);
        } else if (std.mem.eql(u8, token, "ii")) {
            try appendPadded(&out, allocator, now.minute, 2);
        } else if (std.mem.eql(u8, token, "ss")) {
            try appendPadded(&out, allocator, now.second, 2);
        } else if (randDigitsOf(token)) |digits| {
            var buffer: [12]u8 = undefined;
            make_random(random_ctx, digits, buffer[0..digits]);
            try out.appendSlice(allocator, buffer[0..digits]);
        } else {
            // 未知占位符原样输出（便于发现拼写错误）
            try out.appendSlice(allocator, tail[0 .. close + 1]);
        }
        rest = tail[close + 1 ..];
    }
    try out.appendSlice(allocator, rest);
    try out.appendSlice(allocator, extension);
    return out.toOwnedSlice(allocator);
}

/// 取扩展名（含 `.`，保持原始大小写）；无扩展名返回空串。
pub fn extensionOf(filename: []const u8) []const u8 {
    const name = if (std.mem.lastIndexOfAny(u8, filename, "/\\")) |index| filename[index + 1 ..] else filename;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0 or dot + 1 >= name.len) return "";
    return name[dot..];
}

/// 文件名清洗（对齐 `dhrust::io::sanitize_file_name`）：
/// `/\:*?"<>|` 与控制字符 → `_`；`..` → `__`；空名 → `_`。
pub fn sanitizeFileName(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, raw.len + 1);

    for (raw) |c| {
        const illegal = switch (c) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0 => true,
            else => c < 0x20 or c == 0x7F,
        };
        try out.append(allocator, if (illegal) '_' else c);
    }

    // `..` → `__`（可能连锁产生新的 `..`，循环到不再出现）
    while (std.mem.indexOf(u8, out.items, "..")) |index| {
        out.items[index] = '_';
        out.items[index + 1] = '_';
    }

    if (out.items.len == 0) try out.append(allocator, '_');
    return out.toOwnedSlice(allocator);
}

/// 左补零追加（`{yyyy}` / `{mm}` 等时间片用；不依赖格式化器的填充语法）。
fn appendPadded(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32, width: usize) !void {
    var buffer: [12]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    var padding = width -| text.len;
    while (padding > 0) : (padding -= 1) try out.append(allocator, '0');
    try out.appendSlice(allocator, text);
}

/// 解析 `rand:6` / `rand6` 形式，返回位数（上限 12 位，防手改配置写出超长随机串）。
fn randDigitsOf(token: []const u8) ?usize {
    const rest = if (std.mem.startsWith(u8, token, "rand")) token["rand".len..] else return null;
    const digits_text = if (std.mem.startsWith(u8, rest, ":")) rest[1..] else rest;
    if (digits_text.len == 0) return null;
    for (digits_text) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const digits = std.fmt.parseInt(usize, digits_text, 10) catch return null;
    return @min(@max(digits, 1), 12);
}

/// 默认随机源：n 位十进制数字（首位可为 0，与官方实现一致）。
pub fn randomDigits(io: std.Io, digits: usize, out: []u8) void {
    var random: [12]u8 = undefined;
    const source = std.Random.IoSource{ .io = io };
    source.interface().bytes(random[0..digits]);
    for (out[0..digits], 0..) |*slot, index| slot.* = '0' + (random[index] % 10);
}

/// `formatPath` 使用的随机源（`ctx` 指向调用方的 `std.Io`）。
fn randomFromIo(ctx: ?*anyopaque, digits: usize, out: []u8) void {
    const io: *const std.Io = @ptrCast(@alignCast(ctx orelse return));
    randomDigits(io.*, digits, out);
}

// ————— 测试 —————

const testing = std.testing;

fn fixedTime() zzig.DateTime {
    return .{ .year = 2026, .month = 11, .day = 9, .hour = 8, .minute = 5, .second = 3 };
}

fn fixedRandom(_: ?*anyopaque, digits: usize, out: []u8) void {
    @memset(out[0..digits], '1');
}

test "路径：全部时间片与文件名" {
    const path = try formatPathAt(testing.allocator, "报告 v2.PNG", "/images/{yyyy}/{mm}/{dd}/{filename}_{hh}{ii}{ss}", fixedTime(), null, fixedRandom);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/images/2026/11/09/报告 v2_080503.PNG", path);
}

test "路径：rand 位数按请求生成（{rand:6} 与 {rand3}）" {
    const with_colon = try formatPathAt(testing.allocator, "a.txt", "{filename}_{rand:6}", fixedTime(), null, fixedRandom);
    defer testing.allocator.free(with_colon);
    try testing.expectEqualStrings("a_111111.txt", with_colon);

    const without_colon = try formatPathAt(testing.allocator, "a.txt", "{rand3}", fixedTime(), null, fixedRandom);
    defer testing.allocator.free(without_colon);
    try testing.expectEqualStrings("111.txt", without_colon);
}

test "路径：空模板用默认规则" {
    const path = try formatPathAt(testing.allocator, "x.jpg", "", fixedTime(), null, fixedRandom);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("x_111111.jpg", path);
}

test "路径：目录穿越被清洗" {
    const path = try formatPathAt(testing.allocator, "..\\..\\web.config", "{filename}.txt", fixedTime(), null, fixedRandom);
    defer testing.allocator.free(path);
    try testing.expect(std.mem.indexOf(u8, path, "..") == null);
    try testing.expect(std.mem.indexOfScalar(u8, path, '/') == null);
    try testing.expect(std.mem.indexOfScalar(u8, path, '\\') == null);
}

test "路径：扩展名识别" {
    try testing.expectEqualStrings(".gz", extensionOf("a.tar.gz"));
    try testing.expectEqualStrings("", extensionOf("a"));
    try testing.expectEqualStrings("", extensionOf(".gitignore"));
    try testing.expectEqualStrings(".PNG", extensionOf("dir/a.PNG"));
    try testing.expectEqualStrings("", extensionOf("dir.with.dot/a"));
}

test "路径：未知占位符原样保留" {
    const path = try formatPathAt(testing.allocator, "a.txt", "{unknown}_{filename}", fixedTime(), null, fixedRandom);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("{unknown}_a.txt", path);
}

test "路径：{time} 为毫秒时间戳（13 位）" {
    const path = try formatPathAt(testing.allocator, "a.png", "{time}", fixedTime(), null, fixedRandom);
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(usize, 13 + 4), path.len);
}

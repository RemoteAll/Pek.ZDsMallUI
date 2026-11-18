//! UEditor 前后端通信配置（`ueconfig.json`）加载。
//!
//! 原始文件由富文本编辑器官方提供、**带 `/* ... */` 块注释**（见 `assets/ueconfig.json`）。
//! C# 侧 `UeditorConfig.Items` 用正则 `/\*.*?\*/` 去掉块注释后交给 JSON 解析；
//! Zig 侧提供等价且有界的清洗（字符串内的注释符号原样保留）：
//! - 去 UTF-8 BOM；
//! - 去 `/* ... */` 块注释与 `//` 行注释（**字符串内的注释符号原样保留**）；
//! - 去对象/数组的尾随逗号（容忍手改配置常见的多余逗号）。
//!
//! 配置**原样回吐**给前端（`action=config`）：字段顺序由 [`zzig.web.Value`] 的保序对象保留。

const std = @import("std");
const zzig = @import("zzig");

/// 内置 UEditor 配置原文（与 C# 参考工程 `ueconfig.json` 同一份，含块注释）。
pub const EMBEDDED_CONFIG_JSON = @embedFile("../../assets/ueconfig.json");

/// UEditor 配置（保序对象）。
pub const UeditorConfig = struct {
    allocator: std.mem.Allocator,
    items: zzig.web.Value = .null,

    /// 使用 crate 内置配置（与 C# 参考工程 `Pek.DsMallUI/ueconfig.json` 同一份）。
    pub fn embedded(allocator: std.mem.Allocator) !UeditorConfig {
        return parse(allocator, EMBEDDED_CONFIG_JSON);
    }

    /// 从 JSON 文本解析（容忍块注释/行注释/尾逗号）。
    pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !UeditorConfig {
        const cleaned = try stripComments(allocator, raw);
        defer allocator.free(cleaned);
        const value = zzig.web.Value.parse(allocator, cleaned) catch |err| switch (err) {
            error.InvalidJson => return error.InvalidJson,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (value != .object) return error.NotAnObject;
        return .{ .allocator = allocator, .items = value };
    }

    /// 从文件解析（UTF-8）。
    pub fn fromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !UeditorConfig {
        const raw = try zzig.fsio.readFileAlloc(io, allocator, path, 4 * 1024 * 1024);
        defer allocator.free(raw);
        return parse(allocator, raw);
    }

    /// 取字符串配置（缺失或非字符串返回 `null`）。
    pub fn getStr(self: UeditorConfig, key: []const u8) ?[]const u8 {
        return (self.items.get(key) orelse return null).asString();
    }

    /// 取整数配置（兼容数字字符串，如手写成 `"20480000"`）。
    pub fn getInt(self: UeditorConfig, key: []const u8) ?i64 {
        return (self.items.get(key) orelse return null).asInt();
    }

    /// 取布尔配置（`true/false`、`1/0`、`yes/no`、`on/off` 均可）。
    pub fn getBool(self: UeditorConfig, key: []const u8) ?bool {
        const value = self.items.get(key) orelse return null;
        return switch (value) {
            .boolean => |flag| flag,
            .integer => |number| number != 0,
            .number => |number| number != 0,
            .string => |text| blk: {
                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                if (std.ascii.eqlIgnoreCase(trimmed, "true") or std.mem.eql(u8, trimmed, "1") or
                    std.ascii.eqlIgnoreCase(trimmed, "yes") or std.ascii.eqlIgnoreCase(trimmed, "on")) break :blk true;
                if (std.ascii.eqlIgnoreCase(trimmed, "false") or std.mem.eql(u8, trimmed, "0") or
                    std.ascii.eqlIgnoreCase(trimmed, "no") or std.ascii.eqlIgnoreCase(trimmed, "off")) break :blk false;
                break :blk null;
            },
            else => null,
        };
    }

    /// 取字符串数组配置，并**归一化为带前导点的扩展名小写列表**。
    ///
    /// `ueconfig.json` 里 `imageAllowFiles` 存在 `"webp"`（缺前导点）这类脏值，
    /// 归一化后比较才不会漏判；空列表表示「未配置 → 拒绝所有类型」（与 C# 同口径）。
    pub fn getStringList(self: UeditorConfig, allocator: std.mem.Allocator, key: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(allocator);

        const value = self.items.get(key) orelse return out.toOwnedSlice(allocator);
        if (value != .list) return out.toOwnedSlice(allocator);

        for (value.list) |item| {
            const text = item.asString() orelse continue;
            const ext = try normalizeExtension(allocator, text);
            if (ext.len == 0) {
                allocator.free(ext);
                continue;
            }
            var duplicated = false;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, ext)) {
                    duplicated = true;
                    break;
                }
            }
            if (duplicated) {
                allocator.free(ext);
                continue;
            }
            try out.append(allocator, ext);
        }
        return out.toOwnedSlice(allocator);
    }

    /// 配置回吐为紧凑 JSON（`action=config` 的响应体）。
    pub fn toJson(self: UeditorConfig, allocator: std.mem.Allocator) ![]const u8 {
        return self.items.jsonAlloc(allocator);
    }

    /// 释放解析得到的值树（字符串/列表/对象均按 `allocator` 分配）。
    pub fn deinit(self: *UeditorConfig) void {
        deinitValue(self.allocator, self.items);
        self.items = .null;
    }
};

/// 递归释放 [`zzig.web.Value`] 里的堆内存（`Value.parse` 的分配全部归调用方）。
pub fn deinitValue(allocator: std.mem.Allocator, value: zzig.web.Value) void {
    switch (value) {
        .string => |text| allocator.free(text),
        .list => |items| {
            for (items) |item| deinitValue(allocator, item);
            allocator.free(items);
        },
        .object => |fields| {
            for (fields) |field| {
                allocator.free(field.name);
                deinitValue(allocator, field.value);
            }
            allocator.free(fields);
        },
        else => {},
    }
}

/// 扩展名归一化：去空白与引号、补前导 `.`、统一小写。
pub fn normalizeExtension(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    text = std.mem.trim(u8, text, "\"'");
    text = std.mem.trim(u8, text, " \t\r\n");
    if (text.len == 0 or std.mem.eql(u8, text, ".")) return allocator.alloc(u8, 0);

    const needs_dot = text[0] != '.';
    const out = try allocator.alloc(u8, text.len + @intFromBool(needs_dot));
    var index: usize = 0;
    if (needs_dot) {
        out[0] = '.';
        index = 1;
    }
    for (text, 0..) |c, offset| out[index + offset] = std.ascii.toLower(c);
    return out;
}

/// 清洗 JSON 文本：去 BOM、块注释、行注释、尾随逗号（字符串内一律原样）。
pub fn stripComments(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const start: usize = if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) 3 else 0;

    // 全程按字节操作：注释符号都是 ASCII，多字节内容原样搬运
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(allocator);
    try cleaned.ensureTotalCapacity(allocator, raw.len - start);

    var index = start;
    var in_string = false;
    var escaped = false;

    while (index < raw.len) {
        const byte = raw[index];

        if (in_string) {
            try cleaned.append(allocator, byte);
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            index += 1;
            continue;
        }

        if (byte == '"') {
            in_string = true;
            try cleaned.append(allocator, byte);
            index += 1;
            continue;
        }

        if (byte == '/' and index + 1 < raw.len and raw[index + 1] == '*') {
            index += 2;
            while (index + 1 < raw.len and !(raw[index] == '*' and raw[index + 1] == '/')) : (index += 1) {}
            index = @min(index + 2, raw.len);
            continue;
        }

        if (byte == '/' and index + 1 < raw.len and raw[index + 1] == '/') {
            index += 2;
            while (index < raw.len and raw[index] != '\n') : (index += 1) {}
            continue;
        }

        try cleaned.append(allocator, byte);
        index += 1;
    }

    return removeTrailingCommas(allocator, cleaned.items);
}

/// 去掉 `,]` / `,}` 前的逗号（字符串内不动）。
fn removeTrailingCommas(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    var in_string = false;
    var escaped = false;
    for (text, 0..) |byte, index| {
        if (in_string) {
            try out.append(allocator, byte);
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        if (byte == '"') {
            in_string = true;
            try out.append(allocator, byte);
            continue;
        }
        if (byte == ',') {
            // 向后看第一个非空白字符
            var next = index + 1;
            while (next < text.len and std.ascii.isWhitespace(text[next])) : (next += 1) {}
            if (next < text.len and (text[next] == '}' or text[next] == ']')) continue; // 丢弃这个逗号
        }
        try out.append(allocator, byte);
    }
    return out.toOwnedSlice(allocator);
}

// ————— 测试 —————

const testing = std.testing;

test "ueconfig：内置配置可解析且关键键齐全" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = try UeditorConfig.embedded(arena);
    try testing.expectEqualStrings("uploadimage", config.getStr("imageActionName").?);
    try testing.expectEqualStrings("uploadfile", config.getStr("fileActionName").?);
    try testing.expectEqualStrings("upfile", config.getStr("imageFieldName").?);
    try testing.expect((config.getInt("imageMaxSize") orelse 0) > 0);

    const json = try config.toJson(arena);
    try testing.expect(std.mem.startsWith(u8, json, "{"));
    try testing.expect(std.mem.indexOf(u8, json, "imageActionName") != null);
}

test "ueconfig：去注释但保留字符串内容与尾随逗号容忍" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{
        \\  /* 注释 */
        \\  "url": "http://a/b//c", // 行注释
        \\  "list": [1, 2,] /* 尾逗号 */
        \\}
    ;
    const config = try UeditorConfig.parse(arena, raw);
    try testing.expectEqualStrings("http://a/b//c", config.getStr("url").?);
    try testing.expectEqual(@as(usize, 2), config.items.get("list").?.len());
}

test "ueconfig：扩展名列表归一化（补点、小写、去重、空项）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = try UeditorConfig.parse(arena, "{\"imageAllowFiles\":[\".PNG\",\"jpg\",\" webp \",\"\"],\"x\":1}");
    const exts = try config.getStringList(arena, "imageAllowFiles");
    try testing.expectEqual(@as(usize, 3), exts.len);
    try testing.expectEqualStrings(".png", exts[0]);
    try testing.expectEqualStrings(".jpg", exts[1]);
    try testing.expectEqualStrings(".webp", exts[2]);
}

test "ueconfig：缺键宽松，BOM 可容忍" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = try UeditorConfig.parse(arena, "{}");
    try testing.expect(config.getStr("nope") == null);
    try testing.expect(config.getInt("nope") == null);
    try testing.expect(config.getBool("nope") == null);
    try testing.expectEqual(@as(usize, 0), (try config.getStringList(arena, "nope")).len);

    const with_bom = try UeditorConfig.parse(arena, "\xEF\xBB\xBF{\"a\":1,}");
    try testing.expectEqual(@as(i64, 1), with_bom.getInt("a").?);
}

test "ueconfig：顶层必须是对象" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.NotAnObject, UeditorConfig.parse(arena_state.allocator(), "[1,2]"));
    try testing.expectError(error.InvalidJson, UeditorConfig.parse(arena_state.allocator(), "{oops"));
}

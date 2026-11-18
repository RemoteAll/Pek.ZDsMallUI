//! base64 解码（涂鸦上传用）。
//!
//! 对齐 Rust 版 `crate::base64_decode`：先按标准字母表，失败再按 URL 安全字母表；
//! 解码前忽略空白（浏览器可能换行折行），缺少 `=` 填充也能解（UEditor 前端不保证填充）。

const std = @import("std");

/// 解码失败原因。
pub const DecodeError = error{
    /// 内容为空
    Empty,
    /// 四种字母表都无法解码
    Invalid,
    OutOfMemory,
};

/// 解码 base64（标准/URL 安全，含/不含填充）。
pub fn decode(allocator: std.mem.Allocator, text: []const u8) DecodeError![]u8 {
    // 去空白
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(allocator);
    try cleaned.ensureTotalCapacity(allocator, text.len);
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        try cleaned.append(allocator, c);
    }
    if (cleaned.items.len == 0) return error.Empty;

    const engines = [_]std.base64.Codecs{
        std.base64.standard,
        std.base64.standard_no_pad,
        std.base64.url_safe,
        std.base64.url_safe_no_pad,
    };
    for (engines) |engine| {
        const size = engine.Decoder.calcSizeForSlice(cleaned.items) catch continue;
        const buffer = allocator.alloc(u8, size) catch return error.OutOfMemory;
        engine.Decoder.decode(buffer, cleaned.items) catch {
            allocator.free(buffer);
            continue;
        };
        return buffer;
    }
    return error.Invalid;
}

/// 解码 data URL（`data:image/png;base64,iVBOR...`）：无前缀时按原样解码。
pub fn decodeDataUrl(allocator: std.mem.Allocator, text: []const u8) DecodeError![]u8 {
    const payload = if (std.mem.indexOf(u8, text, "base64,")) |index| text[index + "base64,".len ..] else text;
    // data URL 里的 `+` 可能被 urlencoded 转义成空格，这里还原
    var restored: std.ArrayList(u8) = .empty;
    defer restored.deinit(allocator);
    try restored.ensureTotalCapacity(allocator, payload.len);
    for (payload) |c| try restored.append(allocator, if (c == ' ') '+' else c);
    return decode(allocator, restored.items);
}

const testing = std.testing;

test "base64：标准/无填充/URL 安全/换行都能解" {
    const cases = [_][]const u8{ "aGVsbG8=", "aGVs\nbG8=", "aGVsbG8" };
    for (cases) |encoded| {
        const data = try decode(testing.allocator, encoded);
        defer testing.allocator.free(data);
        try testing.expectEqualStrings("hello", data);
    }

    // URL 安全字母表（含 - 与 _）且无填充：先编码再解码，往返一致
    const raw = [_]u8{ 0xFB, 0xFF, 0xBF, 0x01 };
    var encoded_buffer: [8]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buffer, &raw);
    const url_data = try decode(testing.allocator, encoded);
    defer testing.allocator.free(url_data);
    try testing.expectEqualSlices(u8, &raw, url_data);
}

test "base64：非法输入返回错误而不是 panic" {
    try testing.expectError(error.Empty, decode(testing.allocator, "   "));
    try testing.expectError(error.Invalid, decode(testing.allocator, "!!!"));
}

test "base64：data URL 前缀与空格还原" {
    const hello = try decodeDataUrl(testing.allocator, "data:image/png;base64,aGVsbG8=");
    defer testing.allocator.free(hello);
    try testing.expectEqualStrings("hello", hello);

    // `+` 被 urlencoded 成空格后仍能还原（"+w==" 是 0xFB 的 base64）
    const restored = try decodeDataUrl(testing.allocator, "data:image/png;base64, w==");
    defer testing.allocator.free(restored);
    try testing.expectEqualSlices(u8, &.{0xFB}, restored);
}

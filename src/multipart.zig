//! `multipart/form-data` 解析（对齐 ASP.NET Core `Request.ReadFormAsync()` 的表单/文件模型）。
//!
//! **为什么在本 crate 落地**（复用检索结论）：`zzig` 的 HTTP 栈只解析
//! `application/x-www-form-urlencoded`（`router.Ctx.form`），生态内也没有多段表单解析。
//! UEditor 的上传协议**必须**是多段表单，故在此实现最小可用版本；
//! 若之后出现**第二个**消费方，按「同一逻辑出现第二份就下沉」的约定上收进 `zzig.http`。
//!
//! 支持范围（够 UEditor 用，且对浏览器表单友好）：
//! - `Content-Disposition` 的 `name` / `filename` / `filename*`（RFC 5987，UTF-8）；
//! - 每个分段的 `Content-Type`（用于判断抓取/上传的真实类型）；
//! - 边界宽容：缺少前导 CRLF、`\n` 换行、尾随空白均可解析；
//! - 上限保护：[`FormData.parseLimited`] 限制分段数与单段字节数（防内存放大）。
//!
//! 不支持（显式报错，不做半吊子兼容）：`Content-Transfer-Encoding: base64` 等非二进制传输编码。

const std = @import("std");

/// 一个表单项（普通字段或文件）。
pub const Part = struct {
    /// 字段名（`name="upfile"`）
    name: []const u8,
    /// 原始文件名（`filename="a.png"`；普通字段为 `null`）
    filename: ?[]const u8 = null,
    /// 分段自带的 `Content-Type`（有则保留）
    content_type: ?[]const u8 = null,
    /// 分段正文（已剥离尾部 CRLF）
    data: []const u8 = "",

    /// 是否为文件分段。
    pub fn isFile(self: Part) bool {
        return self.filename != null;
    }

    /// 正文长度。
    pub fn len(self: Part) usize {
        return self.data.len;
    }

    /// 正文是否为空。
    pub fn isEmpty(self: Part) bool {
        return self.data.len == 0;
    }
};

/// 解析成功/失败（失败带**面向运维的具体原因**，不含歧义的笼统文案）。
pub const ParseResult = union(enum) {
    ok: FormData,
    fail: []const u8,
};

/// 解析后的表单（保序，与请求体顺序一致）。
pub const FormData = struct {
    allocator: std.mem.Allocator,
    parts: []Part = &.{},

    /// 默认上限：64 个分段、单段 64 MiB（与 HTTP 层请求体上限对齐）。
    pub const DEFAULT_MAX_PARTS: usize = 64;
    /// 默认单段字节上限。
    pub const DEFAULT_MAX_PART_BYTES: usize = 64 * 1024 * 1024;

    /// 释放全部分段（`allocator` 为请求 arena 时等价于 no-op）。
    pub fn deinit(self: *FormData) void {
        for (self.parts) |part| {
            self.allocator.free(part.name);
            if (part.filename) |name| self.allocator.free(name);
            if (part.content_type) |ct| self.allocator.free(ct);
            self.allocator.free(part.data);
        }
        self.allocator.free(self.parts);
        self.parts = &.{};
    }

    /// 按请求头 `Content-Type` 与请求体解析（默认上限）。
    pub fn parse(allocator: std.mem.Allocator, content_type: ?[]const u8, body: []const u8) ParseResult {
        return parseLimited(allocator, content_type, body, DEFAULT_MAX_PARTS, DEFAULT_MAX_PART_BYTES);
    }

    /// 解析并施加分段数/单段体积上限。
    ///
    /// `max_part_bytes` 在解析后校验单段体积；请求体总量由 HTTP 层 `max_body` 兜底。
    pub fn parseLimited(
        allocator: std.mem.Allocator,
        content_type: ?[]const u8,
        body: []const u8,
        max_parts: usize,
        max_part_bytes: usize,
    ) ParseResult {
        const header = content_type orelse return failf(allocator, "缺少 Content-Type，无法确定 multipart 边界", .{});
        const boundary = boundaryOf(header) orelse return failf(
            allocator,
            "Content-Type 不是 multipart/form-data 或缺少 boundary：{s}",
            .{truncateAlloc(allocator, header, 120)},
        );

        var delimiter: std.ArrayList(u8) = .empty;
        defer delimiter.deinit(allocator);
        delimiter.appendSlice(allocator, "--") catch return failf(allocator, "内存不足（分隔符）", .{});
        delimiter.appendSlice(allocator, boundary) catch return failf(allocator, "内存不足（分隔符）", .{});

        // 首个边界：允许位于正文开头（标准）或前面有导言（宽容）
        var cursor = switch (nextBoundary(body, delimiter.items, 0)) {
            .found => |found| found.after,
            .missing => return failf(
                allocator,
                "请求体中没有找到分隔符 --{s}（body {d} 字节）",
                .{ boundary, body.len },
            ),
        };

        var parts: std.ArrayList(Part) = .empty;
        errdefer parts.deinit(allocator);

        while (true) {
            // 边界之后：`--` = 结束；否则应紧跟 CRLF（允许尾随空白）
            const line_end = skipToLineEnd(body, cursor) catch |err| switch (err) {
                error.Malformed => return failf(allocator, "边界后既不是结束标记也不是换行（偏移 {d}）", .{cursor}),
            };
            if (line_end == .closing) break;
            const data_start = line_end.continued;

            if (parts.items.len >= max_parts) {
                return failf(allocator, "分段数量超过上限 {d}", .{max_parts});
            }

            // 分段正文 = 直到「行首 + --boundary + (--|换行)」
            const found = switch (nextBoundary(body, delimiter.items, data_start)) {
                .found => |found| found,
                .missing => return failf(
                    allocator,
                    "第 {d} 个分段缺少结束边界 --{s}",
                    .{ parts.items.len + 1, boundary },
                ),
            };

            const raw = if (found.data_end > data_start) body[data_start..found.data_end] else "";
            if (raw.len > max_part_bytes) {
                return failf(
                    allocator,
                    "第 {d} 个分段 {d} 字节，超过单段上限 {d}",
                    .{ parts.items.len + 1, raw.len, max_part_bytes },
                );
            }

            const part = parsePart(allocator, raw) catch |err| {
                return failf(allocator, "{s}", .{describePartError(err)});
            };
            parts.append(allocator, part) catch return failf(allocator, "内存不足（分段）", .{});
            cursor = found.after;
        }

        return .{ .ok = .{ .allocator = allocator, .parts = parts.toOwnedSlice(allocator) catch &.{} } };
    }

    /// 取普通字段文本（首个同名分段；严格 UTF-8，非法字节返回 `null`）。
    pub fn value(self: *const FormData, name: []const u8) ?[]const u8 {
        for (self.parts) |part| {
            if (!part.isFile() and std.mem.eql(u8, part.name, name)) {
                if (!std.unicode.utf8ValidateSlice(part.data)) return null;
                return part.data;
            }
        }
        return null;
    }

    /// 取文件分段（首个同名分段）。
    pub fn file(self: *const FormData, name: []const u8) ?*const Part {
        for (self.parts) |*part| {
            if (part.isFile() and std.mem.eql(u8, part.name, name)) return part;
        }
        return null;
    }

    /// 取全部文件分段（同名多文件；返回的切片由 `allocator` 分配，调用方释放）。
    pub fn files(self: *const FormData, allocator: std.mem.Allocator, name: []const u8) ![]const *const Part {
        var out: std.ArrayList(*const Part) = .empty;
        errdefer out.deinit(allocator);
        for (self.parts) |*part| {
            if (part.isFile() and std.mem.eql(u8, part.name, name)) try out.append(allocator, part);
        }
        return out.toOwnedSlice(allocator);
    }

    /// 取全部普通字段值（保序；同名重复保留；非法 UTF-8 跳过）。
    pub fn values(self: *const FormData, allocator: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.parts) |part| {
            if (!part.isFile() and std.mem.eql(u8, part.name, name) and std.unicode.utf8ValidateSlice(part.data)) {
                try out.append(allocator, part.data);
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

// ————— 内部实现 —————

/// 边界之后的换行形态。
const LineEnd = union(enum) {
    /// 结束标记（`--`）
    closing,
    /// 正常换行，值为下一分段的起始偏移
    continued: usize,
};

const BoundaryHit = struct {
    /// 分段正文结束偏移
    data_end: usize,
    /// 边界之后的偏移
    after: usize,
};

const BoundaryResult = union(enum) {
    found: BoundaryHit,
    missing,
};

const PartError = error{
    MissingName,
    OutOfMemory,
};

fn describePartError(err: PartError) []const u8 {
    return switch (err) {
        error.MissingName => "分段缺少 Content-Disposition 的 name 参数",
        error.OutOfMemory => "内存不足（分段头）",
    };
}

/// 找到下一个**真实**边界：`--boundary` 必须位于行首（正文开头或紧接 CRLF/LF），
/// 且其后（允许 transport padding）必须是 `--`、CRLF 或 LF。
///
/// 正文中的同前缀字节（如 `\r\n--boundaryX`）不会被误判为边界。
fn nextBoundary(body: []const u8, delimiter: []const u8, from: usize) BoundaryResult {
    var search = from;
    while (true) {
        const pos = std.mem.indexOfPos(u8, body, search, delimiter) orelse return .missing;

        const data_end: ?usize = if (pos == 0)
            0
        else if (pos >= 2 and std.mem.eql(u8, body[pos - 2 .. pos], "\r\n"))
            pos - 2
        else if (body[pos - 1] == '\n')
            pos - 1
        else
            null;

        const boundary_start = pos;
        if (data_end == null) {
            search = boundary_start + 1;
            continue;
        }

        // 后随字符校验（跳过 transport padding）
        var index = pos + delimiter.len;
        while (index < body.len and (body[index] == ' ' or body[index] == '\t')) : (index += 1) {}
        const followed = index >= body.len or
            body[index] == '\r' or
            body[index] == '\n' or
            (index + 1 < body.len and std.mem.eql(u8, body[index .. index + 2], "--"));
        if (!followed) {
            search = boundary_start + 1;
            continue;
        }
        return .{ .found = .{ .data_end = data_end.?, .after = index } };
    }
}

/// 跳过边界行剩余字节，判定是结束标记还是普通分段。
fn skipToLineEnd(body: []const u8, cursor: usize) error{Malformed}!LineEnd {
    var index = cursor;
    // 允许边界后有空白（RFC 2046 允许 transport padding）
    while (index < body.len and (body[index] == ' ' or body[index] == '\t')) : (index += 1) {}

    if (index + 1 < body.len and std.mem.eql(u8, body[index .. index + 2], "--")) return .closing;
    if (index + 1 < body.len and std.mem.eql(u8, body[index .. index + 2], "\r\n")) return .{ .continued = index + 2 };
    if (index < body.len and body[index] == '\n') return .{ .continued = index + 1 };
    return error.Malformed;
}

/// 解析单个分段：头部 + 正文。
fn parsePart(allocator: std.mem.Allocator, raw: []const u8) PartError!Part {
    const split = splitHeaders(raw);
    const head = split.head;

    var name: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var content_type: ?[]const u8 = null;

    var lines = std.mem.splitAny(u8, head, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(key, "content-disposition")) {
            name = dispositionParam(value, "name");
            filename = dispositionParam(value, "filename") orelse
                if (dispositionParam(value, "filename*")) |encoded|
                    try decodeExtValue(allocator, encoded)
                else
                    null;
        } else if (std.ascii.eqlIgnoreCase(key, "content-type")) {
            content_type = try allocator.dupe(u8, value);
        }
    }

    const part_name = name orelse return error.MissingName;

    // 没有文件名的空文件段（部分浏览器会发送 `filename=""`）按普通字段处理
    const effective_filename: ?[]const u8 = if (filename) |f| if (f.len == 0) null else try allocator.dupe(u8, f) else null;

    return Part{
        .name = try allocator.dupe(u8, part_name),
        .filename = effective_filename,
        .content_type = content_type,
        .data = try allocator.dupe(u8, split.body),
    };
}

const HeaderSplit = struct {
    head: []const u8,
    body: []const u8,
};

/// 头部与正文分隔（`\r\n\r\n`，宽容 `\n\n`）；无头部时整段当正文。
fn splitHeaders(raw: []const u8) HeaderSplit {
    if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |pos| {
        return .{ .head = raw[0..pos], .body = raw[pos + 4 ..] };
    }
    if (std.mem.indexOf(u8, raw, "\n\n")) |pos| {
        return .{ .head = raw[0..pos], .body = raw[pos + 2 ..] };
    }
    return .{ .head = "", .body = raw };
}

/// 从 `Content-Type` 提取 boundary（容忍引号与首尾空白）。
fn boundaryOf(content_type: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, content_type, " \t");
    if (!startsWithIgnoreCase(trimmed, "multipart/form-data")) return null;

    // 大小写不敏感的 `boundary=` 查找（配置可能写成 BOUNDARY=）
    const key = "boundary=";
    const lower_index = indexOfIgnoreCase(content_type, key) orelse return null;
    var value = std.mem.trimStart(u8, content_type[lower_index + key.len ..], " \t");
    if (value.len == 0) return null;

    if (value[0] == '"' or value[0] == '\'') {
        const quote = value[0];
        const rest = value[1..];
        const end = std.mem.indexOfScalar(u8, rest, quote) orelse return null;
        return rest[0..end];
    }
    // 未加引号：截到 `;`
    if (std.mem.indexOfScalar(u8, value, ';')) |semi| value = value[0..semi];
    value = std.mem.trim(u8, value, " \t\r\n");
    return if (value.len == 0) null else value;
}

/// 取 `Content-Disposition` 里的参数值（去引号）。
fn dispositionParam(header: []const u8, key: []const u8) ?[]const u8 {
    var segments = std.mem.splitScalar(u8, header, ';');
    _ = segments.next(); // 跳过 `form-data`
    while (segments.next()) |raw_segment| {
        const segment = std.mem.trim(u8, raw_segment, " \t");
        const eq = std.mem.indexOfScalar(u8, segment, '=') orelse continue;
        const name = std.mem.trim(u8, segment[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(name, key)) continue;

        var value = std.mem.trim(u8, segment[eq + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        return value;
    }
    return null;
}

/// RFC 5987 `ext-value` 解码：`UTF-8''%E4%B8%AD.txt` → `中.txt`（仅支持 UTF-8 字符集）。
fn decodeExtValue(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    var parts = std.mem.splitScalar(u8, value, '\'');
    const charset = parts.next() orelse "";
    _ = parts.next() orelse "";
    const encoded = parts.next() orelse value;
    if (!std.ascii.eqlIgnoreCase(charset, "utf-8")) return allocator.dupe(u8, encoded);
    return percentDecode(allocator, encoded);
}

/// 百分号解码（非法序列原样保留）。
fn percentDecode(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '%' and index + 2 < text.len) {
            if (hexVal(text[index + 1])) |high| {
                if (hexVal(text[index + 2])) |low| {
                    try out.append(allocator, (high << 4) | low);
                    index += 3;
                    continue;
                }
            }
        }
        try out.append(allocator, text[index]);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

/// 截断长文本用于错误消息（避免把整段二进制倒进日志）。
fn truncateAlloc(allocator: std.mem.Allocator, text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    const head = text[0..max];
    return std.fmt.allocPrint(allocator, "{s}…", .{head}) catch head;
}

/// 格式化失败原因（arena 分配；内存不足时退化为静态文案）。
fn failf(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ParseResult {
    const message = std.fmt.allocPrint(allocator, fmt, args) catch "multipart 解析失败（内存不足）";
    return .{ .fail = message };
}

// ————— 测试 —————

const testing = std.testing;

fn buildBody(allocator: std.mem.Allocator, boundary: []const u8, parts: []const TestPart) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (parts) |part| {
        try out.appendSlice(allocator, "--");
        try out.appendSlice(allocator, boundary);
        try out.appendSlice(allocator, "\r\n");
        if (part.filename) |file| {
            try out.appendSlice(allocator, "Content-Disposition: form-data; name=\"");
            try out.appendSlice(allocator, part.name);
            try out.appendSlice(allocator, "\"; filename=\"");
            try out.appendSlice(allocator, file);
            try out.appendSlice(allocator, "\"\r\nContent-Type: application/octet-stream\r\n\r\n");
        } else {
            try out.appendSlice(allocator, "Content-Disposition: form-data; name=\"");
            try out.appendSlice(allocator, part.name);
            try out.appendSlice(allocator, "\"\r\n\r\n");
        }
        try out.appendSlice(allocator, part.data);
        try out.appendSlice(allocator, "\r\n");
    }
    try out.appendSlice(allocator, "--");
    try out.appendSlice(allocator, boundary);
    try out.appendSlice(allocator, "--\r\n");
    return out.toOwnedSlice(allocator);
}

const TestPart = struct {
    name: []const u8,
    filename: ?[]const u8,
    data: []const u8,
};

test "multipart：解析普通字段与文件" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const boundary = "----WebKitFormBoundaryABC123";
    const body = try buildBody(arena, boundary, &.{
        .{ .name = "action", .filename = null, .data = "uploadimage" },
        .{ .name = "upfile", .filename = "a.png", .data = "\x89PNG\r\n\x1a\nDATA" },
    });
    const content_type = try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{boundary});

    const result = FormData.parse(arena, content_type, body);
    try testing.expect(result == .ok);
    const form = result.ok;

    try testing.expectEqual(@as(usize, 2), form.parts.len);
    try testing.expectEqualStrings("uploadimage", form.value("action").?);

    const file = form.file("upfile").?;
    try testing.expectEqualStrings("a.png", file.filename.?);
    try testing.expectEqualStrings("\x89PNG\r\n\x1a\nDATA", file.data);
    try testing.expectEqualStrings("application/octet-stream", file.content_type.?);
}

test "multipart：引号边界与裸 LF 换行" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "--abc\nContent-Disposition: form-data; name=\"x\"\n\n1\n--abc--";
    const result = FormData.parse(arena, "multipart/form-data; boundary=\"abc\"", body);
    try testing.expect(result == .ok);
    try testing.expectEqualStrings("1", result.ok.value("x").?);
}

test "multipart：RFC 5987 中文文件名" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "--b1\r\nContent-Disposition: form-data; name=\"upfile\"; filename*=UTF-8''%E4%B8%AD%E6%96%87.txt\r\n\r\ndata\r\n--b1--";
    const result = FormData.parse(arena, "multipart/form-data; boundary=b1", body);
    try testing.expect(result == .ok);
    try testing.expectEqualStrings("中文.txt", result.ok.file("upfile").?.filename.?);
}

test "multipart：缺少 boundary / 分隔符时给出具体原因" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wrong_type = FormData.parse(arena, "application/json", "{}");
    try testing.expect(wrong_type == .fail);
    try testing.expect(std.mem.indexOf(u8, wrong_type.fail, "multipart") != null);

    const no_delimiter = FormData.parse(arena, "multipart/form-data; boundary=zz", "nothing");
    try testing.expect(no_delimiter == .fail);
    try testing.expect(std.mem.indexOf(u8, no_delimiter.fail, "没有找到分隔符") != null);

    const no_header = FormData.parse(arena, null, "x");
    try testing.expect(no_header == .fail);
    try testing.expect(std.mem.indexOf(u8, no_header.fail, "Content-Type") != null);
}

test "multipart：分段数与单段体积上限生效" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildBody(arena, "b2", &.{
        .{ .name = "a", .filename = null, .data = "1" },
        .{ .name = "b", .filename = null, .data = "2" },
    });
    const too_many = FormData.parseLimited(arena, "multipart/form-data; boundary=b2", body, 1, 1024);
    try testing.expect(too_many == .fail);
    try testing.expect(std.mem.indexOf(u8, too_many.fail, "分段数量超过上限") != null);

    const big_body = try buildBody(arena, "b3", &.{
        .{ .name = "big", .filename = null, .data = "1234567890" },
    });
    const too_big = FormData.parseLimited(arena, "multipart/form-data; boundary=b3", big_body, 8, 4);
    try testing.expect(too_big == .fail);
    try testing.expect(std.mem.indexOf(u8, too_big.fail, "超过单段上限") != null);
}

test "multipart：空文件名按普通字段处理" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "--b4\r\nContent-Disposition: form-data; name=\"upfile\"; filename=\"\"\r\n\r\n\r\n--b4--";
    const result = FormData.parseLimited(arena, "multipart/form-data; boundary=b4", body, 8, 1024);
    try testing.expect(result == .ok);
    try testing.expect(result.ok.file("upfile") == null);
    try testing.expectEqualStrings("", result.ok.value("upfile").?);
}

test "multipart：正文含类边界字节不会误判" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const payload = "head--b5-not-a-marker\r\n--b5x\r\ntail";
    const body = try buildBody(arena, "b5", &.{
        .{ .name = "f", .filename = "x.bin", .data = payload },
    });
    const result = FormData.parseLimited(arena, "multipart/form-data; boundary=b5", body, 8, 4096);
    try testing.expect(result == .ok);
    try testing.expectEqualStrings(payload, result.ok.file("f").?.data);
}

test "multipart：同名多值保序" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildBody(arena, "b6", &.{
        .{ .name = "source[]", .filename = null, .data = "http://a/1.png" },
        .{ .name = "source[]", .filename = null, .data = "http://a/2.png" },
    });
    const result = FormData.parse(arena, "multipart/form-data; boundary=b6", body);
    try testing.expect(result == .ok);
    const values = try result.ok.values(arena, "source[]");
    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expectEqualStrings("http://a/2.png", values[1]);
}

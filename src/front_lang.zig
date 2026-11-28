//! 【通用】前台多语言：**URL 前缀优先**（`/en/category/guanyu` 显示英文；默认语言不带前缀）。
//!
//! 从 `site.zig` 拆出来（2026-11-23）—— 这一块与「站点核心」没有耦合，
//! 只依赖语言仓储（`?*language.Store`）与请求上下文，独立成文件更好读、也好测。
//! 不复用后台的语言口径：**前台认地址栏，后台认用户偏好**，两者完全隔离。

const std = @import("std");
const zzig = @import("zzig");
const lang_mod = @import("language.zig");
const pek_zwaf = @import("pek_zwaf");

/// 品牌区回退图标：取站点名的**首个字符**（UTF-8 安全，中文站点名也能取对）。
pub fn brandInitial(name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return "P";
    const need = std.unicode.utf8ByteSequenceLength(trimmed[0]) catch 1;
    return trimmed[0..@min(need, trimmed.len)];
}

/// 语言的**短码**（切换链接与地址栏用）：`zh` / `zh-CN` / `zh-Hans` → `cn`，其余取主语言子标签。
///
/// 为什么不直接用完整文化码：`?culture=zh-CN` 在地址栏里又长又「看不出效果」，
/// 而 `?culture=cn` / `?culture=en` 一眼能分辨。
///
/// **中文变体不再一律压成 `cn`**：简体（`zh` / `zh-CN` / `zh-Hans`）才用 `cn`；
/// `zh-TW` / `zh-HK` 这类保留完整码 —— 否则同时启用简繁时两者前缀都是 `cn`，路由直接冲突。
pub fn shortLangCode(code: []const u8) []const u8 {
    const primary = if (std.mem.indexOfScalar(u8, code, '-')) |i| code[0..i] else code;
    if (std.ascii.eqlIgnoreCase(primary, "zh")) {
        const simplified = std.ascii.eqlIgnoreCase(code, "zh") or
            std.ascii.eqlIgnoreCase(code, "zh-CN") or
            std.ascii.eqlIgnoreCase(code, "zh-Hans");
        return if (simplified) "cn" else code; // zh-TW / zh-HK 原样
    }
    return primary;
}

/// 从请求路径的首段识别语言：`/cn/category/guanyu` → `cn` 对应那行；`/category/guanyu` → null（未带前缀）。
///
/// 不依赖路由参数：任何页面都能直接拿到「本请求属于哪个语言」。
pub fn langOfPath(store: ?*lang_mod.Store, path: []const u8) ?lang_mod.Language {
    const s = store orelse return null;
    if (path.len < 2 or path[0] != '/') return null;
    const rest = path[1..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const seg = rest[0..end];
    if (seg.len == 0) return null;
    for (s.all()) |row| {
        if (!row.status) continue;
        if (std.ascii.eqlIgnoreCase(shortLangCode(row.code), seg)) return row;
    }
    return null;
}

/// 路径的语言前缀是否指向**已停用**的语言。
///
/// 前台路由是**启动时**按当时启用的语言逐条注册的；运营在「语言包」里停用某个语言后，
/// 那些路由不会自动撤销。这里给 `Site.handler` 做一层运行期兜底：停用语言的 URL 一律 404，
/// 与「停用即没有这个语言」的结果一致。
///
/// 与 [`langOfPath`] 的区别：那个**跳过**停用语言（用于「这是哪个启用语言」），
/// 这个专门指出「这段前缀是个已经关掉的语言」。
pub fn disabledLangPrefix(store: ?*lang_mod.Store, path: []const u8) bool {
    const s = store orelse return false;
    if (path.len < 2 or path[0] != '/') return false;
    const rest = path[1..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const seg = rest[0..end];
    if (seg.len == 0) return false;
    var disabled = false;
    for (s.all()) |row| {
        if (!std.ascii.eqlIgnoreCase(shortLangCode(row.code), seg)) continue;
        if (row.status) return false; // 同名启用语言优先
        disabled = true;
    }
    return disabled;
}

/// 当前语言 id：**URL 前缀优先**；无前缀 = 默认语言。
///
/// 不再看 Cookie：地址栏是唯一口径，否则「Cookie 是英文 + 访问 `/category/guanyu`」会渲 染英文、
/// 但链接又都是中文地址，地址与内容对不上。
pub fn frontCultureId(store: ?*lang_mod.Store, path: []const u8) i32 {
    const s = store orelse return 0;
    if (langOfPath(store, path)) |row| return row.id;
    return if (s.defaultLanguage()) |row| row.id else 0;
}

/// 给前台页面模型补 `lang` / `languages` / `linkPrefix` / `currentLangName`
/// （与后台各用各的语言来源）。
pub fn withFrontLanguage(
    store: ?*lang_mod.Store,
    arena: std.mem.Allocator,
    c: *zzig.web.Ctx,
    model: zzig.web.Value,
) !zzig.web.Value {
    const s = store orelse return model;
    const culture_id = frontCultureId(store, c.req.path);

    var builder = zzig.web.ObjectBuilder.init(arena);
    switch (model) {
        .object => |fields| {
            for (fields) |field| try builder.put(field.name, field.value);
        },
        else => {},
    }
    try builder.put("lang", try s.buildLangObject(arena, culture_id));
    // 当前语言 id：视图组件的后端（如顶部导航标签翻译）需要它，但拿不到 request
    try builder.put("cultureId", .{ .integer = culture_id });

    // `linkPrefix`：所有站内链接都拼它（`""` 不会出现 —— 前台页面一律带语言前缀）。
    // 视图里写 `href="@Model.linkPrefix/base64"`，切到英文就是 `/en/category/guanyu`。
    const current_path = c.req.path;
    const prefix = try currentLangPrefix(store, arena, current_path);
    try builder.put("linkPrefix", .{ .string = prefix });
    // 去掉语言前缀后的「页面路径」（语言切换时拼目标前缀用）：`/en/category/guanyu` → `/category/guanyu`
    const bare_path = barePagePath(prefix, current_path);

    var options: std.ArrayList(zzig.web.Value) = .empty;
    var count: usize = 0;
    // 当前语言的**显示名**（如「中文简体」）：挂到模型上给 `<summary>` 用，
    // 否则视图里没有「赋值」能力，无法在列表循环外拿到当前项。
    var current_name: []const u8 = "";
    for (s.all()) |row| {
        if (!row.status) continue;
        count += 1;
        const code = shortLangCode(row.code);
        var item = zzig.web.ObjectBuilder.init(arena);
        try item.str("name", row.name);
        try item.str("code", row.code);
        try item.str("shortCode", code);
        // 切到**默认语言**时地址不带前缀（`/category/guanyu`），切到其它语言才加 `/en`；
        // 这样点一下语言按钮，地址栏的变化正好符合「默认语言省略前缀」的习惯。
        const target_prefix = try langPrefixForRow(store, arena, row.id, row.code);
        try item.str("url", try std.fmt.allocPrint(arena, "{s}{s}", .{ target_prefix, bare_path }));
        try item.boolean("current", row.id == culture_id);
        // 直接在模型里算好 class：模板里 `@if` 写在属性中间会渲染出 `<text>` 标签（踩过）
        try item.str("className", if (row.id == culture_id) "is-active" else "");
        if (row.id == culture_id) current_name = row.name;
        try options.append(arena, item.finish());
    }
    try builder.put("languages", .{ .list = try options.toOwnedSlice(arena) });
    try builder.put("hasLanguages", .{ .boolean = count > 1 });
    try builder.put("currentLangName", .{ .string = current_name });
    return builder.finish();
}

/// 当前请求的语言前缀（非默认语言如 `/en`）。
///
/// **默认语言不加前缀**（`/category/guanyu` 就是中文），只有切到其它语言才加 `/en`；
/// 这样大多数访客看到的地址最短，也不会出现「中文页带 /cn」的冗余。
pub fn currentLangPrefix(store: ?*lang_mod.Store, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const s = store orelse return "";
    const row = langOfPath(store, path) orelse
        (if (s.defaultLanguage()) |def| def else return "");
    if (s.defaultLanguage()) |def| {
        if (def.id == row.id) return "";
    }
    return std.fmt.allocPrint(arena, "/{s}", .{shortLangCode(row.code)});
}

/// 某个语言对应的链接前缀：默认语言为空串，其余为 `/{短码}`。
pub fn langPrefixForRow(store: ?*lang_mod.Store, arena: std.mem.Allocator, row_id: i32, code: []const u8) ![]const u8 {
    if (store) |s| {
        if (s.defaultLanguage()) |def| {
            if (def.id == row_id) return "";
        }
    }
    return std.fmt.allocPrint(arena, "/{s}", .{shortLangCode(code)});
}

/// 去掉语言前缀的页面路径：`("/en", "/en/category/guanyu")` → `/category/guanyu`；`("/en", "/en")` → `/`。
///
/// 语言切换时用它拼目标地址，避免出现 `/en/en/category/guanyu` 这种叠前缀。
pub fn barePagePath(prefix: []const u8, path: []const u8) []const u8 {
    if (prefix.len > 0 and std.mem.startsWith(u8, path, prefix)) {
        const rest = path[prefix.len..];
        return if (rest.len == 0) "/" else rest;
    }
    return path;
}

/// 默认语言**不带前缀**：`/cn/category/guanyu` → **301** `/category/guanyu`（保留查询串）。
///
/// 用户口径（2026-11-23）：「我不是说与默认语言一致，就不要有这个 /cn 吗？」
/// —— 地址栏里不该出现默认语言的前缀。之前只是「链接生成时不加前缀」
/// （旧书签/外链进来的 `/cn/...` 仍能 200），现在直接跳到干净地址。
///
/// 只对 GET / HEAD 重定向：301 会把 POST 变成 GET，表单提交按原路径处理即可
/// （页面内的链接与 `form action` 都已是不带前缀的地址）。
pub fn stripDefaultLangPrefix(store: ?*lang_mod.Store, c: *zzig.web.Ctx) !?zzig.web.Response {
    const s = store orelse return null;
    const def = s.defaultLanguage() orelse return null;
    const code = shortLangCode(def.code);
    if (code.len == 0) return null;

    const path = c.req.path;
    if (path.len < code.len + 1 or path[0] != '/') return null;
    if (!std.ascii.eqlIgnoreCase(path[1 .. 1 + code.len], code)) return null;
    const rest = path[1 + code.len ..];
    if (rest.len > 0 and rest[0] != '/') return null; // `/cnxxx` 不是语言前缀

    const is_get_or_head = std.ascii.eqlIgnoreCase(c.req.method, "GET") or
        std.ascii.eqlIgnoreCase(c.req.method, "HEAD");
    if (!is_get_or_head) return null;

    const target = if (rest.len == 0) "/" else rest;
    const location = if (c.req.query.len > 0)
        try std.fmt.allocPrint(c.arena, "{s}?{s}", .{ target, c.req.query })
    else
        target;
    const headers = try c.arena.alloc(std.http.Header, 1);
    headers[0] = .{ .name = "location", .value = location };
    return .{
        .status = .moved_permanently,
        .content_type = "text/plain; charset=utf-8",
        .body = "",
        .headers = headers,
    };
}

test "front_lang：默认语言前缀要被去掉（301），其它语言/无关路径不动" {
    // 纯路径判定抽成可测的几行：这里只验证 shortLangCode 与「首段相等」的语义，
    // 完整重定向靠 HTTP 实测（`/cn/client-ip` → 301 `/client-ip`）。
    try std.testing.expectEqualStrings("cn", shortLangCode("zh-CN"));
    try std.testing.expectEqualStrings("/category/guanyu", barePagePath("/cn", "/cn/category/guanyu"));
    try std.testing.expectEqualStrings("/", barePagePath("/cn", "/cn"));
}

test "front_lang：短码把 zh 系列统一成 cn，其余取主标签" {
    try std.testing.expectEqualStrings("cn", shortLangCode("zh"));
    try std.testing.expectEqualStrings("cn", shortLangCode("zh-CN"));
    try std.testing.expectEqualStrings("cn", shortLangCode("zh-Hans"));
    try std.testing.expectEqualStrings("en", shortLangCode("en-US"));
    try std.testing.expectEqualStrings("ja", shortLangCode("ja"));
}

test "front_lang：barePagePath 去掉语言前缀且不叠前缀" {
    try std.testing.expectEqualStrings("/category/guanyu", barePagePath("/en", "/en/category/guanyu"));
    try std.testing.expectEqualStrings("/", barePagePath("/en", "/en"));
    try std.testing.expectEqualStrings("/category/guanyu", barePagePath("", "/category/guanyu"));
    try std.testing.expectEqualStrings("/", barePagePath("/en", "/"));
}

test "front_lang：没有语言仓储时一律回退默认（不白屏）" {
    try std.testing.expect(langOfPath(null, "/cn/category/guanyu") == null);
    try std.testing.expectEqual(@as(i32, 0), frontCultureId(null, "/en/category/guanyu"));
}
// ————— 语言协商（Cookie 记忆 + 机器人豁免）—————

/// 从 `Cookie` 请求头取指定名字的值（解析走 `zzig.nat.cookie`，这里只补 trim）。
pub fn cookieValue(header: []const u8, name: []const u8) ?[]const u8 {
    const raw = zzig.cookie.value(header, name) orelse return null;
    return std.mem.trim(u8, raw, " \t");
}

/// 拼一条 `Set-Cookie`（`Path=/` + `Max-Age` + `SameSite=Lax`；不用 HttpOnly：
/// 前端语言浮层可能要读，值不含敏感信息）。
pub fn setCookieValue(arena: std.mem.Allocator, cookie_name: []const u8, prefix: []const u8, max_age: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}={s}; Path=/; Max-Age={d}; SameSite=Lax", .{ cookie_name, prefix, max_age });
}

/// 是否机器人 / 抓取器 / 命令行客户端（这类请求**一律不做语言重定向**，
/// 否则收录会抖动、hreflang 自相矛盾）。复用 WAF 的名单与判定顺序。
pub fn isBot(user_agent: []const u8) bool {
    return pek_zwaf.bots.classifyCached(user_agent) != null;
}

test "front_lang：Cookie 取值与 Set-Cookie 拼装，机器人判定" {
    try std.testing.expectEqualStrings("en", cookieValue("a=1; site_lang=en; b=2", "site_lang").?);
    try std.testing.expectEqualStrings("", cookieValue("site_lang=; x=1", "site_lang").?);
    try std.testing.expect(cookieValue("other=en", "site_lang") == null);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cookie = try setCookieValue(arena_state.allocator(), "site_lang", "en", 100);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "site_lang=en; Path=/; Max-Age=100") != null);

    try std.testing.expect(isBot("Mozilla/5.0 (compatible; Googlebot/2.1)"));
    try std.testing.expect(isBot("curl/8.4.0"));
    try std.testing.expect(!isBot("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120 Safari/537.36"));
}
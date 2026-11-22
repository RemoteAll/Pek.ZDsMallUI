//! 多语言（对齐 C# `Language` + `LocaleStringResource` 两张表）与后台文案。
//!
//! 三个约束（2026-11-22 用户明确要求）：
//! 1. **后台语言与前台语言互相隔离**：后台认「后台用户偏好」（`AdminUser.LanguageId`），
//!    前台认自己的 Cookie（`front_lang`），两边互不影响；
//! 2. **每个用户各自一份**：后台切换语言写在自己的用户记录里，不影响别人；
//! 3. **视图取文案只能是 `@Model.lang.<标识符>`**：Razor 子集不支持方法调用，也不支持字符串下标，
//!    所以 key 统一规范成标识符（`menu.settings` → `menu_settings`），内置清单见 [`BUILTIN_STRINGS`]。
//!
//! 语言包（DB）只覆盖文本，不改变视图能引用的键集合：视图引用 `BUILTIN_STRINGS` 里的键，
//! 缺失回退内置中文/英文，所以新增语言不会让页面报「属性不存在」。

const std = @import("std");
const zzig = @import("zzig");

const sqlite = zzig.db.sqlite;
const value = zzig.web.value;

/// 内置文案（key → 中文 / 英文）。
///
/// **新增界面文案**：在这里加一行，再在视图里写 `@Model.lang.<标识符>`；
/// 语言包管理页可以覆盖这些文本，但键本身由代码定义（视图编译期就要知道它存在）。
pub const Builtin = struct {
    key: []const u8,
    zh: []const u8,
    en: []const u8,
};

pub const BUILTIN_STRINGS = [_]Builtin{
    .{ .key = "menu.console", .zh = "控制台", .en = "Console" },
    .{ .key = "menu.settings", .zh = "设置", .en = "Settings" },
    .{ .key = "menu.product", .zh = "产品", .en = "Products" },
    .{ .key = "menu.website", .zh = "网站", .en = "Website" },
    .{ .key = "menu.welcome", .zh = "欢迎页", .en = "Dashboard" },
    .{ .key = "menu.site_settings", .zh = "站点设置", .en = "Site settings" },
    .{ .key = "menu.culture", .zh = "多语言", .en = "Cultures" },
    .{ .key = "menu.languages", .zh = "语言包", .en = "Languages" },
    .{ .key = "menu.admin_user", .zh = "管理员管理", .en = "Administrators" },
    .{ .key = "user.greeting", .zh = "您好", .en = "Hello" },
    .{ .key = "user.home", .zh = "访问首页", .en = "Visit site" },
    .{ .key = "user.clear_cache", .zh = "清除缓存", .en = "Clear cache" },
    .{ .key = "user.change_password", .zh = "修改密码", .en = "Change password" },
    .{ .key = "user.logout", .zh = "安全退出", .en = "Sign out" },
    .{ .key = "user.language", .zh = "语言", .en = "Language" },
    .{ .key = "common.save", .zh = "保存", .en = "Save" },
    .{ .key = "common.delete", .zh = "删除", .en = "Delete" },
    .{ .key = "common.edit", .zh = "编辑", .en = "Edit" },
    .{ .key = "common.add", .zh = "新增", .en = "Add" },
    .{ .key = "common.search", .zh = "搜索", .en = "Search" },
    .{ .key = "common.back", .zh = "返回", .en = "Back" },
    .{ .key = "common.actions", .zh = "操作", .en = "Actions" },
    .{ .key = "common.status", .zh = "状态", .en = "Status" },
    .{ .key = "common.enabled", .zh = "启用", .en = "Enabled" },
    .{ .key = "common.disabled", .zh = "停用", .en = "Disabled" },
    .{ .key = "common.default", .zh = "默认", .en = "Default" },
    .{ .key = "common.name", .zh = "名称", .en = "Name" },
    .{ .key = "common.order", .zh = "排序", .en = "Order" },
    .{ .key = "common.saved", .zh = "保存成功", .en = "Saved" },
    .{ .key = "page.dashboard.title", .zh = "管理后台", .en = "Admin panel" },
    .{ .key = "page.dashboard.user", .zh = "当前用户", .en = "Current user" },
    .{ .key = "page.dashboard.site_name", .zh = "站点名称", .en = "Site name" },
    .{ .key = "page.dashboard.area", .zh = "当前区域", .en = "Area" },
    .{ .key = "page.dashboard.area_desc", .zh = "路由前缀，可随配置改名", .en = "route prefix, configurable" },
    .{ .key = "page.dashboard.upload", .zh = "上传目录", .en = "Upload folder" },
    .{ .key = "page.dashboard.version", .zh = "后台版本", .en = "Version" },
    .{ .key = "page.dashboard.shortcuts", .zh = "快捷入口", .en = "Shortcuts" },
    .{ .key = "page.culture.title", .zh = "多语言管理", .en = "Cultures" },
    .{ .key = "page.culture.english", .zh = "英文名称", .en = "English name" },
    .{ .key = "page.culture.code", .zh = "语言代码", .en = "Culture code" },
    .{ .key = "page.languages.title", .zh = "语言包管理", .en = "Language resources" },
    .{ .key = "page.languages.key", .zh = "资源键", .en = "Key" },
    .{ .key = "page.languages.value", .zh = "翻译文本", .en = "Value" },
    .{ .key = "page.languages.language", .zh = "语言", .en = "Language" },
};

/// 默认语言代码（没有默认语言记录时使用）。
pub const DEFAULT_CULTURE_CODE = "zh-CN";

/// `key` → Razor 子集可用的标识符：非 `[A-Za-z0-9_]` 一律变 `_`；数字开头前缀 `k_`。
pub fn identifier(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, key.len + 2);
    var len: usize = 0;
    for (key) |c| {
        out[len] = if (std.ascii.isAlphanumeric(c)) c else '_';
        len += 1;
    }
    if (len > 0 and std.ascii.isDigit(out[0])) {
        out[0] = 'k';
        out[1] = '_';
        len = 2;
        // 重新覆盖原内容（数字开头的情况极少）
        for (key) |c| {
            out[len] = if (std.ascii.isAlphanumeric(c)) c else '_';
            len += 1;
        }
    }
    return out[0..len];
}

/// 界面语言。
pub const Language = struct {
    id: i32,
    name: []const u8,
    english_name: []const u8,
    code: []const u8,
    status: bool,
    order: i32,
    is_default: bool,
};

/// 语言包读取结果（`culture_id` → 键值）。线程安全：整体替换快照，读路径无锁。
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 数据库路径（`null` = 纯内存：只用内置文案，不支持管理页写库）
    db_path: ?[]const u8 = null,
    languages: []Language = &.{},
    /// `culture_id` → (key → value)
    resources: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty,
    mutex: zzig.compat.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Store {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Store) void {
        self.freeAllLocked();
        self.mutex.lock();
        self.resources.deinit(self.allocator);
        self.mutex.unlock();
    }

    fn freeAllLocked(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.languages) |row| {
            self.allocator.free(row.name);
            self.allocator.free(row.english_name);
            self.allocator.free(row.code);
        }
        if (self.languages.len > 0) self.allocator.free(self.languages);
        self.languages = &.{};

        var it = self.resources.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var inner = entry.value_ptr.iterator();
            while (inner.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
                self.allocator.free(kv.value_ptr.*);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.resources.clearRetainingCapacity();
    }

    /// 从数据库重载（启动一次 + 管理页保存后调用；读路径不查库）。
    pub fn reload(self: *Store) !void {
        const db_path = self.db_path orelse {
            // 内存模式：内置两种语言（中文/英文），文案走内置清单
            self.freeAllLocked();
            try self.setBuiltinLanguages();
            return;
        };

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000 });
        defer db.close();

        var langs: std.ArrayList(Language) = .empty;
        if (db.prepare(self.allocator, "SELECT Id, Name, EnglishName, UniqueSeoCode, Status, DisplayOrder, IsDefault FROM Language ORDER BY DisplayOrder, Id")) |stmt_in| {
            var stmt = stmt_in;
            defer stmt.finalize();
            try stmt.bindAll(&.{});
            while (stmt.hasRow()) {
                const row = try stmt.readRow(arena);
                try langs.append(self.allocator, .{
                    .id = rowInt(row, "Id"),
                    .name = try self.allocator.dupe(u8, rowText(row, "Name")),
                    .english_name = try self.allocator.dupe(u8, rowText(row, "EnglishName")),
                    .code = try self.allocator.dupe(u8, rowText(row, "UniqueSeoCode")),
                    .status = rowInt(row, "Status") != 0,
                    .order = rowInt(row, "DisplayOrder"),
                    .is_default = rowInt(row, "IsDefault") != 0,
                });
            }
        } else |err| {
            zzig.Logger.warn("[ZDsMallUI] 读取多语言失败（{s}）：语言列表按内置处理", .{@errorName(err)});
        }

        var resources: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty;
        if (db.prepare(self.allocator, "SELECT CultureId, Key, Value FROM LocaleStringResource")) |stmt_in| {
            var stmt = stmt_in;
            defer stmt.finalize();
            try stmt.bindAll(&.{});
            while (stmt.hasRow()) {
                const row = try stmt.readRow(arena);
                const culture_key = try std.fmt.allocPrint(self.allocator, "{d}", .{rowInt(row, "CultureId")});
                const gop = try resources.getOrPut(self.allocator, culture_key);
                if (!gop.found_existing) gop.value_ptr.* = .empty else self.allocator.free(culture_key);
                const key_copy = try self.allocator.dupe(u8, rowText(row, "Key"));
                const value_copy = try self.allocator.dupe(u8, rowText(row, "Value"));
                if (gop.value_ptr.getEntry(key_copy)) |existing| {
                    self.allocator.free(existing.key_ptr.*);
                    self.allocator.free(existing.value_ptr.*);
                    existing.key_ptr.* = key_copy;
                    existing.value_ptr.* = value_copy;
                } else {
                    try gop.value_ptr.put(self.allocator, key_copy, value_copy);
                }
            }
        } else |err| {
            zzig.Logger.warn("[ZDsMallUI] 读取语言包失败（{s}）：全部按内置文案处理", .{@errorName(err)});
        }

        self.freeAllLocked();
        self.mutex.lock();
        self.languages = try langs.toOwnedSlice(self.allocator);
        self.resources = resources;
        const empty = self.languages.len == 0;
        self.mutex.unlock();

        if (empty) {
            // 首次部署：补两种语言，保证后台能选（下次读取生效）
            try self.ensureSeedLanguages(db_path);
            try self.reload();
        }
    }

    fn setBuiltinLanguages(self: *Store) !void {
        const rows = [_]Language{
            .{ .id = 1, .name = "简体中文", .english_name = "Chinese (Simplified)", .code = "zh-CN", .status = true, .order = 1, .is_default = true },
            .{ .id = 2, .name = "English", .english_name = "English", .code = "en-US", .status = true, .order = 2, .is_default = false },
        };
        var langs: std.ArrayList(Language) = .empty;
        for (rows) |row| {
            try langs.append(self.allocator, .{
                .id = row.id,
                .name = try self.allocator.dupe(u8, row.name),
                .english_name = try self.allocator.dupe(u8, row.english_name),
                .code = try self.allocator.dupe(u8, row.code),
                .status = row.status,
                .order = row.order,
                .is_default = row.is_default,
            });
        }
        self.mutex.lock();
        self.languages = try langs.toOwnedSlice(self.allocator);
        self.mutex.unlock();
    }

    /// 首次部署写入 zh-CN / en-US 两条语言记录（幂等：已有任意语言就跳过）。
    fn ensureSeedLanguages(self: *Store, db_path: []const u8) !void {
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000 });
        defer db.close();

        _ = try db.exec(self.allocator, "INSERT INTO Language (Name, EnglishName, UniqueSeoCode, Status, DisplayOrder, IsDefault) VALUES ('简体中文', 'Chinese (Simplified)', 'zh-CN', 1, 1, 1)");
        _ = try db.exec(self.allocator, "INSERT INTO Language (Name, EnglishName, UniqueSeoCode, Status, DisplayOrder, IsDefault) VALUES ('English', 'English', 'en-US', 1, 2, 0)");
        zzig.Logger.info("[ZDsMallUI] 已初始化多语言：简体中文（默认）+ English", .{});
    }

    /// 设为默认语言（写库后重载；同一时刻只有一个默认）。
    pub fn makeDefault(self: *Store, id: i32) !void {
        const db_path = self.db_path orelse return;
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000 });
        defer db.close();

        var stmt = try db.prepare(self.allocator, "UPDATE Language SET IsDefault = 0");
        defer stmt.finalize();
        try stmt.bindAll(&.{});
        try stmt.run();

        var stmt2 = try db.prepare(self.allocator, "UPDATE Language SET IsDefault = 1 WHERE Id = ?");
        defer stmt2.finalize();
        try stmt2.bindAll(&.{.{ .int = id }});
        try stmt2.run();

        try self.reload();
    }

    /// 启用 / 停用语言（停用后不出现在后台语言下拉）。
    pub fn setStatus(self: *Store, id: i32, enabled: bool) !void {
        const db_path = self.db_path orelse return;
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000 });
        defer db.close();

        var stmt = try db.prepare(self.allocator, "UPDATE Language SET Status = ? WHERE Id = ?");
        defer stmt.finalize();
        try stmt.bindAll(&.{ .{ .int = if (enabled) 1 else 0 }, .{ .int = id } });
        try stmt.run();

        try self.reload();
    }

    /// 新增语言（代码唯一；`order` 决定下拉顺序）。
    pub fn addLanguage(self: *Store, name: []const u8, english_name: []const u8, code: []const u8, order: i32) !void {
        const db_path = self.db_path orelse return;
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000 });
        defer db.close();

        var stmt = try db.prepare(self.allocator, "INSERT INTO Language (Name, EnglishName, UniqueSeoCode, Status, DisplayOrder, IsDefault) VALUES (?, ?, ?, 1, ?, 0)");
        defer stmt.finalize();
        try stmt.bindAll(&.{ .{ .text = name }, .{ .text = english_name }, .{ .text = code }, .{ .int = order } });
        try stmt.run();

        try self.reload();
    }

    /// 保存一条语言包（有则更新，无则插入）。
    pub fn saveResource(self: *Store, culture_id: i32, key: []const u8, text_value: []const u8) !void {
        const db_path = self.db_path orelse return;
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000 });
        defer db.close();

        const sql =
            \\INSERT INTO LocaleStringResource (CultureId, [Key], Value, UpdateTime)
            \\VALUES (?, ?, ?, datetime('now'))
            \\ON CONFLICT(CultureId, [Key]) DO UPDATE SET Value = excluded.Value, UpdateTime = excluded.UpdateTime
        ;
        var stmt = try db.prepare(self.allocator, sql);
        defer stmt.finalize();
        try stmt.bindAll(&.{ .{ .int = culture_id }, .{ .text = key }, .{ .text = text_value } });
        try stmt.run();

        try self.reload();
    }

    /// 语言列表（快照，读路径无锁）。
    pub fn all(self: *const Store) []const Language {
        return self.languages;
    }

    /// 默认语言（`IsDefault`；没有则第一条；再没有则 `null`）。
    pub fn defaultLanguage(self: *const Store) ?Language {
        for (self.languages) |row| {
            if (row.is_default and row.status) return row;
        }
        for (self.languages) |row| {
            if (row.status) return row;
        }
        return if (self.languages.len > 0) self.languages[0] else null;
    }

    /// 按代码（`zh-CN`）或 id 找语言。
    pub fn find(self: *const Store, key: []const u8) ?Language {
        if (key.len == 0) return null;
        if (std.fmt.parseInt(i32, key, 10)) |id| {
            for (self.languages) |row| {
                if (row.id == id) return row;
            }
        } else |_| {}
        for (self.languages) |row| {
            if (std.ascii.eqlIgnoreCase(row.code, key)) return row;
        }
        return null;
    }

    /// 取文案：DB 覆盖 > 内置（按语言代码选中文/英文）> 键名本身。
    pub fn text(self: *const Store, culture_id: i32, key: []const u8) []const u8 {
        var buf: [16]u8 = undefined;
        const culture_key = std.fmt.bufPrint(&buf, "{d}", .{culture_id}) catch "";
        if (self.resources.get(culture_key)) |inner| {
            if (inner.get(key)) |translated| {
                if (translated.len > 0) return translated;
            }
        }
        // 内置：按语言代码挑；未知语言回退中文
        const lang = self.byId(culture_id);
        const english = if (lang) |row| isEnglish(row.code) else false;
        for (BUILTIN_STRINGS) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return if (english) entry.en else entry.zh;
        }
        return key;
    }

    fn byId(self: *const Store, culture_id: i32) ?Language {
        for (self.languages) |row| {
            if (row.id == culture_id) return row;
        }
        return null;
    }

    /// 构建视图用的 `lang` 对象：`@Model.lang.<标识符>`。
    pub fn buildLangObject(self: *const Store, arena: std.mem.Allocator, culture_id: i32) !value.Value {
        var builder = value.ObjectBuilder.init(arena);
        for (BUILTIN_STRINGS) |entry| {
            const ident = try identifier(arena, entry.key);
            try builder.str(ident, self.text(culture_id, entry.key));
        }
        return builder.finish();
    }
};

fn isEnglish(code: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(code, "en");
}

fn rowText(row: sqlite.Row, name: []const u8) []const u8 {
    const v = row.get(name) orelse return "";
    return switch (v) {
        .text => |text| text,
        else => "",
    };
}

fn rowInt(row: sqlite.Row, name: []const u8) i32 {
    const v = row.get(name) orelse return 0;
    return switch (v) {
        .int => |number| @intCast(number),
        else => 0,
    };
}

// ————— 测试 —————

const testing = std.testing;

test "多语言：key 规范成 Razor 标识符" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("menu_settings", try identifier(arena, "menu.settings"));
    try testing.expectEqualStrings("page_languages_value", try identifier(arena, "page-languages.value"));
    try testing.expectEqualStrings("k_1a", try identifier(arena, "1a"));
}

test "多语言：内置文案按语言代码回退（无 DB）" {
    var store = Store.init(testing.allocator, testing.io);
    defer store.deinit();
    try store.reload();

    const zh = store.defaultLanguage().?;
    try testing.expectEqualStrings("zh-CN", zh.code);
    try testing.expectEqualStrings("设置", store.text(zh.id, "menu.settings"));

    const en = store.find("en-US").?;
    try testing.expectEqualStrings("Settings", store.text(en.id, "menu.settings"));
    // 未知键原样返回（不会崩）
    try testing.expectEqualStrings("no.such.key", store.text(zh.id, "no.such.key"));
}

test "多语言：lang 对象包含全部内置键" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = Store.init(testing.allocator, testing.io);
    defer store.deinit();
    try store.reload();

    const lang = try store.buildLangObject(arena, store.defaultLanguage().?.id);
    for (BUILTIN_STRINGS) |entry| {
        const ident = try identifier(arena, entry.key);
        try testing.expect(lang.get(ident) != null);
    }
}

//! 多语言（对齐 C# `Language` + `LocaleStringResource` 两张表）与后台文案。
//!
//! 三个约束（2026-11-22 用户明确要求）：
//! 1. **后台语言与前台语言互相隔离**：后台认「后台用户偏好」（C# `UserDetail.LanguageId`），
//!    前台认自己的 Cookie（`front_lang`），两边互不影响；
//! 2. **每个用户各自一份**：后台切换语言写在自己的用户记录里，不影响别人；
//! 3. **视图取文案只能是 `@Model.lang.<标识符>`**：Razor 子集不支持方法调用，也不支持字符串下标，
//!    所以 key 统一规范成标识符（`menu.settings` → `menu_settings`），内置清单见 [`BUILTIN_STRINGS`]。
//!
//! 语言包（DB）只覆盖文本，不改变视图能引用的键集合：视图引用 `BUILTIN_STRINGS` 里的键，
//! 缺失回退内置中文/英文，所以新增语言不会让页面报「属性不存在」。
//!
//! ★ **对外键 = 中文源文**（2026-11-23 用户明确要求：「我就是要类似于中文的这种啊」）：
//! - 后台语言包页的「翻译键」列、导出 CSV 的 `LanKey`、DB 里的 `LocaleStringResource.LanKey`
//!   一律是**中文原文**（如「控制台」「添加成功」），与 C# NCube/DsMall 的 `LanKey` 完全一致，可直接互导；
//! - 视图里仍写 `@Model.lang.<ascii 别名>`（Razor 子集不支持方法调用/字符串下标，Zig 标识符也不能用中文），
//!   所以 `Builtin.key` 保留为**视图别名**（`menu.console`），`Builtin.zh` 就是**对外键**。

const std = @import("std");
const zzig = @import("zzig");

const sqlite = zzig.db.sqlite;
const value = zzig.web.value;

/// 内置文案。
///
/// 字段含义（2026-11-23 起，与 C# 完全对齐）：
/// - `key`：**资源键 = 中文源文**（「控制台」「添加成功」），后台列表 / CSV / DB `LanKey` 都用它；
/// - `en`：英文文案（键不变，只变值）。
///
/// 视图里写 `@T("控制台")`（zzig 模板的 `@T(...)` 是内建翻译调用，与 C# `T(...)` 同款），
/// **不再**用 `@Model.lang.menu_console` 这种 ASCII 别名 —— 代码里也看不到 `menu.console` 了。
pub const Builtin = struct {
    key: []const u8,
    en: []const u8,

    /// 对外键（= `key` 本身；保留方法名是为了调用点语义清晰）。
    pub fn publicKey(entry: Builtin) []const u8 {
        return entry.key;
    }
};

pub const BUILTIN_STRINGS = [_]Builtin{
    .{ .key = "控制台", .en = "Console" },
    .{ .key = "设置", .en = "Settings" },
    .{ .key = "产品", .en = "Products" },
    .{ .key = "网站", .en = "Website" },
    .{ .key = "欢迎页", .en = "Dashboard" },
    .{ .key = "站点设置", .en = "Site settings" },
    .{ .key = "多语言", .en = "Cultures" },
    .{ .key = "语言包", .en = "Languages" },
    .{ .key = "单页文章", .en = "Articles" },
    .{ .key = "管理员管理", .en = "Administrators" },
    .{ .key = "角色权限管理", .en = "Roles" },
    .{ .key = "您好", .en = "Hello" },
    .{ .key = "访问首页", .en = "Visit site" },
    .{ .key = "清除缓存", .en = "Clear cache" },
    .{ .key = "修改密码", .en = "Change password" },
    .{ .key = "安全退出", .en = "Sign out" },
    .{ .key = "您确定退出吗?", .en = "Sign out now?" },
    .{ .key = "语言", .en = "Language" },
    .{ .key = "保存", .en = "Save" },
    .{ .key = "删除", .en = "Delete" },
    .{ .key = "编辑", .en = "Edit" },
    .{ .key = "新增", .en = "Add" },
    .{ .key = "搜索", .en = "Search" },
    .{ .key = "导出", .en = "Export" },
    .{ .key = "导入", .en = "Import" },
    .{ .key = "取消", .en = "Cancel" },
    .{ .key = "请求失败，请稍后重试", .en = "Request failed, please retry" },
    .{ .key = "返回", .en = "Back" },
    .{ .key = "操作", .en = "Actions" },
    .{ .key = "状态", .en = "Status" },
    .{ .key = "启用", .en = "Enabled" },
    .{ .key = "停用", .en = "Disabled" },
    .{ .key = "默认", .en = "Default" },
    .{ .key = "标准", .en = "Standard" },
    .{ .key = "管理", .en = "Manage" },
    .{ .key = "标题", .en = "Title" },
    .{ .key = "显示名称", .en = "Display name" },
    .{ .key = "关键字", .en = "Keyword" },
    .{ .key = "请选择", .en = "Please select" },
    .{ .key = "是", .en = "Yes" },
    .{ .key = "否", .en = "No" },
    .{ .key = "全选", .en = "Select all" },
    .{ .key = "您确定要删除吗?", .en = "Delete this item?" },
    .{ .key = "提交", .en = "Submit" },
    .{ .key = "旗帜", .en = "Flag" },
    .{ .key = "域名", .en = "Domain" },
    .{ .key = "是否默认", .en = "Is default" },
    .{ .key = "描述", .en = "Remark" },
    .{ .key = "请输入内容", .en = "Enter text" },
    .{ .key = "语言缩写", .en = "Language culture" },
    .{ .key = "名称", .en = "Name" },
    .{ .key = "排序", .en = "Order" },
    .{ .key = "保存成功", .en = "Saved" },
    .{ .key = "管理后台", .en = "Admin panel" },
    .{ .key = "当前用户", .en = "Current user" },
    .{ .key = "站点名称", .en = "Site name" },
    .{ .key = "当前区域", .en = "Area" },
    .{ .key = "路由前缀，可随配置改名", .en = "route prefix, configurable" },
    .{ .key = "上传目录", .en = "Upload folder" },
    .{ .key = "后台版本", .en = "Version" },
    .{ .key = "快捷入口", .en = "Shortcuts" },
    .{ .key = "登录", .en = "Sign in" },
    .{ .key = "用户名", .en = "Username" },
    .{ .key = "密码", .en = "Password" },
    .{ .key = "验证码", .en = "Captcha" },
    .{ .key = "看不清？点击刷新", .en = "Click to refresh" },
    .{ .key = "修改密码", .en = "Change password" },
    .{ .key = "原密码", .en = "Current password" },
    .{ .key = "新密码", .en = "New password" },
    .{ .key = "确认新密码", .en = "Confirm new password" },
    .{ .key = "多语言管理", .en = "Cultures" },
    .{ .key = "英文名称", .en = "English name" },
    .{ .key = "语言代码", .en = "Culture code" },
    .{ .key = "语言包管理", .en = "Language resources" },
    .{ .key = "资源键", .en = "Key" },
    .{ .key = "翻译文本", .en = "Value" },
    .{ .key = "语言", .en = "Language" },
    .{ .key = "请先选择语言再导出", .en = "Please select a language before exporting" },
    .{ .key = "网站名称", .en = "Site name" },
    .{ .key = "网站Seo标题", .en = "SEO title" },
    .{ .key = "网站Seo关键字", .en = "SEO keywords" },
    .{ .key = "网站Seo描述", .en = "SEO description" },
    .{ .key = "ICP备案号", .en = "ICP license" },
    .{ .key = "版权", .en = "Copyright" },
    .{ .key = "系统名称", .en = "System name" },
    .{ .key = "系统名称，将显示在后台顶部欢迎信息等位置", .en = "Shown in the admin header" },
    .{ .key = "网站域名", .en = "Site domain" },
    .{ .key = "网站的域名，必须 http:// 或 https:// 开头", .en = "Must start with http:// or https://" },
    .{ .key = "公司名称", .en = "Company" },
    .{ .key = "公司名称，将会显示在底部等位置", .en = "Shown in the footer" },
    .{ .key = "客服联系电话", .en = "Service phone" },
    .{ .key = "客服联系电话，将会显示在头部或者底部等位置", .en = "Shown in header or footer" },
    .{ .key = "前台页头", .en = "Header HTML" },
    .{ .key = "前台页脚", .en = "Footer HTML" },
    .{ .key = "流量统计配置", .en = "Analytics snippet" },
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
    /// 标题（C# `Name`）
    name: []const u8,
    /// 显示名称（C# `DisplayName`）
    display_name: []const u8,
    english_name: []const u8,
    /// 语言缩写（C# `LanguageCulture`，如 zh-CN）
    language_culture: []const u8,
    /// Url 缩写（C# `UniqueSeoCode`，如 zh）
    code: []const u8,
    status: bool,
    order: i32,
    is_default: bool,
    /// 旗帜（C# `Flag`）
    flag: []const u8 = "",
    /// 绑定域名（C# `Domain`）
    domain: []const u8 = "",
    /// Windows LCID（C# `Lcid`）
    lcid: i32 = 0,
    /// 描述（C# `Remark`）
    remark: []const u8 = "",
};

/// 语言包读取结果（`culture_id` → 键值）。线程安全：整体替换快照，读路径无锁。
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 数据库路径（`null` = 纯内存：只用内置文案，不支持管理页写库）
    db_path: ?[]const u8 = null,
    languages: []Language = &.{},
    /// 语言包是否已经尝试过「内置文案落库」（避免 reload 递归重复做）。
    resources_seeded: bool = false,
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
            self.allocator.free(row.display_name);
            self.allocator.free(row.english_name);
            self.allocator.free(row.language_culture);
            self.allocator.free(row.code);
            self.allocator.free(row.flag);
            self.allocator.free(row.domain);
            self.allocator.free(row.remark);
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
        var db = sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null }) catch |e| {
            zzig.Logger.warn("[ZDsMallUI] 多语言库打开失败（{s}，路径 {s}）", .{ @errorName(e), db_path });
            return e;
        };
        defer db.close();

        var langs: std.ArrayList(Language) = .empty;
        if (db.prepare(self.allocator, "SELECT Id, Name, DisplayName, EnglishName, LanguageCulture, UniqueSeoCode, Status, DisplayOrder, IsDefault, Flag, Domain, Lcid, Remark FROM Language ORDER BY DisplayOrder, Id")) |stmt_in| {
            var stmt = stmt_in;
            defer stmt.finalize();
            try stmt.bindAll(&.{});
            while (stmt.hasRow()) {
                const row = try stmt.readRow(arena);
                try langs.append(self.allocator, .{
                    .id = rowInt(row, "Id"),
                    .name = try self.allocator.dupe(u8, rowText(row, "Name")),
                    .display_name = try self.allocator.dupe(u8, rowText(row, "DisplayName")),
                    .english_name = try self.allocator.dupe(u8, rowText(row, "EnglishName")),
                    .language_culture = try self.allocator.dupe(u8, rowText(row, "LanguageCulture")),
                    .code = try self.allocator.dupe(u8, rowText(row, "UniqueSeoCode")),
                    .status = rowInt(row, "Status") != 0,
                    .order = rowInt(row, "DisplayOrder"),
                    .is_default = rowInt(row, "IsDefault") != 0,
                    .flag = try self.allocator.dupe(u8, rowText(row, "Flag")),
                    .domain = try self.allocator.dupe(u8, rowText(row, "Domain")),
                    .lcid = rowInt(row, "Lcid"),
                    .remark = try self.allocator.dupe(u8, rowText(row, "Remark")),
                });
            }
        } else |err| {
            zzig.Logger.warn("[ZDsMallUI] 读取多语言失败（{s}）：语言列表按内置处理", .{@errorName(err)});
        }

        var resources: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty;
        if (db.prepare(self.allocator, "SELECT CultureId, LanKey, LanValue FROM LocaleStringResource")) |stmt_in| {
            var stmt = stmt_in;
            defer stmt.finalize();
            try stmt.bindAll(&.{});
            while (stmt.hasRow()) {
                const row = try stmt.readRow(arena);
                const culture_key = try std.fmt.allocPrint(self.allocator, "{d}", .{rowInt(row, "CultureId")});
                const gop = try resources.getOrPut(self.allocator, culture_key);
                if (!gop.found_existing) gop.value_ptr.* = .empty else self.allocator.free(culture_key);
                const key_copy = try self.allocator.dupe(u8, rowText(row, "LanKey"));
                const value_copy = try self.allocator.dupe(u8, rowText(row, "LanValue"));
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

        // 语言包：表为空时把内置文案**落库一次**。
        //
        // 为什么需要（2026-11-23 用户反馈「语言包每一行为什么没有删除功能」）：
        // 未落库的键在列表里是**虚拟行**（`id = 0`），模板只在 `row.id > 0` 时渲染
        // 复选框与「删除」（与 C# `LocaleStringResource` 同口径）；表空 → 全部是虚拟行 → 用户看不到删除。
        // C# 那张表本来就有完整数据，这里把两边对齐。
        //
        // **只表空时跑一次**：之后删除就是删除，不会重启又回来（与 C# 一致）。
        if (!self.resources_seeded and self.resources.count() == 0) {
            self.resources_seeded = true;
            self.ensureSeedResources(db_path) catch |err| {
                zzig.Logger.warn("[ZDsMallUI] 语言包初始化失败（{s}）：列表仍会显示内置文案（只读）", .{@errorName(err)});
            };
            try self.reload();
        }
    }

    /// 把内置文案按「每个启用的语言」写进 `LocaleStringResource`（仅首次、表空时调用）。
    fn ensureSeedResources(self: *Store, db_path: []const u8) !void {
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null });
        defer db.close();

        const Target = struct { id: i32, english: bool };
        var targets: std.ArrayList(Target) = .empty;
        defer targets.deinit(self.allocator);

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        if (db.prepare(self.allocator, "SELECT Id, LanguageCulture, UniqueSeoCode FROM Language WHERE Status = 1 ORDER BY DisplayOrder")) |stmt_in| {
            var stmt = stmt_in;
            defer stmt.finalize();
            try stmt.bindAll(&.{});
            while (stmt.hasRow()) {
                const row = try stmt.readRow(arena);
                try targets.append(self.allocator, .{
                    .id = rowInt(row, "Id"),
                    .english = isEnglish(rowText(row, "LanguageCulture")) or isEnglish(rowText(row, "UniqueSeoCode")),
                });
            }
        } else |err| {
            zzig.Logger.warn("[ZDsMallUI] 语言包初始化：读语言表失败（{s}）", .{@errorName(err)});
            return err;
        }
        if (targets.items.len == 0) return;

        const sql =
            \\INSERT INTO LocaleStringResource (CultureId, [LanKey], LanValue, UpdateTime)
            \\VALUES (?, ?, ?, datetime('now'))
            \\ON CONFLICT(CultureId, [LanKey]) DO NOTHING
        ;
        var stmt = try db.prepare(self.allocator, sql);
        defer stmt.finalize();

        var rows_written: usize = 0;
        for (targets.items) |target| {
            for (BUILTIN_STRINGS) |entry| {
                stmt.reset();
                try stmt.bindAll(&.{
                    .{ .int = target.id },
                    .{ .text = entry.publicKey() },
                    .{ .text = if (target.english) entry.en else entry.key },
                });
                try stmt.run();
                rows_written += 1;
            }
        }
        zzig.Logger.info(
            "[ZDsMallUI] 语言包初始化：{d} 种语言 × {d} 条内置文案已落库（共写入 {d} 条，之后每行可编辑 / 删除）",
            .{ targets.items.len, BUILTIN_STRINGS.len, rows_written },
        );
    }

    fn setBuiltinLanguages(self: *Store) !void {
        const rows = [_]Language{
            .{ .id = 1, .name = "简体中文", .display_name = "简体中文", .english_name = "Chinese (Simplified)", .language_culture = "zh-CN", .code = "zh", .status = true, .order = 1, .is_default = true },
            .{ .id = 2, .name = "English", .display_name = "English", .english_name = "English", .language_culture = "en-US", .code = "en", .status = true, .order = 2, .is_default = false },
        };
        var langs: std.ArrayList(Language) = .empty;
        for (rows) |row| {
            try langs.append(self.allocator, .{
                .id = row.id,
                .name = try self.allocator.dupe(u8, row.name),
                .display_name = try self.allocator.dupe(u8, row.display_name),
                .english_name = try self.allocator.dupe(u8, row.english_name),
                .language_culture = try self.allocator.dupe(u8, row.language_culture),
                .code = try self.allocator.dupe(u8, row.code),
                .status = row.status,
                .order = row.order,
                .is_default = row.is_default,
                .flag = try self.allocator.dupe(u8, row.flag),
                .domain = try self.allocator.dupe(u8, row.domain),
                .lcid = row.lcid,
                .remark = try self.allocator.dupe(u8, row.remark),
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
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null });
        defer db.close();

        _ = try db.exec(self.allocator, "INSERT INTO Language (Name, DisplayName, EnglishName, LanguageCulture, UniqueSeoCode, Status, DisplayOrder, IsDefault, Flag, Domain, Lcid, Remark) VALUES ('简体中文', '简体中文', 'Chinese (Simplified)', 'zh-CN', 'zh', 1, 1, 1, '', '', 0, '')");
        _ = try db.exec(self.allocator, "INSERT INTO Language (Name, DisplayName, EnglishName, LanguageCulture, UniqueSeoCode, Status, DisplayOrder, IsDefault, Flag, Domain, Lcid, Remark) VALUES ('English', 'English', 'English', 'en-US', 'en', 1, 2, 0, '', '', 0, '')");
        zzig.Logger.info("[ZDsMallUI] 已初始化多语言：简体中文（默认）+ English", .{});
    }

    /// 设为默认语言（写库后重载；同一时刻只有一个默认）。
    pub fn makeDefault(self: *Store, id: i32) !void {
        const db_path = self.db_path orelse return;
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null });
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
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null });
        defer db.close();

        var stmt = try db.prepare(self.allocator, "UPDATE Language SET Status = ? WHERE Id = ?");
        defer stmt.finalize();
        try stmt.bindAll(&.{ .{ .int = if (enabled) 1 else 0 }, .{ .int = id } });
        try stmt.run();

        try self.reload();
    }

    /// 新增语言（代码唯一；`order` 决定下拉顺序）。
    pub fn addLanguage(
        self: *Store,
        name: []const u8,
        display_name: []const u8,
        english_name: []const u8,
        language_culture: []const u8,
        code: []const u8,
        order: i32,
    ) !void {
        const db_path = self.db_path orelse return;
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null });
        defer db.close();

        var stmt = try db.prepare(self.allocator, "INSERT INTO Language (Name, DisplayName, EnglishName, LanguageCulture, UniqueSeoCode, Status, DisplayOrder, IsDefault) VALUES (?, ?, ?, ?, ?, 1, ?, 0)");
        defer stmt.finalize();
        try stmt.bindAll(&.{
            .{ .text = name },
            .{ .text = if (display_name.len > 0) display_name else name },
            .{ .text = if (english_name.len > 0) english_name else name },
            .{ .text = if (language_culture.len > 0) language_culture else code },
            .{ .text = code },
            .{ .int = order },
        });
        try stmt.run();

        try self.reload();
    }

    /// 保存一条语言包（有则更新，无则插入）。
    pub fn saveResource(self: *Store, culture_id: i32, key: []const u8, text_value: []const u8) !void {
        const db_path = self.db_path orelse return;
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null });
        defer db.close();

        const sql =
            \\INSERT INTO LocaleStringResource (CultureId, [LanKey], LanValue, UpdateTime)
            \\VALUES (?, ?, ?, datetime('now'))
            \\ON CONFLICT(CultureId, [LanKey]) DO UPDATE SET LanValue = excluded.LanValue, UpdateTime = excluded.UpdateTime
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

    /// 语言包「资源行」（对齐 C# `LocaleStringResource` 的一行：Id / CultureId / LanKey / LanValue）。
    ///
    /// 行集合 = **库里的行** ∪ **内置键里还没落库的**（后者 `id = 0`，属于「虚拟行」）：
    /// 这样首次部署也能看到/编辑全部文案，保存一次就变成真行（有 Id，可删除/导出）。
    /// `id == 0` 的行**不可删除**（库里本来就没有），前端也不给它 checkbox。
    pub const ResourceRow = struct {
        id: i64,
        culture_id: i32,
        key: []const u8,
        value: []const u8,
        language_name: []const u8,
    };

    /// 查某语言下的资源行（可带 `lanKey` / `lanValue` 过滤，均大小写不敏感子串匹配）。
    ///
    /// 只读：文本全部拷贝进 `arena`，调用方用完即可丢弃。
    pub fn resourceRows(
        self: *Store,
        arena: std.mem.Allocator,
        culture_id: i32,
        key_filter: []const u8,
        value_filter: []const u8,
    ) ![]ResourceRow {
        var out: std.ArrayList(ResourceRow) = .empty;
        var seen = std.StringHashMapUnmanaged(void).empty;
        const language_name = if (self.byId(culture_id)) |row| row.display_name else "";

        if (self.db_path) |db_path| {
            if (sqlite.Lib.load(self.allocator)) |loaded| {
                var lib_val = loaded;
                defer lib_val.deinit();
                if (sqlite.Db.openWithOptions(&lib_val, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null })) |db_in| {
                    var db = db_in;
                    defer db.close();
                    if (db.prepare(self.allocator, "SELECT Id, LanKey, LanValue FROM LocaleStringResource WHERE CultureId = ? ORDER BY LanKey")) |stmt_in| {
                        var stmt = stmt_in;
                        defer stmt.finalize();
                        stmt.bindAll(&.{.{ .int = culture_id }}) catch {};
                        while (stmt.hasRow()) {
                            const row = stmt.readRow(arena) catch break;
                            const key_text = rowText(row, "LanKey");
                            const value_text = rowText(row, "LanValue");
                            seen.put(arena, try arena.dupe(u8, key_text), {}) catch {};
                            if (key_filter.len > 0 and std.mem.indexOf(u8, key_text, key_filter) == null) continue;
                            if (value_filter.len > 0 and std.mem.indexOf(u8, value_text, value_filter) == null) continue;
                            try out.append(arena, .{
                                .id = rowInt(row, "Id"),
                                .culture_id = culture_id,
                                .key = try arena.dupe(u8, key_text),
                                .value = try arena.dupe(u8, value_text),
                                .language_name = try arena.dupe(u8, language_name),
                            });
                        }
                    } else |_| {}
                } else |_| {}
            } else |_| {}
        }

        // 内置键里还没落库的 → 虚拟行（`id = 0`）：保证页面一开始就不是空的
        for (BUILTIN_STRINGS) |entry| {
            const public_key = entry.publicKey();
            if (seen.contains(public_key)) continue;
            if (key_filter.len > 0 and std.mem.indexOf(u8, public_key, key_filter) == null) continue;
            const builtin_value = self.text(culture_id, entry.key);
            if (value_filter.len > 0 and std.mem.indexOf(u8, builtin_value, value_filter) == null) continue;
            try out.append(arena, .{
                .id = 0,
                .culture_id = culture_id,
                .key = public_key,
                .value = try arena.dupe(u8, builtin_value),
                .language_name = try arena.dupe(u8, language_name),
            });
        }
        return out.toOwnedSlice(arena);
    }

    /// 按 `LocaleStringResource.Id` 删一条（对齐 C# `Delete?Ids=`）。返回是否真的删到了行。
    pub fn removeResourceById(self: *Store, id: i64) !bool {
        const db_path = self.db_path orelse return false;
        if (id <= 0) return false;
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null });
        defer db.close();

        var stmt = try db.prepare(self.allocator, "DELETE FROM LocaleStringResource WHERE Id = ?");
        defer stmt.finalize();
        try stmt.bindAll(&.{.{ .int = id }});
        try stmt.run();
        const changed = db.changes();
        try self.reload();
        return changed > 0;
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
        // 同时认 Url 缩写（`en`）与语言缩写（`en-US`），与 C# 两列并存保持一致
        for (self.languages) |row| {
            if (std.ascii.eqlIgnoreCase(row.code, key)) return row;
        }
        for (self.languages) |row| {
            if (std.ascii.eqlIgnoreCase(row.language_culture, key)) return row;
        }
        return null;
    }

    /// 取文案：DB 覆盖 > 内置（按语言代码选中文/英文）> 键名本身。
    ///
    /// `key` 就是**中文资源键**（如「控制台」）：DB 命中用译文，否则英文语言给 `en`、中文语言给键本身。
    /// 对齐 C# 「某语言没这个键就用键名」。
    pub fn text(self: *const Store, culture_id: i32, key: []const u8) []const u8 {
        var buf: [16]u8 = undefined;
        const culture_key = std.fmt.bufPrint(&buf, "{d}", .{culture_id}) catch "";

        if (self.resources.get(culture_key)) |inner| {
            if (inner.get(key)) |translated| {
                if (translated.len > 0) return translated;
            }
        }
        const lang = self.byId(culture_id);
        const english = if (lang) |row| isEnglish(row.code) else false;
        for (BUILTIN_STRINGS) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return if (english) entry.en else entry.key;
        }
        return key;
    }

    fn byId(self: *const Store, culture_id: i32) ?Language {
        for (self.languages) |row| {
            if (row.id == culture_id) return row;
        }
        return null;
    }

    /// 构建视图用的 `lang` 对象：`{ 中文键 → 译文 }`。
    ///
    /// 视图写 `@T("控制台")`，zzig 模板在渲染期按这个对象查（取不到就用键名本身）。
    pub fn buildLangObject(self: *const Store, arena: std.mem.Allocator, culture_id: i32) !value.Value {
        var builder = value.ObjectBuilder.init(arena);
        for (BUILTIN_STRINGS) |entry| {
            try builder.str(entry.publicKey(), self.text(culture_id, entry.key));
        }
        return builder.finish();
    }

    /// 更新语言（编辑页保存；只改传入的字段，`IsDefault` 由「设为默认」单独管）。
    pub fn updateLanguage(
        self: *Store,
        id: i32,
        name: []const u8,
        display_name: []const u8,
        english_name: []const u8,
        language_culture: []const u8,
        code: []const u8,
        status: bool,
        order: i32,
        remark: []const u8,
    ) !void {
        const db_path = self.db_path orelse return;
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null });
        defer db.close();

        const sql =
            \\UPDATE Language SET Name = ?, DisplayName = ?, EnglishName = ?, LanguageCulture = ?,
            \\UniqueSeoCode = ?, Status = ?, DisplayOrder = ?, Remark = ? WHERE Id = ?
        ;
        var stmt = try db.prepare(self.allocator, sql);
        defer stmt.finalize();
        try stmt.bindAll(&.{
            .{ .text = name },
            .{ .text = display_name },
            .{ .text = english_name },
            .{ .text = language_culture },
            .{ .text = code },
            .{ .int = if (status) 1 else 0 },
            .{ .int = order },
            .{ .text = remark },
            .{ .int = id },
        });
        try stmt.run();
        try self.reload();
    }

    /// 删除一条语言包（自定义键也能删）。
    pub fn removeResource(self: *Store, culture_id: i32, key: []const u8) !void {
        const db_path = self.db_path orelse return;
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null });
        defer db.close();

        var stmt = try db.prepare(self.allocator, "DELETE FROM LocaleStringResource WHERE CultureId = ? AND [LanKey] = ?");
        defer stmt.finalize();
        try stmt.bindAll(&.{ .{ .int = culture_id }, .{ .text = key } });
        try stmt.run();
        try self.reload();
    }

    /// 删除语言（**禁止删默认语言**；连同其语言包一起删）。
    pub fn removeLanguage(self: *Store, id: i32) !void {
        if (self.defaultLanguage()) |def| {
            if (def.id == id) return error.CannotRemoveDefaultLanguage;
        }
        const db_path = self.db_path orelse return;
        var lib = try sqlite.Lib.load(self.allocator);
        defer lib.deinit();
        var db = try sqlite.Db.openWithOptions(&lib, db_path, .{ .busy_timeout_ms = 5000, .journal_mode = null, .synchronous = null });
        defer db.close();

        var stmt = try db.prepare(self.allocator, "DELETE FROM LocaleStringResource WHERE CultureId = ?");
        defer stmt.finalize();
        try stmt.bindAll(&.{.{ .int = id }});
        try stmt.run();

        var stmt2 = try db.prepare(self.allocator, "DELETE FROM Language WHERE Id = ?");
        defer stmt2.finalize();
        try stmt2.bindAll(&.{.{ .int = id }});
        try stmt2.run();

        try self.reload();
    }

    /// 语言包键集合：内置键（中文对外键）∪ 数据库里出现过的自定义键（去重、稳定顺序）。
    pub fn resourceKeys(self: *const Store, allocator: std.mem.Allocator) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (BUILTIN_STRINGS) |entry| try list.append(allocator, entry.publicKey());
        var it = self.resources.iterator();
        while (it.next()) |entry| {
            var inner = entry.value_ptr.iterator();
            while (inner.next()) |kv| {
                var exists = false;
                for (list.items) |known| {
                    if (std.mem.eql(u8, known, kv.key_ptr.*)) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) try list.append(allocator, kv.key_ptr.*);
            }
        }
        return list.toOwnedSlice(allocator);
    }
};

fn isChinese(code: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(code, "zh");
}

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

test "多语言：key 规范成 Razor 标识符（遗留工具函数）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 视图已改用 `@T("中文键")`，这个函数只给「自定义 ASCII 键」用；保留行为测试
    try testing.expectEqualStrings("page_languages_value", try identifier(arena, "page-languages.value"));
    try testing.expectEqualStrings("k_1a", try identifier(arena, "1a"));
}

test "多语言：内置文案按语言代码回退（无 DB）" {
    var store = Store.init(testing.allocator, testing.io);
    defer store.deinit();
    try store.reload();

    const zh = store.defaultLanguage().?;
    // 两列并存（对齐 C#）：Url 缩写 `zh` + 语言缩写 `zh-CN`
    try testing.expectEqualStrings("zh", zh.code);
    try testing.expectEqualStrings("zh-CN", zh.language_culture);
    try testing.expectEqualStrings("设置", store.text(zh.id, "设置"));

    const en = store.find("en-US").?;
    try testing.expectEqualStrings("Settings", store.text(en.id, "设置"));
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
        // `@T("控制台")` 按中文键取值：lang 对象里必须有全部内置键
        try testing.expect(lang.get(entry.key) != null);
    }
}

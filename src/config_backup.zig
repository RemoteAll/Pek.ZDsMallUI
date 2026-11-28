//! 配置文件的数据库备份 / 还原（**一条规则，不会互相覆盖**）—— 后台框架通用件。
//!
//! 用户口径：「数据库里的数据是配置文件的备份 —— 服务器上的文件丢了，只要库还在就能用；
//! 关键是不能互相覆盖」。
//!
//! 规则只有两条：
//! 1. **文件缺失/为空 → 用库里的全文原样还原**（`Config.Name = '__configFile'`）；
//! 2. **文件存在 → 用库里的「两边都有」的键刷新文件**（后台保存只写库，不回刷就会被旧文件盖掉），
//!    然后刷新全文备份。文件里**库没有的键**原样保留、仍以文件为准。
//!
//! 刻意**不做**：版本号、时间戳比较、双向字段合并、请求中间件回写。
//! 这些都会引入「谁比谁新」的判定，运维一旦忘记维护元数据就会丢改动 —— 那才是真正的坑。
//! 现在任何时刻只有「文件在不在」一个判定，写路径也只有一条，多实例部署也是幂等的。
//!
//! 行级键读写（`getKey` / `setKey`）在 `zzig.config.text_keys`。
//!
//! ```zig
//! const backup = @import("pek_zdsmallui").config_backup;
//! backup.restoreBeforeConfigLoad(allocator, io, config_path, db_path, "[mysite]");
//! _ = try backup.ensureConfigFile(allocator, io, config_path, be, .{ .log_tag = "[mysite]" });
//! ```

const std = @import("std");
const zzig = @import("zzig");

const SqliteBackend = @import("sqlite_backend.zig").SqliteBackend;
const backend_mod = @import("backend.zig");

/// 日志前缀（多实例 / 多站点同机部署时才能分清是谁在还原）。
pub const Options = struct {
    log_tag: []const u8 = "[config]",
};

/// 全文备份在库里的键名（`Config.Name`）。
pub const DB_KEY_FILE_SNAPSHOT = "__configFile";

/// 配置文件大小上限（只防呆；真实配置就几 KB）。
const MAX_CONFIG_BYTES = 1024 * 1024;

pub const RestoreResult = enum {
    /// 文件已存在（可能需要刷新了同名键）
    file_present,
    /// 文件缺失/为空，已用库里的备份还原
    restored_from_db,
    /// 文件缺失且库里也没有备份，只能按默认值重建模板
    no_backup,
    /// 本文件声明了 `BackupToDatabase = false`（或没写）→ 不进库，也不做还原
    disabled,
};

/// 备份开关的键名：**在这个配置文件里**写 `BackupToDatabase = true` 才进库。
///
/// 默认 **false**（不写就不进库）：含敏感信息的配置（`logger.toml` / `Waf.toml` 等）
/// 不应该因为「程序顺手」就落进数据库。
pub const BACKUP_FLAG_KEY = "BackupToDatabase";

/// 读备份开关（`true` / `1` / `yes` / `on` 视为开启；缺省与其它值都是关闭）。
pub fn backupEnabled(file_text: []const u8) bool {
    const value = getKey(file_text, BACKUP_FLAG_KEY) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "true") or
        std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}

/// **在配置加载之前**跑的一次性还原。
///
/// 为什么需要单独一个函数：`HotConfig.init` 会用 `create_on_missing` 生成模板文件，
/// 一旦模板先生成，「文件缺失 → 从库还原」就再也没机会触发（会被当成「文件存在」）。
/// 所以启动早期先用这个函数直连库把备份写回文件，之后 `HotConfig` 读到的就是还原后的内容。
///
/// 数据库路径按 `{base_dir}/Data/{默认区域}.db` 推断；文件已在、或库不存在、或没有备份时
/// 什么都不做（后续模板逻辑接管），失败一律静默 —— 启动早期不该因为备份问题卡住。
pub fn restoreBeforeConfigLoad(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    db_path: []const u8,
    log_tag: []const u8,
) void {
    // 文件已在且有内容：无需还原
    if (zzig.fsio.readFileAlloc(io, allocator, config_path, MAX_CONFIG_BYTES)) |content| {
        const empty = std.mem.trim(u8, content, " \t\r\n").len == 0;
        allocator.free(content);
        if (!empty) return;
    } else |_| {}

    var lib = zzig.db.sqlite.Lib.load(allocator) catch return;
    defer lib.deinit();
    var db = zzig.db.sqlite.Db.openWithOptions(&lib, db_path, .{
        .busy_timeout_ms = 3000,
        .journal_mode = null,
        .synchronous = null,
        .read_only = true,
    }) catch return;
    defer db.close();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stmt = db.prepare(allocator, "SELECT Value FROM Config WHERE Name = ?") catch return;
    defer stmt.finalize();
    stmt.bindAll(&.{.{ .text = DB_KEY_FILE_SNAPSHOT }}) catch return;
    if (!stmt.hasRow()) return;
    const row = stmt.readRow(arena) catch return;
    const snapshot = switch (row.get("Value") orelse return) {
        .text => |value| value,
        else => return,
    };
    if (std.mem.trim(u8, snapshot, " \t\r\n").len == 0) return;

    zzig.fsio.writeFileAtomic(io, allocator, config_path, snapshot) catch |e| {
        zzig.Logger.warn("{s} 配置文件还原失败（{s}）：{s}", .{ log_tag, config_path, @errorName(e) });
        return;
    };
    zzig.Logger.warn(
        "{s} 配置文件 {s} 缺失，已用数据库备份还原（{d} 字节）",
        .{ log_tag, config_path, snapshot.len },
    );
}

/// 启动时调用：文件缺失就从库还原；文件在就用库里的同名键刷新它（并备份全文）。
pub fn ensureConfigFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    be: *SqliteBackend,
    opts: Options,
) !RestoreResult {
    const existing = zzig.fsio.readFileAlloc(io, allocator, config_path, MAX_CONFIG_BYTES) catch null;
    defer if (existing) |text| allocator.free(text);

    if (existing) |text| {
        if (std.mem.trim(u8, text, " \t\r\n").len > 0) {
            // **本文件自己说了算**：没写 `BackupToDatabase = true` 就不进库、不同步
            if (!backupEnabled(text)) {
                zzig.Logger.info(
                    "{s} 配置 {s} 未声明 {s} = true：不写数据库（如需容灾请在本文件里开启）",
                    .{ opts.log_tag, config_path, BACKUP_FLAG_KEY },
                );
                return .disabled;
            }
            const refreshed = try refreshSharedKeys(allocator, io, config_path, be, text);
            if (refreshed > 0) {
                zzig.Logger.info(
                    "{s} 配置：已用库里的值刷新文件中的 {d} 个同名键（后台改动不会被旧文件盖掉）",
                    .{ opts.log_tag, refreshed },
                );
            } else {
                try backupToDb(be, text);
            }
            return .file_present;
        }
    }

    // 文件缺失/为空：从库还原
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const snapshot = try be.setting(arena_state.allocator(), DB_KEY_FILE_SNAPSHOT);
    if (snapshot) |text| {
        try zzig.fsio.writeFileAtomic(io, allocator, config_path, text);
        zzig.Logger.warn(
            "{s} 配置文件 {s} 缺失/为空，已用数据库备份还原（{d} 字节）——请确认内容是否正确",
            .{ opts.log_tag, config_path, text.len },
        );
        return .restored_from_db;
    }

    zzig.Logger.warn(
        "{s} 配置文件 {s} 缺失，数据库里也没有备份：按默认值重新生成模板",
        .{ opts.log_tag, config_path },
    );
    return .no_backup;
}

/// 把文件全文写进库（`Config.__configFile`）。`HotConfig` 已负责「文件不存在时生成模板」。
pub fn backupToDb(be: *SqliteBackend, file_text: []const u8) !void {
    if (std.mem.trim(u8, file_text, " \t\r\n").len == 0) return;
    try be.putSetting(DB_KEY_FILE_SNAPSHOT, file_text);
}

/// 用库里的值刷新文件里「两边都有」的键；返回刷新了几个（0 = 无需改动）。
///
/// 「两边都有」由 `backend.DEFAULT_SETTINGS` 决定：文件里存在该键的行才处理，
/// 所以以后文件新增键会自动纳入，不需要维护映射表。
fn refreshSharedKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    be: *SqliteBackend,
    file_text: []const u8,
) !usize {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var updates: std.ArrayList([2][]const u8) = .empty;
    for (backend_mod.DEFAULT_SETTINGS) |entry| {
        // 判断「文件里有没有这个键」不能用 `getKey` 的返回值 —— 它对**空值**
        // （`CurDomainUrl = ""`）返回 null，会让新生成的空键永远刷不到库值。
        if (zzig.config.text_keys.findKeyLine(file_text, entry.store_key) == null) continue;
        const current = getKey(file_text, entry.store_key) orelse "";
        // 用 `settingRaw`：库里「键存在但值为空」也要能把文件里的旧值清空
        // （`setting` 会把空值当「没有」，后台就永远清不掉这一项）。
        const db_value = (try be.settingRaw(arena, entry.store_key)) orelse continue;
        if (std.mem.eql(u8, current, db_value)) continue;
        try updates.append(arena, .{ entry.store_key, db_value });
    }
    if (updates.items.len == 0) return 0;

    try writeKeys(allocator, io, config_path, be, updates.items);
    return updates.items.len;
}

/// 把若干键写进文件（保留注释与其它行），然后刷新全文备份。
pub fn writeKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    be: *SqliteBackend,
    updates: []const [2][]const u8,
) !void {
    const existing = zzig.fsio.readFileAlloc(io, allocator, config_path, MAX_CONFIG_BYTES) catch return;
    defer allocator.free(existing);
    if (std.mem.trim(u8, existing, " \t\r\n").len == 0) return;

    var current = try allocator.dupe(u8, existing);
    errdefer allocator.free(current);
    for (updates) |pair| {
        const next = try setKey(allocator, current, pair[0], pair[1]);
        allocator.free(current);
        current = next;
    }
    defer allocator.free(current);

    try zzig.fsio.writeFileAtomic(io, allocator, config_path, current);
    try backupToDb(be, current);
}

/// 行级键读写：统一走 `zzig.config.text_keys`（保留注释、行级定位、不误伤注释里的键名）。
///
/// 这三个函数原来在本文件手写，2026-11-22 下沉到 zzig（`config/text_keys.zig`），
/// 这里保留同名别名，业务侧调用点不需要改。
pub const getKey = zzig.config.text_keys.get;
pub const setKey = zzig.config.text_keys.set;

const testing = std.testing;

test "config_file：getKey / setKey 保留注释与其它键" {
    const text =
        \\# 说明
        \\SiteName = "old"
        \\AdminArea = "Admin"
    ;
    try testing.expectEqualStrings("old", getKey(text, "SiteName").?);
    try testing.expect(getKey(text, "ProbeIpv4Url") == null);

    const updated = try setKey(testing.allocator, text, "SiteName", "new");
    defer testing.allocator.free(updated);
    try testing.expect(std.mem.indexOf(u8, updated, "SiteName = \"new\"") != null);
    try testing.expect(std.mem.indexOf(u8, updated, "# 说明") != null);
    try testing.expect(std.mem.indexOf(u8, updated, "AdminArea = \"Admin\"") != null);
    try testing.expect(std.mem.indexOf(u8, updated, "old") == null);

    const appended = try setKey(testing.allocator, updated, "ProbeIpv4Url", "http://x");
    defer testing.allocator.free(appended);
    try testing.expect(std.mem.indexOf(u8, appended, "ProbeIpv4Url = \"http://x\"") != null);
}

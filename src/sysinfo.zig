//! 进程资源快照 —— 后台「服务状态」卡的数据来源。
//!
//! 为什么放在 UI 库：**每个后台都想知道「我这个进程现在吃多少」**，
//! 而不是每个业务项目各写一套 Windows/Linux 取数（复用优先）。
//!
//! 取数口径：
//! - Windows：`GetProcessTimes`（启动时间 / CPU 累计）+ `psapi.GetProcessMemoryInfo`（工作集）
//!   + `GetProcessHandleCount` + `GetProcessIoCounters` + Toolhelp 数线程；
//! - Linux：`/proc/self/stat`（utime/stime/线程数/starttime/rss）+ `/proc/self/io` + `/proc/self/fd`。
//!
//! `cpu_percent` 是**平均占用**（累计 CPU / 运行时长），不是瞬时值：
//! 瞬时值要后台周期采样，与「非必要不做周期性劳作」冲突；平均占用足以看出「是不是吃满一个核」。
//!
//! 取数**不要求实时**（用户 2026-11-23 原话：「这个就不需要实时获取资源占用吧」）：
//! `collect()` 自己带 30 秒缓存，代价最高的一项是 Windows 的系统级线程枚举
//! （`CreateToolhelp32Snapshot`，本机实测 ~80 ms；其它 API 都是微秒级）。
//! 「运行时长」不进缓存 —— 用缓存的启动时刻现算，任何时刻刷新都是准的。

const std = @import("std");
const builtin = @import("builtin");
const zzig = @import("zzig");

/// 一次进程快照（字段与后台卡片一一对应）。
pub const Snapshot = struct {
    /// 进程号
    pid: u32 = 0,
    /// 线程数
    threads: u32 = 0,
    /// 句柄数（Windows）／打开的文件描述符数（Linux）
    handles: u64 = 0,
    /// 物理内存工作集（字节）
    rss_bytes: u64 = 0,
    /// 平均 CPU 占用（0~100×核数；0 = 未知）
    cpu_percent: f64 = 0,
    /// 已运行秒数
    up_seconds: u64 = 0,
    /// 启动时刻（unix 秒）
    start_unix: i64 = 0,
    /// 累计读字节
    io_read_bytes: u64 = 0,
    /// 累计写字节
    io_write_bytes: u64 = 0,
    /// 取数是否成功（失败时其余字段为 0，视图显示「—」）
    ok: bool = false,
};

/// 快照缓存的有效期。仪表盘是给人看的概览，30 秒内的资源变化没有意义，
/// 但每次都枚举全机线程（~80 ms）纯属浪费。
const snapshot_ttl_ms: i64 = 30_000;

/// 最近一次快照（写入时先存内容、再用 release 存时间戳，读者用 acquire 检新鲜度）。
/// 偶发的并发刷新只是多采一次，结果仍然正确，不需要锁。
var cached_snapshot: Snapshot = .{};
var cached_at_ms = std.atomic.Value(i64).init(0);

/// 采集当前进程快照（带 30 秒缓存）。Windows 全是本地 API；Linux 读 3 个小文件。
pub fn collect(allocator: std.mem.Allocator, io: std.Io) Snapshot {
    const now_ms = clockMillis();
    const at = cached_at_ms.load(.acquire);
    if (at != 0 and now_ms - at >= 0 and now_ms - at < snapshot_ttl_ms) {
        return refreshUptime(cached_snapshot);
    }

    const fresh = collectFresh(allocator, io);
    cached_snapshot = fresh;
    cached_at_ms.store(now_ms, .release);
    return fresh;
}

/// 用缓存的启动时刻重算「已运行秒数」，其余字段原样返回。
fn refreshUptime(snap: Snapshot) Snapshot {
    var out = snap;
    if (out.ok and out.start_unix > 0) {
        const up = unixNow() - @as(u64, @intCast(out.start_unix));
        if (up < (1 << 40)) out.up_seconds = up;
    }
    return out;
}

fn clockMillis() i64 {
    return @intCast(@divTrunc(zzig.compat.nanoTimestamp(), 1_000_000));
}

fn collectFresh(allocator: std.mem.Allocator, io: std.Io) Snapshot {
    return switch (builtin.os.tag) {
        .windows => collectWindows(),
        .linux => collectLinux(allocator, io),
        else => .{},
    };
}

/// 字节数 → `12 MB` / `1.2 GB`（视图直接用）。
pub fn formatBytes(arena: std.mem.Allocator, bytes: u64) ![]const u8 {
    if (bytes >= 1024 * 1024 * 1024) {
        return std.fmt.allocPrint(arena, "{d:.1} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)});
    }
    if (bytes >= 1024 * 1024) {
        return std.fmt.allocPrint(arena, "{d:.0} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    }
    if (bytes >= 1024) {
        return std.fmt.allocPrint(arena, "{d:.0} KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    }
    return std.fmt.allocPrint(arena, "{d} B", .{bytes});
}

/// 秒数 → `11.00:15:12` 风格（小时:分:秒，超过一天带「N天」）。
pub fn formatUptime(arena: std.mem.Allocator, seconds: u64) ![]const u8 {
    const days = seconds / 86400;
    const hours = (seconds % 86400) / 3600;
    const minutes = (seconds % 3600) / 60;
    const secs = seconds % 60;
    if (days > 0) return std.fmt.allocPrint(arena, "{d}天 {d:0>2}:{d:0>2}:{d:0>2}", .{ days, hours, minutes, secs });
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, secs });
}

fn unixNow() u64 {
    return @intCast(@divTrunc(zzig.compat.nanoTimestamp(), std.time.ns_per_s));
}

// ───────────────────── 实例启动记录（安装时间 / 启动次数） ─────────────────────

/// 当前进程号（跨平台；取不到返回 0）。
pub fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .windows => win.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => 0,
    };
}

/// 实例运行记录：写在应用自己的状态文件里，供后台显示「安装时间 / 第 N 次启动」。
///
/// 为什么要落盘：进程一重启「运行时长」就归零，运维看不出「这服务部署多久了」；
/// 有了这份记录，**安装时间（首次运行）** 与 **累计启动次数** 就能跨重启保留。
pub const InstanceInfo = struct {
    /// 安装时间（首次运行），unix 秒；写一次后不再变
    installed_unix: i64 = 0,
    /// 本次启动时间，unix 秒
    started_unix: i64 = 0,
    /// 累计启动次数
    start_count: u32 = 0,
    /// 写入时的进程号：对不上说明是别的实例或上次崩溃留下的记录，不采信
    pid: u32 = 0,
};

/// 读实例记录（文件缺失 / 内容损坏一律当作「首次启动」，不报错）。
pub fn loadInstance(allocator: std.mem.Allocator, io: std.Io, path: []const u8) InstanceInfo {
    const text = zzig.fsio.readFileAlloc(io, allocator, path, 8192) catch return .{};
    defer allocator.free(text);

    var out = InstanceInfo{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "InstalledAt")) {
            out.installed_unix = std.fmt.parseInt(i64, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "StartedAt")) {
            out.started_unix = std.fmt.parseInt(i64, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "StartCount")) {
            out.start_count = std.fmt.parseInt(u32, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "Pid")) {
            out.pid = std.fmt.parseInt(u32, value, 10) catch 0;
        }
    }
    return out;
}

/// 记录本次启动：安装时间只在首次写，启动次数递增；写完返回更新后的记录。
///
/// 写失败只记一条警告（不能因为写不了文件就启动不了），返回内存里的记录。
pub fn recordStartup(allocator: std.mem.Allocator, io: std.Io, path: []const u8) InstanceInfo {
    const now: i64 = @intCast(unixNow());
    var info = loadInstance(allocator, io, path);
    if (info.installed_unix <= 0) info.installed_unix = now;
    info.started_unix = now;
    info.start_count = if (info.start_count == 0) 1 else info.start_count + 1;
    info.pid = currentPid();

    const text = std.fmt.allocPrint(
        allocator,
        "# 实例启动记录（程序启动时自动写入，请不要手工编辑）\n" ++
            "# InstalledAt：安装时间（首次运行，写一次不再变）；StartCount：累计启动次数\n" ++
            "[Instance]\n" ++
            "Pid = {d}\n" ++
            "InstalledAt = {d}\n" ++
            "StartedAt = {d}\n" ++
            "StartCount = {d}\n",
        .{ info.pid, info.installed_unix, info.started_unix, info.start_count },
    ) catch {
        zzig.Logger.warn("[ZDsMallUI] 实例记录拼接失败，本次不落盘：{s}", .{path});
        return info;
    };
    defer allocator.free(text);

    zzig.fsio.ensureParent(io, path) catch {};
    zzig.fsio.writeFileAtomic(io, allocator, path, text) catch |err| {
        zzig.Logger.warn("[ZDsMallUI] 实例记录写入失败（{s}）：{s}；安装时间与启动次数本次不持久化", .{ path, @errorName(err) });
    };
    return info;
}

// ───────────────────────── Windows ─────────────────────────

const win = std.os.windows;

const FILETIME = extern struct { low: u32, high: u32 };

fn fileTimeToU64(ft: FILETIME) u64 {
    return (@as(u64, ft.high) << 32) | ft.low;
}

/// FILETIME（1601-01-01 起的 100ns）→ unix 秒
fn fileTimeToUnixSeconds(ft: FILETIME) i64 {
    const secs_since_1601: i64 = @intCast(fileTimeToU64(ft) / 10_000_000);
    return secs_since_1601 - 11_644_473_600;
}

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: u32 = @sizeOf(PROCESS_MEMORY_COUNTERS),
    PageFaultCount: u32 = 0,
    PeakWorkingSetSize: usize = 0,
    WorkingSetSize: usize = 0,
    QuotaPeakPagedPoolUsage: usize = 0,
    QuotaPagedPoolUsage: usize = 0,
    QuotaPeakNonPagedPoolUsage: usize = 0,
    QuotaNonPagedPoolUsage: usize = 0,
    PagefileUsage: usize = 0,
    PeakPagefileUsage: usize = 0,
};

const TH32CS_SNAPTHREAD: u32 = 0x00000004;
const THREADENTRY32 = extern struct {
    dwSize: u32 = @sizeOf(THREADENTRY32),
    cntUsage: u32 = 0,
    th32ThreadID: u32 = 0,
    th32OwnerProcessID: u32 = 0,
    tpBasePri: i32 = 0,
    tpDeltaPri: i32 = 0,
    dwFlags: u32 = 0,
};

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) win.HANDLE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetProcessTimes(
    h: win.HANDLE,
    creation: *FILETIME,
    exit_time: *FILETIME,
    kernel: *FILETIME,
    user: *FILETIME,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn GetProcessHandleCount(h: win.HANDLE, count: *u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn GetProcessIoCounters(h: win.HANDLE, counters: *IO_COUNTERS) callconv(.winapi) win.BOOL;
extern "psapi" fn GetProcessMemoryInfo(
    h: win.HANDLE,
    counters: *PROCESS_MEMORY_COUNTERS,
    cb: u32,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) win.HANDLE;
extern "kernel32" fn Thread32First(h: win.HANDLE, entry: *THREADENTRY32) callconv(.winapi) win.BOOL;
extern "kernel32" fn Thread32Next(h: win.HANDLE, entry: *THREADENTRY32) callconv(.winapi) win.BOOL;
extern "kernel32" fn CloseHandle(h: win.HANDLE) callconv(.winapi) win.BOOL;

const SYSTEMTIME = extern struct {
    wYear: u16 = 0,
    wMonth: u16 = 0,
    wDayOfWeek: u16 = 0,
    wDay: u16 = 0,
    wHour: u16 = 0,
    wMinute: u16 = 0,
    wSecond: u16 = 0,
    wMilliseconds: u16 = 0,
};

extern "kernel32" fn FileTimeToSystemTime(ft: *const FILETIME, st: *SYSTEMTIME) callconv(.winapi) win.BOOL;
extern "kernel32" fn SystemTimeToTzSpecificLocalTime(
    tz: ?*const anyopaque,
    utc: *const SYSTEMTIME,
    local: *SYSTEMTIME,
) callconv(.winapi) win.BOOL;

/// unix 秒 → **本地**时间字符串 `2026-11-23 12:01:06`。
///
/// ★ 2026-11-23 修：后台仪表盘原来直接用 `std.time.epoch` 格式化，那是 **UTC**，
/// 注释却写「本地时区」—— 东八区机器上「启动时间」会早 8 小时
/// （实测显示 `04:00`，而当时是 `12:00`）。
///
/// Windows 走 `SystemTimeToTzSpecificLocalTime`（含夏令时，无需 libc）；
/// 其它平台没有免 libc 的时区库，退回 UTC 并**显式标注 `UTC`**，不假装成本地时间。
pub fn formatLocalTime(arena: std.mem.Allocator, unix_seconds: i64) ![]const u8 {
    if (unix_seconds <= 0) return arena.dupe(u8, "—");
    if (builtin.os.tag == .windows) {
        if (windowsLocalTime(unix_seconds)) |t| {
            return std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
                t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond,
            });
        }
    }
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_seconds) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const seconds_day = epoch.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        seconds_day.getHoursIntoDay(),
        seconds_day.getMinutesIntoHour(),
        seconds_day.getSecondsIntoMinute(),
    });
}

fn windowsLocalTime(unix_seconds: i64) ?SYSTEMTIME {
    // unix 秒 → FILETIME（从 1601-01-01 起的 100ns）
    const since_1601: i64 = unix_seconds + 11_644_473_600;
    if (since_1601 < 0) return null;
    const ticks: u64 = @as(u64, @intCast(since_1601)) * 10_000_000;
    var ft = FILETIME{ .low = @truncate(ticks), .high = @intCast(ticks >> 32) };
    var utc = SYSTEMTIME{};
    if (!FileTimeToSystemTime(&ft, &utc).toBool()) return null;
    var local = SYSTEMTIME{};
    if (!SystemTimeToTzSpecificLocalTime(null, &utc, &local).toBool()) return null;
    return local;
}

fn countThreadsWindows(pid: u32) u32 {
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == win.INVALID_HANDLE_VALUE) return 0;
    defer _ = CloseHandle(snap);

    var entry = THREADENTRY32{};
    var total: u32 = 0;
    if (Thread32First(snap, &entry).toBool()) {
        while (true) {
            if (entry.th32OwnerProcessID == pid) total += 1;
            if (!Thread32Next(snap, &entry).toBool()) break;
        }
    }
    return total;
}

fn collectWindows() Snapshot {
    var out = Snapshot{};
    const handle = GetCurrentProcess();
    out.pid = GetCurrentProcessId();

    var creation = FILETIME{ .low = 0, .high = 0 };
    var exit_time = FILETIME{ .low = 0, .high = 0 };
    var kernel = FILETIME{ .low = 0, .high = 0 };
    var user = FILETIME{ .low = 0, .high = 0 };
    if (GetProcessTimes(handle, &creation, &exit_time, &kernel, &user).toBool()) {
        out.start_unix = fileTimeToUnixSeconds(creation);
        const cpu_seconds = @as(f64, @floatFromInt(fileTimeToU64(kernel) + fileTimeToU64(user))) / 10_000_000.0;
        const up = @as(f64, @floatFromInt(unixNow())) - @as(f64, @floatFromInt(out.start_unix));
        if (up > 0) {
            out.up_seconds = @intFromFloat(up);
            if (up > 0.5) out.cpu_percent = cpu_seconds / up * 100.0;
        }
        out.ok = true;
    }

    var mem = PROCESS_MEMORY_COUNTERS{};
    if (GetProcessMemoryInfo(handle, &mem, @sizeOf(PROCESS_MEMORY_COUNTERS)).toBool()) {
        out.rss_bytes = mem.WorkingSetSize;
        out.ok = true;
    }

    var handles: u32 = 0;
    if (GetProcessHandleCount(handle, &handles).toBool()) out.handles = handles;

    var io_counters = std.mem.zeroes(IO_COUNTERS);
    if (GetProcessIoCounters(handle, &io_counters).toBool()) {
        out.io_read_bytes = io_counters.ReadTransferCount;
        out.io_write_bytes = io_counters.WriteTransferCount;
    }

    out.threads = countThreadsWindows(out.pid);
    return out;
}

// ───────────────────────── Linux ─────────────────────────

fn collectLinux(allocator: std.mem.Allocator, io: std.Io) Snapshot {
    var out = Snapshot{};
    const page_size: u64 = 4096;

    // `/proc/self/stat`：`pid (name) state ppid ...`
    // 从 `)` 之后切；相对 stat 的列号：3 state、14 utime、15 stime、20 num_threads、22 starttime、24 rss
    // → 相对 rest：state 是 rest[0]，utime rest[11]、stime rest[12]、num_threads rest[17]、
    //   starttime rest[19]、rss rest[21]
    if (zzig.fsio.readFileAlloc(io, allocator, "/proc/self/stat", 4096) catch null) |stat| {
        defer allocator.free(stat);
        if (std.mem.lastIndexOfScalar(u8, stat, ')')) |close_paren| {
            const rest = stat[@min(close_paren + 2, stat.len)..];
            var fields: [24][]const u8 = undefined;
            var count: usize = 0;
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            while (it.next()) |tok| {
                if (count >= fields.len) break;
                fields[count] = tok;
                count += 1;
            }
            if (count > 21) {
                out.pid = std.fmt.parseInt(u32, fields[0], 10) catch 0;
                const utime = std.fmt.parseInt(u64, fields[11], 10) catch 0;
                const stime = std.fmt.parseInt(u64, fields[12], 10) catch 0;
                out.threads = std.fmt.parseInt(u32, fields[17], 10) catch 0;
                out.rss_bytes = (std.fmt.parseInt(u64, fields[21], 10) catch 0) * page_size;
                const start_secs = (std.fmt.parseFloat(f64, fields[19]) catch 0) / 100.0; // USER_HZ = 100
                if (uptimeSeconds(allocator, io)) |up_total| {
                    if (up_total > start_secs) {
                        out.up_seconds = @intFromFloat(up_total - start_secs);
                        out.start_unix = @as(i64, @intCast(unixNow())) - @as(i64, @intCast(out.up_seconds));
                        if (out.up_seconds > 0) {
                            const cpu_seconds = @as(f64, @floatFromInt(utime + stime)) / 100.0;
                            out.cpu_percent = cpu_seconds / @as(f64, @floatFromInt(out.up_seconds)) * 100.0;
                        }
                    }
                }
                out.ok = true;
            }
        }
    }

    if (zzig.fsio.readFileAlloc(io, allocator, "/proc/self/io", 4096) catch null) |text| {
        defer allocator.free(text);
        var it = std.mem.tokenizeScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "read_bytes:")) out.io_read_bytes = parseAfterColon(line);
            if (std.mem.startsWith(u8, line, "write_bytes:")) out.io_write_bytes = parseAfterColon(line);
        }
    }

    out.handles = countDirEntries(io, "/proc/self/fd");
    return out;
}

fn parseAfterColon(line: []const u8) u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
    return std.fmt.parseInt(u64, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch 0;
}

fn uptimeSeconds(allocator: std.mem.Allocator, io: std.Io) ?f64 {
    const text = zzig.fsio.readFileAlloc(io, allocator, "/proc/uptime", 128) catch return null;
    defer allocator.free(text);
    const first = std.mem.tokenizeScalar(u8, text, ' ').next() orelse return null;
    return std.fmt.parseFloat(f64, first) catch null;
}

fn countDirEntries(io: std.Io, path: []const u8) u64 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var n: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |_| n += 1;
    return n;
}

test "sysinfo：采集到的字段自洽（pid 非 0、内存非 0）" {
    const snap = collect(std.testing.allocator, std.testing.io);
    if (!snap.ok) return; // 无权限的环境跳过
    try std.testing.expect(snap.pid != 0);
    try std.testing.expect(snap.rss_bytes > 0);
}

test "sysinfo：本地时间格式化（0 表示未知，正常值形如 yyyy-MM-dd HH:mm:ss）" {
    const unknown = try formatLocalTime(std.testing.allocator, 0);
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqualStrings("—", unknown);

    // 2020-09-13T12:26:40Z：任何时区下都还是 2020-09-13（±14h 内也不会跨出 13/14 两天）
    const text = try formatLocalTime(std.testing.allocator, 1_600_000_000);
    defer std.testing.allocator.free(text);
    try std.testing.expect(text.len >= 19);
    try std.testing.expect(std.mem.startsWith(u8, text, "2020-09-1"));
    try std.testing.expectEqual(@as(u8, ':'), text[13]);
}

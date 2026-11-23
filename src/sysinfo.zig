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

/// 采集当前进程快照。Windows 全是本地 API；Linux 读 3 个小文件。
pub fn collect(allocator: std.mem.Allocator, io: std.Io) Snapshot {
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

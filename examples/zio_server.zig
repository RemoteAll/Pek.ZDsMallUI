//! 异步高并发验证：用 **zio 运行时**（Windows IOCP / Linux io_uring）跑 zzig 的 HTTP 服务端。
//!
//! 目的：验证「不每连接一线程」。zio 完整实现了 `std.Io`，所以 zzig 的 HTTP 代码**一行都不用改**，
//! 只要：① 用 `rt.io()` 作为 io；② `dispatch = .task`（连接跑成协程而不是 OS 线程）。
//!
//! 用法：
//!   zig build zio-server -- <port>        # 起服务（外部工具压测连接数）
//!
//! 观测点：`Get-Process` 的线程数 —— 协程模型下应恒定在「executor 数 + 少量」，不随连接数增长。

const std = @import("std");
const zio = @import("zio");
const zzig = @import("zzig");

/// 让 `std.debug.print` 不阻塞事件循环（zio README 推荐）。
pub const std_options_debug_io = zio.debug_io;

fn handle(ctx: *anyopaque, req: zzig.http_server.RequestView, arena: std.mem.Allocator) anyerror!zzig.http_server.Reply {
    _ = ctx;
    _ = req;
    _ = arena;
    return .{ .status = .ok, .body = "ok" };
}

/// `Server.run` 的返回类型带 `error.SystemResources` 等错误集，而 `std.Io.Group.async`
/// 要求返回可强转成 `Cancelable!void` —— 这里包一层把错误就地消化。
fn runServer(srv: *zzig.http_server.Server, host: []const u8, port: u16) std.Io.Cancelable!void {
    srv.run(host, port) catch |e| {
        std.debug.print("[zio] server 退出：{s}\n", .{@errorName(e)});
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    while (it.next()) |a| try args.append(gpa, a);
    const port: u16 = if (args.items.len > 1) std.fmt.parseInt(u16, args.items[1], 10) catch 18091 else 18091;
    // 第 2 个参数：executor（工作线程）数。0 / 缺省 = `.auto`（按 CPU 核数，且尊重 cgroup 配额）。
    // 用小数值可以在大机器上**模拟 2 核 / 4 核服务器**，验证小规格下的连接承载。
    const executors: u8 = if (args.items.len > 2) std.fmt.parseInt(u8, args.items[2], 10) catch 0 else 0;

    // 协程栈：2026-11-19 起 zzig 的 HTTP 层换成自写的零分配解析（收编 lighting / MIT，
    // 不再走 `std.http`），连接协程的栈需求从 >64 KiB 掉到 32 KiB 以内 —— 之前那个
    // 「64 KiB 就 Stack overflow」的硬下限随之一并消失。实测（5000 空闲连接 / 2 executor / 4 KiB 收发缓冲）：
    //   std.http + 128 KiB 栈 → 302.7 MB（59.3 KB/连接）
    //   自写解析 + 32 KiB 栈 → 20.5 KB/连接（见 zzig/docs/决策记录.md 2026-11-19（十一））
    const rt = try zio.Runtime.init(gpa, .{
        // `ExecutorCount` 是非穷尽枚举（`auto = 0, _`），用 `@fromBackingInt` 构造具体值
        .executors = if (executors > 0) @fromBackingInt(executors) else .auto,
        .stack_pool = .{
            .maximum_size = 32 * 1024,
            .committed_size = 16 * 1024,
        },
    });
    defer rt.deinit();
    const io = rt.io();

    var srv = zzig.http_server.Server{
        .gpa = gpa,
        .io = io,
        .ctx = undefined,
        .handler = handle,
        .opts = .{
            // 关键：连接作为运行时任务（协程）跑，而不是每连接一个 OS 线程
            .dispatch = .task,
            // 协程便宜，把连接上限抬到很高，验证「连接数 ≈ 协程数 ≠ 线程数」
            .max_connections = 200_000,
            .keep_alive = true,
            .keep_alive_requests = 1000,
            // 上万连接场景：每连接缓冲是主要固定开销（实测 16K+16K 与 4K+4K 差 20+ KB/连接）
            .conn_recv_buf_size = 4 * 1024,
            .conn_send_buf_size = 4 * 1024,
        },
    };
    srv.ctx = @ptrCast(&srv);

    std.debug.print("ZIO_HTTP_SERVER port={d} dispatch=task executors={s}\n", .{ port, if (executors > 0) "exact" else "auto" });

    // 服务端必须跑在**运行时里**：zio 的 accept/读写在运行时上下文才会挂起协程，
    // 丢到裸 std.Thread 上会卡死（zgrpc 的 with-zio 示例同样如此）。
    var group: std.Io.Group = .init;
    group.async(io, runServer, .{ &srv, @as([]const u8, "127.0.0.1"), port });
    group.await(io) catch {};
}

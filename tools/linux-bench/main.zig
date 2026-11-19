//! Linux 压测用的最小 HTTP 服务：zzig 的接入层 + zio 协程运行时。
//!
//! 用法：`zbench <port> [executors] [stackKiB]`
//! 与 Windows 上的 `Pek.ZDsMallUI/examples/zio_server.zig` 同一口径，便于跨平台对比。

const std = @import("std");
const zio = @import("zio");
const zzig = @import("zzig");

pub const std_options_debug_io = zio.debug_io;

fn handle(ctx: *anyopaque, req: zzig.http_server.RequestView, arena: std.mem.Allocator) anyerror!zzig.http_server.Reply {
    _ = ctx;
    _ = req;
    _ = arena;
    return .{ .status = .ok, .body = "ok" };
}

fn runServer(srv: *zzig.http_server.Server, host: []const u8, port: u16) std.Io.Cancelable!void {
    srv.run(host, port) catch |e| {
        std.debug.print("[zbench] server 退出：{s}\n", .{@errorName(e)});
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    while (it.next()) |a| try args.append(gpa, a);

    const port: u16 = if (args.items.len > 1) std.fmt.parseInt(u16, args.items[1], 10) catch 18400 else 18400;
    const executors: u8 = if (args.items.len > 2) std.fmt.parseInt(u8, args.items[2], 10) catch 0 else 0;
    const stack_kib: usize = if (args.items.len > 3) std.fmt.parseInt(usize, args.items[3], 10) catch 32 else 32;

    const rt = try zio.Runtime.init(gpa, .{
        .executors = if (executors > 0) @fromBackingInt(executors) else .auto,
        .stack_pool = .{
            .maximum_size = stack_kib * 1024,
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
            .dispatch = .task,
            .max_connections = 200_000,
            .keep_alive = true,
            .keep_alive_requests = 1000,
            .conn_recv_buf_size = 4 * 1024,
            .conn_send_buf_size = 4 * 1024,
        },
    };
    srv.ctx = @ptrCast(&srv);

    std.debug.print("ZBENCH port={d} stack={d}KiB executors={s}\n", .{
        port,
        stack_kib,
        if (executors > 0) "exact" else "auto",
    });

    var group: std.Io.Group = .init;
    group.async(io, runServer, .{ &srv, @as([]const u8, "0.0.0.0"), port });
    group.await(io) catch {};
}

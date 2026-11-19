//! **对照实验**：lighting 框架（自写 HTTP/1.1 解析，**不依赖 `std.http.Server`**）跑在 zio 协程上，
//! 与 `examples/zio_server.zig`（zzig + `std.http`）对比每连接内存。
//!
//! 目的：验证「stack 开销到底来自 std.http，还是来自有栈协程本身」。
//! 若 lighting 在 16~32 KiB 栈下就能跑满上万连接，说明瓶颈确实是 `std.http` 的解析路径。
//!
//! 用法：
//!   zig build lighting-zio -- <port> [executors] [栈上限 KiB]
//!   zig build lighting-zio -Doptimize=ReleaseFast -- 18201 2 32

const std = @import("std");
const lighting = @import("lighting");
const zio = @import("zio");

/// 让 `std.debug.print` 不阻塞事件循环（zio README 推荐）。
pub const std_options_debug_io = zio.debug_io;

fn okHandler(w: *lighting.ResponseWriter, _: *lighting.Request) anyerror!void {
    try w.header().set("Content-Type", "text/plain; charset=utf-8");
    try w.writeAll("ok");
}

/// `listenAndServe` 的错误集比 `Cancelable` 宽，就地消化。
fn runServer(srv: *lighting.Server, host: []const u8, port: u16) std.Io.Cancelable!void {
    srv.listenAndServe(host, port) catch |e| {
        std.debug.print("[lighting] server 退出：{s}\n", .{@errorName(e)});
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    while (it.next()) |a| try args.append(gpa, a);

    const port: u16 = if (args.items.len > 1) std.fmt.parseInt(u16, args.items[1], 10) catch 18201 else 18201;
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

    var mux = lighting.ServeMux.init(gpa);
    defer mux.deinit();
    try mux.handleFunc("GET /{$}", okHandler);

    var server = lighting.Server.init(gpa, io, .{ .handler = mux.handler() });

    std.debug.print(
        "LIGHTING_ZIO port={d} stack={d}KiB executors={s} read_buf=8KiB\n",
        .{ port, stack_kib, if (executors > 0) "exact" else "auto" },
    );

    var group: std.Io.Group = .init;
    group.async(io, runServer, .{ &server, @as([]const u8, "127.0.0.1"), port });
    group.await(io) catch {};
}

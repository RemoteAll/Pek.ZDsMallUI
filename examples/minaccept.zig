//! 对照实验 2：加 `std.http.Server.receiveHead` + 头迭代，但**不 respond**。
//! 用来判断 105 KB/连接 的 HTTP 层开销是在「解析」还是在「响应/arena」阶段。
//!
//! 用法：`zig build minaccept -- <port> <executors> [http]`

const std = @import("std");
const zio = @import("zio");

pub const std_options_debug_io = zio.debug_io;

var with_http: bool = false;
var alloc: std.mem.Allocator = undefined;

fn worker(io: std.Io, s: std.Io.net.Stream) std.Io.Cancelable!void {
    defer s.close(io);
    const recv_buf = alloc.alloc(u8, 16 * 1024) catch return;
    defer alloc.free(recv_buf);
    const send_buf = alloc.alloc(u8, 16 * 1024) catch return;
    defer alloc.free(send_buf);
    var sr = s.reader(io, recv_buf);
    var sw = s.writer(io, send_buf);

    if (!with_http) {
        _ = sr.interface.readSliceShort(recv_buf) catch {};
        return;
    }

    var http = std.http.Server.init(&sr.interface, &sw.interface);
    var req = http.receiveHead() catch return;
    var it = req.iterateHeaders();
    while (it.next()) |_| {}
    // 解析完挂着不响应：连接保持，测「只有解析」的内存
    std.Io.sleep(io, .{ .nanoseconds = 120 * std.time.ns_per_s }, .awake) catch {};
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    alloc = gpa;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    while (it.next()) |a| try args.append(gpa, a);
    const port: u16 = if (args.items.len > 1) std.fmt.parseInt(u16, args.items[1], 10) catch 18095 else 18095;
    const executors: u8 = if (args.items.len > 2) std.fmt.parseInt(u8, args.items[2], 10) catch 0 else 0;
    with_http = args.items.len > 3;

    const rt = try zio.Runtime.init(gpa, .{
        .executors = if (executors > 0) @fromBackingInt(executors) else .auto,
        .stack_pool = .{ .maximum_size = 1024 * 1024, .committed_size = 16 * 1024 },
    });
    defer rt.deinit();
    const io = rt.io();

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    std.debug.print("MINACCEPT_READY port={d} http={}\n", .{ port, with_http });

    var group: std.Io.Group = .init;
    while (true) {
        const s = listener.accept(io) catch continue;
        group.concurrent(io, worker, .{ io, s }) catch {
            s.close(io);
        };
    }
}

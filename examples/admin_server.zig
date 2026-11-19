//! 可运行示例：起服务 + 全部入口（对齐 Rust 版 `examples/admin_server.rs`）。
//!
//! ```powershell
//! zig build run                                  # 默认 127.0.0.1:18080，区域 Biz
//! zig build run -- 18081                         # 指定端口
//! zig build run -- 18081 Admin                   # 指定端口 + 区域名
//! ```
//!
//! 入口（`{area}` 由参数决定，默认 `biz`）：
//!
//! | 路径 | 说明 |
//! |---|---|
//! | `GET /{area}/home/index` | 后台首页（控制台 + 快捷入口） |
//! | `GET /{area}/config/index` | 站点设置页（Razor 子集渲染，套 `Views/Shared/_Layout.cshtml`） |
//! | `POST /{area}/config/updatebase` | 保存设置（字段名与 C# `ConfigController.UpdateBase` 一致） |
//! | `GET /{area}/login/index` | 登录页 |
//! | `POST /{area}/login/login` | 登录（示例账号 `admin` / `admin123`；成功下发 JWT Cookie，Ajax 额外返回 `token`） |
//! | `POST|GET /{area}/login/logout` | 退出登录（吊销 JWT + 清 Cookie） |
//! | `GET /{area}/login/status` | 当前登录状态（JSON） |
//! | `GET /fileuploader?action=config` | UEditor 配置（原样回吐 `ueconfig.json`） |
//! | `POST /fileuploader?action=uploadimage` | 图片上传（multipart，字段 `upfile`） |
//! | `POST /fileuploader?action=uploadscrawl` | 涂鸦（base64 data URL） |
//! | `POST /fileuploader?action=uploadfile` | 附件上传 |
//! | `GET /fileuploader?action=listimage` | 图片管理器分页列表 |
//! | `GET /Upload/downloads/{path}` | 下载上传目录内文件（带 `Content-Disposition`、ETag/304） |

const std = @import("std");
const zzig = @import("zzig");
const pek_zdsmallui = @import("pek_zdsmallui");

/// 示例数据目录（不污染仓库根目录）。
const base_dir = ".zig-cache/zdsmallui-example";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer iterator.deinit();
    while (iterator.next()) |arg| try args.append(gpa, arg);

    const port: u16 = if (args.items.len > 1) std.fmt.parseInt(u16, args.items[1], 10) catch 18080 else 18080;
    const area = if (args.items.len > 2) args.items[2] else "Biz";

    const web_root = base_dir ++ "/wwwroot";
    const views_root = base_dir ++ "/Views";
    const areas_root = base_dir ++ "/Areas";

    const ui = try pek_zdsmallui.DsMallUi.builder(gpa, io)
        .webRoot(web_root)
        .viewsRoot(views_root)
        .areasRoot(areas_root)
        .adminArea(area)
        // 示例密钥：生产必须从配置/环境变量取；不配则每次启动随机（旧令牌失效）
        .jwtSecret("HS256:zdsmallui-example-secret")
        .jwtExpireMinutes(120)
        .build();
    defer ui.deinit();

    const written = try ui.materializeDefaults();
    std.debug.print("[dsmallui] 默认视图/配置已落地：{d} 个文件（已存在则跳过）\n", .{written});

    var app = try zzig.web.App.init(gpa, io, .{
        .wwwroot = web_root,
        // 静态资源缓存 10 分钟：仍有 ETag 兑底（改样式后刷新即生效），但少了每次的 304 往返
        .static_cache_control = "public, max-age=600",
    });
    defer app.deinit();
    try ui.mount(&app);

    const prefix = try ui.admin().routePrefix(gpa);
    defer gpa.free(prefix);
    const site = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
    defer gpa.free(site);

    std.debug.print("[dsmallui] 区域：{s}（路由前缀 {s}）\n", .{ ui.adminArea(), prefix });
    std.debug.print("[dsmallui] 首页      {s}{s}/home/index\n", .{ site, prefix });
    std.debug.print("[dsmallui] 站点设置  {s}{s}/config/index\n", .{ site, prefix });
    std.debug.print("[dsmallui] 登录      {s}{s}/login/index （admin / admin123）\n", .{ site, prefix });
    std.debug.print("[dsmallui] 登录状态  {s}{s}/login/status\n", .{ site, prefix });
    std.debug.print("[dsmallui] 退出登录  {s}{s}/login/logout\n", .{ site, prefix });
    std.debug.print("[dsmallui] UEditor   {s}/fileuploader?action=config\n", .{site});

    try app.run("127.0.0.1", port, .{
        .max_body = ui.maxUploadBytes(),
        .max_connections = 128,
        // 只有前面挂了反向代理（nginx 等）时才设 `true`：
        // 只当 TCP 对端是回环时采购 `x-real-ip` / `x-forwarded-for` 末段，否则 IP 恒为 127.0.0.1
        .trust_forwarded_for = false,
    });
    return 0;
}

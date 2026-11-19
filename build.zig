const std = @import("std");

/// Pek.ZDsMallUI —— 「猿人易 / NCube / DsMallUI」后台 UI 能力的 **Zig 统一封装**
/// （对齐 C# `G:\Code\Pek.FrameWork\Pek.DsMallUI` 与 Rust `G:\Code\Rust\Pek.DsMallUI`）：
/// UEditor 富文本后端、上传下载、后台 Area（首页 / 站点设置 / 登录，区域名可配置）、
/// Razor 子集默认视图与静态资源，全部复用 zzig 的 Web 栈（`zzig.web`）。
///
/// 目录与 C# 工程同构：`Areas/Admin/Controllers`、`Areas/Admin/Views`、`Controllers`、`Views`；
/// Zig 侧基础设施在 `src/`。模块根文件放在仓库根（`pek_zdsmallui.zig`），
/// 这样 `@import`/`@embedFile` 可同时覆盖 `src/`、`Areas/`、`Views/`、`assets/`。
///
/// 构建口径与 zzig 各消费方一致：库只暴露模块 `pek_zdsmallui`，
/// 测试用 `zig build test`，示例用 `zig build run -- 18081 Biz`。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzig_dep = b.dependency("zzig", .{
        .target = target,
        .optimize = optimize,
    });
    const perms_dep = b.dependency("pek_zpermissions", .{
        .target = target,
        .optimize = optimize,
    });
    const zwaf_dep = b.dependency("pek_zwaf", .{
        .target = target,
        .optimize = optimize,
    });
    const zcode_dep = b.dependency("zcode", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("pek_zdsmallui", .{
        .root_source_file = b.path("pek_zdsmallui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zzig", .module = zzig_dep.module("zzig") },
            .{ .name = "pek_zpermissions", .module = perms_dep.module("pek_zpermissions") },
            .{ .name = "pek_zwaf", .module = zwaf_dep.module("pek_zwaf") },
            .{ .name = "zcode", .module = zcode_dep.module("zcode") },
        },
    });

    const lib_tests = b.addTest(.{ .root_module = mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "运行单元测试");
    test_step.dependOn(&run_lib_tests.step);

    // 可运行示例（`zig build run -- 18080 Biz`）：起服务 + 全部入口
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("examples/admin_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zzig", zzig_dep.module("zzig"));
    exe_mod.addImport("pek_zwaf", zwaf_dep.module("pek_zwaf"));
    exe_mod.addImport("pek_zdsmallui", mod);
    const exe = b.addExecutable(.{ .name = "zdsmallui-admin", .root_module = exe_mod });
    b.installArtifact(exe);

    // `zig build run -- 18081 Biz` 的参数直通给示例程序
    const run_exe = b.addRunArtifact(exe);
    run_exe.addPassthruArgs();
    const run_step = b.step("run", "启动后台示例服务（默认 127.0.0.1:18080，区域 Biz）");
    run_step.dependOn(&run_exe.step);

    // 异步高并发验证（zio 运行时：Windows IOCP / Linux io_uring；`dispatch = .task` 即协程）
    // `zig build zio-server -- 18091`
    const zio_dep = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const zio_mod = b.createModule(.{
        .root_source_file = b.path("examples/zio_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    zio_mod.addImport("zzig", zzig_dep.module("zzig"));
    zio_mod.addImport("zio", zio_dep.module("zio"));
    const zio_exe = b.addExecutable(.{ .name = "zdsmallui-zio", .root_module = zio_mod });
    b.installArtifact(zio_exe);
    const run_zio = b.addRunArtifact(zio_exe);
    run_zio.addPassthruArgs();
    const zio_step = b.step("zio-server", "异步高并发验证服务（zio 运行时 + dispatch=task）");
    zio_step.dependOn(&run_zio.step);

    // 最小对照（只 accept+读，不解析 HTTP）：拆分「协程栈」与「HTTP 层」的内存开销
    const min_mod = b.createModule(.{
        .root_source_file = b.path("examples/minaccept.zig"),
        .target = target,
        .optimize = optimize,
    });
    min_mod.addImport("zio", zio_dep.module("zio"));
    const min_exe = b.addExecutable(.{ .name = "zdsmallui-minaccept", .root_module = min_mod });
    const run_min = b.addRunArtifact(min_exe);
    run_min.addPassthruArgs();
    const min_step = b.step("minaccept", "最小对照：只 accept+读，测协程内存底噪");
    min_step.dependOn(&run_min.step);
}

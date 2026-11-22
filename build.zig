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

    // 视图清单自动生成：扫描 `Views/**` 与 `Areas/**/Views/**` 下的 `.zshtml`，
    // 产出 `views_generated.zig`（里面是 `@embedFile` 列表）。
    //
    // ★ 必须是**构建步骤**（run step + 目录作为输入依赖），不能写在 `build()` 里：
    //   `zig build` 会缓存 `build()` 的执行（build.zig 内容不变就不重跑）→
    //   新增视图时清单不更新，运行时直接「视图不存在」（2026-11-23 实测踩到）。
    const gen_views_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_views.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const gen_views_exe = b.addExecutable(.{ .name = "gen-views", .root_module = gen_views_mod });
    const gen_views_run = b.addRunArtifact(gen_views_exe);
    gen_views_run.setCwd(b.path("."));
    gen_views_run.addArg("Views");
    gen_views_run.addArg("Areas");
    // 两个目录作为输入依赖：新增/删除 `.zshtml` 会让该 step 重跑
    _ = gen_views_run.addDirectoryArg(b.path("Views"));
    _ = gen_views_run.addDirectoryArg(b.path("Areas"));
    gen_views_run.has_side_effects = true;
    const gen_views_step = b.step("gen-views", "扫描 Views/Areas 视图 → views_generated.zig");
    gen_views_step.dependOn(&gen_views_run.step);

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
    // 编译前先刷新视图清单（新增 `.zshtml` 不用改任何文件）
    lib_tests.step.dependOn(&gen_views_run.step);
    const run_lib_tests = b.addRunArtifact(lib_tests);

    // 语义检查（编译到 .o，**不链接、不跑测试**）：改代码时先跑它，比完整 `zig build` 快一档。
    //   实测（2026-11-22，Windows / 改一个库源文件）：`zig build` ≈ 14.0s，`zig build check` ≈ 10s，
    //   无改动缓存命中 ≈ 0.3s。
    const check_obj = b.addObject(.{ .name = "zdsmallui-check", .root_module = mod });
    check_obj.step.dependOn(&gen_views_run.step);
    const check_step = b.step("check", "只做语义检查（编译到 .o，不链接；比 zig build 快）");
    check_step.dependOn(&check_obj.step);

    const test_step = b.step("test", "运行单元测试");
    test_step.dependOn(&run_lib_tests.step);

    // 实体生成（**规范**：实体一律由 `Pek.ZCode` 的 `zcodegen` 从 `Model.xml` 生成，不手写）。
    //   zig build codegen           → `src/entities/{表}.zig` + `{表}.biz.zig` + `mod.zig`
    // 用户 / 角色 / 菜单等 Membership 表**不在这里重复生成**：直接用
    // `zcode.membership.entities`（本库已由同一生成器从 C# 同源 `Member.xml` 生成）。
    const gen_exe = zcode_dep.artifact("zcodegen");
    const gen_run = b.addRunArtifact(gen_exe);
    gen_run.setCwd(b.path("."));
    gen_run.addArg("--model");
    gen_run.addFileArg(b.path("assets/Model.xml"));
    gen_run.addArg("--out");
    gen_run.addArg("src/entities");
    const codegen_step = b.step("codegen", "按 assets/Model.xml 生成实体（*.zig + *.biz.zig + mod.zig）");
    codegen_step.dependOn(&gen_run.step);

    // 反向工程（与 C# `XCode` / Rust `Pek.RCode` 的 reverse 同口径）：
    //   zig build reverse -Dconn="Data Source=Data/Admin.db;Provider=SQLite" -Dout=Model.xml
    // 把现有库的表结构导成 `Model.xml`，作为「建表 / 改表」的起点；
    // 实际改不改结构、能不能删列，**由连接串里的 `Migration=` 决定**（Off / ReadOnly / On / Full，
    // 与 C# `ResolveMigration` 一致：只有 `Full` 才会删列 / 删索引 / 改列类型）。
    const rev_run = b.addRunArtifact(gen_exe);
    rev_run.setCwd(b.path("."));
    rev_run.addArg("--reverse");
    rev_run.addArg(b.option([]const u8, "conn", "反向工程连接串（Data Source=...;Provider=SQLite|MySQL|...）") orelse "");
    rev_run.addArg("--out");
    rev_run.addArg(b.option([]const u8, "out", "实体输出目录（默认 src/entities）") orelse "src/entities");
    rev_run.addArg("--model-out");
    rev_run.addArg(b.option([]const u8, "model-out", "导出的 Model.xml 路径（默认 Model.xml）") orelse "Model.xml");
    if (b.option(bool, "model-only", "只导出 Model.xml，不生成实体（看/比结构用）") orelse false) {
        rev_run.addArg("--model-only");
    }
    const reverse_step = b.step("reverse", "反向工程：库 → Model.xml（可选 → 实体）；改表前先反查现状");
    reverse_step.dependOn(&rev_run.step);

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
    exe.step.dependOn(&gen_views_run.step);
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

    // 已移除 `lighting-zio` 对照工程：它当年用来定位「59 KB/连接」里 std.http 占多少，
    // 结论是 std.http 的解析需要 >64 KiB 协程栈。zzig 已于 2026-11-19 把 lighting 的
    // 解析器收编进 src/http/{head_parser,body_reader}.zig（零分配、无外部依赖），
    // 本库 `zio-server` 就是收编后的实现，对照程序已无保留价值。
}

# Pek.ZDsMallUI（Zig）

「猿人易 / NCube / DsMallUI」后台 UI 能力的 **Zig 统一封装**：UEditor 富文本后端、上传下载、
后台 Area（首页 / 站点设置 / 登录，**区域名可配置**）、Razor 子集默认视图与静态资源，
全部复用 [zzig](../../zzig) 的 Web 栈（`zzig.web`：server / router / controller / view / static_files）。

- 参考工程（C#）：`G:\Code\Pek.FrameWork\Pek.DsMallUI`
- 参考实现（Rust）：`G:\Code\Rust\Pek.DsMallUI`
- 依赖公共库：`G:\Code\Zig\zzig`（Zig 侧 `dhrust` 对标库）
- 模块名：`pek_zdsmallui`（根文件 `pek_zdsmallui.zig`）

> **为什么要有这个库**：C# 侧的可移植资产只有三类——UEditor 后端协议、上传/下载控制器、
> 后台 Area 的视图与设置页。它们此前只能靠 ASP.NET Core + XCode 运行；现在 Zig 服务
> 也能用同一套路由/视图约定提供同样的后台界面（视图是 Razor 子集，三端可渲染）。

## 目录（与 C# 工程同构）

```text
Pek.ZDsMallUI/
├─ Areas/Admin/
│  ├─ Controllers/                 # 一控制器一文件（与 C# 一致）
│  │  ├─ AdminArea.zig             #   区域级共享上下文（数据源/视图/区域名/挂载）
│  │  ├─ HomeController.zig        #   GET  /{area}/home/index
│  │  ├─ ConfigController.zig      #   GET  /{area}/config/index、POST updatebase
│  │  └─ LoginController.zig       #   GET /{area}/login/index、POST login、POST|GET logout、GET status
│  └─ Views/                       # 区域视图（Home/Config/Login）
├─ Controllers/UploadController.zig # /fileuploader、/Upload/downloads/*
├─ Views/Shared/                   # _Layout.cshtml、Prompt.cshtml
├─ assets/                         # ueconfig.json、admin-config.js（首次部署落地）
├─ src/                            # Zig 侧基础设施
│  ├─ area.zig / backend.zig / models.zig
│  ├─ auth.zig                     # 登录 JWT 签发/校验/登出吊销（复用 Pek.ZPermissions）
│  ├─ multipart.zig                # multipart/form-data 解析（zzig 暂无）
│  ├─ password.zig                 # C# `SaltPasswordProvider` 字节级互通
│  ├─ views.zig / options.zig      # 视图约定 + 门面（Builder）
│  └─ ueditor/{mod,config,path,upload,list,crawler}.zig
├─ examples/admin_server.zig       # 可运行示例（起服务 + 全部入口）
├─ tools/regression.ps1            # 一键回归（构建 → 测试 → 冒烟）
└─ tools/sync-wwwroot.ps1          # 从 C# 参考工程同步第三方静态资源
```

## 快速开始

```toml
# build.zig.zon
.dependencies = .{
    .zzig = .{ .path = "../zzig" },
    .pek_zdsmallui = .{ .path = "../Pek.ZDsMallUI" },
},
```

```zig
const zzig = @import("zzig");
const pek_zdsmallui = @import("pek_zdsmallui");

pub fn main(init: std.process.Init) !u8 {
    const ui = try pek_zdsmallui.DsMallUi.builder(init.gpa, init.io)
        .webRoot("wwwroot")        // 静态资源根（/static/** 等）
        .viewsRoot("Views")        // 共享视图根（Views/Shared/…）
        .areasRoot("Areas")        // 区域根（Areas/{Area}/Views/…）
        .uploadPath("upload")      // 上传目录（相对 web_root），URL 前缀 /upload
        .adminArea("Biz")          // 后台区域名（默认 Admin；路由变 /biz/...）
        .jwtSecret("HS256:改成你的密钥") // 登录 JWT（不配 = 进程内随机，重启旧令牌失效）
        .jwtExpireMinutes(120)     // 令牌有效期（分钟，对齐 NewLife 默认 2 小时）
        .build();
    defer ui.deinit();

    _ = try ui.materializeDefaults();   // 首次部署：落地默认视图 + ueconfig.json（只补缺失）

    var app = try zzig.web.App.init(init.gpa, init.io, .{ .wwwroot = "wwwroot" });
    defer app.deinit();
    try ui.mount(&app);                  // /fileuploader、/Upload/*、/{area}/home|config|login/*

    try app.run("127.0.0.1", 8080, .{
        .max_body = ui.maxUploadBytes(),      // 上传体积上限
        .max_connections = 128,
    });
    return 0;
}
```

本地跑起来看效果（示例默认区域 `Biz`）：

```powershell
zig build run                       # 默认 127.0.0.1:18080，区域 Biz
zig build run -- 18081              # 指定端口
zig build run -- 18081 Admin        # 指定端口 + 区域名
```

| 入口（`{area}` 由配置决定，默认 `admin`） | 说明 |
|---|---|
| `GET /{area}/home/index` | 后台首页（控制台 + 快捷入口） |
| `GET /{area}/config/index` | 站点设置页（Razor 子集渲染，套 `Views/Shared/_Layout.cshtml`） |
| `POST /{area}/config/updatebase` | 保存设置（字段名与 C# `ConfigController.UpdateBase` 一致） |
| `GET /{area}/login/index` | 登录页 |
| `POST /{area}/login/login` | 登录（示例账号 `admin` / `admin123`；成功下发 JWT Cookie，Ajax 额外返回 `token`） |
| `POST|GET /{area}/login/logout` | 退出登录（吊销 JWT + 清 Cookie） |
| `GET /{area}/login/status` | 当前登录状态（JSON：`authenticated` / `userName` / `isAdmin` / `expiresAt`） |
| `GET /fileuploader?action=config` | UEditor 配置（原样回吐 `ueconfig.json`） |
| `POST /fileuploader?action=uploadimage` | 图片上传（multipart，字段 `upfile`） |
| `POST /fileuploader?action=uploadscrawl` | 涂鸦（base64 data URL） |
| `POST /fileuploader?action=uploadfile` | 附件上传 |
| `POST /fileuploader?action=catchimage` | 远程图片抓取（`source[]`，仅 http/https，带 20s 超时） |
| `GET /fileuploader?action=listimage` | 图片管理器分页列表 |
| `GET /Upload/downloads/{path}` | 下载上传目录内文件（`Content-Disposition`、ETag/304） |

## 登录与 JWT

登录成功即签发 **HS256 JWT**，实现直接复用 [`Pek.ZPermissions`](../Pek.ZPermissions)
（与 C# `NewLife.Web.JwtBuilder`、Rust `Pek.RPermissions` 字节级互通），**不自己写 HMAC**。

- **声明**：`sub`（用户 id）、`name`（登录名）、`displayName`、`isAdmin`，库注入 `iss` / `exp` / `iat` / `jti`；
- **两条通道**：浏览器走 Cookie `{area}_token`（`HttpOnly; SameSite=Lax`），脚本走 `Authorization: Bearer <token>`；
  取令牌顺序 **Cookie 优先 → Bearer**；
- **登出即失效**：`SessionKeeper.revoke(token)` 写吊销表（默认内存实现；
  `builder.sessionStore(store)` 可换成 `SqliteStore` / `FileStore` / `RedisStore` 做持久化）；
- **中间件**挂在 `AdminArea.mount` 最前，解析身份写入链路状态 `auth.uid` / `user` / `auth.token`
  （`user` 即模板里的 `@Model.userName`）；
- **是否强制登录**：`builder.requireLogin(true)` 时后台页面未登录直接 302 到
  `/{area}/login/index?returnUrl=…`；**默认关闭**（与 C#/Rust 版现状一致，不改变既有页面行为）；
- **密钥必须显式配**：未配 = 进程内随机 + WARN 日志（重启后旧令牌全部失效，只适合开发）；
  HTTPS 部署记得 `builder.cookieSecure(true)`。

```powershell
# 取令牌 + 带 Bearer 查状态 + 登出（PowerShell）
$r = curl.exe -s -H 'X-Requested-With: XMLHttpRequest' -d 'UserName=admin&Password=admin123' http://127.0.0.1:18080/biz/login/login
$token = [regex]::Match($r, '"token":"([^"]+)"').Groups[1].Value
curl.exe -s -H "Authorization: Bearer $token" http://127.0.0.1:18080/biz/login/status
curl.exe -s -i -H "Authorization: Bearer $token" http://127.0.0.1:18080/biz/login/logout
```

## 区域（Area）

后台路由与视图都按 **ASP.NET Core Areas** 约定组织（对标 C# `Areas/Admin` 与
`DHSetting.Current.AdminArea`）：

- **默认区域 `Admin`**，消费方可按自己的配置改名（如 `Biz`）：
  `builder.adminArea("Biz")` → 路由 `/biz/...`、视图 `Areas/Biz/Views/...`；
- **视图回退**：`Areas/{Area}/Views/...` 不存在时自动用 `Areas/Admin/Views/...`
  （由 `zzig.web.ViewRenderer` 的 `setFallbackArea` 提供），因此改区域名**不必复制默认视图**；
  要定制时再在 `Areas/Biz/Views/Config/Index.cshtml` 放同名文件覆盖（对齐 NCube「子项目视图重写父项目视图」）；
- **命名约束**：字母开头，仅字母/数字/`_`/`-`（`a/b`、`1admin` 在 `build()` 直接报错）；
  存储/视图目录 Pascal 化，URL 段小写；
- 区域名在**装配时**决定（读自己的配置后传给 builder），与 C# 启动时读 `AdminArea` 同口径。

## 静态资源（wwwroot）

**约定：资源目录默认不编译进二进制，且路径由业务系统决定。**

- `builder.webRoot("wwwroot")` —— 业务系统按自己的配置传入任意路径，默认 `wwwroot`；
- C# 参考工程的 `wwwroot/static` 是 **825 个文件 / 24.6 MB 的第三方前端资产**，
  不适合复制进本仓库；需要时用 `tools/sync-wwwroot.ps1` 增量同步到运行目录：

```powershell
.\tools\sync-wwwroot.ps1
```

## 与 C# / Rust 参考实现的差异

见 [`docs/移植对照.md`](docs/移植对照.md)。要点：

1. C# `UploadHandler.Process`、`Crawler.Fetch`、`UeditorConfig.GetStringList` 当前是**注释掉的**
   （上传一律「未知错误」、扩展名列表恒为空）；Zig 侧按 UEditor 官方协议**补齐实现**。
2. 视图从 C# 版（依赖 `@PekHtml.*`、`@T()`、tag helper）**改写为 Razor 子集**
   （`zzig.web.view`：`@expr` / `@if` / `@foreach` / `@{ var }` / `Layout` / `RenderBody` / `section` / `PartialAsync`）。
3. `{rand:n}` 生成 **n 位**数字（C# 的 `rand.Next(10^n, 10^(n+1))` 实际是 n+1 位）。
4. 文件名清洗把非法字符替换为 `_`、`..` 折叠为 `__`，并额外做落盘路径越界校验。
5. 后台持久化通过 `AdminBackend`（vtable）注入，不绑定任何 ORM；C# 版直接写 XCode 实体。
6. 口令存储/校验走 `password.zig`（默认 `md5+sha1`，与 C# `SaltPasswordProvider` 字节级互通）。
7. 登录/退出与 JWT 走 `auth.zig`（复用 `Pek.ZPermissions`）；C# 参考工程只在动作上打了 `[EntityAuthorize]`，
   本仓库把「签发 / 校验 / 吊销」做完整，并同时支持 Cookie 与 Bearer。
8. 远程抓取扩展名按 URL 推断（`zzig.Http` 不回响应头），无扩展名时 `.jpg` 兜底。

## 依赖与约束

- 需要 Zig **0.17.x**（与 zzig 同步）；
- 依赖 `../zzig` 与 `../Pek.ZPermissions`（后者再带 `Pek.ZCode` / `Pek.ZRedis`），均按路径引用；
- 请求体上限由 `zzig.http.server.Options.max_body` 控制，用 `ui.maxUploadBytes()` 传入；
- `DsMallUi` **必须堆分配且挂载后不得移动**（控制器持有指向它的指针）；
- 新增功能的**第一动作是检索**：先看 `zzig` 有没有现成能力，再看本仓库实现，最后才写。

## 开发

```powershell
zig build test            # 单元测试
zig build                 # 构建示例（zig-out/bin/zdsmallui-admin.exe）
zig build run             # 起服务本地验证
.\tools\regression.ps1    # 一键回归（构建 → 测试 → HTTP 冒烟）
```

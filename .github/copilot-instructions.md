# 项目指令（Pek.ZDsMallUI · Zig）

本仓库是「猿人易 / NCube / DsMallUI」后台 UI 能力的 Zig 封装，**与 C# / Rust 两个参考工程同构**。

## 开工先读（按序）

1. `docs/项目接续指南.md` — 常用命令、目录约定、回归门槛
2. `docs/项目记忆.md` — 已沉淀的坑与决定
3. `docs/决策记录.md` — 为什么这么做（含用户原话）
4. `docs/移植对照.md` — 与 C# / Rust 的功能对照与差异

## 硬性约定

- **目录与 C# 同构**：`Areas/Admin/Controllers`（一控制器一文件）、`Areas/Admin/Views`、
  `Controllers/`、`Views/Shared/`；Zig 侧基础设施放 `src/`。
- **复用优先**：写码前先检索 `zzig`（Zig 侧公共库，对标 Rust 的 `dhrust`）是否已有能力；
  没有才在本仓库实现，并在模块文档写清「检索证据」。
- **视图是 Razor 子集**：`@expr` / `@if` / `@foreach` / `@{ var; Layout = "..." }` /
  `@section` + `@await RenderSectionAsync` / `@Html.PartialAsync`。
  注意：`@section` 体内遇到 `}` 即结束块 → **内联 JS 必须挪到静态文件**。
- **禁止原生弹窗**：新增/修改面板页面不得使用 `alert` / `confirm` / `prompt`（全局前端规范）。
- **口令**：一律走 `src/password.zig`（默认 `md5+sha1`，与 C# 字节级互通），不要自写散列。
- **日志**：失败/跳过必须带「做什么 + 为什么 + 上下文」，禁止吞异常。
- **验证分档**：`zig build test` → `zig build` → 起本地实例实测；不要动辄全量打包。
- **提交信息中文**：`type(scope): 中文主题`，用 `git commit -F <UTF-8 文件>`。

## 回归门槛

```
zig build test                     # 必须全绿（当前基线 82 项）
zig build                          # 示例可执行文件
.\tools\regression.ps1             # 构建 + 测试 + HTTP 冒烟（退出码 0/1）
```

新增用例后同步抬高 `tools/regression.ps1` 里的基线；降低必须写进 `docs/决策记录.md`。

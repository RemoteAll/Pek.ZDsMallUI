//! 库内模块的单点依赖表（**只给库内文件用**）。
//!
//! 为什么需要：`Areas/Admin/Controllers/*.zig` 这类目录比 `src/` 深两级，
//! 直接写 `@import("../../../src/language.zig")` 会把「相对层级 + 具体文件名」散落到各处，
//! 一旦目录调整就得全仓改。这里集中一层：外部/内部都只认 `deps.language` 这样的**名字**。
//!
//! 说明（关于「换电脑 / 换目录」）：Zig 的 `@import` 是**编译期**按当前源文件的相对路径解析，
//! 与盘符、绝对路径无关 —— 仓库内部结构不变就永远有效。真正会跟运行目录绑在一起的是**运行时**路径
//! （`Views` / `wwwroot` / `Model.xml` / `Data`），那些走「程序目录探测 + 相对 cwd」，不写死盘符。

pub const area = @import("area.zig");
pub const auth = @import("auth.zig");
pub const backend = @import("backend.zig");
pub const captcha = @import("captcha.zig");
pub const language = @import("language.zig");
pub const login_guard = @import("login_guard.zig");
pub const menu = @import("menu.zig");
pub const menu_db = @import("menu_db.zig");
pub const password = @import("password.zig");
pub const sqlite_backend = @import("sqlite_backend.zig");
pub const sqlite_session_store = @import("sqlite_session_store.zig");
pub const sysinfo = @import("sysinfo.zig");
pub const views = @import("views.zig");
pub const version = @import("version.zig");

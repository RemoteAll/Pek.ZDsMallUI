//! # Pek ZDsMallUI（Zig）
//!
//! 「猿人易 / NCube / DsMallUI」后台 UI 能力的 **Zig 统一封装**，与
//! C# 参考工程 `G:\Code\Pek.FrameWork\Pek.DsMallUI`、Rust 版 `G:\Code\Rust\Pek.DsMallUI`
//! 一一对应，复用 [zzig](https://github.com/PeiKeSmart/zzig) 的 Web 栈
//! （`zzig.web`：server / router / controller / view / static_files）。
//!
//! ## 目录：与 C# 工程同构
//!
//! ```text
//! ├─ Areas/Admin/Controllers/      # 区域控制器（一控制器一文件）
//! │   ├─ AdminArea.zig             #   区域级共享上下文（C# 的 Areas/Admin 公共部分）
//! │   ├─ HomeController.zig        #   GET  /{area}/home/index
//! │   ├─ ConfigController.zig      #   GET  /{area}/config/index、POST updatebase
//! │   └─ LoginController.zig       #   GET  /{area}/login/index、POST login
//! ├─ Areas/Admin/Views/            # 区域视图（Razor 子集，双端可渲染）
//! ├─ Controllers/UploadController.zig  # /fileuploader、/Upload/downloads/*
//! ├─ Views/Shared/                 # 布局与提示页
//! ├─ assets/                       # ueconfig.json、后台校验脚本（首次部署落地）
//! └─ src/                          # Zig 侧基础设施（C# 无对应物）
//! ```
//!
//! ## 提供什么
//!
//! | 能力 | 入口 | C# 对应 |
//! |---|---|---|
//! | 门面/装配 | [`DsMallUi`] | `PekStartup`（`IPekStartup`） |
//! | 区域约定 | [`area`]（默认 `Admin`，可改 `Biz`） | `DHSetting.Current.AdminArea` |
//! | 上传/下载 | [`Controllers.UploadController`] | `Controllers/UploadController.cs` |
//! | UEditor 后端 | [`ueditor`] | `UEditor/*.cs` |
//! | 多段表单解析 | [`multipart`] | `Request.ReadFormAsync()` |
//! | 后台 Area | [`Areas.Admin.Controllers`] | `Areas/Admin/**` |
//! | 视图约定 | [`views`] | `Areas/Admin/Views/**`（Razor 子集） |
//! | 折叠实体 | [`models`] | `Models/Hierarchy.cs` |
//! | 口令散列 | [`password`] | `SaltPasswordProvider`（字节级互通） |

const std = @import("std");

// ————— Zig 侧基础设施 —————
pub const area = @import("src/area.zig");
pub const auth = @import("src/auth.zig");
pub const backend = @import("src/backend.zig");
pub const sqlite_backend = @import("src/sqlite_backend.zig");
pub const sqlite_session_store = @import("src/sqlite_session_store.zig");
pub const models = @import("src/models.zig");
pub const multipart = @import("src/multipart.zig");
pub const options = @import("src/options.zig");
pub const password = @import("src/password.zig");
pub const base64 = @import("src/base64.zig");
pub const ueditor = @import("src/ueditor/mod.zig");
pub const views = @import("src/views.zig");
pub const language = @import("src/language.zig");
pub const menu = @import("src/menu.zig");
pub const sysinfo = @import("src/sysinfo.zig");
pub const version_info = @import("src/version.zig");

/// `Areas/Admin/Controllers/AdminArea.zig` 的**模块导出**（不只是 struct 类型）。
///
/// 业务项目要加自己的后台页时，需要这几个**模块级函数**（它们不接受 self 作为方法调用）：
/// - `renderView(area, c, "Controller", "View", model)`：渲染 `Areas/{Area}/Views/...` 并自动补
/// `lang` / `groups` / 页面耗时（与库内页面完全同一套口径）；
/// - `currentUser(c)`：读鉴权中间件写入的登录用户；
/// - `castSelf(raw)` / `guarded(...)`。
/// 只导出模块、不改任何行为（纯增量）。
pub const admin_area_mod = @import("Areas/Admin/Controllers/AdminArea.zig");

// ————— C# 风格目录（Areas / Controllers）—————
pub const Areas = struct {
    pub const Admin = struct {
        pub const Controllers = struct {
            pub const AdminArea = @import("Areas/Admin/Controllers/AdminArea.zig").AdminArea;
            pub const HomeController = @import("Areas/Admin/Controllers/HomeController.zig").HomeController;
            pub const ConfigController = @import("Areas/Admin/Controllers/ConfigController.zig").ConfigController;
            pub const LoginController = @import("Areas/Admin/Controllers/LoginController.zig").LoginController;
        };
    };
};

pub const Controllers = struct {
    pub const UploadController = @import("Controllers/UploadController.zig").UploadController;
};

/// 控制器聚合（与 Rust 版 `controllers` 对齐的便捷入口）。
pub const controllers = struct {
    pub const admin_area = @import("Areas/Admin/Controllers/AdminArea.zig");
    pub const home = @import("Areas/Admin/Controllers/HomeController.zig");
    pub const config = @import("Areas/Admin/Controllers/ConfigController.zig");
    pub const login = @import("Areas/Admin/Controllers/LoginController.zig");
    pub const upload = @import("Controllers/UploadController.zig");
};

// ————— 门面再导出（与 Rust 版 `pub use` 对齐）—————
pub const AdminArea = Areas.Admin.Controllers.AdminArea;
pub const AdminBackend = backend.AdminBackend;
pub const AdminUser = backend.AdminUser;
pub const MemoryBackend = backend.MemoryBackend;
pub const SqliteBackend = sqlite_backend.SqliteBackend;
pub const SqliteSessionStore = sqlite_session_store.SqliteSessionStore;
pub const UploadState = ueditor.UploadState;
pub const UeditorConfig = ueditor.UeditorConfig;
pub const UeditorService = ueditor.UeditorService;
pub const Uploader = ueditor.Uploader;
pub const Views = views.Views;
pub const DsMallUi = options.DsMallUi;
pub const Builder = options.Builder;
pub const Auth = auth.Auth;
pub const AuthOptions = auth.Options;
pub const SessionStore = auth.SessionStore;
pub const Hierarchy = models.Hierarchy;

/// 库版本（与 `build.zig.zon` 同步）。
pub fn version() []const u8 {
    return version_info.VERSION;
}

const testing = std.testing;

test "所有子模块可编译（含其测试）" {
    std.testing.refAllDecls(@This());
    testing.refAllDecls(area);
    testing.refAllDecls(auth);
    testing.refAllDecls(backend);
    testing.refAllDecls(models);
    testing.refAllDecls(multipart);
    testing.refAllDecls(password);
    testing.refAllDecls(base64);
    testing.refAllDecls(views);
    testing.refAllDecls(ueditor);
    testing.refAllDecls(options);
    testing.refAllDecls(Areas.Admin.Controllers.AdminArea);
    testing.refAllDecls(Areas.Admin.Controllers.HomeController);
    testing.refAllDecls(Areas.Admin.Controllers.ConfigController);
    testing.refAllDecls(Areas.Admin.Controllers.LoginController);
    testing.refAllDecls(Controllers.UploadController);
}

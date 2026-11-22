//! 门面：一次性组装「静态资源 + 上传控制器 + 后台 Area」，对外只暴露 [`DsMallUi`]。
//!
//! 对应 C# 参考工程的 `PekStartup`（`IPekStartup` 实现）：
//! `ConfigureServices` → [`Builder`]；`UseDHEndpoints`/`Configure` → [`DsMallUi.mount`]。
//!
//! ```zig
//! var ui = try pek_zdsmallui.DsMallUi.builder(allocator, io)
//!     .webRoot("wwwroot")
//!     .viewsRoot("Views")
//!     .adminArea("Biz")      // 后台区域名（默认 Admin；路由变 /biz/...）
//!     .build();
//! defer ui.deinit();
//!
//! _ = try ui.materializeDefaults();   // 首次部署：落地默认视图 + ueconfig.json（只补缺失）
//! var app = try zzig.web.App.init(allocator, io, .{ .wwwroot = "wwwroot" });
//! defer app.deinit();
//! try ui.mount(&app);
//! try app.run("127.0.0.1", 8080, .{ .max_body = ui.maxUploadBytes() });
//! ```

const std = @import("std");
const zzig = @import("zzig");

const area_mod = @import("area.zig");
const auth_mod = @import("auth.zig");
const captcha_mod = @import("captcha.zig");
const backend_mod = @import("backend.zig");
const sqlite_backend_mod = @import("sqlite_backend.zig");
const sqlite_session_mod = @import("sqlite_session_store.zig");
const controllers = struct {
    const admin_area = @import("../Areas/Admin/Controllers/AdminArea.zig");
    const upload = @import("../Controllers/UploadController.zig");
};
const ueditor_mod = @import("ueditor/mod.zig");
const views_mod = @import("views.zig");
const login_guard_mod = @import("login_guard.zig");
const language_mod = @import("language.zig");
const menu_mod = @import("menu.zig");
const pek_zwaf = @import("pek_zwaf");

/// 默认上传目录名（C# `UploadPath` 默认值同为 `upload`）。
pub const DEFAULT_UPLOAD_PATH = "upload";
/// 默认后台区域名（与 C# `AdminArea.AreaName` 默认值一致：`Admin`）。
pub const DEFAULT_ADMIN_AREA = area_mod.DEFAULT_AREA;
/// 默认请求体上限（与 Rust 版 `DEFAULT_MAX_UPLOAD_BYTES` 一致）。
pub const DEFAULT_MAX_UPLOAD_BYTES: u64 = 64 * 1024 * 1024;

/// 内置 UEditor 配置原文（部署时可落地为 `wwwroot/ueconfig.json` 供前端读取）。
pub const UE_CONFIG_JSON = @embedFile("../assets/ueconfig.json");

/// 内置后台客户端校验脚本（部署时落地到 `wwwroot/static/admin/js/admin-config.js`）。
pub const ADMIN_CONFIG_JS = @embedFile("../assets/admin-config.js");

/// 登录页前端 MD5 脚本（部署时落地到 `wwwroot/static/admin/js/login-md5.js`）。
pub const LOGIN_MD5_JS = @embedFile("../assets/login-md5.js");

/// 后台静态资源清单（**原样导出自 C# `Pek.NCubeUI.DsMallUI` 的嵌入资源**，保证版式完全一致）。
///
/// 为什么内置：视图沿用参考工程的类名，而 C# 的 `admin.css` / layui / jquery / logo / 背景图
/// 没有随库迁移 —— 缺文件会导致「登录页无样式裸奔 + 控制台一堆 404」。
/// 带体积（合计 ≈360 KB）对二进制影响可控，换来「开箱即用且与 C# 一致」。
/// 消费方想换皮：直接覆盖 `wwwroot/static/admin/css/admin.css` 即可（materialize 只补缺失、不覆盖）。
pub const ADMIN_STATIC_ASSETS = [_]struct { relative: []const u8, source: []const u8 }{
    .{
        .relative = "static/admin/css/admin.css",
        .source = @embedFile("../assets/wwwroot/static/admin/css/admin.css"),
    },
    .{
        .relative = "static/plugins/js/layui/css/layui.css",
        .source = @embedFile("../assets/wwwroot/static/plugins/js/layui/css/layui.css"),
    },
    .{
        .relative = "static/plugins/jquery214.min.js",
        .source = @embedFile("../assets/wwwroot/static/plugins/jquery214.min.js"),
    },
    .{
        .relative = "static/admin/images/logo.png",
        .source = @embedFile("../assets/wwwroot/static/admin/images/logo.png"),
    },
    // 图标字体（`.iconfont` 类依赖；缺字体会让菜单图标变方框）
    .{
        .relative = "static/plugins/iconfont/iconfont.css",
        .source = @embedFile("../assets/wwwroot/static/plugins/iconfont/iconfont.css"),
    },
    .{
        .relative = "static/plugins/iconfont/iconfont.woff",
        .source = @embedFile("../assets/wwwroot/static/plugins/iconfont/iconfont.woff"),
    },
    .{
        .relative = "static/plugins/iconfont/iconfont.ttf",
        .source = @embedFile("../assets/wwwroot/static/plugins/iconfont/iconfont.ttf"),
    },
    .{
        .relative = "static/plugins/iconfont/iconfont.eot",
        .source = @embedFile("../assets/wwwroot/static/plugins/iconfont/iconfont.eot"),
    },
    // 后台框架页顶部 logo 与波浪背景（C# `.admincp-header` 用图）
    .{
        .relative = "static/admin/images/backlogo.png",
        .source = @embedFile("../assets/wwwroot/static/admin/images/backlogo.png"),
    },
    .{
        .relative = "static/admin/images/wave.png",
        .source = @embedFile("../assets/wwwroot/static/admin/images/wave.png"),
    },
    .{
        .relative = "static/admin/images/wallpage/bg_1.jpg",
        .source = @embedFile("../assets/wwwroot/static/admin/images/wallpage/bg_1.jpg"),
    },
    .{
        .relative = "static/admin/js/admin.js",
        .source = @embedFile("../assets/wwwroot/static/admin/js/admin.js"),
    },
    // layer 弹层（后台视图的提示/确认框依赖它；缺文件会在控制台报 404）
    .{
        .relative = "static/plugins/layer/layer.js",
        .source = @embedFile("../assets/wwwroot/static/plugins/layer/layer.js"),
    },
    .{
        .relative = "static/plugins/layer/theme/default/layer.css",
        .source = @embedFile("../assets/wwwroot/static/plugins/layer/theme/default/layer.css"),
    },
    .{
        .relative = "static/plugins/layer/theme/default/icon.png",
        .source = @embedFile("../assets/wwwroot/static/plugins/layer/theme/default/icon.png"),
    },
    .{
        .relative = "static/plugins/layer/theme/default/icon-ext.png",
        .source = @embedFile("../assets/wwwroot/static/plugins/layer/theme/default/icon-ext.png"),
    },
    .{
        .relative = "static/plugins/layer/theme/default/loading-0.gif",
        .source = @embedFile("../assets/wwwroot/static/plugins/layer/theme/default/loading-0.gif"),
    },
    .{
        .relative = "static/plugins/layer/theme/default/loading-1.gif",
        .source = @embedFile("../assets/wwwroot/static/plugins/layer/theme/default/loading-1.gif"),
    },
    .{
        .relative = "static/plugins/layer/theme/default/loading-2.gif",
        .source = @embedFile("../assets/wwwroot/static/plugins/layer/theme/default/loading-2.gif"),
    },
};

/// DsMallUI 门面（**必须堆分配且挂载后不得移动**：控制器持有指向本对象的指针）。
pub const DsMallUi = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    web_root: []const u8,
    upload_root: []const u8,
    upload_prefix: []const u8,
    views_root: []const u8,
    areas_root: []const u8,
    max_upload_bytes: u64,
    ui_views: views_mod.Views,
    service: ueditor_mod.UeditorService,
    admin_area: *controllers.admin_area.AdminArea,
    upload_controller: *controllers.upload.UploadController,
    /// 伪静态后缀（由 Builder 传入；挂在 `app.router` 上）
    pseudo_suffixes: []const []const u8 = &.{},
    /// 内置内存数据源（未指定外部 backend 时由本对象拥有）
    memory_backend: ?*backend_mod.MemoryBackend = null,
    /// 登录防爆破守卫（进程内计数，随本对象释放）
    login_guard: login_guard_mod.Guard,
    /// 图形验证码存储（`captcha_enabled` 为真时存在；登录失败达阈值后要求输入）
    captcha_store: ?captcha_mod.Store = null,
    /// WAF（`null` = 未启用；由 `Builder.waf(base_dir)` 创建，`mount` 首行注册中间件）
    waf_instance: ?*pek_zwaf.Waf = null,
    /// SQLite 会话吊销表（`storage` 启用且未给外部 store 时自动创建；随本对象释放）
    session_store: ?*sqlite_session_mod.SqliteSessionStore = null,
    /// 多语言（`Language` + `LocaleStringResource`；无 `storage` 时为内存内置双语）
    languages: language_mod.Store,
    /// 后台菜单注册表（库自带默认菜单，项目可 `addMenu` 追加）
    menus: menu_mod.Registry,

    /// 构造门面（默认配置）。
    pub fn builder(allocator: std.mem.Allocator, io: std.Io) Builder {
        return .{ .allocator = allocator, .io = io };
    }

    /// 释放控制器、视图缓存与自有字符串。
    pub fn deinit(self: *DsMallUi) void {
        self.login_guard.deinit();
        self.menus.deinit();
        self.languages.deinit();
        if (self.captcha_store) |*store| store.deinit();
        if (self.waf_instance) |w| w.deinit();
        if (self.session_store) |st| st.deinit();
        self.upload_controller.deinit();
        self.admin_area.deinit();
        self.ui_views.deinit();
        self.service.deinit();
        if (self.memory_backend) |mem| mem.deinit();

        self.allocator.free(self.web_root);
        self.allocator.free(self.upload_root);
        self.allocator.free(self.upload_prefix);
        self.allocator.free(self.views_root);
        self.allocator.free(self.areas_root);
        self.allocator.destroy(self);
    }

    /// 站点物理根（`wwwroot`）。
    pub fn webRoot(self: *const DsMallUi) []const u8 {
        return self.web_root;
    }

    /// 多语言仓储（只读路径：`text` / `defaultLanguage` / `all`）。
    pub fn languagesStore(self: *DsMallUi) *language_mod.Store {
        return &self.languages;
    }

    /// 重载多语言（管理页保存后调用；读路径不查库）。
    pub fn reloadLanguages(self: *DsMallUi) !void {
        try self.languages.reload();
    }

    /// 注册后台菜单项（等价 C# 控制器上的 `[DHMenu(...)]`，项目启动时调用）。
    pub fn addMenu(self: *DsMallUi, item: menu_mod.Item) !void {
        try self.menus.addItem(item);
    }

    /// 注册一级菜单分组（默认已有 `console` / `settings`）。
    pub fn addMenuGroup(self: *DsMallUi, group: menu_mod.Group) !void {
        try self.menus.addGroup(group);
    }

    /// 上传物理根（`<web_root>/<upload_path>`）。
    pub fn uploadRoot(self: *const DsMallUi) []const u8 {
        return self.upload_root;
    }

    /// 上传对外 URL 前缀（`/upload`）。
    pub fn uploadPrefix(self: *const DsMallUi) []const u8 {
        return self.upload_prefix;
    }

    /// 视图根。
    pub fn views(self: *DsMallUi) *views_mod.Views {
        return &self.ui_views;
    }

    /// UEditor 服务（读取配置/单独挂载时使用）。
    pub fn ueditor(self: *const DsMallUi) *const ueditor_mod.UeditorService {
        return &self.service;
    }

    /// 后台 Area（读取数据源/复用页面模型时使用）。
    pub fn admin(self: *const DsMallUi) *controllers.admin_area.AdminArea {
        return self.admin_area;
    }

    /// WAF 实例（需要自己挂 `ServerGuard` 早据时用；未启用为 `null`）。
    pub fn waf(self: *const DsMallUi) ?*pek_zwaf.Waf {
        return self.waf_instance;
    }

    /// 后台区域名（Pascal，如 `Admin` / `Biz`）。
    pub fn adminArea(self: *const DsMallUi) []const u8 {
        return self.admin_area.areaName();
    }

    /// 请求体上限（交给 `zzig.web.App.run` 的 `max_body`）。
    pub fn maxUploadBytes(self: *const DsMallUi) usize {
        return @intCast(self.max_upload_bytes);
    }

    /// 把路由挂到应用：`/fileuploader`、`/Upload/*`、`/{area}/home|config|login/*`。
    pub fn mount(self: *DsMallUi, app: *zzig.web.App) !void {
        // WAF 必须在最前注册：后面匹配到的路由（含登录页、上传、静态）全部生效
        if (self.waf_instance) |w| try app.useMiddleware(w.middleware());

        // 伪静态后缀（官网类）：`/x.html` → `/x`，精确路由优先、参数路由次之
        try app.router.addSuffixes(self.pseudo_suffixes);

        try self.upload_controller.mount(app);
        try self.admin_area.mount(app);
    }

    /// 启动准备：清理历史落盘的视图副本 + 把 `ueconfig.json` / 后台脚本落地（**只补缺失，不覆盖**）。
    ///
    /// - **视图不落盘**：内置视图直接编译进二进制，磁盘缺失时由渲染器回退（对齐 C# 预编译视图）；
    ///   老版本落下的副本（首行带 `@* pek-zdsmallui:generated`）会被删掉，避免盖住库里的新版本；
    ///   用户在项目里手写的同名视图（无标记）保留并优先使用；
    /// - 配置 → `<web_root>/ueconfig.json`；
    /// - 脚本 → `<web_root>/static/admin/js/admin-config.js`、`login-md5.js`（设置页/登录页用）。
    pub fn materializeDefaults(self: *DsMallUi) !usize {
        try zzig.fsio.makePath(self.io, self.web_root);
        var written = views_mod.cleanupGeneratedCopies(
            self.allocator,
            self.io,
            self.views_root,
            self.areas_root,
            self.admin_area.areaName(),
        );

        const config_path = try std.fmt.allocPrint(self.allocator, "{s}/ueconfig.json", .{self.web_root});
        defer self.allocator.free(config_path);
        if (!zzig.fsio.exists(self.io, config_path)) {
            try zzig.fsio.writeFile(self.io, config_path, UE_CONFIG_JSON);
            written += 1;
        }

        const script_path = try std.fmt.allocPrint(self.allocator, "{s}/static/admin/js/admin-config.js", .{self.web_root});
        defer self.allocator.free(script_path);
        if (!zzig.fsio.exists(self.io, script_path)) {
            if (std.fs.path.dirname(script_path)) |parent| try zzig.fsio.makePath(self.io, parent);
            try zzig.fsio.writeFile(self.io, script_path, ADMIN_CONFIG_JS);
            written += 1;
        }

        const login_script_path = try std.fmt.allocPrint(self.allocator, "{s}/static/admin/js/login-md5.js", .{self.web_root});
        defer self.allocator.free(login_script_path);
        if (!zzig.fsio.exists(self.io, login_script_path)) {
            if (std.fs.path.dirname(login_script_path)) |parent| try zzig.fsio.makePath(self.io, parent);
            try zzig.fsio.writeFile(self.io, login_script_path, LOGIN_MD5_JS);
            written += 1;
        }

        const style_path = try std.fmt.allocPrint(self.allocator, "{s}/static/admin/css/admin-ui.css", .{self.web_root});
        defer self.allocator.free(style_path);
        if (zzig.fsio.exists(self.io, style_path)) {
            // 旧版本曾落地过自造样式；版式已改为复用参考 `admin.css`，清掉避免干扰
            std.Io.Dir.cwd().deleteFile(self.io, style_path) catch {};
        }

        // 后台静态资源：admin.css / layui / jquery / logo / 背景图 / admin.js
        // （此前一个都没下发 → 登录页无样式 + 控制台 404）
        for (ADMIN_STATIC_ASSETS) |asset| {
            const target = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.web_root, asset.relative });
            defer self.allocator.free(target);
            if (!zzig.fsio.exists(self.io, target)) {
                if (std.fs.path.dirname(target)) |parent| try zzig.fsio.makePath(self.io, parent);
                try zzig.fsio.writeFile(self.io, target, asset.source);
                written += 1;
            }
            // 预压缩：`StaticFiles` 在客户端支持时优先下发同名 `.gz`
            // （主文件已存在也要补 —— 否则升级后拿不到压缩收益；内容以磁盘为准）
            try writeGzipSibling(self.allocator, self.io, target, asset.relative);
        }

        return written;
    }

    /// 静态资源（`wwwroot`）服务：把上传目录挂到 `<upload_prefix>/downloads`。
    ///
    /// 直接使用 `zzig.web.App` 时无需调用（App 已按 `Options.wwwroot` 提供静态资源）；
    /// 需要把上传目录一起交给 App 时应调用本方法（ETag/304 与下载头由控制器负责）。
    /// **扩展名同样受白名单约束**（未列出的类型 404）。
    pub fn registerStaticRoots(self: *DsMallUi, app: *zzig.web.App) !void {
        const url_prefix = try std.fmt.allocPrint(self.allocator, "{s}/downloads", .{self.upload_prefix});
        defer self.allocator.free(url_prefix);
        try app.addStaticRootOptions(.{
            .url_prefix = url_prefix,
            .dir = self.upload_root,
            .serve_unknown_types = false,
        });
        for (self.upload_controller.allowed_extensions) |ext| {
            try app.statics.setMimeType(ext, controllers.upload.mimeFor(ext));
        }
    }
};

/// 读项目目录下的模型文件（`Model.xml`）：不存在返回 `null`（调用方用库内置模型）。
///
/// 对齐 C#：每个项目自带一份同名 `Model.xml`，库只作兜底 —— 项目要加表/加列只改自己那份。
fn readProjectModel(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    if (path.len == 0) return null;
    if (!zzig.fsio.exists(io, path)) return null;
    const text = try zzig.fsio.readFileAlloc(io, allocator, path, 4 * 1024 * 1024);
    zzig.Logger.info("[ZDsMallUI] 使用项目模型：{s}（{d} 字节）", .{ path, text.len });
    return text;
}

/// JWT 密钥持久化：库里 `Setting.jwtSecret` 有就复用，没有就生成一次并写库。
///
/// 为什么必须持久化：密钥一变，所有已签发的令牌立刻失效 —— 表现在用户侧就是
/// 「每次重启后台都要重新登录」。生成用进程级 CSPRNG（32 字节 → hex），
/// `HS256:` 前缀与 `Auth` 的解析约定一致。
fn ensureJwtSecret(allocator: std.mem.Allocator, be: *sqlite_backend_mod.SqliteBackend) ![]const u8 {
    const setting_key = "jwtSecret";

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    if (try be.setting(arena_state.allocator(), setting_key)) |existing| {
        return allocator.dupe(u8, existing);
    }

    var buffer: [32]u8 = undefined;
    const source = std.Random.IoSource{ .io = zzig.compat.currentIo() };
    source.interface().bytes(&buffer);
    const hex = std.fmt.bytesToHex(buffer, .lower);
    const secret = try std.fmt.allocPrint(allocator, "HS256:{s}", .{hex});
    errdefer allocator.free(secret);

    try be.putSetting(setting_key, secret);
    zzig.Logger.info("[ZDsMallUI] 已生成 JWT 密钥并保存到 Setting 表（重启后令牌仍然有效）", .{});
    return secret;
}

/// 构造器（对应 C# `PekStartup.ConfigureServices` 的配置面）。
pub const Builder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    web_root: []const u8 = "wwwroot",
    upload_path: []const u8 = DEFAULT_UPLOAD_PATH,
    views_root: []const u8 = "Views",
    areas_root: []const u8 = "Areas",
    admin_area: []const u8 = DEFAULT_ADMIN_AREA,
    ueditor_config_path: ?[]const u8 = null,
    max_upload_bytes: u64 = DEFAULT_MAX_UPLOAD_BYTES,
    external_backend: ?backend_mod.AdminBackend = null,
    /// JWT 密钥（`HS256:...`；空 = 进程内随机，仅开发用）
    jwt_secret: []const u8 = "",
    /// JWT 签发者
    jwt_issuer: []const u8 = "Pek.ZDsMallUI",
    /// JWT 有效期（分钟）
    jwt_expire_minutes: i64 = 120,
    /// 是否强制后台页面登录
    require_login: bool = false,
    /// 是否启用图形验证码（登录失败达 `captcha.require_for_fails` 次后才要求；默认关）
    captcha_enabled: bool = false,
    /// Cookie 是否加 `Secure`（HTTPS 部署时应为 `true`）
    cookie_secure: bool = false,
    /// 会话存储（默认内存；可选 `SqliteStore` / `FileStore` / `RedisStore`）
    external_session_store: ?auth_mod.SessionStore = null,
    /// 伪静态后缀（默认 `.html`：`/biz/home/index.html` 命中 `/biz/home/index`；空数组 = 关闭）
    pseudo_suffixes: []const []const u8 = &.{".html"},
    /// 登录防爆破参数（默认：同 IP 10 次 / 同用户 5 次失败 → 封禁 5 分钟）
    login_guard_options: login_guard_mod.Options = .{},
    /// WAF 配置目录（含 `Config/Waf.toml`；`null` = 不启用 WAF）
    waf_base_dir: ?[]const u8 = null,
    /// 数据目录（`null` = 内存后端；设置后启用 SQLite，库文件为 `{dir}/{Area}.db`）
    storage_dir: ?[]const u8 = null,
    /// 下载扩展名白名单（默认常用类型；`&.{}` = 禁止一切下载）
    download_extensions: []const []const u8 = &controllers.upload.DEFAULT_DOWNLOAD_EXTENSIONS,
    /// 在默认白名单基础上追加的扩展名
    extra_download_extensions: []const []const u8 = &.{},
    /// 应用根（对应 ASP.NET Core 的 `~`）：视图里 `~/static/x` → `{path_base}/static/x`。
    /// `null` = 域名根（展开为 `/static/x`）；部署在子目录时传 `/pek`。
    path_base: ?[]const u8 = null,
    /// 模型文件（默认 `Model.xml`，与 C# 同构）：项目目录下存在则用它，否则用库内置模型。
    model_path: []const u8 = sqlite_backend_mod.DEFAULT_MODEL_FILE,

    /// 站点物理根（默认 `wwwroot`；**业务系统按自己的配置改成任意路径**）。
    pub fn webRoot(self: Builder, root: []const u8) Builder {
        var copy = self;
        copy.web_root = root;
        return copy;
    }

    /// 上传目录名（默认 `upload`；相对 `web_root`）。
    pub fn uploadPath(self: Builder, path: []const u8) Builder {
        var copy = self;
        copy.upload_path = path;
        return copy;
    }

    /// 视图根（默认 `Views`）。
    pub fn viewsRoot(self: Builder, root: []const u8) Builder {
        var copy = self;
        copy.views_root = root;
        return copy;
    }

    /// 应用根（对应 C# 的 `~/`）：部署在子目录时传 `/pek`，视图里 `~/static/x` 会自动加前缀。
    pub fn pathBase(self: Builder, base: []const u8) Builder {
        var copy = self;
        copy.path_base = base;
        return copy;
    }

    /// 模型文件路径（默认 `Model.xml`）。项目目录里放一份同名文件即可扩展表结构（对齐 C#）。
    pub fn modelPath(self: Builder, path: []const u8) Builder {
        var copy = self;
        copy.model_path = path;
        return copy;
    }

    /// 区域根（默认 `Areas`，与 C# 目录一致）。
    pub fn areasRoot(self: Builder, root: []const u8) Builder {
        var copy = self;
        copy.areas_root = root;
        return copy;
    }

    /// 后台区域名（默认 `Admin`；本项目可改成 `Biz` 等，路由/视图随之变化）。
    ///
    /// 非法名称（空 / 非字母开头 / 含路径符号）在 [`Builder.build`] 报错。
    pub fn adminArea(self: Builder, name: []const u8) Builder {
        var copy = self;
        copy.admin_area = name;
        return copy;
    }

    /// 指定 `ueconfig.json`（默认内置；指定后解析失败即 `build` 报错）。
    pub fn ueditorConfig(self: Builder, path: []const u8) Builder {
        var copy = self;
        copy.ueditor_config_path = path;
        return copy;
    }

    /// 全局上传体积上限（默认 64 MiB，与 HTTP 层默认 `max_body` 对齐）。
    pub fn maxUploadBytes(self: Builder, bytes: u64) Builder {
        var copy = self;
        copy.max_upload_bytes = if (bytes == 0) 1 else bytes;
        return copy;
    }

    /// 后台数据源（默认内置 [`backend_mod.MemoryBackend`]，仅示例用）。
    pub fn backend(self: Builder, value: backend_mod.AdminBackend) Builder {
        var copy = self;
        copy.external_backend = value;
        return copy;
    }

    /// JWT 密钥（`算法:密钥`，如 `HS256:xxxxxxxx`）。
    ///
    /// 不填 = 进程内随机（重启后旧令牌失效，**仅适合开发**）。
    pub fn jwtSecret(self: Builder, secret: []const u8) Builder {
        var copy = self;
        copy.jwt_secret = secret;
        return copy;
    }

    /// JWT 签发者（`iss`，默认 `Pek.ZDsMallUI`；多系统共用密钥时用它区分）。
    pub fn jwtIssuer(self: Builder, issuer: []const u8) Builder {
        var copy = self;
        copy.jwt_issuer = issuer;
        return copy;
    }

    /// JWT 有效期（分钟；默认 120，对齐 NewLife `JwtBuilder`）。
    pub fn jwtExpireMinutes(self: Builder, minutes: i64) Builder {
        var copy = self;
        copy.jwt_expire_minutes = if (minutes > 0) minutes else 120;
        return copy;
    }

    /// 是否启用图形验证码（失败达阈值后登录页才要求）。
    pub fn captchaEnabled(self: Builder, enabled: bool) Builder {
        var copy = self;
        copy.captcha_enabled = enabled;
        return copy;
    }

    /// 是否强制后台页面登录（默认 `false`：只解析身份不拦截，与 C#/Rust 版现状一致）。
    pub fn requireLogin(self: Builder, required: bool) Builder {
        var copy = self;
        copy.require_login = required;
        return copy;
    }

    /// Cookie 是否加 `Secure`（面板走 HTTPS 时必须开）。
    pub fn cookieSecure(self: Builder, secure: bool) Builder {
        var copy = self;
        copy.cookie_secure = secure;
        return copy;
    }

    /// 会话存储（默认内存：重启后吊销表清空，令牌仍可凭 JWT 签名校验通过）。
    pub fn sessionStore(self: Builder, store: auth_mod.SessionStore) Builder {
        var copy = self;
        copy.external_session_store = store;
        return copy;
    }

    /// 伪静态后缀（默认 `.{ ".html" }`）。
    ///
    /// 官网/门户类站点的诉求：`/biz/home/index.html` 命中 `/biz/home/index`、
    /// 带参数的 `/news/123.html` 拿到 `id=123`（后缀不进参数值）。
    /// 传空数组即关闭（保持纯动态路由）。
    pub fn pseudoStaticSuffixes(self: Builder, suffixes: []const []const u8) Builder {
        var copy = self;
        copy.pseudo_suffixes = suffixes;
        return copy;
    }

    /// 登录防爆破参数（默认：同 IP 10 次 / 同用户 5 次失败 → 封禁 5 分钟）。
    pub fn loginGuardOptions(self: Builder, options: login_guard_mod.Options) Builder {
        var copy = self;
        copy.login_guard_options = options;
        return copy;
    }

    /// 下载扩展名白名单（**整体替换**默认清单；传 `&.{}` = 禁止一切下载）。
    pub fn downloadExtensions(self: Builder, list: []const []const u8) Builder {
        var copy = self;
        copy.download_extensions = list;
        return copy;
    }

    /// 在默认白名单基础上**追加**可下载的扩展名（其它类型需显式指定）。
    pub fn addDownloadExtensions(self: Builder, extra: []const []const u8) Builder {
        var copy = self;
        copy.extra_download_extensions = extra;
        return copy;
    }

    /// 启用 WAF（读 `{base_dir}/Config/Waf.toml`，首启自动生成模板）。
    ///
    /// 启用后 `mount` 会把 WAF 中间件注册在**最前面**，另建议在示例里挂 `ServerGuard` 做早拒。
    pub fn waf(self: Builder, base_dir: []const u8) Builder {
        var copy = self;
        copy.waf_base_dir = base_dir;
        return copy;
    }

    /// 启用 SQLite 持久化（库文件 `{dir}/{Area}.db`，首启自动建表 + 种子账号）。
    ///
    /// 驱动加载失败（没有 `sqlite3.dll`）时**自动回退内存并打 ERR 日志**，不会让服务起不来。
    pub fn storage(self: Builder, dir: []const u8) Builder {
        var copy = self;
        copy.storage_dir = dir;
        return copy;
    }

    /// 组装（失败时已分配的资源全部回滚）。
    pub fn build(self: Builder) !*DsMallUi {
        const normalized_area = try area_mod.normalize(self.allocator, self.admin_area);
        defer self.allocator.free(normalized_area);

        const upload_path = std.mem.trim(u8, self.upload_path, " \t/");
        const effective_upload = if (upload_path.len == 0) DEFAULT_UPLOAD_PATH else upload_path;

        const ui = try self.allocator.create(DsMallUi);
        errdefer self.allocator.destroy(ui);

        const web_root = try self.allocator.dupe(u8, self.web_root);
        errdefer self.allocator.free(web_root);
        const upload_root = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, self.web_root, "/\\"), effective_upload });
        errdefer self.allocator.free(upload_root);
        const upload_prefix = try std.fmt.allocPrint(self.allocator, "/{s}", .{effective_upload});
        errdefer self.allocator.free(upload_prefix);
        const views_root = try self.allocator.dupe(u8, self.views_root);
        errdefer self.allocator.free(views_root);
        const areas_root = try self.allocator.dupe(u8, self.areas_root);
        errdefer self.allocator.free(areas_root);

        // 数据源：外部 > SQLite（`storage`，默认落 `Data/{Area}.db`）> 内存
        var memory: ?*backend_mod.MemoryBackend = null;
        var sqlite_backend: ?*sqlite_backend_mod.SqliteBackend = null;
        const admin_backend: backend_mod.AdminBackend = if (self.external_backend) |external| external else blk: {
            if (self.storage_dir) |dir| {
                const db_path = try std.fs.path.join(self.allocator, &.{ dir, try std.fmt.allocPrint(self.allocator, "{s}.db", .{normalized_area}) });
                defer self.allocator.free(db_path);
                // 模型：项目目录下的 `Model.xml` 优先（对齐 C#），没有则用库内置
                const model_xml = readProjectModel(self.allocator, self.io, self.model_path) catch |e| blk_model: {
                    zzig.Logger.warn("[ZDsMallUI] 读取项目 Model.xml 失败（{s}），改用内置模型", .{@errorName(e)});
                    break :blk_model null;
                };
                defer if (model_xml) |text| self.allocator.free(text);
                if (sqlite_backend_mod.SqliteBackend.initWithModel(self.allocator, self.io, db_path, model_xml)) |created| {
                    sqlite_backend = created;
                    break :blk created.backend();
                } else |e| {
                    zzig.Logger.err(
                        "[ZDsMallUI] SQLite 后端启动失败（{s}，库 {s}）——回退到内存，重启会丢数据",
                        .{ @errorName(e), db_path },
                    );
                }
            }
            const created = try backend_mod.MemoryBackend.init(self.allocator, self.io);
            memory = created;
            break :blk created.backend();
        };
        errdefer if (memory) |created| created.deinit();
        errdefer if (sqlite_backend) |created| created.deinit();

        var service = try ueditor_mod.UeditorService.init(self.allocator, self.io, upload_root, upload_prefix);
        errdefer service.deinit();
        service = service.withMaxBytes(self.max_upload_bytes);
        if (self.ueditor_config_path) |config_path| {
            service = try service.tryWithConfigPath(config_path);
        }

        var ui_views = views_mod.Views.init(self.allocator, self.io, views_root, areas_root);
        if (self.path_base) |base| ui_views.renderer.setPathBase(base);

        // 多语言：与业务库同一个 SQLite（`Language` + `LocaleStringResource`）；无 storage 时为内置双语
        var languages = language_mod.Store.init(self.allocator, self.io);
        if (self.storage_dir) |dir| {
            const db_path = try std.fs.path.join(self.allocator, &.{ dir, try std.fmt.allocPrint(self.allocator, "{s}.db", .{normalized_area}) });
            languages.db_path = db_path;
        }
        languages.reload() catch |e| {
            zzig.Logger.warn("[ZDsMallUI] 多语言初始化失败（{s}）：按内置文案运行", .{@errorName(e)});
        };

        // 菜单：库自带默认项，项目启动后可继续 `ui.addMenu(...)` 追加
        var menus = menu_mod.Registry.init(self.allocator, self.io);
        menus.addDefaults() catch |e| {
            zzig.Logger.warn("[ZDsMallUI] 默认菜单注册失败（{s}）：后台菜单可能为空", .{@errorName(e)});
        };

        ui.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .web_root = web_root,
            .upload_root = upload_root,
            .upload_prefix = upload_prefix,
            .views_root = views_root,
            .areas_root = areas_root,
            .max_upload_bytes = self.max_upload_bytes,
            .ui_views = ui_views,
            .service = service,
            .admin_area = undefined,
            .upload_controller = undefined,
            .pseudo_suffixes = self.pseudo_suffixes,
            .memory_backend = memory,
            .login_guard = login_guard_mod.Guard.init(self.allocator, self.login_guard_options),
            .languages = languages,
            .menus = menus,
            .waf_instance = if (self.waf_base_dir) |base|
                try pek_zwaf.Waf.load(self.allocator, self.io, base)
            else
                null,
        };
        errdefer ui.ui_views.deinit();

        ui.admin_area = try controllers.admin_area.AdminArea.init(self.allocator, self.io, admin_backend, &ui.ui_views);
        errdefer ui.admin_area.deinit();
        try ui.admin_area.setAreaName(normalized_area);
        try ui.admin_area.setUploadPrefix(upload_prefix);

        // 登录鉴权（JWT + 会话吊销）：装配即生效，登录/登出由 LoginController 使用
        //
        // 会话吊销表：外部 store 优先；没给外部 store 但开了 storage 时，
        // 自动用**同一个 SQLite 库**的 Session 表（重启后「已登出」仍然失效）。
        var session_store = self.external_session_store;
        if (session_store == null) {
            if (self.storage_dir) |dir| {
                const db_path = try std.fs.path.join(self.allocator, &.{ dir, try std.fmt.allocPrint(self.allocator, "{s}.db", .{normalized_area}) });
                defer self.allocator.free(db_path);
                if (sqlite_session_mod.SqliteSessionStore.init(self.allocator, db_path)) |created| {
                    ui.session_store = created;
                    session_store = created.store();
                } else |e| {
                    zzig.Logger.err("[ZDsMallUI] 会话吊销表打开失败（{s}），退回内存（重启后已登出的令牌可能复活）", .{@errorName(e)});
                }
            }
        }

        // JWT 密钥：**显式配置 > 库里持久化 > 首次随机生成并落库**。
        //
        // 以前没有配置时是「进程内随机」，后果是每次重启所有已登录用户全部掉线
        // （日志里那句「重启后旧令牌全部失效」）。这里首次生成后写进 `Setting` 表，
        // 之后重启复用同一密钥 —— 运维既不用配、也不会掉线。
        // 仍未启 storage（纯内存后端）时保持进程内随机：那种模式本来就不持久化任何东西。
        var jwt_secret_owned: ?[]const u8 = null;
        const jwt_secret = if (self.jwt_secret.len > 0) self.jwt_secret else blk: {
            if (sqlite_backend) |be| {
                jwt_secret_owned = ensureJwtSecret(self.allocator, be) catch |e| {
                    zzig.Logger.warn("[ZDsMallUI] 读取/生成持久化 JWT 密钥失败（{s}）：本次仍用进程内随机密钥", .{@errorName(e)});
                    break :blk "";
                };
                if (jwt_secret_owned) |secret| break :blk secret;
            }
            break :blk "";
        };

        const auth = try auth_mod.Auth.init(self.allocator, self.io, normalized_area, .{
            .secret = jwt_secret,
            .issuer = self.jwt_issuer,
            .expire_minutes = self.jwt_expire_minutes,
            .cookie_secure = self.cookie_secure,
            .require_login = self.require_login,
        }, session_store);
        ui.admin_area.setAuth(auth);

        // 登录防爆破：失败到阈值后按「IP / 用户名」双维度封禁
        ui.admin_area.setLoginGuard(&ui.login_guard);

        // 多语言 + 菜单注册表（后台页面统一从这里取文案与菜单）
        ui.admin_area.setLanguages(&ui.languages);
        ui.admin_area.setMenus(&ui.menus);

        // 图形验证码（可选）：失败 3 次后登录页要求输入，挡住「换 IP 继续撞库」
        if (self.captcha_enabled) {
            ui.captcha_store = captcha_mod.Store.init(self.allocator, .{});
            ui.admin_area.setCaptcha(&ui.captcha_store.?);
        }

        // 下载白名单 = 默认清单 + 追加清单（去重后交给上传控制器）
        const merged = try mergeExtensions(self.allocator, self.download_extensions, self.extra_download_extensions);
        defer self.allocator.free(merged);
        ui.upload_controller = try controllers.upload.UploadController.init(self.allocator, self.io, service, upload_root, merged);
        errdefer ui.upload_controller.deinit();

        return ui;
    }
};

/// 文本类资源才值得预压缩（图片/字体已压缩，再压反而变大）。
fn isCompressible(relative: []const u8) bool {
    const exts = [_][]const u8{ ".css", ".js", ".json", ".svg", ".html", ".htm", ".xml", ".txt", ".map" };
    for (exts) |ext| {
        if (relative.len > ext.len and std.ascii.endsWithIgnoreCase(relative, ext)) return true;
    }
    return false;
}

/// 为静态文件写一份同名 `.gz`（已存在则跳过）。
///
/// `zzig.web.StaticFiles` 在客户端 `Accept-Encoding: gzip` 时优先下发 `.gz` 并补 `Vary`；
/// **预压缩**（一次性）比每请求压缩省 CPU，契合「非必要不做周期性全量劳作」的口径。
fn writeGzipSibling(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    relative: []const u8,
) !void {
    if (!isCompressible(relative)) return;

    const gz_path = try std.fmt.allocPrint(allocator, "{s}.gz", .{target});
    defer allocator.free(gz_path);
    if (zzig.fsio.exists(io, gz_path)) return;

    const content = zzig.fsio.readFileAlloc(io, allocator, target, 8 * 1024 * 1024) catch return;
    defer allocator.free(content);
    if (content.len < 256) return;

    const gz = zzig.Http.gzipCompressAlloc(allocator, content, .default) catch |err| {
        zzig.Logger.warn("[ZDsMallUI] 预压缩失败（{s}）：{s}", .{ target, @errorName(err) });
        return;
    };
    defer allocator.free(gz);
    try zzig.fsio.writeFile(io, gz_path, gz);
}

/// 合并扩展名清单（大小写不敏感去重；结果容器由调用方释放，字符串借用原入参）。
fn mergeExtensions(
    allocator: std.mem.Allocator,
    base: []const []const u8,
    extra: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (base) |item| try appendUnique(allocator, &out, item);
    for (extra) |item| try appendUnique(allocator, &out, item);
    return out.toOwnedSlice(allocator);
}

fn appendUnique(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), item: []const u8) !void {
    if (item.len == 0) return;
    for (out.items) |existing| {
        if (std.ascii.eqlIgnoreCase(existing, item)) return;
    }
    try out.append(allocator, item);
}

// ————— 测试 —————

const testing = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    dir: []const u8,

    fn init(tag: []const u8) !Fixture {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const arena = arena_state.allocator();
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".", arena);
        const dir = try std.fmt.allocPrint(arena, "{s}/.zig-cache/zdsmallui-facade-{s}", .{ cwd, tag });
        std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
        try zzig.fsio.makePath(testing.io, dir);
        return .{ .arena_state = arena_state, .dir = dir };
    }

    fn deinit(self: *Fixture) void {
        const dir = self.dir;
        std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
        self.arena_state.deinit();
    }
};

test "门面：默认装配（上传前缀 / 区域 / 首页路由）" {
    const ui = try DsMallUi.builder(testing.allocator, testing.io).build();
    defer ui.deinit();

    try testing.expectEqualStrings("/upload", ui.uploadPrefix());
    try testing.expect(std.mem.endsWith(u8, ui.uploadRoot(), "upload"));
    try testing.expectEqualStrings("Admin", ui.adminArea());
    try testing.expectEqualStrings("/admin/home/index", ui.admin().homePath());
    try testing.expect(ui.ueditor().config().getStr("imageActionName") != null);
}

test "门面：区域名小写输入被 Pascal 化" {
    const ui = try DsMallUi.builder(testing.allocator, testing.io).adminArea("biz").build();
    defer ui.deinit();

    try testing.expectEqualStrings("Biz", ui.adminArea());
    const prefix = try ui.admin().routePrefix(testing.allocator);
    defer testing.allocator.free(prefix);
    try testing.expectEqualStrings("/biz", prefix);
    try testing.expectEqualStrings("/biz/home/index", ui.admin().homePath());
}

test "门面：非法区域名被拒" {
    try testing.expectError(error.InvalidCharacters, DsMallUi.builder(testing.allocator, testing.io).adminArea("a/b").build());
    try testing.expectError(error.Empty, DsMallUi.builder(testing.allocator, testing.io).adminArea("  ").build());
    try testing.expectError(error.MustStartWithLetter, DsMallUi.builder(testing.allocator, testing.io).adminArea("1admin").build());
}

test "门面：自定义路径与体积上限" {
    const ui = try DsMallUi.builder(testing.allocator, testing.io)
        .webRoot("pub")
        .uploadPath("files/")
        .viewsRoot("Templates")
        .maxUploadBytes(1024)
        .build();
    defer ui.deinit();

    try testing.expectEqualStrings("/files", ui.uploadPrefix());
    try testing.expect(std.mem.endsWith(u8, ui.uploadRoot(), "files"));
    try testing.expectEqual(@as(usize, 1024), ui.maxUploadBytes());
    try testing.expectEqualStrings("Templates", ui.views().root);
}

test "门面：缺失 ueconfig 路径是错误" {
    try testing.expectError(error.FileNotFound, DsMallUi.builder(testing.allocator, testing.io)
        .ueditorConfig("definitely-not-here.json")
        .build());
}

test "门面：视图不落盘、静态资源落地且幂等" {
    var fixture = try Fixture.init("materialize");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const web_root = try std.fmt.allocPrint(arena, "{s}/wwwroot", .{fixture.dir});
    const views_root = try std.fmt.allocPrint(arena, "{s}/Views", .{fixture.dir});
    const areas_root = try std.fmt.allocPrint(arena, "{s}/Areas", .{fixture.dir});

    const ui = try DsMallUi.builder(testing.allocator, testing.io)
        .webRoot(web_root)
        .viewsRoot(views_root)
        .areasRoot(areas_root)
        .build();
    defer ui.deinit();

    _ = try ui.materializeDefaults();
    try testing.expect(zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/ueconfig.json", .{web_root})));
    try testing.expect(zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/static/admin/js/admin-config.js", .{web_root})));
    try testing.expect(zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/static/admin/js/login-md5.js", .{web_root})));
    // 自造样式已废弃：不再落地（旧版本留下的会被清理）
    try testing.expect(!zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/static/admin/css/admin-ui.css", .{web_root})));
    // 视图**不再落地**：磁盘无副本，渲染走内置源（对齐 C# 预编译视图）
    try testing.expect(!zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/Admin/Views/Config/Index.cshtml", .{areas_root})));

    const second = try ui.materializeDefaults();
    try testing.expectEqual(@as(usize, 0), second);
}

test "门面：起服务后四个入口都可访问（端到端冒烟）" {
    var fixture = try Fixture.init("e2e");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const web_root = try std.fmt.allocPrint(arena, "{s}/wwwroot", .{fixture.dir});
    const views_root = try std.fmt.allocPrint(arena, "{s}/Views", .{fixture.dir});
    const areas_root = try std.fmt.allocPrint(arena, "{s}/Areas", .{fixture.dir});

    const ui = try DsMallUi.builder(testing.allocator, testing.io)
        .webRoot(web_root)
        .viewsRoot(views_root)
        .areasRoot(areas_root)
        .adminArea("Biz")
        .build();
    defer ui.deinit();
    _ = try ui.materializeDefaults();

    var app = try zzig.web.App.init(testing.allocator, testing.io, .{ .wwwroot = web_root });
    defer app.deinit();
    try ui.mount(&app);

    // 首页（框架页：顶部导航 + 左侧菜单 + iframe）
    const home = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/home/index" });
    try testing.expectEqual(std.http.Status.ok, home.status);
    try testing.expect(std.mem.indexOf(u8, home.body, "admincp-container") != null);
    try testing.expect(std.mem.indexOf(u8, home.body, "main-frame") != null);

    // 欢迎页（iframe 内容）：区域名与快捷入口在这里
    const dashboard = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/home/dashboard" });
    try testing.expectEqual(std.http.Status.ok, dashboard.status);
    try testing.expect(std.mem.indexOf(u8, dashboard.body, "Biz") != null);

    // 设置页
    const config = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/config/index" });
    try testing.expectEqual(std.http.Status.ok, config.status);
    try testing.expect(std.mem.indexOf(u8, config.body, "站点设置") != null);

    // 登录页
    const login = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/login/index" });
    try testing.expectEqual(std.http.Status.ok, login.status);

    // UEditor 配置
    const ue = try app.dispatch(arena, .{ .method = "GET", .path = "/fileuploader", .query = "action=config" });
    try testing.expectEqual(std.http.Status.ok, ue.status);
    try testing.expect(std.mem.indexOf(u8, ue.body, "imageActionName") != null);
}

test "门面：换区域名后旧地址 404、新地址生效（配置热加载口径）" {
    var fixture = try Fixture.init("area-switch");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const web_root = try std.fmt.allocPrint(arena, "{s}/wwwroot", .{fixture.dir});
    const views_root = try std.fmt.allocPrint(arena, "{s}/Views", .{fixture.dir});
    const areas_root = try std.fmt.allocPrint(arena, "{s}/Areas", .{fixture.dir});

    const ui = try DsMallUi.builder(testing.allocator, testing.io)
        .webRoot(web_root)
        .viewsRoot(views_root)
        .areasRoot(areas_root)
        .adminArea("Admin")
        .build();
    defer ui.deinit();
    _ = try ui.materializeDefaults();

    var app = try zzig.web.App.init(testing.allocator, testing.io, .{ .wwwroot = web_root });
    defer app.deinit();
    try ui.mount(&app);

    const before = try app.dispatch(arena, .{ .method = "GET", .path = "/admin/login/index" });
    try testing.expectEqual(std.http.Status.ok, before.status);

    // 运行期换区域名（不重建路由、不重启进程）
    try ui.admin().setAreaName("Biz");

    const old_route = try app.dispatch(arena, .{ .method = "GET", .path = "/admin/login/index" });
    try testing.expectEqual(std.http.Status.not_found, old_route.status);

    const new_route = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/login/index" });
    try testing.expectEqual(std.http.Status.ok, new_route.status);
    try testing.expectEqualStrings("/biz/home/index", ui.admin().homePath());
}

test "门面：伪静态 .html 后缀命中动态路由（官网类站点）" {
    var fixture = try Fixture.init("pseudo");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const web_root = try std.fmt.allocPrint(arena, "{s}/wwwroot", .{fixture.dir});
    const views_root = try std.fmt.allocPrint(arena, "{s}/Views", .{fixture.dir});
    const areas_root = try std.fmt.allocPrint(arena, "{s}/Areas", .{fixture.dir});

    const ui = try DsMallUi.builder(testing.allocator, testing.io)
        .webRoot(web_root)
        .viewsRoot(views_root)
        .areasRoot(areas_root)
        .adminArea("Biz")
        .build();
    defer ui.deinit();
    _ = try ui.materializeDefaults();

    var app = try zzig.web.App.init(testing.allocator, testing.io, .{ .wwwroot = web_root });
    defer app.deinit();
    try ui.mount(&app);

    // `/biz/home/index.html` → `/biz/home/index`
    const home = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/home/index.html" });
    try testing.expectEqual(std.http.Status.ok, home.status);
    try testing.expect(std.mem.indexOf(u8, home.body, "main-frame") != null);

    // 欢迎页（iframe 内容）同样可加后缀，且承载「快捷入口」
    const dashboard = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/home/dashboard.html" });
    try testing.expectEqual(std.http.Status.ok, dashboard.status);
    try testing.expect(std.mem.indexOf(u8, dashboard.body, "快捷入口") != null);

    // 登录页同样可加后缀
    const login = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/login/index.html" });
    try testing.expectEqual(std.http.Status.ok, login.status);
    try testing.expect(std.mem.indexOf(u8, login.body, "密码") != null);

    // 不存在的页面仍是 404（不会因为加后缀就"命中一切"）
    const missing = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/home/nope.html" });
    try testing.expectEqual(std.http.Status.not_found, missing.status);
}

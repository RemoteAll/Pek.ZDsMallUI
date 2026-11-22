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
    /// WAF（`null` = 未启用；由 `Builder.waf(base_dir)` 创建，`mount` 首行注册中间件）
    waf_instance: ?*pek_zwaf.Waf = null,
    /// SQLite 会话吊销表（`storage` 启用且未给外部 store 时自动创建；随本对象释放）
    session_store: ?*sqlite_session_mod.SqliteSessionStore = null,

    /// 构造门面（默认配置）。
    pub fn builder(allocator: std.mem.Allocator, io: std.Io) Builder {
        return .{ .allocator = allocator, .io = io };
    }

    /// 释放控制器、视图缓存与自有字符串。
    pub fn deinit(self: *DsMallUi) void {
        self.login_guard.deinit();
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

    /// 首次部署：把内置视图与 `ueconfig.json` 落到磁盘（**只补缺失，不覆盖**）。
    ///
    /// - 区域视图 → `{areas_root}/{Area}/Views/…`（默认 `Areas/Admin/Views/…`）；
    /// - 共享视图 → `{views_root}/Shared/…`（默认 `Views/Shared/…`）；
    /// - 配置 → `<web_root>/ueconfig.json`；
    /// - 脚本 → `<web_root>/static/admin/js/admin-config.js`（设置页客户端校验）。
    pub fn materializeDefaults(self: *DsMallUi) !usize {
        try zzig.fsio.makePath(self.io, self.web_root);
        var written = try views_mod.materializeFor(
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
                if (sqlite_backend_mod.SqliteBackend.init(self.allocator, self.io, db_path)) |created| {
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

        const ui_views = views_mod.Views.init(self.allocator, self.io, views_root, areas_root);

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

        const auth = try auth_mod.Auth.init(self.allocator, self.io, normalized_area, .{
            .secret = self.jwt_secret,
            .issuer = self.jwt_issuer,
            .expire_minutes = self.jwt_expire_minutes,
            .cookie_secure = self.cookie_secure,
            .require_login = self.require_login,
        }, session_store);
        ui.admin_area.setAuth(auth);

        // 登录防爆破：失败到阈值后按「IP / 用户名」双维度封禁
        ui.admin_area.setLoginGuard(&ui.login_guard);

        // 下载白名单 = 默认清单 + 追加清单（去重后交给上传控制器）
        const merged = try mergeExtensions(self.allocator, self.download_extensions, self.extra_download_extensions);
        defer self.allocator.free(merged);
        ui.upload_controller = try controllers.upload.UploadController.init(self.allocator, self.io, service, upload_root, merged);
        errdefer ui.upload_controller.deinit();

        return ui;
    }
};

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

test "门面：落地默认视图与配置是幂等的" {
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

    const first = try ui.materializeDefaults();
    try testing.expect(first >= views_mod.DEFAULT_VIEWS.len + 1);
    try testing.expect(zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/ueconfig.json", .{web_root})));
    try testing.expect(zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/static/admin/js/admin-config.js", .{web_root})));
    try testing.expect(zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/static/admin/js/login-md5.js", .{web_root})));
    // 自造样式已废弃：不再落地（旧版本留下的会被清理）
    try testing.expect(!zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/static/admin/css/admin-ui.css", .{web_root})));
    try testing.expect(zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/Admin/Views/Config/Index.cshtml", .{areas_root})));

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

    // 首页
    const home = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/home/index" });
    try testing.expectEqual(std.http.Status.ok, home.status);
    try testing.expect(std.mem.indexOf(u8, home.body, "Biz") != null);

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
    try testing.expect(std.mem.indexOf(u8, home.body, "快捷入口") != null);

    // 登录页同样可加后缀
    const login = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/login/index.html" });
    try testing.expectEqual(std.http.Status.ok, login.status);
    try testing.expect(std.mem.indexOf(u8, login.body, "密码") != null);

    // 不存在的页面仍是 404（不会因为加后缀就"命中一切"）
    const missing = try app.dispatch(arena, .{ .method = "GET", .path = "/biz/home/nope.html" });
    try testing.expectEqual(std.http.Status.not_found, missing.status);
}

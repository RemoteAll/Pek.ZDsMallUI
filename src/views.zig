//! 视图约定：**与 C# 同构** —— `Areas/{Area}/Views/{Controller}/{Action}.cshtml`，
//! 共享视图 `Views/Shared/{Name}.cshtml`（Razor 子集，双端可渲染）。
//!
//! `zzig.web.ViewRenderer` 原生支持这套 ASP.NET Core Areas 约定：
//! `/biz/config/index` → `Areas/Biz/Views/Config/Index.cshtml`；
//! 区域视图缺失时回退 `Areas/Admin/Views/…`，因此改区域名（如 `Biz`）不必复制默认视图；
//! 需要定制时再在 `Areas/Biz/Views/…` 放同名文件覆盖即可（对齐 NCube「子项目视图重写父项目视图」）。
//!
//! 视图引擎是 **Razor 子集**（zzig `http/view.zig`）：支持 `@expr`、`@if`、`@foreach`、
//! `@{ var x = ...; Layout = "..."; }`、`@section` + `@await RenderSectionAsync`、
//! `@Html.PartialAsync`；不支持 `@using`/`@inject`/tag helper/自由方法调用。
//! 默认视图随库内置，可用 [`materializeFor`] 落地后由项目覆盖。

const std = @import("std");
const zzig = @import("zzig");

const area = @import("area.zig");
const backend_mod = @import("backend.zig");
const version = @import("version.zig");

/// 默认区域（与 C# `Areas/Admin` 对齐）。
pub const DEFAULT_AREA = area.DEFAULT_AREA;
/// 区域根目录（C# 的 `Areas/`）。
pub const DEFAULT_AREAS_ROOT = "Areas";
/// 共享视图根（C# 的 `Views/`）。
pub const DEFAULT_VIEWS_ROOT = "Views";

/// 内置默认视图（相对**项目根**的规范路径 → 模板源码）。
pub const DefaultView = struct {
    /// 相对项目根的规范路径（`/` 分隔）
    relative: []const u8,
    /// 模板源码（编译期嵌入）
    source: []const u8,
};

/// 内置默认视图清单（与 C# 参考工程同一份，仅改为 Razor 子集语法）。
pub const DEFAULT_VIEWS = [_]DefaultView{
    .{ .relative = "Views/Shared/_Layout.cshtml", .source = @embedFile("../Views/Shared/_Layout.cshtml") },
    .{ .relative = "Views/Shared/Prompt.cshtml", .source = @embedFile("../Views/Shared/Prompt.cshtml") },
    .{ .relative = "Areas/Admin/Views/Home/Index.cshtml", .source = @embedFile("../Areas/Admin/Views/Home/Index.cshtml") },
    .{ .relative = "Areas/Admin/Views/Config/Index.cshtml", .source = @embedFile("../Areas/Admin/Views/Config/Index.cshtml") },
    .{ .relative = "Areas/Admin/Views/Login/Index.cshtml", .source = @embedFile("../Areas/Admin/Views/Login/Index.cshtml") },
};

/// 渲染结果。
pub const RenderOutcome = union(enum) {
    html: []const u8,
    fail: []const u8,
};

/// 视图渲染器（区域约定 + 模板缓存）。
pub const Views = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 共享视图根（默认 `Views`）
    root: []const u8,
    /// 区域根（默认 `Areas`）
    areas_root: []const u8,
    renderer: zzig.web.ViewRenderer,

    /// 创建渲染器（默认 `Views` + `Areas`）。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8, areas_root: []const u8) Views {
        var renderer = zzig.web.ViewRenderer.init(allocator, io);
        renderer.setRoot(root);
        renderer.setAreasRoot(areas_root);
        renderer.setFallbackArea(area.DEFAULT_AREA);
        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .areas_root = areas_root,
            .renderer = renderer,
        };
    }

    /// 释放模板缓存。
    pub fn deinit(self: *Views) void {
        self.renderer.deinit();
    }

    /// 按 Area 约定渲染：`Areas/{Area}/Views/{Controller}/{Action}.cshtml`
    /// （缺失回退 `Areas/Admin/Views/…`）。
    pub fn render(
        self: *Views,
        arena: std.mem.Allocator,
        area_name: []const u8,
        controller: []const u8,
        view: []const u8,
        model: zzig.web.Value,
    ) RenderOutcome {
        const trimmed_area = std.mem.trim(u8, area_name, " \t/");
        if (trimmed_area.len == 0) {
            return .{ .fail = "区域名不可为空（Views.render 需要 areaName）" };
        }
        const trimmed_controller = std.mem.trim(u8, controller, " /");
        const prefix = std.fmt.allocPrint(arena, "{s}/{s}", .{ trimmed_area, trimmed_controller }) catch {
            return .{ .fail = "视图控制器前缀拼接失败（内存不足）" };
        };

        // Razor 子集对「取不存在的属性」是硬错误，故渲染前先补齐内置模板用到的键
        const full_model = withTemplateDefaults(arena, model) catch {
            return .{ .fail = "视图模型构建失败（内存不足）" };
        };

        return switch (self.renderer.render(arena, prefix, view, full_model)) {
            .html => |html| .{ .html = html },
            .fail => |message| .{ .fail = std.fmt.allocPrint(arena, "渲染 {s}/{s} 失败：{s}", .{ prefix, view, message }) catch message },
        };
    }

    /// 渲染共享视图：`Views/Shared/{Name}.cshtml`（如 `Prompt`）。
    pub fn renderShared(self: *Views, arena: std.mem.Allocator, name: []const u8, model: zzig.web.Value) RenderOutcome {
        const full_model = withTemplateDefaults(arena, model) catch {
            return .{ .fail = "视图模型构建失败（内存不足）" };
        };
        return switch (self.renderer.render(arena, "Shared", name, full_model)) {
            .html => |html| .{ .html = html },
            .fail => |message| .{ .fail = std.fmt.allocPrint(arena, "渲染 Shared/{s} 失败：{s}", .{ name, message }) catch message },
        };
    }

    /// 区域视图是否存在（部署自检用；大小写按文件系统语义）。
    pub fn exists(self: *Views, area_name: []const u8, controller: []const u8, action: []const u8) bool {
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}/Views/{s}/{s}.cshtml", .{
            self.areas_root,
            std.mem.trim(u8, area_name, " /"),
            std.mem.trim(u8, controller, " /"),
            action,
        }) catch return false;
        defer self.allocator.free(path);
        return zzig.fsio.exists(self.io, path);
    }

    /// 解析实际使用的区域目录（`{Area}` → 回退 `Admin`）。
    pub fn resolveArea(self: *Views, allocator: std.mem.Allocator, area_name: []const u8, controller: []const u8, view: []const u8) ?[]const u8 {
        const requested = std.mem.trim(u8, area_name, " \t/");
        if (requested.len == 0) return null;
        if (self.exists(requested, controller, view)) return allocator.dupe(u8, requested) catch null;
        if (!area.isDefault(requested) and self.exists(area.DEFAULT_AREA, controller, view)) {
            return allocator.dupe(u8, area.DEFAULT_AREA) catch null;
        }
        return null;
    }
};

/// 模板默认键：Razor 子集对「取不存在的属性」是硬错误，
/// 故渲染前先把内置模板会引用到的键补齐（宿主只传业务字段也不会失败）。
pub fn withTemplateDefaults(arena: std.mem.Allocator, model: zzig.web.Value) !zzig.web.Value {
    var builder = zzig.web.ObjectBuilder.init(arena);

    // 1) 宿主传入的字段优先
    var provided_keys: std.ArrayList([]const u8) = .empty;
    switch (model) {
        .object => |fields| {
            for (fields) |field| {
                try builder.put(field.name, field.value);
                try provided_keys.append(arena, field.name);
            }
        },
        else => {},
    }

    // 2) 站点设置默认键（缺则补默认值）
    for (backend_mod.DEFAULT_SETTINGS) |entry| {
        if (!containsKey(provided_keys.items, entry.key)) {
            try builder.str(entry.key, entry.default);
        }
    }

    // 3) 其余模板键
    const extra = [_]struct { key: []const u8, value: zzig.web.Value }{
        .{ .key = "title", .value = .{ .string = "" } },
        .{ .key = "userName", .value = .{ .string = "" } },
        .{ .key = "saved", .value = .{ .boolean = false } },
        .{ .key = "hasLanguages", .value = .{ .boolean = false } },
        .{ .key = "languages", .value = .{ .list = &.{} } },
        .{ .key = "message", .value = .{ .string = "" } },
        .{ .key = "isOk", .value = .{ .boolean = false } },
        .{ .key = "hasBackUrl", .value = .{ .boolean = false } },
        .{ .key = "backUrl", .value = .{ .string = "" } },
        .{ .key = "autoBack", .value = .{ .boolean = false } },
        .{ .key = "hasError", .value = .{ .boolean = false } },
        .{ .key = "error", .value = .{ .string = "" } },
        .{ .key = "returnUrl", .value = .{ .string = "" } },
        .{ .key = "areaName", .value = .{ .string = area.DEFAULT_AREA } },
        .{ .key = "areaRoute", .value = .{ .string = "/admin" } },
        .{ .key = "uploadPrefix", .value = .{ .string = "/upload" } },
        .{ .key = "version", .value = .{ .string = version.VERSION } },
        .{ .key = "menus", .value = .{ .list = &.{} } },
        .{ .key = "hasMenus", .value = .{ .boolean = false } },
    };
    for (extra) |entry| {
        if (!containsKey(provided_keys.items, entry.key)) {
            try builder.put(entry.key, entry.value);
        }
    }

    return builder.finish();
}

fn containsKey(keys: []const []const u8, key: []const u8) bool {
    for (keys) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return true;
    }
    return false;
}

/// 把内置默认视图落到**指定区域**目录（只补缺失，不覆盖已有文件）。
///
/// - 共享视图 → `{views_root}/Shared/…`（不随区域变化）；
/// - 区域视图 → `{areas_root}/{Area}/Views/…`（默认区域落 `Areas/Admin/Views/…`）。
pub fn materializeFor(
    allocator: std.mem.Allocator,
    io: std.Io,
    views_root: []const u8,
    areas_root: []const u8,
    area_name: []const u8,
) !usize {
    const normalized = try area.normalize(allocator, area_name);
    defer allocator.free(normalized);

    var written: usize = 0;
    for (DEFAULT_VIEWS) |entry| {
        const target_relative = if (std.mem.startsWith(u8, entry.relative, "Areas/Admin/Views/"))
            try std.fmt.allocPrint(allocator, "{s}/{s}/Views/{s}", .{
                areas_root,
                normalized,
                entry.relative["Areas/Admin/Views/".len..],
            })
        else if (std.mem.startsWith(u8, entry.relative, "Views/"))
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ views_root, entry.relative["Views/".len..] })
        else
            entry.relative;
        defer if (target_relative.ptr != entry.relative.ptr) allocator.free(target_relative);

        if (zzig.fsio.exists(io, target_relative)) continue;
        if (std.fs.path.dirname(target_relative)) |parent| try zzig.fsio.makePath(io, parent);
        try zzig.fsio.writeFile(io, target_relative, entry.source);
        written += 1;
    }
    return written;
}

/// 落地到**默认目录**（`Views` + `Areas`）的默认区域（`Admin`）。
pub fn materialize(allocator: std.mem.Allocator, io: std.Io) !usize {
    return materializeFor(allocator, io, DEFAULT_VIEWS_ROOT, DEFAULT_AREAS_ROOT, area.DEFAULT_AREA);
}

// ————— 测试 —————

const testing = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    /// 测试工作目录下的绝对根
    base: []const u8,

    fn init(tag: []const u8) !Fixture {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const arena = arena_state.allocator();
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".", arena);
        const base = try std.fmt.allocPrint(arena, "{s}/.zig-cache/zdsmallui-views-{s}", .{ cwd, tag });
        std.Io.Dir.cwd().deleteTree(testing.io, base) catch {};
        try zzig.fsio.makePath(testing.io, base);
        return .{ .arena_state = arena_state, .base = base };
    }

    fn deinit(self: *Fixture) void {
        const base = self.base;
        std.Io.Dir.cwd().deleteTree(testing.io, base) catch {};
        self.arena_state.deinit();
    }

    fn viewsRoot(self: *Fixture, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{s}/Views", .{self.base}) catch self.base;
    }

    fn areasRoot(self: *Fixture, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{s}/Areas", .{self.base}) catch self.base;
    }
};

test "视图：落地默认视图是幂等的（Areas + Views）" {
    var fixture = try Fixture.init("materialize");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const views_root = fixture.viewsRoot(arena);
    const areas_root = fixture.areasRoot(arena);

    const first = try materializeFor(arena, testing.io, views_root, areas_root, "Admin");
    try testing.expectEqual(DEFAULT_VIEWS.len, first);

    const second = try materializeFor(arena, testing.io, views_root, areas_root, "Admin");
    try testing.expectEqual(@as(usize, 0), second);

    try testing.expect(zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/Admin/Views/Config/Index.cshtml", .{areas_root})));
    try testing.expect(zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/Shared/_Layout.cshtml", .{views_root})));
}

test "视图：非默认区域落地到该区域目录" {
    var fixture = try Fixture.init("area");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const views_root = fixture.viewsRoot(arena);
    const areas_root = fixture.areasRoot(arena);

    const written = try materializeFor(arena, testing.io, views_root, areas_root, "Biz");
    try testing.expectEqual(DEFAULT_VIEWS.len, written);
    try testing.expect(zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/Biz/Views/Config/Index.cshtml", .{areas_root})));
    try testing.expect(zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/Shared/_Layout.cshtml", .{views_root})));
    try testing.expect(!zzig.fsio.exists(testing.io, try std.fmt.allocPrint(arena, "{s}/Biz/Views/Shared/_Layout.cshtml", .{areas_root})));
}

test "视图：非默认区域回退到 Admin 模板渲染" {
    var fixture = try Fixture.init("fallback");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const views_root = fixture.viewsRoot(arena);
    const areas_root = fixture.areasRoot(arena);
    _ = try materializeFor(arena, testing.io, views_root, areas_root, "Admin");

    var views = Views.init(testing.allocator, testing.io, views_root, areas_root);
    defer views.deinit();

    var model_builder = zzig.web.ObjectBuilder.init(arena);
    try model_builder.str("siteName", "示例站点");
    const outcome = views.render(arena, "Biz", "Config", "Index", model_builder.finish());
    try testing.expect(outcome == .html);
    try testing.expect(std.mem.indexOf(u8, outcome.html, "示例站点") != null);
    try testing.expect(std.mem.indexOf(u8, outcome.html, "</html>") != null);
}

test "视图：区域专属模板覆盖 Admin" {
    var fixture = try Fixture.init("override");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const views_root = fixture.viewsRoot(arena);
    const areas_root = fixture.areasRoot(arena);
    _ = try materializeFor(arena, testing.io, views_root, areas_root, "Admin");

    try zzig.fsio.makePath(testing.io, try std.fmt.allocPrint(arena, "{s}/Biz/Views/Config", .{areas_root}));
    try zzig.fsio.writeFile(testing.io, try std.fmt.allocPrint(arena, "{s}/Biz/Views/Config/Index.cshtml", .{areas_root}), "<p>BIZ-OVERRIDE</p>");

    var views = Views.init(testing.allocator, testing.io, views_root, areas_root);
    defer views.deinit();
    const outcome = views.render(arena, "Biz", "Config", "Index", .null);
    try testing.expect(outcome == .html);
    try testing.expect(std.mem.indexOf(u8, outcome.html, "BIZ-OVERRIDE") != null);
}

test "视图：首页模型（菜单循环 + 条件）" {
    var fixture = try Fixture.init("home");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const views_root = fixture.viewsRoot(arena);
    const areas_root = fixture.areasRoot(arena);
    _ = try materializeFor(arena, testing.io, views_root, areas_root, "Admin");

    var views = Views.init(testing.allocator, testing.io, views_root, areas_root);
    defer views.deinit();

    var menu = zzig.web.ObjectBuilder.init(arena);
    try menu.str("name", "站点设置");
    try menu.str("url", "/biz/config/index");
    try menu.str("desc", "站点信息");

    var builder = zzig.web.ObjectBuilder.init(arena);
    try builder.str("areaName", "Biz");
    try builder.str("areaRoute", "/biz");
    try builder.list("menus", &.{menu.finish()});
    try builder.boolean("hasMenus", true);

    const outcome = views.render(arena, "Admin", "Home", "Index", builder.finish());
    try testing.expect(outcome == .html);
    try testing.expect(std.mem.indexOf(u8, outcome.html, "Biz") != null);
    try testing.expect(std.mem.indexOf(u8, outcome.html, "站点设置") != null);
}

test "视图：共享提示页" {
    var fixture = try Fixture.init("prompt");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const views_root = fixture.viewsRoot(arena);
    const areas_root = fixture.areasRoot(arena);
    _ = try materializeFor(arena, testing.io, views_root, areas_root, "Admin");

    var views = Views.init(testing.allocator, testing.io, views_root, areas_root);
    defer views.deinit();

    var builder = zzig.web.ObjectBuilder.init(arena);
    try builder.str("message", "保存成功");
    try builder.boolean("isOk", true);
    try builder.str("backUrl", "/biz/config/index");

    const outcome = views.renderShared(arena, "Prompt", builder.finish());
    try testing.expect(outcome == .html);
    try testing.expect(std.mem.indexOf(u8, outcome.html, "保存成功") != null);
    try testing.expect(std.mem.indexOf(u8, outcome.html, "/biz/config/index") != null);
}

test "视图：缺失视图时错误信息带路径" {
    var fixture = try Fixture.init("missing");
    defer fixture.deinit();
    const arena = fixture.arena_state.allocator();

    const views_root = fixture.viewsRoot(arena);
    const areas_root = fixture.areasRoot(arena);
    _ = try materializeFor(arena, testing.io, views_root, areas_root, "Admin");

    var views = Views.init(testing.allocator, testing.io, views_root, areas_root);
    defer views.deinit();

    const outcome = views.render(arena, "Biz", "Nope", "Index", .null);
    try testing.expect(outcome == .fail);
    try testing.expect(std.mem.indexOf(u8, outcome.fail, "Biz/Nope") != null);
}

test "视图：模板默认键补齐（宿主只传业务字段）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = zzig.web.ObjectBuilder.init(arena);
    try builder.str("siteName", "商城");
    const model = try withTemplateDefaults(arena, builder.finish());

    for (backend_mod.DEFAULT_SETTINGS) |entry| try testing.expect(model.get(entry.key) != null);
    for ([_][]const u8{ "title", "userName", "saved", "languages", "message", "isOk", "backUrl", "autoBack", "hasError", "returnUrl", "areaName", "areaRoute", "uploadPrefix", "version", "menus", "hasMenus" }) |key| {
        try testing.expect(model.get(key) != null);
    }
    try testing.expectEqualStrings("商城", model.get("siteName").?.asString().?);
    try testing.expectEqualStrings("管理后台", model.get("displayName").?.asString().?);
}

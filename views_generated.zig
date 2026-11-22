//! **自动生成，请勿手改** —— `zig build` 时由 `build.zig` 扫描
//! `Views/**` 与 `Areas/**/Views/**` 下的 `.zshtml` 生成；新增视图不用改任何清单。

pub const Entry = struct {
    /// 相对库根的规范路径（`/` 分隔）
    relative: []const u8,
    /// 模板源码（编译期内嵌）
    source: []const u8,
};

pub const ENTRIES = [_]Entry{
    .{ .relative = "Areas/Admin/Views/AdminUser/Edit.zshtml", .source = @embedFile("Areas/Admin/Views/AdminUser/Edit.zshtml") },
    .{ .relative = "Areas/Admin/Views/AdminUser/Index.zshtml", .source = @embedFile("Areas/Admin/Views/AdminUser/Index.zshtml") },
    .{ .relative = "Areas/Admin/Views/Config/Index.zshtml", .source = @embedFile("Areas/Admin/Views/Config/Index.zshtml") },
    .{ .relative = "Areas/Admin/Views/Culture/AddCulture.zshtml", .source = @embedFile("Areas/Admin/Views/Culture/AddCulture.zshtml") },
    .{ .relative = "Areas/Admin/Views/Culture/EditCulture.zshtml", .source = @embedFile("Areas/Admin/Views/Culture/EditCulture.zshtml") },
    .{ .relative = "Areas/Admin/Views/Culture/Index.zshtml", .source = @embedFile("Areas/Admin/Views/Culture/Index.zshtml") },
    .{ .relative = "Areas/Admin/Views/Home/Dashboard.zshtml", .source = @embedFile("Areas/Admin/Views/Home/Dashboard.zshtml") },
    .{ .relative = "Areas/Admin/Views/Home/Index.zshtml", .source = @embedFile("Areas/Admin/Views/Home/Index.zshtml") },
    .{ .relative = "Areas/Admin/Views/Home/ModifyPw.zshtml", .source = @embedFile("Areas/Admin/Views/Home/ModifyPw.zshtml") },
    .{ .relative = "Areas/Admin/Views/Languages/AddLanguages.zshtml", .source = @embedFile("Areas/Admin/Views/Languages/AddLanguages.zshtml") },
    .{ .relative = "Areas/Admin/Views/Languages/EditLanguages.zshtml", .source = @embedFile("Areas/Admin/Views/Languages/EditLanguages.zshtml") },
    .{ .relative = "Areas/Admin/Views/Languages/Index.zshtml", .source = @embedFile("Areas/Admin/Views/Languages/Index.zshtml") },
    .{ .relative = "Areas/Admin/Views/Login/Index.zshtml", .source = @embedFile("Areas/Admin/Views/Login/Index.zshtml") },
    .{ .relative = "Areas/Admin/Views/Menu/Edit.zshtml", .source = @embedFile("Areas/Admin/Views/Menu/Edit.zshtml") },
    .{ .relative = "Areas/Admin/Views/Menu/Index.zshtml", .source = @embedFile("Areas/Admin/Views/Menu/Index.zshtml") },
    .{ .relative = "Areas/Admin/Views/Role/Edit.zshtml", .source = @embedFile("Areas/Admin/Views/Role/Edit.zshtml") },
    .{ .relative = "Areas/Admin/Views/Role/Index.zshtml", .source = @embedFile("Areas/Admin/Views/Role/Index.zshtml") },
    .{ .relative = "Views/Shared/Prompt.zshtml", .source = @embedFile("Views/Shared/Prompt.zshtml") },
    .{ .relative = "Views/Shared/_Layout.zshtml", .source = @embedFile("Views/Shared/_Layout.zshtml") },
};

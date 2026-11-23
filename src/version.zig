//! 版本号（`build.zig.zon` 与本文件同步维护；避免 root ↔ views 循环引用）。

const std = @import("std");

pub const VERSION = "0.1.0";

/// 编译本程序的 Zig 版本（编译期常量）。
///
/// 取 `builtin.zig_version`（`std.SemanticVersion`）拼成字符串：
/// dev 版带预发布标记（如 `0.17.1`），正式版只有 `major.minor.patch`。
/// 前台/后台底部展示它，既是「构建信息」也顺带推荐 ziglang。
pub const ZIG_VERSION = zig_version_string;

const zig_version_string = blk: {
    const v = @import("builtin").zig_version;
    if (v.pre) |pre| {
        break :blk std.fmt.comptimePrint("{d}.{d}.{d}-{s}", .{ v.major, v.minor, v.patch, pre });
    }
    break :blk std.fmt.comptimePrint("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
};

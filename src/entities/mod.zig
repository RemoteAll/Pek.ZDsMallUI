//! 由 zcodegen 生成：实体索引，请勿手改。
//!
//! 约定：`{Name}.zig` 是生成的数据契约（会覆盖）；`{Name}.biz.zig` 是业务扩展（不覆盖）。

pub const Config = @import("Config.zig").Config;
pub const UserDetail = @import("UserDetail.zig").UserDetail;
pub const Session = @import("Session.zig").Session;

/// 业务扩展模块（`{Name}.biz.zig`，手写代码放这里）
pub const ConfigBiz = @import("Config.biz.zig");
pub const UserDetailBiz = @import("UserDetail.biz.zig");
pub const SessionBiz = @import("Session.biz.zig");

/// 全部实体（用 `inline for (all) |T|` 编译期逐个处理）
pub const all = .{Config, UserDetail, Session};

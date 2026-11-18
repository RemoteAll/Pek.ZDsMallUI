//! 通用模型（对应 C# `Pek.DsMallUI/Models/Hierarchy.cs`）。
//!
//! 目前只有 [`Hierarchy`]（折叠实体）：C# 参考工程里用于把「分类 / 区域」等树形数据
//! 拍平成带层级的列表交给前端渲染。字段名保持 C# 原名（`gc_id` / `gc_name` / `ParentCode` …），
//! 便于与既有前端 JS 直接对接。
//!
//! 树节点抽象：任何类型只要实现 `treeId()` / `treeParentId()` / `treeName()` 三个方法，
//! 就能交给 [`flatten`]（Zig 没有 trait，用编译期鸭子类型）。

const std = @import("std");
const zzig = @import("zzig");

/// 折叠实体（C# `Pek.DsMallUI.Models.Hierarchy`）。
pub const Hierarchy = struct {
    /// 当前层级 / 深度
    deep: i32 = 0,
    /// 编号
    gc_id: i64 = 0,
    /// 名称（`null` = 未命名）
    gc_name: ?[]const u8 = null,
    /// 父编号
    gc_parent_id: i64 = 0,
    /// 类型（JSON 键 `type`）
    kind: i32 = 0,
    /// 父区域编号（JSON 键 `ParentCode`）
    parent_code: i64 = 0,
    /// 区域编号（JSON 键 `AreaCode`）
    area_code: i64 = 0,
    /// 排序（JSON 键 `Sort`）
    sort: i64 = 0,
    /// 是否显示
    gc_show: i32 = 0,
    /// 排序
    gc_sort: i32 = 0,
    /// 是否有子节点（0/1）
    have_child: i32 = 0,
    /// 添加人（JSON 键 `CreateUser`）
    create_user: []const u8 = "",
    /// 添加时间（JSON 键 `CreateTime`）
    create_time: ?[]const u8 = null,
    /// 是否系统（JSON 键 `IsSystem`）
    is_system: bool = false,

    /// 主键（供 [`flatten`] 使用）。
    pub fn treeId(self: Hierarchy) i64 {
        return self.gc_id;
    }

    /// 父键（根为 0 或负数）。
    pub fn treeParentId(self: Hierarchy) i64 {
        return self.gc_parent_id;
    }

    /// 显示名。
    pub fn treeName(self: Hierarchy) []const u8 {
        return self.gc_name orelse "";
    }

    /// 序列化为视图/接口通用值（键名保持 C# 原名）。
    pub fn toValue(self: Hierarchy, arena: std.mem.Allocator) !zzig.web.Value {
        var builder = zzig.web.ObjectBuilder.init(arena);
        try builder.int("deep", self.deep);
        try builder.int("gc_id", self.gc_id);
        try builder.put("gc_name", if (self.gc_name) |name| .{ .string = name } else .null);
        try builder.int("gc_parent_id", self.gc_parent_id);
        try builder.int("type", self.kind);
        try builder.int("ParentCode", self.parent_code);
        try builder.int("AreaCode", self.area_code);
        try builder.int("Sort", self.sort);
        try builder.int("gc_show", self.gc_show);
        try builder.int("gc_sort", self.gc_sort);
        try builder.int("have_child", self.have_child);
        try builder.put("CreateUser", .{ .string = self.create_user });
        try builder.put("CreateTime", if (self.create_time) |text| .{ .string = text } else .null);
        try builder.boolean("IsSystem", self.is_system);
        return builder.finish();
    }
};

/// 把任意树节点拍平成 [`Hierarchy`] 列表（深度优先，`deep` 从 0 开始）。
///
/// 与 C# 侧 `HaveChild` / `Deep` 的填法一致：父在前、子在紧随其后，
/// 列表顺序即前端展示顺序；孤立节点（父不存在）按根处理，避免数据脏导致丢节点。
/// 递归带 10 万节点守卫（与 Rust 侧一致），防止坏数据造成无限递归。
pub fn flatten(allocator: std.mem.Allocator, items: anytype) ![]Hierarchy {
    const T = std.meta.Elem(@TypeOf(items));
    comptime {
        // 编译期鸭子类型校验：缺方法直接编译失败并给出明确信息
        if (!@hasDecl(T, "treeId") or !@hasDecl(T, "treeParentId") or !@hasDecl(T, "treeName")) {
            @compileError("flatten 的元素类型必须实现 treeId()/treeParentId()/treeName()");
        }
    }

    const count = items.len;
    if (count == 0) return &.{};

    var out: std.ArrayList(Hierarchy) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, count);

    var guard: usize = 0;
    for (items) |item| {
        const id = item.treeId();
        const parent = item.treeParentId();
        const is_root = parent == id or !containsId(items, parent);
        if (!is_root) continue;
        try walk(allocator, items, item, 0, &out, &guard);
    }
    return out.toOwnedSlice(allocator);
}

fn containsId(items: anytype, id: i64) bool {
    for (items) |item| {
        if (item.treeId() == id) return true;
    }
    return false;
}

fn walk(
    allocator: std.mem.Allocator,
    items: anytype,
    node: anytype,
    deep: i32,
    out: *std.ArrayList(Hierarchy),
    guard: *usize,
) !void {
    if (guard.* > 100_000) return;
    guard.* += 1;

    const node_id = node.treeId();
    var has_child = false;
    for (items) |candidate| {
        if (candidate.treeId() != node_id and candidate.treeParentId() == node_id) {
            has_child = true;
            break;
        }
    }

    try out.append(allocator, .{
        .deep = deep,
        .gc_id = node_id,
        .gc_name = node.treeName(),
        .gc_parent_id = node.treeParentId(),
        .have_child = if (has_child) 1 else 0,
    });

    for (items) |candidate| {
        if (candidate.treeId() != node_id and candidate.treeParentId() == node_id) {
            try walk(allocator, items, candidate, deep + 1, out, guard);
        }
    }
}

// ————— 测试 —————

const testing = std.testing;

test "Hierarchy：序列化保留 C# 键名" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const node = Hierarchy{ .gc_id = 1, .gc_name = "根" };
    const value = try node.toValue(arena);

    try testing.expectEqual(@as(i64, 1), value.get("gc_id").?.asInt().?);
    try testing.expectEqualStrings("根", value.get("gc_name").?.asString().?);
    try testing.expect(value.get("type") != null);
    try testing.expect(value.get("ParentCode") != null);
    try testing.expect(value.get("IsSystem") != null);
    try testing.expect(value.get("CreateTime") != null);
}

const Node = struct {
    id: i64,
    parent: i64,
    name: []const u8,

    pub fn treeId(self: Node) i64 {
        return self.id;
    }
    pub fn treeParentId(self: Node) i64 {
        return self.parent;
    }
    pub fn treeName(self: Node) []const u8 {
        return self.name;
    }
};

test "flatten：父在前、子紧随、深度正确" {
    const items = [_]Node{
        .{ .id = 2, .parent = 1, .name = "子" },
        .{ .id = 1, .parent = 0, .name = "根" },
        .{ .id = 3, .parent = 1, .name = "子二" },
    };
    const flat = try flatten(testing.allocator, &items);
    defer testing.allocator.free(flat);

    try testing.expectEqual(@as(usize, 3), flat.len);
    try testing.expectEqual(@as(i64, 1), flat[0].gc_id);
    try testing.expectEqual(@as(i32, 0), flat[0].deep);
    try testing.expectEqual(@as(i32, 1), flat[0].have_child);
    try testing.expectEqual(@as(i64, 2), flat[1].gc_id);
    try testing.expectEqual(@as(i32, 1), flat[1].deep);
    try testing.expectEqual(@as(i64, 3), flat[2].gc_id);
}

test "flatten：孤立节点按根处理" {
    const items = [_]Node{
        .{ .id = 9, .parent = 404, .name = "孤立" },
    };
    const flat = try flatten(testing.allocator, &items);
    defer testing.allocator.free(flat);
    try testing.expectEqual(@as(usize, 1), flat.len);
    try testing.expectEqual(@as(i32, 0), flat[0].deep);
}

test "flatten：空列表返回空切片" {
    const items = [_]Node{};
    const flat = try flatten(testing.allocator, &items);
    defer testing.allocator.free(flat);
    try testing.expectEqual(@as(usize, 0), flat.len);
}

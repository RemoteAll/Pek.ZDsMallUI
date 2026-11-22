//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 站点配置（键值，对齐 C# Config 表）
const zcode = @import("zcode");

pub const Config = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号
    @"Id": i32 = 0,
    /// 分类（可空）
    @"Category": []const u8 = "",
    /// 配置名（= 实体属性名，如 SiteName）
    @"Name": []const u8 = "",
    /// 配置值
    @"Value": []const u8 = "",
    /// 备注（可空）
    @"Remark": []const u8 = "",

    pub const meta = zcode.entity.checkMeta(zcode.entity.EntityMeta{
        .name = "Config",
        .table_name = "Config",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .identity = true, .description = "编号" },
            .{ .name = "Category", .data_type = .string, .nullable = true, .length = 50, .description = "分类（可空）" },
            .{ .name = "Name", .data_type = .string, .nullable = true, .length = 100, .description = "配置名（= 实体属性名，如 SiteName）" },
            .{ .name = "Value", .data_type = .string, .nullable = true, .length = 4000, .description = "配置值" },
            .{ .name = "Remark", .data_type = .string, .nullable = true, .length = 200, .description = "备注（可空）" },
        },
    });

    /// 列名常量（写 SQL / `Where` / `Field` 时引用这里）
    pub const Field = struct {
        pub const @"Id" = "Id";
        pub const @"Category" = "Category";
        pub const @"Name" = "Name";
        pub const @"Value" = "Value";
        pub const @"Remark" = "Remark";
    };

    /// 主键列下标（按模型声明顺序）
    pub const main_keys: []const usize = &.{0};
    /// 自增列下标（Id）
    pub const identity_index: usize = 0;

    /// 索引（对应 `Model.xml` 的 `Index`）
    pub const indexes = [_]zcode.codegen.IndexInfo{
        .{ .columns = &.{"Name"}, .unique = true },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("Config");
    }

    /// 模型 `MaxCacheCount`（0 = 不参与整表缓存）
    pub const max_cache_count: i32 = 1000;

    /// 插入一行（自增 ID 回写到自身）。
    pub fn insert(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !i64 {
        return zcode.entity.insert(dal, self, s);
    }

    /// 只更新脏列（无脏列不发 SQL）。
    pub fn update(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !usize {
        return zcode.entity.update(dal, self, s);
    }

    /// 按主键删除。
    pub fn delete(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !usize {
        return zcode.entity.delete(dal, self, s);
    }

    /// 保存：主键空则插入，否则更新（对齐 XCode `Save`）。
    pub fn save(self: *@This(), dal: *zcode.Dal, s: *zcode.Session) !i64 {
        return zcode.entity.save(dal, self, s);
    }

    /// 按主键值取一行（支持复合主键：按 `meta.fields` 中主键顺序传值）。
    pub fn findByKey(dal: *zcode.Dal, s: *zcode.Session, pk_values: []const zcode.Value) !?@This() {
        return zcode.entity.findByPk(dal, @This(), s, pk_values);
    }

    /// 按主键取一行（单主键便利版）。
    pub fn findByPk(dal: *zcode.Dal, s: *zcode.Session, pk: i64) !?@This() {
        return zcode.entity.findByPk(dal, @This(), s, &.{.{ .int = pk }});
    }

    /// 条件查询（分页/排序/列选择同 `Query`）。
    pub fn query(dal: *zcode.Dal, s: *zcode.Session, q: *const zcode.Query) ![]@This() {
        return zcode.entity.queryRows(dal, @This(), s, q);
    }

    /// 计数。
    pub fn count(dal: *zcode.Dal, s: *zcode.Session, filter: ?*const zcode.Where) !i64 {
        return zcode.entity.count(dal, @This(), s, filter);
    }

    /// 整表缓存：小表常驻，配词查询不再打库；行数超过 `max_cache_count` 时自动退回查库。
    pub fn cache(dal: *zcode.Dal) zcode.cache.Cache(@This()) {
        return zcode.cache.Cache(@This()).init(dal, zcode.setting.current().entity_cache_expire);
    }

    /// 单对象缓存：大表按主键取，只缓存访问过的行。
    pub fn singleCache(dal: *zcode.Dal) zcode.cache.SingleCache(@This()) {
        return zcode.cache.SingleCache(@This()).init(dal, zcode.setting.current().single_cache_expire);
    }

    /// 必填校验：返回第一个为空的非空字符列名，全通过返回 null。
    pub fn valid(self: *const @This()) ?[]const u8 {
        return zcode.entity_ext.checkRequired(self);
    }

    pub fn getId(self: @This()) i32 { return self.@"Id"; }
    pub fn setId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Id", v)) return;
        self.@"Id" = v;
        zcode.entity.markDirty(&self.dirty, 0);
    }
    pub fn getCategory(self: @This()) []const u8 { return self.@"Category"; }
    pub fn setCategory(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Category", v)) return;
        self.@"Category" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getName(self: @This()) []const u8 { return self.@"Name"; }
    pub fn setName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Name", v)) return;
        self.@"Name" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getValue(self: @This()) []const u8 { return self.@"Value"; }
    pub fn setValue(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Value", v)) return;
        self.@"Value" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getRemark(self: @This()) []const u8 { return self.@"Remark"; }
    pub fn setRemark(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Remark", v)) return;
        self.@"Remark" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = @intCast(self.@"Id") },
            1 => .{ .text = self.@"Category" },
            2 => .{ .text = self.@"Name" },
            3 => .{ .text = self.@"Value" },
            4 => .{ .text = self.@"Remark" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"Id" = v.asI32() orelse 0; },
            1 => { switch (v) { .text => |t| self.@"Category" = t, .null => self.@"Category" = "", else => {} } },
            2 => { switch (v) { .text => |t| self.@"Name" = t, .null => self.@"Name" = "", else => {} } },
            3 => { switch (v) { .text => |t| self.@"Value" = t, .null => self.@"Value" = "", else => {} } },
            4 => { switch (v) { .text => |t| self.@"Remark" = t, .null => self.@"Remark" = "", else => {} } },
            else => {},
        }
    }
};

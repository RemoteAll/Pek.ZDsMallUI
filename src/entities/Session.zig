//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 会话吊销表（登出后令牌立即失效，重启仍有效）
const zcode = @import("zcode");

pub const Session = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 键（含令牌/用户维度前缀）
    @"Key": []const u8 = "",
    /// 值（会话/版本信息）
    @"Value": []const u8 = "",
    /// 过期 Unix 秒（0 = 不过期）
    @"ExpireAt": i64 = 0,

    pub const meta = zcode.entity.checkMeta(zcode.entity.EntityMeta{
        .name = "Session",
        .table_name = "Session",
        .fields = &.{
            .{ .name = "Key", .data_type = .string, .primary_key = true, .length = 200, .description = "键（含令牌/用户维度前缀）" },
            .{ .name = "Value", .data_type = .string, .nullable = true, .length = 400, .description = "值（会话/版本信息）" },
            .{ .name = "ExpireAt", .data_type = .int64, .description = "过期 Unix 秒（0 = 不过期）" },
        },
    });

    /// 列名常量（写 SQL / `Where` / `Field` 时引用这里）
    pub const Field = struct {
        pub const @"Key" = "Key";
        pub const @"Value" = "Value";
        pub const @"ExpireAt" = "ExpireAt";
    };

    /// 主键列下标（按模型声明顺序）
    pub const main_keys: []const usize = &.{0};

    /// 索引（对应 `Model.xml` 的 `Index`）
    pub const indexes = [_]zcode.codegen.IndexInfo{
        .{ .columns = &.{"ExpireAt"}, .unique = false },
    };

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("Session");
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

    pub fn getKey(self: @This()) []const u8 { return self.@"Key"; }
    pub fn setKey(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Key", v)) return;
        self.@"Key" = v;
        zcode.entity.markDirty(&self.dirty, 0);
    }
    pub fn getValue(self: @This()) []const u8 { return self.@"Value"; }
    pub fn setValue(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Value", v)) return;
        self.@"Value" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getExpireAt(self: @This()) i64 { return self.@"ExpireAt"; }
    pub fn setExpireAt(self: *@This(), v: i64) void {
        if (zcode.entity.valueEql(self.@"ExpireAt", v)) return;
        self.@"ExpireAt" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .text = self.@"Key" },
            1 => .{ .text = self.@"Value" },
            2 => .{ .int = @intCast(self.@"ExpireAt") },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { switch (v) { .text => |t| self.@"Key" = t, .null => self.@"Key" = "", else => {} } },
            1 => { switch (v) { .text => |t| self.@"Value" = t, .null => self.@"Value" = "", else => {} } },
            2 => { self.@"ExpireAt" = v.asI64() orelse 0; },
            else => {},
        }
    }
};

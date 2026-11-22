//! 由 zcodegen 生成，请勿手改。
//! 重新生成：zig build codegen -Dmodel=<Model.xml> -Dout=<目录>
//! 用户扩展表（C# `UserDetail` 同构；`Id` = `User.ID` 一对一，后台界面语言在 `LanguageId`）
const zcode = @import("zcode");

pub const UserDetail = struct {
    /// 脏列位图（setter 置位；`zcode.entity.update` 只写脏列）
    dirty: zcode.entity.DirtyBits = 0,

    /// 编号（= User.ID）
    @"Id": i32 = 0,
    /// 后台界面语言（= Language.Id，0 = 跟默认）
    @"LanguageId": i32 = 0,
    /// IsSuper
    @"IsSuper": bool = false,
    /// SId
    @"SId": i64 = 0,
    /// TenantId
    @"TenantId": i32 = 0,
    /// UType
    @"UType": i16 = 0,
    /// RoleExIds
    @"RoleExIds": []const u8 = "",
    /// OtherPermissions
    @"OtherPermissions": []const u8 = "",
    /// DepartmentIds
    @"DepartmentIds": []const u8 = "",
    /// TrueName
    @"TrueName": []const u8 = "",
    /// PayPwd
    @"PayPwd": []const u8 = "",
    /// AuthState
    @"AuthState": i16 = 0,
    /// IdCard
    @"IdCard": []const u8 = "",
    /// IdcardImage1
    @"IdcardImage1": []const u8 = "",
    /// IdcardImage2
    @"IdcardImage2": []const u8 = "",
    /// IdcardImage3
    @"IdcardImage3": []const u8 = "",
    /// CompanyName
    @"CompanyName": []const u8 = "",
    /// CompnayAuthState
    @"CompnayAuthState": i16 = 0,
    /// CorporateName
    @"CorporateName": []const u8 = "",
    /// BusinessLicenseImage
    @"BusinessLicenseImage": []const u8 = "",
    /// CorporateImage
    @"CorporateImage": []const u8 = "",
    /// EmailBind
    @"EmailBind": bool = false,
    /// MobileBind
    @"MobileBind": bool = false,
    /// IsSubScribe
    @"IsSubScribe": bool = false,
    /// IsSales
    @"IsSales": bool = false,
    /// IsEngineer
    @"IsEngineer": bool = false,
    /// ReferrerId
    @"ReferrerId": i32 = 0,
    /// KeFuId
    @"KeFuId": i32 = 0,
    /// ParentUId
    @"ParentUId": i32 = 0,
    /// Points
    @"Points": i32 = 0,
    /// ExpPoints
    @"ExpPoints": i32 = 0,
    /// QQ
    @"QQ": []const u8 = "",
    /// WeiXin
    @"WeiXin": []const u8 = "",
    /// WangWang
    @"WangWang": []const u8 = "",
    /// ContactName
    @"ContactName": []const u8 = "",
    /// Tel
    @"Tel": []const u8 = "",
    /// Fax
    @"Fax": []const u8 = "",
    /// CompanyInfo
    @"CompanyInfo": []const u8 = "",
    /// Address
    @"Address": []const u8 = "",
    /// InformAllow
    @"InformAllow": bool = false,
    /// IsBuy
    @"IsBuy": bool = false,
    /// IsAllowTalk
    @"IsAllowTalk": bool = false,
    /// AvailablePredeposit
    @"AvailablePredeposit": zcode.Decimal = .{ .mantissa = 0, .scale = 0 },
    /// FreezePredeposit
    @"FreezePredeposit": zcode.Decimal = .{ .mantissa = 0, .scale = 0 },
    /// AvailableRcBalance
    @"AvailableRcBalance": zcode.Decimal = .{ .mantissa = 0, .scale = 0 },
    /// FreezeRcBalance
    @"FreezeRcBalance": zcode.Decimal = .{ .mantissa = 0, .scale = 0 },
    /// CountryCode
    @"CountryCode": []const u8 = "",
    /// CountryId
    @"CountryId": i32 = 0,
    /// AreaId
    @"AreaId": i32 = 0,
    /// CityId
    @"CityId": i32 = 0,
    /// ProvinceId
    @"ProvinceId": i32 = 0,
    /// AreaInfo
    @"AreaInfo": []const u8 = "",
    /// Question1
    @"Question1": []const u8 = "",
    /// Answer1
    @"Answer1": []const u8 = "",
    /// Question2
    @"Question2": []const u8 = "",
    /// Answer2
    @"Answer2": []const u8 = "",
    /// Question3
    @"Question3": []const u8 = "",
    /// Answer3
    @"Answer3": []const u8 = "",
    /// OnlineTime
    @"OnlineTime": i32 = 0,
    /// LastUpdateTime
    @"LastUpdateTime": i64 = 0,
    /// CreateUser
    @"CreateUser": []const u8 = "",
    /// CreateUserID
    @"CreateUserID": i32 = 0,
    /// CreateTime
    @"CreateTime": zcode.DateTime = .{},
    /// CreateIP
    @"CreateIP": []const u8 = "",
    /// UpdateUser
    @"UpdateUser": []const u8 = "",
    /// UpdateUserID
    @"UpdateUserID": i32 = 0,
    /// UpdateTime
    @"UpdateTime": zcode.DateTime = .{},
    /// UpdateIP
    @"UpdateIP": []const u8 = "",

    pub const meta = zcode.entity.checkMeta(zcode.entity.EntityMeta{
        .name = "UserDetail",
        .table_name = "UserDetail",
        .fields = &.{
            .{ .name = "Id", .data_type = .int32, .primary_key = true, .nullable = true, .description = "编号（= User.ID）" },
            .{ .name = "LanguageId", .data_type = .int32, .description = "后台界面语言（= Language.Id，0 = 跟默认）" },
            .{ .name = "IsSuper", .data_type = .boolean, .description = "IsSuper" },
            .{ .name = "SId", .data_type = .int64, .description = "SId" },
            .{ .name = "TenantId", .data_type = .int32, .description = "TenantId" },
            .{ .name = "UType", .data_type = .int16, .description = "UType" },
            .{ .name = "RoleExIds", .data_type = .string, .nullable = true, .length = 100, .description = "RoleExIds" },
            .{ .name = "OtherPermissions", .data_type = .string, .nullable = true, .length = 200, .description = "OtherPermissions" },
            .{ .name = "DepartmentIds", .data_type = .string, .nullable = true, .length = 200, .description = "DepartmentIds" },
            .{ .name = "TrueName", .data_type = .string, .nullable = true, .length = 50, .description = "TrueName" },
            .{ .name = "PayPwd", .data_type = .string, .nullable = true, .length = 50, .description = "PayPwd" },
            .{ .name = "AuthState", .data_type = .int16, .description = "AuthState" },
            .{ .name = "IdCard", .data_type = .string, .nullable = true, .length = 50, .description = "IdCard" },
            .{ .name = "IdcardImage1", .data_type = .string, .nullable = true, .length = 100, .description = "IdcardImage1" },
            .{ .name = "IdcardImage2", .data_type = .string, .nullable = true, .length = 100, .description = "IdcardImage2" },
            .{ .name = "IdcardImage3", .data_type = .string, .nullable = true, .length = 100, .description = "IdcardImage3" },
            .{ .name = "CompanyName", .data_type = .string, .nullable = true, .length = 100, .description = "CompanyName" },
            .{ .name = "CompnayAuthState", .data_type = .int16, .description = "CompnayAuthState" },
            .{ .name = "CorporateName", .data_type = .string, .nullable = true, .length = 50, .description = "CorporateName" },
            .{ .name = "BusinessLicenseImage", .data_type = .string, .nullable = true, .length = 100, .description = "BusinessLicenseImage" },
            .{ .name = "CorporateImage", .data_type = .string, .nullable = true, .length = 100, .description = "CorporateImage" },
            .{ .name = "EmailBind", .data_type = .boolean, .description = "EmailBind" },
            .{ .name = "MobileBind", .data_type = .boolean, .description = "MobileBind" },
            .{ .name = "IsSubScribe", .data_type = .boolean, .description = "IsSubScribe" },
            .{ .name = "IsSales", .data_type = .boolean, .description = "IsSales" },
            .{ .name = "IsEngineer", .data_type = .boolean, .description = "IsEngineer" },
            .{ .name = "ReferrerId", .data_type = .int32, .description = "ReferrerId" },
            .{ .name = "KeFuId", .data_type = .int32, .description = "KeFuId" },
            .{ .name = "ParentUId", .data_type = .int32, .description = "ParentUId" },
            .{ .name = "Points", .data_type = .int32, .description = "Points" },
            .{ .name = "ExpPoints", .data_type = .int32, .description = "ExpPoints" },
            .{ .name = "QQ", .data_type = .string, .nullable = true, .length = 50, .description = "QQ" },
            .{ .name = "WeiXin", .data_type = .string, .nullable = true, .length = 50, .description = "WeiXin" },
            .{ .name = "WangWang", .data_type = .string, .nullable = true, .length = 50, .description = "WangWang" },
            .{ .name = "ContactName", .data_type = .string, .nullable = true, .length = 50, .description = "ContactName" },
            .{ .name = "Tel", .data_type = .string, .nullable = true, .length = 50, .description = "Tel" },
            .{ .name = "Fax", .data_type = .string, .nullable = true, .length = 50, .description = "Fax" },
            .{ .name = "CompanyInfo", .data_type = .string, .nullable = true, .length = 1024, .description = "CompanyInfo" },
            .{ .name = "Address", .data_type = .string, .nullable = true, .length = 100, .description = "Address" },
            .{ .name = "InformAllow", .data_type = .boolean, .description = "InformAllow" },
            .{ .name = "IsBuy", .data_type = .boolean, .description = "IsBuy" },
            .{ .name = "IsAllowTalk", .data_type = .boolean, .description = "IsAllowTalk" },
            .{ .name = "AvailablePredeposit", .data_type = .decimal, .description = "AvailablePredeposit" },
            .{ .name = "FreezePredeposit", .data_type = .decimal, .description = "FreezePredeposit" },
            .{ .name = "AvailableRcBalance", .data_type = .decimal, .description = "AvailableRcBalance" },
            .{ .name = "FreezeRcBalance", .data_type = .decimal, .description = "FreezeRcBalance" },
            .{ .name = "CountryCode", .data_type = .string, .nullable = true, .length = 50, .description = "CountryCode" },
            .{ .name = "CountryId", .data_type = .int32, .description = "CountryId" },
            .{ .name = "AreaId", .data_type = .int32, .description = "AreaId" },
            .{ .name = "CityId", .data_type = .int32, .description = "CityId" },
            .{ .name = "ProvinceId", .data_type = .int32, .description = "ProvinceId" },
            .{ .name = "AreaInfo", .data_type = .string, .nullable = true, .length = 50, .description = "AreaInfo" },
            .{ .name = "Question1", .data_type = .string, .nullable = true, .length = 100, .description = "Question1" },
            .{ .name = "Answer1", .data_type = .string, .nullable = true, .length = 100, .description = "Answer1" },
            .{ .name = "Question2", .data_type = .string, .nullable = true, .length = 100, .description = "Question2" },
            .{ .name = "Answer2", .data_type = .string, .nullable = true, .length = 100, .description = "Answer2" },
            .{ .name = "Question3", .data_type = .string, .nullable = true, .length = 100, .description = "Question3" },
            .{ .name = "Answer3", .data_type = .string, .nullable = true, .length = 100, .description = "Answer3" },
            .{ .name = "OnlineTime", .data_type = .int32, .description = "OnlineTime" },
            .{ .name = "LastUpdateTime", .data_type = .int64, .description = "LastUpdateTime" },
            .{ .name = "CreateUser", .data_type = .string, .nullable = true, .length = 50, .description = "CreateUser" },
            .{ .name = "CreateUserID", .data_type = .int32, .description = "CreateUserID" },
            .{ .name = "CreateTime", .data_type = .datetime, .nullable = true, .description = "CreateTime" },
            .{ .name = "CreateIP", .data_type = .string, .nullable = true, .length = 50, .description = "CreateIP" },
            .{ .name = "UpdateUser", .data_type = .string, .nullable = true, .length = 50, .description = "UpdateUser" },
            .{ .name = "UpdateUserID", .data_type = .int32, .description = "UpdateUserID" },
            .{ .name = "UpdateTime", .data_type = .datetime, .nullable = true, .description = "UpdateTime" },
            .{ .name = "UpdateIP", .data_type = .string, .nullable = true, .length = 50, .description = "UpdateIP" },
        },
    });

    /// 列名常量（写 SQL / `Where` / `Field` 时引用这里）
    pub const Field = struct {
        pub const @"Id" = "Id";
        pub const @"LanguageId" = "LanguageId";
        pub const @"IsSuper" = "IsSuper";
        pub const @"SId" = "SId";
        pub const @"TenantId" = "TenantId";
        pub const @"UType" = "UType";
        pub const @"RoleExIds" = "RoleExIds";
        pub const @"OtherPermissions" = "OtherPermissions";
        pub const @"DepartmentIds" = "DepartmentIds";
        pub const @"TrueName" = "TrueName";
        pub const @"PayPwd" = "PayPwd";
        pub const @"AuthState" = "AuthState";
        pub const @"IdCard" = "IdCard";
        pub const @"IdcardImage1" = "IdcardImage1";
        pub const @"IdcardImage2" = "IdcardImage2";
        pub const @"IdcardImage3" = "IdcardImage3";
        pub const @"CompanyName" = "CompanyName";
        pub const @"CompnayAuthState" = "CompnayAuthState";
        pub const @"CorporateName" = "CorporateName";
        pub const @"BusinessLicenseImage" = "BusinessLicenseImage";
        pub const @"CorporateImage" = "CorporateImage";
        pub const @"EmailBind" = "EmailBind";
        pub const @"MobileBind" = "MobileBind";
        pub const @"IsSubScribe" = "IsSubScribe";
        pub const @"IsSales" = "IsSales";
        pub const @"IsEngineer" = "IsEngineer";
        pub const @"ReferrerId" = "ReferrerId";
        pub const @"KeFuId" = "KeFuId";
        pub const @"ParentUId" = "ParentUId";
        pub const @"Points" = "Points";
        pub const @"ExpPoints" = "ExpPoints";
        pub const @"QQ" = "QQ";
        pub const @"WeiXin" = "WeiXin";
        pub const @"WangWang" = "WangWang";
        pub const @"ContactName" = "ContactName";
        pub const @"Tel" = "Tel";
        pub const @"Fax" = "Fax";
        pub const @"CompanyInfo" = "CompanyInfo";
        pub const @"Address" = "Address";
        pub const @"InformAllow" = "InformAllow";
        pub const @"IsBuy" = "IsBuy";
        pub const @"IsAllowTalk" = "IsAllowTalk";
        pub const @"AvailablePredeposit" = "AvailablePredeposit";
        pub const @"FreezePredeposit" = "FreezePredeposit";
        pub const @"AvailableRcBalance" = "AvailableRcBalance";
        pub const @"FreezeRcBalance" = "FreezeRcBalance";
        pub const @"CountryCode" = "CountryCode";
        pub const @"CountryId" = "CountryId";
        pub const @"AreaId" = "AreaId";
        pub const @"CityId" = "CityId";
        pub const @"ProvinceId" = "ProvinceId";
        pub const @"AreaInfo" = "AreaInfo";
        pub const @"Question1" = "Question1";
        pub const @"Answer1" = "Answer1";
        pub const @"Question2" = "Question2";
        pub const @"Answer2" = "Answer2";
        pub const @"Question3" = "Question3";
        pub const @"Answer3" = "Answer3";
        pub const @"OnlineTime" = "OnlineTime";
        pub const @"LastUpdateTime" = "LastUpdateTime";
        pub const @"CreateUser" = "CreateUser";
        pub const @"CreateUserID" = "CreateUserID";
        pub const @"CreateTime" = "CreateTime";
        pub const @"CreateIP" = "CreateIP";
        pub const @"UpdateUser" = "UpdateUser";
        pub const @"UpdateUserID" = "UpdateUserID";
        pub const @"UpdateTime" = "UpdateTime";
        pub const @"UpdateIP" = "UpdateIP";
    };

    /// 主键列下标（按模型声明顺序）
    pub const main_keys: []const usize = &.{0};

    /// 取表句柄（表级 CRUD / 分片路由都用它）。
    pub fn table(dal: *zcode.Dal) !zcode.dbtable.TableRef {
        return dal.table("UserDetail");
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
    pub fn getLanguageId(self: @This()) i32 { return self.@"LanguageId"; }
    pub fn setLanguageId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"LanguageId", v)) return;
        self.@"LanguageId" = v;
        zcode.entity.markDirty(&self.dirty, 1);
    }
    pub fn getIsSuper(self: @This()) bool { return self.@"IsSuper"; }
    pub fn setIsSuper(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"IsSuper", v)) return;
        self.@"IsSuper" = v;
        zcode.entity.markDirty(&self.dirty, 2);
    }
    pub fn getSId(self: @This()) i64 { return self.@"SId"; }
    pub fn setSId(self: *@This(), v: i64) void {
        if (zcode.entity.valueEql(self.@"SId", v)) return;
        self.@"SId" = v;
        zcode.entity.markDirty(&self.dirty, 3);
    }
    pub fn getTenantId(self: @This()) i32 { return self.@"TenantId"; }
    pub fn setTenantId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"TenantId", v)) return;
        self.@"TenantId" = v;
        zcode.entity.markDirty(&self.dirty, 4);
    }
    pub fn getUType(self: @This()) i16 { return self.@"UType"; }
    pub fn setUType(self: *@This(), v: i16) void {
        if (zcode.entity.valueEql(self.@"UType", v)) return;
        self.@"UType" = v;
        zcode.entity.markDirty(&self.dirty, 5);
    }
    pub fn getRoleExIds(self: @This()) []const u8 { return self.@"RoleExIds"; }
    pub fn setRoleExIds(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"RoleExIds", v)) return;
        self.@"RoleExIds" = v;
        zcode.entity.markDirty(&self.dirty, 6);
    }
    pub fn getOtherPermissions(self: @This()) []const u8 { return self.@"OtherPermissions"; }
    pub fn setOtherPermissions(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"OtherPermissions", v)) return;
        self.@"OtherPermissions" = v;
        zcode.entity.markDirty(&self.dirty, 7);
    }
    pub fn getDepartmentIds(self: @This()) []const u8 { return self.@"DepartmentIds"; }
    pub fn setDepartmentIds(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"DepartmentIds", v)) return;
        self.@"DepartmentIds" = v;
        zcode.entity.markDirty(&self.dirty, 8);
    }
    pub fn getTrueName(self: @This()) []const u8 { return self.@"TrueName"; }
    pub fn setTrueName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"TrueName", v)) return;
        self.@"TrueName" = v;
        zcode.entity.markDirty(&self.dirty, 9);
    }
    pub fn getPayPwd(self: @This()) []const u8 { return self.@"PayPwd"; }
    pub fn setPayPwd(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"PayPwd", v)) return;
        self.@"PayPwd" = v;
        zcode.entity.markDirty(&self.dirty, 10);
    }
    pub fn getAuthState(self: @This()) i16 { return self.@"AuthState"; }
    pub fn setAuthState(self: *@This(), v: i16) void {
        if (zcode.entity.valueEql(self.@"AuthState", v)) return;
        self.@"AuthState" = v;
        zcode.entity.markDirty(&self.dirty, 11);
    }
    pub fn getIdCard(self: @This()) []const u8 { return self.@"IdCard"; }
    pub fn setIdCard(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"IdCard", v)) return;
        self.@"IdCard" = v;
        zcode.entity.markDirty(&self.dirty, 12);
    }
    pub fn getIdcardImage1(self: @This()) []const u8 { return self.@"IdcardImage1"; }
    pub fn setIdcardImage1(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"IdcardImage1", v)) return;
        self.@"IdcardImage1" = v;
        zcode.entity.markDirty(&self.dirty, 13);
    }
    pub fn getIdcardImage2(self: @This()) []const u8 { return self.@"IdcardImage2"; }
    pub fn setIdcardImage2(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"IdcardImage2", v)) return;
        self.@"IdcardImage2" = v;
        zcode.entity.markDirty(&self.dirty, 14);
    }
    pub fn getIdcardImage3(self: @This()) []const u8 { return self.@"IdcardImage3"; }
    pub fn setIdcardImage3(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"IdcardImage3", v)) return;
        self.@"IdcardImage3" = v;
        zcode.entity.markDirty(&self.dirty, 15);
    }
    pub fn getCompanyName(self: @This()) []const u8 { return self.@"CompanyName"; }
    pub fn setCompanyName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CompanyName", v)) return;
        self.@"CompanyName" = v;
        zcode.entity.markDirty(&self.dirty, 16);
    }
    pub fn getCompnayAuthState(self: @This()) i16 { return self.@"CompnayAuthState"; }
    pub fn setCompnayAuthState(self: *@This(), v: i16) void {
        if (zcode.entity.valueEql(self.@"CompnayAuthState", v)) return;
        self.@"CompnayAuthState" = v;
        zcode.entity.markDirty(&self.dirty, 17);
    }
    pub fn getCorporateName(self: @This()) []const u8 { return self.@"CorporateName"; }
    pub fn setCorporateName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CorporateName", v)) return;
        self.@"CorporateName" = v;
        zcode.entity.markDirty(&self.dirty, 18);
    }
    pub fn getBusinessLicenseImage(self: @This()) []const u8 { return self.@"BusinessLicenseImage"; }
    pub fn setBusinessLicenseImage(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"BusinessLicenseImage", v)) return;
        self.@"BusinessLicenseImage" = v;
        zcode.entity.markDirty(&self.dirty, 19);
    }
    pub fn getCorporateImage(self: @This()) []const u8 { return self.@"CorporateImage"; }
    pub fn setCorporateImage(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CorporateImage", v)) return;
        self.@"CorporateImage" = v;
        zcode.entity.markDirty(&self.dirty, 20);
    }
    pub fn getEmailBind(self: @This()) bool { return self.@"EmailBind"; }
    pub fn setEmailBind(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"EmailBind", v)) return;
        self.@"EmailBind" = v;
        zcode.entity.markDirty(&self.dirty, 21);
    }
    pub fn getMobileBind(self: @This()) bool { return self.@"MobileBind"; }
    pub fn setMobileBind(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"MobileBind", v)) return;
        self.@"MobileBind" = v;
        zcode.entity.markDirty(&self.dirty, 22);
    }
    pub fn getIsSubScribe(self: @This()) bool { return self.@"IsSubScribe"; }
    pub fn setIsSubScribe(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"IsSubScribe", v)) return;
        self.@"IsSubScribe" = v;
        zcode.entity.markDirty(&self.dirty, 23);
    }
    pub fn getIsSales(self: @This()) bool { return self.@"IsSales"; }
    pub fn setIsSales(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"IsSales", v)) return;
        self.@"IsSales" = v;
        zcode.entity.markDirty(&self.dirty, 24);
    }
    pub fn getIsEngineer(self: @This()) bool { return self.@"IsEngineer"; }
    pub fn setIsEngineer(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"IsEngineer", v)) return;
        self.@"IsEngineer" = v;
        zcode.entity.markDirty(&self.dirty, 25);
    }
    pub fn getReferrerId(self: @This()) i32 { return self.@"ReferrerId"; }
    pub fn setReferrerId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ReferrerId", v)) return;
        self.@"ReferrerId" = v;
        zcode.entity.markDirty(&self.dirty, 26);
    }
    pub fn getKeFuId(self: @This()) i32 { return self.@"KeFuId"; }
    pub fn setKeFuId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"KeFuId", v)) return;
        self.@"KeFuId" = v;
        zcode.entity.markDirty(&self.dirty, 27);
    }
    pub fn getParentUId(self: @This()) i32 { return self.@"ParentUId"; }
    pub fn setParentUId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ParentUId", v)) return;
        self.@"ParentUId" = v;
        zcode.entity.markDirty(&self.dirty, 28);
    }
    pub fn getPoints(self: @This()) i32 { return self.@"Points"; }
    pub fn setPoints(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"Points", v)) return;
        self.@"Points" = v;
        zcode.entity.markDirty(&self.dirty, 29);
    }
    pub fn getExpPoints(self: @This()) i32 { return self.@"ExpPoints"; }
    pub fn setExpPoints(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ExpPoints", v)) return;
        self.@"ExpPoints" = v;
        zcode.entity.markDirty(&self.dirty, 30);
    }
    pub fn getQQ(self: @This()) []const u8 { return self.@"QQ"; }
    pub fn setQQ(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"QQ", v)) return;
        self.@"QQ" = v;
        zcode.entity.markDirty(&self.dirty, 31);
    }
    pub fn getWeiXin(self: @This()) []const u8 { return self.@"WeiXin"; }
    pub fn setWeiXin(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"WeiXin", v)) return;
        self.@"WeiXin" = v;
        zcode.entity.markDirty(&self.dirty, 32);
    }
    pub fn getWangWang(self: @This()) []const u8 { return self.@"WangWang"; }
    pub fn setWangWang(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"WangWang", v)) return;
        self.@"WangWang" = v;
        zcode.entity.markDirty(&self.dirty, 33);
    }
    pub fn getContactName(self: @This()) []const u8 { return self.@"ContactName"; }
    pub fn setContactName(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"ContactName", v)) return;
        self.@"ContactName" = v;
        zcode.entity.markDirty(&self.dirty, 34);
    }
    pub fn getTel(self: @This()) []const u8 { return self.@"Tel"; }
    pub fn setTel(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Tel", v)) return;
        self.@"Tel" = v;
        zcode.entity.markDirty(&self.dirty, 35);
    }
    pub fn getFax(self: @This()) []const u8 { return self.@"Fax"; }
    pub fn setFax(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Fax", v)) return;
        self.@"Fax" = v;
        zcode.entity.markDirty(&self.dirty, 36);
    }
    pub fn getCompanyInfo(self: @This()) []const u8 { return self.@"CompanyInfo"; }
    pub fn setCompanyInfo(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CompanyInfo", v)) return;
        self.@"CompanyInfo" = v;
        zcode.entity.markDirty(&self.dirty, 37);
    }
    pub fn getAddress(self: @This()) []const u8 { return self.@"Address"; }
    pub fn setAddress(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Address", v)) return;
        self.@"Address" = v;
        zcode.entity.markDirty(&self.dirty, 38);
    }
    pub fn getInformAllow(self: @This()) bool { return self.@"InformAllow"; }
    pub fn setInformAllow(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"InformAllow", v)) return;
        self.@"InformAllow" = v;
        zcode.entity.markDirty(&self.dirty, 39);
    }
    pub fn getIsBuy(self: @This()) bool { return self.@"IsBuy"; }
    pub fn setIsBuy(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"IsBuy", v)) return;
        self.@"IsBuy" = v;
        zcode.entity.markDirty(&self.dirty, 40);
    }
    pub fn getIsAllowTalk(self: @This()) bool { return self.@"IsAllowTalk"; }
    pub fn setIsAllowTalk(self: *@This(), v: bool) void {
        if (zcode.entity.valueEql(self.@"IsAllowTalk", v)) return;
        self.@"IsAllowTalk" = v;
        zcode.entity.markDirty(&self.dirty, 41);
    }
    pub fn getAvailablePredeposit(self: @This()) zcode.Decimal { return self.@"AvailablePredeposit"; }
    pub fn setAvailablePredeposit(self: *@This(), v: zcode.Decimal) void {
        if (zcode.entity.valueEql(self.@"AvailablePredeposit", v)) return;
        self.@"AvailablePredeposit" = v;
        zcode.entity.markDirty(&self.dirty, 42);
    }
    pub fn getFreezePredeposit(self: @This()) zcode.Decimal { return self.@"FreezePredeposit"; }
    pub fn setFreezePredeposit(self: *@This(), v: zcode.Decimal) void {
        if (zcode.entity.valueEql(self.@"FreezePredeposit", v)) return;
        self.@"FreezePredeposit" = v;
        zcode.entity.markDirty(&self.dirty, 43);
    }
    pub fn getAvailableRcBalance(self: @This()) zcode.Decimal { return self.@"AvailableRcBalance"; }
    pub fn setAvailableRcBalance(self: *@This(), v: zcode.Decimal) void {
        if (zcode.entity.valueEql(self.@"AvailableRcBalance", v)) return;
        self.@"AvailableRcBalance" = v;
        zcode.entity.markDirty(&self.dirty, 44);
    }
    pub fn getFreezeRcBalance(self: @This()) zcode.Decimal { return self.@"FreezeRcBalance"; }
    pub fn setFreezeRcBalance(self: *@This(), v: zcode.Decimal) void {
        if (zcode.entity.valueEql(self.@"FreezeRcBalance", v)) return;
        self.@"FreezeRcBalance" = v;
        zcode.entity.markDirty(&self.dirty, 45);
    }
    pub fn getCountryCode(self: @This()) []const u8 { return self.@"CountryCode"; }
    pub fn setCountryCode(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CountryCode", v)) return;
        self.@"CountryCode" = v;
        zcode.entity.markDirty(&self.dirty, 46);
    }
    pub fn getCountryId(self: @This()) i32 { return self.@"CountryId"; }
    pub fn setCountryId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"CountryId", v)) return;
        self.@"CountryId" = v;
        zcode.entity.markDirty(&self.dirty, 47);
    }
    pub fn getAreaId(self: @This()) i32 { return self.@"AreaId"; }
    pub fn setAreaId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"AreaId", v)) return;
        self.@"AreaId" = v;
        zcode.entity.markDirty(&self.dirty, 48);
    }
    pub fn getCityId(self: @This()) i32 { return self.@"CityId"; }
    pub fn setCityId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"CityId", v)) return;
        self.@"CityId" = v;
        zcode.entity.markDirty(&self.dirty, 49);
    }
    pub fn getProvinceId(self: @This()) i32 { return self.@"ProvinceId"; }
    pub fn setProvinceId(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"ProvinceId", v)) return;
        self.@"ProvinceId" = v;
        zcode.entity.markDirty(&self.dirty, 50);
    }
    pub fn getAreaInfo(self: @This()) []const u8 { return self.@"AreaInfo"; }
    pub fn setAreaInfo(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"AreaInfo", v)) return;
        self.@"AreaInfo" = v;
        zcode.entity.markDirty(&self.dirty, 51);
    }
    pub fn getQuestion1(self: @This()) []const u8 { return self.@"Question1"; }
    pub fn setQuestion1(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Question1", v)) return;
        self.@"Question1" = v;
        zcode.entity.markDirty(&self.dirty, 52);
    }
    pub fn getAnswer1(self: @This()) []const u8 { return self.@"Answer1"; }
    pub fn setAnswer1(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Answer1", v)) return;
        self.@"Answer1" = v;
        zcode.entity.markDirty(&self.dirty, 53);
    }
    pub fn getQuestion2(self: @This()) []const u8 { return self.@"Question2"; }
    pub fn setQuestion2(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Question2", v)) return;
        self.@"Question2" = v;
        zcode.entity.markDirty(&self.dirty, 54);
    }
    pub fn getAnswer2(self: @This()) []const u8 { return self.@"Answer2"; }
    pub fn setAnswer2(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Answer2", v)) return;
        self.@"Answer2" = v;
        zcode.entity.markDirty(&self.dirty, 55);
    }
    pub fn getQuestion3(self: @This()) []const u8 { return self.@"Question3"; }
    pub fn setQuestion3(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Question3", v)) return;
        self.@"Question3" = v;
        zcode.entity.markDirty(&self.dirty, 56);
    }
    pub fn getAnswer3(self: @This()) []const u8 { return self.@"Answer3"; }
    pub fn setAnswer3(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"Answer3", v)) return;
        self.@"Answer3" = v;
        zcode.entity.markDirty(&self.dirty, 57);
    }
    pub fn getOnlineTime(self: @This()) i32 { return self.@"OnlineTime"; }
    pub fn setOnlineTime(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"OnlineTime", v)) return;
        self.@"OnlineTime" = v;
        zcode.entity.markDirty(&self.dirty, 58);
    }
    pub fn getLastUpdateTime(self: @This()) i64 { return self.@"LastUpdateTime"; }
    pub fn setLastUpdateTime(self: *@This(), v: i64) void {
        if (zcode.entity.valueEql(self.@"LastUpdateTime", v)) return;
        self.@"LastUpdateTime" = v;
        zcode.entity.markDirty(&self.dirty, 59);
    }
    pub fn getCreateUser(self: @This()) []const u8 { return self.@"CreateUser"; }
    pub fn setCreateUser(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CreateUser", v)) return;
        self.@"CreateUser" = v;
        zcode.entity.markDirty(&self.dirty, 60);
    }
    pub fn getCreateUserID(self: @This()) i32 { return self.@"CreateUserID"; }
    pub fn setCreateUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"CreateUserID", v)) return;
        self.@"CreateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 61);
    }
    pub fn getCreateTime(self: @This()) zcode.DateTime { return self.@"CreateTime"; }
    pub fn setCreateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"CreateTime", v)) return;
        self.@"CreateTime" = v;
        zcode.entity.markDirty(&self.dirty, 62);
    }
    pub fn getCreateIP(self: @This()) []const u8 { return self.@"CreateIP"; }
    pub fn setCreateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"CreateIP", v)) return;
        self.@"CreateIP" = v;
        zcode.entity.markDirty(&self.dirty, 63);
    }
    pub fn getUpdateUser(self: @This()) []const u8 { return self.@"UpdateUser"; }
    pub fn setUpdateUser(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateUser", v)) return;
        self.@"UpdateUser" = v;
        zcode.entity.markDirty(&self.dirty, 64);
    }
    pub fn getUpdateUserID(self: @This()) i32 { return self.@"UpdateUserID"; }
    pub fn setUpdateUserID(self: *@This(), v: i32) void {
        if (zcode.entity.valueEql(self.@"UpdateUserID", v)) return;
        self.@"UpdateUserID" = v;
        zcode.entity.markDirty(&self.dirty, 65);
    }
    pub fn getUpdateTime(self: @This()) zcode.DateTime { return self.@"UpdateTime"; }
    pub fn setUpdateTime(self: *@This(), v: zcode.DateTime) void {
        if (zcode.entity.valueEql(self.@"UpdateTime", v)) return;
        self.@"UpdateTime" = v;
        zcode.entity.markDirty(&self.dirty, 66);
    }
    pub fn getUpdateIP(self: @This()) []const u8 { return self.@"UpdateIP"; }
    pub fn setUpdateIP(self: *@This(), v: []const u8) void {
        if (zcode.entity.valueEql(self.@"UpdateIP", v)) return;
        self.@"UpdateIP" = v;
        zcode.entity.markDirty(&self.dirty, 67);
    }

    /// 读取第 i 列（与 meta.fields 同序）。
    pub fn columnValue(self: @This(), i: usize) zcode.Value {
        return switch (i) {
            0 => .{ .int = @intCast(self.@"Id") },
            1 => .{ .int = @intCast(self.@"LanguageId") },
            2 => .{ .boolean = self.@"IsSuper" },
            3 => .{ .int = @intCast(self.@"SId") },
            4 => .{ .int = @intCast(self.@"TenantId") },
            5 => .{ .int = @intCast(self.@"UType") },
            6 => .{ .text = self.@"RoleExIds" },
            7 => .{ .text = self.@"OtherPermissions" },
            8 => .{ .text = self.@"DepartmentIds" },
            9 => .{ .text = self.@"TrueName" },
            10 => .{ .text = self.@"PayPwd" },
            11 => .{ .int = @intCast(self.@"AuthState") },
            12 => .{ .text = self.@"IdCard" },
            13 => .{ .text = self.@"IdcardImage1" },
            14 => .{ .text = self.@"IdcardImage2" },
            15 => .{ .text = self.@"IdcardImage3" },
            16 => .{ .text = self.@"CompanyName" },
            17 => .{ .int = @intCast(self.@"CompnayAuthState") },
            18 => .{ .text = self.@"CorporateName" },
            19 => .{ .text = self.@"BusinessLicenseImage" },
            20 => .{ .text = self.@"CorporateImage" },
            21 => .{ .boolean = self.@"EmailBind" },
            22 => .{ .boolean = self.@"MobileBind" },
            23 => .{ .boolean = self.@"IsSubScribe" },
            24 => .{ .boolean = self.@"IsSales" },
            25 => .{ .boolean = self.@"IsEngineer" },
            26 => .{ .int = @intCast(self.@"ReferrerId") },
            27 => .{ .int = @intCast(self.@"KeFuId") },
            28 => .{ .int = @intCast(self.@"ParentUId") },
            29 => .{ .int = @intCast(self.@"Points") },
            30 => .{ .int = @intCast(self.@"ExpPoints") },
            31 => .{ .text = self.@"QQ" },
            32 => .{ .text = self.@"WeiXin" },
            33 => .{ .text = self.@"WangWang" },
            34 => .{ .text = self.@"ContactName" },
            35 => .{ .text = self.@"Tel" },
            36 => .{ .text = self.@"Fax" },
            37 => .{ .text = self.@"CompanyInfo" },
            38 => .{ .text = self.@"Address" },
            39 => .{ .boolean = self.@"InformAllow" },
            40 => .{ .boolean = self.@"IsBuy" },
            41 => .{ .boolean = self.@"IsAllowTalk" },
            42 => .{ .decimal = self.@"AvailablePredeposit" },
            43 => .{ .decimal = self.@"FreezePredeposit" },
            44 => .{ .decimal = self.@"AvailableRcBalance" },
            45 => .{ .decimal = self.@"FreezeRcBalance" },
            46 => .{ .text = self.@"CountryCode" },
            47 => .{ .int = @intCast(self.@"CountryId") },
            48 => .{ .int = @intCast(self.@"AreaId") },
            49 => .{ .int = @intCast(self.@"CityId") },
            50 => .{ .int = @intCast(self.@"ProvinceId") },
            51 => .{ .text = self.@"AreaInfo" },
            52 => .{ .text = self.@"Question1" },
            53 => .{ .text = self.@"Answer1" },
            54 => .{ .text = self.@"Question2" },
            55 => .{ .text = self.@"Answer2" },
            56 => .{ .text = self.@"Question3" },
            57 => .{ .text = self.@"Answer3" },
            58 => .{ .int = @intCast(self.@"OnlineTime") },
            59 => .{ .int = @intCast(self.@"LastUpdateTime") },
            60 => .{ .text = self.@"CreateUser" },
            61 => .{ .int = @intCast(self.@"CreateUserID") },
            62 => .{ .datetime = self.@"CreateTime" },
            63 => .{ .text = self.@"CreateIP" },
            64 => .{ .text = self.@"UpdateUser" },
            65 => .{ .int = @intCast(self.@"UpdateUserID") },
            66 => .{ .datetime = self.@"UpdateTime" },
            67 => .{ .text = self.@"UpdateIP" },
            else => .{ .null = {} },
        };
    }

    /// 装载第 i 列（不置脏）。
    pub fn setColumnValue(self: *@This(), i: usize, v: zcode.Value) !void {
        switch (i) {
            0 => { self.@"Id" = v.asI32() orelse 0; },
            1 => { self.@"LanguageId" = v.asI32() orelse 0; },
            2 => { self.@"IsSuper" = v.asBool() orelse false; },
            3 => { self.@"SId" = v.asI64() orelse 0; },
            4 => { self.@"TenantId" = v.asI32() orelse 0; },
            5 => { self.@"UType" = v.asI16() orelse 0; },
            6 => { switch (v) { .text => |t| self.@"RoleExIds" = t, .null => self.@"RoleExIds" = "", else => {} } },
            7 => { switch (v) { .text => |t| self.@"OtherPermissions" = t, .null => self.@"OtherPermissions" = "", else => {} } },
            8 => { switch (v) { .text => |t| self.@"DepartmentIds" = t, .null => self.@"DepartmentIds" = "", else => {} } },
            9 => { switch (v) { .text => |t| self.@"TrueName" = t, .null => self.@"TrueName" = "", else => {} } },
            10 => { switch (v) { .text => |t| self.@"PayPwd" = t, .null => self.@"PayPwd" = "", else => {} } },
            11 => { self.@"AuthState" = v.asI16() orelse 0; },
            12 => { switch (v) { .text => |t| self.@"IdCard" = t, .null => self.@"IdCard" = "", else => {} } },
            13 => { switch (v) { .text => |t| self.@"IdcardImage1" = t, .null => self.@"IdcardImage1" = "", else => {} } },
            14 => { switch (v) { .text => |t| self.@"IdcardImage2" = t, .null => self.@"IdcardImage2" = "", else => {} } },
            15 => { switch (v) { .text => |t| self.@"IdcardImage3" = t, .null => self.@"IdcardImage3" = "", else => {} } },
            16 => { switch (v) { .text => |t| self.@"CompanyName" = t, .null => self.@"CompanyName" = "", else => {} } },
            17 => { self.@"CompnayAuthState" = v.asI16() orelse 0; },
            18 => { switch (v) { .text => |t| self.@"CorporateName" = t, .null => self.@"CorporateName" = "", else => {} } },
            19 => { switch (v) { .text => |t| self.@"BusinessLicenseImage" = t, .null => self.@"BusinessLicenseImage" = "", else => {} } },
            20 => { switch (v) { .text => |t| self.@"CorporateImage" = t, .null => self.@"CorporateImage" = "", else => {} } },
            21 => { self.@"EmailBind" = v.asBool() orelse false; },
            22 => { self.@"MobileBind" = v.asBool() orelse false; },
            23 => { self.@"IsSubScribe" = v.asBool() orelse false; },
            24 => { self.@"IsSales" = v.asBool() orelse false; },
            25 => { self.@"IsEngineer" = v.asBool() orelse false; },
            26 => { self.@"ReferrerId" = v.asI32() orelse 0; },
            27 => { self.@"KeFuId" = v.asI32() orelse 0; },
            28 => { self.@"ParentUId" = v.asI32() orelse 0; },
            29 => { self.@"Points" = v.asI32() orelse 0; },
            30 => { self.@"ExpPoints" = v.asI32() orelse 0; },
            31 => { switch (v) { .text => |t| self.@"QQ" = t, .null => self.@"QQ" = "", else => {} } },
            32 => { switch (v) { .text => |t| self.@"WeiXin" = t, .null => self.@"WeiXin" = "", else => {} } },
            33 => { switch (v) { .text => |t| self.@"WangWang" = t, .null => self.@"WangWang" = "", else => {} } },
            34 => { switch (v) { .text => |t| self.@"ContactName" = t, .null => self.@"ContactName" = "", else => {} } },
            35 => { switch (v) { .text => |t| self.@"Tel" = t, .null => self.@"Tel" = "", else => {} } },
            36 => { switch (v) { .text => |t| self.@"Fax" = t, .null => self.@"Fax" = "", else => {} } },
            37 => { switch (v) { .text => |t| self.@"CompanyInfo" = t, .null => self.@"CompanyInfo" = "", else => {} } },
            38 => { switch (v) { .text => |t| self.@"Address" = t, .null => self.@"Address" = "", else => {} } },
            39 => { self.@"InformAllow" = v.asBool() orelse false; },
            40 => { self.@"IsBuy" = v.asBool() orelse false; },
            41 => { self.@"IsAllowTalk" = v.asBool() orelse false; },
            42 => { self.@"AvailablePredeposit" = v.asDecimal() orelse .{ .mantissa = 0, .scale = 0 }; },
            43 => { self.@"FreezePredeposit" = v.asDecimal() orelse .{ .mantissa = 0, .scale = 0 }; },
            44 => { self.@"AvailableRcBalance" = v.asDecimal() orelse .{ .mantissa = 0, .scale = 0 }; },
            45 => { self.@"FreezeRcBalance" = v.asDecimal() orelse .{ .mantissa = 0, .scale = 0 }; },
            46 => { switch (v) { .text => |t| self.@"CountryCode" = t, .null => self.@"CountryCode" = "", else => {} } },
            47 => { self.@"CountryId" = v.asI32() orelse 0; },
            48 => { self.@"AreaId" = v.asI32() orelse 0; },
            49 => { self.@"CityId" = v.asI32() orelse 0; },
            50 => { self.@"ProvinceId" = v.asI32() orelse 0; },
            51 => { switch (v) { .text => |t| self.@"AreaInfo" = t, .null => self.@"AreaInfo" = "", else => {} } },
            52 => { switch (v) { .text => |t| self.@"Question1" = t, .null => self.@"Question1" = "", else => {} } },
            53 => { switch (v) { .text => |t| self.@"Answer1" = t, .null => self.@"Answer1" = "", else => {} } },
            54 => { switch (v) { .text => |t| self.@"Question2" = t, .null => self.@"Question2" = "", else => {} } },
            55 => { switch (v) { .text => |t| self.@"Answer2" = t, .null => self.@"Answer2" = "", else => {} } },
            56 => { switch (v) { .text => |t| self.@"Question3" = t, .null => self.@"Question3" = "", else => {} } },
            57 => { switch (v) { .text => |t| self.@"Answer3" = t, .null => self.@"Answer3" = "", else => {} } },
            58 => { self.@"OnlineTime" = v.asI32() orelse 0; },
            59 => { self.@"LastUpdateTime" = v.asI64() orelse 0; },
            60 => { switch (v) { .text => |t| self.@"CreateUser" = t, .null => self.@"CreateUser" = "", else => {} } },
            61 => { self.@"CreateUserID" = v.asI32() orelse 0; },
            62 => { self.@"CreateTime" = v.asDatetime() orelse .{}; },
            63 => { switch (v) { .text => |t| self.@"CreateIP" = t, .null => self.@"CreateIP" = "", else => {} } },
            64 => { switch (v) { .text => |t| self.@"UpdateUser" = t, .null => self.@"UpdateUser" = "", else => {} } },
            65 => { self.@"UpdateUserID" = v.asI32() orelse 0; },
            66 => { self.@"UpdateTime" = v.asDatetime() orelse .{}; },
            67 => { switch (v) { .text => |t| self.@"UpdateIP" = t, .null => self.@"UpdateIP" = "", else => {} } },
            else => {},
        }
    }
};

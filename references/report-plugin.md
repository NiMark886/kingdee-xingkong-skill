# 星空账表插件参考（SysReportBaseService）

## 0. 常用 using

```csharp
using Kingdee.BOS;                          // LocaleValue、Context
using Kingdee.BOS.Core.Report;              // ReportHeader、ReportProperty、IRptParams
using Kingdee.BOS.Core.List;                // ListHeader
using Kingdee.BOS.Contracts.Report;         // SysReportBaseService
using Kingdee.BOS.Core.Report.PlugIn;       // AbstractSysReportPlugIn
```

## 1. 账表类型

| 类型 | 开发方式 | 关键类 |
|---|---|---|
| SQL 账表 | BOS 建 SQL 账表，写 SQL、解析字段、配参数 | 配置为主 |
| 简单账表 | 服务端插件取数 + 临时表 + 表头 | `SysReportBaseService` |
| 分页账表 | `REPORTTYPE_MOVE`，实现 `GetList` | `SysReportBaseService` |
| 树形账表 | `REPORTTYPE_TREE`，实现 `GetTreeNodes` | `SysReportBaseService` |
| 报表界面插件 | 双击钻取、打开子报表 | `AbstractSysReportPlugIn` |

## 2. 生命周期

```text
Initialize
→ BuilderReportSqlAndTempTable   // 取数写临时表
→ GetReportHeaders               // 定义列
→ GetReportTitles                // 标题
→ GetSummaryColumnInfo           // 汇总列
```

## 3. ReportProperty 常用属性

```csharp
public override void Initialize()
{
    base.Initialize();

    this.ReportProperty.ReportType = ReportType.REPORTTYPE_NORMAL;
    this.ReportProperty.IdentityFieldName = "FIDENTITYID";   // 序号字段，从 1 连续
    this.ReportProperty.PrimaryKeyFieldName = "FIDENTITYID"; // 主键字段
    this.ReportProperty.IsUIDesignerColumns = false;         // 列由插件定义，设计器不生效
    this.ReportProperty.IsGroupSummary = true;               // 允许分组汇总
}
```

| 属性 | 作用 |
|---|---|
| `ReportType` | `REPORTTYPE_NORMAL` / `REPORTTYPE_MOVE` / `REPORTTYPE_TREE` |
| `IdentityFieldName` | 序号字段，必须从 1 连续，否则分页/导出错乱 |
| `PrimaryKeyFieldName` | 主键字段，用于合并相同行 |
| `IsUIDesignerColumns` | `false` 时完全以 `GetReportHeaders` 代码为准 |
| `IsGroupSummary` | 是否允许按列分组汇总 |

## 4. 列定义与列顺序（最容易踩坑）

`ReportHeader` 是**单个对象**，不是集合。列通过 `AddChild()` 添加，返回 `ListHeader`：

```csharp
public override ReportHeader GetReportHeaders(IRptParams filter)
{
    ReportHeader header = new ReportHeader();
    int colIndex = 0;

    // 一级列（无分组）
    ListHeader seq = header.AddChild();
    seq.Key = "FSEQ";
    seq.Caption = new LocaleValue("单个序号");
    seq.ColIndex = colIndex++;          // ★ 列顺序由这里决定
    seq.Width = 80;

    // 两级表头：父列
    ListHeader parent = header.AddChild();
    parent.Key = "FGROUP_SALARY";
    parent.Caption = new LocaleValue("工资");
    parent.ColIndex = colIndex;         // 父列也要设置

    // 子列挂在父列下
    ListHeader child = parent.AddChild();
    child.Key = "FBASICSALARY";
    child.Caption = new LocaleValue("岗位基本工资");
    child.ColIndex = colIndex++;        // ★ 叶子列递增
    child.Width = 120;
    child.Decimal = 2;

    return header;
}
```

**关键结论（已实测）：**

- 运行时列顺序按 `ListHeader.ColIndex` 升序，值越小越靠前；集合添加顺序不保证最终顺序。
- **父列和叶子列都要设置 `ColIndex`**；只设父列不设叶列，或只设叶列不设父列，都可能出现“年月排在单个序号前面”这类问题。
- `IsUIDesignerColumns = false` 时，在 BOS 设计器里拖动列顺序**不会**写回 `ColIndex`，运行时完全以代码为准。
- 如果希望设计器维护列，就不要在插件里重写 `GetReportHeaders`，两者只能选一个作为唯一来源。
- `ListHeader` 还有 `Width`、`Visible`、`Decimal`、`Caption`、`Key`。

## 5. 取数写临时表

```csharp
public override void BuilderReportSqlAndTempTable(IRptParams filter, string tableName)
{
    // tableName 是平台分配的临时表名，存储过程按这个表名写入结果
    string sql = "EXEC dbo.MyReportProc @YearMonth=@YearMonth, @TableName=@TableName";

    List<SqlParam> paramList = new List<SqlParam>();
    paramList.Add(new SqlParam("@YearMonth", KDDbType.String, GetYearMonth(filter)));
    paramList.Add(new SqlParam("@TableName", KDDbType.String, tableName));

    DBUtils.Execute(this.Context, sql, paramList: paramList);
}
```

存储过程内部用 `SELECT ... INTO` 或 `INSERT INTO` 写入传入的表名；表名不能用参数直接拼进普通 SQL，需用 `QUOTENAME` + `sp_executesql`。

## 6. 读取过滤参数和自定义参数

`FilterParameter` 只有过滤条件，**没有** `ParameterData` / `CustomParams`。这两个在 `IRptParams` 上：

```csharp
private string GetYearMonth(IRptParams filter)
{
    if (this.SysReportModel == null || this.SysReportModel.RptParams == null)
    {
        return "";
    }

    // 过滤字段
    var filterParameter = this.SysReportModel.FilterParameter;

    // 自定义参数 / 参数数据
    var parameterData = this.SysReportModel.RptParams.ParameterData;
    var customParams = this.SysReportModel.RptParams.CustomParams;

    object value = null;
    if (customParams != null && customParams.ContainsKey("FYearMonth"))
    {
        value = customParams["FYearMonth"];
    }

    return value == null ? "" : value.ToString();
}
```

坑：`FilterParameter` 上访问 `ParameterData` / `CustomParams` 会编译报错（CS1061）；`SysReportModel` 在部分时点为 null，必须判空。

## 7. 分组汇总

建议：

- `ReportProperty.IsGroupSummary = true`。
- **不要**再设置 `GroupSummaryInfoData`，否则平台生成分组 SQL 时可能重复指定分组字段（例如 `fcostdept` 出现两次）而报错。
- 分组字段在 SQL 结果中保留，表头按普通列定义即可。
- 需要“成本部门分组、个人明细展开”时，SQL 先按部门+个人输出明细，平台按分组列汇总。

## 8. 汇总列

```csharp
public override ReportSummaryFieldCollection GetSummaryColumnInfo(IRptParams filter)
{
    ReportSummaryFieldCollection summary = new ReportSummaryFieldCollection();
    summary.Add(new SummaryField("FQTY", BOSEnums.Enu_SummaryType.SUM));
    return summary;
}
```

## 9. 账表界面插件 AbstractSysReportPlugIn

```csharp
using Kingdee.BOS.Core.Report.PlugIn;
using Kingdee.BOS.Core.Report.PlugIn.Args;

public class MyReportPlugIn : AbstractSysReportPlugIn
{
    public override void CellDbClick(CellEventArgs args)
    {
        base.CellDbClick(args);

        SysReportShowParameter param = new SysReportShowParameter();
        param.FormId = "XX_DetailReport";
        param.ParentPageId = this.View.PageId;
        param.IsShowFilter = false;
        this.View.ShowForm(param);
    }
}
```

## 10. 账表常见坑

1. **列顺序不对**：`ListHeader.ColIndex` 未设置或父子列不一致。
2. **列重复/数据串列**：`GetReportHeaders` 添加的 Key 与临时表字段不一致。
3. **分组 SQL 报重复字段**：设置了 `GroupSummaryInfoData`，与平台自动分组冲突。
4. **序号不连续**：`IdentityFieldName` 没有从 1 开始，分页/导出错乱。
5. **临时表字段类型不对**：金额/数量精度丢失，临时表列用 `DECIMAL(18,4)` 以上。
6. **自定义参数取不到**：从 `FilterParameter` 取，或父子页面 Key 不一致。
7. **分页账表只取第一页**：程序化调用要循环 `CurrentPosition`。
8. **报表界面插件与数据源插件混淆**：一个管界面，一个管取数。

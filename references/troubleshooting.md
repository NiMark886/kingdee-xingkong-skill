# 星空开发排查手册

本文是通用排查手册，案例已脱敏。字段、表名、单据号均为占位符，不包含客户完整源码或真实业务数据。

## 0. 排查顺序

1. **确认入口**：界面点击、WebAPI、引入、下推、工作流，走的是不是同一个插件/事件。
2. **确认标识**：字段 Key、单据体标识、表名、操作标识是否与 BOS 元数据一致。
3. **确认状态**：单据 `FDOCUMENTSTATUS` 是否已审核（`C`），是否作废。
4. **确认数据**：字段是否有值、单位是否一致、数量在 `_DATA` 还是 `_Q` 表。
5. **确认匹配**：多字段 JOIN 时逐字段比对，重点看字符串差异和 `NULL`。
6. **确认执行**：DLL 是否部署、插件是否注册、IIS 是否回收、断点是否命中。

## 1. 账表列顺序在 BOS 拖动后无效

**现象**：`年月` 一直排在 `单个序号` 前面，设计器里拖动没有效果。

**根因**：简单账表列顺序由 `GetReportHeaders` 中 `ListHeader.ColIndex` 决定。设计器拖动只改树节点顺序，不写回 `ColIndex`；`IsUIDesignerColumns=false` 时完全以代码为准。

**修复**：

```csharp
int colIndex = 0;

ListHeader parent = header.AddChild();
parent.Caption = new LocaleValue("基本信息");
parent.ColIndex = colIndex;          // 父列也要设置

ListHeader leaf = parent.AddChild();
leaf.Caption = new LocaleValue("单个序号");
leaf.ColIndex = colIndex++;          // 叶子列递增
```

父列、叶列都设置 `ColIndex`，值越小越靠前。

## 2. 账表分组 SQL 报字段重复

**现象**：账表运行报错，生成的 SQL 中分组列出现两次。

**根因**：`ReportProperty.IsGroupSummary = true` 时平台会自动按分组列生成 SQL，插件又设置了 `GroupSummaryInfoData`，重复指定分组字段。

**修复**：删除插件里的 `GroupSummaryInfoData` 和重复隐藏表头，只保留 `IsGroupSummary = true`。

## 3. `ShowErrMessage` 编译报错

**现象**：`CS1501 方法“ShowErrMessage”没有采用 2 个参数的重载`。

**根因**：`IDynamicFormView` 没有 `(string, MessageBoxType)` 两参重载。

**修复**：

```csharp
this.View.ShowErrMessage("提示内容", "", MessageBoxType.Advise);
```

`MessageBoxType` 只有 `Notice`、`Advise`、`AskOK`、`AskYes`、`Error`，**没有 `Warning`**。

## 4. 账表插件取不到自定义参数

**现象**：访问 `FilterParameter.ParameterData` 或 `FilterParameter.CustomParams` 编译报错。

**根因**：`FilterParameter` 没有这两个成员，它们在 `IRptParams` 上。

**修复**：

```csharp
if (this.SysReportModel == null || this.SysReportModel.RptParams == null)
{
    return "";
}

var parameterData = this.SysReportModel.RptParams.ParameterData;
var customParams = this.SysReportModel.RptParams.CustomParams;
```

## 5. 保存校验只在界面生效

**现象**：界面上超量保存被拦截，但 WebAPI/下推/引入仍能保存。

**根因**：校验写在 `AbstractBillPlugIn`，只走 Web 层。

**修复**：把规则移到 `AbstractOperationServicePlugIn`（`BeforeExecuteOperationTransaction` 或校验器），界面保存也会走操作插件。

## 6. 单据体合计超限仍能保存

**现象**：同一来源分录的数量合计超过允许值，仍然保存成功。

**修复**：`BeforeDoOperation` 中按来源分录内码分组累加，超限 `e.Cancel = true`。

```csharp
string op = e.Operation.FormOperation.Operation;
if (op != "Save" && op != "Submit") return;

var groups = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
int rowCount = this.Model.GetEntryRowCount("FEntity");

for (int i = 0; i < rowCount; i++)
{
    string sourceKey = Convert.ToString(this.Model.GetValue("FYDFLNM", i)).Trim();
    if (string.IsNullOrEmpty(sourceKey)) continue;

    decimal qty = ToDecimal(this.Model.GetValue("F_CUST_QTY", i));
    if (!groups.ContainsKey(sourceKey)) groups[sourceKey] = 0m;
    groups[sourceKey] += qty;
}

foreach (var item in groups)
{
    if (item.Value > GetLimit(item.Key))
    {
        this.View.ShowErrMessage("第 " + item.Key + " 行起数量合计超限。", "", MessageBoxType.Advise);
        e.Cancel = true;
        return;
    }
}
```

注意：

- 来源分录内码用字符串分组，不要盲目转 `long`；转 0 会把不同来源混成一组。
- 组内额度取法按业务确定；如果业务是每行独立额度，改成逐行校验。
- 只拦界面；要拦 WebAPI 需改操作服务插件。

## 7. 已审核出库，但即时库存没扣

**现象**：出库单已审核，即时库存报表仍然显示库存。

**根因（按发生频率）**：

1. 扣减子查询**没有过滤 `FDOCUMENTSTATUS`**，所有状态都参与；但这只是口径错误，真正“已审核也不扣”通常是下面两条。
2. **匹配字段值不一致**：库存工艺是 `工艺A`，单据是 `工艺A-1`，完整匹配失败。
3. **`NULL = NULL` 不成立**：双方形状都为空/NULL，JOIN 条件不成立。
4. 入库长度是平均值（`总长度/数量`），与单据长度有小数差异。

**修复**：

```sql
where t1.FDOCUMENTSTATUS = 'C'                    -- 只扣已审核
...
and left(a.F_CUST_PROCESS, 1) = left(t1.工艺, 1)   -- 工艺A-1 = 工艺A
and isnull(a.F_CUST_SHAPE, '') = isnull(t1.形状, '')  -- 处理 NULL
and a.F_CUST_LENGTH = t1.入库长度
```

核对时把单据行与库存行的“名称/型号/材质/工艺/形状/长度”逐列对比，哪列不同就修哪列，不要只看数量。

## 8. 查询结果出现长度大于下料长度的料

**现象**：寻料/选料弹窗里出现长度大于下料长度的材料。

**根因**：父页面没有把下料长度传给弹窗，查询 SQL 没有长度过滤。

**修复**：

1. 父页面把当前行下料长度放进 `CustomParams`：

```csharp
var length = this.View.Model.GetValue("F_CUST_REQUIREDLENGTH", curIndex);
formParam.CustomParams.Add("REQUIRED_LENGTH", length == null ? "" : length.ToString());
```

2. 弹窗读取参数，SQL 增加：

```sql
and (t6.F_CUST_TOTALLENGTH / nullif(t6.FQTY, 0)) <= @REQUIRED_LENGTH
```

## 9. 可用量为 0 的行仍显示

**现象**：可用量为 0 的材料仍然出现在结果里。

**根因**：`WHERE` 只判断了基础数量，没有扣减锁库数量。

**修复**：

```sql
where (t1.FBASEQTY - isnull(TSUB.FSECLOCKQTY, 0)) > 0
```

## 10. 生成下游单据时出现 0 行

**现象**：上游单据生成下游单据时，部分单据一行数据都没有。

**根因**：先删除合并行、再查找模板行；当唯一一行就是合并行时，删除后行数为 0，模板返回 -1。

**修复**：先用合并行复制出缺失的明细行，全部补齐后才删除合并行。同类补行逻辑默认关闭，避免两张单互相补行。

## 11. 下游单据行数翻倍

**现象**：两张单据各自补对方的明细行，每张从 1 行变 2 行，合计翻倍。

**根因**：补行逻辑没有和“按行下推”互斥。

**修复**：默认关闭界面补行，由下推按行生成；确需补行时先确认不会重复。

## 12. 下推重复生成下游单据

**修复组合**：

```csharp
ids = ids.Distinct().ToList();
```

```sql
where not exists (
    select 1
    from T_QM_INSPECTBILLENTRY e
    where e.F_CUST_SOURCEBILL = t.F_CUST_SOURCEBILL
      and e.FOperNumber = t.FOperNumber
      and e.F_CUST_BOX = t.F_CUST_BOX
)
```

同时校验来源内码非空、目标分录只保留 1 行、数量/料框一致，校验失败不保存。

## 13. 派工数量超过可派工数量仍能保存

**修复**：动态表单 `BarItemClick` 拦截 `tbSave` / `tbSplitSave`，逐行比较本次派工数量与可派工数量，超限 `ShowErrMessage` + `e.Cancel = true`。

注意确认“可派工数量”的实际字段 Key；不同项目可能不同。

## 14. 反写数量重复累加

**现象**：同一单据重复保存后，已派工/已检验数量越存越大。

**根因**：反写 SQL 每次都用 `+=`。

**修复**：按差额反写（本次值 - 上次值），或在操作插件里先读旧值再算差额。

## 15. 找不到字段 Key

方法一：BOS 设计器打开单据，选中字段看“标识”。

方法二：解析本地元数据缓存：

```text
C:\Users\Administrator\Documents\Kingdee\K3Cloud\FormMetadataCacheManager\Cache_<hash>
```

JSON 文件（UTF-8 BOM），搜索字段标题或自定义字段前缀即可。

方法三：数据库查元数据表 `T_META_OBJECTTYPE` / `T_META_OBJECTTYPECACHE`。

## 16. 无法反编译 Kingdee DLL

**现象**：ildasm 报 `Protected module -- cannot disassemble`。

**修复**：用 PowerShell 反射查看类型、属性、方法：

```powershell
$asm = [Reflection.Assembly]::LoadFrom(
  'C:\Program Files (x86)\Kingdee\K3Cloud\DeskClient\K3CloudClient\Kingdee.BOS.Core.dll')
$type = $asm.GetType('Kingdee.BOS.Core.DynamicForm.IFormOperation')
$type.GetProperties() | ForEach-Object { "$($_.PropertyType.Name) $($_.Name)" }
```

技能包内 `scripts/inspect-api.ps1` 可直接用。

## 17. 插件不触发 / 断点不命中

按顺序检查：

1. DLL 是否复制到 `WebSite\bin`。
2. BOS 是否注册到正确的表单/操作/转换。
3. 类是否 `public`，是否继承正确基类。
4. 类名、命名空间是否与 BOS 注册的完全一致。
5. 是否回收应用程序池 / `iisreset`。
6. VS 是否附加到正确的 `w3wp.exe`（`appcmd list wp` 查 PID）。
7. 引用 DLL 版本是否与服务器一致。
8. 事件是否用错：`BeforeSave` 只在界面保存触发；WebAPI 走操作插件。

## 18. 通用错误速查

| 现象 | 可能原因 | 排查 |
|---|---|---|
| “实体类型中不存在名为 xxx 的属性” | 字段没在 `OnPreparePropertys` 预加载、属性名写错 | `e.FieldKeys.Add`；核对属性名 |
| 取值为 null | 字段标识/属性名混用、字段未加载 | Model 用 Key，DynamicObject 用属性名 |
| 保存报错 | 校验器拦截、必填、权限、反写超额 | 看 `ValidationErrors`、日志、反写 |
| 汇总数量偏大 | JOIN 一对多 | 先聚合再 JOIN / `EXISTS` |
| 报表分页错乱 | 序号不连续 | 重置 `FIDENTITYID`，从 1 连续 |
| WebAPI 修改变新增 | 没传 FID/FEntryID | 修改必须传内码 |
| WebAPI 字段没更新 | 没传 `NeedUpDateFields` | 指定更新字段 |
| 热更新不生效 | 没加 `[HotUpdate]`、配置没开、目录权限 | 检查配置和权限，重启 IIS |

## 19. 界面有值，数据库里是 0

**现象**：选物料后界面能看到带出的值，保存后查数据库全是 0。

**排查顺序**：

1. 单据是否真的保存了？未保存的单据不在业务表里，按单号查不到。
2. 查的是不是同一张单、同一行？按 `FENTRYID` 或单号定位，不要只看最新几行。
3. 服务器上跑的是不是最新 DLL？旧 DLL 可能只写了部分字段。
4. 字段是不是在正确的实体上？表头字段写到了分录行，或分录字段写到了表头。
5. 保存前是否被其他插件/校验覆盖？用 `BeforeSave` 前后各查一次值。

## 20. 插件只带出部分字段

**现象**：选了物料，只有一两个字段有值，其余字段不动。

**常见原因**：

- 某个字段不在当前实体上，直接 `SetValue` 抛异常，后面的写入全部中断。
- 字段 Key 大小写/拼写不一致，`GetField` 找不到。
- 字段在当前视图没有加载。
- `DataChanged` 没有判断 `e.Field.Key`，或者目标字段的事件没进分支。
- `SetValue` 后没有 `UpdateView`，界面看起来没变。

**修复**：所有写入先 `HasField`，字段不存在就跳过；每个字段单独 try/catch 或安全写入，保证一个字段失败不影响其他字段；打开调试弹窗确认事件和字段 Key。

## 21. SQL 报 8114：从 nvarchar 转换为 numeric 时出错

**三个根因，按出现频率**：

1. `ISNULL(数字列, N'')`：`N''` 被隐式转成 `numeric`，不是空字符串。改成 `ISNULL(CONVERT(NVARCHAR(500), 数字列), N'')`。
2. `UNION ALL` 各分支类型不一致：只要一个分支是 `numeric`，整个结果列按 `numeric` 处理，其他分支的空串/文本转换失败。每个分支都 `CONVERT(NVARCHAR(500), ...)`。
3. `CASE` 的 `THEN` / `ELSE` 类型不一致：同样按优先级统一，数字分支把文本分支拖进 numeric。每个分支显式转换。

另外，`ISNUMERIC` 会放过 `1e-5`、`1,000`、`+`、`-` 等值，不能作为 `CAST` 前的唯一判断。SQL Server 2008 R2 没有 `TRY_CONVERT`，用“非空、只含数字和小数点、最多一个小数点、至少一位数字”的严格条件判断。

## 22. 批号带不出长度

**现象**：选了批号，长度字段仍为 0 或旧值。

**排查顺序**：

1. `FLot` 返回的是 `DynamicObject`，不是字符串；内码取 `obj["Id"]`。
2. 分录表批号列存的是批号主档 ID，不是界面文本；拿文本去比永远匹配不上。
3. 批号文本可能不在 `Name` 属性；按 `Name`、`Number`、显示值等候选键逐个取。
4. 文本分隔符/分段位置是否与预期一致；解析失败要回退，不要直接抛异常。
5. 回退 SQL 是否过滤了 `FDOCUMENTSTATUS = 'C'`、是否用 `NULLIF(SUM(FREALQTY), 0)` 防除零。
6. 查不到时是否错误地覆盖了人工值；按业务要求应保留原值。

## 23. `DataChanged` 卡顿或递归

**现象**：选一个字段后界面卡住，或字段值反复变化。

**原因**：`DataChanged` 里 `SetValue` 又触发 `DataChanged`，形成递归；或没有判断 `e.Field.Key`，任何字段变化都跑全量计算。

**修复**：

- 只处理目标字段 Key。
- 加 `recalculating` 标志，进入计算前置 true，结束后置 false。
- 计算保持幂等，每次都从基础值全量重算，不做累加。

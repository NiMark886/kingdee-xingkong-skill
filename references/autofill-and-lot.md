# 表单自动带值与批号取数

本文只记录通用模式。示例中的字段、表名、批号均为占位符，不包含任何客户的完整插件源码、真实字段清单或业务数据。

## 1. 事件选择

| 需求 | 事件 | 要点 |
|---|---|---|
| 选物料后带出属性 | `DataChanged` | 先判断 `e.Field.Key`，只处理目标字段 |
| 选批号后带出长度/规格 | `DataChanged` | 先解析批号文本，解析不到再查入库历史 |
| 数量、长度变化后重算 | `DataChanged` | 每次从基础值全量重算，不做累加 |
| 保存前统一刷新 | `BeforeSave` | 逐行刷新，保证落库值最新 |

`DataChanged` 会在每个字段变化时触发，不判断字段 Key 会把整张单的联动都跑一遍，界面会明显变卡。

表单插件只覆盖界面入口。WebAPI、引入、下推、工作流不会经过 `DataChanged` / `BeforeSave`；要求全入口生效时，把同一规则放到操作服务插件或校验器。

## 2. 安全读写字段

字段可能还没在 BOS 上加、加在表头而不是分录、或当前视图没有加载。直接 `SetValue` 会抛异常，后面的字段就全部不写了。先判断字段是否存在：

```csharp
private bool HasField(string fieldKey)
{
    if (this.View == null || this.View.BusinessInfo == null) return false;
    if (this.View.BusinessInfo.GetField(fieldKey) != null) return true;

    foreach (var f in this.View.BusinessInfo.GetFieldList())
    {
        if (string.Equals(f.Key, fieldKey, StringComparison.OrdinalIgnoreCase))
            return true;
    }
    return false;
}
```

写入统一走安全方法，字段不存在就跳过，不影响其他字段：

```csharp
private void SetDecimal(string fieldKey, decimal value, int row)
{
    if (!HasField(fieldKey)) return;
    this.Model.SetValue(fieldKey, value, row);
    this.View.UpdateView(fieldKey, row);
}
```

读取也要容错：空值、`DBNull`、非数字都按 0 处理，避免一行脏数据中断整个循环。

## 3. 基础资料字段

物料、批号等基础资料字段返回 `DynamicObject`，不是字符串：

```csharp
DynamicObject obj = this.Model.GetValue("FMaterialId", row) as DynamicObject;
long id = 0;
if (obj != null && obj["Id"] != null)
{
    long.TryParse(Convert.ToString(obj["Id"]), out id);
}
string text = obj == null ? "" : Convert.ToString(obj["Name"]);
```

- `Model.GetValue` 用字段 Key。
- `DynamicObject` 索引用实体属性名，不是字段 Key。
- 显示文本不一定在 `Name`，也可能为空；按候选键依次取，不能只认一个属性。

## 4. 批号：对象、内码、文本是三件事

| 位置 | 存什么 | 怎么用 |
|---|---|---|
| 单据字段（批次） | 基础资料对象 | `Model.GetValue` 得到 `DynamicObject` |
| 对象内码 | 批号主档 ID | `obj["Id"]`，SQL 参数用 `Int64` |
| 分录表批号列 | 批号主档 ID | 关联 `T_BD_LOTMASTER.FLOTID` |
| 批号文本 | 业务编码/名称 | 从对象属性取，或按候选键取 |

常见错误：拿界面上看到的批号文本，去和分录表的批号列比较。分录表存的是 ID，不是文本，永远匹配不上。

批号文本经常承载业务属性（长度、规格、供应商、日期等）。如果文本有稳定分隔符，优先解析文本，解析不到再查入库历史：

```text
批号示例：A-B-C-D
按分隔符拆分，取第二段作为长度 → decimal.TryParse
```

解析只接受正数；失败返回 `false`，不要抛异常。批号文本可能有多个候选属性（名称、编码、显示值），逐个尝试，全部失败再回退 SQL。

按批号回退查入库时，用「物料 + 批号主档 ID」，并且只统计已审核单据：

```sql
SELECT CONVERT(DECIMAL(18,6),
       SUM(e.F_CUST_LENGTH) / NULLIF(SUM(e.FREALQTY), 0)) AS LENGTH
FROM T_STK_INSTOCKENTRY e
INNER JOIN T_STK_INSTOCK h ON h.FID = e.FID
WHERE e.FMATERIALID = @FMATERIALID
  AND e.FLOT = @FLOTID
  AND h.FDOCUMENTSTATUS = 'C'
  AND ISNULL(e.FREALQTY, 0) <> 0
HAVING SUM(e.FREALQTY) <> 0;
```

查不到时不要覆盖单据上已有的人工值。

## 5. 联动计算

派生字段每次都用基础值全量重算，不要 `+=`：

```text
单件重量 = 长度 × 单位重量
单件金额 = 长度 × 单位金额
总长度   = 数量 × 长度
总重量   = 数量 × 单件重量
```

顺序：先算单件，再算总量；先把依赖字段都读出来，再统一写回。`SetValue` 可能再次触发 `DataChanged`，计算必须幂等，或加一个 `recalculating` 标志防止递归。

## 6. 调试顺序

1. 事件是否触发：在 `DataChanged` 开头用 `ShowMessage` 输出 `e.Field.Key`。
2. 字段是否取到：输出值的类型，确认是 `DynamicObject` 还是字符串。
3. 批号文本是否取到：把候选文本拼起来输出，确认分隔符和第二段。
4. SQL 是否返回行：输出参数和返回行数。
5. 界面有值不等于数据库有值：**先保存，再查库**；未保存的单据不在业务表里。
6. 只带出部分字段：确认字段在表头还是分录；表头字段不能带分录行号写入。
7. 类名、命名空间必须和 BOS 注册的完全一致；旧 DLL 残留时会出现“有时生效、有时不生效”。

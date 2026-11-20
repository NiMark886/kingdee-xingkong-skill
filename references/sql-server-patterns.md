# 星空 SQL Server 模式与表结构

本文只记录通用模式。示例中的自定义字段、表名均为占位符（`F_CUST_xxx`、`T_CUST_xxx`），具体项目以 BOS 元数据和实际表结构为准。

## 1. 表名规律

| 后缀 | 含义 | 示例 |
|---|---|---|
| 无后缀 | 单据头 | `T_PUR_POOrder`、`T_STK_INSTOCK` |
| `ENTRY` | 单据体/分录 | `T_PUR_POOrderEntry`、`T_STK_INSTOCKENTRY` |
| `_Q` | 分录数量/多单位 | `T_PRD_FEEDMTRLDATA_Q` |
| `_LK` | 关联/下推关系 | `T_QM_INSPECTBILLENTRY_LK` |
| `_L` | 多语言名称 | `T_BD_MATERIAL_L` |
| `_F` | 财务/扩展 | `T_PUR_POOrderENTRY_F` |
| `_S` | 辅助属性 | `T_STK_INVENTORY_S` |
| `_P` | 计划 | `T_PRD_MOENTRY_P` |

扩展字段命名一般是 `F_开发商代码_名称`。开发商代码因项目而异，示例统一写成 `F_CUST_xxx`，不要直接把某个项目的真实字段清单带进公共技能库。

## 2. 单据状态

表头字段 `FDOCUMENTSTATUS`：

| 值 | 含义 |
|---|---|
| `Z` | 暂存 |
| `A` | 创建 |
| `B` | 审核中 |
| `C` | 已审核 |
| `D` | 重新审核 |

作废字段按版本/单据可能是 `FCANCELLATION` 或 `FCANCELSTATUS`，以实际表结构为准。

统计/扣减时默认口径：

```sql
where FDOCUMENTSTATUS = 'C'   -- 只算已审核
```

不按状态过滤会把暂存、审核中的单据也算进去，这是“库存数量对不上”的常见原因。

## 3. 常用标准表

| 业务 | 表 |
|---|---|
| 采购订单 | `T_PUR_POOrder` / `T_PUR_POOrderEntry` |
| 采购入库 | `T_STK_INSTOCK` / `T_STK_INSTOCKENTRY` |
| 生产领料/补料 | `T_PRD_FEEDMTRL` / `T_PRD_FEEDMTRLDATA` / `T_PRD_FEEDMTRLDATA_Q` |
| 即时库存 | `T_STK_INVENTORY` |
| 初始库存 | `T_STK_INVINIT` / `T_STK_INVINITDETAIL` |
| 工序汇报 | `T_SFC_OPTRPT` / `T_SFC_OPTRPTENTRY` |
| 检验单 | `T_QM_INSPECTBILL` / `T_QM_INSPECTBILLENTRY` |
| 物料 | `T_BD_MATERIAL` / `T_BD_MATERIAL_L` |
| 单位 | `T_BD_UNIT` / `T_BD_UNIT_L` |
| 仓库 | `T_BD_STOCK` |
| 批号主档 | `T_BD_LOTMASTER` / `T_BD_LOTMASTER_L` |
| 锁库日志 | `T_STK_LOCKSTOCKLOG` |
| 预留关系 | `T_PLN_RESERVELINKENTRY` |

注意：`T_PRD_FEEDMTRL` 是生产领料单，不是 `T_PRD_PICKMTRL`；不同版本可能有差异，以 BOS 设计器“表名”属性为准。

项目自定义表不在技能中登记具体表名。需要时从 BOS 设计器、`T_META_OBJECTTYPE` 或元数据缓存确认，不要凭记忆猜。

## 4. 扣减模式：已审核单据才扣

错误写法：没有状态过滤，暂存/审核中也扣。

```sql
from T_PRD_FEEDMTRL t1
left join T_PRD_FEEDMTRLDATA t2 on t1.FID = t2.FID
...
-- 缺 where
group by ...
```

正确写法（占位符示意）：

```sql
update t1
set t1.数量 = t1.数量 - isnull(a.SL, 0)
from #汇总表 t1
left join (
    select
        t3.F_CUST_ATTR     as 材料属性,
        t4.FNAME           as 材料名称,
        t4.FSPECIFICATION  as 材料型号,
        t3.F_CUST_MATERIAL as 材质,
        t3.F_CUST_PROCESS  as 工艺,
        t3.F_CUST_SHAPE    as 形状,
        sum(t2a.FACTUALQTY) as SL,
        t2.F_CUST_LENGTH   as 入库长度
    from T_PRD_FEEDMTRL t1
    left join T_PRD_FEEDMTRLDATA t2 on t1.FID = t2.FID
    left join T_PRD_FEEDMTRLDATA_Q t2a on t2.FENTRYID = t2a.FENTRYID
    left join T_BD_MATERIAL t3 on t2.FMATERIALID = t3.FMATERIALID
    left join T_BD_MATERIAL_L t4 on t3.FMATERIALID = t4.FMATERIALID
    where t1.FDOCUMENTSTATUS = 'C'          -- 只扣已审核
    group by t3.F_CUST_ATTR, t4.FNAME, t4.FSPECIFICATION,
             t3.F_CUST_MATERIAL, t3.F_CUST_PROCESS, t3.F_CUST_SHAPE,
             t2.F_CUST_LENGTH
) a on a.材料属性 = t1.材料属性
   and a.材料名称 = t1.材料名称
   and a.材料型号 = t1.材料型号
   and a.材质 = t1.材质
   and left(a.工艺, 1) = left(t1.工艺, 1)    -- “工艺A-1”和“工艺A”按首字符视为同一种
   and isnull(a.形状, '') = isnull(t1.形状, '')  -- NULL = NULL 不成立
   and a.入库长度 = t1.入库长度;
```

### 4.1 匹配字段逐项核对

扣减不生效时，不要只看数量，按维度逐项核对：

| 维度 | 常见差异 |
|---|---|
| 材料属性 | 入库单原值 vs 领料单推导值 |
| 材料名称 | 长料 / 短料 / 锻打料等名称差异 |
| 材料型号 | 规格写法、前后空格、φ/Φ 等符号 |
| 材质 | `40Cr`、`GCr15`、`42CrMo` 等大小写/后缀差异 |
| 材料工艺 | `工艺A` vs `工艺A-1`，用 `left(x,1)` 匹配 |
| 形状 | 可能为 `NULL`，用 `isnull(x,'')` 比较 |
| 长度 | 入库长度若是“总长度/数量”的平均值，必须与领料单长度完全相等 |

### 4.2 扣减后的过滤

```sql
where 材料属性 <> '成品采购' and 入库数量 > 0
```

库存扣到 0 或负数时整行不显示；如果业务要保留 0 行，改成 `>= 0`。

## 5. 反写模式

### 5.1 错误：每次保存都累加

```sql
update t1
set t1.F_CUST_WRITTENQTY = t1.F_CUST_WRITTENQTY + @Qty
```

同一单据重复保存会重复累加，越存越大。

### 5.2 正确：按差额反写

```sql
-- 本次保存先减去上次记录的数量，再加本次数量
update t1
set t1.F_CUST_WRITTENQTY =
    isnull(t1.F_CUST_WRITTENQTY, 0) - isnull(@OldQty, 0) + @NewQty
```

或者在操作插件中先读旧值、算差额，再写回。

## 6. 下推防重复

```sql
-- 排除已经生成过的目标分录
where not exists (
    select 1
    from T_QM_INSPECTBILLENTRY e
    where e.F_CUST_SOURCEBILL = t.F_CUST_SOURCEBILL
      and e.FOperNumber = t.FOperNumber
      and e.F_CUST_BOX = t.F_CUST_BOX
)
```

配套 C# 去重：

```csharp
ids = ids.Distinct().ToList();
```

下推后目标分录只保留需要的行；保存前再校验数量、料框等关键字段。

## 7. MERGE 保存参数

```sql
merge dbo.[参数表] as t
using (select @YearMonth as FYearMonth) as s
on t.FYearMonth = s.FYearMonth
when matched then
    update set
        t.F_CUST_PARAM1 = @Param1,
        t.F_CUST_PARAM2 = @Param2
when not matched then
    insert (FYearMonth, F_CUST_PARAM1, F_CUST_PARAM2, [是否启用])
    values (@YearMonth, @Param1, @Param2, 1);
```

`MERGE` 语句必须以分号结尾。

## 8. 存储过程输出临时表

```sql
alter procedure dbo.MyReport
    @YearMonth nvarchar(20),
    @TableName nvarchar(100)
as
begin
    set nocount on;

    -- 中间计算用临时表
    select ... into #TMP from ...;

    -- 输出到平台分配的临时表名
    declare @sql nvarchar(max);
    set @sql = N'
        select ... into ' + quotename(@TableName) + N'
        from #TMP ...';
    exec sp_executesql @sql;

    drop table #TMP;
end
```

- 表名不能直接参数化，必须 `quotename` 后拼进动态 SQL。
- 动态 SQL 里引用外部临时表 `#TMP` 时，临时表在同一个会话中可见。

## 9. 数值/文本隐式转换（8114 重点）

SQL Server 按数据类型优先级决定表达式类型。`nvarchar` 和 `numeric` 混在一起时，低优先级的 `nvarchar` 会被隐式转成 `numeric`；只要有一个空串或非数字文本，就报：

```text
消息 8114，级别 16，状态 5：从数据类型 nvarchar 转换为 numeric 时出错。
```

### 9.1 `ISNULL(数字列, N'')` 是常见根因

`N''` 会被转成 `numeric`，不是“空字符串”：

```sql
-- 错：第二参数 N'' 被隐式转 numeric
isnull(数字列, N'')

-- 对：先转 nvarchar，再 isnull
isnull(convert(nvarchar(500), 数字列), N'')
```

### 9.2 `UNION ALL` 会把整列统一成最高优先级类型

只要有一个分支的列是 `numeric`，整个 `UNION` 结果列就按 `numeric` 处理，其他分支的空串/文本会转换失败：

```sql
-- 错：各分支类型不一致
select F_CUST_NUM from 表A
union all
select F_CUST_TEXT from 表B

-- 对：每个分支显式统一成 nvarchar
select convert(nvarchar(500), F_CUST_NUM) from 表A
union all
select convert(nvarchar(500), F_CUST_TEXT) from 表B
```

`CASE` 表达式同理：`THEN` / `ELSE` 分支类型不一致时，按优先级统一，数字分支会把文本分支拖进 numeric。每个分支都显式 `convert(nvarchar(500), ...)`。

### 9.3 `ISNUMERIC` 不可靠

`ISNUMERIC` 对 `1e-5`、`1,000`、`+`、`-`、`$` 等会返回 1，但 `CAST/DECIMAL` 仍可能失败。不要用它做转换前的唯一判断。

SQL Server 2008 R2 没有 `TRY_CONVERT`（2012 才引入），用严格字符判断：

```sql
case
    when 值 is null then 0
    when ltrim(rtrim(值)) = '' then 0
    when 值 like '%[^0-9.]%' then 0
    when 值 like '%.%.%' then 0
    when 值 not like '%[0-9]%' then 0
    else cast(值 as decimal(18,6))
end
```

条件含义：非空、只含数字和小数点、最多一个小数点、至少一位数字。`TRY_CONVERT` 可用时优先用它。

### 9.4 外层再兜底

即使内层已经过滤，外层 `CAST` 仍建议再判断一次；数据库里的脏值往往超出预期。C# 侧从 `DynamicObject` 读数值也要 `TryParse`，不要直接 `Convert.ToDecimal`。

## 10. 批号表关联

采购入库、其他出入库等分录的批号列通常存**批号主档 ID**，不是界面上的批号文本：

```sql
select e.FMATERIALID, e.FLOT, l.FNUMBER, l.FNAME
from T_STK_INSTOCKENTRY e
left join T_BD_LOTMASTER l on l.FLOTID = e.FLOT
where e.FLOT <> 0;
```

如果批号文本里编码了业务属性（长度、规格等），优先在 C# 解析文本；需要按历史入库回退时，用「物料 + 批号主档 ID」聚合，并过滤 `FDOCUMENTSTATUS = 'C'`：

```sql
select convert(decimal(18,6),
       sum(e.F_CUST_LENGTH) / nullif(sum(e.FREALQTY), 0)) as 单件长度
from T_STK_INSTOCKENTRY e
inner join T_STK_INSTOCK h on h.FID = e.FID
where e.FMATERIALID = @FMATERIALID
  and e.FLOT = @FLOTID
  and h.FDOCUMENTSTATUS = 'C'
  and isnull(e.FREALQTY, 0) <> 0
having sum(e.FREALQTY) <> 0;
```

## 11. 常见 SQL 坑

| 现象 | 原因 | 修复 |
|---|---|---|
| 已审核单据没扣 | 没加 `FDOCUMENTSTATUS='C'` | 加状态过滤 |
| 状态过滤了仍没扣 | 某个匹配字段值不一致（工艺、形状、长度） | 逐字段对比单据值和库存值 |
| `NULL = NULL` 不匹配 | SQL 三值逻辑 | `isnull(a,'') = isnull(b,'')` |
| SUM 数量翻倍 | JOIN 一对多 | 先聚合再 JOIN，或 `EXISTS` |
| 平均值匹配不上 | 入库长度是 `总长/数量`，有小数 | 用单据实际长度，或改为范围匹配 |
| 8114 nvarchar → numeric | `ISNULL(数字列,N'')`、`UNION`/`CASE` 类型优先级 | 先 `CONVERT(NVARCHAR(500), ...)` 再 `ISNULL`；所有分支统一类型 |
| 数字文本转换失败 | 用了 `ISNUMERIC`，脏值漏过 | 严格字符判断或 `TRY_CONVERT` |
| 批号匹配不上 | 拿文本去比分录表 ID | 关联 `T_BD_LOTMASTER.FLOTID` |
| 参数超过 2100 个 | SQL Server 参数上限 | 每 500~1000 个分批 |
| 报表慢 | 全表扫描、缺索引、`SELECT *` | 列裁剪、建索引、看执行计划 |

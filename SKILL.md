---
name: kingdee-xingkong-development
description: Use when developing or debugging Kingdee K/3 Cloud (金蝶云星空) BOS customizations: bill form plugins, dynamic form plugins, operation service plugins, convert plugins, simple report services, report SQL or stored procedures, field autofill on material or lot selection, lot text parsing, unit weight or unit amount calculations, SQL numeric conversion errors, or when plugin fields, report column order, bill status filtering, push-down duplication, or inventory deduction behave unexpectedly.
---

# 金蝶云星空二开（K/3 Cloud）

## Overview

星空二开由三层组成：BOS 元数据（FormId、字段 Key、实体标识）→ C# 插件（Web 层表单 / App 层操作 / 报表服务）→ SQL Server（单据表、临时表、存储过程）。先判断代码运行在哪一层，再选基类；选错层会出现“界面有效、接口无效”或“字段取不到”。

## 选型表

| 需求 | 基类 | 注册位置 |
|---|---|---|
| 单据界面按钮、字段联动、显隐、保存前提示 | `AbstractBillPlugIn` | 单据 → 表单插件 |
| 弹窗、选单、参数录入、返回值 | `AbstractDynamicFormPlugIn` | 动态表单 → 表单插件 |
| 列表过滤、格式化、行颜色 | `AbstractListPlugIn` | 列表 → 列表插件 |
| 保存/提交/审核/反写，WebAPI 也要生效 | `AbstractOperationServicePlugIn` | 操作 → 服务插件 |
| 下推字段赋值、拆行、防重复 | `AbstractConvertPlugIn` | 转换规则 → 插件 |
| 简单账表取数、表头、列顺序 | `SysReportBaseService` | 账表 → 数据源 |
| 账表双击钻取 | `AbstractSysReportPlugIn` | 账表 → 表单插件 |

## 开发流程

1. 在 BOS 设计器确认：FormId、单据体标识（常为 `FEntity`）、字段 Key、操作标识（Save/Submit/Audit）。
2. 按选型表建 .NET Framework 类库，引用站点 `WebSite\bin` 下的 `Kingdee.BOS.dll`、`Kingdee.BOS.Core.dll`，版本必须与服务器一致。
3. 写插件；类 `public`，加 `[Description]`，需要热更新加 `[HotUpdate]`。
4. 编译 DLL → `WebSite\bin` → BOS 注册插件 → 回收应用程序池。
5. 分别验证界面入口和 WebAPI/下推入口；表单插件管不到的入口必须用操作插件补。

## 三条铁律

1. **界面校验 ≠ 服务端校验**：`AbstractBillPlugIn` 只在界面触发；WebAPI、引入、下推、工作流不会经过。要求全入口生效的规则放 `AbstractOperationServicePlugIn` 或校验器。
2. **字段有三套名字**：字段 Key `FQty`（Model/设计器/WebAPI）、数据库列 `FQTY`（SQL）、实体属性 `Qty`（DynamicObject）。混用会取到 null。
3. **插件无状态**：成员变量不能存当前单据/用户/行号，插件实例会被并发复用。

## 自动带值与联动

- 选物料、批号后带值：在 `DataChanged` 里先判断 `e.Field.Key`，只处理目标字段。
- 只写当前实体确实存在的字段：先 `HasField`，避免一个缺失字段抛异常，导致后面的字段全部不写。
- 批号字段返回 `DynamicObject`，内码是 `obj["Id"]`；分录表批号列存的是批号主档 ID，不是界面文本。
- 批号文本能解析业务属性时优先解析，解析不到再查入库历史；查不到时不要覆盖人工值。
- 派生字段每次按基础值全量重算，不用 `+=`；`BeforeSave` 再统一刷新一遍。
- 表单插件只覆盖界面；WebAPI、下推、引入要走操作服务插件。

## 常用 API

```csharp
// 表单取值/赋值
this.Model.GetValue("FQty", row);
this.Model.SetValue("FQty", 10m, row);
this.View.UpdateView("FQty", row);
this.Model.GetEntryRowCount("FEntity");
this.Model.CreateNewEntryRow("FEntity");
this.Model.DeleteEntryRow("FEntity", row);

// 保存/提交前拦截（已验证写法）
public override void BeforeDoOperation(BeforeDoOperationEventArgs e)
{
    string op = e.Operation.FormOperation.Operation;
    if (op != "Save" && op != "Submit") return;

    this.View.ShowErrMessage("提示内容", "", MessageBoxType.Advise);
    e.Cancel = true;
}

// 操作服务插件
public override void OnPreparePropertys(PreparePropertysEventArgs e)
{
    e.FieldKeys.Add("FBillNo");
    e.FieldKeys.Add("FEntity");
}
foreach (DynamicObject bill in e.DataEntitys) { /* 必须遍历数组 */ }

// SQL
DBUtils.ExecuteDynamicObject(this.Context, sql, paramList: paramList);
DBUtils.Execute(this.Context, sql, paramList: paramList);
```

## 高频坑

| 现象 | 原因 | 修复 |
|---|---|---|
| 账表列顺序在 BOS 拖动后无效 | 列顺序由 `GetReportHeaders` 中 `ListHeader.ColIndex` 决定，设计器拖动不写回 | 父列和叶列都按递增设置 `ColIndex`；`IsUIDesignerColumns=false` 时完全以代码为准 |
| `ShowErrMessage` 编译报错 | `IDynamicFormView` 没有 `(string, MessageBoxType)` 两参重载 | 用 `(msg, "", MessageBoxType.Advise)` |
| `MessageBoxType.Warning` 不存在 | 枚举只有 `Notice/Advise/AskOK/AskYes/Error` | 用 `Advise` |
| 账表插件取自定义参数报错 | `FilterParameter` 没有 `ParameterData/CustomParams` | 从 `SysReportModel.RptParams` 取，并判空 `SysReportModel` |
| 保存校验只在界面生效 | 用了表单插件 | 改操作服务插件/校验器 |
| SQL 扣减已审核单据不生效 | 未过滤 `FDOCUMENTSTATUS='C'`；或匹配字段值不一致（如 `工艺A` vs `工艺A-1`、`NULL=NULL`） | 加状态过滤；逐字段核对维度；用 `LEFT(x,1)`、`ISNULL` 处理 |
| 下推行数/数量翻倍 | 循环里 Push、重复注册、JOIN 一对多、只改 `Qty` 没改 `ActualQty` | 去重、一次 Push、先聚合再 JOIN、四个数量字段同时改 |
| 反写重复累加 | 每次保存都 `+=` | 改为按本次与上次的差额反写 |
| 插件不触发 | DLL 没进 bin、没注册、类不是 public、没回收 IIS | 按部署清单逐项检查 |
| `BeforeSave` 编译报错 / 基类没有该方法 | 单据插件误用 `AbstractDynamicFormPlugIn` | 单据用 `AbstractBillPlugIn`，动态表单用 `BeforeDoOperation` |
| 界面有值、数据库为 0 | 单据没保存、查错单号、旧 DLL 还在跑 | 保存后再查，核对单号与 DLL 版本 |
| 只带出部分字段 | 字段不在当前实体、未加载、某个 `SetValue` 抛异常中断 | 先 `HasField` 再安全读写；确认表头/分录 |
| SQL 报 8114（nvarchar → numeric） | `ISNULL(数字列, N'')`；`UNION`/`CASE` 类型优先级把整列当 numeric | 先 `CONVERT(NVARCHAR(500), 列)` 再 `ISNULL`；所有分支显式统一类型 |
| 批号带不出长度 | 拿批号文本去比分录表 ID；批号文本属性取错 | 用 `obj["Id"]` 关联批号主档；按候选键取文本；先解析再回退 SQL |

## 参考文件

- `references/plugin-development.md`：基类、事件顺序、表单/动态表单/操作/转换插件模板
- `references/autofill-and-lot.md`：选物料/批号自动带值、安全读写字段、批号内码与文本、公式联动
- `references/report-plugin.md`：简单账表、ReportProperty、`ColIndex`、两级表头、分组汇总
- `references/sql-server-patterns.md`：表名规律、单据状态、扣减/反写/下推防重 SQL、NULL 与匹配、隐式类型转换
- `references/troubleshooting.md`：现象 → 原因 → 修复（通用案例，已脱敏）
- `scripts/inspect-api.ps1`：没有 SDK 文档时反射查 Kingdee DLL 的类、属性、方法
- 深入阅读：`E:\aiknowledge\ku1\kingdee-xingkong\金蝶云星空二开详细学习笔记.md`

## 脱敏约定

本技能只收录通用开发模式。示例中的字段、表名、单据号、批号均为占位符，不包含客户完整插件源码、数据库连接、账号口令或真实业务数据。提交到公开仓库前，必须删除客户名称、真实字段清单、自定义表名、完整插件文件和可识别的业务数据；只保留最小可复用的代码片段。

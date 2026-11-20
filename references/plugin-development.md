# 星空插件开发参考

## 1. 运行位置决定基类

| 层 | 插件 | 依赖界面 | WebAPI/下推会触发 |
|---|---|---|---|
| Web | 表单、列表、动态表单 | 是 | 否 |
| App | 操作、转换、定时任务 | 否 | 是 |

- 界面联动、按钮、字段显隐 → 表单插件。
- 保存/提交/审核必须满足的规则、事务内写库 → 操作服务插件。
- 同一规则既要界面提示、又要接口生效：两处都写，或只在操作插件写（界面保存也会走操作插件）。

## 2. 表单插件 AbstractBillPlugIn

命名空间：`Kingdee.BOS.Core.Bill.PlugIn`

### 2.1 事件顺序

```text
OnInitialize → CreateNewData → AfterCreateNewData → AfterBindData
→ DataChanged / BeforeUpdateValue / BarItemClick / EntryBarItemClick / BeforeF7Select
→ BeforeDoOperation → BeforeSave → 保存 → AfterSave → AfterDoOperation
```

| 事件 | 典型用途 |
|---|---|
| `AfterBindData` | 数据绑定完成后设默认值、改控件显隐、锁定字段 |
| `DataChanged` | 字段值变化后联动计算，必须判断 `e.Field.Key` |
| `BeforeUpdateValue` | 值写入前校验，`e.Cancel = true` 拦截 |
| `BarItemClick` | 工具栏/按钮点击，匹配 `e.BarItemKey` |
| `BeforeDoOperation` | Save/Submit/Audit 等操作执行前，按操作标识拦截 |
| `BeforeSave` | 界面保存前，`e.Cancel = true` 拦截 |
| `AfterSave` | 保存后处理，不要在这里写关键事务 |

### 2.2 取值/赋值

```csharp
object v = this.Model.GetValue("FQty", row);       // 单据体
this.Model.SetValue("FQty", 10m, row);
this.View.UpdateView("FQty", row);                 // SetValue 后刷新界面

// 基础资料取值：返回 DynamicObject，取内码和显示值
DynamicObject material = this.Model.GetValue("FMaterialId", row) as DynamicObject;
object id = material == null ? null : material["Id"];
string name = material == null ? "" : Convert.ToString(material["Name"]);
```

- 字段 Key 用 BOS 字段标识（`FQty`），不是数据库列（`FQTY`），也不是属性名（`Qty`）。
- `SetValue` 不会自动触发值更新服务；需要触发时用 `this.View.InvokeFieldUpdateService("FQty", row)`。

### 2.3 单据体

```csharp
int count = this.Model.GetEntryRowCount("FEntity");
this.Model.CreateNewEntryRow("FEntity");
this.Model.CopyEntryRow("FEntity", srcRow, true);
this.Model.DeleteEntryRow("FEntity", row);
object pk = this.Model.GetEntryPKValue("FEntity", row);
```

### 2.4 保存/提交前校验模板

```csharp
using System;
using System.Collections.Generic;
using System.ComponentModel;
using Kingdee.BOS.Core.Bill.PlugIn;
using Kingdee.BOS.Core.DynamicForm;
using Kingdee.BOS.Core.DynamicForm.PlugIn.Args;

namespace XX.K3.PlugIn
{
    [Description("保存前校验")]
    public class SaveValidator : AbstractBillPlugIn
    {
        private const string EntityKey = "FEntity";

        public override void BeforeDoOperation(BeforeDoOperationEventArgs e)
        {
            base.BeforeDoOperation(e);

            if (e.Operation == null || e.Operation.FormOperation == null)
            {
                return;
            }

            string op = e.Operation.FormOperation.Operation;
            if (!string.Equals(op, "Save", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(op, "Submit", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            int rowCount = this.Model.GetEntryRowCount(EntityKey);
            for (int i = 0; i < rowCount; i++)
            {
                decimal qty = ToDecimal(this.Model.GetValue("FQty", i));
                if (qty < 0)
                {
                    // 注意：必须用三参重载，IDynamicFormView 没有两参重载
                    this.View.ShowErrMessage("第 " + (i + 1) + " 行数量不能小于 0。", "", MessageBoxType.Advise);
                    e.Cancel = true;
                    return;
                }
            }
        }

        private static decimal ToDecimal(object value)
        {
            if (value == null || value == DBNull.Value) return 0m;
            decimal result;
            return decimal.TryParse(value.ToString(), out result) ? result : 0m;
        }
    }
}
```

### 2.5 提示 API

```csharp
this.View.ShowMessage("提示");
this.View.ShowErrMessage("错误", "", MessageBoxType.Advise);
this.View.ShowErrMessage("错误", "", MessageBoxType.Error);
// MessageBoxType 只有：Notice、Advise、AskOK、AskYes、Error（没有 Warning）
```

### 2.6 表单插件坑

1. `ShowErrMessage` 两参重载不存在，编译报 CS1501。
2. `MessageBoxType.Warning` 不存在，用 `Advise`。
3. `DataChanged` 不判断 `e.Field.Key`，任何字段刷新都进事件，界面卡。
4. `SetValue` 后不 `UpdateView`，前端看不到。
5. 在 `OnInitialize` 改控件显隐，数据未绑定可能无效，放 `AfterBindData`。
6. 在表单插件做关键写库：表单插件没有操作事务，放操作插件。
7. 成员变量存当前单据，并发串数据。
8. 用字段标识去 `DynamicObject["FQty"]` 取值：应使用属性名 `Qty`。
9. `BeforeSave(BeforeSaveEventArgs e)` 在 `AbstractBillPlugIn` 上；动态表单没有这个方法，用 `BeforeDoOperation`。参数命名空间是 `Kingdee.BOS.Core.Bill.PlugIn.Args`。
10. `SetValue` 写入不存在的字段会抛异常，导致同一方法里后面的字段全部不写；先 `HasField` 再写。

### 2.7 自动带值与安全写入

选物料、批号后联动带值，常用三个事件：`DataChanged` 负责即时联动，`BeforeSave` 负责落库前统一刷新。

```csharp
public override void DataChanged(DataChangedEventArgs e)
{
    base.DataChanged(e);

    string key = e.Field == null ? "" : e.Field.Key;
    if (string.Equals(key, "FMaterialId", StringComparison.OrdinalIgnoreCase))
    {
        FillRow(e.Row);
    }
    else if (string.Equals(key, "FLot", StringComparison.OrdinalIgnoreCase))
    {
        FillLot(e.Row);
        RecalcRow(e.Row);
    }
    else if (string.Equals(key, "FQty", StringComparison.OrdinalIgnoreCase)
          || string.Equals(key, "F_CUST_LENGTH", StringComparison.OrdinalIgnoreCase))
    {
        RecalcRow(e.Row);
    }
}
```

字段可能没加在分录上，直接 `SetValue` 会抛异常，后面的字段全部不写。先判断字段是否存在：

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

`SetValue` 后必须 `UpdateView`，否则界面不刷新。派生字段每次全量重算，不要 `+=`；`SetValue` 可能再次触发 `DataChanged`，计算要幂等或加防递归标志。

### 2.8 批号字段

批号字段返回 `DynamicObject`，内码取 `obj["Id"]`；分录表批号列存的是批号主档 ID，不是界面文本。批号文本可能承载长度等业务属性：有稳定分隔符时先解析文本，解析不到再按「物料 + 批号主档 ID」查入库历史；查不到不要覆盖人工值。完整模式见 `references/autofill-and-lot.md`。

## 3. 动态表单插件 AbstractDynamicFormPlugIn

命名空间：`Kingdee.BOS.Core.DynamicForm.PlugIn`

```csharp
using System;
using System.ComponentModel;
using Kingdee.BOS.Core.DynamicForm;
using Kingdee.BOS.Core.DynamicForm.PlugIn;
using Kingdee.BOS.Core.DynamicForm.PlugIn.Args;

namespace XX.K3.PlugIn
{
    [Description("选料弹窗")]
    public class MaterialSelectPlugIn : AbstractDynamicFormPlugIn
    {
        public override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);

            // 父页面传参
            object param = this.View.OpenParameter.GetCustomParameter("FMaterialId");
            if (param != null)
            {
                this.Model.SetValue("FMaterialId", param);
            }
        }

        public override void BarItemClick(BarItemClickEventArgs e)
        {
            base.BarItemClick(e);

            if (!string.Equals(e.BarItemKey, "tbOK", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            // 返回父页面（按版本选择可用重载）
            this.View.ReturnToParentWindow(this.Model.GetValue("FMaterialId"));
            this.View.Close();
        }
    }
}
```

打开动态表单并传参：

```csharp
DynamicFormShowParameter param = new DynamicFormShowParameter();
param.FormId = "XX_MaterialSelect";
param.CustomParams.Add("FMaterialId", materialId);
this.View.ShowForm(param);
```

坑：

1. 动态表单默认没有业务表，不能当单据保存，要自己调服务。
2. 父页面用 `CustomParams.Add(key, value)`，子页面用 `OpenParameter.GetCustomParameter(key)`，Key 必须一致。
3. 只在界面做权限判断，接口仍可调用，服务端要再校验。

## 4. 操作服务插件 AbstractOperationServicePlugIn

命名空间：`Kingdee.BOS.Core.DynamicForm.PlugIn`

### 4.1 事件顺序

```text
OnPreparePropertys
→ OnAddValidators
→ BeforeExecuteOperationTransaction
→ BeginOperationTransaction
→ EndOperationTransaction
→ AfterExecuteOperationTransaction
```

| 事件 | 能做什么 |
|---|---|
| `OnPreparePropertys` | 预加载字段，**用到的字段都要 Add** |
| `OnAddValidators` | 注册校验器，校验失败进 `ValidationErrors` |
| `BeforeExecuteOperationTransaction` | 事务前校验，只读不写 |
| `BeginOperationTransaction` | 事务开始，可写库 |
| `EndOperationTransaction` | 事务内业务处理，抛异常会回滚 |
| `AfterExecuteOperationTransaction` | 事务提交后：日志、通知、异步 |

### 4.2 模板

```csharp
using System;
using System.ComponentModel;
using Kingdee.BOS.Core.DynamicForm.PlugIn;
using Kingdee.BOS.Core.DynamicForm.PlugIn.Args;
using Kingdee.BOS.Orm.DataEntity;

namespace XX.K3.PlugIn
{
    [Description("审核后处理")]
    public class AuditPlugIn : AbstractOperationServicePlugIn
    {
        public override void OnPreparePropertys(PreparePropertysEventArgs e)
        {
            base.OnPreparePropertys(e);
            e.FieldKeys.Add("FBillNo");
            e.FieldKeys.Add("FEntity");
            e.FieldKeys.Add("FQty");
        }

        public override void EndOperationTransaction(EndOperationTransactionArgs e)
        {
            base.EndOperationTransaction(e);

            if (!string.Equals(this.FormOperation.Operation, "Audit",
                StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            // e.DataEntitys 是数组，必须遍历所有单据
            foreach (DynamicObject bill in e.DataEntitys)
            {
                string billNo = Convert.ToString(bill["BillNo"]);
                DynamicObjectCollection entries =
                    bill["Entity"] as DynamicObjectCollection;

                if (entries == null || entries.Count == 0)
                {
                    continue;
                }

                foreach (DynamicObject entry in entries)
                {
                    decimal qty = Convert.ToDecimal(entry["Qty"]);
                    // 事务内业务处理
                }
            }
        }
    }
}
```

### 4.3 校验器

```csharp
public class QtyValidator : AbstractValidator
{
    public override void Validate(ExtendedDataEntity[] dataEntities, ValidateContext validateContext, Context ctx)
    {
        foreach (ExtendedDataEntity data in dataEntities)
        {
            decimal qty = Convert.ToDecimal(data.DataEntity["Qty"]);
            if (qty <= 0)
            {
                validateContext.AddError(data,
                    new ValidationErrorInfo("FQty", "数量必须大于 0", data.DataEntity["Id"].ToString(), "FEntity", 0));
            }
        }
    }
}
```

- 校验器必须 `AddError`，只 `throw` 用户看不到友好提示。
- 校验器要处理批量：`dataEntities` 是数组。

### 4.4 操作插件坑

1. `OnPreparePropertys` 漏加字段，运行时报“实体类型中不存在名为 xxx 的属性”。
2. 只处理 `e.DataEntitys[0]`，漏掉批量单据。
3. 事务内做远程调用、文件、消息，超时锁表。
4. 循环里保存/下推，行数被放大。
5. 成员变量存当前单据。
6. 校验器只 throw 不 `AddError`。

## 5. 转换插件 AbstractConvertPlugIn

命名空间：`Kingdee.BOS.Core.Metadata.ConvertElement.PlugIn`

```csharp
using Kingdee.BOS.Core.Metadata.ConvertElement.PlugIn;
using Kingdee.BOS.Core.Metadata.ConvertElement.PlugIn.Args;
using Kingdee.BOS.Orm.DataEntity;
```

事件顺序：

```text
OnInitVariable → OnQueryBuilderParemeter → OnGetSourceData → OnBeforeGroupBy
→ OnCreateTarget → OnBeforeFieldMapping → OnFieldMapping → OnAfterFieldMapping
→ OnCreateLink → OnAfterCreateLink → AfterConvert
```

最常用 `AfterConvert`：

```csharp
public override void AfterConvert(AfterConvertEventArgs e)
{
    base.AfterConvert(e);

    var rows = e.Result.FindByEntityKey("FEntity");
    foreach (var row in rows)
    {
        DynamicObject target = row.DataEntity;
        target["Qty"] = 1m;
        target["ActualQty"] = 1m;
        target["BaseQty"] = 1m;
        target["BaseActualQty"] = 1m;   // 四个数量字段要一起改
    }
}
```

下推防重复要点：

1. 选中行 ID 先 `Distinct()`。
2. 目标分录按源单分录去重。
3. 用 `NOT EXISTS` 排除已生成的目标分录。
4. 目标分录只保留需要的行，不要一次带全部。
5. 数量、料框等关键字段在保存前再校验一次。
6. 先聚合再 JOIN，避免一对多把数量放大。

## 6. 数据访问

```csharp
// 数据包（数据实体）
DynamicObject bill = e.DataEntitys[0];
string billNo = Convert.ToString(bill["BillNo"]);      // 属性名，不是 Key
DynamicObjectCollection entries = bill["Entity"] as DynamicObjectCollection;

// ORM
BusinessDataServiceHelper.LoadSingle(this.Context, id, type);
BusinessDataServiceHelper.Load(this.Context, ids, type);

// SQL（paramList 是命名参数，保留写法）
List<SqlParam> paramList = new List<SqlParam>();
paramList.Add(new SqlParam("@FID", KDDbType.Int64, fid));
DynamicObjectCollection rows = DBUtils.ExecuteDynamicObject(
    this.Context, sql, paramList: paramList);
```

- `DynamicObject` 用属性名：`bill["BillNo"]`、`entry["Qty"]`。
- `Model.GetValue` 用字段 Key：`"FBillNo"`、`"FQty"`。
- SQL 里用数据库列：`FBILLNO`、`FQTY`。

## 7. 部署与调试

1. 编译 DLL，复制到 `WebSite\bin`。
2. BOS 注册插件：表单/列表/操作/转换/账表对应位置。
3. 回收应用程序池或 `iisreset`。
4. VS 附加 `w3wp.exe`；多站点时用 `appcmd list wp` 找对应 PID。
5. 断点不命中按顺序查：DLL 是否进 bin、插件是否注册、类是否 public、是否回收 IIS、是否附加到正确进程、SDK 版本是否一致。

热更新（仅开发环境）：

- 插件加 `[HotUpdate]`。
- `WebSite\App_Data\Common.config` 加 `IsEnablePlugInHotUpdate=true`。
- 建 `WebSite\tempfilePath\PluginLoaderTempBin` 并给 IIS 用户权限。

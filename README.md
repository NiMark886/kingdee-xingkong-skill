# 金蝶云星空（K/3 Cloud）开发技能

## 安装

把整个文件夹复制到 Claude Code 的技能目录：

```text
C:\Users\Administrator\.claude\skills\kingdee-xingkong-development\
```

最终路径应为：

```text
...\.claude\skills\kingdee-xingkong-development\SKILL.md
```

重启 Claude Code 会话后生效。

## 触发方式

在对话里提到以下内容时会自动匹配：

- 金蝶云星空 / K3 Cloud / BOS 插件
- 表单插件、动态表单插件、操作服务插件、转换插件、简单账表
- 下推、反写、单据转换、关联数量
- 星空存储过程、即时库存、生产领料扣减、材料工艺匹配
- 选物料/批号自动带值、按批号带出长度、公式联动、保存前刷新
- 字段 Key、账表列顺序、`ShowErrMessage`、`MessageBoxType`、SQL 8114 类型转换

## 文件结构

| 文件 | 内容 |
|---|---|
| `SKILL.md` | 主入口：选型表、开发流程、三条铁律、自动带值、常用 API、高频坑 |
| `references/plugin-development.md` | 表单/动态表单/操作/转换插件事件与模板 |
| `references/autofill-and-lot.md` | 选物料/批号自动带值、安全读写字段、批号内码与文本、公式联动 |
| `references/report-plugin.md` | 简单账表、`ReportProperty`、`ListHeader.ColIndex`、两级表头、分组汇总 |
| `references/sql-server-patterns.md` | 表名规律、单据状态、扣减/反写/下推防重 SQL、隐式类型转换 |
| `references/troubleshooting.md` | 现象 → 原因 → 修复，通用案例（已脱敏） |
| `scripts/inspect-api.ps1` | 反射查看 Kingdee DLL 的类、属性、方法 |

## 脱敏与信息安全

本仓库是通用开发技能，不是项目源码仓库：

- 不收录客户的完整插件文件、存储过程全文、数据库连接、账号口令。
- 示例字段统一用 `F_CUST_xxx`，自定义表统一用占位说明，不列真实表名。
- 不写客户名称、真实单据号、批号、供应商、物料编码等可识别信息。
- 提交前检查 `git diff`，确认没有把项目文件整段复制进来。

如果历史提交里已经包含敏感内容，仅修改当前文件不会删除历史；需要把仓库设为私有，或重写历史后强制推送，或删除仓库重建。

## 验证

- 账表列顺序、`ShowErrMessage` 重载、`MessageBoxType` 枚举、`ListHeader.ColIndex`、`IRptParams` 成员均已用本地 `Kingdee.BOS.Core.dll` / `Kingdee.BOS.Contracts.dll` 反射核对。
- 技能经过“无技能基线测试 → 写技能 → 读技能复测”流程，针对基线答错的三处（`ReportHeader.ColIndex`、生产领料单表名、`NULL`/工艺匹配）做了明确纠正。

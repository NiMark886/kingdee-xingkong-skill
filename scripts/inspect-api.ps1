# 反射查看 Kingdee DLL 的类型、属性、方法、字段。
# 类型不在默认 Kingdee.BOS.Core.dll 时，用 -AssemblyPath 指定：
#   Kingdee.BOS.Contracts.dll   -> SysReportBaseService
#   Kingdee.BOS.App.dll         -> 部分服务端服务
# 示例：
#   .\inspect-api.ps1 -TypeName Kingdee.BOS.Core.List.ListHeader -Filter ColIndex
#   .\inspect-api.ps1 -TypeName Kingdee.BOS.Contracts.Report.SysReportBaseService `
#       -AssemblyPath 'C:\Program Files (x86)\Kingdee\K3Cloud\DeskClient\K3CloudClient\Kingdee.BOS.Contracts.dll'
param(
    [Parameter(Mandatory = $true)]
    [string]$TypeName,

    [string]$AssemblyPath = 'C:\Program Files (x86)\Kingdee\K3Cloud\DeskClient\K3CloudClient\Kingdee.BOS.Core.dll',

    [string]$Filter = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $AssemblyPath)) {
    Write-Output "assembly not found: $AssemblyPath"
    exit 1
}

try {
    $assembly = [Reflection.Assembly]::LoadFrom($AssemblyPath)
}
catch {
    Write-Output "load failed: $($_.Exception.Message)"
    exit 1
}

$type = $assembly.GetType($TypeName)
if ($null -eq $type) {
    Write-Output "type not found: $TypeName"
    Write-Output 'try searching by simple name:'

    try {
        $types = $assembly.GetTypes()
    }
    catch [Reflection.ReflectionTypeLoadException] {
        $types = $_.Exception.Types | Where-Object { $null -ne $_ }
    }

    $types |
        Where-Object { $_.Name -like "*$TypeName*" } |
        Select-Object -First 30 |
        ForEach-Object { $_.FullName }
    exit 1
}

Write-Output "=== $($type.FullName) ==="
Write-Output "BaseType: $($type.BaseType)"
Write-Output ''

Write-Output '-- properties --'
$type.GetProperties([Reflection.BindingFlags]'Public,Instance,Static,DeclaredOnly') |
    Where-Object { [string]::IsNullOrEmpty($Filter) -or $_.Name -like "*$Filter*" } |
    ForEach-Object { '{0} {1}' -f $_.PropertyType.Name, $_.Name }

Write-Output ''
Write-Output '-- methods --'
$type.GetMethods([Reflection.BindingFlags]'Public,Instance,Static,DeclaredOnly') |
    Where-Object { [string]::IsNullOrEmpty($Filter) -or $_.Name -like "*$Filter*" } |
    ForEach-Object { $_.ToString() } |
    Sort-Object -Unique

Write-Output ''
Write-Output '-- fields --'
$type.GetFields([Reflection.BindingFlags]'Public,Instance,Static,DeclaredOnly') |
    Where-Object { [string]::IsNullOrEmpty($Filter) -or $_.Name -like "*$Filter*" } |
    ForEach-Object { '{0} {1}' -f $_.FieldType.Name, $_.Name }

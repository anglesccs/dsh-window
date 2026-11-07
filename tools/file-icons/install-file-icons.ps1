# 给 Office 家族扩展名装本地图标（用户级 HKCU，不需要管理员）。
#
# 做法：
#   1. 备份每个扩展名改前的状态到 %LOCALAPPDATA%\DshFileIcons\backup-<时间戳>.json
#   2. 建三个 ProgID（DshDocFile / DshXlsFile / DshPptFile）：
#      DefaultIcon 指向本地 ico，shell\open\command 走 OpenWith.exe（保住「打开方式」选择器）
#   3. 逐个扩展名：没有 UserChoice 就改扩展名默认值；
#      有 UserChoice 就改那个 ProgId 的 DefaultIcon（不动 UserChoice 本身，它带 Hash 保护）
#   4. SHChangeNotify(SHCNE_ASSOCCHANGED) 刷图标缓存
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\file-icons\install-file-icons.ps1 [-IconDir <dir>] [-Uninstall]
#
# 退出码：0 成功 / 1 失败。只用注册表 cmdlet，不碰 HKCR/HKLM。

param(
    [string]$IconDir = '',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
}

$script:Here = $PSScriptRoot
if (-not $script:Here) { $script:Here = (Get-Location).Path }
if (-not $IconDir) { $IconDir = $script:Here }
$script:IconDir = [System.IO.Path]::GetFullPath($IconDir)
if ($script:IconDir.Length -gt 3 -and $script:IconDir.EndsWith('\')) {
    $script:IconDir = $script:IconDir.Substring(0, $script:IconDir.Length - 1)
}
$script:IconDirLower = $script:IconDir.ToLowerInvariant()

$script:ClassesRoot = 'HKCU:\Software\Classes'
$script:FileExtsRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
$script:BackupDir = Join-Path $env:LOCALAPPDATA 'DshFileIcons'
$script:CommandLine = '"%SystemRoot%\system32\OpenWith.exe" "%1"'

# ---------------------------------------------------------------- 一张表（22 条）
# 扩展名 → 图标文件。安装、备份、卸载都只读这张表，别处不再出现扩展名。
$script:ExtensionMap = [ordered]@{
    # Word
    '.doc'  = 'doc.ico'
    '.docx' = 'doc.ico'
    '.docm' = 'doc.ico'
    '.dot'  = 'doc.ico'
    '.dotx' = 'doc.ico'
    '.dotm' = 'doc.ico'
    # Excel
    '.xls'  = 'xls.ico'
    '.xlsx' = 'xls.ico'
    '.xlsm' = 'xls.ico'
    '.xlsb' = 'xls.ico'
    '.xlt'  = 'xls.ico'
    '.xltx' = 'xls.ico'
    '.xltm' = 'xls.ico'
    # PowerPoint
    '.ppt'  = 'ppt.ico'
    '.pptx' = 'ppt.ico'
    '.pptm' = 'ppt.ico'
    '.pps'  = 'ppt.ico'
    '.ppsx' = 'ppt.ico'
    '.ppsm' = 'ppt.ico'
    '.pot'  = 'ppt.ico'
    '.potx' = 'ppt.ico'
    '.potm' = 'ppt.ico'
}

# 图标文件 → ProgID / 显示名。
$script:ProgIdMap = [ordered]@{
    'doc.ico' = @{ ProgId = 'DshDocFile'; Label = 'Word 文档（无 Office）' }
    'xls.ico' = @{ ProgId = 'DshXlsFile'; Label = 'Excel 工作表（无 Office）' }
    'ppt.ico' = @{ ProgId = 'DshPptFile'; Label = 'PowerPoint 演示文稿（无 Office）' }
}

$script:OwnProgIds = @('DshDocFile', 'DshXlsFile', 'DshPptFile')

# ---------------------------------------------------------------- 注册表小工具
function Test-RegKey([string]$Path) {
    return (Test-Path -LiteralPath $Path)
}

function Get-RegDefault([string]$Path) {
    # 返回 @{ Exists = <键是否存在>; HasValue = <默认值是否已设置>; Value = <默认值> }
    $result = @{ Exists = $false; HasValue = $false; Value = '' }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $result.Exists = $true
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $raw = $key.GetValue('')
        if ($null -ne $raw) {
            $result.HasValue = $true
            $result.Value = [string]$raw
        }
    } catch {
        # 读不到就按「键存在但没有默认值」处理。
    }
    return $result
}

function Set-RegDefault([string]$Path, [string]$Value) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    # 默认值（无名值）：provider 里叫 '(default)'；个别版本不认，就退回 Set-Item。
    try {
        Set-ItemProperty -LiteralPath $Path -Name '(default)' -Value $Value -ErrorAction Stop
    } catch {
        Set-Item -LiteralPath $Path -Value $Value
    }
}

function Clear-RegDefault([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $state = Get-RegDefault $Path
    if (-not $state.HasValue) { return }
    try {
        Remove-ItemProperty -LiteralPath $Path -Name '(default)' -ErrorAction Stop
    } catch {
        Set-RegDefault $Path ''
    }
}

function Get-ExtKey([string]$Extension) {
    return $script:ClassesRoot + '\' + $Extension
}

function Get-ProgIdKey([string]$ProgId) {
    return $script:ClassesRoot + '\' + $ProgId
}

function Get-DefaultIconKey([string]$ProgId) {
    return $script:ClassesRoot + '\' + $ProgId + '\DefaultIcon'
}

function Get-UserChoiceKey([string]$Extension) {
    return $script:FileExtsRoot + '\' + $Extension + '\UserChoice'
}

function Get-UserChoiceProgId([string]$Extension) {
    # UserChoice 在 HKCU\...\Explorer\FileExts\<ext>\UserChoice，值名是 ProgId。
    $path = Get-UserChoiceKey $Extension
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $progId = $item.GetValue('ProgId')
    } catch {
        return ''
    }
    if ($null -eq $progId) { return '' }
    $text = [string]$progId
    if ($text.Trim().Length -eq 0) { return '' }
    return $text.Trim()
}

function Test-IsOurIconValue([string]$Value) {
    if ($null -eq $Value) { return $false }
    if ($Value.Length -eq 0) { return $false }
    return $Value.ToLowerInvariant().StartsWith($script:IconDirLower + '\')
}

function Test-IsOurProgId([string]$Value) {
    if ($null -eq $Value) { return $false }
    return ($script:OwnProgIds -contains $Value)
}

function Get-Entry([object[]]$List, [string]$Name, [string]$Value) {
    # 备份是数组，按名字字段线性查找（比把 '.doc' 当 JSON 属性名可靠）。
    if ($null -eq $List) { return $null }
    foreach ($item in @($List)) {
        if ($null -eq $item) { continue }
        if ([string](Get-Field $item $Name) -eq $Value) { return $item }
    }
    return $null
}

function Get-Field($Item, [string]$Name) {
    if ($null -eq $Item) { return $null }
    # 内存里是 Hashtable（本次运行），读回来是 PSCustomObject（备份 JSON），两种都支持。
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }
    $prop = $Item.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Format-RegState($State) {
    # { Exists, HasValue, Value } 三元组 → 便于打印的文本。
    if ($null -eq $State) { return '<none>' }
    if ((Get-Field $State 'Exists') -ne $true) { return '<key missing>' }
    if ((Get-Field $State 'HasValue') -ne $true) { return '<empty>' }
    $value = [string](Get-Field $State 'Value')
    if ($value.Length -eq 0) { return '<empty>' }
    return $value
}

# ---------------------------------------------------------------- 备份
function New-RegState([string]$Path) {
    return (Get-RegDefault $Path)
}

function Merge-PriorState($Fresh, $Prior, [string]$Kind, [string]$Expected = '') {
    # 重复安装时「改前状态」已经是我们的值。此时沿用上一份备份里的原始状态，
    # 否则卸载会把安装态当原始态还原，图标永远清不掉。
    if ($null -eq $Prior) { return $Fresh }
    if ((Get-Field $Fresh 'HasValue') -ne $true) { return $Fresh }
    $value = [string](Get-Field $Fresh 'Value')
    if ($value.Length -eq 0) { return $Fresh }

    $isOurs = $false
    if ($Kind -eq 'exact') {
        $isOurs = ($value -eq $Expected)
    } elseif ($Kind -eq 'icon') {
        $isOurs = Test-IsOurIconValue $value
    } elseif ($Kind -eq 'progid') {
        $isOurs = Test-IsOurProgId $value
    } else {
        $isOurs = ($value -eq $script:CommandLine)
    }
    if (-not $isOurs) { return $Fresh }
    return $Prior
}

function New-BackupRecord($PrevRecord) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $progIdStates = @()
    $extStates = @()

    foreach ($progId in $script:OwnProgIds) {
        $key = Get-ProgIdKey $progId
        $iconKey = Get-DefaultIconKey $progId
        $cmdKey = $key + '\shell\open\command'
        $label = ''
        foreach ($icoName in $script:ProgIdMap.Keys) {
            if ($script:ProgIdMap[$icoName].ProgId -eq $progId) {
                $label = $script:ProgIdMap[$icoName].Label
                break
            }
        }

        $prev = $null
        if ($PrevRecord) { $prev = Get-Entry (Get-Field $PrevRecord 'progIds') 'progId' $progId }

        $freshDefault = New-RegState $key
        $freshIcon = New-RegState $iconKey
        $freshCommand = New-RegState $cmdKey
        $existed = (Test-RegKey $key)
        $perceivedExists = $false
        $perceivedType = ''

        if ($existed) {
            $item = Get-Item -LiteralPath $key
            if (@($item.GetValueNames()) -contains 'PerceivedType') {
                $perceivedExists = $true
                $perceivedType = [string]$item.GetValue('PerceivedType')
            }
        }

        if ($prev) {
            $freshDefault = Merge-PriorState $freshDefault (Get-Field $prev 'defaultValue') 'exact' $label
            $freshIcon = Merge-PriorState $freshIcon (Get-Field $prev 'defaultIcon') 'icon'
            $freshCommand = Merge-PriorState $freshCommand (Get-Field $prev 'command') 'command'
            if ((Get-Field $prev 'existed') -eq $false) {
                # 上一次就是我们建的：仍记成「原本不存在」，卸载才删得掉。
                $existed = $false
                $perceivedExists = $false
                $perceivedType = ''
            }
        }

        $progIdStates += @{
            progId          = $progId
            label           = $label
            existed         = $existed
            defaultValue    = $freshDefault
            defaultIcon     = $freshIcon
            command         = $freshCommand
            perceivedExists = $perceivedExists
            perceivedType   = $perceivedType
        }
    }

    foreach ($ext in $script:ExtensionMap.Keys) {
        $extKey = Get-ExtKey $ext
        $userChoice = Get-UserChoiceProgId $ext
        if ($userChoice.Length -gt 0) {
            $targetProgId = $userChoice
        } else {
            $targetProgId = $script:ProgIdMap[$script:ExtensionMap[$ext]].ProgId
        }
        $iconKey = Get-DefaultIconKey $targetProgId

        $prev = $null
        if ($PrevRecord) { $prev = Get-Entry (Get-Field $PrevRecord 'extensions') 'ext' $ext }

        $freshExtDefault = New-RegState $extKey
        $freshIcon = New-RegState $iconKey
        $iconParentExisted = (Test-RegKey (Get-ProgIdKey $targetProgId))

        if ($prev) {
            $freshExtDefault = Merge-PriorState $freshExtDefault (Get-Field $prev 'extensionDefault') 'progid'
            $freshIcon = Merge-PriorState $freshIcon (Get-Field $prev 'defaultIcon') 'icon'
            if ((Get-Field $prev 'iconParentExisted') -eq $false) {
                $iconParentExisted = $false
            }
        }

        $extStates += @{
            ext               = $ext
            extensionDefault  = $freshExtDefault
            userChoiceProgId  = $userChoice
            iconProgId        = $targetProgId
            iconKey           = $iconKey
            iconParentKey     = (Get-ProgIdKey $targetProgId)
            iconParentExisted = $iconParentExisted
            defaultIcon       = $freshIcon
        }
    }

    $record = @{
        schema     = 1
        created    = (Get-Date).ToString('o')
        iconDir    = $script:IconDir
        progIds    = $progIdStates
        extensions = $extStates
    }
    return @{ Stamp = $stamp; Record = $record }
}

function Save-Backup($Backup) {
    if (-not (Test-Path -LiteralPath $script:BackupDir)) {
        New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
    }
    $file = Join-Path $script:BackupDir ('backup-' + $Backup.Stamp + '.json')
    $json = $Backup.Record | ConvertTo-Json -Depth 8
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
    [System.IO.File]::WriteAllText($file, $json, $utf8)
    return $file
}

function Get-LatestBackup {
    if (-not (Test-Path -LiteralPath $script:BackupDir)) { return $null }
    $files = @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'backup-*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property Name)
    if ($files.Count -eq 0) { return $null }
    $file = $files[$files.Count - 1]
    $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    return @{ Path = $file.FullName; Record = ($raw | ConvertFrom-Json) }
}

# ---------------------------------------------------------------- 图标缓存刷新
if (-not ('DshFileIconShell' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DshFileIconShell
{
    public const int SHCNE_ASSOCCHANGED = 0x08000000;
    public const uint SHCNF_IDLIST = 0x0000;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

    public static void Refresh()
    {
        SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, IntPtr.Zero, IntPtr.Zero);
    }
}
'@ | Out-Null
}

function Invoke-ShellRefresh {
    [DshFileIconShell]::Refresh()
}

# ---------------------------------------------------------------- 安装
function Invoke-Install {
    foreach ($icoName in @($script:ExtensionMap.Values | Sort-Object -Unique)) {
        $icoPath = Join-Path $script:IconDir $icoName
        if (-not (Test-Path -LiteralPath $icoPath)) {
            throw ("icon not found: " + $icoPath + " (先跑 generate-icons.ps1)")
        }
    }

    $prior = Get-LatestBackup
    $priorRecord = $null
    if ($prior) { $priorRecord = $prior.Record }
    $backup = New-BackupRecord $priorRecord
    $backupFile = Save-Backup $backup
    Write-Host ("backup  " + $backupFile)

    # 1) 三个 ProgID
    foreach ($icoName in $script:ProgIdMap.Keys) {
        $meta = $script:ProgIdMap[$icoName]
        $key = Get-ProgIdKey $meta.ProgId
        $icoValue = (Join-Path $script:IconDir $icoName) + ',0'
        New-Item -Path $key -Force | Out-Null
        Set-RegDefault $key $meta.Label
        Set-RegDefault (Get-DefaultIconKey $meta.ProgId) $icoValue
        $cmdKey = $key + '\shell\open\command'
        New-Item -Path $cmdKey -Force | Out-Null
        Set-RegDefault $cmdKey $script:CommandLine
        Set-ItemProperty -LiteralPath $key -Name 'PerceivedType' -Value 'document'
        Write-Host ("progid  {0}  {1}  -> {2}" -f $meta.ProgId, $meta.Label, $icoValue)
    }

    # 2) 22 个扩展名
    $direct = 0
    $viaChoice = 0
    $skipped = 0
    foreach ($ext in $script:ExtensionMap.Keys) {
        $icoValue = (Join-Path $script:IconDir $script:ExtensionMap[$ext]) + ',0'
        $extKey = Get-ExtKey $ext
        $userChoice = Get-UserChoiceProgId $ext

        if (-not (Test-RegKey (Get-UserChoiceKey $ext))) {
            $before = Get-RegDefault $extKey
            $progId = $script:ProgIdMap[$script:ExtensionMap[$ext]].ProgId
            New-Item -Path $extKey -Force | Out-Null
            Set-RegDefault $extKey $progId
            $after = Get-RegDefault $extKey
            Write-Host ("{0,-6} direct   {1} -> {2}" -f $ext, (Format-RegState $before), (Format-RegState $after))
            $direct++
        } elseif ($userChoice.Length -eq 0) {
            Write-Host ("{0,-6} skip     UserChoice has no ProgId; left untouched" -f $ext)
            $skipped++
        } else {
            $iconKey = Get-DefaultIconKey $userChoice
            $before = Get-RegDefault $iconKey
            New-Item -Path $iconKey -Force | Out-Null
            Set-RegDefault $iconKey $icoValue
            $after = Get-RegDefault $iconKey
            Write-Host ("{0,-6} choice   {1}\DefaultIcon  {2} -> {3}" -f `
                    $ext, $userChoice, (Format-RegState $before), (Format-RegState $after))
            $viaChoice++
        }
    }

    Invoke-ShellRefresh
    Write-Host ''
    Write-Host ("installed: {0} direct + {1} via UserChoice = {2}/{3} extensions (skipped {4})" -f `
            $direct, $viaChoice, ($direct + $viaChoice), $script:ExtensionMap.Count, $skipped)
    Write-Host ("iconDir = " + $script:IconDir)
}

# ---------------------------------------------------------------- 卸载
function Invoke-Uninstall {
    $latest = Get-LatestBackup
    $restored = 0

    if ($null -eq $latest) {
        Write-Host 'WARN  no backup found; removing our ProgIDs and clearing only our own values'
        foreach ($ext in $script:ExtensionMap.Keys) {
            $extKey = Get-ExtKey $ext
            $current = Get-RegDefault $extKey
            if ((Get-Field $current 'HasValue') -eq $true -and (Test-IsOurProgId ([string](Get-Field $current 'Value')))) {
                Clear-RegDefault $extKey
            }
            $userChoice = Get-UserChoiceProgId $ext
            if ($userChoice.Length -gt 0) {
                $iconKey = Get-DefaultIconKey $userChoice
                $state = Get-RegDefault $iconKey
                if ((Get-Field $state 'HasValue') -eq $true -and (Test-IsOurIconValue ([string](Get-Field $state 'Value')))) {
                    Clear-RegDefault $iconKey
                }
            }
            $restored++
        }
        foreach ($progId in $script:OwnProgIds) {
            $key = Get-ProgIdKey $progId
            if (Test-RegKey $key) { Remove-Item -LiteralPath $key -Recurse -Force }
        }
        Invoke-ShellRefresh
        Write-Host ''
        Write-Host ("uninstalled (no backup): {0} extensions cleared" -f $restored)
        return
    }

    Write-Host ("restore " + $latest.Path)
    $record = $latest.Record
    $savedExts = Get-Field $record 'extensions'

    foreach ($ext in $script:ExtensionMap.Keys) {
        $saved = Get-Entry $savedExts 'ext' $ext
        if ($null -eq $saved) { continue }
        $extKey = Get-ExtKey $ext
        $savedExtDefault = Get-Field $saved 'extensionDefault'
        $savedIcon = Get-Field $saved 'defaultIcon'
        $iconKey = [string](Get-Field $saved 'iconKey')
        $iconParentKey = [string](Get-Field $saved 'iconParentKey')

        # 扩展名默认值
        if ((Get-Field $savedExtDefault 'Exists') -eq $true) {
            if ((Get-Field $savedExtDefault 'HasValue') -eq $true) {
                Set-RegDefault $extKey ([string](Get-Field $savedExtDefault 'Value'))
            } else {
                Clear-RegDefault $extKey
            }
        } elseif (Test-RegKey $extKey) {
            # 改前没有这个扩展名键，是我们建的：整个删掉，回到跟随系统默认。
            Remove-Item -LiteralPath $extKey -Recurse -Force -ErrorAction SilentlyContinue
        }

        # 图标键
        if ((Get-Field $saved 'iconParentExisted') -eq $false -and $iconParentKey.Length -gt 0) {
            # 这个 ProgID 本来不存在（UserChoice 指向的键是我们建的）：整个删掉。
            if (Test-RegKey $iconParentKey) {
                Remove-Item -LiteralPath $iconParentKey -Recurse -Force -ErrorAction SilentlyContinue
            }
        } elseif ((Get-Field $savedIcon 'Exists') -eq $true) {
            if ((Get-Field $savedIcon 'HasValue') -eq $true) {
                Set-RegDefault $iconKey ([string](Get-Field $savedIcon 'Value'))
            } else {
                Clear-RegDefault $iconKey
            }
        } elseif (Test-RegKey $iconKey) {
            Remove-Item -LiteralPath $iconKey -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Host ("{0,-6} restored   ext default: {1}; icon: {2}" -f `
                $ext, (Format-RegState $savedExtDefault), (Format-RegState $savedIcon))
        $restored++
    }

    foreach ($progId in $script:OwnProgIds) {
        $saved = Get-Entry (Get-Field $record 'progIds') 'progId' $progId
        $key = Get-ProgIdKey $progId
        if ($null -eq $saved) { continue }
        if ((Get-Field $saved 'existed') -ne $true) {
            if (Test-RegKey $key) {
                Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
            }
            continue
        }

        # 原本就存在的 ProgID：把被覆盖的值还原
        $savedDefault = Get-Field $saved 'defaultValue'
        $savedIcon = Get-Field $saved 'defaultIcon'
        $savedCommand = Get-Field $saved 'command'

        if ((Get-Field $savedDefault 'HasValue') -eq $true) {
            Set-RegDefault $key ([string](Get-Field $savedDefault 'Value'))
        } else {
            Clear-RegDefault $key
        }
        $iconKey = Get-DefaultIconKey $progId
        if ((Get-Field $savedIcon 'Exists') -eq $true) {
            if ((Get-Field $savedIcon 'HasValue') -eq $true) {
                Set-RegDefault $iconKey ([string](Get-Field $savedIcon 'Value'))
            } else {
                Clear-RegDefault $iconKey
            }
        }
        $cmdKey = $key + '\shell\open\command'
        if ((Get-Field $savedCommand 'Exists') -eq $true) {
            if ((Get-Field $savedCommand 'HasValue') -eq $true) {
                Set-RegDefault $cmdKey ([string](Get-Field $savedCommand 'Value'))
            } else {
                Clear-RegDefault $cmdKey
            }
        }
        if ((Get-Field $saved 'perceivedExists') -eq $true) {
            Set-ItemProperty -LiteralPath $key -Name 'PerceivedType' `
                -Value ([string](Get-Field $saved 'perceivedType'))
        } else {
            Remove-ItemProperty -LiteralPath $key -Name 'PerceivedType' -ErrorAction SilentlyContinue
        }
    }

    Invoke-ShellRefresh
    Write-Host ''
    Write-Host ("uninstalled: {0} extensions restored" -f $restored)
}

try {
    if ($Uninstall) {
        Invoke-Uninstall
    } else {
        Invoke-Install
    }
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

exit 0

# 文件图标验收（编排方编写，Codex 不得修改）
# 在 Windows 上运行，验证「.doc/.docx/.xls/.xlsx/.ppt/.pptx 的图标真的指向本地 ico」。
#
# 用法：
#   powershell -File ci\accept_file_icons.ps1 -IconDir <ico 所在目录> -InstallScript <installer.ps1> [-Uninstall]
#
# 退出码：0 全部 PASS / 1 有 FAIL / 2 无法执行
#
# 做法：用 shell32!SHGetFileInfo(SHGFI_ICONLOCATION) 直接问 Shell「这个文件的图标
# 来自哪个文件的第几个索引」——不靠肉眼看，也不采信安装脚本的自述。

param(
    [Parameter(Mandatory = $true)][string]$IconDir,
    [Parameter(Mandatory = $true)][string]$InstallScript,
    [switch]$SkipUninstall
)

$ErrorActionPreference = 'Continue'
$failed = 0
function Report([string]$status, [string]$name, [string]$detail) {
    Write-Host ("{0}  {1}  {2}" -f $status, $name, $detail)
    if ($status -eq 'FAIL') { $script:failed++ }
}

# 完整 Office 家族（二进制 + OOXML + 启用宏 + 模板 + 放映）
$map = [ordered]@{
    '.doc'   = 'doc.ico'; '.docx' = 'doc.ico'; '.docm' = 'doc.ico'
    '.dot'   = 'doc.ico'; '.dotx' = 'doc.ico'; '.dotm' = 'doc.ico'
    '.xls'   = 'xls.ico'; '.xlsx' = 'xls.ico'; '.xlsm' = 'xls.ico'
    '.xlsb'  = 'xls.ico'; '.xlt'  = 'xls.ico'; '.xltx' = 'xls.ico'; '.xltm' = 'xls.ico'
    '.ppt'   = 'ppt.ico'; '.pptx' = 'ppt.ico'; '.pptm' = 'ppt.ico'
    '.pps'   = 'ppt.ico'; '.ppsx' = 'ppt.ico'; '.ppsm' = 'ppt.ico'
    '.pot'   = 'ppt.ico'; '.potx' = 'ppt.ico'; '.potm' = 'ppt.ico'
}

# ---------------------------------------------------------------- 前置检查
if (-not (Test-Path -LiteralPath $InstallScript)) { Write-Host "ABORT: installer not found: $InstallScript"; exit 2 }
if (-not (Test-Path -LiteralPath $IconDir)) { Write-Host "ABORT: icon dir not found: $IconDir"; exit 2 }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DshShellIcon
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string pszPath, uint dwFileAttributes,
        ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);

    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

    public const int SHCNE_ASSOCCHANGED = 0x08000000;
    public const uint SHCNF_IDLIST = 0x0000;

    // Returns "C:\path\file.ico,0" or null.
    public static string IconLocation(string path)
    {
        SHFILEINFO fi = new SHFILEINFO();
        const uint SHGFI_ICONLOCATION = 0x1000;
        IntPtr ok = SHGetFileInfo(path, 0, ref fi, (uint)Marshal.SizeOf(fi), SHGFI_ICONLOCATION);
        if (ok == IntPtr.Zero) return null;
        return fi.szDisplayName + "," + fi.iIcon.ToString();
    }
}
'@ | Out-Null

$tmp = Join-Path $env:TEMP ('dsh-fileicon-accept-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Probe-Location([string]$ext) {
    $probe = Join-Path $tmp ("probe" + $ext)
    Set-Content -LiteralPath $probe -Value '' -Encoding ASCII
    [DshShellIcon]::SHChangeNotify([DshShellIcon]::SHCNE_ASSOCCHANGED, [DshShellIcon]::SHCNF_IDLIST,
        [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    return [DshShellIcon]::IconLocation($probe)
}

# ---------------------------------------------------------------- 1) ico 文件本身
foreach ($ico in ($map.Values | Sort-Object -Unique)) {
    $path = Join-Path $IconDir $ico
    if (-not (Test-Path -LiteralPath $path)) {
        Report 'FAIL' "ico/$ico" 'missing'
        continue
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $okHeader = ($bytes.Length -ge 6 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 1 -and $bytes[3] -eq 0)
    $count = if ($bytes.Length -ge 6) { [int]$bytes[4] + [int]$bytes[5] * 256 } else { 0 }
    if ($okHeader -and $count -ge 1) {
        Report 'PASS' "ico/$ico" ("$($bytes.Length) bytes, $count image(s)")
    } else {
        Report 'FAIL' "ico/$ico" 'not a valid .ico container'
    }
}

# ---------------------------------------------------------------- 2) 安装前的基线（必须不等于我们的 ico）
$baseline = @{}
foreach ($ext in $map.Keys) { $baseline[$ext] = Probe-Location $ext }
$alreadyMapped = @($baseline.Keys | Where-Object {
        $baseline[$_] -ne $null -and ($baseline[$_]).ToLowerInvariant().StartsWith($IconDir.ToLowerInvariant())
    })
if ($alreadyMapped.Count -gt 0) {
    Report 'INFO' 'baseline' ("already mapped before install: " + ($alreadyMapped -join ','))
} else {
    Report 'PASS' 'baseline' 'no extension points at our icons yet (precondition ok)'
}

# ---------------------------------------------------------------- 3) 安装
& powershell -NoProfile -ExecutionPolicy Bypass -File $InstallScript -IconDir $IconDir
$installCode = $LASTEXITCODE
if ($installCode -ne 0) {
    Report 'FAIL' 'install' "installer exit=$installCode"
} else {
    Report 'PASS' 'install' 'installer exit=0'
}

# ---------------------------------------------------------------- 4) 逐个扩展名断言
foreach ($ext in $map.Keys) {
    $want = (Join-Path $IconDir $map[$ext]).ToLowerInvariant()
    $got = Probe-Location $ext
    if ($null -eq $got) {
        Report 'FAIL' "icon/$ext" 'SHGetFileInfo returned nothing'
        continue
    }
    $gotPath = ($got -split ',')[0].ToLowerInvariant()
    if ($gotPath -eq $want) {
        Report 'PASS' "icon/$ext" "-> $got"
    } else {
        Report 'FAIL' "icon/$ext" "-> $got (expect $want)"
    }
}

# ---------------------------------------------------------------- 5) 卸载恢复（默认做，证明可逆）
if (-not $SkipUninstall) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $InstallScript -IconDir $IconDir -Uninstall
    $uninstallCode = $LASTEXITCODE
    if ($uninstallCode -ne 0) {
        Report 'FAIL' 'uninstall' "exit=$uninstallCode"
    } else {
        $backOk = $true
        foreach ($ext in $map.Keys) {
            $now = Probe-Location $ext
            $nowPath = if ($now) { ($now -split ',')[0].ToLowerInvariant() } else { '' }
            if ($nowPath.StartsWith($IconDir.ToLowerInvariant())) { $backOk = $false }
        }
        if ($backOk) { Report 'PASS' 'uninstall' 'extensions no longer point at our icons' }
        else { Report 'FAIL' 'uninstall' 'some extension still points at our icons' }
    }
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:failed -gt 0) {
    Write-Host "FILE ICON ACCEPTANCE: FAIL ($($script:failed) failing)"
    exit 1
}
Write-Host 'FILE ICON ACCEPTANCE: PASS'
exit 0
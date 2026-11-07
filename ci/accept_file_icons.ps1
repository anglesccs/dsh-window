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

    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);

    // Renders the icon the Shell would use for this file, as an HICON.
    public static IntPtr ShellLargeIcon(string path)
    {
        SHFILEINFO fi = new SHFILEINFO();
        const uint SHGFI_ICON = 0x100;
        IntPtr ok = SHGetFileInfo(path, 0, ref fi, (uint)Marshal.SizeOf(fi), SHGFI_ICON);
        return ok == IntPtr.Zero ? IntPtr.Zero : fi.hIcon;
    }

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

Add-Type -AssemblyName System.Drawing

function Get-OpaqueMean([System.Drawing.Bitmap]$bmp) {
    $rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $len = $data.Stride * $bmp.Height
        $buf = New-Object byte[] $len
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $len)
    } finally {
        $bmp.UnlockBits($data)
    }
    $r = 0L; $g = 0L; $b = 0L; $n = 0L
    for ($i = 0; $i -lt $len; $i += 4) {
        if ($buf[$i + 3] -ge 200) { $b += $buf[$i]; $g += $buf[$i + 1]; $r += $buf[$i + 2]; $n++ }
    }
    if ($n -eq 0) { return $null }
    return @([double]($r / $n), [double]($g / $n), [double]($b / $n))
}

function Get-RenderedMean([string]$ext) {
    $path = Join-Path $tmp ("probe" + $ext)
    if (-not (Test-Path -LiteralPath $path)) { Set-Content -LiteralPath $path -Value '' -Encoding ASCII }
    $h = [DshShellIcon]::ShellLargeIcon($path)
    if ($h -eq [IntPtr]::Zero) { return $null }
    try {
        $bmp = [System.Drawing.Icon]::FromHandle($h).ToBitmap()
        try { return Get-OpaqueMean $bmp } finally { $bmp.Dispose() }
    } finally {
        [void][DshShellIcon]::DestroyIcon($h)
    }
}

function Get-ColorDistance($a, $b) {
    return [math]::Sqrt([math]::Pow($a[0] - $b[0], 2) + [math]::Pow($a[1] - $b[1], 2) + [math]::Pow($a[2] - $b[2], 2))
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

# 负例自证：安装前 .docx 必须与「通用图标」几乎一样，否则后面的判据不可信
$preMean = Get-RenderedMean '.docx'
$preUnknown = Get-RenderedMean '.dshprobeunregistered'
if ($null -eq $preMean -or $null -eq $preUnknown) {
    Report 'INFO' 'baseline colour' 'shell returned no icon before install (cannot pre-check)'
} else {
    $preDist = Get-ColorDistance $preMean $preUnknown
    if ($preDist -lt 6) {
        Report 'PASS' 'baseline colour' ("pre-install .docx rgb({0:N0},{1:N0},{2:N0}) matches the generic icon (d={3:N0})" -f $preMean[0], $preMean[1], $preMean[2], $preDist)
    } else {
        Report 'FAIL' 'baseline colour' ("pre-install .docx already differs from generic (d={0:N0}) - judge cannot tell the difference" -f $preDist)
    }
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
# SHGFI_ICONLOCATION 对 .ico 来源会返回空路径（只剩索引），因此判据改为
# 「Shell 实际渲染出来的图标颜色必须等于我们的品牌色」，比查注册表文本强得多。
$means = @{}
$UNKNOWN = '.dshprobeunregistered'

# 「通用图标」基准：一个没注册的扩展名，Shell 会给出未知类型图标。
# 判据是「装了之后必须和它明显不同」，不依赖解码我们自己的 .ico（.NET Framework
# 解 PNG 帧的 ICO 不可靠，实测会把彩色图标读成灰的）。
$unknownMean = Get-RenderedMean $UNKNOWN
if ($null -eq $unknownMean) {
    Report 'FAIL' 'baseline icon' 'could not render the generic (unregistered) icon'
} else {
    Report 'INFO' 'baseline icon' ("generic icon rgb({0:N0},{1:N0},{2:N0})" -f $unknownMean[0], $unknownMean[1], $unknownMean[2])
}

foreach ($ext in $map.Keys) {
    $icoName = $map[$ext]
    $mean = Get-RenderedMean $ext
    $where = Probe-Location $ext
    if ($null -eq $mean) {
        Report 'FAIL' "icon/$ext" 'shell returned no icon'
        continue
    }
    $means[$ext] = $mean
    $shown = "rgb({0:N0},{1:N0},{2:N0})" -f $mean[0], $mean[1], $mean[2]
    if ($null -eq $unknownMean) {
        Report 'FAIL' "icon/$ext" "$shown  (no generic baseline to compare)"
        continue
    }
    $dist = Get-ColorDistance $mean $unknownMean
    if ($dist -gt 25) {
        Report 'PASS' "icon/$ext" "$shown  differs from generic by $([int]$dist)  (loc=$where)"
    } else {
        Report 'FAIL' "icon/$ext" "$shown  still looks like the generic icon (d=$([int]$dist))  (loc=$where)"
    }
}

# 三组图标必须彼此可区分：整套成同一个图标也要被抓住
$groups = @{ 'doc.ico' = @(); 'xls.ico' = @(); 'ppt.ico' = @() }
foreach ($ext in $means.Keys) { $groups[$map[$ext]] += , $means[$ext] }
$avg = @{}
foreach ($ico in $groups.Keys) {
    $list = $groups[$ico]
    if ($list.Count -eq 0) { continue }
    $avg[$ico] = @(
        ($list | ForEach-Object { $_[0] } | Measure-Object -Average).Average,
        ($list | ForEach-Object { $_[1] } | Measure-Object -Average).Average,
        ($list | ForEach-Object { $_[2] } | Measure-Object -Average).Average)
}
if ($avg.Count -eq 3) {
    $d1 = Get-ColorDistance $avg['doc.ico'] $avg['xls.ico']
    $d2 = Get-ColorDistance $avg['xls.ico'] $avg['ppt.ico']
    $d3 = Get-ColorDistance $avg['doc.ico'] $avg['ppt.ico']
    if ($d1 -gt 25 -and $d2 -gt 25 -and $d3 -gt 25) {
        Report 'PASS' 'distinct' ("three groups differ: {0:N0}/{1:N0}/{2:N0}" -f $d1, $d2, $d3)
    } else {
        Report 'FAIL' 'distinct' ("groups too similar: {0:N0}/{1:N0}/{2:N0}" -f $d1, $d2, $d3)
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
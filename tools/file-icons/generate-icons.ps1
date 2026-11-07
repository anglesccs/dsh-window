# 生成 Office 家族文件图标（Word / Excel / PowerPoint）。
#
# 纯 PowerShell 5.1 + .NET Framework（System.Drawing）：不联网、不依赖 ImageMagick。
# 每个 .ico 含 16/32/48/256 四帧，全部为 PNG 帧（Vista+ 支持）。
# 视觉：圆角方块底 + 白色大写字母，超采样后缩放，小尺寸也抗锯齿。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\file-icons\generate-icons.ps1 [-OutDir <dir>] [-Force]
#
# 退出码：0 成功 / 1 失败。

param(
    [string]$OutDir = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # 控制台不支持改编码时忽略（不影响生成结果）。
}

Add-Type -AssemblyName System.Drawing

$script:Here = $PSScriptRoot
if (-not $script:Here) { $script:Here = (Get-Location).Path }
if (-not $OutDir) { $OutDir = $script:Here }
$script:OutDir = [System.IO.Path]::GetFullPath($OutDir)

# 三个图标：文件名 / 底色 / 字母。
$script:Specs = @(
    [pscustomobject]@{ Name = 'doc.ico'; Color = '#2B579A'; Letter = 'W' },
    [pscustomobject]@{ Name = 'xls.ico'; Color = '#217346'; Letter = 'X' },
    [pscustomobject]@{ Name = 'ppt.ico'; Color = '#D24726'; Letter = 'P' }
)
$script:Sizes = @(16, 32, 48, 256)

function New-IconPngBytes {
    # 画一张 size×size 的图标并编码为 PNG 字节。
    param(
        [int]$Size,
        [string]$HexColor,
        [string]$Letter
    )

    # 先在大图上画（画布约 512px），再缩到目标尺寸——小尺寸边缘更干净。
    $supersample = [int][math]::Ceiling(512.0 / [double]$Size)
    if ($supersample -lt 2) { $supersample = 2 }
    if ($supersample -gt 32) { $supersample = 32 }
    $w = $Size * $supersample
    $color = [System.Drawing.ColorTranslator]::FromHtml($HexColor)

    $big = New-Object -TypeName System.Drawing.Bitmap -ArgumentList @(
        $w, $w, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($big)
    $final = $null
    $g2 = $null
    $path = $null
    $brush = $null
    $white = $null
    $glyph = $null
    $shift = $null
    $family = $null
    $ms = $null

    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)

        # 圆角方块：留一点边距，圆角半径约 20% 边长。
        $margin = [float]($w * 0.03)
        $side = [float]($w - 2.0 * $margin)
        $d = [float]($side * 0.40)
        $right = [float]($margin + $side - $d)
        $bottom = [float]($margin + $side - $d)

        $path = New-Object -TypeName System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($margin, $margin, $d, $d, 180, 90)
        $path.AddArc($right, $margin, $d, $d, 270, 90)
        $path.AddArc($right, $bottom, $d, $d, 0, 90)
        $path.AddArc($margin, $bottom, $d, $d, 90, 90)
        $path.CloseFigure()

        $brush = New-Object -TypeName System.Drawing.SolidBrush -ArgumentList @($color)
        $g.FillPath($brush, $path)

        # 白色大写字母：把字形转成 GraphicsPath，按墨迹包围盒精确居中
        # （比 DrawString 的行盒对齐可靠，不受 ascent/descent 影响）。
        $em = [float]($w * 0.86)
        $family = New-Object -TypeName System.Drawing.FontFamily -ArgumentList @('Segoe UI')
        $style = [int][System.Drawing.FontStyle]::Bold
        $origin = New-Object -TypeName System.Drawing.PointF -ArgumentList @([float]0, [float]0)

        $glyph = New-Object -TypeName System.Drawing.Drawing2D.GraphicsPath
        $glyph.AddString($Letter, $family, $style, $em, $origin, [System.Drawing.StringFormat]::GenericTypographic)
        $ink = $glyph.GetBounds()
        $dx = [float](($w - $ink.Width) / 2.0 - $ink.X)
        $dy = [float](($w - $ink.Height) / 2.0 - $ink.Y)
        $shift = New-Object -TypeName System.Drawing.Drawing2D.Matrix
        $shift.Translate($dx, $dy)
        $glyph.Transform($shift)

        $white = New-Object -TypeName System.Drawing.SolidBrush -ArgumentList @(
            [System.Drawing.Color]::White)
        $g.FillPath($white, $glyph)

        $final = New-Object -TypeName System.Drawing.Bitmap -ArgumentList @(
            $Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g2 = [System.Drawing.Graphics]::FromImage($final)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g2.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g2.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $dest = New-Object -TypeName System.Drawing.Rectangle -ArgumentList @(0, 0, $Size, $Size)
        $g2.DrawImage($big, $dest, 0, 0, $w, $w, [System.Drawing.GraphicsUnit]::Pixel)

        $ms = New-Object -TypeName System.IO.MemoryStream
        $final.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        # 逗号防止 PowerShell 把 byte[] 逐元素展开到输出流。
        return , $ms.ToArray()
    } finally {
        if ($ms) { $ms.Dispose() }
        if ($white) { $white.Dispose() }
        if ($glyph) { $glyph.Dispose() }
        if ($shift) { $shift.Dispose() }
        if ($family) { $family.Dispose() }
        if ($brush) { $brush.Dispose() }
        if ($path) { $path.Dispose() }
        if ($g2) { $g2.Dispose() }
        if ($final) { $final.Dispose() }
        if ($g) { $g.Dispose() }
        if ($big) { $big.Dispose() }
    }
}

function Write-IcoFile {
    # 手写 ICO 容器：ICONDIR(6) + N×ICONDIRENTRY(16) + 帧数据。
    # 每帧都是 PNG，所以 ICONDIRENTRY 里 planes=1 / bitCount=32；256 的宽高字节写 0。
    param(
        [string]$Path,
        [object[]]$Frames
    )

    $count = $Frames.Count
    $offset = 6 + 16 * $count
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $writer = New-Object -TypeName System.IO.BinaryWriter -ArgumentList @($stream)

    try {
        $writer.Write([uint16]0)          # reserved
        $writer.Write([uint16]1)          # type: 1 = icon
        $writer.Write([uint16]$count)     # image count

        foreach ($frame in $Frames) {
            $dim = [byte]0
            if ([int]$frame.Size -lt 256) { $dim = [byte][int]$frame.Size }
            $writer.Write($dim)                          # width  (0 = 256)
            $writer.Write($dim)                          # height (0 = 256)
            $writer.Write([byte]0)                       # palette colors
            $writer.Write([byte]0)                       # reserved
            $writer.Write([uint16]1)                     # planes
            $writer.Write([uint16]32)                    # bits per pixel
            $writer.Write([uint32]$frame.Bytes.Length)   # bytes in resource
            $writer.Write([uint32]$offset)               # image offset
            $offset = $offset + $frame.Bytes.Length
        }

        foreach ($frame in $Frames) {
            $writer.Write([byte[]]$frame.Bytes)
        }

        $writer.Flush()
    } finally {
        $writer.Dispose()
    }
}

function Invoke-Generate {
    if (-not (Test-Path -LiteralPath $script:OutDir)) {
        New-Item -ItemType Directory -Force -Path $script:OutDir | Out-Null
    }

    $made = 0
    $skipped = 0
    foreach ($spec in $script:Specs) {
        $target = Join-Path $script:OutDir $spec.Name
        if ((Test-Path -LiteralPath $target) -and -not $Force) {
            Write-Host ("skip    {0} (exists, use -Force to rebuild)" -f $target)
            $skipped++
            continue
        }

        $frames = @()
        foreach ($size in $script:Sizes) {
            $png = New-IconPngBytes -Size $size -HexColor $spec.Color -Letter $spec.Letter
            $frames += @{ Size = $size; Bytes = $png }
        }

        Write-IcoFile -Path $target -Frames $frames
        $length = (Get-Item -LiteralPath $target).Length
        Write-Host ("write   {0}  {1} frames ({2})  {3} bytes" -f `
                $target, $frames.Count, (($script:Sizes | ForEach-Object { "$_" }) -join '/'), $length)
        $made++
    }

    Write-Host ''
    Write-Host ("done: {0} written, {1} skipped, outDir = {2}" -f $made, $skipped, $script:OutDir)
}

try {
    Invoke-Generate
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

exit 0

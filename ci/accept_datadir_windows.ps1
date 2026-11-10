# dsh-window: dataDir behavioral acceptance, run ON WINDOWS in CI.
#
# Proves with a real built exe that the `dataDir` config key moves the data
# directory, and that a missing / invalid value keeps the old default:
#   A config      absolute dataDir  -> report.dataDir == it, source=config, dir created
#   B default     no dataDir key    -> report.dataDirSource=default, path ends with DeepSeekHarnessWindow
#   C negative    relative dataDir  -> falls back to default, dataDirError set, --check still exit 0
#
# Only --check is exercised (headless): the real WebView2Data folder is
# verified after deployment on the host, not here.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File accept_datadir_windows.ps1 `
#       -Source "D:\DSH Script\dsh-window-build\dist"

param(
    [string]$Source = "D:\DSH Script\dsh-window-build\dist",
    [string]$Work   = "",
    [int]$StubPort  = 39081
)

$ErrorActionPreference = 'Continue'
$exeName = 'DeepSeek Harness Window.exe'
$shipFiles = @($exeName, 'Microsoft.Web.WebView2.Core.dll',
               'Microsoft.Web.WebView2.WinForms.dll', 'WebView2Loader.dll')
$script:failed = 0

function Report([string]$status, [string]$name, [string]$detail) {
    Write-Host ("{0}  {1}  {2}" -f $status, $name, $detail)
    if ($status -eq 'FAIL') { $script:failed++ }
}

function New-Case([string]$name, $config) {
    $dir = Join-Path $Work $name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in $shipFiles) {
        $src = Join-Path $Source $f
        if (-not (Test-Path $src)) { throw "missing source file: $src" }
        Copy-Item $src $dir -Force
    }
    # No runtime\ dir on purpose: external mode must never need Node.
    $configJson = $config | ConvertTo-Json -Depth 4
    Set-Content -Path (Join-Path $dir 'dsh-window.config.json') -Value $configJson -Encoding UTF8
    return $dir
}

function Invoke-Check([string]$dir, [int]$timeoutSec = 25) {
    $exe = Join-Path $dir $exeName
    $out = Join-Path $dir 'report.json'
    if (Test-Path $out) { Remove-Item $out -Force }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $exe -ArgumentList ('--check --out "' + $out + '"') `
        -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        $sw.Stop()
        return [pscustomobject]@{ code = -1; timedOut = $true; seconds = [int]$sw.Elapsed.TotalSeconds; report = $null }
    }
    $sw.Stop()
    $rep = $null
    if (Test-Path $out) {
        try { $rep = Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $rep = $null }
    }
    return [pscustomobject]@{ code = $p.ExitCode; timedOut = $false; seconds = [int]$sw.Elapsed.TotalSeconds; report = $rep }
}

function Test-HasKey($obj, [string]$key) {
    return ($null -ne $obj) -and ($obj.PSObject.Properties.Name -contains $key)
}

function Get-NormalizedPath([string]$path) {
    if ([string]::IsNullOrEmpty($path)) { return '' }
    return [System.IO.Path]::GetFullPath($path).TrimEnd([char]'\')
}

# ---------------------------------------------------------------- defaults
if ([string]::IsNullOrEmpty($Work)) {
    if ([string]::IsNullOrEmpty($env:RUNNER_TEMP)) { $Work = 'D:\DSH Script\dshw-accept-datadir' }
    else { $Work = Join-Path $env:RUNNER_TEMP 'dshw-accept-datadir' }
}
$liveUrl = 'http://127.0.0.1:' + $StubPort + '/'
if ([string]::IsNullOrEmpty($env:RUNNER_TEMP)) { $customDir = Join-Path $Work 'dd\custom' }
else { $customDir = Join-Path $env:RUNNER_TEMP 'dd\custom' }

# A local TCP stub, so external mode has a reachable URL without a real server.
$serveJob = Start-Job -ScriptBlock {
    param([int]$port)
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
    $listener.Start()
    while ($true) {
        try {
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream)
            while (-not [string]::IsNullOrEmpty($reader.ReadLine())) { }
            $html = '<!doctype html><html><head><meta charset="utf-8"><title>stub</title></head><body>ok</body></html>'
            $payload = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: " +
                       [System.Text.Encoding]::UTF8.GetByteCount($html).ToString() +
                       "`r`nConnection: close`r`n`r`n" + $html
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $client.Close()
        } catch { break }
    }
} -ArgumentList $StubPort

$deadline = (Get-Date).AddSeconds(25)
$up = $false
while (-not $up -and (Get-Date) -lt $deadline) {
    try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $StubPort); $c.Close(); $up = $true }
    catch { Start-Sleep -Milliseconds 300 }
}
if (-not $up) {
    Stop-Job $serveJob -ErrorAction SilentlyContinue
    Remove-Job $serveJob -Force -ErrorAction SilentlyContinue
    Write-Host "ABORT: local stub did not start on $StubPort"
    exit 2
}
Write-Host "local stub listening on 127.0.0.1:$StubPort"

# ---------------------------------------------------------------- preflight
if (-not (Test-Path $Source)) { Write-Host "ABORT: source dir not found: $Source"; exit 2 }
if (-not (Test-Path (Join-Path $Source $exeName))) { Write-Host "ABORT: exe not found in $Source"; exit 2 }
New-Item -ItemType Directory -Force -Path $Work | Out-Null
# Case A must prove the directory is created by the app, so start without it.
if ((Test-Path $customDir) -and $customDir.Length -gt 4) { Remove-Item $customDir -Recurse -Force }

Write-Host "source = $Source"
Write-Host "work   = $Work"
Write-Host "custom = $customDir"
Write-Host ''

# ---------------------------------------------------------------- A: config dataDir
$cfgConfig = @{
    serverMode     = 'external'
    externalUrl    = $liveUrl
    dataDir        = $customDir
    waitTimeoutMs  = 3000
    killServerOnClose = $false
    closeToTray    = $true
    checkUpdates   = $false
    logFile        = $true
}
$dir = New-Case 'a-config-datadir' $cfgConfig
$r = Invoke-Check $dir 25
$rep = $r.report
$want = Get-NormalizedPath $customDir
if ($r.timedOut) {
    Report 'FAIL' 'A config dataDir' 'process did not exit'
} elseif ($r.code -ne 0) {
    Report 'FAIL' 'A config dataDir' "exit=$($r.code) (expect 0)"
} elseif ($null -eq $rep) {
    Report 'FAIL' 'A config dataDir' 'report.json missing or not JSON'
} elseif (-not (Test-HasKey $rep 'dataDir') -or -not (Test-HasKey $rep 'dataDirSource') -or
          -not (Test-HasKey $rep 'dataDirOk') -or -not (Test-HasKey $rep 'dataDirError')) {
    Report 'FAIL' 'A config dataDir' 'report is missing one of dataDir/dataDirSource/dataDirOk/dataDirError'
} elseif ((Get-NormalizedPath $rep.dataDir) -ne $want) {
    Report 'FAIL' 'A config dataDir' "report.dataDir=$($rep.dataDir) (expect $want)"
} elseif ($rep.dataDirSource -ne 'config') {
    Report 'FAIL' 'A config dataDir' "dataDirSource=$($rep.dataDirSource) (expect config)"
} elseif (-not $rep.dataDirOk) {
    Report 'FAIL' 'A config dataDir' "dataDirOk=$($rep.dataDirOk) error=$($rep.dataDirError)"
} elseif (-not (Test-Path -LiteralPath $customDir)) {
    Report 'FAIL' 'A config dataDir' "directory was not created: $customDir"
} else {
    Report 'PASS' 'A config dataDir' "exit=0 source=config dir=$($rep.dataDir)"
}

# ---------------------------------------------------------------- B: default (no dataDir key)
$cfgDefault = @{
    serverMode     = 'external'
    externalUrl    = $liveUrl
    waitTimeoutMs  = 3000
    killServerOnClose = $false
    closeToTray    = $true
    checkUpdates   = $false
    logFile        = $true
}
$dir = New-Case 'b-default-datadir' $cfgDefault
$r = Invoke-Check $dir 25
$rep = $r.report
if ($r.timedOut) {
    Report 'FAIL' 'B default dataDir' 'process did not exit'
} elseif ($r.code -ne 0) {
    Report 'FAIL' 'B default dataDir' "exit=$($r.code) (expect 0)"
} elseif ($null -eq $rep) {
    Report 'FAIL' 'B default dataDir' 'report.json missing or not JSON'
} elseif ($rep.dataDirSource -ne 'default') {
    Report 'FAIL' 'B default dataDir' "dataDirSource=$($rep.dataDirSource) (expect default)"
} elseif ((Get-NormalizedPath $rep.dataDir) -notmatch '\\DeepSeekHarnessWindow$') {
    Report 'FAIL' 'B default dataDir' "report.dataDir=$($rep.dataDir) (expect ...\DeepSeekHarnessWindow)"
} elseif (-not $rep.dataDirOk) {
    Report 'FAIL' 'B default dataDir' "dataDirOk=$($rep.dataDirOk) error=$($rep.dataDirError)"
} elseif (-not [string]::IsNullOrEmpty([string]$rep.dataDirError)) {
    Report 'FAIL' 'B default dataDir' "dataDirError=$($rep.dataDirError) (expect empty)"
} else {
    Report 'PASS' 'B default dataDir' "exit=0 source=default dir=$($rep.dataDir)"
}

# ---------------------------------------------------------------- C: relative path falls back
$cfgBad = @{
    serverMode     = 'external'
    externalUrl    = $liveUrl
    dataDir        = 'relative\bad'
    waitTimeoutMs  = 3000
    killServerOnClose = $false
    closeToTray    = $true
    checkUpdates   = $false
    logFile        = $true
}
$dir = New-Case 'c-relative-datadir' $cfgBad
$r = Invoke-Check $dir 25
$rep = $r.report
if ($r.timedOut) {
    Report 'FAIL' 'C relative dataDir' 'process did not exit (must not crash)'
} elseif ($r.code -ne 0) {
    Report 'FAIL' 'C relative dataDir' "exit=$($r.code) (expect 0: bad dataDir only degrades)"
} elseif ($null -eq $rep) {
    Report 'FAIL' 'C relative dataDir' 'report.json missing or not JSON'
} elseif ($rep.dataDirSource -ne 'default') {
    Report 'FAIL' 'C relative dataDir' "dataDirSource=$($rep.dataDirSource) (expect default)"
} elseif ([string]::IsNullOrWhiteSpace([string]$rep.dataDirError)) {
    Report 'FAIL' 'C relative dataDir' 'dataDirError is empty (expect a message)'
} elseif ((Get-NormalizedPath $rep.dataDir) -notmatch '\\DeepSeekHarnessWindow$') {
    Report 'FAIL' 'C relative dataDir' "report.dataDir=$($rep.dataDir) (expect the default root)"
} else {
    Report 'PASS' 'C relative dataDir' "exit=0 source=default error=$($rep.dataDirError)"
}

# ---------------------------------------------------------------- cleanup
if ($null -ne $serveJob) {
    Stop-Job $serveJob -ErrorAction SilentlyContinue
    Remove-Job $serveJob -Force -ErrorAction SilentlyContinue
}
Get-Process -Name 'DeepSeek Harness Window' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like (Join-Path $Work '*') } |
    ForEach-Object { try { $_.Kill() } catch {} }

Write-Host ''
if ($script:failed -gt 0) {
    Write-Host "DATA DIRECTORY ACCEPTANCE: FAIL ($($script:failed) failing)"
    exit 1
}
Write-Host 'DATA DIRECTORY ACCEPTANCE: PASS'
exit 0

# dsh-window fork: behavioral acceptance, run ON WINDOWS by the orchestrator (DSH).
# Written by DSH; Codex must not modify this file.
#
# Proves with a real built exe that:
#   T1 external mode + live URL  -> --check exit 0, ok=true, runtime.available=false
#   T2 external mode + --no-window -> exit 0 and NO node.exe spawned
#   T3 external mode + dead URL  -> --no-window exit 3, no spawn, fast fail
#   T4 local mode, no runtime    -> --check exit 2, problems=[runtime-missing], no MessageBox hang
#   T5 local mode + remote host  -> problems=[refuse-remote-host-in-local-mode], no spawn
#   T6 GUI retry backoff (informational; needs a desktop session)
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File accept_behavior_windows.ps1 `
#       -Source "D:\DSH Script\dsh-window-build\dist"

param(
    [string]$Source  = "D:\DSH Script\dsh-window-build\dist",
    [string]$Work    = "",
    [string]$LiveUrl = "",
    [string]$DeadUrl = "",
    [switch]$ServeLocal
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

function New-Case([string]$name, [string]$configJson) {
    $dir = Join-Path $Work $name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in $shipFiles) {
        $src = Join-Path $Source $f
        if (-not (Test-Path $src)) { throw "missing source file: $src" }
        Copy-Item $src $dir -Force
    }
    # Deliberately no runtime\ dir: proves external mode never needs Node.
    Set-Content -Path (Join-Path $dir 'dsh-window.config.json') -Value $configJson -Encoding UTF8
    return $dir
}

function Invoke-App([string]$dir, [string]$argLine, [int]$timeoutSec = 25) {
    $exe = Join-Path $dir $exeName
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        $sw.Stop()
        return [pscustomobject]@{ code = -1; timedOut = $true; seconds = [int]$sw.Elapsed.TotalSeconds }
    }
    $sw.Stop()
    return [pscustomobject]@{ code = $p.ExitCode; timedOut = $false; seconds = [int]$sw.Elapsed.TotalSeconds }
}

function Get-NodeCount {
    return (Get-Process -Name node -ErrorAction SilentlyContinue | Measure-Object).Count
}

function Read-Report([string]$dir) {
    $path = Join-Path $dir 'report.json'
    if (-not (Test-Path $path)) { return $null }
    try { return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Check-ReportShape($r) {
    $problems = @()
    if ($null -eq $r) { return @('report.json missing or not JSON') }
    foreach ($k in 'version', 'serverMode', 'url', 'configPath', 'configFound', 'runtime', 'hostIsLocal', 'problems', 'ok') {
        if (-not ($r.PSObject.Properties.Name -contains $k)) { $problems += "missing key: $k" }
    }
    if ($r -and $r.runtime) {
        foreach ($k in 'available', 'nodeExe', 'dshEntry') {
            if (-not ($r.runtime.PSObject.Properties.Name -contains $k)) { $problems += "missing runtime key: $k" }
        }
    }
    return $problems
}

# ---------------------------------------------------------------- defaults
if ([string]::IsNullOrEmpty($Work)) {
    if ([string]::IsNullOrEmpty($env:RUNNER_TEMP)) { $Work = 'D:\DSH Script\dshw-accept' }
    else { $Work = Join-Path $env:RUNNER_TEMP 'dshw-accept' }
}
if ([string]::IsNullOrEmpty($LiveUrl)) {
    if ($ServeLocal) { $LiveUrl = 'http://127.0.0.1:39080/' } else { $LiveUrl = 'http://192.168.78.2:3080/' }
}
if ([string]::IsNullOrEmpty($DeadUrl)) {
    if ($ServeLocal) { $DeadUrl = 'http://127.0.0.1:39998/' } else { $DeadUrl = 'http://192.168.78.2:3998/' }
}

# A local TCP stub, so CI can prove "external mode + reachable URL" without
# any real server. Raw HTTP 200 on a TcpListener: no URL ACL, no admin.
$serveJob = $null
if ($ServeLocal) {
    $serveJob = Start-Job -ScriptBlock {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 39080)
        $listener.Start()
        while ($true) {
            try {
                $client = $listener.AcceptTcpClient()
                $stream = $client.GetStream()
                $reader = New-Object System.IO.StreamReader($stream)
                while (-not [string]::IsNullOrEmpty($reader.ReadLine())) { }
                $payload = "HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: 2`r`nConnection: close`r`n`r`nok"
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($payload)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                $client.Close()
            } catch { break }
        }
    }
    $deadline = (Get-Date).AddSeconds(25)
    $up = $false
    while (-not $up -and (Get-Date) -lt $deadline) {
        try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', 39080); $c.Close(); $up = $true }
        catch { Start-Sleep -Milliseconds 300 }
    }
    if (-not $up) { Write-Host 'ABORT: local stub did not start on 39080'; exit 2 }
    Write-Host 'local stub listening on 127.0.0.1:39080'
}

# ---------------------------------------------------------------- preflight
if (-not (Test-Path $Source)) { Write-Host "ABORT: source dir not found: $Source"; exit 2 }
if (-not (Test-Path (Join-Path $Source $exeName))) { Write-Host "ABORT: exe not found in $Source"; exit 2 }
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$nodeBefore = Get-NodeCount

$cfgExternalLive = @"
{
  "serverMode": "external",
  "externalUrl": "$LiveUrl",
  "waitTimeoutMs": 3000,
  "killServerOnClose": true,
  "closeToTray": true,
  "checkUpdates": false,
  "logFile": true
}
"@

$cfgExternalDead = @"
{
  "serverMode": "external",
  "externalUrl": "$DeadUrl",
  "waitTimeoutMs": 2000,
  "closeToTray": true,
  "checkUpdates": false,
  "logFile": true
}
"@

$cfgLocalLocalhost = @"
{
  "serverMode": "local",
  "host": "127.0.0.1",
  "port": 3080,
  "waitTimeoutMs": 2000,
  "killServerOnClose": true,
  "checkUpdates": false,
  "logFile": true
}
"@

$cfgLocalRemote = @"
{
  "serverMode": "local",
  "host": "192.168.78.2",
  "port": 3080,
  "waitTimeoutMs": 2000,
  "killServerOnClose": true,
  "checkUpdates": false,
  "logFile": true
}
"@

Write-Host "source = $Source"
Write-Host "work   = $Work"
Write-Host "live   = $LiveUrl"
Write-Host "dead   = $DeadUrl"
Write-Host "node processes before = $nodeBefore"
Write-Host ''

# ---------------------------------------------------------------- T1
$dir = New-Case 't1-check-external-live' $cfgExternalLive
$out = Join-Path $dir 'report.json'
$r = Invoke-App $dir ('--check --out "' + $out + '"') 20
$rep = Read-Report $dir
$shape = Check-ReportShape $rep
if ($r.timedOut) {
    Report 'FAIL' 'T1 external/live --check' 'process did not exit (MessageBox hang?)'
} elseif ($r.code -ne 0) {
    Report 'FAIL' 'T1 external/live --check' "exit=$($r.code) (expect 0)"
} elseif ($shape.Count -gt 0) {
    Report 'FAIL' 'T1 external/live --check' ("report shape: " + ($shape -join '; '))
} elseif (-not $rep.ok) {
    Report 'FAIL' 'T1 external/live --check' "ok=false problems=$($rep.problems -join ',')"
} elseif ($rep.serverMode -ne 'external') {
    Report 'FAIL' 'T1 external/live --check' "serverMode=$($rep.serverMode) (expect external)"
} elseif ($rep.runtime.available -ne $false) {
    Report 'FAIL' 'T1 external/live --check' "runtime.available=$($rep.runtime.available) (expect false: no runtime dir)"
} elseif ($rep.url.TrimEnd('/') -ne $LiveUrl.TrimEnd('/')) {
    Report 'FAIL' 'T1 external/live --check' "url=$($rep.url) (expect $LiveUrl)"
} else {
    Report 'PASS' 'T1 external/live --check' "exit=0 mode=external runtime=false url=$($rep.url)"
}

# ---------------------------------------------------------------- T2
$dir = New-Case 't2-nowindow-external-live' $cfgExternalLive
$n0 = Get-NodeCount
$r = Invoke-App $dir '--no-window' 20
$n1 = Get-NodeCount
if ($r.timedOut) {
    Report 'FAIL' 'T2 external/live --no-window' 'did not exit'
} elseif ($r.code -ne 0) {
    Report 'FAIL' 'T2 external/live --no-window' "exit=$($r.code) (expect 0)"
} elseif ($n1 -ne $n0) {
    Report 'FAIL' 'T2 external/live --no-window' "node spawned ($n0 -> $n1)"
} else {
    Report 'PASS' 'T2 external/live --no-window' "exit=0 no node spawn, $($r.seconds)s"
}

# ---------------------------------------------------------------- T3
$dir = New-Case 't3-nowindow-external-dead' $cfgExternalDead
$n0 = Get-NodeCount
$r = Invoke-App $dir '--no-window' 25
$n1 = Get-NodeCount
if ($r.timedOut) {
    Report 'FAIL' 'T3 external/dead --no-window' 'did not exit'
} elseif ($r.code -ne 3) {
    Report 'FAIL' 'T3 external/dead --no-window' "exit=$($r.code) (expect 3)"
} elseif ($n1 -ne $n0) {
    Report 'FAIL' 'T3 external/dead --no-window' "node spawned ($n0 -> $n1)"
} else {
    Report 'PASS' 'T3 external/dead --no-window' "exit=3 no node spawn, $($r.seconds)s"
}

# ---------------------------------------------------------------- T4
$dir = New-Case 't4-check-local-no-runtime' $cfgLocalLocalhost
$out = Join-Path $dir 'report.json'
$r = Invoke-App $dir ('--check --out "' + $out + '"') 20
$rep = Read-Report $dir
if ($r.timedOut) {
    Report 'FAIL' 'T4 local/no-runtime --check' 'process did not exit (MessageBox hang -> must be headless)'
} elseif ($r.code -ne 2) {
    Report 'FAIL' 'T4 local/no-runtime --check' "exit=$($r.code) (expect 2)"
} elseif ($null -eq $rep) {
    Report 'FAIL' 'T4 local/no-runtime --check' 'report.json missing'
} elseif ($rep.ok) {
    Report 'FAIL' 'T4 local/no-runtime --check' 'ok=true (expect false)'
} elseif (-not (($rep.problems) -contains 'runtime-missing')) {
    Report 'FAIL' 'T4 local/no-runtime --check' "problems=$($rep.problems -join ',') (expect runtime-missing)"
} else {
    Report 'PASS' 'T4 local/no-runtime --check' "exit=2 problems=$($rep.problems -join ',') headless"
}

# ---------------------------------------------------------------- T5
$dir = New-Case 't5-local-remote-host' $cfgLocalRemote
$out = Join-Path $dir 'report.json'
$r1 = Invoke-App $dir ('--check --out "' + $out + '"') 20
$rep = Read-Report $dir
$n0 = Get-NodeCount
$r2 = Invoke-App $dir '--no-window' 20
$n1 = Get-NodeCount
if ($r1.timedOut -or $r2.timedOut) {
    Report 'FAIL' 'T5 local/remote-host' 'a run did not exit'
} elseif ($null -eq $rep) {
    Report 'FAIL' 'T5 local/remote-host' 'report.json missing'
} elseif (-not (($rep.problems) -contains 'refuse-remote-host-in-local-mode')) {
    Report 'FAIL' 'T5 local/remote-host' "problems=$($rep.problems -join ',') (expect refuse-remote-host-in-local-mode)"
} elseif ($n1 -ne $n0) {
    Report 'FAIL' 'T5 local/remote-host' "node spawned ($n0 -> $n1) against remote host"
} elseif ($r2.code -ne 3) {
    Report 'FAIL' 'T5 local/remote-host' "--no-window exit=$($r2.code) (expect 3)"
} else {
    Report 'PASS' 'T5 local/remote-host' "refused, exit=$($r2.code), no spawn"
}

# ---------------------------------------------------------------- T6 (informational)
$dir = New-Case 't6-gui-retry-backoff' $cfgExternalDead
$log = Join-Path $env:LOCALAPPDATA 'DeepSeekHarnessWindow\launcher.log'
$logBak = $log + '.acceptbak'
if (Test-Path $log) { Move-Item -Force $log $logBak }   # never destroy the user's real log
$exe = Join-Path $dir $exeName
$n0 = Get-NodeCount
$p = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 14
try { $p.Kill() } catch {}
$n1 = Get-NodeCount
$retries = 0
if (Test-Path $log) {
    $retries = (Select-String -Path $log -Pattern 'retry\s*#\d+' -AllMatches | Measure-Object).Count
}
if ($n1 -ne $n0) { Report 'FAIL' 'T6 gui/retry' "node spawned ($n0 -> $n1)" }
else { Report 'INFO' 'T6 gui/retry' "retry log lines=$retries (informational; needs desktop session)" }
if (Test-Path $logBak) { Remove-Item -Force $log; Move-Item -Force $logBak $log }

# ---------------------------------------------------------------- cleanup
Get-Process -Name 'DeepSeek Harness Window' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like (Join-Path $Work '*') } |
    ForEach-Object { try { $_.Kill() } catch {} }

if ($null -ne $serveJob) { Stop-Job $serveJob -ErrorAction SilentlyContinue; Remove-Job $serveJob -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:failed -gt 0) {
    Write-Host "BEHAVIOR ACCEPTANCE: FAIL ($($script:failed) failing)"
    exit 1
}
Write-Host 'BEHAVIOR ACCEPTANCE: PASS'
exit 0
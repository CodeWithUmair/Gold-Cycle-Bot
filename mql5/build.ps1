# Copy the GoldCycle MQL5 sources into a MetaTrader 5, compile them, and refresh release\GoldCycle.ex5.
#
#   powershell -ExecutionPolicy Bypass -File mql5\build.ps1
#   powershell -ExecutionPolicy Bypass -File mql5\build.ps1 -Terminal "C:\Program Files\MetaTrader 5 EXNESS"
#   powershell -ExecutionPolicy Bypass -File mql5\build.ps1 -Terminal D:\mt5copy -Portable      (a portable copy)
param(
    [string]$Terminal = 'C:\Program Files\MetaTrader 5 EXNESS',
    [switch]$Portable
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$editor = Join-Path $Terminal 'MetaEditor64.exe'
if (-not (Test-Path $editor)) { throw "MetaEditor64.exe not found in '$Terminal'. Pass -Terminal <MetaTrader 5 folder>." }

if ($Portable) {
    $data = $Terminal
} else {
    # the terminal's data folder is the one whose origin.txt names the install folder
    $data = Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal" -Directory | Where-Object {
        $o = Join-Path $_.FullName 'origin.txt'
        (Test-Path $o) -and ((Get-Content $o -Raw).Trim().TrimEnd('\') -ieq $Terminal.TrimEnd('\'))
    } | Select-Object -First 1 -ExpandProperty FullName
    if (-not $data) { throw "No data folder for '$Terminal'. Start that MetaTrader 5 once, then run this again." }
}
$mql = Join-Path $data 'MQL5'
foreach ($dir in 'Include', 'Experts', 'Scripts') {
    $to = Join-Path $mql "$dir\GoldCycle"
    New-Item -ItemType Directory -Force $to | Out-Null
    Copy-Item (Join-Path $src "$dir\GoldCycle\*") $to -Force
}
Write-Host "Sources copied to $mql"

$failed = $false
foreach ($file in 'Experts\GoldCycle\GoldCycle.mq5', 'Scripts\GoldCycle\GoldCycleTests.mq5', 'Scripts\GoldCycle\GoldCycleLiveTest.mq5') {
    $mq5 = Join-Path $mql $file
    $ex5 = [IO.Path]::ChangeExtension($mq5, 'ex5')
    $log = Join-Path $env:TEMP 'goldcycle-compile.log'
    Remove-Item $ex5, $log -ErrorAction SilentlyContinue
    $options = @("/compile:`"$mq5`"", "/inc:`"$mql`"", "/log:`"$log`"")
    if ($Portable) { $options = @('/portable') + $options }
    Start-Process -FilePath $editor -ArgumentList $options -Wait
    $result = if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match ' error |warning \d|Result:' } } else { 'no compile log' }
    Write-Host "== $file"; $result | ForEach-Object { Write-Host "   $_" }
    if (-not (Test-Path $ex5)) { $failed = $true }
}
if ($failed) { Write-Host 'BUILD FAILED' -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Force (Join-Path $src 'release') | Out-Null
Copy-Item (Join-Path $mql 'Experts\GoldCycle\GoldCycle.ex5') (Join-Path $src 'release\GoldCycle.ex5') -Force
Write-Host 'BUILD OK. Installed in that MetaTrader (Navigator > Expert Advisors > Refresh). release\GoldCycle.ex5 updated.' -ForegroundColor Green

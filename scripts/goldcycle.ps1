# GoldCycle Manager: run several MT5 accounts from one install on one VPS.
#
#   C:\GoldCycle\app\                 this repo (one copy, updated once for every account)
#   C:\GoldCycle\accounts\<name>\     .env, start.bat, data\, logs\   (one dashboard port each: 8001, 8002, ...)
#   C:\GoldCycle\terminals\<name>\    a copy of the Exness MT5 terminal for that account
#
# Double-click "GoldCycle Manager" on the desktop for the menu, or:
#   goldcycle.ps1 install | add | list | start [name] | stop [name] | stop-mt5 [name] | restart [name]
#                 | mode <name> | update | repair | open <name>
param([string]$Command = 'menu', [string]$Name = '')

$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
$Root = Split-Path $App -Parent
$Py = Join-Path $App 'backend\.venv\Scripts\python.exe'
$Utf8 = New-Object Text.UTF8Encoding $false   # .env must be UTF-8 without BOM

function Invoke-Native([string]$What, [scriptblock]$Run) {
    & $Run
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

function Install-App {
    Write-Host "`n=== Installing GoldCycle (Python packages + dashboard) ===" -ForegroundColor Cyan
    if (-not (Test-Path $Py)) { Invoke-Native 'Creating the Python environment' { python -m venv (Join-Path $App 'backend\.venv') } }
    Invoke-Native 'pip upgrade' { & $Py -m pip install --upgrade pip --quiet }
    Invoke-Native 'Python packages' { & $Py -m pip install -r (Join-Path $App 'backend\requirements.txt') --quiet }
    Push-Location (Join-Path $App 'frontend')
    try {
        Invoke-Native 'npm ci' { npm.cmd ci --no-audit --no-fund }
        Invoke-Native 'Dashboard build' { npm.cmd run build }
    } finally { Pop-Location }
}

function Get-Accounts {
    $dir = Join-Path $Root 'accounts'
    if (-not (Test-Path $dir)) { return @() }
    foreach ($d in Get-ChildItem $dir -Directory) {
        $envFile = Join-Path $d.FullName '.env'
        if (-not (Test-Path $envFile)) { continue }
        $kv = @{}
        foreach ($line in [IO.File]::ReadAllLines($envFile)) {
            if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*(.*)$') { $kv[$Matches[1]] = $Matches[2].Trim().Trim("'").Trim('"') }
        }
        [pscustomobject]@{
            Name = $d.Name; Dir = $d.FullName; EnvFile = $envFile
            Port = [int]$kv['PORT']; Login = $kv['MT5_LOGIN']; Server = $kv['MT5_SERVER']; Mt5Path = $kv['MT5_PATH']
            Real = ($kv['DRY_RUN'] -eq 'false'); Running = [bool](Get-BotProcess $d.Name)
        }
    }
}

function Get-BotProcess([string]$AccountName) {
    # Every bot runs as `cmd.exe /c "...\accounts\<name>\start.bat"` (task, shortcut or double-click).
    $bat = "*\accounts\$AccountName\start.bat*"
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" | Where-Object { $_.CommandLine -like $bat }
}

function Show-Accounts {
    $list = @(Get-Accounts)
    if ($list.Count -eq 0) { Write-Host '  (no accounts yet)'; return }
    foreach ($a in $list) {
        $mode = if ($a.Real) { 'REAL ORDERS' } else { 'practice (no orders sent)' }
        $run = if ($a.Running) { 'running' } else { 'stopped' }
        $color = if ($a.Running) { 'Green' } else { 'DarkGray' }
        Write-Host ("  {0,-12} #{1,-11} {2,-20} http://127.0.0.1:{3}  {4,-26} {5}" -f $a.Name, $a.Login, $a.Server, $a.Port, $mode, $run) -ForegroundColor $color
    }
}

function Read-Plain([string]$Prompt) {
    $s = Read-Host -AsSecureString $Prompt
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}

function Format-EnvValue([string]$v) {
    # Single quotes = taken literally by the .env reader (passwords with $ # etc.)
    if ($v -notmatch "'") { return "'$v'" }
    return '"' + $v.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Find-BaseTerminal {
    $found = @(Get-ChildItem 'C:\Program Files', 'C:\Program Files (x86)' -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'terminal64.exe') } | Sort-Object { $_.Name -notmatch 'EXNESS' })
    if ($found.Count -eq 0) {
        $p = Read-Host 'No MetaTrader 5 found in Program Files. Paste the folder that has terminal64.exe (or Enter to cancel)'
        if (-not $p -or -not (Test-Path (Join-Path $p 'terminal64.exe'))) { throw 'Install Exness MetaTrader 5 first, then run "Add an account" again.' }
        return $p
    }
    if ($found.Count -eq 1) { return $found[0].FullName }
    for ($i = 0; $i -lt $found.Count; $i++) { Write-Host "  $($i + 1)) $($found[$i].FullName)" }
    $n = [int](Read-Host 'Which MetaTrader 5 should be copied for this account? Number')
    return $found[$n - 1].FullName
}

function New-AccountFiles {
    param([string]$AccountName, [string]$Login, [string]$Password, [string]$Server, [bool]$Real,
        [string]$DashHash, [int]$Port, [string]$TerminalExe)
    $dir = Join-Path $Root "accounts\$AccountName"
    New-Item -ItemType Directory -Force (Join-Path $dir 'data'), (Join-Path $dir 'logs') | Out-Null
    $magic = 7700501 + ($Port - 8000) * 10   # unique per account; Single uses magic+1
    $dry = if ($Real) { 'false' } else { 'true' }
    $envText = @(
        "# GoldCycle account '$AccountName'. Written by the GoldCycle Manager. Restart the bot after editing.",
        "# DRY_RUN=true = practice: real prices, but NO orders are sent to Exness (nothing in MT5/Exness history).",
        'BROKER=mt5',
        "DRY_RUN=$dry",
        "MT5_PATH=$(Format-EnvValue $TerminalExe)",
        "MT5_LOGIN=$Login",
        "MT5_PASSWORD=$(Format-EnvValue $Password)",
        "MT5_SERVER=$(Format-EnvValue $Server)",
        'SYMBOL=',
        "MAGIC=$magic",
        'HOST=127.0.0.1',
        "PORT=$Port",
        'ADMIN_USERNAME=admin',
        "ADMIN_PASSWORD_HASH=$(Format-EnvValue $DashHash)",
        'RESUME_ON_RESTART=false',
        "DB_PATH=$(Format-EnvValue (Join-Path $dir 'data\goldcycle.db'))",
        "LOG_DIR=$(Format-EnvValue (Join-Path $dir 'logs'))"
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $dir '.env'), $envText + "`r`n", $Utf8)
    Write-Launchers $AccountName $Port
    return $dir
}

function Write-Launchers([string]$AccountName, [int]$Port) {
    # The bot runs HIDDEN (launch.vbs -> start.bat): no black window to click on (a click freezes a console)
    # or close by mistake, and start.bat starts it again 6 s after any crash. Output goes to logs\console.log.
    $dir = Join-Path $Root "accounts\$AccountName"
    $bat = @(
        '@echo off',
        "title GoldCycle - $AccountName (port $Port)",
        "set GOLDCYCLE_ENV_FILE=$dir\.env",
        "cd /d `"$App\backend`"",
        ':loop',
        "`".venv\Scripts\python.exe`" -m app.main > `"$dir\logs\console.log`" 2>&1",
        'ping -n 6 127.0.0.1 >nul',
        'goto loop'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $dir 'start.bat'), $bat + "`r`n", [Text.Encoding]::ASCII)
    $vbs = 'CreateObject("WScript.Shell").Run "cmd /c ""' + (Join-Path $dir 'start.bat') + '""", 0, True'
    [IO.File]::WriteAllText((Join-Path $dir 'launch.vbs'), $vbs + "`r`n", [Text.Encoding]::ASCII)
}

function Register-Account([string]$AccountName, [int]$Port) {
    $vbs = Join-Path $Root "accounts\$AccountName\launch.vbs"
    $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B //Nologo `"$vbs`""
    $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    # ExecutionTimeLimit 0: the default (3 days) would kill the bot after 72 hours
    $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName "GoldCycle-$AccountName" -Action $act -Trigger $trg -Settings $set -Force | Out-Null
    $desk = [Environment]::GetFolderPath('Desktop')
    [IO.File]::WriteAllText((Join-Path $desk "GoldCycle $AccountName.url"), "[InternetShortcut]`r`nURL=http://127.0.0.1:$Port/`r`n")
}

function Add-Account {
    Write-Host "`n=== Add an MT5 account ===" -ForegroundColor Cyan
    $existing = @(Get-Accounts)
    do {
        $n = (Read-Host 'Short name for this account (letters/numbers, e.g. gold1)').Trim()
        $ok = $n -match '^[A-Za-z0-9_-]{1,20}$' -and -not ($existing | Where-Object Name -eq $n)
        if (-not $ok) { Write-Host '  Use 1-20 letters/numbers, not already used.' -ForegroundColor Yellow }
    } until ($ok)
    do { $login = (Read-Host 'MT5 account number').Trim() } until ($login -match '^\d+$')
    $password = Read-Plain 'MT5 password (trading password, not the investor one)'
    $server = (Read-Host 'MT5 server exactly as in Exness, e.g. Exness-MT5Real8 or Exness-MT5Trial15').Trim()
    Write-Host "`nPractice mode uses real prices but sends NO orders (nothing appears in MT5 / Exness history)."
    $real = (Read-Host 'Type REAL to send real orders to this account, or press Enter for practice') -ceq 'REAL'
    do {
        $dash = Read-Plain 'Choose a dashboard password (10+ characters)'
        $ok = $dash.Length -ge 10 -and $dash -eq (Read-Plain 'Repeat the dashboard password')
        if (-not $ok) { Write-Host '  Too short or not the same. Try again.' -ForegroundColor Yellow }
    } until ($ok)

    $term = Join-Path $Root "terminals\$n"
    if (-not (Test-Path (Join-Path $term 'terminal64.exe'))) {
        $base = Find-BaseTerminal
        Write-Host "Copying MetaTrader 5 to $term ..."
        New-Item -ItemType Directory -Force (Split-Path $term) | Out-Null
        Copy-Item $base $term -Recurse -Force
    }

    Push-Location (Join-Path $App 'backend')
    try {
        # Via an env var, not a pipe: PS 5.1 puts a BOM in front of piped text. Not on the command line either.
        $env:GC_DASH_PW = $dash
        $hash = & $Py -c "import os; from app.security import hash_password; print(hash_password(os.environ['GC_DASH_PW']))"
        if ($LASTEXITCODE -ne 0 -or -not $hash) { throw 'Could not create the dashboard password hash.' }
    } finally { Remove-Item Env:GC_DASH_PW -ErrorAction SilentlyContinue; Pop-Location }

    $port = 8001
    while ($existing | Where-Object Port -eq $port) { $port++ }
    New-AccountFiles -AccountName $n -Login $login -Password $password -Server $server -Real $real `
        -DashHash $hash -Port $port -TerminalExe (Join-Path $term 'terminal64.exe') | Out-Null
    Register-Account $n $port
    Write-Host "`nAccount '$n' added: dashboard http://127.0.0.1:$port (user: admin). It starts by itself when Windows logs on." -ForegroundColor Green
    Write-Host 'In the new MT5 window that opens, click "Algo Trading" once (it must be green for real orders).' -ForegroundColor Yellow
    Start-Bot $n
    Start-Process "http://127.0.0.1:$port/"
}

function Start-Bot([string]$AccountName) {
    foreach ($a in @(Get-Accounts)) {
        if ($AccountName -and $a.Name -ne $AccountName) { continue }
        if ($a.Running) { Write-Host "  $($a.Name): already running"; continue }
        Start-ScheduledTask -TaskName "GoldCycle-$($a.Name)"
        Write-Host "  $($a.Name): starting ..." -NoNewline
        $up = $false
        foreach ($i in 1..45) {
            Start-Sleep -Seconds 2
            try { $up = (Invoke-WebRequest "http://127.0.0.1:$($a.Port)/health" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } catch { $up = $false }
            if ($up) { break }
        }
        if ($up) { Write-Host " ready: http://127.0.0.1:$($a.Port)" -ForegroundColor Green }
        else { Write-Host " not answering yet. Look at the account's MT5 window (login box / wrong server?) and logs\console.log" -ForegroundColor Yellow }
    }
}

function Stop-Tree([int]$ProcId) {
    # The bot's cmd + python, but NOT the MT5 terminal: mt5.initialize() starts it as a child of the bot,
    # and closing the bot must leave the trader's MT5 running. Parent first, so start.bat's restart loop
    # cannot start a new python between the two kills.
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcId" | Where-Object { $_.Name -ne 'terminal64.exe' })
    Stop-Process -Id $ProcId -Force -ErrorAction SilentlyContinue
    foreach ($c in $children) { Stop-Tree $c.ProcessId }
}

function Stop-Mt5([string]$AccountName) {
    # Closes the account's own MT5 window (the terminal the bot started). Open trades stay on the broker.
    foreach ($a in @(Get-Accounts)) {
        if ($AccountName -and $a.Name -ne $AccountName) { continue }
        if (-not $a.Mt5Path) { continue }
        $procs = @(Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $a.Mt5Path })
        foreach ($p in $procs) { [void]$p.CloseMainWindow() }
        for ($i = 0; $i -lt 10 -and @($procs | Where-Object { -not $_.HasExited }).Count; $i++) { Start-Sleep -Seconds 1 }
        foreach ($p in $procs) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
        Write-Host "  $($a.Name): MT5 closed"
    }
}

function Restart-All([string]$AccountName) {
    Stop-Bot $AccountName
    Stop-Mt5 $AccountName
    Start-Sleep -Seconds 3
    Start-Bot $AccountName
}

function Select-Account {
    # One account: no question. Several: ask which one (Enter = all). Returns '' for all.
    $list = @(Get-Accounts)
    if ($list.Count -le 1) { return '' }
    Show-Accounts
    $n = (Read-Host 'Which account? (name, or press Enter for ALL)').Trim()
    if ($n -and -not ($list | Where-Object Name -eq $n)) { throw "No account '$n'." }
    return $n
}

function Confirm-Stop {
    Write-Host 'Open trades stay on Exness with their TP/SL. While the bot is stopped it will not open the next order.' -ForegroundColor Yellow
    return ((Read-Host 'Continue? (y/n)') -eq 'y')
}

function Repair-Accounts {
    # Rewrites every account's launcher + logon task from the current code (an account made by an older
    # version gets the hidden, self-restarting launcher), and removes tasks left by older versions.
    foreach ($a in @(Get-Accounts)) {
        New-Item -ItemType Directory -Force (Join-Path $a.Dir 'logs') | Out-Null
        Write-Launchers $a.Name $a.Port
        Register-Account $a.Name $a.Port
        Write-Host "  $($a.Name): launcher updated (runs hidden, restarts itself if it crashes)"
    }
}

function Stop-Bot([string]$AccountName) {
    foreach ($a in @(Get-Accounts)) {
        if ($AccountName -and $a.Name -ne $AccountName) { continue }
        Stop-ScheduledTask -TaskName "GoldCycle-$($a.Name)" -ErrorAction SilentlyContinue
        foreach ($p in @(Get-BotProcess $a.Name)) { Stop-Tree $p.ProcessId }
        Write-Host "  $($a.Name): stopped"
    }
}

function Switch-Mode([string]$AccountName) {
    if (-not $AccountName) { Show-Accounts; $AccountName = Read-Host 'Account name' }
    $a = @(Get-Accounts) | Where-Object Name -eq $AccountName
    if (-not $a) { throw "No account '$AccountName'." }
    if ($a.Real) {
        $to = 'true'; Write-Host "$AccountName -> PRACTICE (no orders sent)."
    } else {
        Write-Host 'Before real orders: Algo Trading must be ON in that MT5 window, and no other EA may trade this account.' -ForegroundColor Yellow
        if ((Read-Host "Type REAL to send real orders from '$AccountName'") -cne 'REAL') { Write-Host 'Not changed.'; return }
        $to = 'false'
    }
    $text = [IO.File]::ReadAllText($a.EnvFile) -replace '(?m)^DRY_RUN=.*$', "DRY_RUN=$to"
    [IO.File]::WriteAllText($a.EnvFile, $text, $Utf8)
    Write-Host 'Restarting the bot ...'
    Stop-Bot $AccountName; Start-Sleep -Seconds 2; Start-Bot $AccountName
}

function Update-App {
    $running = @(Get-Accounts | Where-Object Running | ForEach-Object Name)
    if ($running.Count) {
        Write-Host 'Bots will restart. Open trades keep their TP/SL on the broker; the dashboard asks "Resume?" afterwards.' -ForegroundColor Yellow
        if ((Read-Host 'Continue? (y/n)') -ne 'y') { return }
        Stop-Bot ''
    }
    Invoke-Native 'git pull' { git -C $App pull --ff-only }
    Install-App
    Repair-Accounts
    foreach ($n in $running) { Start-Bot $n }
    Write-Host 'Updated. Open dashboard pages reconnect by themselves.' -ForegroundColor Green
}

function Install-All {
    Install-App
    Repair-Accounts
    $old = Get-ScheduledTask -TaskName 'GoldCycle' -ErrorAction SilentlyContinue
    if ($old) {
        Disable-ScheduledTask -TaskName 'GoldCycle' | Out-Null
        Write-Host 'An older GoldCycle auto-start was found and turned off, so two bots never trade one account.' -ForegroundColor Yellow
        Write-Host 'If its window is still open, close it.' -ForegroundColor Yellow
    }
    $desk = [Environment]::GetFolderPath('Desktop')
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $desk 'GoldCycle Manager.lnk'))
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $lnk.Save()
    Write-Host 'Desktop shortcut "GoldCycle Manager" created.' -ForegroundColor Green
    if (@(Get-Accounts).Count -eq 0) { Add-Account }
}

function Show-Menu {
    while ($true) {
        Write-Host "`n==== GoldCycle Manager ($Root) ====" -ForegroundColor Cyan
        Show-Accounts
        Write-Host @'

  What do you want to do?
    1) START the bot            (MetaTrader 5 opens by itself)
    2) STOP the bot             (MetaTrader 5 stays open)
    3) STOP the bot AND MetaTrader 5
    4) RESTART everything       (stop the bot and MetaTrader 5, then start again)
    5) Switch practice <-> real orders
    6) Add another account
    7) Open the dashboard
    8) Update GoldCycle to the newest version
    0) Exit
'@
        try {
            switch (Read-Host 'Type a number') {
                '1' { Start-Bot (Select-Account) }
                '2' { $n = Select-Account; if (Confirm-Stop) { Stop-Bot $n } }
                '3' { $n = Select-Account; if (Confirm-Stop) { Stop-Bot $n; Stop-Mt5 $n } }
                '4' { $n = Select-Account; if (Confirm-Stop) { Restart-All $n } }
                '5' { Switch-Mode '' }
                '6' { Add-Account }
                '7' {
                    Show-Accounts
                    $list = @(Get-Accounts)
                    $a = if ($list.Count -eq 1) { $list[0] } else { $list | Where-Object Name -eq (Read-Host 'Account name') }
                    if ($a) { Start-Process "http://127.0.0.1:$($a.Port)/" }
                }
                '8' { Update-App }
                '0' { return }
            }
        } catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    switch ($Command) {
        'menu' { Show-Menu }
        'install' { Install-All }
        'add' { Add-Account }
        'list' { Show-Accounts }
        'start' { Start-Bot $Name }
        'stop' { Stop-Bot $Name }
        'stop-mt5' { Stop-Bot $Name; Stop-Mt5 $Name }
        'restart' { Restart-All $Name }
        'mode' { Switch-Mode $Name }
        'update' { Update-App }
        'repair' { Repair-Accounts }
        'open' { Start-Process "http://127.0.0.1:$((@(Get-Accounts) | Where-Object Name -eq $Name).Port)/" }
        default { throw "Unknown command '$Command'. Use: install, add, list, start, stop, mode, update, open" }
    }
}

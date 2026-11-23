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
        $mode = if ($a.Real) { 'sends orders' } else { 'practice (no orders sent)' }
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

function Read-Choice([string]$Title, [string[]]$Options) {
    # Numbered multiple choice. Only the numbers shown are accepted; anything else asks again.
    Write-Host "`n$Title"
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ('  {0}) {1}' -f ($i + 1), $Options[$i]) }
    while ($true) {
        $a = "$(Read-Host 'Type a number')".Trim()
        if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $Options.Count) { return [int]$a }
        Write-Host "  Please type a number from 1 to $($Options.Count)." -ForegroundColor Yellow
    }
}

function Find-BaseTerminal {
    $found = @(Get-ChildItem 'C:\Program Files', 'C:\Program Files (x86)' -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'terminal64.exe') } | Sort-Object { $_.Name -notmatch 'EXNESS' })
    if ($found.Count -eq 0) {
        throw 'MetaTrader 5 is not installed on this PC. Download it from your Exness account (Terminals > MT5), install it, then choose "Add another account" again.'
    }
    if ($found.Count -eq 1) { return $found[0].FullName }
    $n = Read-Choice 'Which MetaTrader 5 should the bot use?' @($found | ForEach-Object { $_.FullName })
    return $found[$n - 1].FullName
}

function New-TerminalCopy([string]$AccountName) {
    # The bot gets its OWN copy of MetaTrader 5: a clean terminal with no charts and no expert advisors, so nothing
    # else can trade the account. Returns the path of its terminal64.exe.
    $term = Join-Path $Root "terminals\$AccountName"
    if (-not (Test-Path (Join-Path $term 'terminal64.exe'))) {
        $base = Find-BaseTerminal
        Write-Host "Copying MetaTrader 5 to $term ..."
        New-Item -ItemType Directory -Force (Split-Path $term) | Out-Null
        Copy-Item $base $term -Recurse -Force
    }
    return (Join-Path $term 'terminal64.exe')
}

function Test-Mt5Connection([string]$TerminalExe, [string]$Login, [string]$Password, [string]$Server) {
    # Logs the bot's MetaTrader in for real and reports the result in plain words (see backend\tools\check_mt5.py).
    Write-Host 'Connecting to MetaTrader 5. This can take up to a minute ...'
    $env:GC_MT5_PATH = $TerminalExe; $env:GC_MT5_LOGIN = $Login; $env:GC_MT5_PASSWORD = $Password; $env:GC_MT5_SERVER = $Server
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $line = & $Py (Join-Path $App 'backend\tools\check_mt5.py') 2>$null | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
    } finally {
        $ErrorActionPreference = $prev
        Remove-Item Env:GC_MT5_PATH, Env:GC_MT5_LOGIN, Env:GC_MT5_PASSWORD, Env:GC_MT5_SERVER -ErrorAction SilentlyContinue
    }
    if (-not $line) { return [pscustomobject]@{ ok = $false; hint = 'The connection test could not run. Close every MetaTrader 5 window and try again.' } }
    return ($line | ConvertFrom-Json)
}

function New-AccountFiles {
    param([string]$AccountName, [string]$Login, [string]$Password, [string]$Server,
        [string]$DashHash, [int]$Port, [string]$TerminalExe)
    $dir = Join-Path $Root "accounts\$AccountName"
    New-Item -ItemType Directory -Force (Join-Path $dir 'data'), (Join-Path $dir 'logs') | Out-Null
    $magic = 7700501 + ($Port - 8000) * 10   # unique per account; Single uses magic+1
    $envText = @(
        "# GoldCycle account '$AccountName'. Written by the GoldCycle Manager. Restart the bot after editing.",
        '# DRY_RUN=false: orders go to the account (a demo account trades demo money, a real one real money).',
        'BROKER=mt5',
        'DRY_RUN=false',
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

function Read-AccountDetails([object[]]$Existing) {
    # Only what is needed: kind of account, its number, the server number and the password.
    $kind = Read-Choice 'What kind of Exness account is this?' @('A real account (real money)', 'A demo account (practice money)')
    $word = if ($kind -eq 1) { 'Real' } else { 'Trial' }
    while ($true) {
        $login = "$(Read-Host 'MT5 account number (digits only, as shown in your Exness account)')".Trim()
        if ($login -notmatch '^\d{5,12}$') { Write-Host '  That does not look like an account number. Digits only, for example 474902598.' -ForegroundColor Yellow; continue }
        if ($Existing | Where-Object { $_.Login -eq $login -or $_.Name -eq $login }) { Write-Host "  Account $login is already added." -ForegroundColor Yellow; continue }
        break
    }
    while ($true) {
        Write-Host "`nServer: the number at the end of your server name. Exness-MT5${word}8 -> type 8. No number at the end -> just press Enter."
        $num = "$(Read-Host 'Server number')".Trim()
        if ($num -match '^\d{0,3}$') { $server = "Exness-MT5$word$num"; break }
        if ($num -match '^[A-Za-z0-9._-]+$') { $server = $num; break }   # he typed the whole server name: use it as it is
        Write-Host '  Type only the number (for example 8), or press Enter.' -ForegroundColor Yellow
    }
    $password = Read-Plain "`nMT5 password (the TRADING password; typing is hidden)"
    while ($true) {
        $dash = Read-Plain 'Dashboard password: what you will type to open the bot page. Press Enter to use the MT5 password'
        if (-not $dash) { $dash = $password; break }
        if ($dash.Length -ge 8) { break }
        Write-Host '  Use at least 8 characters, or press Enter.' -ForegroundColor Yellow
    }
    return @{ Login = $login; Server = $server; Password = $password; Dash = $dash }
}

function Add-Account {
    Write-Host "`n=== Add an MT5 account ===" -ForegroundColor Cyan
    $existing = @(Get-Accounts)
    $d = Read-AccountDetails $existing
    Write-Host @'

A second MetaTrader 5 window opens now. It is the bot's own MetaTrader: leave it open (you can minimize it).
Your usual MetaTrader 5 is not changed.
'@ -ForegroundColor Yellow
    $termExe = New-TerminalCopy $d.Login

    while ($true) {   # nothing is saved until the account really connects
        $r = Test-Mt5Connection $termExe $d.Login $d.Password $d.Server
        if ($r.ok) { break }
        Write-Host "`nNot connected: $($r.hint)" -ForegroundColor Red
        switch (Read-Choice 'What do you want to do?' @('Try again with the same details', 'Type the account details again', 'Cancel (nothing is saved)')) {
            2 { $d = Read-AccountDetails $existing; if (-not (Test-Path $termExe)) { $termExe = New-TerminalCopy $d.Login } }
            3 { Write-Host 'Nothing was saved.'; return }
        }
    }
    $n = "$($d.Login)"   # the account number is the account's name (folder, task, shortcut)
    $kind = if ($r.demo) { 'DEMO' } else { 'REAL' }
    Write-Host ("`nConnected: account #{0} on {1} ({2}), balance {3} {4}." -f $r.login, $r.server, $kind, $r.balance, $r.currency) -ForegroundColor Green
    if (-not $r.algo) {
        if (Enable-AlgoTrading $termExe) {
            Write-Host 'Algo Trading was switched on for the bot''s MetaTrader (the bot needs it to send orders).' -ForegroundColor Green
        } else {
            Write-Host 'One thing left: in the bot''s MetaTrader window click the "Algo Trading" button at the top so it turns GREEN. Without it no orders can be sent.' -ForegroundColor Yellow
        }
    }

    Push-Location (Join-Path $App 'backend')
    try {
        # Via an env var, not a pipe: PS 5.1 puts a BOM in front of piped text. Not on the command line either.
        $env:GC_DASH_PW = $d.Dash
        $hash = & $Py -c "import os; from app.security import hash_password; print(hash_password(os.environ['GC_DASH_PW']))"
        if ($LASTEXITCODE -ne 0 -or -not $hash) { throw 'Could not create the dashboard password hash.' }
    } finally { Remove-Item Env:GC_DASH_PW -ErrorAction SilentlyContinue; Pop-Location }

    $port = 8001
    while ($existing | Where-Object Port -eq $port) { $port++ }
    New-AccountFiles -AccountName $n -Login $d.Login -Password $d.Password -Server $d.Server `
        -DashHash $hash -Port $port -TerminalExe $termExe | Out-Null
    Register-Account $n $port
    Write-Host "`nAccount $n added. Dashboard: http://127.0.0.1:$port  (user: admin). It starts by itself when Windows logs on." -ForegroundColor Green
    Start-Bot $n
    if ((Get-BotHealth $port).connected) { Start-Process "http://127.0.0.1:$port/" }
}

function Get-BotHealth([int]$Port) {
    try { return (Invoke-WebRequest "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 2).Content | ConvertFrom-Json } catch { return $null }
}

function Start-Bot([string]$AccountName) {
    foreach ($a in @(Get-Accounts)) {
        if ($AccountName -and $a.Name -ne $AccountName) { continue }
        if ($a.Running) { Write-Host "  $($a.Name): already running"; continue }
        Start-ScheduledTask -TaskName "GoldCycle-$($a.Name)"
        Write-Host "  $($a.Name): starting (MetaTrader 5 opens by itself) ..."
        $h = $null
        foreach ($i in 1..60) { Start-Sleep -Seconds 2; $h = Get-BotHealth $a.Port; if ($h) { break } }   # the bot page answers
        for ($i = 0; $h -and -not $h.connected -and $i -lt 30; $i++) { Start-Sleep -Seconds 2; $h = Get-BotHealth $a.Port }   # MT5 login
        if ($h -and $h.connected) {
            Write-Host "  $($a.Name): READY and connected to MetaTrader 5. Dashboard: http://127.0.0.1:$($a.Port)" -ForegroundColor Green
        } elseif ($h) {
            Write-Host "  $($a.Name): running, but NOT connected to MetaTrader 5 yet." -ForegroundColor Yellow
            if ($h.error) { Write-Host "    Reason: $($h.error)" -ForegroundColor Yellow }
            Write-Host "    Look at the bot's own MetaTrader 5 window: is it logged in to account $($a.Login) (green bars at the bottom right)?" -ForegroundColor Yellow
        } else {
            Write-Host "  $($a.Name): the bot did not start. Details: $($a.Dir)\logs\console.log" -ForegroundColor Red
        }
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

function Stop-Terminal([string]$TerminalExe) {
    # Closes that MetaTrader window politely (so it saves its settings), and forces it only if it does not close.
    $procs = @(Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $TerminalExe })
    foreach ($p in $procs) { [void]$p.CloseMainWindow() }
    for ($i = 0; $i -lt 15 -and @($procs | Where-Object { -not $_.HasExited }).Count; $i++) { Start-Sleep -Seconds 1 }
    foreach ($p in $procs) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
}

function Stop-Mt5([string]$AccountName) {
    # Closes the account's own MT5 window (the terminal the bot started). Open trades stay on the broker.
    foreach ($a in @(Get-Accounts)) {
        if ($AccountName -and $a.Name -ne $AccountName) { continue }
        if (-not $a.Mt5Path) { continue }
        Stop-Terminal $a.Mt5Path
        Write-Host "  $($a.Name): MT5 closed"
    }
}

function Enable-AlgoTrading([string]$TerminalExe) {
    # A fresh MetaTrader has "Algo Trading" OFF and refuses every order until someone clicks the button. Nobody should
    # have to: switch it on in the terminal's settings file while the terminal is closed (it reads it at start).
    # Returns $true when done. The bot starts the terminal again by itself.
    $dir = (Split-Path $TerminalExe -Parent).TrimEnd('\')
    $data = Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal" -Directory -ErrorAction SilentlyContinue | Where-Object {
        $o = Join-Path $_.FullName 'origin.txt'
        (Test-Path $o) -and ((Get-Content $o -Raw).Trim().TrimEnd('\') -ieq $dir)
    } | Select-Object -First 1
    if (-not $data) { return $false }
    $ini = Join-Path $data.FullName 'config\common.ini'
    if (-not (Test-Path $ini)) { return $false }
    Stop-Terminal $TerminalExe
    $lines = New-Object System.Collections.ArrayList
    $lines.AddRange(@([IO.File]::ReadAllText($ini) -split "\r?\n"))
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\[Experts\]\s*$') { $start = $i; break } }
    if ($start -lt 0) { [void]$lines.Add('[Experts]'); $start = $lines.Count - 1 }
    # Account=0 / Profile=0: otherwise MetaTrader switches Algo Trading off again when the account or profile changes
    foreach ($kv in @(@('Enabled', '1'), @('Account', '0'), @('Profile', '0'))) {
        $end = $lines.Count
        for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\[') { $end = $i; break } }
        $set = $false
        for ($i = $start + 1; $i -lt $end; $i++) { if ($lines[$i] -match "^$($kv[0])=") { $lines[$i] = "$($kv[0])=$($kv[1])"; $set = $true } }
        if (-not $set) { $lines.Insert($start + 1, "$($kv[0])=$($kv[1])") }
    }
    [IO.File]::WriteAllText($ini, ($lines -join "`r`n"), [Text.Encoding]::Unicode)   # MetaTrader writes UTF-16 with a BOM
    return $true
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
    $c = Read-Choice 'Which account?' (@($list | ForEach-Object { "$($_.Name)  ($($_.Server))" }) + 'All accounts')
    if ($c -gt $list.Count) { return '' }
    return $list[$c - 1].Name
}

function Confirm-Stop {
    Write-Host 'Open trades stay on Exness with their TP/SL. While the bot is stopped it will not open the next order.' -ForegroundColor Yellow
    return ((Read-Choice 'Continue?' @('Yes', 'No')) -eq 1)
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
    # Command-line only (`goldcycle.ps1 mode <name>`): a practice mode for testing. Not in the menu: accounts send orders.
    if (-not $AccountName) { $AccountName = Select-Account }
    $a = @(Get-Accounts) | Where-Object Name -eq $AccountName
    if (-not $a) { throw "No account '$AccountName'." }
    if ($a.Real) {
        if ((Read-Choice "Switch $AccountName to PRACTICE (no orders are sent)?" @('Yes', 'No')) -ne 1) { return }
        $to = 'true'
    } else {
        if ((Read-Choice "Switch $AccountName back to sending orders?" @('Yes', 'No')) -ne 1) { return }
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
        if ((Read-Choice 'Continue?' @('Yes', 'No')) -ne 1) { return }
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
    5) Add another account
    6) Open the dashboard
    7) Update GoldCycle to the newest version
    0) Exit
'@
        try {
            switch ("$(Read-Host 'Type a number')".Trim()) {
                '1' { Start-Bot (Select-Account) }
                '2' { $n = Select-Account; if (Confirm-Stop) { Stop-Bot $n } }
                '3' { $n = Select-Account; if (Confirm-Stop) { Stop-Bot $n; Stop-Mt5 $n } }
                '4' { $n = Select-Account; if (Confirm-Stop) { Restart-All $n } }
                '5' { Add-Account }
                '6' {
                    $n = Select-Account
                    foreach ($a in @(Get-Accounts)) { if (-not $n -or $a.Name -eq $n) { Start-Process "http://127.0.0.1:$($a.Port)/" } }
                }
                '7' { Update-App }
                '0' { return }
                default { Write-Host 'Please type one of the numbers shown above.' -ForegroundColor Yellow }
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

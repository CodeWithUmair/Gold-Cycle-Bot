# GoldCycle one-line installer. In PowerShell **as Administrator**:
#
#   Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/CodeWithUmair/Gold-Cycle-Bot/main/scripts/setup.ps1 | iex
#
# Installs Python / Git / Node if missing, downloads GoldCycle to C:\GoldCycle\app, builds it, then asks
# for the first MT5 account. Running it again is safe: it updates instead of reinstalling.
# (Runs through `iex`: no param block, and no `exit`: that would close the window.)

# A click inside a Windows console starts "Select" mode and PAUSES everything until Esc (the title then starts with
# "Select"). The install takes minutes and people click; turn that off for this window. Best effort: if it cannot
# be done the install simply runs as before.
try {
    Add-Type -Namespace GC -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint mode);
'@
    $gcIn = [GC.Con]::GetStdHandle(-10)
    $gcMode = [uint32]0
    if ([GC.Con]::GetConsoleMode($gcIn, [ref]$gcMode)) { [void][GC.Con]::SetConsoleMode($gcIn, [uint32](($gcMode -band 0xFFFFFFBF) -bor 0x80)) }
} catch { $null = $_ }

function Install-GoldCycle {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on PS 5.1
    $repo = 'https://github.com/CodeWithUmair/Gold-Cycle-Bot.git'
    # Same command everywhere: an install that already exists on this PC (found through its logon tasks,
    # wherever it was put) is UPDATED; otherwise a new one goes to C:\GoldCycle. Never a second copy.
    $root = $env:GOLDCYCLE_ROOT
    if (-not $root) {
        foreach ($t in @(Get-ScheduledTask -TaskName 'GoldCycle-*' -ErrorAction SilentlyContinue)) {
            if ("$($t.Actions[0].Arguments)" -match '"?([A-Za-z]:\\[^"]*?)\\accounts\\[^\\"]+\\(launch\.vbs|start\.bat)') { $root = $Matches[1]; break }
        }
    }
    if (-not $root) { $root = 'C:\GoldCycle' }
    $app = Join-Path $root 'app'
    $existing = Test-Path (Join-Path $app '.git')
    if ($existing) { Write-Host "GoldCycle is already installed in $root : updating it." -ForegroundColor Cyan }

    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Close this window, right-click PowerShell > "Run as administrator", and paste the command again.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    function Update-Path {
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }
    function Install-From([string]$What, [string]$Url, [string]$InstallArgs) {
        Write-Host "Installing $What ..." -ForegroundColor Cyan
        $file = Join-Path $env:TEMP (Split-Path $Url -Leaf)
        Invoke-WebRequest $Url -OutFile $file -UseBasicParsing
        if ($file.EndsWith('.msi')) { $p = Start-Process msiexec.exe "/i `"$file`" $InstallArgs" -Wait -PassThru }
        else { $p = Start-Process $file $InstallArgs -Wait -PassThru }
        if ($p.ExitCode -ne 0) { throw "$What installer failed (exit code $($p.ExitCode))" }
        Update-Path
    }
    function Test-Python {
        # The Windows Store "python" stub prints nothing useful, so ask for the version explicitly
        try { return ((& python -c 'import sys;print(int(sys.version_info>=(3,11)))' 2>$null) -eq '1') } catch { return $false }
    }

    Update-Path
    if (-not (Test-Python)) {
        Install-From 'Python 3.12' 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0'
        if (-not (Test-Python)) { throw 'Python was installed but is not on PATH. Close this window, open a new Administrator PowerShell and run the command again.' }
    } else { Write-Host 'Python: OK' }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Install-From 'Git' 'https://github.com/git-for-windows/git/releases/download/v2.51.0.windows.1/Git-2.51.0-64-bit.exe' '/VERYSILENT /NORESTART /NOCANCEL /SP-'
    } else { Write-Host 'Git: OK' }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Install-From 'Node.js 22' 'https://nodejs.org/dist/v22.20.0/node-v22.20.0-x64.msi' '/qn /norestart'
    } else { Write-Host 'Node.js: OK' }

    if ($existing) {
        git -C $app pull --ff-only
    } else {
        Write-Host "Downloading GoldCycle to $app ..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Force $root | Out-Null
        git clone $repo $app
    }
    if ($LASTEXITCODE -ne 0) { throw 'Downloading GoldCycle failed (see the git message above).' }

    $mode = if ($existing) { 'update' } else { 'install' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\goldcycle.ps1') $mode
    if ($LASTEXITCODE -ne 0) { throw 'The GoldCycle Manager stopped with an error (see the message above).' }

    # Do not end on "Finished": show the menu now (start / stop / restart / add account / fix a login ...).
    Write-Host ''
    Write-Host 'Opening the GoldCycle Manager menu ...' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\goldcycle.ps1')
}

try { Install-GoldCycle } catch {
    Write-Host "`nSETUP STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    if ($PSCommandPath) { exit 1 }   # run as a file (GoldCycle-Setup.bat): report the failure. Under `iex` there is no path and the window must stay open.
}

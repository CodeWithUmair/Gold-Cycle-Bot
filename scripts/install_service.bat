@echo off
REM Install GoldCycle as a Windows service with NSSM (https://nssm.cc).
REM Run as Administrator. nssm.exe must be on PATH (or next to this script).
REM
REM Uninstall:   nssm stop GoldCycle  &&  nssm remove GoldCycle confirm
REM Status:      nssm status GoldCycle
REM Restart:     nssm restart GoldCycle
REM
REM Note: the MT5 terminal must run in the SAME Windows user session the service can reach.
REM If the service cannot attach to the terminal, set the service to log on as your user:
REM   nssm set GoldCycle ObjectName .\YourUser YourPassword
setlocal
set ROOT=%~dp0..
for %%I in ("%ROOT%") do set ROOT=%%~fI
set BACKEND=%ROOT%\backend
set PY=%BACKEND%\.venv\Scripts\python.exe

if not exist "%PY%" (
    echo Run scripts\install.bat first.
    exit /b 1
)
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"

nssm install GoldCycle "%PY%" -m app.main || exit /b 1
nssm set GoldCycle AppDirectory "%BACKEND%"
nssm set GoldCycle DisplayName "GoldCycle MT5 Bot"
nssm set GoldCycle Description "GoldCycle XAUUSD TP/SL cycle bot + dashboard on 127.0.0.1"
nssm set GoldCycle Start SERVICE_AUTO_START
nssm set GoldCycle AppStdout "%ROOT%\logs\service.log"
nssm set GoldCycle AppStderr "%ROOT%\logs\service.log"
nssm set GoldCycle AppRotateFiles 1
nssm set GoldCycle AppRotateBytes 10485760
nssm set GoldCycle AppExit Default Restart
nssm set GoldCycle AppRestartDelay 5000

nssm start GoldCycle
echo Service installed. Dashboard: http://127.0.0.1:8000

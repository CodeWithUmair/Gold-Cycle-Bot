@echo off
title GoldCycle Setup
REM Double-click this file. It installs GoldCycle (or updates it if it is already installed).
REM It needs Administrator rights: Windows asks once; click Yes.
REM Everything goes to C:\GoldCycle (or, if GoldCycle is already installed on this PC, where it already is).
REM (No parentheses blocks below on purpose: a file name like "GoldCycle-Setup (1).bat" would break them.)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

net session >nul 2>&1
if errorlevel 1 goto :ask_permission
goto :run

:ask_permission
echo Windows will now ask for permission. Please click Yes.
"%PS%" -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:run
echo.
echo ==== GoldCycle Setup ====
echo This installs what is missing (Python, Git, Node.js), downloads GoldCycle and sets it up.
echo Please wait and do not click inside this window. It can take a few minutes.
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; $ErrorActionPreference='Stop'; try { $f = Join-Path $env:TEMP 'goldcycle-setup.ps1'; Invoke-WebRequest 'https://raw.githubusercontent.com/CodeWithUmair/Gold-Cycle-Bot/main/scripts/setup.ps1' -OutFile $f -UseBasicParsing; & $f } catch { Write-Host ('SETUP COULD NOT START: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }"
set "CODE=%errorlevel%"
echo.
if not "%CODE%"=="0" echo Something went wrong (code %CODE%). Please take a photo or screenshot of this window and send it.
if "%CODE%"=="0" echo ==== Finished. You can close this window. ====
if "%CODE%"=="0" echo From now on use the "GoldCycle Manager" icon on your Desktop.
pause

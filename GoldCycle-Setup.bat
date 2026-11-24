@echo off
title GoldCycle Setup
REM Double-click this file. It installs GoldCycle (or updates it if it is already installed).
REM It needs Administrator rights: Windows asks once; click Yes.
REM Everything goes to C:\GoldCycle (or, if GoldCycle is already installed on this PC, where it already is).
REM (No parentheses blocks below on purpose: a file name like "GoldCycle-Setup (1).bat" would break them.)
REM The installer script is downloaded to a file first and then run as a file: a single PowerShell command line
REM that downloads and runs code in one go is exactly what antivirus programs react to.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "URL=https://raw.githubusercontent.com/CodeWithUmair/Gold-Cycle-Bot/main/scripts/setup.ps1"
set "SCRIPT=%TEMP%\goldcycle-setup.ps1"

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
del "%SCRIPT%" >nul 2>&1
where curl.exe >nul 2>&1
if errorlevel 1 goto :download_with_powershell
curl.exe -fsSL -o "%SCRIPT%" "%URL%"
goto :downloaded

:download_with_powershell
"%PS%" -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest '%URL%' -OutFile '%SCRIPT%' -UseBasicParsing"

:downloaded
if not exist "%SCRIPT%" goto :download_failed
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "CODE=%errorlevel%"
goto :finish

:download_failed
echo Could not download the installer. Check the internet connection and try again.
set "CODE=1"

:finish
echo.
if not "%CODE%"=="0" echo Something went wrong (code %CODE%). Please take a photo or screenshot of this window and send it.
if "%CODE%"=="0" echo ==== Finished. You can close this window. ====
if "%CODE%"=="0" echo From now on use the "GoldCycle Manager" icon on your Desktop.
pause

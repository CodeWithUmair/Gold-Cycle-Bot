@echo off
title GoldCycle Setup
REM Double-click this file. It installs GoldCycle (or updates it if it is already installed).
REM It needs Administrator rights: Windows asks once; click Yes.
REM Everything goes to C:\GoldCycle (or, if GoldCycle is already installed on this PC, where it already is).

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Windows will now ask for permission. Please click Yes.
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo ==== GoldCycle Setup ====
echo This installs what is missing (Python, Git, Node.js), downloads GoldCycle and sets it up.
echo Please wait and do not click inside this window. It can take a few minutes.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/CodeWithUmair/Gold-Cycle-Bot/main/scripts/setup.ps1 | iex"
echo.
echo ==== Finished. You can close this window. ====
echo From now on use the "GoldCycle Manager" icon on your Desktop.
pause

@echo off
REM Start GoldCycle in this console. Dashboard: http://127.0.0.1:8000
setlocal
cd /d "%~dp0..\backend"
if not exist ".venv\Scripts\python.exe" (
    echo Run scripts\install.bat first.
    exit /b 1
)
call .venv\Scripts\activate.bat
python -m app.main

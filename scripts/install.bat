@echo off
REM GoldCycle install: Python venv + deps, .env, frontend build.
REM Needs Python 3.11+ and Node 20+ on PATH.
setlocal
set ROOT=%~dp0..
set BACKEND=%ROOT%\backend
set FRONTEND=%ROOT%\frontend

echo === Backend: virtualenv + packages ===
if not exist "%BACKEND%\.venv\Scripts\python.exe" (
    python -m venv "%BACKEND%\.venv" || goto :fail
)
"%BACKEND%\.venv\Scripts\python.exe" -m pip install --upgrade pip || goto :fail
"%BACKEND%\.venv\Scripts\python.exe" -m pip install -r "%BACKEND%\requirements.txt" || goto :fail

echo === .env ===
if not exist "%ROOT%\.env" (
    copy "%ROOT%\.env.example" "%ROOT%\.env" >nul
    echo Created .env from .env.example - edit it before starting.
) else (
    echo .env already exists, left unchanged.
)

echo === Frontend: install + build ===
pushd "%FRONTEND%"
if exist package-lock.json (
    call npm ci || (popd & goto :fail)
) else (
    call npm install || (popd & goto :fail)
)
call npm run build || (popd & goto :fail)
popd

echo.
echo Done. Next:
echo   1. cd backend ^&^& .venv\Scripts\python -m app.security   (paste the hash into .env)
echo   2. Edit .env
echo   3. scripts\start.bat
exit /b 0

:fail
echo.
echo INSTALL FAILED - see the error above.
exit /b 1

@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Image Text Editor - Status

cd /d "%~dp0"
set "PIDFILE=.run\server.pid"
set "PORT=7860"
set "OWNER="
for /f "tokens=5" %%p in ('netstat -ano ^| findstr /R /C:":%PORT% .*LISTENING"') do if not defined OWNER set "OWNER=%%p"

if defined OWNER (
    echo [ OK ] Running ^(PID !OWNER!^), port %PORT%
    echo         URL : http://127.0.0.1:%PORT%
    if exist "%PIDFILE%" (
        set /p PID=<"%PIDFILE%"
        if not "!PID!"=="!OWNER!" echo [WARN] PID file says !PID!, real listener is !OWNER!. Run stop.bat then start.bat.
    )
) else (
    echo [WARN] Image Text Editor is not running.
)
echo.
pause
exit /b 0

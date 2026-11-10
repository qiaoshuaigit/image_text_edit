@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Image Text Editor - Stopping

cd /d "%~dp0"

set "PIDFILE=.run\server.pid"
set "PORT=7860"
set "HIT=0"

:: 1. stop by PID file
if not exist "%PIDFILE%" goto by_port
set /p PID=<"%PIDFILE%"
echo [INFO] Stopping PID !PID! ...
taskkill /PID !PID! /T /F >nul 2>&1
if not errorlevel 1 set "HIT=1"
del /q "%PIDFILE%" >nul 2>&1

:: 2. fallback: stop whatever listens on the port
:by_port
for /f "tokens=5" %%p in ('netstat -ano ^| findstr /R /C:":%PORT% .*LISTENING"') do (
    echo [INFO] Port %PORT% held by PID %%p, terminating ...
    taskkill /PID %%p /T /F >nul 2>&1
    set "HIT=1"
)

if "%HIT%"=="0" echo [WARN] Image Text Editor is not running.
if "%HIT%"=="1" echo [ OK ] Image Text Editor stopped.
echo.
pause
exit /b 0

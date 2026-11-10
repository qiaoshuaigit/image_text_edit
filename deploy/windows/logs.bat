@echo off
setlocal EnableExtensions
title Image Text Editor - Logs
cd /d "%~dp0"
if not exist "logs\server.log" (
    echo No log file yet: logs\server.log
    pause
    exit /b 1
)
echo ---------- last 100 lines of logs\server.log ----------
powershell -NoProfile -Command "Get-Content 'logs\server.log' -Tail 100 -Wait"
exit /b 0

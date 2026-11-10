@echo off
title Image Text Editor - Restarting
echo [INFO] Restarting Image Text Editor ...
echo.
call "%~dp0stop.bat"
ping -n 3 127.0.0.1 >nul
call "%~dp0start.bat"
exit /b %errorlevel%

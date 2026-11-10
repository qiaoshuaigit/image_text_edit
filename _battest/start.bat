@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Image Text Editor - Starting

cd /d "%~dp0"
mkdir ".run" 2>nul
mkdir "logs" 2>nul
mkdir "output" 2>nul

set "PIDFILE=.run\server.pid"
set "LOGFILE=%~dp0logs\server.log"
set "PORT=7860"

:: read python recorded by install.bat
set "PY="
if exist "python_cmd.txt" set /p PY=<python_cmd.txt
if not defined PY (
    py -3 -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" >nul 2>&1
    if not errorlevel 1 set "PY=py -3"
)
if not defined PY (
    :: common install locations (PATH may not be refreshed yet)
    for %%d in ("%LOCALAPPDATA%\Programs\Python\Python313" "%LOCALAPPDATA%\Programs\Python\Python312" "%LOCALAPPDATA%\Programs\Python\Python311" "%LOCALAPPDATA%\Programs\Python\Python310" "%ProgramFiles%\Python313" "%ProgramFiles%\Python312" "%ProgramFiles%\Python311" "%ProgramFiles%\Python310") do (
        if not defined PY if exist "%%~d\python.exe" set "PY=%%~d\python.exe"
    )
)
if not defined PY goto no_python

:: already running?
if not exist "%PIDFILE%" goto check_port
set /p OLDPID=<"%PIDFILE%"
tasklist /FI "PID eq !OLDPID!" 2>nul | findstr /I "python" >nul
if not errorlevel 1 goto already_running
del /q "%PIDFILE%" >nul 2>&1

:check_port
for /f "tokens=5" %%p in ('netstat -ano ^| findstr /R /C:":%PORT% .*LISTENING"') do (
    echo [ERROR] Port %PORT% is already in use by PID %%p.
    echo         Run stop.bat first, or close that process.
    pause
    exit /b 1
)

echo [INFO] Starting Image Text Editor ...
echo [INFO] Python : %PY%
echo [INFO] Log    : %LOGFILE%
echo.

:: build a tiny launcher so the python command with spaces works reliably
> ".run\launcher.bat" echo @echo off
>> ".run\launcher.bat" echo cd /d "%~dp0"
>> ".run\launcher.bat" echo %PY% -u image_text_editor.py 1^>^> "%~dp0logs\server.log" 2^>^&1

:: start hidden in background
start "" /b cmd /c ".run\launcher.bat"

:: health check: wait up to 60s for the port
set "READY="
for /l %%i in (1,1,60) do if not defined READY (
    ping -n 2 127.0.0.1 >nul
    netstat -ano | findstr /R /C:":%PORT% .*LISTENING" >nul && set "READY=1"
)
if not defined READY goto timeout

set "REALPID="
for /f "tokens=5" %%p in ('netstat -ano ^| findstr /R /C:":%PORT% .*LISTENING"') do if not defined REALPID set "REALPID=%%p"
> "%PIDFILE%" echo !REALPID!

echo [ OK ] Started ^(PID !REALPID!^)
echo         URL : http://127.0.0.1:%PORT%
echo         Log : %LOGFILE%
echo         Stop: stop.bat
echo.
pause
exit /b 0

:already_running
echo [WARN] Already running ^(PID !OLDPID!^). URL: http://127.0.0.1:%PORT%
pause
exit /b 0

:no_python
echo [ERROR] Python 3.10+ not found. Run install.bat first.
pause
exit /b 1

:timeout
echo [ERROR] Timeout: port %PORT% not ready within 60s. Check %LOGFILE%
echo ---------- last 30 log lines ----------
powershell -NoProfile -Command "if (Test-Path '%LOGFILE%') { Get-Content '%LOGFILE%' -Tail 30 }"
echo -----------------------------------------
pause
exit /b 1

@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Image Text Editor - Install

:: Image Text Editor v6 - Windows install (English output only)

echo ==========================================
echo   Image Text Editor v6 - Windows Install
echo ==========================================
echo.

echo [1/5] Checking Python 3.10+ ...
set "PY="
where py >nul 2>&1
if not errorlevel 1 (
    py -3 -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" >nul 2>&1
    if not errorlevel 1 set "PY=py -3"
)
if not defined PY (
    python -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" >nul 2>&1
    if not errorlevel 1 set "PY=python"
)
if not defined PY goto no_python
%PY% --version
echo.

echo [2/5] Installing dependencies ...
%PY% -m pip install --upgrade pip -i https://pypi.tuna.tsinghua.edu.cn/simple
%PY% -m pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
if not errorlevel 1 goto verify
echo [WARN] Tsinghua mirror failed, retrying with default PyPI ...
%PY% -m pip install -r requirements.txt
if errorlevel 1 goto install_failed

:verify
echo.
echo [3/5] Verifying dependencies ...
%PY% -c "import sys, cv2, numpy, pandas, gradio, PIL, rapidocr_onnxruntime; print('Python', sys.version.split()[0], 'gradio', gradio.__version__, 'opencv', cv2.__version__)"
if errorlevel 1 goto verify_failed
echo.

echo [4/5] Checking Chinese fonts ...
if exist "%WINDIR%\Fonts\msyh.ttc" echo   OK: Microsoft YaHei found
if not exist "%WINDIR%\Fonts\msyh.ttc" echo   [WARN] Microsoft YaHei missing, fallback font will be used
echo.

echo [5/5] Writing launcher config ...
> "python_cmd.txt" echo %PY%
echo   OK: python_cmd.txt written
mkdir ".run" 2>nul
mkdir "logs" 2>nul
mkdir "output" 2>nul
echo.

echo ==========================================
echo   INSTALL COMPLETE
echo ==========================================
echo   Start : start.bat
echo   Stop  : stop.bat
echo   URL   : http://127.0.0.1:7860
echo.
pause
exit /b 0

:no_python
echo [WARN] Python 3.10+ not found. gradio 6 requires Python 3.10 or newer.
echo        Trying to install Python 3.12 via winget ...
winget install Python.Python.3.12 --accept-source-agreements --accept-package-agreements
echo.
:: PATH is not refreshed in this window, so locate the new interpreter directly
set "NEWPY="
for %%d in ("%LOCALAPPDATA%\Programs\Python\Python312" "%LOCALAPPDATA%\Programs\Python\Python311" "%LOCALAPPDATA%\Programs\Python\Python310") do (
    if not defined NEWPY if exist "%%~d\python.exe" set "NEWPY=%%~d\python.exe"
)
if defined NEWPY (
    echo   Found new interpreter: !NEWPY!
    "!NEWPY!" --version
    echo !NEWPY!> "python_cmd.txt"
    echo   OK: python_cmd.txt written, start.bat can find it now.
    echo.
    echo  Next step: run install.bat AGAIN to install dependencies.
)
echo  Close this window, open a NEW cmd window, then run install.bat again.
pause
exit /b 0

:install_failed
echo [ERROR] Dependency install failed. Check network and run install.bat again.
pause
exit /b 1

:verify_failed
echo [ERROR] Verification failed. Missing one of: cv2 numpy pandas gradio PIL rapidocr_onnxruntime
pause
exit /b 1

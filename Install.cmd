@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0installer\Gui.ps1" -InitialAction Install %*
set "result=%errorlevel%"
if not "%result%"=="0" (
    echo The installer window could not start. Exit code: %result%
    pause
)
exit /b %result%

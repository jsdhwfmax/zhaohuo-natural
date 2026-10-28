@echo off
setlocal
rem Run the offline package updater; it never starts the game.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Update-Manager.ps1"
set "UPDATE_EXIT=%errorlevel%"
if not "%UPDATE_EXIT%"=="0" pause
exit /b %UPDATE_EXIT%

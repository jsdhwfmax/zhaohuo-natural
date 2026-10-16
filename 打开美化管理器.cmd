@echo off
setlocal
call "%~dp0Install.cmd" %*
exit /b %errorlevel%

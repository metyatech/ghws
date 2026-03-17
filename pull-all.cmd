@echo off
:: One-click launcher for pull-all.ps1
:: Double-click this file in Explorer to pull all workspace repositories.
:: Pauses after completion so the output is readable before the window closes.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\pull-all.ps1"
set EXITCODE=%ERRORLEVEL%
echo.
pause
exit /b %EXITCODE%

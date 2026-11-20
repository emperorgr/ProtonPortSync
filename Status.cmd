@echo off
title ProtonPortSync status
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ProtonPortSync.ps1" -Status
echo.
pause

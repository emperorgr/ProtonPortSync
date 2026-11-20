@echo off
title ProtonPortSync setup
echo.
echo  ProtonPortSync - one-time setup
echo  ================================
echo  You will be asked for your qBittorrent WebUI password.
echo  It is stored encrypted (Windows DPAPI, this user account only).
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ProtonPortSync.Setup.ps1" -RegisterStartup
echo.
pause

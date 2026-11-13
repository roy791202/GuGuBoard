@echo off
chcp 65001 >nul
rem 外部監看通道：缺少 cloudflared 會自動安裝
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-tunnel.ps1" %*
if errorlevel 1 pause

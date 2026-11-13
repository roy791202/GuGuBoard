@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-board.ps1"
if errorlevel 1 pause

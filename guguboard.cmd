@echo off
chcp 65001 >nul
rem GuGuBoard 指令（Windows）：guguboard mcp install <client> [-Token ...]；其他指令交給 start-board.cmd
if /I "%~1"=="mcp" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0guguboard-mcp.ps1" %2 %3 %4 %5 %6 %7 %8 %9
  exit /b %ERRORLEVEL%
)
call "%~dp0start-board.cmd" %*

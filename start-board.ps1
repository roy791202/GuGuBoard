# SPDX-License-Identifier: Apache-2.0
# 一鍵啟動看板：直接啟動伺服器並開啟瀏覽器。第一次使用時在網頁上建立管理員帳號與專案。
$ErrorActionPreference = 'Stop'
try {
  $serve = Join-Path $PSScriptRoot 'serve-board.ps1'
  Write-Host '=== GuGuBoard 進度看板 ===' -ForegroundColor Cyan
  Write-Host '啟動中… 瀏覽器會自動開啟 http://localhost:8765/ （關閉這個視窗即停止看板）' -ForegroundColor Green
  & $serve -InitGit
} catch {
  Write-Host ''
  Write-Host "看板啟動失敗：$($_.Exception.Message)" -ForegroundColor Red
  Write-Host "位置：$($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
  Write-Host '常見原因：port 8765 已被占用（看板可能已經在執行，直接開 http://localhost:8765/ 即可）。'
  [void](Read-Host '按 Enter 關閉視窗')
  exit 1
}

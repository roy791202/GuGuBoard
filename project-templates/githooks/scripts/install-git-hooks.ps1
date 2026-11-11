<#
.SYNOPSIS  啟用（或用 -Uninstall 停用）本專案的 Git hooks：git config core.hooksPath .githooks
#>
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$root = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $root) { throw '這個資料夾不是 git repo，請在專案 repo 內執行' }
$cur = (& git -C $root config --get core.hooksPath 2>$null)
if ($Uninstall) {
  if ($cur -eq '.githooks') { & git -C $root config --unset core.hooksPath; Write-Host '已停用 .githooks' } else { Write-Host "core.hooksPath 目前是「$cur」，不是 .githooks，不變更" }
  return
}
if ($cur -and $cur -ne '.githooks') { Write-Warning "原本的 core.hooksPath 是「$cur」，將改成 .githooks（原本的 hooks 不會再執行，請自行合併）" }
& git -C $root config core.hooksPath .githooks
if ($IsWindows -eq $false) { & chmod +x (Join-Path $root '.githooks/pre-commit') (Join-Path $root '.githooks/commit-msg') }
Write-Host '已啟用 .githooks（pre-commit：board.json／略過測試／版本同步；commit-msg：Conventional Commits）'

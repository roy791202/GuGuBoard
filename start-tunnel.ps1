# SPDX-License-Identifier: Apache-2.0
<#
.SYNOPSIS  GuGuBoard 外部監看：用 Cloudflare Tunnel 或 Tailscale Funnel 把本機看板開成 HTTPS 網址（只讀監看，預設關閉）。
.DESCRIPTION
  1. 先在看板「👥 帳號 → Google 整合 → 外部監看」設定 Google OAuth client、允許的 email／網域並啟用。
  2. 執行本腳本；缺少 cloudflared／tailscale 會自動安裝（問一次，預設是），然後顯示 https 網址。
  3. 把網址填回「公開網址」（Google OAuth 的重新導向 URI 設成 <網址>/api/google/callback）。
  也可以直接在看板設定按「自動安裝並啟動通道」。外部連線一律唯讀。按 Ctrl+C 結束通道。
.EXAMPLE  .\start-tunnel.ps1 -Provider cloudflare -Port 8765
.EXAMPLE  .\start-tunnel.ps1 -Provider tailscale
#>
param([ValidateSet('cloudflare', 'tailscale')][string]$Provider = 'cloudflare', [int]$Port = 8765, [switch]$Yes, [switch]$NoPause)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deps.ps1') -Yes:$Yes
$code = 0
try {
  if ($Provider -eq 'cloudflare') {
    $exe = Use-GgTool cloudflared; if (-not $exe) { throw '沒有 cloudflared，無法建立通道' }
    Write-Host "啟動 Cloudflare Tunnel → http://localhost:$Port（網址出現後填到看板的「公開網址」）" -ForegroundColor Green
    # HttpListener 只接受 Host=localhost，通道的公開主機名稱會被回 400 Invalid Hostname，所以改寫 Host 標頭
    & $exe tunnel --no-autoupdate --http-host-header "localhost:$Port" --url "http://localhost:$Port"; $code = $LASTEXITCODE
  } else {
    $exe = Use-GgTool tailscale; if (-not $exe) { throw '沒有 tailscale，無法建立通道（安裝後需登入，並在管理後台開啟 Funnel）' }
    Write-Host "啟動 Tailscale Funnel → http://localhost:$Port（網址是 https://<機器名稱>.<tailnet>.ts.net）" -ForegroundColor Green
    & $exe funnel $Port; $code = $LASTEXITCODE
  }
} catch { Write-Host "外部監看通道啟動失敗：$($_.Exception.Message)" -ForegroundColor Red; $code = 1 }
# 從捷徑或雙擊開啟時，出錯不要讓視窗一閃就關掉
if ($code -ne 0 -and -not $NoPause -and (Test-GgInteractive)) { [void](Read-Host '按 Enter 關閉視窗') }
exit $code

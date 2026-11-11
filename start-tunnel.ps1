<#
.SYNOPSIS  GuGuBoard 外部監看：用 Cloudflare Tunnel 或 Tailscale Funnel 把本機看板開成 HTTPS 網址（只讀監看，預設關閉）。
.DESCRIPTION
  1. 先在看板「👥 帳號 → Google 整合 → 外部監看」設定 Google OAuth client、允許的 email／網域並啟用。
  2. 執行本腳本；它會啟動 cloudflared（臨時 trycloudflare 網址）或 tailscale funnel，顯示 https 網址。
  3. 把網址填回「公開網址」（Google OAuth 的重新導向 URI 設成 <網址>/api/google/callback）。
  外部連線一律唯讀；Agent API、管理與 Git 寫入不對外。按 Ctrl+C 結束通道。
.EXAMPLE  .\start-tunnel.ps1 -Provider cloudflare -Port 8765
.EXAMPLE  .\start-tunnel.ps1 -Provider tailscale
#>
param([ValidateSet('cloudflare', 'tailscale')][string]$Provider = 'cloudflare', [int]$Port = 8765)
$ErrorActionPreference = 'Stop'
if ($Provider -eq 'cloudflare') {
  $exe = Get-Command cloudflared -ErrorAction SilentlyContinue
  if (-not $exe) { Write-Host '找不到 cloudflared。安裝：winget install --id Cloudflare.cloudflared（或到 developers.cloudflare.com 下載）'; exit 1 }
  Write-Host "啟動 Cloudflare Tunnel → http://localhost:$Port（網址出現後填到看板的「公開網址」）"
  & $exe.Source tunnel --no-autoupdate --url "http://localhost:$Port"
} else {
  $exe = Get-Command tailscale -ErrorAction SilentlyContinue
  if (-not $exe) { Write-Host '找不到 tailscale。安裝：winget install --id Tailscale.Tailscale，登入後在管理後台開啟 Funnel'; exit 1 }
  Write-Host "啟動 Tailscale Funnel → http://localhost:$Port（網址是 https://<機器名稱>.<tailnet>.ts.net）"
  & $exe.Source funnel $Port
}

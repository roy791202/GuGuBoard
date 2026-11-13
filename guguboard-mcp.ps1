# SPDX-License-Identifier: Apache-2.0
<#
.SYNOPSIS  把 GuGuBoard MCP 設定寫進 AI 工具：guguboard mcp install <client> -Token <token>
.DESCRIPTION
  client：claude-code、claude-desktop、cursor、codex、gemini、http（只印出網址與標頭）
  token 存在使用者資料夾 ~/.guguboard/mcp.json（不會寫進 repo）；AI 工具設定只指向 stdio 橋接 mcp-stdio.ps1。
  cursor 與 gemini 會寫「目前 repo」的設定檔（.cursor/mcp.json、.gemini/settings.json），裡面不含 token，可以 commit。
.EXAMPLE   guguboard mcp install claude-code -Token aipm_xxxx_yyyy
.EXAMPLE   guguboard mcp install cursor            # 在專案資料夾執行；token 已存過就不用再給
.EXAMPLE   guguboard mcp uninstall codex
#>
param(
  [Parameter(Position = 0)][ValidateSet('install', 'uninstall', 'status')][string]$Action = 'status',
  [Parameter(Position = 1)][ValidateSet('claude-code', 'claude-desktop', 'cursor', 'codex', 'gemini', 'http', '')][string]$Client = '',
  [string]$Token = '', [string]$Url = 'http://localhost:8765', [string]$Project = '', [string]$Repo = ''
)
$ErrorActionPreference = 'Stop'
$u8 = [Text.UTF8Encoding]::new($false)
$isWin = ($env:OS -eq 'Windows_NT')
$home_ = $(if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME })
$bridge = Join-Path $PSScriptRoot 'mcp-stdio.ps1'
$storeDir = Join-Path $home_ '.guguboard'; $store = Join-Path $storeDir 'mcp.json'
if (-not $Repo) { $Repo = (Get-Location).Path }

# Windows 用內建的 Windows PowerShell 5.1（-ExecutionPolicy Bypass 避免被執行原則擋下）；其他平台用 pwsh
$psExe = $(if ($isWin) { 'powershell.exe' } else { 'pwsh' })
$psArgs = @('-NoLogo', '-NoProfile', '-NonInteractive'); if ($isWin) { $psArgs += @('-ExecutionPolicy', 'Bypass') }; $psArgs += @('-File', $bridge)

function Find-ProjectId([string]$d) {
  while ($d) { $f = Join-Path (Join-Path $d '.ai-pm') 'project.json'; if (Test-Path -LiteralPath $f) { return [string]((Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json).id) }; $p = Split-Path -Parent $d; if (-not $p -or $p -eq $d) { break }; $d = $p }
  ''
}
function Read-JsonFile([string]$f) { if (Test-Path -LiteralPath $f) { $t = [IO.File]::ReadAllText($f); if ($t.Trim()) { return ($t | ConvertFrom-Json) } }; [pscustomobject]@{} }
function Save-JsonFile([string]$f, $o) {
  $d = Split-Path -Parent $f; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination "$f.bak" -Force }   # 改別人的設定檔前先備份
  [IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 20), $u8)
}
function Set-Prop($o, [string]$k, $v) { if ($o.PSObject.Properties[$k]) { $o.$k = $v } else { $o | Add-Member -NotePropertyName $k -NotePropertyValue $v } }
function Get-ServerEntry { [pscustomobject]@{ command = $psExe; args = @($psArgs) } }
function Set-McpServers([string]$f, [bool]$remove) {
  $o = Read-JsonFile $f; if (-not $o.PSObject.Properties['mcpServers']) { Set-Prop $o 'mcpServers' ([pscustomobject]@{}) }
  if ($remove) { $o.mcpServers.PSObject.Properties.Remove('guguboard') } else { Set-Prop $o.mcpServers 'guguboard' (Get-ServerEntry) }
  Save-JsonFile $f $o; Write-Host "$(if ($remove) { '已移除' } else { '已寫入' })：$f"
}
function Get-ClaudeDesktopFile {
  if ($isWin) { return Join-Path $env:APPDATA 'Claude\claude_desktop_config.json' }
  if ((uname) -eq 'Darwin') { return Join-Path $home_ 'Library/Application Support/Claude/claude_desktop_config.json' }
  Join-Path $home_ '.config/Claude/claude_desktop_config.json'
}
function Set-CodexToml([bool]$remove) {
  $f = Join-Path (Join-Path $home_ '.codex') 'config.toml'; $t = ''; if (Test-Path -LiteralPath $f) { $t = [IO.File]::ReadAllText($f); Copy-Item -LiteralPath $f -Destination "$f.bak" -Force }
  $t = [regex]::Replace($t, '(?ms)^\[mcp_servers\.guguboard\]\r?\n.*?(?=^\[|\z)', '')   # 移除舊的區段再寫新的，重複執行不會累加
  if (-not $remove) {
    $q = { param($s) '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }
    $t = $t.TrimEnd() + "`n`n[mcp_servers.guguboard]`ncommand = $(& $q $psExe)`nargs = [" + (($psArgs | ForEach-Object { & $q $_ }) -join ', ') + "]`n"
  }
  $d = Split-Path -Parent $f; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  [IO.File]::WriteAllText($f, $t.TrimStart(), $u8); Write-Host "$(if ($remove) { '已移除' } else { '已寫入' })：$f"
}

if (-not $Project) { $Project = Find-ProjectId $Repo }
if ($Action -eq 'status' -or -not $Client) {
  $s = Read-JsonFile $store
  Write-Host "橋接程式：$bridge"; Write-Host "token 存放：$store"
  if ($s.PSObject.Properties['projects']) { foreach ($p in $s.projects.PSObject.Properties) { Write-Host "  專案 $($p.Name)：$($p.Value.url)  token $(([string]$p.Value.token).Substring(0, [Math]::Min(13, ([string]$p.Value.token).Length)))…" } } else { Write-Host '  （還沒有存任何 token）' }
  Write-Host '用法：guguboard mcp install <claude-code|claude-desktop|cursor|codex|gemini|http> -Token <token>'
  return
}

if ($Action -eq 'install') {
  $s = Read-JsonFile $store; if (-not $s.PSObject.Properties['projects']) { Set-Prop $s 'projects' ([pscustomobject]@{}) }
  if ($Token) {
    if ($Token -notmatch '^aipm_[0-9a-f]{8}_[A-Za-z0-9_-]{20,80}$') { throw 'token 格式不對（應該是 aipm_ 開頭，從看板「⚙ 設定 → MCP」建立）' }
    $key = $(if ($Project) { $Project } else { 'default' })
    Set-Prop $s.projects $key ([pscustomobject]@{ url = $Url.TrimEnd('/'); token = $Token }); Set-Prop $s 'default' $key
    if (-not (Test-Path -LiteralPath $storeDir)) { New-Item -ItemType Directory -Force -Path $storeDir | Out-Null }
    [IO.File]::WriteAllText($store, ($s | ConvertTo-Json -Depth 5), $u8)
    if (-not $isWin) { & chmod 600 $store }   # 只有自己能讀
    Write-Host "token 已存到 $store（專案 $key）"
  } elseif (-not ($s.projects.PSObject.Properties.Count)) { Write-Warning '還沒有存過 token：請加 -Token <token>（看板「⚙ 設定 → MCP」建立）' }
}
$rm = $Action -eq 'uninstall'
switch ($Client) {
  'claude-code' {
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if ($claude) {
      if ($rm) { & claude mcp remove --scope user guguboard } else { & claude mcp remove --scope user guguboard 2>$null | Out-Null; & claude mcp add --scope user guguboard -- $psExe @psArgs }
    } else { Write-Host '找不到 claude 指令，請手動執行：'; Write-Host "  claude mcp add --scope user guguboard -- $psExe $($psArgs -join ' ')" }
  }
  'claude-desktop' { Set-McpServers (Get-ClaudeDesktopFile) $rm; Write-Host '請重新開啟 Claude Desktop。' }
  'cursor' { Set-McpServers (Join-Path (Join-Path $Repo '.cursor') 'mcp.json') $rm }
  'gemini' { Set-McpServers (Join-Path (Join-Path $Repo '.gemini') 'settings.json') $rm }
  'codex' { Set-CodexToml $rm }
  'http' { Write-Host "MCP 網址：$($Url.TrimEnd('/'))/mcp"; Write-Host '標頭：Authorization: Bearer <token>'; Write-Host '外部（例如 Grok Bot）請用看板設定的公開 https 網址，並在設定開啟「允許外部 MCP 連線」。' }
}

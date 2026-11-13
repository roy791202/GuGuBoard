# SPDX-License-Identifier: Apache-2.0
<#
 GuGuBoard MCP stdio 橋接：給 Claude Code、Cursor、Codex、Gemini CLI 這類在本機啟動 MCP 伺服器的工具用。
 從 stdin 讀一行一則 JSON-RPC，轉送到看板的 POST /mcp，再把回應寫回 stdout。stdout 只能放協定訊息，其他訊息都寫 stderr。
 不需要貼專案路徑：
  - 網址：GUGUBOARD_URL，或 ~/.guguboard/mcp.json 裡這個專案的 url，預設 http://localhost:8765
  - token：GUGUBOARD_TOKEN，或 ~/.guguboard/mcp.json（用 guguboard mcp install 寫入，不會放進 repo）
  - 專案：GUGUBOARD_PROJECT，或從目前資料夾往上找 .ai-pm/project.json 的 id
#>
param([string]$Url = '', [string]$Token = '', [string]$Project = '')
$ErrorActionPreference = 'Stop'
$u8 = [Text.UTF8Encoding]::new($false)
try { [Console]::InputEncoding = $u8; [Console]::OutputEncoding = $u8 } catch {}
function Write-Log([string]$t) { [Console]::Error.WriteLine("[guguboard-mcp] $t") }

function Find-ProjectId {
  $d = (Get-Location).Path
  while ($d) {
    $f = Join-Path (Join-Path $d '.ai-pm') 'project.json'
    if (Test-Path -LiteralPath $f) { try { return [string]((Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json).id) } catch { return '' } }
    $p = Split-Path -Parent $d; if (-not $p -or $p -eq $d) { break }; $d = $p
  }
  ''
}
$home_ = $(if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME })
$store = Join-Path (Join-Path $home_ '.guguboard') 'mcp.json'
if (-not $Project) { $Project = "$env:GUGUBOARD_PROJECT" }; if (-not $Project) { $Project = Find-ProjectId }
if (-not $Token) { $Token = "$env:GUGUBOARD_TOKEN" }; if (-not $Url) { $Url = "$env:GUGUBOARD_URL" }
if ((-not $Token -or -not $Url) -and (Test-Path -LiteralPath $store)) {
  try {
    $s = Get-Content -LiteralPath $store -Raw -Encoding UTF8 | ConvertFrom-Json; $e = $null
    if ($Project -and $s.projects.PSObject.Properties[$Project]) { $e = $s.projects.$Project }
    elseif (-not $Project -and $s.default -and $s.projects.PSObject.Properties[[string]$s.default]) { $e = $s.projects.([string]$s.default) }
    if ($e) { if (-not $Token) { $Token = [string]$e.token }; if (-not $Url) { $Url = [string]$e.url } }
  } catch { Write-Log "讀不到 $store：$($_.Exception.Message)" }
}
if (-not $Url) { $Url = 'http://localhost:8765' }
$endpoint = $Url.TrimEnd('/') + '/mcp'
if (-not $Token) { Write-Log "找不到 token。請在看板「⚙ 設定 → MCP」建立 token，再執行：guguboard mcp install <client> -Token <token>（專案：$(if ($Project) { $Project } else { '未偵測到 .ai-pm/project.json' })）" }

Add-Type -AssemblyName System.Net.Http
$http = [Net.Http.HttpClient]::new(); $http.Timeout = [TimeSpan]::FromSeconds(120)
$session = ''
function Send-Line([string]$s) { [Console]::Out.WriteLine($s); [Console]::Out.Flush() }
function Send-RpcError($id, [int]$code, [string]$msg) {
  if ($null -eq $id) { return }
  Send-Line (@{ jsonrpc = '2.0'; id = $id; error = @{ code = $code; message = $msg } } | ConvertTo-Json -Depth 5 -Compress)
}

while ($true) {
  $line = [Console]::In.ReadLine(); if ($null -eq $line) { break }
  if (-not $line.Trim()) { continue }
  $id = $null; try { $msg = $line | ConvertFrom-Json; if ($msg.PSObject.Properties['id']) { $id = $msg.id } } catch { Send-Line '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}'; continue }
  if (-not $Token) { Send-RpcError $id -32001 '沒有 GuGuBoard token：請在看板設定 → MCP 建立 token，再執行 guguboard mcp install'; continue }
  try {
    $rq = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $endpoint)
    $rq.Content = [Net.Http.StringContent]::new($line, $u8, 'application/json')
    [void]$rq.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token")
    [void]$rq.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream')
    if ($session) { [void]$rq.Headers.TryAddWithoutValidation('Mcp-Session-Id', $session) }
    $rs = $http.SendAsync($rq).GetAwaiter().GetResult()
    $vals = $null; if ($rs.Headers.TryGetValues('Mcp-Session-Id', [ref]$vals)) { $session = @($vals)[0] }
    $body = $rs.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ([int]$rs.StatusCode -eq 202 -or -not $body) { continue }
    $j = $null; try { $j = $body | ConvertFrom-Json } catch {}
    if ($j -and ($j.PSObject.Properties['jsonrpc'] -or $j -is [array])) { Send-Line (($body -replace "`r?`n", '')) }
    else { $m = $(if ($j -and $j.message) { [string]$j.message } elseif ($j -and $j.error) { [string]$j.error } else { "HTTP $([int]$rs.StatusCode)" }); Send-RpcError $id -32001 "GuGuBoard：$m" }
  } catch {
    Send-RpcError $id -32000 "連不到 GuGuBoard 看板（$endpoint）。請先啟動看板（guguboard start）。$($_.Exception.Message)"
  }
}

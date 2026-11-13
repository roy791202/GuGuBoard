# SPDX-License-Identifier: Apache-2.0
<#
 MCP 伺服器（Model Context Protocol，Streamable HTTP：POST /mcp）。
 讓 Claude、Cursor、Codex、Gemini、Grok Bot 等 AI 用標準工具操作看板。
 安全原則：
 - 只接受 Agent token（Bearer aipm_…），預設關閉，要在「設定 → MCP」打開。
 - 每個工具都轉給既有的 Agent API 執行，所以 L1–L7 與角色權限只有一套，不會因為走 MCP 而變寬鬆。
 - 透過 MCP 的 AI 一律不可移到 Done／Released、設藍燈或核准佈署（不論角色）。
 - 每次呼叫都寫進帳號稽核紀錄（不記 token）。
#>
$MCP_VERSIONS = '2025-06-18', '2025-03-26', '2024-11-05'
$MCP_ERR = @{
  E_CLAIMED = '這張工單已被其他代理領取'; E_NOT_CLAIMABLE = '這張工單目前不能由這個角色領取（狀態、紅燈、暫停、相依或指派不符）'; E_NO_CLAIM = '你沒有領取這張工單（租約可能已過期被釋放），請先 claim_ticket'
  E_NOT_FOUND = '找不到這張工單或資源'; E_BAD_REQUEST = '參數格式不正確'; E_RULES = '修改不符燈號規則，未寫入'; E_RATE_LIMIT = '呼叫太頻繁，請稍後再試'
}
function Get-McpCfg { $m = Get-Sec (Read-Integ) 'mcp'; @{ enabled = [bool]($m -and $m.enabled -eq $true); allowExternal = [bool]($m -and $m.allowExternal -eq $true) } }

# 用假的 request／response 物件呼叫既有的 Invoke-AgentApi，結果收回來（伺服器是單執行緒，不能自己連自己）
function Invoke-AgentInternal($ag, [string]$method, [string]$sub, $body, $query) {
  $json = '{}'; if ($null -ne $body) { $json = $body | ConvertTo-Json -Depth 10 -Compress }
  $bytes = [Text.Encoding]::UTF8.GetBytes($json); $q = @{}; if ($query) { $q = $query }
  $req = [pscustomobject]@{ HttpMethod = $method; InputStream = [IO.MemoryStream]::new($bytes); ContentLength64 = $bytes.Length; QueryString = $q; Headers = @{}; IsLocal = $true }
  $out = [IO.MemoryStream]::new()
  $res = [pscustomobject]@{ StatusCode = 200; ContentType = ''; ContentLength64 = 0; Headers = @{}; OutputStream = $out }
  $res | Add-Member -MemberType ScriptMethod -Name Close -Value { }
  Invoke-AgentApi $req $res $ag $sub
  $txt = [Text.Encoding]::UTF8.GetString($out.ToArray()); $obj = $null
  if ($res.ContentType -like 'application/json*') { try { $obj = $txt | ConvertFrom-Json } catch {} }
  @{ code = [int]$res.StatusCode; body = $obj; text = $txt }
}

function New-McpText([string]$t, [bool]$isErr, $data) {
  $r = [ordered]@{ content = @(@{ type = 'text'; text = $t }); isError = $isErr }
  if ($null -ne $data) { $r.structuredContent = $data }
  $r
}
function New-McpRejection($r) {   # 規則拒絕：回規則編號＋中文原因，讓 AI 知道要怎麼改
  $b = $r.body; $code = [string]$(if ($b) { $b.error } else { 'E_HTTP' })
  $errs = @(); if ($b -and $b.errors) { $errs = @($b.errors | ForEach-Object { [string]$_ }) }
  $rules = @($errs | ForEach-Object { if ($_ -match '\[(L\d)\]') { $Matches[1] } } | Select-Object -Unique)
  $msg = [string]$(if ($b -and $b.message) { $b.message } elseif ($MCP_ERR.ContainsKey($code)) { $MCP_ERR[$code] } else { $code })
  $lines = @("拒絕（$code）：$msg") + $errs
  New-McpText ($lines -join "`n") $true ([ordered]@{ error = $code; rules = $rules; errors = $errs; message = $msg })
}
function Get-McpOk($r) { $r.code -ge 200 -and $r.code -lt 300 -and -not ($r.body -and $r.body.error) }
function ConvertTo-McpResult($r) { if (Get-McpOk $r) { New-McpText ($r.body | ConvertTo-Json -Depth 10) $false $r.body } else { New-McpRejection $r } }

$McpTicketArg = @{ type = 'string'; description = '工單 id，例如 T-12'; pattern = '^[A-Za-z0-9._-]{1,40}$' }
$MCP_TOOLS = @(
  @{ name = 'list_projects'; description = '列出這個 token 可以操作的 GuGuBoard 專案與你的角色'; inputSchema = @{ type = 'object'; properties = @{} } }
  @{ name = 'get_board_summary'; description = '看板摘要：各狀態、各燈號的工單數量與你領取中的工單'; inputSchema = @{ type = 'object'; properties = @{} } }
  @{ name = 'list_tickets'; description = '列出工單，可依燈號、狀態、層級篩選'; inputSchema = @{ type = 'object'; properties = @{ light = @{ type = 'string'; enum = @('Gray', 'Green', 'Yellow', 'Red', 'Blue') }; status = @{ type = 'string'; description = '例如 Todo、In Progress、In Review、Done' }; level = @{ type = 'string'; description = 'Epic、Feature、Story、Task' }; mine = @{ type = 'boolean'; description = '只列我領取或指派給我的' } } } }
  @{ name = 'get_ticket'; description = '讀一張工單的完整內容（BDD、驗收條件、history、notes、領取狀態）'; inputSchema = @{ type = 'object'; properties = @{ ticket = $McpTicketArg }; required = @('ticket') } }
  @{ name = 'claim_ticket'; description = '領取工單（租約制，每 5 分鐘要 renew_lease）；不帶 ticket 就領下一張可領的'; inputSchema = @{ type = 'object'; properties = @{ ticket = $McpTicketArg } } }
  @{ name = 'renew_lease'; description = '延長領取租約（heartbeat）'; inputSchema = @{ type = 'object'; properties = @{ ticket = $McpTicketArg }; required = @('ticket') } }
  @{ name = 'release_ticket'; description = '釋放領取（完成或卡住時）'; inputSchema = @{ type = 'object'; properties = @{ ticket = $McpTicketArg }; required = @('ticket') } }
  @{ name = 'update_ticket_progress'; description = '更新狀態／燈號／測試／PR／備註；伺服器依 L1–L7 驗證，history 自動追加。不可移到 Done、Released 或設藍燈'; inputSchema = @{ type = 'object'; required = @('ticket', 'reason'); properties = @{ ticket = $McpTicketArg; status = @{ type = 'string'; enum = @('Backlog', 'Todo', 'In Progress', 'In Review') }; light = @{ type = 'string'; enum = @('Gray', 'Green', 'Yellow', 'Red') }; lightReason = @{ type = 'string'; description = '黃／紅燈必填（L4）' }; paused = @{ type = 'boolean' }; pausedReason = @{ type = 'string' }; prUrl = @{ type = 'string' }; tests = @{ type = 'object'; properties = @{ status = @{ type = 'string'; enum = @('Green', 'Red', 'Pending') }; passed = @{ type = 'number' }; failed = @{ type = 'number' }; url = @{ type = 'string' } } }; note = @{ type = 'string' }; reason = @{ type = 'string'; description = '這次變更的原因（寫進 history，L7）' } } } }
  @{ name = 'add_ticket_note'; description = '在工單加一則備註（進度、發現、提問）'; inputSchema = @{ type = 'object'; required = @('ticket', 'text'); properties = @{ ticket = $McpTicketArg; text = @{ type = 'string'; maxLength = 2000 } } } }
  @{ name = 'answer_verifier_question'; description = '回答驗證代理的提問（例如「為什麼程式這樣寫」），答案寫進工單備註'; inputSchema = @{ type = 'object'; required = @('ticket', 'answer'); properties = @{ ticket = $McpTicketArg; question = @{ type = 'string' }; answer = @{ type = 'string'; maxLength = 2000 } } } }
  @{ name = 'submit_for_tdd'; description = '開發完成、測試全綠，送交驗證（In Review 綠燈，READY_FOR_TDD）'; inputSchema = @{ type = 'object'; required = @('ticket', 'summary', 'testsPassed'); properties = @{ ticket = $McpTicketArg; summary = @{ type = 'string'; description = '做了什麼、怎麼測' }; prUrl = @{ type = 'string' }; testsPassed = @{ type = 'number' }; testsFailed = @{ type = 'number' } } } }
  @{ name = 'get_rules'; description = '燈號規則 L1–L7、你的角色流程與租約規定'; inputSchema = @{ type = 'object'; properties = @{} } }
  @{ name = 'list_runs'; description = '派工器執行紀錄（這個專案）'; inputSchema = @{ type = 'object'; properties = @{ ticket = $McpTicketArg } } }
  @{ name = 'get_run_log'; description = '讀一筆派工器執行 log（最後 50 KB）'; inputSchema = @{ type = 'object'; required = @('log'); properties = @{ log = @{ type = 'string'; pattern = '^[A-Za-z0-9._-]{1,120}\.log$' } } } }
)
function Get-McpArg($a, [string]$k) { if ($a -and $a.PSObject.Properties[$k]) { $a.$k } else { $null } }

function Invoke-McpTool($ag, [string]$name, $a) {
  $Pj = $projects[$ag.project]; $tk = [string](Get-McpArg $a 'ticket')
  if ($tk -and $tk -notmatch '^[A-Za-z0-9._-]{1,40}$') { return New-McpText '工單 id 格式不正確' $true @{ error = 'E_BAD_ID' } }
  switch ($name) {
    'list_projects' { $me = (Invoke-AgentInternal $ag 'GET' '/me' $null $null).body; return New-McpText ($me | ConvertTo-Json) $false @{ projects = @(@{ id = $Pj.id; name = $Pj.name; role = $ag.role; agent = $ag.name }) } }
    'get_rules' { return ConvertTo-McpResult (Invoke-AgentInternal $ag 'GET' '/rules' $null $null) }
    'list_tickets' {
      $q = @{}; if ((Get-McpArg $a 'mine') -eq $true) { $q['mine'] = '1' }
      $r = Invoke-AgentInternal $ag 'GET' '/tickets' $null $q; if (-not (Get-McpOk $r)) { return New-McpRejection $r }
      $l = @($r.body.tickets | Where-Object { $_ } | Where-Object { (-not (Get-McpArg $a 'light') -or $_.light -ceq (Get-McpArg $a 'light')) -and (-not (Get-McpArg $a 'status') -or $_.status -ceq (Get-McpArg $a 'status')) -and (-not (Get-McpArg $a 'level') -or $_.level -ceq (Get-McpArg $a 'level')) })
      return New-McpText ("共 $($l.Count) 張`n" + (($l | ForEach-Object { "$($_.id)  [$($_.level)] $($_.status) / $($_.light)  $($_.title)$(if ($_.claimedBy) { '（' + $_.claimedBy + ' 領取中）' })" }) -join "`n")) $false @{ tickets = $l }
    }
    'get_board_summary' {
      $r = Invoke-AgentInternal $ag 'GET' '/tickets' $null @{}; if (-not (Get-McpOk $r)) { return New-McpRejection $r }
      $l = @($r.body.tickets | Where-Object { $_ }); $bs = [ordered]@{}; $bl = [ordered]@{}
      foreach ($t in $l) { $bs[[string]$t.status] = 1 + [int]$bs[[string]$t.status]; $bl[[string]$t.light] = 1 + [int]$bl[[string]$t.light] }
      $mine = @((Invoke-AgentInternal $ag 'GET' '/tickets' $null @{ mine = '1' }).body.tickets | Where-Object { $_ } | ForEach-Object { $_.id })
      $o = [ordered]@{ project = $Pj.id; name = $Pj.name; total = $l.Count; byStatus = $bs; byLight = $bl; mine = $mine }
      return New-McpText ($o | ConvertTo-Json -Depth 5) $false $o
    }
    'get_ticket' { return ConvertTo-McpResult (Invoke-AgentInternal $ag 'GET' "/tickets/$tk" $null $null) }
    'claim_ticket' { $b = @{}; if ($tk) { $b.ticket = $tk }; return ConvertTo-McpResult (Invoke-AgentInternal $ag 'POST' '/claim' $b $null) }
    'renew_lease' { return ConvertTo-McpResult (Invoke-AgentInternal $ag 'POST' '/heartbeat' @{ ticket = $tk } $null) }
    'release_ticket' { return ConvertTo-McpResult (Invoke-AgentInternal $ag 'POST' '/release' @{ ticket = $tk } $null) }
    'update_ticket_progress' {
      $st = [string](Get-McpArg $a 'status'); $lt = [string](Get-McpArg $a 'light')
      # AI 不論角色都不能結案或核准：移到 Done／Released、設藍燈是人（或人核准的流程）才能做的事
      if ($st -cin 'Done', 'Released' -or $lt -ceq 'Blue') { return New-McpRejection @{ code = 422; body = [pscustomobject]@{ error = 'E_RULES'; message = 'AI 不可結案或核准佈署'; errors = @('[L5] 透過 MCP 的 AI 不可把工單移到 Done／Released 或設定藍燈，請送交驗證（submit_for_tdd）由人核准') } } }
      if (($st -or $lt) -and -not [string](Get-McpArg $a 'reason')) { return New-McpRejection @{ code = 422; body = [pscustomobject]@{ error = 'E_RULES'; message = '缺少變更原因'; errors = @('[L7] 變更狀態或燈號時必須填 reason（會寫進 history）') } } }
      $b = [ordered]@{}; foreach ($k in 'status', 'light', 'lightReason', 'paused', 'pausedReason', 'prUrl', 'tests', 'note', 'reason') { $v = Get-McpArg $a $k; if ($null -ne $v -and "$v" -ne '') { $b[$k] = $v } }
      return ConvertTo-McpResult (Invoke-AgentInternal $ag 'PATCH' "/tickets/$tk" $b $null)
    }
    'add_ticket_note' { return ConvertTo-McpResult (Invoke-AgentInternal $ag 'PATCH' "/tickets/$tk" @{ note = [string](Get-McpArg $a 'text') } $null) }
    'answer_verifier_question' {
      $q = [string](Get-McpArg $a 'question'); $txt = "[回覆驗證提問] $(if ($q) { '問：' + $q + ' ／ ' })答：$([string](Get-McpArg $a 'answer'))"
      return ConvertTo-McpResult (Invoke-AgentInternal $ag 'PATCH' "/tickets/$tk" @{ note = $txt } $null)
    }
    'submit_for_tdd' {
      $fail = [double](Get-McpArg $a 'testsFailed'); $pass = [double](Get-McpArg $a 'testsPassed')
      if ($fail -gt 0 -or $pass -le 0) { return New-McpRejection @{ code = 422; body = [pscustomobject]@{ error = 'E_RULES'; message = '測試還沒全綠'; errors = @('[L6] 送交驗證前測試必須全綠（testsPassed > 0 且 testsFailed = 0）') } } }
      $b = [ordered]@{ status = 'In Review'; light = 'Green'; tdd = 'Green'; tests = @{ status = 'Green'; passed = $pass; failed = 0 }; note = "READY_FOR_TDD：$([string](Get-McpArg $a 'summary'))"; reason = '開發完成，測試全綠，送交 TDD 驗證' }
      if (Get-McpArg $a 'prUrl') { $b.prUrl = [string](Get-McpArg $a 'prUrl') }
      return ConvertTo-McpResult (Invoke-AgentInternal $ag 'PATCH' "/tickets/$tk" $b $null)
    }
    'list_runs' {
      $l = @($runs.Values | Where-Object { $_.project -eq $Pj.id -and (-not $tk -or $_.ticket -eq $tk) } | Sort-Object { $_.start } -Descending | Select-Object -First 50 | ForEach-Object { [ordered]@{ id = $_.id; ticket = $_.ticket; profile = $_.profile; status = $_.status; start = $_.start.ToString('o'); exit = $_.exit } })
      $d = Get-RunDir $Pj; $files = @(); if (Test-Path -LiteralPath $d) { $files = @(Get-ChildItem -LiteralPath $d -Filter '*.log' -File | Where-Object { -not $tk -or $_.Name -like "*$tk*" } | Sort-Object Name -Descending | Select-Object -First 50 | ForEach-Object { $_.Name }) }
      $o = [ordered]@{ runs = $l; logs = $files }; return New-McpText ($o | ConvertTo-Json -Depth 5) $false $o
    }
    'get_run_log' {
      $n = [string](Get-McpArg $a 'log'); if ($n -notmatch '^[A-Za-z0-9._-]{1,120}\.log$') { return New-McpText 'log 名稱格式不正確' $true @{ error = 'E_BAD_ID' } }
      $f = Join-Path (Get-RunDir $Pj) $n; if (-not (Test-Path -LiteralPath $f)) { return New-McpRejection @{ code = 404; body = [pscustomobject]@{ error = 'E_NOT_FOUND' } } }
      $t = [IO.File]::ReadAllText($f); if ($t.Length -gt 50000) { $t = $t.Substring($t.Length - 50000) }; return New-McpText $t $false $null
    }
  }
  New-McpText "沒有這個工具：$name" $true @{ error = 'E_UNKNOWN_TOOL' }
}

function Get-McpPrompt($ag) {
  $Pj = $projects[$ag.project]; $role = $ROLE_LABEL[$ag.role]
  "你是 GuGuBoard 專案「$($Pj.name)」（id: $($Pj.id)）的$role，代號 $($ag.name)。你已透過 MCP 連上看板，不需要專案路徑，也不要直接編輯 board.json。`n" +
  "1. 先呼叫 get_rules 讀燈號規則 L1–L7 與你的流程。`n2. claim_ticket 領取工單，get_ticket 讀 BDD 與驗收條件；工作期間每 5 分鐘 renew_lease。`n" +
  "3. 用 update_ticket_progress 更新狀態與燈號（每次都要寫 reason）；卡住就改黃／紅燈並寫 lightReason，然後 release_ticket。`n" +
  "4. 先寫失敗的測試再實作；測試全綠後 submit_for_tdd 送交驗證。驗證代理提問時用 answer_verifier_question 白話回答。`n" +
  "5. 你不能移到 Done、設藍燈或核准佈署，那是人的決定。被拒絕時照回覆的規則編號修正後再試。"
}

function Invoke-McpMethod($ag, [string]$method, $p) {
  switch ($method) {
    'initialize' {
      $want = [string](Get-McpArg $p 'protocolVersion'); $ver = $(if ($want -in $MCP_VERSIONS) { $want } else { $MCP_VERSIONS[0] })
      return [ordered]@{ protocolVersion = $ver; capabilities = @{ tools = @{ listChanged = $false }; prompts = @{ listChanged = $false }; resources = @{ listChanged = $false } }
        serverInfo = @{ name = 'guguboard'; title = 'GuGuBoard'; version = $(if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'VERSION')) { ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION'))).Trim() } else { '0.1.0' }) }
        instructions = (Get-McpPrompt $ag) }
    }
    'ping' { return @{} }
    'tools/list' { return @{ tools = $MCP_TOOLS } }
    'tools/call' {
      $name = [string](Get-McpArg $p 'name'); $args_ = Get-McpArg $p 'arguments'
      if (-not ($MCP_TOOLS | Where-Object { $_.name -eq $name })) { throw [ArgumentException]::new("沒有這個工具：$name") }
      $r = $null; try { $r = Invoke-McpTool $ag $name $args_ } catch { $r = New-McpText "伺服器錯誤：$($_.Exception.Message)" $true @{ error = 'E_SERVER' } }
      $sd = $r['structuredContent']; $er = $null; if ($sd -is [Collections.IDictionary]) { $er = $sd['error'] } elseif ($sd) { $er = $sd.error }
      Write-AcctAudit @{ user = "mcp:$($ag.name)" } 'mcp.tool' ([ordered]@{ project = $ag.project; role = $ag.role; token = $ag.id; tool = $name; ticket = [string](Get-McpArg $args_ 'ticket'); ok = -not $r.isError; error = [string]$er })
      return $r
    }
    'prompts/list' { return @{ prompts = @(@{ name = 'guguboard_collaborate'; title = 'GuGuBoard 協作提示詞'; description = '開始與 GuGuBoard 協作的短提示詞（依你的角色）' }) } }
    'prompts/get' { if ([string](Get-McpArg $p 'name') -ne 'guguboard_collaborate') { throw [ArgumentException]::new('沒有這個提示詞') }; return @{ description = 'GuGuBoard 協作提示詞'; messages = @(@{ role = 'user'; content = @{ type = 'text'; text = (Get-McpPrompt $ag) } }) } }
    'resources/list' { return @{ resources = @(@{ uri = 'guguboard://rules'; name = 'rules'; title = '燈號規則與流程'; mimeType = 'application/json' }, @{ uri = 'guguboard://prompt'; name = 'prompt'; title = '協作提示詞'; mimeType = 'text/plain' }) } }
    'resources/read' {
      $u = [string](Get-McpArg $p 'uri')
      if ($u -eq 'guguboard://rules') { return @{ contents = @(@{ uri = $u; mimeType = 'application/json'; text = ((Invoke-AgentInternal $ag 'GET' '/rules' $null $null).text) }) } }
      if ($u -eq 'guguboard://prompt') { return @{ contents = @(@{ uri = $u; mimeType = 'text/plain'; text = (Get-McpPrompt $ag) }) } }
      throw [ArgumentException]::new('沒有這個資源')
    }
  }
  throw [MissingMethodException]::new("不支援的方法：$method")
}

function Send-McpJson($res, $obj, [int]$code = 200) { Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 20 -Compress))) 'application/json; charset=utf-8' $code }
function Invoke-McpHttp($req, $res) {
  $cfg = Get-McpCfg
  if (-not $cfg.enabled) { return Send-Json $res @{ error = 'E_MCP_DISABLED'; message = 'MCP 尚未啟用（看板「⚙ 設定 → MCP」）' } 404 }
  if ((Test-External $req) -and -not $cfg.allowExternal) { return Send-Json $res @{ error = 'E_MCP_LOCAL_ONLY'; message = 'MCP 只允許本機連線（可在設定開啟外部連線）' } 403 }
  # 擋 DNS rebinding：瀏覽器送來的 Origin 必須是本機或設定的公開網址
  $o = [string]$req.Headers['Origin']; $x = Get-Sec (Read-Integ) 'external'; $pu = ''; if ($x -and $x.publicUrl) { $pu = ([string]$x.publicUrl).TrimEnd('/') }
  if ($o -and $o -ne "http://localhost:$Port" -and $o -ne "http://127.0.0.1:$Port" -and -not ($pu -and $o -eq $pu)) { return Send-Err $res 403 'E_ORIGIN' }
  $ag = Get-AgentAuth $req; if ($ag -eq 'RATE') { return Send-Err $res 429 'E_RATE_LIMIT' }
  if (-not $ag) { $res.Headers['WWW-Authenticate'] = 'Bearer realm="guguboard"'; return Send-Json $res @{ error = 'E_AGENT_TOKEN'; message = '需要有效的 Agent token（Authorization: Bearer aipm_…）' } 401 }
  if ($req.HttpMethod -eq 'DELETE') { return Send-Json $res @{ ok = $true } }
  if ($req.HttpMethod -ne 'POST') { $res.Headers['Allow'] = 'POST, DELETE'; return Send-Err $res 405 'E_METHOD' }
  $raw = Read-BodyMax $req 262144
  if ($null -eq $raw) { return Send-McpJson $res @{ jsonrpc = '2.0'; id = $null; error = @{ code = -32700; message = 'Parse error' } } 400 }
  $batch = $raw -is [array]; $out = [Collections.ArrayList]::new()
  foreach ($m in @($raw)) {
    $hasId = [bool]$m.PSObject.Properties['id']; $method = [string]$m.method
    if (-not $method) { continue }   # 用戶端回給我們的 response，伺服器不需要處理
    try { $r = Invoke-McpMethod $ag $method (Get-McpArg $m 'params'); if ($hasId) { [void]$out.Add([ordered]@{ jsonrpc = '2.0'; id = $m.id; result = $r }) } }
    catch [MissingMethodException] { if ($hasId) { [void]$out.Add([ordered]@{ jsonrpc = '2.0'; id = $m.id; error = @{ code = -32601; message = $_.Exception.Message } }) } }
    catch [ArgumentException] { if ($hasId) { [void]$out.Add([ordered]@{ jsonrpc = '2.0'; id = $m.id; error = @{ code = -32602; message = $_.Exception.Message } }) } }
    catch { if ($hasId) { [void]$out.Add([ordered]@{ jsonrpc = '2.0'; id = $m.id; error = @{ code = -32603; message = $_.Exception.Message } }) } }
    if ($method -eq 'initialize') { $res.Headers['Mcp-Session-Id'] = (New-Token) }
  }
  if (-not $out.Count) { $res.StatusCode = 202; $res.ContentLength64 = 0; $res.Close(); return }
  if ($batch) { Send-McpJson $res (, @($out.ToArray())) } else { Send-McpJson $res $out[0] }
}

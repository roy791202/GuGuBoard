# GuGuBoard 伺服器擴充：.ai-pm 工具資料夾、備份／還原、搬移、經驗證的寫入、Agent API（token、領取、心跳）、AI 提示詞、
# 使用者偏好、派工器（push）、Google Sheets 同步、外部監看（Google 登入）、通知（Gmail SMTP／Google Chat）
# 由 serve-board.ps1 dot-source；PowerShell 5.1／7 皆可。所有密鑰只存在伺服器設定資料夾，不送到瀏覽器、不放進提示詞。

# ---------- .ai-pm 工具資料夾 ----------
$AIPM_README = @'
# .ai-pm — GuGuBoard 看板資料夾（請勿手動編輯）

這個資料夾由 GuGuBoard 管理：

- `board.json`：專案看板（Epic／Feature／Story／Task／Deployment）。AI 代理只能用編輯工具修改，修改會先經過驗證（燈號規則 L1–L7、不可刪卡、不可整檔覆寫）。
- `project.json`：專案識別（id、名稱），AI 提示詞只要寫專案 id，不需要路徑。
- `backups/`：伺服器每次寫入前的自動備份（已加入 .gitignore）。
- `runs/`：派工器執行 AI CLI 的紀錄（已加入 .gitignore）。

要還原請在 GuGuBoard 看板的「🕘 歷史 → 備份」操作；不要刪除或搬走這個資料夾，pre-commit 與 CI 會擋下。
'@
function Test-InAiPm([string]$bp) { (Split-Path -Leaf (Split-Path -Parent $bp)) -eq '.ai-pm' }
function Initialize-AiPm([string]$bp, [string]$id, [string]$name) {
  if (-not (Test-InAiPm $bp)) { return }
  $d = Split-Path -Parent $bp; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
  $u8 = [Text.UTF8Encoding]::new($false)
  $f = Join-Path $d 'README.md'; if (-not (Test-Path -LiteralPath $f)) { [IO.File]::WriteAllText($f, ($AIPM_README -replace "`r`n", "`n"), $u8) }
  $f = Join-Path $d '.gitignore'; if (-not (Test-Path -LiteralPath $f)) { [IO.File]::WriteAllText($f, "backups/`nruns/`n", $u8) }
  $f = Join-Path $d 'project.json'; if (-not (Test-Path -LiteralPath $f)) { [IO.File]::WriteAllText($f, ([ordered]@{ aipm = 1; id = $id; name = $name; board = 'board.json'; rules = 'AGENTS.md' } | ConvertTo-Json), $u8) }
}
function Get-BackupDir($Pj) { if (Test-InAiPm $Pj.json) { Join-Path (Split-Path -Parent $Pj.json) 'backups' } else { Join-Path (Join-Path $ConfigDir 'backups') $Pj.id } }
function Backup-Board($Pj, [string]$text, [string]$why) {
  if (-not $text) { return $null }
  $d = Get-BackupDir $Pj; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
  $why = ($why -replace '[^A-Za-z0-9-]', ''); if (-not $why) { $why = 'write' }
  $n = 'board-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff', [Globalization.CultureInfo]::InvariantCulture) + '-' + $why + '.json'
  [IO.File]::WriteAllText((Join-Path $d $n), $text, [Text.UTF8Encoding]::new($false))
  $all = @(Get-ChildItem -LiteralPath $d -Filter 'board-*.json' -File | Sort-Object Name -Descending)
  if ($all.Count -gt $BACKUP_KEEP) { $all | Select-Object -Skip $BACKUP_KEEP | Remove-Item -Force -ErrorAction SilentlyContinue }   # 輪替：只留最新 N 份
  $n
}
$BACKUP_KEEP = 30
function ConvertTo-BoardText($obj) { ($obj | ConvertTo-Json -Depth 40) -replace "`r`n", "`n" }
# 經驗證的寫入：伺服器所有寫入 board.json 的 API 都走這裡（與 validator／hooks／pre-commit／CI 用同一套規則）
function Write-BoardChecked($Pj, $new, [string]$role, [string]$why, [switch]$SkipIntegrity, $flags) {
  $oldText = [IO.File]::ReadAllText($Pj.json); $old = $null; try { $old = Read-BoardJson $oldText } catch {}
  $rv = 0; if ($old -and (IsNum (Get-V $old 'revision'))) { $rv = [int]$old['revision'] }
  $new['revision'] = [double]($rv + 1); $new['updatedAt'] = Get-NowIso
  $text = ConvertTo-BoardText $new; $chk = Read-BoardJson $text
  $errs = @(Test-Board $chk)
  if ($old -and -not $SkipIntegrity) { $errs += @(Test-BoardBookkeeping $old $chk); $errs += @(Test-BoardIntegrity $old $chk) }   # 還原（人工確認的回復）只略過 L7 與 20% 規則，格式與燈號照查
  if ($role -and $role -ne 'admin' -and $role -ne 'high-tier' -and $role -ne 'verifier') { $errs += @(Test-BoardRole $old $chk $role) }
  if ($flags -and $flags.noApprove) { $errs += @(Test-NoApprove $old $chk) }
  if ($errs.Count) { return @($errs) }
  [void](Backup-Board $Pj $oldText $why)
  [IO.File]::WriteAllText($Pj.json, $text, [Text.UTF8Encoding]::new($false))
  $Pj.lastText = $text; $Pj.lastTag = Get-Tag $Pj; $Pj.dirtyAt = Get-Date
  Push-All 'board' @{ p = $Pj.id } $Pj.id
  Invoke-BoardEvents $Pj $old $chk
  return @()
}
# 派工器啟動的 AI 一律不可自動核准：不能移到 Done／Released、不能設藍燈、不能填 approvedBy（不分角色）
function Test-NoApprove($old, $new) { @(Test-BoardRole $old $new 'dev-agent' | ForEach-Object { $_ -replace '開發代理', '派工器啟動的 AI（不自動核准）' }) }
function Read-BoardObj($Pj) { Read-BoardJson ([IO.File]::ReadAllText($Pj.json)) }
function Find-Item($b, [string]$id) { foreach ($it in $b['items']) { if ((IsObj $it) -and [string]$it['id'] -ceq $id) { return $it } }; $null }

function Invoke-Backups($req, $res, $s, $Pj) {
  $d = Get-BackupDir $Pj; $l = @(); if (Test-Path -LiteralPath $d) { $l = @(Get-ChildItem -LiteralPath $d -Filter 'board-*.json' -File | Sort-Object Name -Descending | ForEach-Object { [ordered]@{ name = $_.Name; size = $_.Length; at = $_.LastWriteTime.ToString('o') } }) }
  Send-Json $res @{ backups = $l; dir = $(if (Test-InAiPm $Pj.json) { '.ai-pm/backups' } else { 'GuGuBoard 設定資料夾' }); keep = $BACKUP_KEEP }
}
function Test-CanRestore($s, $Pj) { $r = $s.allowed[$Pj.id]; $r -eq 'admin' -or $r -eq 'high-tier' }
function Invoke-Restore($req, $res, $s, $Pj) {
  if (-not (Test-CanRestore $s $Pj)) { return Send-Err $res 403 'E_FORBIDDEN' }
  $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  $txt = $null; $src = ''
  if ([string]$in.source -eq 'backup') { $n = [string]$in.name; if ($n -notmatch '^board-[0-9-]+-[A-Za-z0-9-]{1,30}\.json$') { return Send-Err $res 400 'E_BAD_NAME' }
    $f = Join-Path (Get-BackupDir $Pj) $n; if (-not (Test-Path -LiteralPath $f)) { return Send-Err $res 404 'E_NOT_FOUND' }; $txt = [IO.File]::ReadAllText($f); $src = "備份 $n" }
  elseif ([string]$in.source -eq 'git') { $sha = [string]$in.sha; if (-not $Pj.git -or $sha -notmatch '^[0-9a-fA-F]{7,40}$') { return Send-Err $res 400 'E_BAD_REF' }
    $r = Invoke-Git $Pj @('show', "${sha}:$($Pj.rel)"); if ($r.Code -ne 0) { return Send-Err $res 404 'E_NOT_FOUND' }; $txt = $r.Out; $src = "git $($sha.Substring(0,7))" }
  else { return Send-Err $res 400 'E_BAD_REQUEST' }
  try { $new = Read-BoardJson $txt } catch { return Send-Json $res @{ error = 'E_BAD_JSON'; message = '來源不是合法 JSON' } 409 }
  $cur = Read-BoardObj $Pj; $keep = @{}; foreach ($it in $new['items']) { if (IsObj $it) { $keep[[string]$it['id']] = 1 } }
  $rm = [Collections.ArrayList]::new(); if (IsArr (Get-V $new 'removed')) { foreach ($x in $new['removed']) { [void]$rm.Add($x) } }
  foreach ($it in $cur['items']) { if ((IsObj $it) -and -not $keep.ContainsKey([string]$it['id'])) { [void]$rm.Add([ordered]@{ id = [string]$it['id']; title = [string]$it['title']; at = (Get-NowIso); by = [string]$s.user; reason = 'restore' }) } }
  if ($rm.Count) { $new['removed'] = @($rm.ToArray()) }
  $errs = @(Write-BoardChecked $Pj $new $null 'before-restore' -SkipIntegrity)   # 還原是人工確認的復原操作：略過 20% 規則，但仍檢查格式與燈號
  if ($errs.Count) { return Send-Json $res @{ error = 'E_INVALID'; errors = $errs } 422 }
  $committed = $false; $cmErr = ''
  if ($in.commit -eq $true -and $Pj.git) { $c = Invoke-Git $Pj @('-c', "user.name=$($s.user -replace '[<>\r\n]', '')", '-c', 'user.email=board-admin@ai-board.local', 'commit', '-q', '-m', "chore(board): 還原 board.json（$src）", '--', $Pj.rel); $committed = $c.Code -eq 0; if (-not $committed) { $cmErr = (Clip ($c.Err + $c.Out) 2000) } ; if ($committed) { $Pj.dirtyAt = $null; Push-All 'history' @{ p = $Pj.id } $Pj.id } }
  Write-Host "$(Get-Date -f HH:mm:ss) [$($Pj.id)] $($s.user) 還原 board.json（$src）"
  Send-Json $res @{ ok = $true; source = $src; committed = $committed; commitError = $cmErr }
}
function Invoke-MigrateAiPm($req, $res, $s, $Pj) {
  if ($s.role -ne 'admin') { return Send-Err $res 403 'E_FORBIDDEN' }
  $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  if (Test-InAiPm $Pj.json) { return Send-Json $res @{ error = 'E_ALREADY'; message = '已經在 .ai-pm/ 裡' } 409 }
  $root = $Pj.dir; $dst = Join-Path (Join-Path $root '.ai-pm') 'board.json'
  if (Test-Path -LiteralPath $dst) { return Send-Json $res @{ error = 'E_EXISTS'; message = '.ai-pm/board.json 已存在，請先確認內容' } 409 }
  $oldText = [IO.File]::ReadAllText($Pj.json); [void](Backup-Board $Pj $oldText 'before-migrate')
  New-Item -ItemType Directory (Split-Path -Parent $dst) -Force | Out-Null
  $moved = $false
  if ($Pj.git) { $t = Invoke-Git $Pj @('ls-files', '--error-unmatch', '--', $Pj.rel); if ($t.Code -eq 0) { $m = Invoke-Git $Pj @('mv', '--', $Pj.rel, '.ai-pm/board.json'); if ($m.Code -ne 0) { return Send-Json $res @{ error = 'E_GIT'; message = (Clip $m.Err 500) } 422 }; $moved = $true } }
  if (-not $moved) { Move-Item -LiteralPath $Pj.json -Destination $dst }
  Initialize-AiPm $dst $Pj.id $Pj.name
  $hc = Join-Path (Join-Path $root '.ai-hooks') 'config.json'; $hooksUpd = $false
  if (Test-Path -LiteralPath $hc) { $h = [IO.File]::ReadAllText($hc); $h2 = $h -replace '"boardPath":\s*"[^"]*"', '"boardPath": ".ai-pm/board.json"'; if ($h2 -ne $h) { Copy-Item -LiteralPath $hc -Destination ($hc + '.bak') -Force; [IO.File]::WriteAllText($hc, $h2, [Text.UTF8Encoding]::new($false)); $hooksUpd = $true } }
  $list = @(Read-Projects); foreach ($p in $list) { if ($p.id -eq $Pj.id) { $p.boardPath = [IO.Path]::GetFullPath($dst) } }; Save-Projects $list
  $def = $list | Where-Object id -eq $Pj.id | Select-Object -First 1; $oldRel = $Pj.rel
  $NP = Add-LoadedProject $def; if (-not $NP) { return Send-Err $res 500 'E_PROJECT_LOAD' }; $NP.lastTag = Get-Tag $NP; $NP.lastText = [IO.File]::ReadAllText($NP.json)
  $committed = $false; $cmErr = ''
  if ($in.commit -eq $true -and $NP.git) {
    $paths = @('.ai-pm/board.json', '.ai-pm/README.md', '.ai-pm/project.json', '.ai-pm/.gitignore'); if ($hooksUpd) { $paths += '.ai-hooks/config.json' }
    [void](Invoke-Git $NP (@('add', '--') + $paths)); $all = $paths; if ($moved) { $all = @($oldRel) + $paths }
    $c = Invoke-Git $NP (@('-c', "user.name=$($s.user -replace '[<>\r\n]', '')", '-c', 'user.email=board-admin@ai-board.local', 'commit', '-q', '-m', 'chore(board): 將 board.json 搬到 .ai-pm/', '--') + $all)
    $committed = $c.Code -eq 0; if (-not $committed) { $cmErr = Clip ($c.Err + $c.Out) 2000 }
  }
  Write-Host "$(Get-Date -f HH:mm:ss) [$($Pj.id)] 已搬移 board.json → .ai-pm/board.json"
  Push-All 'board' @{ p = $Pj.id } $Pj.id
  Send-Json $res @{ ok = $true; boardPath = $NP.json; gitMv = $moved; hooksUpdated = $hooksUpd; committed = $committed; commitError = $cmErr }
}

# ---------- Agent token（專案範圍、會過期、可撤銷；只存 SHA-256 雜湊）----------
$AgentTokFile = Join-Path $ConfigDir 'agent-tokens.json'
$AGENT_ROLES = 'dev-agent', 'verifier', 'high-tier'   # 永遠不會是 admin
function Read-AgentTokens { if (Test-Path -LiteralPath $AgentTokFile) { @((Get-Content -LiteralPath $AgentTokFile -Raw -Encoding UTF8 | ConvertFrom-Json).tokens | Where-Object { $_ }) } else { @() } }
function Save-AgentTokens($l) { Initialize-ConfigDir; [ordered]@{ version = 1; tokens = @($l) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $AgentTokFile -Encoding UTF8 }
function New-AgentToken([string]$pid_, [string]$role, [string]$name, [int]$minutes, [string]$by, [bool]$noApprove) {
  if ($role -notin $AGENT_ROLES) { throw 'E_BAD_ROLE' }
  $b = [byte[]]::new(4); [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); $tid = ([BitConverter]::ToString($b) -replace '-', '').ToLower()
  $secret = New-Token; $tok = "aipm_${tid}_$secret"
  $rec = [ordered]@{ id = $tid; project = $pid_; role = $role; name = $name; hash = (Get-Key $tok); createdBy = $by; createdAt = (Get-NowIso); expiresAt = (Get-Date).AddMinutes($minutes).ToString('o'); revoked = $false; noApprove = $noApprove; lastUsed = '' }
  $l = @(Read-AgentTokens | Where-Object { -not $_.revoked -and [DateTimeOffset]::Parse([string]$_.expiresAt) -gt [DateTimeOffset]::Now }) + @([pscustomobject]$rec)
  if ($l.Count -gt 500) { $l = @($l | Select-Object -Last 500) }
  Save-AgentTokens $l; @{ token = $tok; rec = $rec }
}
$agentRate = @{}
function Get-AgentAuth($req) {
  $h = [string]$req.Headers['Authorization']; if ($h -notmatch '^Bearer (aipm_([0-9a-f]{8})_[A-Za-z0-9_-]{20,80})$') { return $null }
  $tok = $Matches[1]; $tid = $Matches[2]; $l = @(Read-AgentTokens); $t = $l | Where-Object { $_.id -eq $tid } | Select-Object -First 1
  if (-not $t -or $t.revoked) { return $null }
  if ([DateTimeOffset]::Parse([string]$t.expiresAt) -lt [DateTimeOffset]::Now) { return $null }
  if (-not (Test-Equal ([Convert]::FromBase64String((Get-Key $tok))) ([Convert]::FromBase64String([string]$t.hash)))) { return $null }
  if (-not $projects.Contains([string]$t.project)) { return $null }
  $now = Get-Date; $r = $agentRate[$tid]; if (-not $r -or ($now - $r.t0).TotalSeconds -ge 60) { $r = @{ t0 = $now; n = 0 }; $agentRate[$tid] = $r }; $r.n++
  if ($r.n -gt 240) { return 'RATE' }
  if (-not $t.lastUsed -or ($now - [datetime]::Parse([string]$t.lastUsed)).TotalMinutes -ge 1) { $t.lastUsed = $now.ToString('o'); Save-AgentTokens $l }
  @{ id = $tid; project = [string]$t.project; role = [string]$t.role; name = [string]$t.name; noApprove = [bool]$t.noApprove }
}
function Invoke-AgentTokensAdmin($req, $res, $s, $Pj, [bool]$post) {
  if ($s.role -ne 'admin') { return Send-Err $res 403 'E_FORBIDDEN' }
  if ($post) {
    $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
    if ([string]$in.action -eq 'revoke') { $l = @(Read-AgentTokens); $hit = $false; foreach ($t in $l) { if ($t.id -eq [string]$in.id -and $t.project -eq $Pj.id) { $t.revoked = $true; $hit = $true } }; if (-not $hit) { return Send-Err $res 404 'E_NOT_FOUND' }; Save-AgentTokens $l; Write-AcctAudit $s 'agentTokenRevoke' @{ project = $Pj.id; id = [string]$in.id } }
    else { return Send-Err $res 400 'E_BAD_ACTION' }
  }
  $l = @(Read-AgentTokens | Where-Object { $_.project -eq $Pj.id } | ForEach-Object { [ordered]@{ id = $_.id; role = $_.role; name = $_.name; createdBy = $_.createdBy; createdAt = $_.createdAt; expiresAt = $_.expiresAt; revoked = [bool]$_.revoked; lastUsed = $_.lastUsed; dispatcher = [bool]$_.noApprove } })
  Send-Json $res @{ tokens = $l }
}

# ---------- 規則與流程摘要（bootstrap，讓提示詞保持簡短）----------
$RULES = @(
  '[L1] Backlog／Todo（佈署 Planned）只能灰燈', '[L2] In Progress／In Review（佈署 Deploying／Verifying）只能綠／黃／紅；灰燈須 paused:true + pausedReason',
  '[L3] Done（佈署 Released）只能藍燈；藍燈只能在 Done／Released；Rolled Back 必須紅燈', '[L4] 黃燈／紅燈必須填 lightReason',
  '[L5] 開發代理不可設藍燈、移到 Done、設 Released、填 approvedBy', '[L6] Task 在 In Review 綠燈時 tdd 或 tests.status 必須是 Green',
  '[L7] 燈號或欄位變更要更新 updatedAt 並追加 history {at, from, to, by, reason}', '不可刪卡或整檔覆寫 board.json（移除要留 removed 紀錄；一次移除 >20% 會被擋）')
$WORKFLOW = @{
  'dev-agent' = @('領取 Task（POST claim）→ 讀 BDD 與驗收條件', '狀態改 In Progress（綠燈）→ 依 TDD 先寫失敗的測試再實作', '測試全綠後改 In Review，tdd／tests.status = Green，附 PR 連結', '每 5 分鐘 heartbeat；完成或卡住都要 report，再 release', '遇到阻礙：燈號改黃／紅並寫 lightReason，然後 release（不要硬做）')
  'verifier'  = @('領取 In Review 的 Task', '依 TDD／BDD 實際操作驗證，截圖錄影附在 notes', '通過：交給人或高階模型核准（派工器啟動時不可自行移到 Done）；不通過：退回 In Progress 並寫原因')
  'high-tier' = @('規劃與審查：拆 Story／Task、估算、更新 BDD', '審查 PR 與驗證結果，必要時調整燈號與優先順序', '不可略過驗證直接核准佈署')
}
function Get-Bootstrap($Pj, [string]$role, [string]$base) {
  [ordered]@{ project = [ordered]@{ id = $Pj.id; name = $Pj.name }; role = $role; board = $(if ($Pj.rel) { $Pj.rel } else { [IO.Path]::GetFileName($Pj.json) })
    rules = $RULES; workflow = @($WORKFLOW[$role]); lease = @{ minutes = $LEASE_MIN; heartbeat = '每 5 分鐘 POST /api/agent/v1/heartbeat' }
    endpoints = [ordered]@{ me = 'GET /api/agent/v1/me'; bootstrap = 'GET /api/agent/v1/bootstrap'; tickets = 'GET /api/agent/v1/tickets?mine=1'; ticket = 'GET /api/agent/v1/tickets/<id>'; update = 'PATCH /api/agent/v1/tickets/<id>  {status, light, lightReason, paused, pausedReason, tdd, tests, prUrl, note, reason}'
      claim = 'POST /api/agent/v1/claim  {ticket?}'; heartbeat = 'POST /api/agent/v1/heartbeat {ticket}'; release = 'POST /api/agent/v1/release {ticket}'; report = 'POST /api/agent/v1/report {ticket, summary, result}' }
    base = $base; note = '不要直接編輯 board.json；所有修改走 PATCH，伺服器會用同一套規則驗證。不要把 token 寫進 repo 或 log。' }
}

# ---------- 領取（lease + heartbeat，不會重複領取）----------
$LEASE_MIN = 15.0; if ("$env:AIPM_LEASE_MIN" -match '^\d{1,3}(\.\d+)?$') { $LEASE_MIN = [double]$env:AIPM_LEASE_MIN }   # 租約分鐘數（測試可用環境變數縮短）
$claims = @{}   # projectId -> @{ ticketId -> @{ agent; token; name; until; at } }
function Get-ClaimFile([string]$pid_) { Join-Path $ConfigDir "claims-$pid_.json" }
function Get-Claims([string]$pid_) {
  if (-not $claims.ContainsKey($pid_)) { $m = @{}; $f = Get-ClaimFile $pid_; if (Test-Path -LiteralPath $f) { try { $o = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $o.PSObject.Properties) { $m[$p.Name] = @{ token = [string]$p.Value.token; name = [string]$p.Value.name; until = [datetime]::Parse([string]$p.Value.until); at = [string]$p.Value.at } } } catch {} }; $claims[$pid_] = $m }
  $m = $claims[$pid_]; foreach ($k in @($m.Keys)) { if ($m[$k].until -lt (Get-Date)) { $m.Remove($k) } }   # 過期自動釋放
  $m
}
function Save-Claims([string]$pid_) { Initialize-ConfigDir; $o = [ordered]@{}; foreach ($k in $claims[$pid_].Keys) { $c = $claims[$pid_][$k]; $o[$k] = [ordered]@{ token = $c.token; name = $c.name; until = $c.until.ToString('o'); at = $c.at } }; ([pscustomobject]$o) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-ClaimFile $pid_) -Encoding UTF8 }
function Test-ClaimCandidate($it, $b, $ag) {
  $st = [string]$it['status']; $lv = [string]$it['level']; $lt = [string]$it['light']
  $ok = switch ($ag.role) { 'dev-agent' { $lv -ceq 'Task' -and $st -cin 'Todo', 'In Progress' } 'verifier' { $lv -ceq 'Task' -and $st -ceq 'In Review' } default { $lv -cin 'Story', 'Feature' -and $st -cin 'Backlog', 'Todo' } }
  if (-not $ok -or $lt -ceq 'Red' -or (Get-V $it 'paused') -eq $true) { return $false }
  $a = [string](Get-V $it 'assignee'); if ($a -and $a -cne $ag.name -and $a -cne ('agent:' + $ag.role)) { if (-not ($a.StartsWith('group:') -and $ag.name -and (@(Read-Groups | Where-Object { 'group:' + $_.id -ceq $a -and (Get-Members $_) -ccontains $ag.name }).Count))) { return $false } }
  if (IsArr (Get-V $it 'dependsOn')) { foreach ($d in $it['dependsOn']) { $x = Find-Item $b ([string]$d); if ($x -and [string]$x['status'] -cne 'Done' -and [string]$x['status'] -cne 'Released') { return $false } } }
  $true
}
function Invoke-AgentApi($req, $res, $ag, [string]$sub) {
  $Pj = $projects[$ag.project]; $m = $req.HttpMethod; $base = "http://localhost:$Port"
  if ($sub -eq '/me' -and $m -eq 'GET') { return Send-Json $res @{ project = $Pj.id; name = $Pj.name; role = $ag.role; agent = $ag.name; tokenId = $ag.id; noApprove = $ag.noApprove } }
  if ($sub -in '/bootstrap', '/rules' -and $m -eq 'GET') { return Send-Json $res (Get-Bootstrap $Pj $ag.role $base) }
  $b = Read-BoardObj $Pj; $cl = Get-Claims $Pj.id
  if ($sub -eq '/tickets' -and $m -eq 'GET') {
    $mine = $req.QueryString['mine'] -eq '1'
    $l = @($b['items'] | Where-Object { IsObj $_ } | Where-Object { -not $mine -or ($cl.ContainsKey([string]$_['id']) -and $cl[[string]$_['id']].token -eq $ag.id) -or ([string](Get-V $_ 'assignee') -ceq $ag.name -and $ag.name) } | ForEach-Object { [ordered]@{ id = $_['id']; level = $_['level']; title = $_['title']; status = $_['status']; light = $_['light']; parentId = (Get-V $_ 'parentId'); assignee = (Get-V $_ 'assignee'); claimedBy = $(if ($cl.ContainsKey([string]$_['id'])) { $cl[[string]$_['id']].name } else { $null }) } })
    return Send-Json $res @{ tickets = $l }
  }
  if ($sub -match '^/tickets/([A-Za-z0-9._-]{1,40})$') {
    $tid = $Matches[1]; $it = Find-Item $b $tid; if (-not $it) { return Send-Err $res 404 'E_NOT_FOUND' }
    if ($m -eq 'GET') { $kids = @($b['items'] | Where-Object { (IsObj $_) -and (Get-V $_ 'parentId') -ceq $tid } | ForEach-Object { $_['id'] }); $par = $null; if (Get-V $it 'parentId') { $par = Find-Item $b ([string]$it['parentId']) }
      return Send-Json $res @{ ticket = $it; children = $kids; parent = $(if ($par) { [ordered]@{ id = $par['id']; title = $par['title']; level = $par['level'] } } else { $null }); claim = $(if ($cl.ContainsKey($tid)) { @{ by = $cl[$tid].name; until = $cl[$tid].until.ToString('o') } } else { $null }) } }
    if ($m -eq 'PATCH' -or $m -eq 'POST') {
      if ($cl.ContainsKey($tid) -and $cl[$tid].token -ne $ag.id) { return Send-Json $res @{ error = 'E_CLAIMED'; message = "工單 $tid 已被 $($cl[$tid].name) 領取" } 409 }
      $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
      $from = "$($it['status']) / $($it['light'])"; $chg = $false
      foreach ($k in 'status', 'light', 'lightReason', 'pausedReason', 'tdd', 'prUrl', 'startedAt', 'completedAt') { if ($in.PSObject.Properties[$k]) { $v = $in.$k; if ($null -ne $v) { $v = [string]$v }; if ($null -eq $v) { $it.Remove($k) } else { $it[$k] = $v } } }
      if ($in.PSObject.Properties['paused']) { if ($in.paused -eq $true) { $it['paused'] = $true } else { $it.Remove('paused') } }
      if ($in.PSObject.Properties['tests'] -and $in.tests) { $t = [ordered]@{}; foreach ($p in $in.tests.PSObject.Properties) { if ($p.Name -in 'status', 'url') { $t[$p.Name] = [string]$p.Value } elseif ($p.Name -in 'passed', 'failed') { $t[$p.Name] = [double]$p.Value } }; $it['tests'] = $t }
      $to = "$($it['status']) / $($it['light'])"; $who = "$($ag.name)（$($ag.role)）"
      if ($in.note) { $ns = [Collections.ArrayList]::new(); if (IsArr (Get-V $it 'notes')) { foreach ($x in $it['notes']) { [void]$ns.Add($x) } }; [void]$ns.Add([ordered]@{ at = (Get-NowIso); by = $who; text = (Clip ([string]$in.note) 2000) }); $it['notes'] = @($ns.ToArray()) }
      if ($from -cne $to) {
        if ($it['status'] -cin 'In Progress', 'Deploying' -and -not (Get-V $it 'startedAt')) { $it['startedAt'] = Get-NowIso }
        if ($it['status'] -cin 'Done', 'Released' -and -not (Get-V $it 'completedAt')) { $it['completedAt'] = Get-NowIso }
        $hs = [Collections.ArrayList]::new(); if (IsArr (Get-V $it 'history')) { foreach ($x in $it['history']) { [void]$hs.Add($x) } }
        [void]$hs.Add([ordered]@{ at = (Get-NowIso); from = $from; to = $to; by = $who; reason = [string]$in.reason }); $it['history'] = @($hs.ToArray())
      }
      $it['updatedAt'] = Get-NowIso
      $errs = @(Write-BoardChecked $Pj $b $ag.role 'agent' -flags @{ noApprove = $ag.noApprove })
      if ($errs.Count) { return Send-Json $res @{ error = 'E_RULES'; message = '修改不符規則，未寫入'; errors = $errs } 422 }
      return Send-Json $res @{ ok = $true; ticket = (Find-Item (Read-BoardObj $Pj) $tid) }
    }
  }
  if ($m -ne 'POST') { return Send-Err $res 405 'E_METHOD' }
  $in = Read-Body $req; if (-not $in) { $in = [pscustomobject]@{} }
  switch ($sub) {
    '/claim' {
      $want = [string]$in.ticket; $mine = @($cl.Keys | Where-Object { $cl[$_].token -eq $ag.id })
      if ($mine.Count -and -not $want) { return Send-Json $res @{ ok = $true; ticket = $mine[0]; already = $true; until = $cl[$mine[0]].until.ToString('o') } }
      $cand = $null
      if ($want) { $it = Find-Item $b $want; if (-not $it) { return Send-Err $res 404 'E_NOT_FOUND' }; if ($cl.ContainsKey($want) -and $cl[$want].token -ne $ag.id) { return Send-Json $res @{ error = 'E_CLAIMED'; message = "已被 $($cl[$want].name) 領取" } 409 }; if (-not (Test-ClaimCandidate $it $b $ag)) { return Send-Json $res @{ error = 'E_NOT_CLAIMABLE'; message = '這張工單目前不能由這個角色領取（狀態、紅燈、暫停、相依或指派不符）' } 409 }; $cand = $it }
      else { foreach ($it in $b['items']) { if ((IsObj $it) -and -not $cl.ContainsKey([string]$it['id']) -and (Test-ClaimCandidate $it $b $ag)) { $cand = $it; break } } }
      if (-not $cand) { return Send-Json $res @{ ok = $true; ticket = $null; message = '目前沒有可領取的工單' } }
      $id = [string]$cand['id']; $cl[$id] = @{ token = $ag.id; name = $ag.name; until = (Get-Date).AddMinutes($LEASE_MIN); at = (Get-NowIso) }; Save-Claims $Pj.id
      Push-All 'board' @{ p = $Pj.id; claim = $id } $Pj.id
      return Send-Json $res @{ ok = $true; ticket = $id; title = $cand['title']; until = $cl[$id].until.ToString('o'); leaseMinutes = $LEASE_MIN }
    }
    '/heartbeat' { $id = [string]$in.ticket; if (-not $cl.ContainsKey($id) -or $cl[$id].token -ne $ag.id) { return Send-Json $res @{ error = 'E_NO_CLAIM'; message = '沒有領取這張工單（可能已過期被釋放）' } 409 }; $cl[$id].until = (Get-Date).AddMinutes($LEASE_MIN); Save-Claims $Pj.id; return Send-Json $res @{ ok = $true; until = $cl[$id].until.ToString('o') } }
    '/release' { $id = [string]$in.ticket; if ($cl.ContainsKey($id) -and $cl[$id].token -eq $ag.id) { $cl.Remove($id); Save-Claims $Pj.id; Push-All 'board' @{ p = $Pj.id } $Pj.id }; return Send-Json $res @{ ok = $true } }
    '/report' {
      $id = [string]$in.ticket; $it = Find-Item $b $id; if (-not $it) { return Send-Err $res 404 'E_NOT_FOUND' }
      $ns = [Collections.ArrayList]::new(); if (IsArr (Get-V $it 'notes')) { foreach ($x in $it['notes']) { [void]$ns.Add($x) } }
      [void]$ns.Add([ordered]@{ at = (Get-NowIso); by = "$($ag.name)（$($ag.role)）"; text = (Clip ("[report:" + ([string]$in.result -replace '[^A-Za-z-]', '') + "] " + [string]$in.summary) 2000) }); $it['notes'] = @($ns.ToArray())
      $errs = @(Write-BoardChecked $Pj $b $ag.role 'report' -flags @{ noApprove = $ag.noApprove }); if ($errs.Count) { return Send-Json $res @{ error = 'E_RULES'; errors = $errs } 422 }
      if ($in.release -eq $true -and $cl.ContainsKey($id) -and $cl[$id].token -eq $ag.id) { $cl.Remove($id); Save-Claims $Pj.id }
      return Send-Json $res @{ ok = $true }
    }
  }
  Send-Err $res 404 'E_NOT_FOUND'
}

# ---------- AI 提示詞 ----------
$ROLE_LABEL = @{ 'dev-agent' = '開發代理（dev agent）'; 'verifier' = '驗證代理（verifier）'; 'high-tier' = '高階模型（規劃／審查）' }
function Invoke-AgentPrompt($req, $res, $s, $Pj) {
  $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  $role = [string]$in.role; if ($role -notin $AGENT_ROLES) { return Send-Err $res 400 'E_BAD_ROLE' }
  $tk = [string]$in.ticket; if ($tk -and $tk -notmatch '^[A-Za-z0-9._-]{1,40}$') { return Send-Err $res 400 'E_BAD_ID' }
  $my = [string]$s.allowed[$Pj.id]; if ((Get-RoleRank $my) -lt (Get-RoleRank $role) -and $my -ne 'admin') { return Send-Err $res 403 'E_FORBIDDEN' }
  $tline = $(if ($tk) { "這次處理工單 $tk。" } else { '請領取下一張指派給你的工單。' })
  if ([string]$in.mode -ne 'B') {
    $txt = "你是 GuGuBoard 專案「$($Pj.name)」（id: $($Pj.id)）的$($ROLE_LABEL[$role])。`n先讀 repo 的 AGENTS.md（或你的 AI 工具規則檔）與 .ai-pm/project.json；看板是 $(if ($Pj.rel) { $Pj.rel } else { '.ai-pm/board.json' })。`n$tline`n依 ai-dev-pipeline 流程工作；只用編輯工具修改看板，遵守燈號規則 L1–L7（開發代理不可移到 Done 或設藍燈），每次變更燈號或欄位都要追加 history。"
    return Send-Json $res @{ mode = 'A'; prompt = $txt }
  }
  if ($s.role -ne 'admin' -and $my -ne 'high-tier') { return Send-Err $res 403 'E_FORBIDDEN' }
  $days = 1; if ([string]$in.days -match '^\d{1,2}$') { $days = [Math]::Min(30, [Math]::Max(1, [int]$in.days)) }
  $nm = ([string]$in.agentName -replace '[^A-Za-z0-9._-]', ''); if (-not $nm) { $nm = "$role-$((Get-Date).ToString('MMddHHmm'))" }; if ($nm.Length -gt 32) { $nm = $nm.Substring(0, 32) }
  $t = New-AgentToken $Pj.id $role $nm ($days * 1440) $s.user $false
  Write-AcctAudit $s 'agentTokenCreate' @{ project = $Pj.id; id = $t.rec.id; role = $role; days = $days }
  $base = "http://localhost:$Port"
  $txt = "你是 GuGuBoard 專案「$($Pj.name)」的$($ROLE_LABEL[$role])（代號 $nm）。用 GuGuBoard Agent API 工作，不需要專案路徑：`nAPI：$base/api/agent/v1　標頭 Authorization: Bearer $($t.token)（$days 天後失效，可在看板撤銷；不要寫進 repo 或 log）`n1. GET /bootstrap 取得規則與流程`n2. $(if ($tk) { 'POST /claim {"ticket":"' + $tk + '"}' } else { 'POST /claim 領取下一張工單' })，每 5 分鐘 POST /heartbeat`n3. 用 PATCH /tickets/<id> 更新狀態、燈號、測試與備註（伺服器會驗證 L1–L7）`n4. 完成或卡住時 POST /report，再 POST /release"
  Send-Json $res @{ mode = 'B'; prompt = $txt; tokenId = $t.rec.id; expiresAt = $t.rec.expiresAt }
}

# ---------- 使用者偏好（語言、主題）----------
$LANGS = 'zh-TW', 'en', 'zh-CN'; $THEMES = 'light', 'gray', 'dark', 'gugu'
function Get-Prefs([string]$name) { $u = Read-Users | Where-Object name -eq $name | Select-Object -First 1; $p = @{ lang = 'zh-TW'; theme = 'light' }; if ($u -and $u.prefs) { if ([string]$u.prefs.lang -in $LANGS) { $p.lang = [string]$u.prefs.lang }; if ([string]$u.prefs.theme -in $THEMES) { $p.theme = [string]$u.prefs.theme } }; $p }
function Invoke-Prefs($req, $res, $s) {
  $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  $p = Get-Prefs $s.user; if ([string]$in.lang -in $LANGS) { $p.lang = [string]$in.lang }; if ([string]$in.theme -in $THEMES) { $p.theme = [string]$in.theme }
  if (-not $NoAuth) { $l = @(Read-Users); $u = $l | Where-Object name -eq $s.user | Select-Object -First 1; if ($u) { $u | Add-Member -NotePropertyName prefs -NotePropertyValue ([ordered]@{ lang = $p.lang; theme = $p.theme }) -Force; Save-Users $l } }
  Send-Json $res @{ ok = $true; prefs = $p }
}

# ---------- 整合設定（integrations.json：Google Sheets、外部監看、通知、派工器）；密鑰只在伺服器 ----------
$IntegFile = Join-Path $ConfigDir 'integrations.json'
$SECRET_KEYS = 'clientSecret', 'refreshToken', 'smtpPassword', 'chatWebhook', 'serviceAccountKey', 'googleClientSecret'
function Read-Integ { if (Test-Path -LiteralPath $IntegFile) { try { return (Get-Content -LiteralPath $IntegFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }; [pscustomobject]@{} }
function Save-Integ($o) { Initialize-ConfigDir; $o | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $IntegFile -Encoding UTF8 }
function Get-Sec($o, [string]$k) { if ($o -and $o.PSObject.Properties[$k]) { $o.$k } else { $null } }
function ConvertTo-Masked($o) {   # 回傳給瀏覽器前把密鑰換成 { set: true }
  if ($null -eq $o) { return $null }
  if ($o -is [pscustomobject]) { $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { if ($p.Name -in $SECRET_KEYS) { $h[$p.Name] = @{ set = [bool]$p.Value } } else { $h[$p.Name] = ConvertTo-Masked $p.Value } }; return $h }
  if ($o -is [array]) { return ,@($o | ForEach-Object { ConvertTo-Masked $_ }) }
  $o
}
function Merge-Integ($cur, $in) {   # 密鑰欄位沒給（或給 { set: true }）就保留舊值；給空字串才清除
  $h = [ordered]@{}; if ($cur) { foreach ($p in $cur.PSObject.Properties) { $h[$p.Name] = $p.Value } }
  foreach ($p in $in.PSObject.Properties) {
    if ($p.Name -in $SECRET_KEYS) { if ($p.Value -is [string]) { $h[$p.Name] = $p.Value } ; continue }
    if ($p.Value -is [pscustomobject] -and -not ($p.Name -in 'projects')) { $h[$p.Name] = Merge-Integ (Get-Sec $cur $p.Name) $p.Value } else { $h[$p.Name] = $p.Value }
  }
  [pscustomobject]$h
}
function Invoke-IntegAdmin($req, $res, $s, [bool]$post) {
  if ($s.role -ne 'admin') { return Send-Err $res 403 'E_FORBIDDEN' }
  if (-not $req.IsLocal -or (Test-External $req)) { return Send-Err $res 403 'E_NOT_LOCAL' }   # 敏感設定只限本機
  $cur = Read-Integ
  if ($post) {
    $in = Read-BodyMax $req 65536; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
    if ($in.PSObject.Properties['external'] -and $in.external.publicUrl -and [string]$in.external.publicUrl -notmatch '^https://[A-Za-z0-9.-]+(:\d+)?/?$') { return Send-Json $res @{ error = 'E_BAD_URL'; message = '外部網址必須是 https://主機名稱' } 400 }
    if ($in.PSObject.Properties['notify'] -and $in.notify.chatWebhook -and [string]$in.notify.chatWebhook -notmatch '^https://') { return Send-Json $res @{ error = 'E_BAD_URL'; message = 'Google Chat webhook 必須是 https 網址' } 400 }
    $cur = Merge-Integ $cur $in; Save-Integ $cur; Write-AcctAudit $s 'integrations' @{ keys = @($in.PSObject.Properties.Name) }
    if ($in.test -eq 'notify') { $r = Send-Notify $null 'test' "GuGuBoard 測試通知（$($s.user)）" 'test' $null; return Send-Json $res @{ ok = $true; test = $r; settings = (ConvertTo-Masked $cur) } }
    if ($in.test -eq 'sheets') { $r = @(); foreach ($Pj in $projects.Values) { $r += Sync-Sheets $Pj $true }; return Send-Json $res @{ ok = $true; test = $r; settings = (ConvertTo-Masked $cur) } }
  }
  Send-Json $res @{ settings = (ConvertTo-Masked $cur); dispatch = @($projects.Keys | ForEach-Object { @{ project = $_; config = (Get-DispatchCfg $_) } }) }
}

# ---------- 通知：Gmail（SMTP）與 Google Chat webhook ----------
# 事件：pr-opened、pr-merged、ci-fail、red-light、done、released、dispatch-stop、test。規則依專案與群組設定（群組成員的 email 收信）
function Get-NotifyTargets($cfg, [string]$pid_, [string]$event) {
  $mails = [Collections.Generic.List[string]]::new(); $chat = $false
  foreach ($r in @($cfg.rules)) { if (-not $r) { continue }
    $evs = @($r.events); $ps = @($r.projects); if ($event -ne 'test' -and $evs.Count -and $evs -notcontains $event) { continue }; if ($pid_ -and $ps.Count -and $ps -notcontains '*' -and $ps -notcontains $pid_) { continue }
    foreach ($m in @($r.emails)) { if ([string]$m -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $mails.Add([string]$m) } }
    foreach ($gid in @($r.groups)) { $g = Read-Groups | Where-Object { $_.id -ceq [string]$gid } | Select-Object -First 1; if ($g) { foreach ($n in Get-Members $g) { $u = Read-Users | Where-Object name -ceq $n | Select-Object -First 1; if ($u -and [string]$u.email -match '^[^@\s]+@[^@\s]+$' -and [string]$u.status -ne 'disabled') { $mails.Add([string]$u.email) } } } }
    if ($r.chat -eq $true) { $chat = $true } }
  @{ mails = @($mails | Select-Object -Unique); chat = $chat }
}
$notifyLog = [Collections.ArrayList]::new()
function Send-Notify($Pj, [string]$event, [string]$text, [string]$subject, $url) {
  $all = Read-Integ; $cfg = Get-Sec $all 'notify'; $out = @{ event = $event; mail = 0; chat = $false; errors = @() }
  if (-not $cfg -or -not $cfg.enabled) { $out.errors += 'notify 未啟用'; return $out }
  $pid_ = $(if ($Pj) { $Pj.id } else { '' }); $tg = Get-NotifyTargets $cfg $pid_ $event
  if ($event -eq 'test') { $tg.chat = [bool]$cfg.chatWebhook; if (-not $tg.mails.Count -and $cfg.from) { $tg.mails = @([string]$cfg.from) } }
  $title = "[GuGuBoard$(if ($Pj) { '・' + $Pj.name })] $subject"
  if ($tg.chat -and $cfg.chatWebhook) {
    try { $body = @{ text = "*$title*`n$text$(if ($url) { "`n$url" })" } | ConvertTo-Json -Compress
      Invoke-WebRequest -Method Post -Uri ([string]$cfg.chatWebhook) -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop | Out-Null; $out.chat = $true }
    catch { $out.errors += "Google Chat：$($_.Exception.Message)" } }
  if ($tg.mails.Count -and $cfg.smtpHost) {
    try { $sc = [Net.Mail.SmtpClient]::new([string]$cfg.smtpHost, $(if ($cfg.smtpPort) { [int]$cfg.smtpPort } else { 587 })); $sc.EnableSsl = ($cfg.smtpSsl -ne $false); $sc.Timeout = 10000
      if ($cfg.smtpUser) { $sc.Credentials = [Net.NetworkCredential]::new([string]$cfg.smtpUser, [string]$cfg.smtpPassword) }
      $mm = [Net.Mail.MailMessage]::new(); $mm.From = [Net.Mail.MailAddress]::new([string]$(if ($cfg.from) { $cfg.from } else { $cfg.smtpUser })); foreach ($m in $tg.mails) { $mm.To.Add($m) }
      $mm.Subject = $title; $mm.Body = $text + $(if ($url) { "`n`n$url" } else { '' }); $mm.BodyEncoding = [Text.Encoding]::UTF8; $mm.SubjectEncoding = [Text.Encoding]::UTF8
      $sc.Send($mm); $mm.Dispose(); $sc.Dispose(); $out.mail = $tg.mails.Count }
    catch { $out.errors += "Email：$($_.Exception.Message)" } }
  [void]$notifyLog.Add(@{ at = (Get-NowIso); event = $event; project = $pid_; mail = $out.mail; chat = $out.chat; errors = $out.errors }); while ($notifyLog.Count -gt 100) { $notifyLog.RemoveAt(0) }
  $out
}
# 看板變更事件：紅燈、Done／Released（由檔案監看與伺服器寫入觸發）
function Invoke-BoardEvents($Pj, $old, $new) {
  if (-not ($old -and $new)) { return }
  try {
    $om = @{}; foreach ($it in $old['items']) { if (IsObj $it) { $om[[string]$it['id']] = $it } }
    foreach ($it in $new['items']) { if (-not (IsObj $it)) { continue }; $o = $om[[string]$it['id']]; $id = [string]$it['id']; $t = "$id $($it['title'])"
      if ($it['light'] -ceq 'Red' -and -not ($o -and $o['light'] -ceq 'Red')) { [void](Send-Notify $Pj 'red-light' "$t 變成紅燈：$($it['lightReason'])" "紅燈 $id" $null) ; Stop-DispatchOnRed $Pj $id }
      if ($it['status'] -ceq 'Done' -and -not ($o -and $o['status'] -ceq 'Done')) { [void](Send-Notify $Pj 'done' "$t 已完成" "完成 $id" $null) }
      if ($it['status'] -ceq 'Released' -and -not ($o -and $o['status'] -ceq 'Released')) { [void](Send-Notify $Pj 'released' "$t 已上線（$($it['version']) / $($it['environment'])）" "上線 $id" $null) } }
    $Pj.sheetsDirty = $true
  } catch { Write-Warning "[$($Pj.id)] 事件通知失敗：$($_.Exception.Message)" }
}
function Invoke-PrEvent($Pj, $e) {   # Update-GitHub 產生的 PR 事件
  $k = [string]$e.kind; $map = @{ opened = 'pr-opened'; merged = 'pr-merged'; ci_failed = 'ci-fail'; 'ci-fail' = 'ci-fail' }
  if ($map.ContainsKey($k)) { [void](Send-Notify $Pj $map[$k] "PR #$($e.number) $($e.title)" "PR #$($e.number) $k" $e.url) }
}

# ---------- Google Sheets 單向同步（board.json → 試算表，不會寫回）----------
# 驗證：OAuth（clientId + clientSecret + refreshToken）；PowerShell 7 也可用 service account（JSON 金鑰）。API 網址可設定（測試用 mock）
function Get-GoogleToken($g) {
  if ($script:gTok -and $script:gTok.exp -gt (Get-Date).AddMinutes(2)) { return $script:gTok.v }
  $tokUrl = $(if ($g.tokenUrl) { [string]$g.tokenUrl } else { 'https://oauth2.googleapis.com/token' })
  if ($g.refreshToken) { $r = Invoke-RestMethod -Method Post -Uri $tokUrl -Body @{ client_id = [string]$g.clientId; client_secret = [string]$g.clientSecret; refresh_token = [string]$g.refreshToken; grant_type = 'refresh_token' } -TimeoutSec 15 -ErrorAction Stop }
  elseif ($g.serviceAccountKey) {
    $k = [string]$g.serviceAccountKey | ConvertFrom-Json; $rsa = [Security.Cryptography.RSA]::Create(); if (-not ($rsa | Get-Member -Name ImportFromPem)) { throw 'service account 需要 PowerShell 7（或改用 OAuth refresh token）' }
    $rsa.ImportFromPem([string]$k.private_key); $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $b64 = { param($b) [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $h = & $b64 ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}')); $c = & $b64 ([Text.Encoding]::UTF8.GetBytes((@{ iss = $k.client_email; scope = 'https://www.googleapis.com/auth/spreadsheets'; aud = $tokUrl; iat = $now; exp = $now + 3600 } | ConvertTo-Json -Compress)))
    $sig = & $b64 ($rsa.SignData([Text.Encoding]::ASCII.GetBytes("$h.$c"), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
    $r = Invoke-RestMethod -Method Post -Uri $tokUrl -Body @{ grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer'; assertion = "$h.$c.$sig" } -TimeoutSec 15 -ErrorAction Stop
  } else { throw '尚未設定 Google 驗證（OAuth refresh token 或 service account）' }
  $script:gTok = @{ v = [string]$r.access_token; exp = (Get-Date).AddSeconds([int]$r.expires_in) }; $script:gTok.v
}
function Get-SheetRows($b) {
  $cols = 'id', 'level', 'title', 'parentId', 'status', 'light', 'lightReason', 'assignee', 'sprint', 'storyPoints', 'hours', 'plannedStart', 'due', 'startedAt', 'completedAt', 'updatedAt', 'prUrl'
  $items = @(, @($cols)); foreach ($it in $b['items']) { if (-not (IsObj $it)) { continue }; $e = Get-V $it 'estimate'; $items += , @($cols | ForEach-Object { if ($_ -eq 'storyPoints' -or $_ -eq 'hours') { if (IsObj $e) { [string](Get-V $e $_) } else { '' } } else { [string](Get-V $it $_) } }) }
  $spr = @(, @('id', 'name', 'start', 'end', 'goal')); if (IsArr (Get-V $b 'sprints')) { foreach ($s in $b['sprints']) { $spr += , @([string]$s['id'], [string](Get-V $s 'name'), [string]$s['start'], [string]$s['end'], [string](Get-V $s 'goal')) } }
  $his = @(, @('ticket', 'at', 'from', 'to', 'by', 'reason')); foreach ($it in $b['items']) { if ((IsObj $it) -and (IsArr (Get-V $it 'history'))) { foreach ($h in $it['history']) { $his += , @([string]$it['id'], [string]$h['at'], [string]$h['from'], [string]$h['to'], [string]$h['by'], [string]$(if (Get-V $h 'reason') { $h['reason'] } else { Get-V $h 'note' })) } } }
  @{ items = $items; sprints = $spr; history = $his }
}
function Sync-Sheets($Pj, [bool]$force) {
  $all = Read-Integ; $g = Get-Sec $all 'sheets'; if (-not $g -or -not $g.enabled) { return @{ project = $Pj.id; skipped = '未啟用' } }
  $sid = [string](Get-Sec $g.projects $Pj.id); if (-not $sid) { return @{ project = $Pj.id; skipped = '這個專案沒有設定試算表' } }
  if ($sid -notmatch '^[A-Za-z0-9_-]{10,100}$') { return @{ project = $Pj.id; error = '試算表 ID 格式錯誤' } }
  $api = $(if ($g.apiBase) { ([string]$g.apiBase).TrimEnd('/') } else { 'https://sheets.googleapis.com' })
  try {
    $tok = Get-GoogleToken $g; $H = @{ Authorization = "Bearer $tok" }
    $meta = Invoke-RestMethod -Uri "$api/v4/spreadsheets/$sid`?fields=sheets.properties.title" -Headers $H -TimeoutSec 20 -ErrorAction Stop
    $have = @($meta.sheets | ForEach-Object { [string]$_.properties.title }); $add = @('items', 'sprints', 'history' | Where-Object { $have -notcontains $_ })
    if ($add.Count) { $rq = @{ requests = @($add | ForEach-Object { @{ addSheet = @{ properties = @{ title = $_ } } } }) } | ConvertTo-Json -Depth 6 -Compress; Invoke-RestMethod -Method Post -Uri "$api/v4/spreadsheets/${sid}:batchUpdate" -Headers $H -Body ([Text.Encoding]::UTF8.GetBytes($rq)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 -ErrorAction Stop | Out-Null }
    $rows = Get-SheetRows (Read-BoardObj $Pj)
    $clr = @{ ranges = @('items', 'sprints', 'history') } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "$api/v4/spreadsheets/${sid}/values:batchClear" -Headers $H -Body $clr -ContentType 'application/json' -TimeoutSec 20 -ErrorAction Stop | Out-Null
    $up = @{ valueInputOption = 'RAW'; data = @(@{ range = 'items!A1'; values = $rows.items }, @{ range = 'sprints!A1'; values = $rows.sprints }, @{ range = 'history!A1'; values = $rows.history }) } | ConvertTo-Json -Depth 8 -Compress
    Invoke-RestMethod -Method Post -Uri "$api/v4/spreadsheets/${sid}/values:batchUpdate" -Headers $H -Body ([Text.Encoding]::UTF8.GetBytes($up)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 -ErrorAction Stop | Out-Null
    $Pj.sheetsAt = Get-NowIso; $Pj.sheetsErr = $null; return @{ project = $Pj.id; ok = $true; items = $rows.items.Count - 1 }
  } catch { $Pj.sheetsErr = $_.Exception.Message; Write-Warning "[$($Pj.id)] Google Sheets 同步失敗：$($_.Exception.Message)"; return @{ project = $Pj.id; error = $_.Exception.Message } }
}
function Update-SheetsTick {
  $g = Get-Sec (Read-Integ) 'sheets'; if (-not $g -or -not $g.enabled) { return }
  $iv = 300; if ([string]$g.intervalSec -match '^\d{1,6}$') { $iv = [Math]::Max(30, [int]$g.intervalSec) }
  foreach ($Pj in $projects.Values) { if (-not (Get-Sec $g.projects $Pj.id)) { continue }
    $due = (-not $Pj.sheetsNext) -or (Get-Date) -ge $Pj.sheetsNext
    if ($Pj.sheetsDirty -or $due) { $Pj.sheetsDirty = $false; $Pj.sheetsNext = (Get-Date).AddSeconds($iv); [void](Sync-Sheets $Pj $false) } }
}

# ---------- 派工器（push，預設關閉）----------
# 每個專案：interval、同時執行上限、profile（CLI 指令範本：exe + args 陣列，{prompt}／{ticket}／{project} 只會整個取代成單一參數，不經過 shell）
$DEFAULT_PROFILES = @(
  [ordered]@{ id = 'claude'; label = 'Claude Code'; exe = 'claude'; args = @('-p', '{prompt}'); role = 'dev-agent'; timeoutMin = 30 },
  [ordered]@{ id = 'codex'; label = 'Codex CLI'; exe = 'codex'; args = @('exec', '{prompt}'); role = 'dev-agent'; timeoutMin = 30 },
  [ordered]@{ id = 'cursor'; label = 'Cursor CLI'; exe = 'cursor-agent'; args = @('-p', '{prompt}'); role = 'dev-agent'; timeoutMin = 30 })
# Copilot、Windsurf 等只在編輯器裡執行的工具沒有 CLI：只能用「複製 AI 提示詞」＋ pull（claim）
function Get-DispatchFile([string]$pid_) { Join-Path $ConfigDir "dispatch-$pid_.json" }
function Get-DispatchCfg([string]$pid_) {
  $c = [ordered]@{ enabled = $false; intervalSec = 60; maxConcurrent = 1; notBefore = $null; profile = 'claude'; profiles = $DEFAULT_PROFILES; stoppedReason = '' }
  $f = Get-DispatchFile $pid_; if (Test-Path -LiteralPath $f) { try { $o = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $o.PSObject.Properties) { $c[$p.Name] = $p.Value } } catch {} }
  $c.maxConcurrent = 1   # 所有執行共用專案工作目錄（$Pj.dir），在每次執行有獨立 worktree 之前只能 1
  if ($c.notBefore -is [datetime]) { $c.notBefore = ([DateTimeOffset]$c.notBefore).ToString('yyyy-MM-dd\THH\:mm\:sszzz', [Globalization.CultureInfo]::InvariantCulture) }   # PowerShell 7 的 ConvertFrom-Json 會把日期字串轉成 DateTime
  $c
}
# notBefore：ISO 8601 且必須含時區（Z 或 ±hh:mm）；回傳 DateTimeOffset，格式不對回傳 $null
function ConvertTo-NotBefore($v) {
  if ($v -is [datetime]) { if ($v.Kind -eq [DateTimeKind]::Unspecified) { return $null }; return [DateTimeOffset]$v }   # 沒有時區的字串在 PowerShell 7 會變成 Unspecified
  $s = [string]$v; if ($s -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$') { return $null }
  $d = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }; $null
}
function Save-DispatchCfg([string]$pid_, $c) { Initialize-ConfigDir; ([pscustomobject]$c) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-DispatchFile $pid_) -Encoding UTF8 }
function Test-Profile($p) {
  if ([string]$p.id -notmatch '^[a-z0-9-]{1,30}$') { return 'profile id 格式錯誤' }
  if ([string]$p.exe -notmatch '^[A-Za-z0-9_.:\\/ -]{1,260}$' -or [string]$p.exe -match '[;&|<>`$]') { return "profile $($p.id)：exe 只能是程式名稱或路徑" }
  if (@($p.args).Count -gt 40) { return "profile $($p.id)：args 太多" }
  foreach ($a in @($p.args)) { if (-not ($a -is [string]) -or $a.Length -gt 2000) { return "profile $($p.id)：args 必須是字串陣列" } }
  if ([string]$p.role -notin 'dev-agent', 'verifier') { return "profile $($p.id)：派工器只能啟動 dev-agent 或 verifier" }
  $null
}
$runs = @{}   # runId -> @{ project; ticket; proc; out; err; start; timeoutMin; log; tokenId; status }
function Get-RunDir($Pj) { $d = $(if (Test-InAiPm $Pj.json) { Join-Path (Split-Path -Parent $Pj.json) 'runs' } else { Join-Path (Join-Path $ConfigDir 'runs') $Pj.id }); if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory $d -Force | Out-Null }; $d }
function Start-DispatchRun($Pj, $cfg, $prof, [string]$ticket) {
  $t = New-AgentToken $Pj.id ([string]$prof.role) ("dispatch-" + $prof.id) ([int]$prof.timeoutMin + 10) 'dispatcher' $true   # 派工器 token：不可核准
  $base = "http://localhost:$Port"
  $prompt = "你是 GuGuBoard 專案「$($Pj.name)」的$($ROLE_LABEL[[string]$prof.role])。用 GuGuBoard Agent API：$base/api/agent/v1，標頭 Authorization: Bearer 取環境變數 AIPM_AGENT_TOKEN。先 GET /bootstrap；工單 $ticket 已替你領取，每 5 分鐘 POST /heartbeat {""ticket"":""$ticket""}；用 PATCH /tickets/$ticket 更新；完成或卡住都 POST /report 並 release。不可把工單移到 Done 或設藍燈。"
  $a = @($prof.args | ForEach-Object { ([string]$_).Replace('{prompt}', $prompt).Replace('{ticket}', $ticket).Replace('{project}', $Pj.id) })
  $psi = [Diagnostics.ProcessStartInfo]::new([string]$prof.exe); $psi.WorkingDirectory = $Pj.dir; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $psi.EnvironmentVariables['AIPM_AGENT_TOKEN'] = $t.token; $psi.EnvironmentVariables['AIPM_API'] = "$base/api/agent/v1"; $psi.EnvironmentVariables['AIPM_TICKET'] = $ticket; $psi.EnvironmentVariables['AIPM_PROJECT'] = $Pj.id
  if ($psi.PSObject.Properties['ArgumentList']) { foreach ($x in $a) { $psi.ArgumentList.Add($x) } } else { $psi.Arguments = ($a | ForEach-Object { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }) -join ' ' }
  $rid = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + $ticket + '-' + $prof.id; $log = Join-Path (Get-RunDir $Pj) ($rid + '.log')
  try { $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close() } catch { [IO.File]::WriteAllText($log, "無法啟動 $($prof.exe)：$($_.Exception.Message)`n", [Text.UTF8Encoding]::new($false)); Remove-Claim $Pj.id $ticket; return $null }
  $runs[$rid] = @{ id = $rid; project = $Pj.id; ticket = $ticket; profile = [string]$prof.id; proc = $p; startTime = (Get-ProcStartIso $p); out = $p.StandardOutput.ReadToEndAsync(); err = $p.StandardError.ReadToEndAsync(); start = Get-Date; timeoutMin = [int]$prof.timeoutMin; log = $log; tokenId = $t.rec.id; status = 'running' }
  [IO.File]::WriteAllText($log, "# $rid`n# 指令：$($prof.exe) $(($a | ForEach-Object { if ($_.Length -gt 80) { $_.Substring(0, 80) + '…' } else { $_ } }) -join ' ')`n# 開始：$(Get-NowIso)`n", [Text.UTF8Encoding]::new($false))
  Save-RunRecords $Pj.id
  Write-Host "$(Get-Date -f HH:mm:ss) [$($Pj.id)] 派工：$ticket → $($prof.id)"; Push-All 'dispatch' @{ p = $Pj.id; run = $rid; status = 'running' } $Pj.id
  $rid
}
function Remove-Claim([string]$pid_, [string]$ticket) { $cl = Get-Claims $pid_; if ($cl.ContainsKey($ticket)) { $cl.Remove($ticket); Save-Claims $pid_ } }
function Revoke-RunToken([string]$tokenId) { $l = @(Read-AgentTokens); foreach ($t in $l) { if ($t.id -eq $tokenId) { $t.revoked = $true } }; Save-AgentTokens $l }   # 每次執行用完即撤銷

# ---- 執行紀錄持久化（T-DL-4）：伺服器重啟後才知道哪些 CLI 可能還在跑 ----
$DispState = @{ resumed = $false }
function Get-RunRecordFile([string]$pid_) { Join-Path $ConfigDir "runs-$pid_.json" }
function Get-ProcStartIso($p) { try { $p.StartTime.ToString('o') } catch { '' } }
function Save-RunRecords([string]$pid_) {   # 只存還沒結束（running／stuck）的執行
  Initialize-ConfigDir
  $l = @($runs.Values | Where-Object { $_.project -eq $pid_ -and $_.status -in 'running', 'stuck' } | ForEach-Object {
      [ordered]@{ id = $_.id; project = $_.project; ticket = $_.ticket; pid = $(try { $_.proc.Id } catch { 0 }); startTime = $(if ($_.startTime) { $_.startTime } else { Get-ProcStartIso $_.proc }); log = $_.log; tokenId = $_.tokenId; status = $_.status } })
  [IO.File]::WriteAllText((Get-RunRecordFile $pid_), (ConvertTo-Json -InputObject @($l) -Depth 4), [Text.UTF8Encoding]::new($false))
}
function Resume-DispatchRuns {   # 啟動後第一次 tick：收拾上一次伺服器留下的執行（不接管，終止後交給核對流程）
  foreach ($Pj in @($projects.Values)) {
    $f = Get-RunRecordFile $Pj.id; if (-not (Test-Path -LiteralPath $f)) { continue }
    $recs = @(); try { $recs = @(Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json | Where-Object { $_ }) } catch { Write-Warning "[$($Pj.id)] 無法讀取執行紀錄 $f"; continue }
    foreach ($rec in $recs) {
      try {   # 每筆各自保護：一筆壞掉不影響其他專案與其他紀錄
        if ($runs.ContainsKey([string]$rec.id)) { continue }
        $p = $null; try { $p = [Diagnostics.Process]::GetProcessById([int]$rec.pid) } catch {}
        $stillRunning = $false
        if ($p) {
          $st = [string]$rec.startTime; if ($rec.startTime -is [datetime]) { $st = $rec.startTime.ToString('o') }
          if ($st -and (Get-ProcStartIso $p) -eq $st) { $stillRunning = $true }   # 同一個程序：PID 與建立時間都相符
        }
        if ($stillRunning -and -not (Stop-RunTree $p)) {   # 仍在執行又殺不掉：標 stuck，放回 $runs 佔住名額、保留 claim 與紀錄，不撤 token／不釋放／不暫停工單
          $runs[[string]$rec.id] = @{ id = [string]$rec.id; project = $Pj.id; ticket = [string]$rec.ticket; profile = 'resumed'; proc = $p; start = (Get-Date); timeoutMin = 0; log = [string]$rec.log; tokenId = [string]$rec.tokenId; status = 'stuck' }
          $cl = Get-Claims $Pj.id; if ($cl.ContainsKey([string]$rec.ticket)) { $cl[[string]$rec.ticket].until = (Get-Date).AddYears(10); Save-Claims $Pj.id }
          try { [IO.File]::AppendAllText([string]$rec.log, "`n# $(Get-NowIso)　重啟時程序仍在執行且無法終止，標為 stuck，需要人處理`n", [Text.UTF8Encoding]::new($false)) } catch {}
          Push-All 'dispatch' @{ p = $Pj.id; run = [string]$rec.id; status = 'stuck' } $Pj.id
          continue
        }
        $note = if (-not $p) { '伺服器重啟時程序已不存在' } elseif ($stillRunning) { '伺服器重啟時程序仍在執行，已終止整個程序樹' } else { "PID $($rec.pid) 已被其他程序使用，未終止" }
        try { [IO.File]::AppendAllText([string]$rec.log, "`n# 結束：$(Get-NowIso)　狀態：interrupted　$note`n", [Text.UTF8Encoding]::new($false)) } catch {}
        if ($rec.tokenId) { Revoke-RunToken ([string]$rec.tokenId) }
        try { Set-TicketAfterRun $Pj ([string]$rec.ticket) 'interrupted' '?' ([string]$rec.log) } catch { Write-Warning "[$($Pj.id)] 重啟核對工單 $($rec.ticket) 失敗：$($_.Exception.Message)"; Disable-DispatchForSafety $Pj "重啟核對工單 $($rec.ticket) 失敗，派工器已停止（需要人處理）" }
        Remove-Claim $Pj.id ([string]$rec.ticket)
        Write-Host "$(Get-Date -f HH:mm:ss) [$($Pj.id)] 派工：$($rec.ticket) 上次執行中斷（$note）"
      } catch { Write-Warning "[$($Pj.id)] 處理執行紀錄 $($rec.id) 失敗：$($_.Exception.Message)" }
    }
    Save-RunRecords $Pj.id   # stuck 的執行（status=stuck）會留在檔案；已處理完的不在 $runs，會被移除
  }
}

# ---- 終止整個程序樹（T-DL-2）：AI CLI 會再啟動 node、git 等子程序，只 Kill 父程序會留下它們 ----
function Get-ProcTreeIds([int]$rootId) {
  $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate -ErrorAction SilentlyContinue)
  $by = @{}; foreach ($x in $all) { $by[[int]$x.ProcessId] = $x }
  $ids = [Collections.Generic.List[int]]::new(); $ids.Add($rootId); $i = 0
  while ($i -lt $ids.Count) {
    $pp = $ids[$i]; $pc = $by[$pp]
    foreach ($x in $all) {   # 子程序必須比父程序晚建立，避免 PID 重用時誤認
      $cid = [int]$x.ProcessId
      if ([int]$x.ParentProcessId -eq $pp -and $cid -ne $pp -and -not $ids.Contains($cid) -and (-not $pc -or -not $pc.CreationDate -or $x.CreationDate -ge $pc.CreationDate)) { $ids.Add($cid) }
    }
    $i++
  }
  $ids.ToArray()
}
function Stop-RunTree($proc, [int]$waitMs = 10000) {   # 回傳 $true＝確定整棵樹都已結束；無法確定回 $false（交給 stuck 流程）
  $ids = @($proc.Id); $enumerated = $false
  if ($null -eq $IsWindows -or $IsWindows) { try { $ids = @(Get-ProcTreeIds $proc.Id); $enumerated = $true } catch { $enumerated = $false } }   # 列舉子樹靠 Get-CimInstance，只在 Windows 可用
  $killedTree = $false
  try { $proc.Kill($true); $killedTree = $true }   # PowerShell 7（.NET Core）：跨平台一次殺整棵樹
  catch { try { $proc.Kill() } catch {} }           # Windows PowerShell 5.1 沒有這個多載：只殺父程序，靠下面用列舉結果補殺子程序
  foreach ($id in $ids) { if ($id -ne $proc.Id) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch {} } }
  $deadline = (Get-Date).AddMilliseconds($waitMs)
  do {
    $alive = @($ids | Where-Object { if ($_ -eq $proc.Id) { try { -not $proc.HasExited } catch { $false } } else { [bool](Get-Process -Id $_ -ErrorAction SilentlyContinue) } })
    if (-not $alive.Count) {
      if (-not $enumerated -and -not $killedTree) { return $false }   # 既不能列舉子樹、也不能整棵樹殺：不敢保證沒有殘留的子程序
      return $true
    }
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)
  $false
}
function Stop-Run($r, [string]$status) {   # 逾時／手動停止；無法確認結束就標 stuck，保留 claim 讓同一張不被重派
  if (Stop-RunTree $r.proc) { Complete-Run $r $status; return }
  $r.status = 'stuck'; Revoke-RunToken $r.tokenId
  $cl = Get-Claims $r.project; if ($cl.ContainsKey($r.ticket)) { $cl[$r.ticket].until = (Get-Date).AddYears(10); Save-Claims $r.project }
  [IO.File]::AppendAllText($r.log, "`n# $(Get-NowIso)　無法確認程序樹已結束（$status），標為 stuck，需要人處理`n", [Text.UTF8Encoding]::new($false))
  $Pj = $projects[$r.project]; if ($Pj) { try { Set-TicketAfterRun $Pj $r.ticket 'stuck' '?' $r.log } catch { Write-Warning "[$($r.project)] stuck 核對工單失敗：$($_.Exception.Message)"; Disable-DispatchForSafety $Pj "工單 $($r.ticket) stuck 且核對丟出例外，派工器已停止（需要人處理）" } }
  Save-RunRecords $r.project
  Push-All 'dispatch' @{ p = $r.project; run = $r.id; status = 'stuck' } $r.project
}

# 工單暫停不了（驗證失敗或寫入丟例外）就停掉整個專案的派工器，寧可停也不要無限重派
function Disable-DispatchForSafety($Pj, [string]$reason) {
  $c = Get-DispatchCfg $Pj.id; if (-not $c.enabled) { return }
  $c.enabled = $false; $c.stoppedReason = $reason; Save-DispatchCfg $Pj.id $c; Push-All 'dispatch' @{ p = $Pj.id; stopped = $reason } $Pj.id
}
# ---- 執行結束後核對工單（T-DL-3）：工單還沒完成就暫停，避免下一次 tick 重派同一張而無限耗用 token ----
function Set-TicketAfterRun($Pj, [string]$ticket, [string]$runStatus, $code, [string]$log) {
  $b = Read-BoardObj $Pj; $it = Find-Item $b $ticket; if (-not $it) { return }
  $st = [string]$it['status']; if ($st -cnotin 'Todo', 'In Progress') { return }   # In Review／Done 等：AI 已交付或有人處理，不動
  $lt = [string]$it['light']
  $why = "派工執行結束但工單未完成（狀態 $st，exit=$code，$runStatus）"; $now = Get-NowIso; $from = "$st / $lt"
  if ([string](Get-V $it 'updatedAt') -ceq $now) { Start-Sleep -Milliseconds (1005 - (Get-Date).Millisecond); $now = Get-NowIso }   # updatedAt 只到秒；同一秒內再改會被 L7 判成沒更新
  if ($st -ceq 'In Progress' -and $lt -ceq 'Green') { $it['light'] = 'Yellow'; $it['lightReason'] = $why }   # 只降綠燈；AI 自己設的紅／黃燈與原因保留（紅燈代表阻塞，由 tick 的紅燈停機機制處理）
  $it['paused'] = $true; if (-not [string](Get-V $it 'pausedReason')) { $it['pausedReason'] = $why }   # 不覆寫 AI 已寫的原因
  $it['updatedAt'] = $now
  # 直接讀 $it['history']／$it['notes']，不走 Get-V：Get-V 的逗號防護在 pipeline 中會讓整個舊陣列變成單一元素，造成巢狀而驗證失敗
  $oh = @(); if ($it.Contains('history') -and $null -ne $it['history']) { $oh = @($it['history']) }
  $it['history'] = @($oh + [ordered]@{ at = $now; from = $from; to = "$st / $($it['light'])"; by = 'dispatcher'; note = $why })
  $on = @(); if ($it.Contains('notes') -and $null -ne $it['notes']) { $on = @($it['notes']) }
  $it['notes'] = @($on + [ordered]@{ at = $now; by = 'dispatcher'; text = "$why；log：$(Split-Path -Leaf $log)" })
  $errs = @(Write-BoardChecked $Pj $b 'dev-agent' 'dispatch-outcome')
  if ($errs.Count) { Write-Warning "[$($Pj.id)] 無法暫停工單 ${ticket}：$($errs -join '；')"; Disable-DispatchForSafety $Pj "工單 $ticket 執行結束但無法自動暫停（$($errs[0])），派工器已停止（需要人處理）" }
}
function Complete-Run($r, [string]$status) {
  $r.status = $status; $o = ''; $e = ''; try { if ($r.out.Wait(2000)) { $o = $r.out.Result } } catch {}; try { if ($r.err.Wait(2000)) { $e = $r.err.Result } } catch {}
  $code = $(try { $r.proc.ExitCode } catch { -1 })
  [IO.File]::AppendAllText($r.log, "`n## stdout`n$o`n## stderr`n$e`n# 結束：$(Get-NowIso)　狀態：$status　exit=$code`n", [Text.UTF8Encoding]::new($false))
  Revoke-RunToken $r.tokenId
  $Pj = $projects[$r.project]; if ($Pj) { try { Set-TicketAfterRun $Pj $r.ticket $status $code $r.log } catch { Write-Warning "[$($r.project)] 核對工單 $($r.ticket) 失敗：$($_.Exception.Message)"; Disable-DispatchForSafety $Pj "工單 $($r.ticket) 執行結束但核對丟出例外（$($_.Exception.Message)），派工器已停止（需要人處理）" } }
  Remove-Claim $r.project $r.ticket; $r.exit = $code; $r.end = Get-Date
  Save-RunRecords $r.project
  Push-All 'dispatch' @{ p = $r.project; run = $r.id; status = $status } $r.project
}
function Stop-DispatchOnRed($Pj, [string]$id) {
  $c = Get-DispatchCfg $Pj.id; if (-not $c.enabled) { return }
  $c.enabled = $false; $c.stoppedReason = "工單 $id 變成紅燈，派工器已停止（需要人處理）"; Save-DispatchCfg $Pj.id $c
  [void](Send-Notify $Pj 'dispatch-stop' $c.stoppedReason '派工器已停止' $null); Push-All 'dispatch' @{ p = $Pj.id; stopped = $c.stoppedReason } $Pj.id
}
function Update-DispatchTick {
  if (-not $DispState.resumed) { $DispState.resumed = $true; try { Resume-DispatchRuns } catch { Write-Warning "派工器：重啟對帳失敗：$($_.Exception.Message)" } }
  foreach ($r in @($runs.Values | Where-Object { $_.status -eq 'running' })) {
    if ($r.proc.HasExited) { Complete-Run $r $(if ($r.proc.ExitCode -eq 0) { 'done' } else { 'failed' }) }
    elseif (((Get-Date) - $r.start).TotalMinutes -ge $r.timeoutMin) { Stop-Run $r 'timeout' }
  }
  foreach ($Pj in $projects.Values) {
    $c = Get-DispatchCfg $Pj.id; if (-not $c.enabled) { continue }
    if ($c.notBefore) { $nb = ConvertTo-NotBefore $c.notBefore; if (-not $nb -or [DateTimeOffset]::Now -lt $nb) { continue } }   # 開始時間未到（或格式壞掉）就不派；到期時間相等算到期
    if ($Pj.dispNext -and (Get-Date) -lt $Pj.dispNext) { continue }; $Pj.dispNext = (Get-Date).AddSeconds([Math]::Max(5, [int]$c.intervalSec))
    $running = @($runs.Values | Where-Object { $_.project -eq $Pj.id -and $_.status -in 'running', 'stuck' }).Count   # stuck 的程序可能還在改檔，也算在上限內
    if ($running -ge 1) { continue }
    $prof = @($c.profiles) | Where-Object { $_.id -eq $c.profile } | Select-Object -First 1; if (-not $prof -or (Test-Profile $prof)) { continue }
    $b = Read-BoardObj $Pj
    if (@($b['items'] | Where-Object { (IsObj $_) -and $_['light'] -ceq 'Red' -and $_['status'] -cin 'In Progress', 'In Review' }).Count -and $c.stopOnRed -ne $false) { Stop-DispatchOnRed $Pj (@($b['items'] | Where-Object { (IsObj $_) -and $_['light'] -ceq 'Red' })[0]['id']); continue }
    $ag = @{ role = [string]$prof.role; name = 'dispatch-' + $prof.id; id = 'dispatcher' }; $cl = Get-Claims $Pj.id; $cand = $null
    foreach ($it in $b['items']) { if ((IsObj $it) -and -not $cl.ContainsKey([string]$it['id']) -and (Test-ClaimCandidate $it $b $ag)) { $cand = $it; break } }
    if (-not $cand) { continue }
    $tid = [string]$cand['id']; $cl[$tid] = @{ token = 'pending'; name = $ag.name; until = (Get-Date).AddMinutes([int]$prof.timeoutMin + 5); at = (Get-NowIso) }; Save-Claims $Pj.id
    $rid = Start-DispatchRun $Pj $c $prof $tid; if ($rid) { $cl[$tid].token = $runs[$rid].tokenId; Save-Claims $Pj.id }
  }
}
function Invoke-DispatchApi($req, $res, $s, $Pj, [string]$sub) {
  if ($s.role -ne 'admin') { return Send-Err $res 403 'E_FORBIDDEN' }
  if ($req.HttpMethod -eq 'GET' -and $sub -eq '/dispatch') { $l = @($runs.Values | Where-Object { $_.project -eq $Pj.id } | Sort-Object { $_.start } -Descending | Select-Object -First 50 | ForEach-Object { [ordered]@{ id = $_.id; ticket = $_.ticket; profile = $_.profile; status = $_.status; start = $_.start.ToString('o'); exit = $_.exit } })
    $files = @(Get-ChildItem -LiteralPath (Get-RunDir $Pj) -Filter '*.log' -File | Sort-Object Name -Descending | Select-Object -First 50 | ForEach-Object { $_.Name })
    return Send-Json $res @{ config = (Get-DispatchCfg $Pj.id); runs = $l; logs = $files } }
  if ($req.HttpMethod -eq 'GET' -and $sub -match '^/dispatch/log/([A-Za-z0-9._-]{1,120}\.log)$') { $f = Join-Path (Get-RunDir $Pj) $Matches[1]; if (-not (Test-Path -LiteralPath $f)) { return Send-Err $res 404 'E_NOT_FOUND' }; $t = [IO.File]::ReadAllText($f); if ($t.Length -gt 200000) { $t = $t.Substring($t.Length - 200000) }; return Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes($t)) 'text/plain; charset=utf-8' }
  if ($req.HttpMethod -ne 'POST') { return Send-Err $res 405 'E_METHOD' }
  if (-not $req.IsLocal -or (Test-External $req)) { return Send-Err $res 403 'E_NOT_LOCAL' }
  $in = Read-BodyMax $req 65536; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  if ($sub -eq '/dispatch/kill') { $r = $runs[[string]$in.run]; if (-not $r -or $r.project -ne $Pj.id) { return Send-Err $res 404 'E_NOT_FOUND' }; if ($r.status -in 'running', 'stuck') { Stop-Run $r 'killed' }; return Send-Json $res @{ ok = $true; status = $r.status } }
  if ($sub -eq '/dispatch/config') {
    $c = Get-DispatchCfg $Pj.id
    if ($in.PSObject.Properties['notBefore']) {   # 先驗證，錯了整筆不存
      if ($null -eq $in.notBefore -or [string]$in.notBefore -eq '') { $c.notBefore = $null }
      elseif (-not (ConvertTo-NotBefore $in.notBefore)) { return Send-Json $res @{ error = 'E_BAD_TIME'; message = '開始時間必須是含時區的 ISO 8601，例如 2026-11-08T09:00:00+08:00' } 400 }
      elseif ($in.notBefore -is [datetime]) { $c.notBefore = ([DateTimeOffset]$in.notBefore).ToString('yyyy-MM-dd\THH\:mm\:sszzz', [Globalization.CultureInfo]::InvariantCulture) }
      else { $c.notBefore = [string]$in.notBefore }
    }
    foreach ($k in 'enabled', 'stopOnRed') { if ($in.PSObject.Properties[$k]) { $c[$k] = ($in.$k -eq $true) } }
    if ([string]$in.intervalSec -match '^\d{1,5}$') { $c.intervalSec = [Math]::Max(5, [int]$in.intervalSec) }
    $c.maxConcurrent = 1   # 共用工作目錄，暫時固定 1（傳入的值忽略）
    if ($in.profiles) { $pl = @(); foreach ($p in @($in.profiles)) { $e = Test-Profile $p; if ($e) { return Send-Json $res @{ error = 'E_PROFILE'; message = $e } 400 }; $tm = 30; if ([string]$p.timeoutMin -match '^\d{1,4}$') { $tm = [Math]::Min(600, [Math]::Max(1, [int]$p.timeoutMin)) }
      $pl += [ordered]@{ id = [string]$p.id; label = [string]$p.label; exe = [string]$p.exe; args = @($p.args | ForEach-Object { [string]$_ }); role = [string]$p.role; timeoutMin = $tm } }; $c.profiles = $pl }
    if ($in.profile) { if (-not (@($c.profiles) | Where-Object { $_.id -eq [string]$in.profile })) { return Send-Json $res @{ error = 'E_PROFILE'; message = '找不到 profile' } 400 }; $c.profile = [string]$in.profile }
    if ($c.enabled) { $c.stoppedReason = '' }
    Save-DispatchCfg $Pj.id $c; Write-AcctAudit $s 'dispatchConfig' @{ project = $Pj.id; enabled = $c.enabled; profile = $c.profile }; $Pj.dispNext = $null
    return Send-Json $res @{ ok = $true; config = $c }
  }
  Send-Err $res 404 'E_NOT_FOUND'
}

# ---------- 外部監看（預設關閉）：經由 Cloudflare Tunnel／Tailscale Funnel 的 HTTPS，Google 登入，只能看不能改 ----------
function Test-External($req) { [bool]($req.Headers['X-Forwarded-For'] -or $req.Headers['CF-Connecting-IP'] -or $req.Headers['Tailscale-User-Login'] -or $req.Headers['X-Forwarded-Host']) }
$extRate = @{}
function Test-ExtRate($req) {
  $ip = [string]$(if ($req.Headers['CF-Connecting-IP']) { $req.Headers['CF-Connecting-IP'] } else { ([string]$req.Headers['X-Forwarded-For'] -split ',')[0].Trim() }); if (-not $ip) { $ip = 'x' }
  $now = Get-Date; $r = $extRate[$ip]; if (-not $r -or ($now - $r.t0).TotalSeconds -ge 60) { $r = @{ t0 = $now; n = 0 }; $extRate[$ip] = $r }; $r.n++
  if ($extRate.Count -gt 5000) { $extRate.Clear() }
  $lim = 120; $x = Get-Sec (Read-Integ) 'external'; if ($x -and [string]$x.ratePerMin -match '^\d{1,5}$') { $lim = [int]$x.ratePerMin }
  $r.n -le $lim
}
# 外部請求的關卡：沒啟用一律 403；只允許 GET（看板、圖表、歷史、Git 唯讀）與 Google 登入／登出
function Test-ExternalGate($req, $res, [string]$path) {
  $x = Get-Sec (Read-Integ) 'external'
  if (-not ($x -and $x.enabled)) { Send-Err $res 403 'E_EXTERNAL_DISABLED'; return $false }
  if (-not (Test-ExtRate $req)) { $res.Headers['Retry-After'] = '60'; Send-Err $res 429 'E_RATE_LIMIT'; return $false }
  if ($path -in '/', '/board.html', '/api/status', '/api/me', '/events', '/api/google/start', '/api/google/callback') { return $true }
  if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/logout') { return $true }
  if ($req.HttpMethod -ne 'GET') { Send-Err $res 403 'E_READ_ONLY'; return $false }
  if ($path -match '^/api/(admin|projects|setup|agent)' -or $path -match '/(git/op|clear-examples|restore|migrate-aipm|agent-tokens|dispatch|agent/prompt)') { Send-Err $res 403 'E_READ_ONLY'; return $false }
  $true
}
$gFlows = @{}
function Invoke-GoogleStart($req, $res) {
  $x = Get-Sec (Read-Integ) 'external'; if (-not ($x -and $x.enabled -and $x.googleClientId -and $x.publicUrl)) { return Send-Err $res 409 'E_EXTERNAL_DISABLED' }
  $st = New-Token; $gFlows[$st] = Get-Date; foreach ($k in @($gFlows.Keys)) { if (((Get-Date) - $gFlows[$k]).TotalMinutes -gt 10) { $gFlows.Remove($k) } }
  $auth = $(if ($x.authUrl) { [string]$x.authUrl } else { 'https://accounts.google.com/o/oauth2/v2/auth' })
  $redir = ([string]$x.publicUrl).TrimEnd('/') + '/api/google/callback'
  $u = $auth + '?response_type=code&scope=openid%20email%20profile&client_id=' + [uri]::EscapeDataString([string]$x.googleClientId) + '&redirect_uri=' + [uri]::EscapeDataString($redir) + '&state=' + $st + '&prompt=select_account'
  $res.StatusCode = 302; $res.Headers['Location'] = $u; $res.Close()
}
function Invoke-GoogleCallback($req, $res) {
  $x = Get-Sec (Read-Integ) 'external'; if (-not ($x -and $x.enabled)) { return Send-Err $res 403 'E_EXTERNAL_DISABLED' }
  $st = [string]$req.QueryString['state']; $code = [string]$req.QueryString['code']
  if (-not $st -or -not $gFlows.ContainsKey($st) -or -not $code -or $code.Length -gt 2000) { return Send-Err $res 400 'E_BAD_STATE' }; $gFlows.Remove($st)
  $tokUrl = $(if ($x.tokenUrl) { [string]$x.tokenUrl } else { 'https://oauth2.googleapis.com/token' }); $redir = ([string]$x.publicUrl).TrimEnd('/') + '/api/google/callback'
  try { $t = Invoke-RestMethod -Method Post -Uri $tokUrl -Body @{ code = $code; client_id = [string]$x.googleClientId; client_secret = [string]$x.googleClientSecret; redirect_uri = $redir; grant_type = 'authorization_code' } -TimeoutSec 15 -ErrorAction Stop } catch { return Send-Err $res 502 'E_GOOGLE' }
  $info = $(if ($x.tokenInfoUrl) { [string]$x.tokenInfoUrl } else { 'https://oauth2.googleapis.com/tokeninfo' })
  try { $ti = Invoke-RestMethod -Uri ($info + '?id_token=' + [uri]::EscapeDataString([string]$t.id_token)) -TimeoutSec 15 -ErrorAction Stop } catch { return Send-Err $res 502 'E_GOOGLE' }
  if ([string]$ti.aud -ne [string]$x.googleClientId -or [string]$ti.email_verified -ne 'true' -or [string]$ti.iss -notmatch '^(https://)?accounts\.google\.com$') { return Send-Err $res 403 'E_GOOGLE_TOKEN' }
  $em = ([string]$ti.email).ToLower(); $dom = ($em -split '@')[-1]
  $ok = (@($x.allowedEmails) | Where-Object { ([string]$_).ToLower() -eq $em }) -or (@($x.allowedDomains) | Where-Object { ([string]$_).ToLower() -eq $dom })
  if (-not $ok) { Write-Host "$(Get-Date -f HH:mm:ss) 外部 Google 登入被拒：$em"; return Send-Err $res 403 'E_NOT_ALLOWED' }
  $u = Read-Users | Where-Object { ([string]$_.email).ToLower() -eq $em -and [string]$_.status -ne 'disabled' } | Select-Object -First 1
  if (-not $u) { $mp = @($x.emailMap) | Where-Object { ([string]$_.email).ToLower() -eq $em -or ([string]$_.domain).ToLower() -eq $dom } | Select-Object -First 1; if ($mp) { $u = Read-Users | Where-Object { $_.name -eq [string]$mp.user -and [string]$_.status -ne 'disabled' } | Select-Object -First 1 } }
  if (-not $u) { return Send-Err $res 403 'E_NOT_MAPPED' }
  $tk = New-Token; $sx = @{ user = $u.name; role = 'viewer'; allowed = @{}; last = Get-Date; ghToken = $null; ghLogin = $null; ghName = $null; ghId = $null; external = $true; email = $em }
  foreach ($k in (Get-Allowed $u).Keys) { $sx.allowed[$k] = 'viewer' }   # 外部登入一律唯讀（viewer）
  $sessions[(Get-Key $tk)] = $sx; Write-Host "$(Get-Date -f HH:mm:ss) 外部監看登入：$em → $($u.name)（唯讀）"
  $res.Headers.Add('Set-Cookie', "aib_sid=$tk; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=$($IDLE_MIN*60)"); $res.StatusCode = 302; $res.Headers['Location'] = '/'; $res.Close()
}

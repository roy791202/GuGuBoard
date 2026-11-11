<#
 CI Guard（第 3 層強制）：GitHub Actions 在 pull_request 時執行。PowerShell 7（ubuntu-latest 內建 pwsh）。
 檢查：board.json 規則、PR 對應的 Task 卡片（In Review + TDD Green + 涵蓋情境 Green）、.feature 修改需 spec-change 標籤、
       不可新增略過的測試、版本與 CHANGELOG（有佈署或版本變更時）。測試本身在 workflow 的 tests job 跑。
 環境變數：BOARD_PATH（預設 .ai-pm/board.json；舊專案沒有時用 docs/board.json）、BASE_SHA、PR_TITLE、HEAD_REF、PR_LABELS（逗號分隔）
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'validate-board.ps1') -Library
$errs = [Collections.Generic.List[string]]::new(); $warns = [Collections.Generic.List[string]]::new()
$board = if ($env:BOARD_PATH) { $env:BOARD_PATH } elseif (Test-Path -LiteralPath '.ai-pm/board.json') { '.ai-pm/board.json' } else { 'docs/board.json' }
$base = $env:BASE_SHA; $title = "$env:PR_TITLE"; $ref = "$env:HEAD_REF"
$labels = @("$env:PR_LABELS" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
function G([string[]]$a) { $o = & git @a 2>$null; if ($LASTEXITCODE -ne 0) { return $null }; return ($o -join "`n") }
function Note($m) { Write-Host "::error::$m"; $errs.Add($m) }

# 1) board.json
$d = $null
if ($base) { foreach ($l in ((G @('diff', '--name-status', '-M', "$base", 'HEAD')) -split "`n" | Where-Object { $_ })) { $c = $l -split "`t"; if (($c[0] -eq 'D' -or $c[0] -like 'R*') -and $c[1] -match '(^|/)\.ai-pm/board\.json$') { Note "PR 刪除或搬走了 $($c[1])（看板資料），不允許" } } }
if (-not (Test-Path -LiteralPath $board)) { Note "找不到 $board（可用 BOARD_PATH 指定）" }
else {
  try { $d = Read-BoardJson ([IO.File]::ReadAllText($board)) } catch { Note "$board 無法解析：$($_.Exception.Message)" }
  if ($d) { foreach ($x in @(Test-Board $d)) { Note "${board}：$x" }
    if ($base) { $ot = G @('show', "${base}:$board"); if ($ot) { try { $ob = Read-BoardJson $ot; foreach ($x in @(Test-BoardBookkeeping $ob $d) + @(Test-BoardIntegrity $ob $d)) { Note "${board}：$x" } } catch {} } } }
}
# 2) PR 對應的 Task 卡片
$isRelease = $ref -match '^(release|hotfix)/'
if ($d -and -not $isRelease) {
  $tasks = @($d['items'] | Where-Object { (IsObj $_) -and $_['level'] -ceq 'Task' })
  $card = $tasks | Where-Object { $ref -like "feature/$($_['id'])-*" } | Select-Object -First 1
  if (-not $card) { $card = $tasks | Where-Object { $title -match ('(^|[\s\[(])' + [regex]::Escape($_['id']) + '([\s\]):]|$)') } | Select-Object -First 1 }
  if (-not $card) { Note "PR 沒有對應的 Task 卡片：分支要叫 feature/<task-id>-<slug>，或 PR 標題要包含 Task ID（目前分支 $ref）" }
  else {
    $id = $card['id']
    if ($card['status'] -cne 'In Review') { Note "$id 的狀態是 $($card['status'])，PR 送審時必須是 In Review" }
    if ($card['tdd'] -cne 'Green') { Note "$id 的 TDD 不是 Green" }
    $sc = @{}; foreach ($it in $d['items']) { if ((IsObj $it) -and (IsArr $it['bdd'])) { foreach ($s in $it['bdd']) { $sc[[string]$s['id']] = $s['status'] } } }
    foreach ($s in @($card['scenarioIds'])) { if ($s -and $sc[[string]$s] -cne 'Green') { Note "$id 涵蓋的 BDD 情境 $s 不是 Green" } }
    if (-not @($card['scenarioIds']).Count) { $warns.Add("$id 沒有列出 scenarioIds") }
    Write-Host "對應卡片：$id $($card['title'])"
  }
}
# 3) 變更檔案
$changed = @(); if ($base) { $changed = @((G @('diff', '--name-only', "$base...HEAD")) -split "`n" | Where-Object { $_ }) }
$feat = @($changed | Where-Object { $_ -match '\.feature$' })
if ($feat.Count -and 'spec-change' -notin $labels) { Note ("修改了 BDD 情境（" + ($feat -join ', ') + "），需要核准者加上 spec-change 標籤，並經 CODEOWNERS 審查") }
$prot = @($changed | Where-Object { $_ -match '^(\.ai-hooks/|\.githooks/|\.github/workflows/|\.cursor/hooks\.json$|\.claude/settings)' })
if ($prot.Count -and 'guard-change' -notin $labels) { Note ("修改了強制機制檔案（" + ($prot -join ', ') + "），需要 guard-change 標籤與 CODEOWNERS 審查") }
# 4) 不可新增略過的測試
if ($base) {
  $cur = ''
  foreach ($l in ((G @('diff', '-U0', '--no-color', "$base...HEAD")) -split "`n")) {
    if ($l -match '^\+\+\+ b/(.+)$') { $cur = $Matches[1]; continue }
    if ($cur -match '\.(md|mdc|txt|html?|rst|adoc)$') { continue }   # 文件裡的範例文字不算測試
    if ($l -match '^\+' -and $l -notmatch '^\+\+\+' -and $l.Substring(1) -match '#\[ignore\]|\b(it|test|describe)\.(skip|only)\s*\(|\b(xit|xdescribe|fit|fdescribe)\s*\(') { Note "${cur}：新增了被略過或只跑部分的測試：$($l.Substring(1).Trim())" }
  }
}
# 5) 版本與 CHANGELOG
$verFiles = @($changed | Where-Object { $_ -match '(^|/)(Cargo\.toml|package\.json|tauri\.conf\.json)$' })
$deployChanged = $false
if ($d -and $base) { $ot = G @('show', "${base}:$board"); $oldIds = @{}
  if ($ot) { try { $od = Read-BoardJson $ot; foreach ($it in $od['items']) { if ((IsObj $it) -and $it['level'] -ceq 'Deployment') { $oldIds[[string]$it['id']] = ($it | ConvertTo-Json -Depth 8 -Compress) } } } catch {} }
  foreach ($it in $d['items']) { if ((IsObj $it) -and $it['level'] -ceq 'Deployment' -and $oldIds[[string]$it['id']] -ne ($it | ConvertTo-Json -Depth 8 -Compress)) { $deployChanged = $true } } }
function Get-Versions([string]$rev) {
  $v = [ordered]@{}
  foreach ($c in 'src-tauri/Cargo.toml', 'Cargo.toml') { $t = if ($rev) { G @('show', "${rev}:$c") } elseif (Test-Path $c) { Get-Content $c -Raw } else { $null }; if ($t -and $t -match '(?ms)^\[package\][^\[]*?^version\s*=\s*"([^"]+)"') { $v[$c] = $Matches[1]; break } }
  $t = if ($rev) { G @('show', "${rev}:package.json") } elseif (Test-Path 'package.json') { Get-Content 'package.json' -Raw } else { $null }; if ($t -and $t -match '"version"\s*:\s*"([^"]+)"') { $v['package.json'] = $Matches[1] }
  foreach ($c in 'src-tauri/tauri.conf.json', 'tauri.conf.json') { $t = if ($rev) { G @('show', "${rev}:$c") } elseif (Test-Path $c) { Get-Content $c -Raw } else { $null }; if ($t -and $t -match '"version"\s*:\s*"([^"]+)"') { $v[$c] = $Matches[1]; break } }
  $v
}
$now = Get-Versions ''
if (@($now.Values | Select-Object -Unique).Count -gt 1) { Note ('版本號不一致：' + (($now.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '、')) }
if ($isRelease -or $deployChanged) {
  if (-not ($changed | Where-Object { $_ -match '(^|/)CHANGELOG\.md$' })) { Note '這是發版／佈署相關的 PR，必須更新 CHANGELOG.md' }
  if ($base -and $now.Count) { $was = Get-Versions $base; $a = @($was.Values)[0]; $b = @($now.Values)[0]
    if ($a -and $b -and $a -eq $b) { Note "發版 PR 必須升版號（目前仍是 $b）" } }
}
foreach ($w in $warns) { Write-Host "::warning::$w" }
if ($errs.Count) { Write-Host "AI Dev Guard 未通過：$($errs.Count) 項"; exit 1 }
Write-Host 'AI Dev Guard 通過'; exit 0

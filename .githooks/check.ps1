<#
 Git hooks（第 3 層強制）：pre-commit / commit-msg 共用。PowerShell 5.1 / 7 皆可。
 由 .githooks/pre-commit、.githooks/commit-msg 呼叫；安裝：scripts/install-git-hooks.ps1
 錯誤＝擋下 commit；警告＝只提示。不要用 --no-verify 跳過（AI Hooks 也會擋）。
#>
param([ValidateSet('pre-commit','commit-msg')][string]$Mode = 'pre-commit', [string]$MsgFile = '')
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
. (Join-Path $PSScriptRoot 'validate-board.ps1') -Library
$errs = [Collections.Generic.List[string]]::new(); $warns = [Collections.Generic.List[string]]::new()
function G([string[]]$a) { $o = & git @a 2>$null; if ($LASTEXITCODE -ne 0) { return $null }; return ($o -join "`n") }

if ($Mode -eq 'commit-msg') {
  $msg = (Get-Content -LiteralPath $MsgFile -Encoding UTF8 | Where-Object { $_ -notmatch '^#' } | Select-Object -First 1)
  $cc = '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([A-Za-z0-9._/-]+\))?!?: \S.{0,99}$'
  if ($msg -notmatch $cc -and $msg -notmatch '^(Merge |Revert "|board: |fixup! |squash! )') {
    $errs.Add("commit 訊息不符合 Conventional Commits：「$msg」。格式：feat(scope): 說明 / fix: 說明 / feat!: 不相容變更")
  }
} else {
  $files = @((G @('diff', '--cached', '--name-only', '--diff-filter=ACMR')) -split "`n" | Where-Object { $_ })
  foreach ($f in $files) {
    if ([IO.Path]::GetFileName($f) -ieq 'board.json') {
      $txt = G @('show', ":$f")
      try { $d = Read-BoardJson $txt; foreach ($x in @(Test-Board $d)) { $errs.Add("${f}：$x") }
            $old = $null; $ot = G @('show', "HEAD:$f"); if ($ot) { $old = Read-BoardJson $ot; foreach ($x in @(Test-BoardBookkeeping $old $d) + @(Test-BoardIntegrity $old $d)) { $errs.Add("${f}：$x") }
              $role = "$env:AIPM_ROLE"; if (-not $role -and (Test-Path -LiteralPath '.ai-hooks/config.json')) { try { $role = [string]((Get-Content -LiteralPath '.ai-hooks/config.json' -Raw -Encoding UTF8 | ConvertFrom-Json).role) } catch {} }
              if ($role -eq 'dev-agent') { foreach ($x in @(Test-BoardRole $old $d 'dev-agent')) { $errs.Add("${f}：$x") } } } }
      catch { $errs.Add("${f}：無法解析（$($_.Exception.Message)）") }
    }
    if ($f -match '\.feature$') { $warns.Add("$f：修改了 BDD 情境，PR 需要 spec-change 標籤並由核准者審查") }
  }
  # .ai-pm/board.json 不可刪除或搬走；.ai-pm/ 其他檔案（project.json、README）只提醒
  foreach ($l in ((G @('diff', '--cached', '--name-status', '-M')) -split "`n" | Where-Object { $_ })) { $c = $l -split "`t"
    if (($c[0] -eq 'D' -or $c[0] -like 'R*') -and $c[1] -match '(^|/)\.ai-pm/board\.json$') { $errs.Add("不可刪除或搬走 $($c[1])（看板資料）。要還原請在看板「歷史／備份」操作") }
    elseif ($c[0] -eq 'D' -and $c[1] -match '(^|/)\.ai-pm/project\.json$') { $errs.Add("不可刪除 $($c[1])（專案識別檔）") } }
  # 新增的行：不可新增 skip / only / ignore；非測試 Rust 的 unwrap 只警告
  $cur = ''; $n = 0
  foreach ($l in ((G @('diff', '--cached', '-U0', '--no-color')) -split "`n")) {
    if ($l -match '^\+\+\+ b/(.+)$') { $cur = $Matches[1]; continue }
    if ($l -notmatch '^\+' -or $l -match '^\+\+\+') { continue }
    if ($cur -match '\.(md|mdc|txt|html?|rst|adoc)$') { continue }   # 文件裡的範例文字不算測試
    $code = $l.Substring(1)
    if ($code -match '#\[ignore\]|\b(it|test|describe)\.(skip|only)\s*\(|\b(xit|xdescribe|fit|fdescribe)\s*\(|\.skip\(\s*["'']') { $errs.Add("${cur}：新增了被略過或只跑部分的測試：$($code.Trim())") }
    if ($cur -match '\.rs$' -and $cur -notmatch '(^|/)(tests|benches)/|_test\.rs$' -and $code -match '\.(unwrap|expect)\s*\(' -and $code -notmatch '^\s*//') { $warns.Add("${cur}：新增 unwrap()/expect()（若在 #[cfg(test)] 內可忽略）：$($code.Trim())") }
    if (++$n -gt 20000) { break }
  }
  # 版本同步：Cargo.toml / package.json / tauri.conf.json
  if ($files | Where-Object { $_ -match '(^|/)(Cargo\.toml|package\.json|tauri\.conf\.json)$' }) {
    $v = [ordered]@{}
    foreach ($c in 'src-tauri/Cargo.toml', 'Cargo.toml') { $t = G @('show', ":$c"); if ($t -and $t -match '(?ms)^\[package\][^\[]*?^version\s*=\s*"([^"]+)"') { $v[$c] = $Matches[1]; break } }
    $t = G @('show', ':package.json'); if ($t -and $t -match '"version"\s*:\s*"([^"]+)"') { $v['package.json'] = $Matches[1] }
    foreach ($c in 'src-tauri/tauri.conf.json', 'tauri.conf.json') { $t = G @('show', ":$c"); if ($t -and $t -match '"version"\s*:\s*"([^"]+)"') { $v[$c] = $Matches[1]; break } }
    if (@($v.Values | Select-Object -Unique).Count -gt 1) { $errs.Add('版本號不一致：' + (($v.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '、')) }
  }
}
foreach ($w in $warns) { Write-Host "⚠ $w" }
if ($errs.Count) { foreach ($e in ($errs | Select-Object -First 30)) { Write-Host "✗ $e" }; Write-Host "（$Mode 未通過，commit 已取消。請修正後重新 commit，不要用 --no-verify。）"; exit 1 }
exit 0

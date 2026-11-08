# Git-based 跨機器派工：遠端 runner pull 迴圈（T-GIT-4）
# 串起前三塊：定時 pull → 挑未領可領工單 → claim → 執行 AI（executor）→ 回報 push → 沒工單進 idle。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Git-Claim.ps1')
. (Join-Path $PSScriptRoot 'Git-Report.ps1')
. (Join-Path $PSScriptRoot 'Git-Heartbeat.ps1')

function Select-ClaimableTicket($Repo) {
  # 挑第一個可領的 Task：Todo／In Progress、沒有未過期的 claim、dependsOn 都 Done／Released
  $board = Get-Content -LiteralPath (Join-Path $Repo 'board.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($it in $board.items) {
    if ([string]$it.level -ne 'Task' -or [string]$it.status -notin 'Todo', 'In Progress') { continue }
    $cf = Join-Path $Repo "claims/$($it.id).json"
    if (Test-Path -LiteralPath $cf) {
      try {
        $c = Get-Content -LiteralPath $cf -Raw -Encoding UTF8 | ConvertFrom-Json
        $u = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$c.until, [ref]$u) -and $u -gt [DateTimeOffset]::Now) { continue }   # 還有人領著
      } catch { continue }   # F2：損毀的 claim 檔保守當有人領，跳過、不中斷整個 runner
    }
    $depOk = $true
    if ($it.PSObject.Properties['dependsOn'] -and $it.dependsOn) {
      foreach ($d in $it.dependsOn) { $x = $board.items | Where-Object { $_.id -eq $d }; if (-not $x -or [string]$x.status -notin 'Done', 'Released') { $depOk = $false } }   # 查無相依工單也保守當未滿足
    }
    if ($depOk) { return [string]$it.id }
  }
  $null
}

function Invoke-GitRunnerOnce {
  # 一次迭代：回傳 'IDLE'（沒工單）、'SKIP:<id>'（搶輸了）、'<report>:<id>'（已領並回報，report 為 REPORTED/CONFLICT/INVALID…）
  param([string]$Repo, [string]$Runner, [scriptblock]$Executor)
  Invoke-Git $Repo fetch -q origin main | Out-Null
  Invoke-Git $Repo reset -q --hard origin/main | Out-Null
  $cand = Select-ClaimableTicket $Repo
  if (-not $cand) { return 'IDLE' }
  if ((Invoke-GitClaim $Repo $cand $Runner) -ne 'CLAIMED') { return "SKIP:$cand" }   # 別台先搶到
  $board = ConvertFrom-JsonKeepDates (Get-Content -LiteralPath (Join-Path $Repo 'board.json') -Raw -Encoding UTF8)   # base 要保留毫秒，否則一讀進來就被截到秒、樂觀鎖失效
  $base = [string]($board.items | Where-Object { $_.id -eq $cand }).updatedAt
  try { $upd = & $Executor $Repo $cand }   # 執行 AI（本機啟動 CLI 的部分沿用現有派工器，這裡注入）
  catch { Release-GitClaim $Repo $cand $Runner | Out-Null; return "EXEC_FAILED:$cand" }   # F4：executor 失敗就釋放 claim，別占著
  if (-not $upd) { return "CLAIMED:$cand" }
  if ((Invoke-GitHeartbeat $Repo $cand $Runner) -eq 'LOST') { return "LOST:$cand" }   # F3：回報前確認 claim 還是自己的（executor 跑太久被重領就放棄，別蓋掉接手者）
  $rep = Invoke-GitReport $Repo $cand $base $upd
  "${rep}:$cand"
}

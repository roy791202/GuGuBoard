# Git-based 跨機器派工：遠端 runner pull 迴圈（T-GIT-4）
# 串起前三塊：定時 pull → 挑未領可領工單 → claim → 執行 AI（executor）→ 回報 push → 沒工單進 idle。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Git-Claim.ps1')
. (Join-Path $PSScriptRoot 'Git-Report.ps1')
. (Join-Path $PSScriptRoot 'Git-Heartbeat.ps1')
. (Join-Path $PSScriptRoot 'Git-DeadLetter.ps1')

function Select-ClaimableTicket($Repo, [int]$MaxInvalid = 3) {
  # 挑第一個可領的 Task：Todo／In Progress、沒有未過期的 claim、非死信、dependsOn 都 Done／Released
  $board = Get-Content -LiteralPath (Join-Path $Repo 'board.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($it in $board.items) {
    if ([string]$it.level -ne 'Task' -or [string]$it.status -notin 'Todo', 'In Progress') { continue }
    if (Test-GitDeadLettered $Repo ([string]$it.id) $MaxInvalid) { continue }   # T-GIT-5：連續 N 次 INVALID 的死信工單，所有 runner 一律跳過
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
  # 一次迭代：回傳 'IDLE'（沒工單）、'SKIP:<id>'（搶輸了）、'<report>:<id>'（已領並回報，report 為 REPORTED/CONFLICT/INVALID…）、
  #            'DEADLETTER:<id>'（本輪 INVALID 使連續次數達上限，已隔離，自此不再重領）
  param([string]$Repo, [string]$Runner, [scriptblock]$Executor, [int]$MaxInvalid = 3)
  Invoke-Git $Repo fetch -q origin main | Out-Null
  Invoke-Git $Repo reset -q --hard origin/main | Out-Null
  $cand = Select-ClaimableTicket $Repo $MaxInvalid
  if (-not $cand) { return 'IDLE' }
  if ((Invoke-GitClaim $Repo $cand $Runner) -ne 'CLAIMED') { return "SKIP:$cand" }   # 別台先搶到
  $board = ConvertFrom-JsonKeepDates (Get-Content -LiteralPath (Join-Path $Repo 'board.json') -Raw -Encoding UTF8)   # base 要保留毫秒，否則一讀進來就被截到秒、樂觀鎖失效
  $base = [string]($board.items | Where-Object { $_.id -eq $cand }).updatedAt
  try { $upd = & $Executor $Repo $cand }   # 執行 AI（本機啟動 CLI 的部分沿用現有派工器，這裡注入）
  catch { Release-GitClaim $Repo $cand $Runner | Out-Null; return "EXEC_FAILED:$cand" }   # F4：executor 失敗就釋放 claim，別占著
  if (-not $upd) { return "CLAIMED:$cand" }
  if ((Invoke-GitHeartbeat $Repo $cand $Runner) -eq 'LOST') { return "LOST:$cand" }   # F3：回報前確認 claim 還是自己的（executor 跑太久被重領就放棄，別蓋掉接手者）
  $rep = Invoke-GitReport $Repo $cand $base $upd
  if ($rep -eq 'INVALID') {
    # T-GIT-5：連續 INVALID 計數 +1，並釋放 claim（別占著 lease、也讓別台／本台下輪能重判）。
    $dl = Add-GitDeadLetterFail $Repo $cand $Runner "runner $Runner 回報 INVALID：executor 更新不符 L1–L7" $MaxInvalid
    Release-GitClaim $Repo $cand $Runner | Out-Null
    if ($dl -eq 'DEAD') {
      Add-DeadLetterBoardNote $Repo $cand $MaxInvalid | Out-Null   # best-effort：工單留 note 交人工（note-only，不改狀態/燈號）
      return "DEADLETTER:$cand"
    }
    return "INVALID:$cand"
  }
  if ($rep -eq 'REPORTED') { Clear-GitDeadLetter $Repo $cand | Out-Null }   # 成功回報＝連續中斷，死信計數歸零
  "${rep}:$cand"
}

function Add-DeadLetterBoardNote($Repo, $Ticket, [int]$MaxInvalid) {
  # 工單死信時在 board.json 留一筆 note 交人工。note-only 不動狀態/燈號，過得了 L1–L7；
  # 失敗（CONFLICT／別台搶改／重試用盡）就算了，死信判斷本身靠 deadletters/ 檔，不靠這筆 note。
  try {
    $b = ConvertFrom-JsonKeepDates (Get-Content -LiteralPath (Join-Path $Repo 'board.json') -Raw -Encoding UTF8)
    $base = [string]($b.items | Where-Object { $_.id -eq $Ticket }).updatedAt
    Invoke-GitReport $Repo $Ticket $base @{ note = "死信隔離：連續 $MaxInvalid 次 INVALID，已停止重領，待人工處理" } '死信隔離 note' | Out-Null
  } catch {}
}

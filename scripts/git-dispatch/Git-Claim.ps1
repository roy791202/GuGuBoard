# Git-based 跨機器派工：claim 協議（T-GIT-1）
# 領工單＝建/改 claims/<ticket>.json → commit → push。push 成功才算領到；
# 被 non-fast-forward 拒＝別台先 push，重新 pull 後再判。per-ticket 檔讓「同張競爭、異張自動合併」天然成立。
$ErrorActionPreference = 'Stop'

function Invoke-Git {   # 包一層：回傳 @(exitCode, 輸出)，用 exit code 判成敗
  param([string]$Repo, [Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  # git 把進度／reject 摘要寫到 stderr；在 ErrorActionPreference=Stop 下 2>&1 會被當 error 拋出，
  # 所以這裡暫時降級成 Continue，純用 $LASTEXITCODE 判斷成敗。
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = (& git -C $Repo @GitArgs 2>&1 | Out-String) } finally { $ErrorActionPreference = $old }
  @($LASTEXITCODE, $out.Trim())
}

# pwsh 7 的裸 ConvertFrom-Json 會把 ISO 字串轉成 [DateTime]，[string] 後只剩到「秒」，
# 樂觀鎖的毫秒精度 updatedAt 會被吃掉（同一秒兩次更新比不出差異）。-DateKind String 讓日期保留原字串；
# 5.1 沒有這個參數、但本來就不轉 DateTime，所以依版本條件帶參數。
$script:HasDateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')
function ConvertFrom-JsonKeepDates([Parameter(ValueFromPipeline = $true)][string]$Text) {
  if ($script:HasDateKind) { $Text | ConvertFrom-Json -DateKind String } else { $Text | ConvertFrom-Json }
}

function Invoke-GitClaim {
  # 回傳 'CLAIMED'（領到）、'NOT_CLAIMED'（已被別台領且未過期）、'FAILED'（重試用盡）
  param([string]$Repo, [string]$Ticket, [string]$Runner, [int]$LeaseMin = 15, [int]$MaxRetry = 5)
  for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
    # 1. 同步到 origin 最新（丟棄本地未 push 的）
    Invoke-Git $Repo fetch -q origin main | Out-Null
    Invoke-Git $Repo reset -q --hard origin/main | Out-Null
    # 2. 已被別台領且未過期就放棄（讓給對方）
    $claimFile = Join-Path $Repo "claims/$Ticket.json"
    if (Test-Path -LiteralPath $claimFile) {
      try {
        $c = Get-Content -LiteralPath $claimFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $until = [DateTimeOffset]::MinValue; $parsed = [DateTimeOffset]::TryParse([string]$c.until, [ref]$until)
        if ([string]$c.by -ne $Runner -and $parsed -and $until -gt [DateTimeOffset]::Now) { return 'NOT_CLAIMED' }
      } catch { return 'NOT_CLAIMED' }   # 損毀的 claim 檔：保守當作有人領著，不覆蓋（交人工處理）
    }
    # 3. 寫 claim 並 commit
    $claim = [ordered]@{ ticketId = $Ticket; by = $Runner; host = [Environment]::MachineName; at = [DateTimeOffset]::Now.ToString('o'); until = [DateTimeOffset]::Now.AddMinutes($LeaseMin).ToString('o') }
    $dir = Split-Path $claimFile; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    [IO.File]::WriteAllText($claimFile, ($claim | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Invoke-Git $Repo add -- "claims/$Ticket.json" | Out-Null
    Invoke-Git $Repo commit -q -m "claim $Ticket by $Runner" | Out-Null
    # 4. push：成功＝領到；被 non-fast-forward 拒＝別台先 push，丟棄本地 commit 後回圈重判
    $p = Invoke-Git $Repo push -q origin HEAD:main
    if ($p[0] -eq 0) { return 'CLAIMED' }
    Invoke-Git $Repo reset -q --hard 'HEAD~1' | Out-Null
  }
  return 'FAILED'
}

function Release-GitClaim {
  # 釋放自己的 claim（刪 claims/<ticket>.json）。回傳 'RELEASED'、'NOT_MINE'（不是自己的，不動）、'FAILED'
  param([string]$Repo, [string]$Ticket, [string]$Runner, [int]$MaxRetry = 5)
  for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
    Invoke-Git $Repo fetch -q origin main | Out-Null
    Invoke-Git $Repo reset -q --hard origin/main | Out-Null
    $claimFile = Join-Path $Repo "claims/$Ticket.json"
    if (-not (Test-Path -LiteralPath $claimFile)) { return 'RELEASED' }
    try { $c = Get-Content -LiteralPath $claimFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ([string]$c.by -ne $Runner) { return 'NOT_MINE' } } catch {}
    Invoke-Git $Repo rm -q -- "claims/$Ticket.json" | Out-Null
    Invoke-Git $Repo commit -q -m "release $Ticket by $Runner" | Out-Null
    $p = Invoke-Git $Repo push -q origin HEAD:main
    if ($p[0] -eq 0) { return 'RELEASED' }
    Invoke-Git $Repo reset -q --hard origin/main | Out-Null
  }
  return 'FAILED'
}

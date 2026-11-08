# Git-based 跨機器派工：heartbeat 續租（T-GIT-3）
# runner 定時更新 claims/<ticket>.json 的 until（續租）。claim 的「until 過期可領」就是逾期重領：
# runner 失聯不再續租 → until 過期 → 別台 Invoke-GitClaim 可接手。原 runner 若之後想續租，
# 發現 claim 已不是自己的（被接手）就回 LOST，不搶回。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Git-Claim.ps1')   # 取 Invoke-Git

function Invoke-GitHeartbeat {
  # 回傳 'RENEWED'（已續租）、'LOST'（claim 已不屬於自己／不存在）、'FAILED'（重試用盡）
  param([string]$Repo, [string]$Ticket, [string]$Runner, [int]$LeaseMin = 15, [int]$MaxRetry = 5)
  for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
    Invoke-Git $Repo fetch -q origin main | Out-Null
    Invoke-Git $Repo reset -q --hard origin/main | Out-Null
    $claimFile = Join-Path $Repo "claims/$Ticket.json"
    if (-not (Test-Path -LiteralPath $claimFile)) { return 'LOST' }   # claim 不見了
    try { $c = Get-Content -LiteralPath $claimFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return 'LOST' }   # 損毀的 claim 檔：當作已失去租約，不中斷 runner（與 Claim/Select/Release 保守處理一致）
    if ([string]$c.by -ne $Runner) { return 'LOST' }   # 已被別台接手，不搶回
    $c.until = [DateTimeOffset]::Now.AddMinutes($LeaseMin).ToString('o')
    [IO.File]::WriteAllText($claimFile, ($c | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Invoke-Git $Repo add -- "claims/$Ticket.json" | Out-Null
    Invoke-Git $Repo commit -q -m "heartbeat $Ticket by $Runner" | Out-Null
    $p = Invoke-Git $Repo push -q origin HEAD:main
    if ($p[0] -eq 0) { return 'RENEWED' }
    Invoke-Git $Repo reset -q --hard 'HEAD~1' | Out-Null   # push 被拒：別台改了別的，重試
  }
  return 'FAILED'
}

# Git-based 跨機器派工：死信隔離（T-GIT-5）
# 問題：executor 若每次都產出不合 L1–L7 的更新 → Git-Report 回 INVALID → 別台重領 → 再 INVALID…
#       跨機器無限重跑、燒算力。對策＝連續 N 次 INVALID 就把工單標成死信，所有 runner 的 Select 自此跳過。
# 計數存在專屬檔 deadletters/<ticket>.json（跟 claims/ 一樣逐張一檔、git 同步、跨機器持久），
# 刻意「不」寫進 board.json：免過 L1–L7 驗證、免與回報搶樂觀鎖，死信判斷永遠挑得乾淨。
# 歸零：成功回報（連續中斷）或人工刪檔。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Git-Claim.ps1')   # 取 Invoke-Git

function Get-GitDeadLetter {
  # 讀本地 repo 的死信檔；沒有或損毀回 $null
  param([string]$Repo, [string]$Ticket)
  $f = Join-Path $Repo "deadletters/$Ticket.json"
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Test-GitDeadLettered {
  # 該工單是否已達死信門檻（failCount >= N）
  param([string]$Repo, [string]$Ticket, [int]$MaxInvalid = 3)
  $d = Get-GitDeadLetter $Repo $Ticket
  return [bool]($d -and ([int]$d.failCount -ge $MaxInvalid))
}

function Add-GitDeadLetterFail {
  # 連續 INVALID +1：寫/更新 deadletters/<ticket>.json → commit → push。
  # 回傳 'DEAD'（已達上限）、'COUNTED'（未達）、'FAILED'（重試用盡）。用與 claim 同款樂觀鎖重放。
  param([string]$Repo, [string]$Ticket, [string]$Runner,
    [string]$Reason = 'executor 連續產出不合 L1–L7 的更新', [int]$MaxInvalid = 3, [int]$MaxRetry = 5)
  for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
    Invoke-Git $Repo fetch -q origin main | Out-Null
    Invoke-Git $Repo reset -q --hard origin/main | Out-Null
    $cur = Get-GitDeadLetter $Repo $Ticket
    $prev = 0; $firstAt = $null
    if ($cur) { $prev = [int]$cur.failCount; if ($cur.firstFailAt) { $firstAt = [string]$cur.firstFailAt } }
    $count = $prev + 1
    $now = [DateTimeOffset]::Now.ToString('o')
    if (-not $firstAt) { $firstAt = $now }
    $rec = [ordered]@{
      ticketId    = $Ticket
      failCount   = $count
      maxInvalid  = $MaxInvalid
      blocked     = ($count -ge $MaxInvalid)
      firstFailAt = $firstAt
      lastFailAt  = $now
      lastRunner  = $Runner
      lastReason  = $Reason
    }
    $f = Join-Path $Repo "deadletters/$Ticket.json"
    $dir = Split-Path $f; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    [IO.File]::WriteAllText($f, ($rec | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Invoke-Git $Repo add -- "deadletters/$Ticket.json" | Out-Null
    Invoke-Git $Repo commit -q -m "deadletter $Ticket failCount=$count by $Runner" | Out-Null
    $p = Invoke-Git $Repo push -q origin HEAD:main
    if ($p[0] -eq 0) { if ($count -ge $MaxInvalid) { return 'DEAD' } else { return 'COUNTED' } }
    Invoke-Git $Repo reset -q --hard 'HEAD~1' | Out-Null   # 被別台先 push：丟棄本地 commit 後回圈重讀重算
  }
  return 'FAILED'
}

function Clear-GitDeadLetter {
  # 歸零：刪 deadletters/<ticket>.json → commit → push。成功回報或人工介入後呼叫。
  # 回傳 'CLEARED'（已清或本來就沒有）、'FAILED'（重試用盡）。
  param([string]$Repo, [string]$Ticket, [int]$MaxRetry = 5)
  for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
    Invoke-Git $Repo fetch -q origin main | Out-Null
    Invoke-Git $Repo reset -q --hard origin/main | Out-Null
    $f = Join-Path $Repo "deadletters/$Ticket.json"
    if (-not (Test-Path -LiteralPath $f)) { return 'CLEARED' }
    Invoke-Git $Repo rm -q -- "deadletters/$Ticket.json" | Out-Null
    Invoke-Git $Repo commit -q -m "deadletter clear $Ticket" | Out-Null
    $p = Invoke-Git $Repo push -q origin HEAD:main
    if ($p[0] -eq 0) { return 'CLEARED' }
    Invoke-Git $Repo reset -q --hard origin/main | Out-Null
  }
  return 'FAILED'
}

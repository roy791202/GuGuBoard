# Git-based 跨機器派工：回報合併（T-GIT-2）
# runner 回報＝改 board.json 的該工單 → commit → push。用重放式樂觀鎖處理併發：
# 回報前記下 item.updatedAt 當基準；push 前重讀最新 origin，若該 item 已被別台改過＝CONFLICT（交人工），
# 否則重新套用自己的變更（別台改的是別張時自動合併）；套用後跑 L1–L7，不過就 INVALID 不 push。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Git-Claim.ps1')   # 取 Invoke-Git

function Invoke-GitReport {
  # updates: @{ note=..; status=..; light=..; lightReason=.. }（有哪個改哪個）
  # 回傳 'REPORTED'（已回報）、'CONFLICT'（同張被別台改過，交人工）、'INVALID'（不符 L1–L7）、
  #      'NOT_FOUND'（查無此工單）、'FAILED'（重試用盡）
  param([string]$Repo, [string]$Ticket, [string]$BaseUpdatedAt, [hashtable]$Updates, [string]$Reason = '派工 runner 回報', [int]$MaxRetry = 5)
  $boardPath = Join-Path $Repo 'board.json'; $validator = Join-Path $Repo 'validate-board.ps1'
  for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
    # 1. 同步到最新 origin
    Invoke-Git $Repo fetch -q origin main | Out-Null
    Invoke-Git $Repo reset -q --hard origin/main | Out-Null
    $oldText = Get-Content -LiteralPath $boardPath -Raw -Encoding UTF8   # 原始版：下面當 OldPath 驗 L5/L7/完整性
    $board = ConvertFrom-JsonKeepDates $oldText   # 保留 updatedAt 毫秒字串，樂觀鎖才比得出同秒差異
    $item = $board.items | Where-Object { $_.id -eq $Ticket } | Select-Object -First 1
    if (-not $item) { return 'NOT_FOUND' }
    # 2. 樂觀鎖：該工單自我讀取後被別台改過 → 衝突，交人工（不亂合）
    if ([string]$item.updatedAt -ne $BaseUpdatedAt) { return 'CONFLICT' }
    # 3. 套用變更
    $now = (Get-Date).ToString('yyyy-MM-dd\THH\:mm\:ss.fffzzz', [Globalization.CultureInfo]::InvariantCulture)   # 補毫秒，避免同一秒內兩台撞樂觀鎖
    $fromStatus = [string]$item.status; $fromLight = [string]$item.light   # 先抓舊值，下面 foreach 會覆寫
    if ($Updates.ContainsKey('note')) {
      $n = @(); if ($item.PSObject.Properties['notes'] -and $item.notes) { $n = @($item.notes) }
      $item | Add-Member notes (@($n) + [pscustomobject]@{ at = $now; by = 'runner'; text = [string]$Updates.note }) -Force
    }
    foreach ($k in $Updates.Keys) { if ($k -ne 'note') { $item | Add-Member $k ([string]$Updates[$k]) -Force } }   # note 另外追加；其餘欄位（status/light/prUrl…）直接設
    $toStr = "$($item.status) / $($item.light)"; $fromStr = "$fromStatus / $fromLight"
    if (($Updates.ContainsKey('status') -or $Updates.ContainsKey('light')) -and $toStr -ne $fromStr) {   # 狀態或燈號「真的變了」才補 history（L7，from 用改前的值、note 必填；值沒變不留無意義紀錄）
      $h = @(); if ($item.PSObject.Properties['history'] -and $item.history) { $h = @($item.history) }
      $item | Add-Member history (@($h) + [pscustomobject]@{ at = $now; from = $fromStr; to = $toStr; by = 'runner'; note = $Reason }) -Force
    }
    $item | Add-Member updatedAt $now -Force; $board.updatedAt = $now
    [IO.File]::WriteAllText($boardPath, ($board | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    # 4. push 前驗 L1–L7：帶 OldPath＋Role，跟 .ai-hooks／.githooks／CI 同一把尺（runner＝dev-agent，擋 Done／藍燈／Released）
    $oldFile = Join-Path ([IO.Path]::GetTempPath()) ('oldboard-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($oldFile, $oldText, [Text.UTF8Encoding]::new($false))
    # 用「當前直譯器」跑 validator，而非寫死 powershell（Linux/Mac runner 沒有 powershell.exe，寫死會整輪炸掉；也避免在 Windows 被強制降到 5.1）
    $onWin = ($PSVersionTable.Platform -ne 'Unix')   # 5.1 無 Platform 屬性＝$null→非 Unix→Windows
    $psExe = (Get-Process -Id $PID).Path; if (-not $psExe) { $psExe = if ($onWin) { 'powershell' } else { 'pwsh' } }
    $psArgs = @('-NoProfile'); if ($onWin) { $psArgs += @('-ExecutionPolicy', 'Bypass') }   # -ExecutionPolicy 只在 Windows 有意義
    $psArgs += @('-File', $validator, '-Path', $boardPath, '-OldPath', $oldFile, '-Role', 'dev-agent')
    & $psExe @psArgs *> $null
    $vcode = $LASTEXITCODE; Remove-Item $oldFile -Force -ErrorAction SilentlyContinue
    if ($vcode -ne 0) { Invoke-Git $Repo reset -q --hard origin/main | Out-Null; return 'INVALID' }
    # 5. commit + push：成功＝回報完成；被拒＝別台改了別張，丟棄本地 commit 後回圈重放
    Invoke-Git $Repo add -- 'board.json' | Out-Null
    Invoke-Git $Repo commit -q -m "report $Ticket" | Out-Null
    $p = Invoke-Git $Repo push -q origin HEAD:main
    if ($p[0] -eq 0) { return 'REPORTED' }
    Invoke-Git $Repo reset -q --hard 'HEAD~1' | Out-Null
  }
  return 'FAILED'
}

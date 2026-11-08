# 驗收後補強：鎖住 A/B 指出的存活 mutation 與 BLOCKER 修正
. (Join-Path $PSScriptRoot '_Helper.ps1')

Describe 'git-dispatch 補強（獨立驗收後）' {
  It 'BLOCKER-1 report 把工單設成 Done/Blue 被 L5 擋（INVALID、不搶改角色）' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'; $base = Get-TicketUpdatedAt $a 'T-1'
      (Invoke-GitReport $a 'T-1' $base @{ status = 'Done'; light = 'Blue' }) | Should Be 'INVALID'
      ((Get-OriginBoard $fix).items | Where-Object { $_.id -eq 'T-1' }).status | Should Be 'Todo'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'BLOCKER-2/MAJOR-3 report 改狀態時 history from 用舊值、且含 note' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'; $base = Get-TicketUpdatedAt $a 'T-1'
      (Invoke-GitReport $a 'T-1' $base @{ status = 'In Progress'; light = 'Green' } '開始做') | Should Be 'REPORTED'
      $h = ((Get-OriginBoard $fix).items | Where-Object { $_.id -eq 'T-1' }).history[-1]
      $h.from | Should Be 'Todo / Gray'
      $h.to | Should Be 'In Progress / Green'
      [string]$h.note | Should Be '開始做'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'R6b report 對已有多筆 notes 的工單追加而非覆蓋' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      Edit-OriginBoard $fix { param($b) ($b.items | Where-Object { $_.id -eq 'T-1' }) | Add-Member notes @([pscustomobject]@{ at = '2026-11-08T00:00:00+08:00'; by = 'u'; text = '舊1' }, [pscustomobject]@{ at = '2026-11-08T00:00:01+08:00'; by = 'u'; text = '舊2' }) -Force }
      $base = Get-TicketUpdatedAt $a 'T-1'
      (Invoke-GitReport $a 'T-1' $base @{ note = '新' }) | Should Be 'REPORTED'
      @(((Get-OriginBoard $fix).items | Where-Object { $_.id -eq 'T-1' }).notes).Count | Should Be 3
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S2 Select 跳過 dependsOn 未 Done 的工單' {
    $fix = New-GitDispatchFixture @('T-1', 'T-2')
    try {
      $a = New-Runner $fix 'A'
      Edit-OriginBoard $fix { param($b) ($b.items | Where-Object { $_.id -eq 'T-2' }) | Add-Member dependsOn @('T-1') -Force }
      Sync-Runner $a
      Select-ClaimableTicket $a | Should Be 'T-1'   # T-2 的相依 T-1 還沒 Done
      Invoke-GitClaim $a 'T-1' 'A' | Out-Null; Sync-Runner $a
      Select-ClaimableTicket $a | Should BeNullOrEmpty   # T-1 被領、T-2 相依未滿足
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S2b Select 對 dependsOn 指向不存在工單保守不領' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      Edit-OriginBoard $fix { param($b) ($b.items | Where-Object { $_.id -eq 'T-1' }) | Add-Member dependsOn @('T-GHOST') -Force }
      Sync-Runner $a
      Select-ClaimableTicket $a | Should BeNullOrEmpty
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S4 Select 跳過非 Todo/In Progress 的工單' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      Edit-OriginBoard $fix { param($b) $it = $b.items | Where-Object { $_.id -eq 'T-1' }; $it.status = 'Done'; $it.light = 'Blue' }
      Sync-Runner $a
      Select-ClaimableTicket $a | Should BeNullOrEmpty
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'F4 runner 的 executor 丟例外時釋放 claim、回 EXEC_FAILED' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      (Invoke-GitRunnerOnce $a 'A' { param($r, $t) throw '炸了' }) | Should Match 'EXEC_FAILED'
      (Get-OriginClaim $fix 'T-1') | Should BeNullOrEmpty   # claim 已釋放，別台可接手
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'F2 Select 遇到損毀 claim 檔不中斷、保守跳過' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      Corrupt-OriginClaim $fix 'T-1'; Sync-Runner $a
      { Select-ClaimableTicket $a } | Should Not Throw
      Select-ClaimableTicket $a | Should BeNullOrEmpty
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'H4 heartbeat 對不存在的 claim 回 LOST' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      (Invoke-GitHeartbeat $a 'T-1' 'A') | Should Be 'LOST'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'R7 report 對已有多筆 history 的工單是追加、舊筆原封不動' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      Edit-OriginBoard $fix { param($b) ($b.items | Where-Object { $_.id -eq 'T-1' }) | Add-Member history @(
          [pscustomobject]@{ at = '2026-11-08T00:00:00+08:00'; from = '-'; to = 'Backlog / Gray'; by = 'u'; note = '建立' },
          [pscustomobject]@{ at = '2026-11-08T00:00:01+08:00'; from = 'Backlog / Gray'; to = 'Todo / Gray'; by = 'u'; note = '排入' }) -Force }
      $base = Get-TicketUpdatedAt $a 'T-1'
      (Invoke-GitReport $a 'T-1' $base @{ status = 'In Progress'; light = 'Green' } '開工') | Should Be 'REPORTED'
      $h = @(((Get-OriginBoard $fix).items | Where-Object { $_.id -eq 'T-1' }).history)
      $h.Count | Should Be 3                         # 追加不是覆蓋
      [string]$h[0].note | Should Be '建立'           # 舊筆原封不動
      [string]$h[1].note | Should Be '排入'
      $h[2].from | Should Be 'Todo / Gray'           # 新筆 from 用改前的值
      $h[2].to | Should Be 'In Progress / Green'
      [string]$h[2].note | Should Be '開工'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'R8 樂觀鎖毫秒精度：同一秒內 base 與現值差毫秒也要 CONFLICT' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      Edit-OriginBoard $fix { param($b) ($b.items | Where-Object { $_.id -eq 'T-1' }).updatedAt = '2026-11-08T12:00:00.456+08:00' }
      # base 與現值同一秒、只差毫秒：pwsh7 若把日期截到秒就會漏判（這測試鎖住 -DateKind String 修正）
      (Invoke-GitReport $a 'T-1' '2026-11-08T12:00:00.123+08:00' @{ status = 'In Progress'; light = 'Green' } 'x') | Should Be 'CONFLICT'
      ((Get-OriginBoard $fix).items | Where-Object { $_.id -eq 'T-1' }).status | Should Be 'Todo'   # 沒被覆蓋
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'H5 heartbeat 遇損毀 claim 檔回 LOST、不丟例外' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      Corrupt-OriginClaim $fix 'T-1'
      { Invoke-GitHeartbeat $a 'T-1' 'A' } | Should Not Throw
      (Invoke-GitHeartbeat $a 'T-1' 'A') | Should Be 'LOST'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'R9 report 值沒變(status 回報相同值)不產生無意義 history' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'; $base = Get-TicketUpdatedAt $a 'T-1'
      (Invoke-GitReport $a 'T-1' $base @{ status = 'Todo' } '重送') | Should Be 'REPORTED'
      $item = (Get-OriginBoard $fix).items | Where-Object { $_.id -eq 'T-1' }
      $hc = 0; if ($item.PSObject.Properties['history'] -and $item.history) { $hc = @($item.history).Count }
      $hc | Should Be 0   # Todo→Todo 不留 history
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S5 真並行兩台 runner 同一張：一台回報、一台 SKIP' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'; $rp = Join-Path $RepoScripts 'Git-Runner.ps1'
      $sb = { param($repo, $runner, $scriptPath) . $scriptPath; Invoke-GitRunnerOnce $repo $runner { param($r, $t) @{ note = "$runner 做" } } }
      $ja = Start-Job -ScriptBlock $sb -ArgumentList $a, 'A', $rp
      $jb = Start-Job -ScriptBlock $sb -ArgumentList $b, 'B', $rp
      $null = Wait-Job $ja, $jb -Timeout 60
      $res = @((Receive-Job $ja), (Receive-Job $jb)); Remove-Job $ja, $jb -Force
      @($res | Where-Object { $_ -match 'REPORTED' }).Count | Should Be 1
      @($res | Where-Object { $_ -match 'SKIP|IDLE' }).Count | Should Be 1   # 另一台搶輸（SKIP）或沒挑到（IDLE）
    } finally { Remove-GitDispatchFixture $fix }
  }
}
